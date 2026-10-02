/// The immutable result model for a picked document.
library;

import 'dart:typed_data';

import 'exceptions.dart';
import 'filters/selection_filter.dart';
import 'native/native_codec.dart';
import 'native/resource_gateway.dart';

/// The default read granularity, 1 MiB.
///
/// Chosen from measurement, not taste. Every chunk costs one asynchronous
/// native-to-Dart delivery, and that round trip is the bottleneck on **both**
/// platforms, independent of chunk size: it measured ~35 ms per chunk on a
/// physical iPhone 15 Pro Max (iOS 26.6) and ~43 ms on an Android 14 emulator,
/// for a local app-owned file as much as for a provider's document. Throughput
/// is therefore latency-bound at roughly `chunkSize / 40 ms`:
///
/// | chunk | iOS | Android |
/// |---|---|---|
/// | 32 KiB | 0.63 MB/s (measured) | — |
/// | 64 KiB | ~1.3 MB/s | ~1.5 MB/s |
/// | **1 MiB** | **28.7 MB/s (measured)** | **23.3 MB/s (measured)** |
///
/// 64 KiB was the original default and is memory-optimal, but it made a 600 MB
/// document take about sixteen minutes, which is not a usable API. 1 MiB keeps
/// peak memory per chunk trivial while making a large read practical: the same
/// 600 MB document streamed in 20.9 s on iOS and 25.8 s on Android, in 600
/// chunks, with no chunk exceeding 1 MiB.
///
/// Raise it further for throughput on a big document, or lower it when you want
/// finer progress reporting and the file is small. For a multi-gigabyte document
/// where you only need the bytes on disk, [PlatformFile.copyToCache] is faster
/// still: the copy happens entirely in native code with no per-chunk round trip
/// at all.
const int defaultChunkSize = 1024 * 1024;

/// A document the user picked.
///
/// Immutable. Every field is a fact recorded at pick time; the methods are the
/// operations that reach back to the platform.
///
/// ## The important thing to understand
///
/// [uri] is the document's identity; [path] usually is not, and is frequently
/// `null`. Android's Storage Access Framework hands back a `content://` URI
/// owned by a provider that may be Google Drive, Dropbox, or a network share,
/// and no filesystem path exists for those. iOS documents may live in another
/// app's container or in iCloud. This package will not invent a path that does
/// not exist.
///
/// If you need a real file — to hand to a native library, or to upload with a
/// tool that only speaks paths — call [copyToCache], or pick with
/// [FilePickerAccessMode.copyToCache] in the first place.
///
/// ## Lifetime
///
/// A picked document is readable while the grant that produced it lasts:
///
/// - for a normal pick, for as long as the app keeps running;
/// - across restarts only when [persistedAccess] is `true`;
/// - never after [releasePersistedAccess], or after the provider revokes the
///   grant, or after the user deletes the document.
///
/// All of those surface as a [FilePickerException] with
/// [FilePickerErrorCode.accessDenied], [FilePickerErrorCode.providerUnavailable]
/// or [FilePickerErrorCode.readFailed] from the method you call — never as
/// silently empty bytes.
final class PlatformFile {
  /// Creates a document reference.
  ///
  /// Apps receive instances from [FilePicker]; this constructor is public so
  /// that tests and fakes can build one. [gateway] is the platform
  /// implementation the methods call into.
  PlatformFile({
    required this.name,
    required this.uri,
    required this.persistedAccess,
    required FileResourceGateway gateway,
    this.path,
    this.mimeType,
    this.size,
  }) : _gateway = gateway;

  /// Builds a document from a decoded native record.
  PlatformFile.fromRecord(NativeFileRecord record, FileResourceGateway gateway)
    : this(
        name: record.name,
        uri: record.uri,
        persistedAccess: record.persistedAccess,
        gateway: gateway,
        path: record.path,
        mimeType: record.mimeType,
        size: record.size,
      );

  final FileResourceGateway _gateway;

  /// The document's display name, including its extension when it has one.
  ///
  /// Never empty: a provider that reports no name falls back to the URI's last
  /// segment, then to `'document'`. May contain spaces, non-ASCII characters and
  /// right-to-left text, and is **not** safe to use as a filesystem path — it is
  /// what the user sees, not where the bytes are. [copyToCache] sanitizes it
  /// before writing.
  final String name;

  /// The canonical reference to the document. The real identity of this file.
  ///
  /// - **Android**: a `content://` URI belonging to a `DocumentsProvider`.
  /// - **iOS**: a `file://` URL, which may point outside this app's container
  ///   and may therefore require a security-scoped resource to read. The
  ///   methods on this class handle that for you.
  final Uri uri;

  /// A real local filesystem path, or `null` when none exists.
  ///
  /// Non-null **only** when the bytes genuinely sit at a path this app can open:
  /// after a [FilePickerAccessMode.copyToCache] pick, or when the picked
  /// document was already a readable file in this app's own container.
  ///
  /// A `null` value is the normal case for cloud and cross-app documents, and it
  /// does not mean the document cannot be read — [readAsBytes] and
  /// [readAsByteStream] work either way.
  ///
  /// This field is not updated by a later [copyToCache] call, because this class
  /// is immutable; use that method's return value.
  final String? path;

  /// The MIME type the provider reported, or `null` when it reported none.
  ///
  /// Provider-supplied and therefore **not** trustworthy for a security
  /// decision: a provider may report `application/pdf` for anything at all.
  /// Validate content before acting on it.
  final String? mimeType;

