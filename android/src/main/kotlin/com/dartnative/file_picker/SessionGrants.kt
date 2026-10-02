// SessionGrants.kt
// The ledger that makes AccessMode.reference truthful on Android.
//
// Why this file exists at all
// ---------------------------
// A URI grant that arrives in an activity result is owned by the activity that
// received it. AOSP is explicit about the lifetime:
//
//     // ActivityRecord.removeFromHistory()
//     cleanUpActivityServices();
//     removeUriPermissionsLocked();   // uriPermissions.removeUriPermissions()
//
// FilePickerProxyActivity delivers the result and finishes immediately, so the
// transient grant is revoked milliseconds later. Every later read of the picked
// content:// URI then fails with SecurityException. That was finding F9 on a
// physical Galaxy S23 Ultra (Android 16): reads failed for a local Downloads
// document and for a Drive document alike, while persistAccess: true worked.
//
// The Flutter ecosystem avoids the problem by never handing out a bare URI:
// file_selector_android and image_picker_android copy the bytes into the app
// cache inside the grant window, and file_picker does the same by default. Its
// public API spells the constraint out:
//
//     enum AndroidSAFGrant {
//       /// Grant permission to the requested URI for the current request only.
//       transient,
//       /// Grant permission to the requested URI, until permission is
//       /// explicitly revoked.
//       lifetime,
//     }
//
// Neither of those is acceptable here: copying at pick time is exactly what this
// package exists to avoid, because it turns picking a 4 GB video into a 4 GB
// disk write. Android offers only one other sanctioned way to keep a URI
// readable past the receiving activity, and that is a persistable grant.
//
// So reference mode takes one, and this ledger owns its lifetime:
//
//  * persistAccess: true  -> the grant belongs to the caller. Recorded as
//    OWNED, released only by release(). This is what openPersisted() resolves.
//  * persistAccess: false -> the grant belongs to this app session. Recorded as
//    SESSION, and released when the process next starts, when the engine
//    detaches, or when the ledger reaches [MAX_SESSION_GRANTS].
//
// The sweep on process start is the part that makes the documented promise
// ("set persistAccess to keep it across restarts") literally true: a
// session-scoped grant cannot survive a restart, because the first thing the
// plugin does on attach is give it back.
//
// Budget
// ------
// Persisted grants are a finite, per-package resource. AOSP:
//
//     private static final int MAX_PERSISTED_URI_GRANTS = 512;
//     // maybePrunePersistedUriGrantsLocked() sorts by PersistedTimeComparator
//     // and releases the oldest until the count is under the limit.
//
// The OS prunes oldest-first and silently, which would break a reference the
// caller still holds. [MAX_SESSION_GRANTS] stays well under that limit and the
// eviction happens here instead, oldest first, so it is ours, bounded and
// logged rather than invisible.

package com.dartnative.file_picker

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray

/**
 * Tracks which persisted URI grants this plugin took, and on whose behalf.
 *
 * Two ledgers, kept in one `SharedPreferences` file:
 *
 *  * **session** — taken so that `AccessMode.reference` can be read after the
 *    pick. Insertion-ordered, because eviction is oldest-first.
 *  * **owned** — taken because the caller asked for `persistAccess: true`.
 *    Never swept, and the only thing `openPersisted` will resolve.
 *
 * Both are stored as JSON arrays rather than `StringSet`, because a set has no
 * order and the eviction policy needs one.
 *
 * All mutation is serialized on [executor]: the methods are called from the I/O
 * pool during a pick and from the main thread on engine attach, and
 * `releasePersistableUriPermission` is a binder call that has no business on
 * the main thread in a framework where the main thread also runs Dart.
 */
internal object SessionGrants {

    private const val PREFS = "dn_file_picker_grants"
    private const val KEY_SESSION = "session"
    private const val KEY_OWNED = "owned"

