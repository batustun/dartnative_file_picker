// DNFilePickerBridge.kt
// Kotlin/JNI bridge for dartnative_file_picker — Android side.
//
// Mirrors the iOS surface in ios/Classes/DNFilePickerBridge.swift. Every
// entry point is a @Keep top-level function called from the extern "C" symbols
// in dn_file_picker_bridge.cpp.
//
// Two architectural notes:
//
//  * DartNative exposes NO Activity-result hook (no onActivityResult, no
//    ActivityAware equivalent — verified by a repo-wide search). ACTION_OPEN_DOCUMENT
//    needs a result, so this plugin owns FilePickerProxyActivity: a transparent
//    activity declared in this plugin's manifest that runs the
//    startActivityForResult round trip and hands the result back here.
//
//  * This plugin deliberately does NOT depend on project(':dartnative_android'),
//    so it has no DNNavigator/DNAppContext/DNCallbackFire. The framework docs
//    state that a plugin with that dependency "cannot yet produce its own
//    Android archive for publishing", which would make a community plugin
//    unpublishable. The Context comes from the FlutterPluginBinding instead
//    (the documented pattern for view-less plugins), and the hot-restart guard
//    resolves DN_IsolateGen() at runtime via dlsym.

package com.dartnative.file_picker

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import androidx.annotation.Keep
import java.io.BufferedInputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONArray
import org.json.JSONObject

internal const val TAG = "DNFilePicker"

/** Subdirectory under cacheDir that copied documents land in. */
private const val CACHE_SUBDIR = "dn_file_picker"

// Wire contract with FilePickerErrorCode in Dart. native_codec_test.dart
// asserts every Dart code round-trips, so a name that exists on one side only
// is caught by the test suite.
private const val ERR_UNSUPPORTED_TYPE = "unsupportedType"
private const val ERR_ACCESS_DENIED = "accessDenied"
private const val ERR_PROVIDER_UNAVAILABLE = "providerUnavailable"
private const val ERR_READ_FAILED = "readFailed"
private const val ERR_COPY_FAILED = "copyFailed"
private const val ERR_PERSISTENCE_FAILED = "persistenceFailed"
private const val ERR_NATIVE_FAILURE = "nativeFailure"
private const val ERR_NO_CONTEXT = "noPresentationContext"
private const val ERR_PICKER_BUSY = "pickerBusy"

private const val EVENT_JSON = 1
private const val EVENT_CHUNK = 2
private const val EVENT_EOF = 3

/** Application context, set by DartNativeFilePickerPlugin on engine attach. */
@Volatile internal var appContext: Context? = null

/** I/O pool. Reads and copies must never run on the main thread: in DartNative
 *  the main thread is both the UI thread and the Dart isolate's thread. */
private val ioExecutor = Executors.newCachedThreadPool { runnable ->
    Thread(runnable, "dn-file-picker-io").apply { isDaemon = true }
}

private val mainHandler = Handler(Looper.getMainLooper())

// ─── Result dispatcher (generation-gated — hot-restart safe) ──────────────────
//
// Dart hands us ONE dispatcher address for the whole plugin. The pointer is an
// isolate-bound trampoline that a hot restart deletes, so we capture the
// framework's isolate generation NEXT TO the pointer and compare before EVERY
// delivery: the framework bumps the generation before the old isolate dies, so a
// picker still open across a restart delivers into a stale generation and is
// dropped rather than calling freed memory.

@Volatile private var dispatcherPtr: Long = 0L
@Volatile private var dispatcherGen: Long = 0L

@Keep
fun setDispatcher(ptr: Long) {
    dispatcherPtr = ptr
    dispatcherGen = nativeIsolateGen() // capture the generation WITH the pointer
}

/** Reads DN_IsolateGen() from the framework's .so (see the cpp bridge). */
private external fun nativeIsolateGen(): Long

/** Invokes the Dart dispatcher function pointer (see the cpp bridge). */
private external fun nativeDeliver(ptr: Long, token: Long, type: Int, payload: ByteArray?)

/** EVERY delivery to Dart goes through here: main thread, generation-gated. */
private fun deliver(token: Long, type: Int, payload: ByteArray?) {
    mainHandler.post {
        if (dispatcherGen != nativeIsolateGen()) return@post // restarted → drop
        val ptr = dispatcherPtr
        if (ptr == 0L) return@post
        nativeDeliver(ptr, token, type, payload)
    }
}

