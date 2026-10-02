/// Options that shape how a picked document may be accessed afterwards.
library;

/// How the plugin takes hold of the document the user picked.
///
/// This is the single most consequential option, because it decides whether
/// [PlatformFile.path] can exist at all.
enum FilePickerAccessMode {
  /// Keep the provider's own resource reference. The default.
  ///
  /// Nothing is copied and nothing is read at pick time, so picking a 4 GB
  /// video costs the same as picking a 2 KB note. [PlatformFile.uri] is the
  /// document's identity; [PlatformFile.path] is `null` unless the provider
  /// genuinely exposes a readable file.
  ///
  /// Read the bytes with [PlatformFile.readAsBytes] or
  /// [PlatformFile.readAsByteStream], or materialize a real file later with
  /// [PlatformFile.copyToCache].
  ///
  /// Lifetime: the reference stays usable for as long as your app keeps
  /// running, and no longer. Set [FilePickerOptions.persistAccess] to keep it
  /// across restarts.
  ///
  /// How that lifetime is achieved differs by platform, and on Android it has a
  /// consequence worth knowing about:
  ///
  /// - **iOS**: the picked URL is retained by the plugin and read inside a
  ///   security-scoped access, so nothing leaves the process.
  /// - **Android**: a URI grant delivered in an activity result is owned by the
  ///   activity that received it and is revoked when that activity goes away.
  ///   The picker runs in this plugin's own short-lived activity, so the only
  ///   mechanism Android offers for reading the document afterwards is a
  ///   *persistable* grant, and the plugin takes one. It is released again
  ///   automatically: the next time your app's process starts, and when the
  ///   engine detaches. Until then the grant is visible in the system's list of
  ///   files your app has access to, which is why [PlatformFile.persistedAccess] still
  ///   reports `false` for it — it is the plugin's bookkeeping, not a promise to
  ///   you. Only [FilePickerOptions.persistAccess] makes that promise, and only
  ///   then does [FilePicker.openPersisted] resolve the document.
  ///
  /// If you need neither the grant nor the wait, [copyToCache] takes a copy
  /// during the pick and needs no grant at all.
  reference,

  /// Copy the document into this app's cache directory during the pick.
  ///
  /// [PlatformFile.path] is then always non-null and points at a file this app
  /// owns outright, which is what a native library taking a `char*` path
  /// needs.
  ///
  /// **What [PlatformFile.uri] refers to differs by platform in this mode**, and
  /// the difference is forced by the OS rather than chosen here:
  ///
  /// - **Android**: the original `content://` document. The provider URI stays
  ///   valid and readable, so it is still the document's identity.
  /// - **iOS**: the app-owned copy. The system's `asCopy: true` picker hands back
  ///   *only* the copy's URL and never reveals the original document's, so there
  ///   is nothing else that could truthfully be reported.
  ///
  /// In this mode use [PlatformFile.path], which is non-null on both platforms
  /// and points at the same bytes. Treat [PlatformFile.uri] as "a readable
  /// reference", not as a stable cross-platform identity, and do not persist it
  /// expecting to reopen the original later — that is what
  /// [FilePickerAccessMode.reference] with [persistAccess] is for.
  ///
  /// The cost is real: the whole document is streamed to disk before the
  /// [Future] completes, so a large cloud file means a wait and the disk space
  /// to hold it. Prefer [reference] unless you actually need a path.
  ///
  /// On iOS this is the picker's own `asCopy: true` mode, so the copy is made
  /// by the system. On Android the bytes are streamed through the
  /// `ContentResolver`.
  copyToCache,
}

/// Fine-grained control over a pick.
///
/// The defaults are the cheap, safe ones: reference the document, persist
/// nothing, allow cloud providers.
///
/// ```dart
/// final file = await FilePicker.pickFile(
///   options: const FilePickerOptions(
///     accessMode: FilePickerAccessMode.copyToCache,
///   ),
/// );
/// // file.path is non-null here.
/// ```
final class FilePickerOptions {
  /// Creates an option set; every field has a documented default.
  const FilePickerOptions({
    this.accessMode = FilePickerAccessMode.reference,
    this.persistAccess = false,
    this.localOnly = false,
  });