    /**
     * How many session-scoped grants to hold before evicting the oldest.
     *
     * Deliberately far below AOSP's `MAX_PERSISTED_URI_GRANTS` (512), which is a
     * whole-package budget shared with every grant the host app took for its
     * own reasons. Leaving headroom means the OS pruner never gets to pick a
     * victim for us.
     */
    private const val MAX_SESSION_GRANTS = 256

    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "dn-file-picker-grants").apply { isDaemon = true }
    }

    /** Guards the process-start sweep so a second engine attach cannot re-run it. */
    private val swept = AtomicBoolean(false)

    /**
     * Releases every session-scoped grant left over from a previous process.
     *
     * Called once per process from `onAttachedToEngine`. A second
     * `FlutterEngine` attaching later in the same process must not run this: by
     * then the ledger holds grants that live Dart objects are still using.
     */
    fun sweepOnce(context: Context) {
        if (!swept.compareAndSet(false, true)) return
        releaseSessionGrants(context, "process start")
    }

    /** Releases every session-scoped grant. Called when the engine detaches. */
    fun releaseAll(context: Context) = releaseSessionGrants(context, "engine detach")

    /**
     * Records a grant taken so a referenced document stays readable this session.
     *
     * A URI already in the **owned** ledger is left alone: the caller asked for
     * that grant to be durable in an earlier pick, and demoting it here would
     * have the next process start revoke something they still own.
     */
    fun registerSession(context: Context, uri: Uri) = executor.execute {
        val key = uri.toString()
        if (read(context, KEY_OWNED).contains(key)) return@execute

        val session = read(context, KEY_SESSION)
        session.remove(key)
        session.add(key)

        val resolver = context.contentResolver
        while (session.size > MAX_SESSION_GRANTS) {
            val oldest = session.removeAt(0)
            Log.i(TAG, "session grant budget reached, releasing $oldest")
            releaseQuietly(resolver, oldest)
        }
        write(context, KEY_SESSION, session)
    }

    /**
     * Promotes a grant to caller-owned, which is what `persistAccess: true` means.
     *
     * Also drops it from the session ledger, so the next process start does not
     * revoke a grant the caller expects to find waiting for them.
     */
    fun registerOwned(context: Context, uri: Uri) = executor.execute {
        val key = uri.toString()
        val session = read(context, KEY_SESSION)
        if (session.remove(key)) write(context, KEY_SESSION, session)

        val owned = read(context, KEY_OWNED)
        if (!owned.contains(key)) {
            owned.add(key)
            write(context, KEY_OWNED, owned)
        }
    }

    /** Drops [uri] from both ledgers, after the grant itself has been released. */
    fun forget(context: Context, uri: Uri) = executor.execute {
        val key = uri.toString()
        for (ledger in arrayOf(KEY_SESSION, KEY_OWNED)) {
            val entries = read(context, ledger)
            if (entries.remove(key)) write(context, ledger, entries)
        }
    }

    /**
     * Whether the caller asked for [uri] to be persisted.
     *
     * `openPersisted` is gated on this rather than on
     * `persistedUriPermissions` alone. Holding the grant is not the same as
     * having been asked to hold it: reference mode takes a grant for every
     * picked document, and resolving those would report a persistence the
     * caller never requested and that the next process start will revoke.
     *
     * Reads the ledger directly instead of going through [executor], because
     * callers need the answer rather than a future. The underlying
     * `SharedPreferences` read is already thread-safe.
     */
    fun isOwned(context: Context, uri: Uri): Boolean =
        read(context, KEY_OWNED).contains(uri.toString())

    // ─── Internals ───────────────────────────────────────────────────────────

    private fun releaseSessionGrants(context: Context, reason: String) = executor.execute {
        val session = read(context, KEY_SESSION)
        if (session.isEmpty()) return@execute
        Log.i(TAG, "releasing ${session.size} session grant(s) on $reason")
        val resolver = context.contentResolver
        for (entry in session) releaseQuietly(resolver, entry)
        write(context, KEY_SESSION, mutableListOf())
    }

    /**
     * Gives a grant back, tolerating every way that can fail.
     *
     * A grant can already be gone: the provider was uninstalled, the user
     * cleared the app's data, or the OS pruner got there first. None of that is
     * worth failing an engine attach over, so it is logged and dropped.
     */
    private fun releaseQuietly(resolver: android.content.ContentResolver, uri: String) {
        try {
            resolver.releasePersistableUriPermission(
                Uri.parse(uri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            Log.i(TAG, "session grant for $uri was already gone: ${e.message}")
        } catch (e: IllegalArgumentException) {
            Log.i(TAG, "session grant for $uri is no longer parseable: ${e.message}")
        }
    }

    private fun read(context: Context, key: String): MutableList<String> {
        val raw = context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(key, null)
            ?: return mutableListOf()
        return try {
            val array = JSONArray(raw)
            MutableList(array.length()) { array.getString(it) }
        } catch (e: org.json.JSONException) {
            // Corrupt ledger. Losing it costs at most one sweep; keeping it
            // would break every pick from here on.
            Log.w(TAG, "grant ledger '$key' was unreadable, discarding it: ${e.message}")
            mutableListOf()
        }
    }

    private fun write(context: Context, key: String, entries: List<String>) {
        context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(key, JSONArray(entries).toString())
            .apply()
    }
}