private fun deliverJson(token: Long, json: JSONObject) =
    deliver(token, EVENT_JSON, json.toString().toByteArray(Charsets.UTF_8))

private fun deliverError(
    token: Long,
    code: String,
    message: String,
    nativeCode: String? = null,
) {
    val error = JSONObject().put("code", code).put("message", message)
    if (nativeCode != null) error.put("nativeCode", nativeCode)
    deliverJson(token, JSONObject().put("__error", error))
}

private fun deliverCancelled(token: Long) =
    deliverJson(token, JSONObject().put("files", JSONArray()))

/** Maps a Java exception onto the closest Dart error code. */
private fun codeFor(e: Throwable, fallback: String): String = when (e) {
    is SecurityException -> ERR_ACCESS_DENIED
    is FileNotFoundException -> ERR_PROVIDER_UNAVAILABLE
    else -> fallback
}

// ─── Pick ────────────────────────────────────────────────────────────────────

/** A pick request waiting on the proxy activity's result. */
internal class PendingPick(
    val token: Long,
    val copyToCache: Boolean,
    val persistAccess: Boolean,
)

private val pendingPicks = ConcurrentHashMap<Long, PendingPick>()

/**
 * Presents the Storage Access Framework document picker.
 *
 * Fire-and-forget: the reply arrives through the dispatcher under [token] once
 * [FilePickerProxyActivity] reports the result.
 */
@Keep
fun pick(token: Long, requestJson: String?) {
    val context = appContext
    if (context == null) {
        deliverError(token, ERR_NO_CONTEXT, "The plugin has no application context yet.")
        return
    }
    if (requestJson == null) {
        deliverError(token, ERR_NATIVE_FAILURE, "The pick request was empty.")
        return
    }

    val request = try {
        JSONObject(requestJson)
    } catch (e: org.json.JSONException) {
        deliverError(
            token,
            ERR_NATIVE_FAILURE,
            "The pick request could not be parsed: ${e.message}",
        )
        return
    }

    if (pendingPicks.isNotEmpty()) {
        deliverError(token, ERR_PICKER_BUSY, "A document picker is already on screen.")
        return
    }

    val type = request.optString("type", "any")
    val allowMultiple = request.optBoolean("allowMultiple", false)
    val persistAccess = request.optBoolean("persistAccess", false)
    val copyToCache = request.optString("accessMode") == "copyToCache"
    val localOnly = request.optBoolean("localOnly", false)
    val mimeTypes = request.optJSONArray("mimeTypes").toStringList()
    val unresolved = request.optJSONArray("unresolvedExtensions").toStringList()

    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (!copyToCache) {
            // Asked for on every reference-mode pick, not only when the caller
            // wanted persistence, because the read grant in an activity result
            // dies with the activity that received it and this plugin's proxy
            // finishes at once. Without this flag
            // takePersistableUriPermission throws, and the URI handed back to
            // Dart would be unreadable by the time Dart could use it.
            //
            // Asking is not taking: the provider decides, and the grant is only
            // taken (and its lifetime recorded in SessionGrants) once the
            // result comes back. See SessionGrants for the whole argument.
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        if (allowMultiple) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        if (localOnly) putExtra(Intent.EXTRA_LOCAL_ONLY, true)
        applyFilter(this, type, mimeTypes, unresolved)
    }

    pendingPicks[token] = PendingPick(token, copyToCache, persistAccess)
    try {
        FilePickerProxyActivity.launch(context, token, intent)
    } catch (e: Exception) {
        pendingPicks.remove(token)
        Log.w(TAG, "could not start the picker: ${e.message}")
        deliverError(
            token,
            ERR_NO_CONTEXT,
            "The document picker activity could not be started.",
            e.javaClass.simpleName,
        )
    }
}

/**
 * Applies the MIME filter.
 *
 * `EXTRA_MIME_TYPES` is the supported way to offer several types, and Android
 * expects the intent's own type to be the wildcard when it is present.
 *
 * When a requested extension has no known MIME type the filter widens to the
 * full wildcard type instead of excluding it. Excluding would hide the very file the user
 * came for; widening shows more than was asked for, which the Dart side
 * documents (`PickerRequest.androidFilterIsExact`).
 */