  /// The size in bytes, or `null` when the provider did not report one.
  ///
  /// `null` means "unknown", which is a normal answer from a cloud provider; it
  /// is deliberately not conflated with `0`, which means "a genuinely empty
  /// document". Treat `null` as "show an indeterminate progress indicator".
  final int? size;

  /// Whether access to this document survives an app restart.
  ///
  /// `true` only when persistence was requested *and* the platform granted it —
  /// an Android provider may refuse, in which case the pick still succeeds with
  /// this set to `false`. Check it rather than assuming.
  final bool persistedAccess;

  /// The lowercase extension derived from [name], or `null` when it has none.
  ///
  /// Derived from the name's last dot, so `Q3.Final.XLSX` gives `xlsx`. A
  /// dotfile such as `.gitignore` has no extension and gives `null`, as does a
  /// name with no dot at all. Comes from the filename, never from [mimeType].
  ///
  /// This is the same derivation [FilePicker] enforces `allowedExtensions`
  /// against, so for a `FileType.custom` pick this value is guaranteed to be one
  /// of the extensions you asked for.
  String? get extension => extensionOfName(name);

  /// Reads the whole document into memory.
  ///
  /// Convenience for documents you know are small — a config file, a modest
  /// image. It streams internally and accumulates, so peak memory is the
  /// document size plus one chunk, but that is still the whole document in RAM:
  /// a 2 GB video will exhaust the process. For anything whose size you do not
  /// control, use [readAsByteStream].
  ///
  /// Throws [FilePickerException] with [FilePickerErrorCode.readFailed],
  /// [FilePickerErrorCode.accessDenied] or
  /// [FilePickerErrorCode.providerUnavailable].
  Future<Uint8List> readAsBytes({int chunkSize = defaultChunkSize}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in readAsByteStream(chunkSize: chunkSize)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Streams the document's bytes without holding it all in memory.
  ///
  /// The correct way to read a document of unknown size: hash it, upload it, or
  /// write it somewhere, a chunk at a time.
  ///
  /// ```dart
  /// final sink = File(target).openWrite();
  /// await file.readAsByteStream().pipe(sink);
  /// ```
  ///
  /// Guarantees:
  ///
  /// - nothing is read until the stream is listened to;
  /// - no chunk is larger than [chunkSize], though any chunk may be smaller;
  /// - the native read handle and any iOS security-scoped access are released
  ///   when the stream ends, is cancelled, or fails;
  /// - the native side never buffers the whole document first — each chunk is
  ///   read on demand on a background thread and handed over as it arrives, so
  ///   a slow consumer slows the reading rather than filling memory.
  ///
  /// A zero-byte document yields no chunks and simply closes.
  ///
  /// Throws [FilePickerException] with [FilePickerErrorCode.invalidFilter] if
  /// [chunkSize] is not positive — synchronously, before any listen.
  Stream<Uint8List> readAsByteStream({int chunkSize = defaultChunkSize}) {
    if (chunkSize <= 0) {
      throw FilePickerException(
        FilePickerErrorCode.invalidFilter,
        'chunkSize must be greater than zero (got $chunkSize).',
      );
    }
    return _gateway.openRead(uri, chunkSize: chunkSize);
  }

  /// Copies the document into this app's cache directory and returns its path.
  ///
  /// For when a path is unavoidable. The copy:
  ///
  /// - is streamed, so a multi-gigabyte document does not pass through memory;
  /// - lands in a unique subdirectory, so two documents with the same name
  ///   cannot collide;
  /// - keeps [extension] when there is one, so extension-sniffing consumers
  ///   still work;
  /// - has its filename sanitized — path separators, `..` and control
  ///   characters cannot escape the destination directory;
  /// - is deleted if the copy fails partway, so a truncated file is never
  ///   returned;
  /// - exists and is complete by the time this [Future] completes.
  ///
  /// The result lives in the OS cache directory, which means **the system may
  /// delete it** when storage runs low, and this package never deletes it for
  /// you. Move it somewhere you own if you need to keep it.
  ///
  /// Calling this twice produces two independent copies.
  ///
  /// Throws [FilePickerException] with [FilePickerErrorCode.copyFailed], or
  /// [FilePickerErrorCode.accessDenied] / [FilePickerErrorCode.readFailed] if
  /// the source could not be read.
  Future<String> copyToCache() =>
      _gateway.copyToCache(uri, preferredName: name);

  /// Gives up persisted access to this document.
  ///
  /// Call it when your app no longer needs a document it persisted: Android
  /// caps how many persisted URI grants one app may hold, so keeping dead ones
  /// eventually costs you a live one. After this call the document is no longer
  /// readable in a later app session, and reading it in *this* session may fail
  /// too.
  ///
  /// A no-op when [persistedAccess] is `false`, so it is safe to call
  /// unconditionally during cleanup.
  ///
  /// Throws [FilePickerException] with
  /// [FilePickerErrorCode.persistenceFailed] when the platform refused.
  Future<void> releasePersistedAccess() async {
    if (!persistedAccess) return;
    final released = await _gateway.releasePersistedAccess(uri);
    if (!released) {
      throw FilePickerException(
        FilePickerErrorCode.persistenceFailed,
        'The platform did not release persisted access to $uri.',
      );
    }
  }

  @override
  String toString() =>
      'PlatformFile($name, uri: $uri, size: ${size ?? 'unknown'}, '
      'mimeType: ${mimeType ?? 'unknown'}, path: ${path ?? 'none'}, '
      'persistedAccess: $persistedAccess)';
}
