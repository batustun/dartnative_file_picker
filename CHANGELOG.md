# Changelog

## 0.1.0

First release. Document picking on iOS and Android over FFI, with no Flutter
platform channels.

### Picking

- `FilePicker.pickFile()` for a single document, returning `null` on cancel.
- `FilePicker.pickFiles()` for several, returning `[]` on cancel.
- `FileType.any`, `.image`, `.video`, `.audio` and `.custom`.
- `allowedExtensions` for `FileType.custom`, normalized (lowercased, dots
  stripped, de-duplicated) and validated before the picker is presented.
- `allowedExtensions` is **enforced after selection**, against each document's
  filename, not merely passed to the picker as a filter. A platform picker's
  filter is a hint: Android widens to a wildcard for an extension with no known
  MIME type, and provider MIME types are unreliable even when it does not.
  Documents outside the list are dropped, and a selection with nothing valid left
  raises `unsupportedType` naming what was picked. So every
  `PlatformFile.extension` from a `custom` pick is one that was asked for, on both
  platforms and against every provider.
- One picker at a time: a concurrent call fails immediately with
  `FilePickerErrorCode.pickerBusy`, and the guard is released on every outcome.

### Reading

- `PlatformFile.readAsByteStream({chunkSize})`, chunked and lazily opened, with
  no whole-document buffering on either side.
- The default `chunkSize` is **1 MiB**, chosen from measurement rather than taste.
  Each chunk costs one asynchronous native-to-Dart delivery, measured at ~35 ms per
  chunk on an iPhone 15 Pro Max and ~43 ms on an Android 14 emulator regardless of
  chunk size, so throughput is latency-bound. The same 600 MB document streams in
  20.9 s on iOS and 25.8 s on Android; at the originally chosen 64 KiB it would
  have taken about sixteen minutes. For a document you only need on disk,
  `copyToCache()` is faster still, with no per-chunk round trip at all.
- `PlatformFile.readAsBytes()` for documents known to be small.
- `PlatformFile.copyToCache()`: streamed, collision-safe, filename sanitized,
  partial copies deleted on failure.
- `FilePickerAccessMode.copyToCache` to copy during the pick, which uses the iOS
  picker's own `asCopy` mode. In that mode `PlatformFile.path` is guaranteed
  non-null: a file returned without one is treated as a native contract violation
  and raises `copyFailed`, rather than handing the caller a `null` to check.

### Persisted access

- `FilePickerOptions.persistAccess`: `takePersistableUriPermission` on Android,
  taking the **read** grant only and verified against `persistedUriPermissions`
  rather than trusting the flags a provider echoes back. DocumentsUI also offers
  write, which this package has no use for and could not fully release, since
  the release call names read; a security-scoped bookmark on iOS. On Android the flag
  decides who *owns* the grant, not whether one is taken: see the reference-mode
  entry under Platform native.
- `FilePicker.openPersisted(uri)` to reopen a document in a later session,
  returning `null` when the grant or the document is gone. On iOS the bookmark is
  stored in the host app's `UserDefaults.standard` under
  `dartnative_file_picker.bookmarks`, keyed by the document's URI, and
  `releasePersistedAccess()` deletes that entry. The README documents the lifetime
  in full, including backup behaviour.
- `persistAccess` is ignored when combined with
  `FilePickerAccessMode.copyToCache`, and reports `persistedAccess == false`: a
  copy in the app's own cache needs no grant.
- `PlatformFile.releasePersistedAccess()`, a no-op when nothing was persisted.

### Platform native

- iOS: `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)` with
  `UTType` content types, presented in a dedicated `UIWindow` on the active
  `UIWindowScene`. Security-scoped access is acquired per operation and always
  released. Reads are coordinated with `NSFileCoordinator`, so an iCloud document
  that is not on the device yet is materialized first.
- Android: the MIME filter offers each extension's registered type **plus the
  legacy spellings providers actually use**. MediaStore indexes a `.csv` as
  `text/comma-separated-values`, so a filter carrying only `text/csv` hid every
  CSV from the picker. Widening is safe because enforcement works on the filename:
  a surplus type costs one extra row, a missing one costs the user their file.
- Android: `Intent.ACTION_OPEN_DOCUMENT` with `CATEGORY_OPENABLE`,
  `EXTRA_ALLOW_MULTIPLE`, `EXTRA_MIME_TYPES` and `EXTRA_LOCAL_ONLY`. Results are
  read from both `Intent.data` and `ClipData`. Metadata comes from
  `OpenableColumns` and `ContentResolver.getType`, with every column treated as
  optional.
- Android results arrive through a transparent proxy activity owned by this
  plugin, because DartNative exposes no Activity-result hook. It is
  `exported="false"`, and refuses to start any forwarded intent whose action is
  not `ACTION_OPEN_DOCUMENT`, so it cannot be turned into a way to launch
  arbitrary intents with the app's identity. It deliberately keeps the app's
  **default task affinity**, so the picker returns the user to their own task
  rather than to an empty one.
- Android: `FilePickerAccessMode.reference` takes a persistable URI grant during
  the pick, and the plugin owns its lifetime. This is not an optimization but the
  only mechanism Android offers: a URI permission delivered in an activity result
  is owned by the receiving activity and revoked by
  `ActivityRecord.removeFromHistory()`, and this plugin's proxy activity finishes
  the moment it has the result. Without the grant, every post-pick read failed
  with `SecurityException` on a physical Galaxy S23 Ultra (Android 16), for a
  local document as well as a Drive one. The ecosystem's answer is to copy the
  bytes during the pick, which is precisely what this package exists to avoid.
  Grants taken without `persistAccess: true` are released automatically at the
  next process start and on engine detach, are evicted oldest-first past 256 to
  stay clear of Android's 512-grant cap, and are never resolved by
  `openPersisted()`, so `persistedAccess` keeps meaning "survives a restart".
- File I/O runs on a native background queue or executor, never on the main
  thread, which in DartNative is both the UI thread and the Dart isolate's
  thread.
- Hot-restart safety: one dispatcher pointer in a framework-invalidated slot on
  iOS, generation-gated against `DN_IsolateGen()` on Android, plus a reset that
  closes handles left by a previous isolate.

### Errors

- `FilePickerException` with a `FilePickerErrorCode` and an optional
  `nativeCode`. Cancellation is never an error.

### Packaging note: the generated CocoaPods metadata is not authoritative

The iOS pod that ships in the published binary archive is generated by
`dn plugin build` from a fixed template in the DartNative SDK. That template
hardcodes `s.license = { :type => 'Commercial' }` and
`s.author = { 'DartNative' => 'hello@dartnative.com' }` for every plugin it
builds, and the generator takes no license, author, homepage or summary input,
so a package cannot correct those fields.

**This package is MIT licensed and authored by Batuhan Ustun.** The authoritative
statements are the `LICENSE` file shipped in the archive, this package's own
`ios/dartnative_file_picker.podspec`, and the README. The generated pod's
`license` and `author` fields describe the DartNative distribution template, not
the ownership or licensing of this package, and are known to be wrong for
community plugins. See `doc/upstream/dartnative-podspec-metadata.md`.

### Not in this release

Directory picking, document creation and write support. See the README's
Limitations section for the full list.