private fun applyFilter(
    intent: Intent,
    type: String,
    mimeTypes: List<String>,
    unresolved: List<String>,
) {
    when (type) {
        "image" -> intent.type = "image/*"
        "video" -> intent.type = "video/*"
        "audio" -> intent.type = "audio/*"
        "custom" -> {
            if (unresolved.isNotEmpty() || mimeTypes.isEmpty()) {
                intent.type = "*/*"
            } else if (mimeTypes.size == 1) {
                intent.type = mimeTypes.first()
            } else {
                intent.type = "*/*"
                intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            }
        }
        else -> intent.type = "*/*"
    }
}

/**
 * Called by [FilePickerProxyActivity] with whatever the system returned.
 *
 * [uris] is empty for a cancellation, which is a normal outcome and is reported
 * as an empty file list rather than an error.
 */
internal fun onPickResult(token: Long, uris: List<Uri>) {
    val pending = pendingPicks.remove(token)
    if (pending == null) {
        // A result for a request this isolate no longer knows about: a hot
        // restart, or a duplicate delivery. Dropping it is correct.
        Log.i(TAG, "ignoring a result for unknown token $token")
        return
    }
    val context = appContext
    if (context == null) {
        deliverError(token, ERR_NO_CONTEXT, "The plugin lost its application context.")
        return
    }
    if (uris.isEmpty()) {
        deliverCancelled(token)
        return
    }

    // Metadata queries, persistence and copying all touch the provider, so none
    // of it belongs on the main thread.
    ioExecutor.execute {
        val files = JSONArray()
        for (uri in uris) {
            try {
                files.put(describe(context, uri, pending))
            } catch (e: Exception) {
                // One unreadable document must not lose the others the user
                // picked. Report the failure for the whole call only if nothing
                // at all could be described.
                Log.w(TAG, "could not describe $uri: ${e.message}")
            }
        }
        if (files.length() == 0) {
            deliverError(
                token,
                ERR_ACCESS_DENIED,
                "None of the selected documents could be opened.",
            )
        } else {
            deliverJson(token, JSONObject().put("files", files))
        }
    }
}

/** Builds one file record, copying the bytes first when that was requested. */
private fun describe(
    context: Context,
    uri: Uri,
    pending: PendingPick,
): JSONObject {
    val resolver = context.contentResolver
    val metadata = queryMetadata(resolver, uri)
    val name = metadata.first ?: uri.lastPathSegment ?: "document"

    // Reference mode always takes the persistable grant, because it is the only
    // mechanism Android offers for reading a picked document after the activity
    // that received the result is gone. What differs is who owns the grant
    // afterwards, which is what SessionGrants records:
    //
    //   persistAccess: true  -> the caller's, released only by release()
    //   persistAccess: false -> this session's, released on the next process
    //                           start or on engine detach
    //
    // copyToCache needs no grant at all: the bytes are copied below, inside the
    // window where the transient grant is still alive.
    val granted = if (pending.copyToCache) {
        false
    } else {
        takePersistableAccess(resolver, uri)
    }
    if (granted) {
        if (pending.persistAccess) {
            SessionGrants.registerOwned(context, uri)
        } else {
            SessionGrants.registerSession(context, uri)
        }
    } else if (!pending.copyToCache) {
        // Rare: a provider that routes through ACTION_OPEN_DOCUMENT but refuses
        // to persist. There is nothing honest to do about it here. The URI is
        // reported as picked and the first read fails with a typed
        // accessDenied, which is the truth, rather than this code quietly
        // copying gigabytes the caller did not ask for.
        Log.w(TAG, "no durable grant for $uri; reads after this pick will fail")
    }

    // Only a grant the caller asked for is reported as persisted. Saying true
    // for a session grant would promise a document that survives a restart,
    // and the next process start revokes exactly those.
    val persisted = granted && pending.persistAccess

    val record = JSONObject()
        .put("uri", uri.toString())
        .put("name", name)
        .put("persistedAccess", persisted)
    metadata.second?.let { record.put("size", it) }
    runCatching { resolver.getType(uri) }.getOrNull()
        ?.takeIf { it.isNotBlank() }
        ?.let { record.put("mimeType", it) }

    if (pending.copyToCache) {
        // A content:// URI has no filesystem path, so copyToCache is the only
        // way `path` can be non-null on Android.
        record.put("path", copyToCacheBlocking(context, uri, name))
    }
    return record
}