  /// Whether to reference the document or copy it into the cache.
  ///
  /// Defaults to [FilePickerAccessMode.reference].
  final FilePickerAccessMode accessMode;

  /// Whether to keep access to the document across app restarts.
  ///
  /// Defaults to `false`, which is what the overwhelming majority of pickers
  /// want: read the file now, forget it afterwards.
  ///
  /// Set it to `true` only for a document your app keeps referring to — a
  /// chosen export target, a watched spreadsheet. The mechanism differs by
  /// platform and the difference is visible to you:
  ///
  /// - **Android** calls `ContentResolver.takePersistableUriPermission` and then
  ///   confirms the grant really appears in
  ///   `ContentResolver.persistedUriPermissions`, rather than trusting the
  ///   flags echoed back in the result intent, which a provider is not obliged
  ///   to set. A provider that refuses leaves
  ///   [PlatformFile.persistedAccess] `false`; the pick still succeeds.
  ///
  ///   What this flag changes on Android is *ownership*, not whether a grant is
  ///   taken: [FilePickerAccessMode.reference] always takes one, because the
  ///   transient grant in an activity result does not outlive the picker's
  ///   activity. With `persistAccess: false` the grant belongs to the plugin
  ///   and is released at the next process start; with `true` it belongs to
  ///   you and is released only by [PlatformFile.releasePersistedAccess].
  ///   Android caps an app at 512 persisted grants and silently releases the
  ///   oldest beyond that, so release the ones you stop using.
  /// - **iOS** creates a security-scoped bookmark and stores it in the host
  ///   app's `UserDefaults.standard`, in a `[String: Data]` dictionary under the
  ///   key `dartnative_file_picker.bookmarks`, keyed by the document's URI
  ///   string. Nothing on iOS holds the grant for you, so this package has to
  ///   hold it somewhere, and that is where. It survives launches and updates,
  ///   goes away with the app, and is included in device backups (a bookmark
  ///   restored onto another device simply fails to resolve).
  ///   [PlatformFile.releasePersistedAccess] deletes that entry, so releasing is
  ///   a real release. A moved document is recovered through the bookmark's
  ///   staleness handling; a deleted one is not recoverable.
  ///
  /// Always check [PlatformFile.persistedAccess] on the result instead of
  /// assuming the request was honoured, and call
  /// [PlatformFile.releasePersistedAccess] when you are finished with the
  /// document.
  ///
  /// Persistence applies to referenced documents only. Combined with
  /// [FilePickerAccessMode.copyToCache] it is ignored and
  /// [PlatformFile.persistedAccess] reports `false`, because a copy in your own
  /// cache needs no grant to be readable later.
  ///
  /// Store [PlatformFile.uri] yourself and pass it to
  /// [FilePicker.openPersisted] on a later launch. Without the URI there is
  /// nothing to reopen.
  final bool persistAccess;

  /// Whether to hide documents that are not already on the device.
  ///
  /// Defaults to `false`.
  ///
  /// - **Android**: sets `Intent.EXTRA_LOCAL_ONLY`, so cloud-backed providers
  ///   are excluded from the picker.
  /// - **iOS**: **ignored**. `UIDocumentPickerViewController` has no
  ///   equivalent, and this package does not fake one by filtering the result
  ///   after the fact — that would silently discard a file the user
  ///   deliberately chose. If your app cannot handle a download, set
  ///   [accessMode] to [FilePickerAccessMode.copyToCache], which forces the
  ///   bytes to be materialized before the [Future] completes.
  final bool localOnly;

  @override
  String toString() =>
      'FilePickerOptions(accessMode: ${accessMode.name}, '
      'persistAccess: $persistAccess, localOnly: $localOnly)';
}