/**
 * Takes a persistable URI permission and reports whether it actually stuck.
 *
 * The outcome is established by evidence, not by inference:
 *
 *  1. ask for the read grant to be persisted;
 *  2. then confirm the system really lists it in `persistedUriPermissions`.
 *
 * Deliberately NOT gated on `FLAG_GRANT_PERSISTABLE_URI_PERMISSION` appearing in
 * the result Intent's flags. A provider is not obliged to echo the flags that
 * were asked for, so treating a missing flag as a refusal would silently disable
 * persistence against providers that do support it. Asking and then verifying
 * covers both cases without guessing: a provider that refuses throws
 * SecurityException, and one that quietly ignores the request fails the
 * verification.
 *
 * Reporting a persistence that did not happen would be a lie that only surfaces
 * after the user's next app launch, so this returns false unless the grant is
 * genuinely held.
 */
private fun takePersistableAccess(
    resolver: ContentResolver,
    uri: Uri,
): Boolean {
    // Read, and only read, whatever the result intent offered.
    //
    // DocumentsUI hands back FLAG_GRANT_WRITE_URI_PERMISSION as well, and an
    // earlier version persisted whatever came back. `dumpsys activity
    // permissions` on a Galaxy S23 Ultra showed the consequence:
    //
    //     mode=0x3 persistable=0x3 persisted=0x3
    //
    // 0x3 is read plus write. That is more authority than this package has any
    // use for — it offers no write API at all, and SECURITY.md states that
    // documents are opened read-only — and it does not come back off: both
    // release paths give back FLAG_GRANT_READ_URI_PERMISSION, which left the
    // write half persisted forever. Taking only the read grant makes the
    // release symmetric and the authority minimal.
    try {
        resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
    } catch (e: SecurityException) {
        Log.i(TAG, "provider refused persistable access to $uri: ${e.message}")
        return false
    }
    val held = resolver.persistedUriPermissions.any {
        it.uri == uri && it.isReadPermission
    }
    if (!held) Log.i(TAG, "persistable access to $uri did not stick")
    return held
}

/**
 * Reads DISPLAY_NAME and SIZE, tolerating a provider that answers neither.
 *
 * A `DocumentsProvider` is not obliged to return any particular column, so a
 * missing column, a null value and a provider that throws are all normal and
 * none of them may crash the pick. A missing size stays null: "unknown" and
 * "empty" are different facts.
 */
private fun queryMetadata(resolver: ContentResolver, uri: Uri): Pair<String?, Long?> {
    var name: String? = null
    var size: Long? = null
    try {
        resolver.query(uri, null, null, null, null)?.use { cursor: Cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    name = cursor.getString(nameIndex)?.takeIf { it.isNotBlank() }
                }
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    size = cursor.getLong(sizeIndex).takeIf { it >= 0 }
                }
            }
        }
    } catch (e: Exception) {
        // SecurityException, IllegalArgumentException from a provider that has
        // gone away, or anything else a third-party provider chooses to throw.
        Log.i(TAG, "metadata query failed for $uri: ${e.message}")
    }
    return name to size
}

// ─── Read sessions ───────────────────────────────────────────────────────────

/** One open document being streamed to Dart. */
private class ReadSession(val stream: InputStream) {
    fun close() = runCatching { stream.close() }
}

private val readSessions = ConcurrentHashMap<Long, ReadSession>()
private val nextSessionId = AtomicLong(1L)

/** Opens a document for reading. Replies with `{"handle":<id>}`. */
@Keep
fun open(token: Long, uri: String?) {
    val context = appContext
    if (context == null || uri == null) {
        deliverError(token, ERR_READ_FAILED, "The plugin has no context, or no document reference.")
        return
    }
    ioExecutor.execute {
        try {
            val stream = context.contentResolver.openInputStream(Uri.parse(uri))
                ?: throw IOException("the provider returned no stream")
            val id = nextSessionId.getAndIncrement()
            readSessions[id] = ReadSession(BufferedInputStream(stream))
            deliverJson(token, JSONObject().put("handle", id))
        } catch (e: Exception) {
            deliverError(
                token,
                codeFor(e, ERR_READ_FAILED),
                "The document could not be opened for reading.",
                e.javaClass.simpleName,
            )
        }
    }
}

/** Reads up to [chunkSize] bytes. Replies with a chunk, EOF, or an error. */
@Keep
fun readNext(token: Long, handle: Long, chunkSize: Int) {
    val session = readSessions[handle]
    if (session == null) {
        deliverError(token, ERR_READ_FAILED, "The read handle is no longer open.")
        return
    }
    val size = if (chunkSize > 0) chunkSize else 1
    ioExecutor.execute {
        try {
            val buffer = ByteArray(size)
            val read = session.stream.read(buffer)
            if (read <= 0) {
                deliver(token, EVENT_EOF, null)
            } else {
                // Hand over exactly what was read, never the slack.
                val chunk = if (read == size) buffer else buffer.copyOf(read)
                deliver(token, EVENT_CHUNK, chunk)
            }
        } catch (e: Exception) {
            deliverError(
                token,
                codeFor(e, ERR_READ_FAILED),
                "Reading the document failed.",
                e.javaClass.simpleName,
            )
        }
    }
}

/** Closes a read handle. Idempotent. */
@Keep
fun close(handle: Long) {
    readSessions.remove(handle)?.close()
}

// ─── Copy to cache ───────────────────────────────────────────────────────────

/** Streams the document into the cache. Replies with `{"path":"…"}`. */
@Keep
fun copyToCache(token: Long, uri: String?, preferredName: String?) {
    val context = appContext
    if (context == null || uri == null) {
        deliverError(token, ERR_COPY_FAILED, "The plugin has no context, or no document reference.")
        return
    }
    ioExecutor.execute {
        try {
            val path = copyToCacheBlocking(
                context,
                Uri.parse(uri),
                preferredName ?: "document",
            )
            deliverJson(token, JSONObject().put("path", path))
        } catch (e: Exception) {
            deliverError(
                token,
                codeFor(e, ERR_COPY_FAILED),
                "Copying the document into the cache failed.",
                e.javaClass.simpleName,
            )
        }
    }
}

/**
 * Streams [uri] into a fresh cache directory and returns the absolute path.
 *
 * Streamed in 64 KiB blocks so a multi-gigabyte document copies in constant
 * memory. A failure deletes the partial copy and its directory, so a truncated
 * file is never returned. Must not be called on the main thread.
 */
private fun copyToCacheBlocking(context: Context, uri: Uri, preferredName: String): String {
    // A directory per copy: two documents sharing a display name cannot
    // collide, and the user-visible filename survives intact.
    val directory = File(File(context.cacheDir, CACHE_SUBDIR), UUID.randomUUID().toString())
    if (!directory.mkdirs() && !directory.isDirectory) {
        throw IOException("could not create the cache directory")
    }
    val destination = File(directory, sanitizeFilename(preferredName))

    // Belt and braces against traversal: the sanitized name cannot contain a
    // separator, and this proves the result really is inside the directory.
    if (destination.canonicalPath != File(directory, destination.name).canonicalPath ||
        !destination.canonicalPath.startsWith(directory.canonicalPath + File.separator)
    ) {
        directory.deleteRecursively()
        throw IOException("the destination filename escaped the cache directory")
    }

    try {
        val input = context.contentResolver.openInputStream(uri)
            ?: throw IOException("the provider returned no stream")
        input.use { source ->
            destination.outputStream().use { sink ->
                source.copyTo(sink, DEFAULT_COPY_BUFFER)
                sink.flush()
            }
        }
    } catch (e: Exception) {
        directory.deleteRecursively()
        throw e
    }
    return destination.absolutePath
}

private const val DEFAULT_COPY_BUFFER = 64 * 1024

/**
 * Strips everything from [name] that could escape the destination directory.
 *
 * Path separators, `..`, control characters and leading dots go; the result is
 * capped at 200 bytes (the filesystem limit is 255, and multi-byte names reach
 * it sooner than they look) while keeping the extension, because consumers sniff
 * it. An empty result becomes "document".
 */
internal fun sanitizeFilename(name: String): String {
    val base = name.substringAfterLast('/').substringAfterLast('\\')
    var cleaned = base
        .filter { it.isLetterOrDigit() || it in ".-_ " }
        .replace("..", ".")
        .trim()
    while (cleaned.startsWith(".")) cleaned = cleaned.removePrefix(".")
    if (cleaned.isEmpty()) return "document"

    val maxBytes = 200
    if (cleaned.toByteArray(Charsets.UTF_8).size <= maxBytes) return cleaned
    val extension = cleaned.substringAfterLast('.', "")
    var stem = if (extension.isEmpty()) cleaned else cleaned.substringBeforeLast('.')
    while (
        stem.isNotEmpty() &&
        stem.toByteArray(Charsets.UTF_8).size +
        extension.toByteArray(Charsets.UTF_8).size + 1 > maxBytes
    ) {
        stem = stem.dropLast(1)
    }
    if (stem.isEmpty()) stem = "document"
    return if (extension.isEmpty()) stem else "$stem.$extension"
}

// ─── Persisted access ────────────────────────────────────────────────────────

/** Releases a persisted URI grant. Replies with `{"released":true|false}`. */
@Keep
fun release(token: Long, uri: String?) {
    val context = appContext
    if (context == null || uri == null) {
        deliverError(token, ERR_PERSISTENCE_FAILED, "No context, or no document reference.")
        return
    }
    val target = Uri.parse(uri)
    val resolver = context.contentResolver
    val held = resolver.persistedUriPermissions.firstOrNull { it.uri == target }
    if (held == null) {
        // Nothing to give back. Reporting true keeps releasing idempotent.
        SessionGrants.forget(context, target)
        deliverJson(token, JSONObject().put("released", true))
        return
    }
    try {
        resolver.releasePersistableUriPermission(
            target,
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
        )
        // Drop it from both ledgers: the grant is gone, so a later sweep
        // trying to release it again would only log a failure.
        SessionGrants.forget(context, target)
        deliverJson(token, JSONObject().put("released", true))
    } catch (e: SecurityException) {
        Log.w(TAG, "releasePersistableUriPermission failed: ${e.message}")
        deliverJson(token, JSONObject().put("released", false))
    }
}

/**
 * Resolves a previously persisted document. Replies with `{"files":[…]}`, an
 * empty list when the grant is gone or the document has disappeared.
 */
@Keep
fun resolve(token: Long, uri: String?) {
    val context = appContext
    if (context == null || uri == null) {
        deliverCancelled(token)
        return
    }
    val target = Uri.parse(uri)
    ioExecutor.execute {
        val resolver = context.contentResolver
        val held = resolver.persistedUriPermissions.any { it.uri == target && it.isReadPermission }
        // Holding the grant is not the same as having been asked to hold it.
        // Reference mode takes a grant for every picked document, so the
        // permission list alone would let openPersisted resolve a document the
        // caller never asked to persist — and that grant is revoked at the next
        // process start, making the success a one-session illusion.
        if (!held || !SessionGrants.isOwned(context, target)) {
            deliverCancelled(token)
            return@execute
        }
        // A held grant does not prove the document still exists.
        val metadata = queryMetadata(resolver, target)
        val reachable = try {
            resolver.openInputStream(target)?.use { true } ?: false
        } catch (e: Exception) {
            Log.i(TAG, "persisted document is no longer reachable: ${e.message}")
            false
        }
        if (!reachable) {
            deliverCancelled(token)
            return@execute
        }
        val record = JSONObject()
            .put("uri", target.toString())
            .put("name", metadata.first ?: target.lastPathSegment ?: "document")
            .put("persistedAccess", true)
        metadata.second?.let { record.put("size", it) }
        runCatching { resolver.getType(target) }.getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?.let { record.put("mimeType", it) }
        deliverJson(token, JSONObject().put("files", JSONArray().put(record)))
    }
}

// ─── Reset ───────────────────────────────────────────────────────────────────

/**
 * Clears state left behind by a previous Dart isolate (hot restart).
 *
 * Native code is not restarted with Dart: read streams stay open and a pick can
 * still be outstanding. Dart calls this from `loadSymbols()` before handing over
 * a new dispatcher.
 */
@Keep
fun reset() {
    for (session in readSessions.values) session.close()
    readSessions.clear()
    pendingPicks.clear()
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

private fun JSONArray?.toStringList(): List<String> {
    if (this == null) return emptyList()
    val result = ArrayList<String>(length())
    for (i in 0 until length()) {
        optString(i).takeIf { it.isNotBlank() }?.let { result.add(it) }
    }
    return result
}
