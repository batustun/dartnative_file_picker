# file_picker

The native document picker for DartNative apps. It presents the operating
system's own document browser over FFI: **`UIDocumentPickerViewController`** on
iOS and the **Android Storage Access Framework** (`Intent.ACTION_OPEN_DOCUMENT`)
on Android.

No Flutter `MethodChannel`. No platform-channel serialization. No storage
permissions. The picker UI belongs to the OS, and this package does not draw a
pixel of it.

It also refuses to lie to you about one thing the Flutter ecosystem routinely
gets wrong: **a picked document usually has no filesystem path.** Android hands
back a `content://` URI owned by a provider that may be Google Drive, Dropbox or
a network share. This package gives you the URI as the document's identity, and
a real path only when one genuinely exists.

```dart
final file = await FilePicker.pickFile();
if (file == null) return;                 // the user closed the picker
print('${file.name} · ${file.uri}');      // path is often null, uri never is
```

## Features

- Single and multiple selection.
- Filter by category (`image`, `video`, `audio`, `any`) or by exact extension.
- Cancellation is `null` / `[]`, never an exception.
- **Large files are safe**: nothing is read at pick time, and
  `readAsByteStream()` streams in constant memory. A 4 GB video costs the same
  to pick as a 2 KB note.
- `copyToCache()` when a library really needs a `char*` path, streamed and
  collision-safe.
- Optional persisted access that survives an app restart, with `openPersisted()`
  to use it, on both platforms.
- Typed errors (`FilePickerErrorCode`), never `Exception("failed")`.
- One picker at a time, enforced; a second concurrent call fails fast.
- Cloud and third-party document providers work, including iCloud Drive.
- Zero permissions declared. No analytics, no telemetry, no network code.

## Platform implementation

| | iOS | Android |
|---|---|---|
| Picker | `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)` | `Intent.ACTION_OPEN_DOCUMENT` + `CATEGORY_OPENABLE` |
| Filter | `UTType` from UniformTypeIdentifiers | `Intent.setType` + `EXTRA_MIME_TYPES` |
| Multiple | `allowsMultipleSelection` | `EXTRA_ALLOW_MULTIPLE`, read from `ClipData` |
| Identity | `file://` URL, security-scoped | `content://` URI from a `DocumentsProvider` |
| Reading | `FileHandle` inside `NSFileCoordinator`, on a background queue | `ContentResolver.openInputStream`, on a background executor |
| Metadata | `URL.resourceValues` | `OpenableColumns` + `ContentResolver.getType` |
| Persistence | security-scoped bookmark | `takePersistableUriPermission` |
| Bridge | `@_cdecl` Swift, `DynamicLibrary.process()` | Kotlin + JNI in `libdartnative_file_picker.so` |

## Install

```yaml
dependencies:
  file_picker: ^0.1.0   # from dartpub.dev
```

```bash
dn pub get
```

```dart
void main() {
  DartNativePluginRegistrant.registerAll();   // first line, always
  runApp(const MyApp());
}
```

`dn pub get` regenerates `lib/dartnative_plugin_registrant.dart`, and
`registerAll()` binds this plugin's FFI symbols. Forgetting it is the one setup
mistake possible, and it reports itself with an actionable message rather than a
crash. Nothing to add to `AppDelegate.swift`, `Application.kt`, your `Podfile`
or your manifest.

## Pick one document

```dart
import 'package:file_picker/file_picker.dart';

final PlatformFile? file = await FilePicker.pickFile();
if (file == null) {
  // Cancelled. Not an error.
  return;
}
```

## Pick several

```dart
final List<PlatformFile> files = await FilePicker.pickFiles();
// Cancelled → [].
```

## Filter by extension

```dart
final file = await FilePicker.pickFile(
  type: FileType.custom,
  allowedExtensions: ['pdf', 'xlsx', 'csv'],
);
```

Extensions are normalized before use: `'.PDF'`, `'pdf'` and `' pdf '` are one
filter, and duplicates collapse. Malformed input is rejected **before** the
picker is presented, with a message naming the offender:

```dart
allowedExtensions: ['application/pdf']  // throws invalidFilter: that is a MIME type
allowedExtensions: ['*.pdf']            // throws invalidFilter: that is a glob
allowedExtensions: ['tar.gz']           // throws invalidFilter: pass 'gz'
allowedExtensions: []                   // throws invalidFilter: custom needs one
```

`allowedExtensions` applies only to `FileType.custom`. Passing it with
`FileType.image` trips an assertion in debug builds and is ignored in release:
no platform picker can express "images, but only PDFs", and guessing which half
to honour would be worse than saying so.

**The filter is enforced, not merely requested.** A platform picker's filter is a
hint: Android cannot express an extension with no known MIME type and widens to a
wildcard rather than hiding your file, and provider MIME types are unreliable even
when it can. So the selection is also checked against each document's filename:

- anything outside `allowedExtensions` is dropped;
- if that leaves nothing, you get `FilePickerErrorCode.unsupportedType` naming
  what was picked and what is allowed, rather than an empty result that looks
  like the picker silently failed;
- a document with no extension never satisfies a filter.

So for a `FileType.custom` pick, every `PlatformFile.extension` you receive is one
you asked for, on both platforms and against every provider. With `pickFiles()` a
partly valid selection returns the valid subset.

## Filter by category

```dart
final images = await FilePicker.pickFiles(type: FileType.image);
```

For photos and videos out of the user's **photo library**, the first-party
`dartnative_media_picker` is the better tool: it uses `PHPicker` and the Android
Photo Picker, which need no permission and are built for media. Use this package
when you want the *document* browser instead.

## Read the bytes

```dart
final bytes = await file.readAsBytes();   // whole document in memory
```

Convenient, and a trap for anything whose size you do not control. Prefer:

## Stream the bytes

```dart
final sink = File(target).openWrite();
await file.readAsByteStream().pipe(sink);
```

```dart
await for (final chunk in file.readAsByteStream(chunkSize: 32 * 1024)) {
  hash.add(chunk);
}
```

Guarantees:

- nothing is read until you listen;
- no chunk exceeds `chunkSize`, though any chunk may be smaller;
- the native side never buffers the whole document first: each chunk is read on
  demand, on a background thread, so a slow consumer slows the read rather than
  filling memory;
- the native handle and any iOS security scope are released when the stream
  ends, is cancelled, or fails;
- a zero-byte document yields no chunks and simply closes.

## Get a real file path

```dart
final path = await file.copyToCache();
```

Or ask for it up front, which on iOS uses the picker's own `asCopy` mode:

```dart
final files = await FilePicker.pickFiles(
  options: const FilePickerOptions(
    accessMode: FilePickerAccessMode.copyToCache,
  ),
);
// every file.path is non-null here
```

The copy is streamed, lands in its own directory so same-named documents cannot
collide, keeps the extension, has its filename sanitized against traversal, and
is deleted if it fails partway, so a truncated file is never returned. It lives
in the OS cache directory, which means **the system may delete it** and this
package never does. Move it somewhere you own if you need to keep it.

The two modes, stated as a contract:

| | `path` on the returned file | `copyToCache()` afterwards |
|---|---|---|
| `accessMode: reference` (default) | `null`, unless the document already sits inside your app's container | creates a managed copy and returns its path |
| `accessMode: copyToCache` | **always non-null.** Guaranteed: a returned file without a path is treated as a native contract violation and raises `copyFailed` rather than handing you a `null` to check | creates a *second*, independent copy |

In `copyToCache` mode, use `path`. What `uri` refers to is not the same on both
platforms, because the OS decides: Android keeps the original `content://`
document, while on iOS the system's `asCopy` picker only ever hands back the
copy's URL. Verified on device.

So `copyToCache()` is not idempotent, by design: it is a command, not a cached
accessor. Two calls mean two files, and the package neither deduplicates nor
deletes them. In `copyToCache` access mode you already have the path, so you
should not need to call it at all.

## Persisted access

```dart
final file = await FilePicker.pickFile(
  options: const FilePickerOptions(persistAccess: true),
);
if (file != null && file.persistedAccess) {
  await prefs.setString('watched', file.uri.toString());
}
```

Next launch:

```dart
final saved = prefs.getString('watched');
final file = saved == null
    ? null
    : await FilePicker.openPersisted(Uri.parse(saved));
if (file == null) {
  // The grant or the document is gone. Ask the user to pick again.
}
```

Always check `persistedAccess` on the result rather than assuming the request
was honoured: an Android provider may decline, and the pick still succeeds with
`persistedAccess == false`.

Give it back when you are done, because Android caps how many persisted grants
an app may hold:

```dart
await file.releasePersistedAccess();   // no-op when nothing was persisted
```

## Cancellation

| Call | Cancelled |
|---|---|
| `pickFile()` | returns `null` |
| `pickFiles()` | returns `[]` |

Identical on both platforms. Closing the picker is something users do on
purpose, so it never throws.

One more case lands here, verified on device: if the app is **backgrounded while
the picker is open**, iOS may tear the picker down, and the pick then completes as
a cancellation. The future always completes — it does not hang — so a pick left
open when the user switches away resolves as `null` / `[]` rather than leaving
your `await` stuck forever.

## Android: content URIs

A picked document is a `content://` URI, not a file. There is no path to find,
and this package does not try:

- **no** `getRealPathFromUri()`, which is the hack that breaks on every provider
  it was not tested against;
- **no** undocumented `MediaStore` column spelunking;
- **no** assumption that Drive, OneDrive or Dropbox expose a readable path.

Read it with `readAsBytes()` / `readAsByteStream()`, or call `copyToCache()` when
a path is unavoidable. Access lasts while your app runs, or across restarts with
`persistAccess`.

### Why reference mode takes a URI grant on Android

A URI permission that arrives in an activity result is owned by the activity
that received it. AOSP revokes it when that activity leaves the history stack:

```java
// ActivityRecord.removeFromHistory()
cleanUpActivityServices();
removeUriPermissionsLocked();   // uriPermissions.removeUriPermissions()
```

Flutter's own packages dodge this by receiving the result on the host activity,
which lives as long as the app is in the foreground. DartNative exposes no
activity-result hook, so this plugin owns a transparent proxy activity that
finishes the moment it has the result, and with it the transient grant. Measured
on a Galaxy S23 Ultra (Android 16): every read after the pick failed with
`SecurityException`, for a local Downloads document and for a Drive document
alike.

The alternative taken by the ecosystem is to copy the bytes during the pick
(`file_selector_android`, `image_picker_android`, and `file_picker` by default,
which also offers an opt-in `AndroidSAFGrant.lifetime`). Copying is exactly what
this package exists to avoid, because it turns picking a 4 GB video into a 4 GB
disk write.

So `AccessMode.reference` takes the one durable mechanism Android offers, a
persistable grant, and manages its lifetime instead of leaking it:

| `persistAccess` | Grant belongs to | Released by |
| --- | --- | --- |
| `false` (default) | the plugin | the next process start, or engine detach |
| `true` | you | `releasePersistedAccess()` only |

Two consequences worth knowing. While your app runs, a referenced document
appears in the system's list of files your app can access, even with
`persistAccess: false`. And `persistedAccess` still reports `false` for those,
because it answers "can you reopen this after a restart", which only
`persistAccess: true` makes true; `openPersisted()` resolves those grants and
only those.

Provider metadata is treated as optional throughout, because a
`DocumentsProvider` is not obliged to answer any particular column: a missing
display name falls back to the URI's last segment and then to `'document'`, and a
missing size stays `null` rather than becoming `0`. `null` means "unknown", which
is a normal answer from a cloud provider; it is deliberately not conflated with a
genuinely empty document.

## iOS: security-scoped resources

A picked document often lives outside your app's container, so reading it
requires a security-scoped resource. This package acquires the scope, performs
the operation and releases it, balancing every successful
`startAccessingSecurityScopedResource()` with a `stop…`. Nothing is held open to
make the API look simpler.

Reads go through `NSFileCoordinator`, which is the supported way to read a
document another process may be writing, and which would also materialize an
iCloud item that is not on the device.

In practice that second part may never be needed: on device, removing a
document's local copy and then picking it caused **the picker itself** to download
it before handing over the URL, so the file was already materialized by the time
this package saw it. The coordination is kept because it is correct for
coordinated documents, not because a materialization benefit was observed.

### Where persisted access actually lives on iOS

Worth being concrete, because the two platforms store it in different places and
that difference is yours to manage:

On **Android** the operating system holds the grant. Your app holds nothing, and
the grant is visible to the user in system settings.

On **iOS** nothing holds it for you, so this package does:

```text
PlatformFile.uri (absolute string)        the key
        ↓
security-scoped bookmark (Data)           the value
        ↓
UserDefaults.standard, under the key
"dartnative_file_picker.bookmarks"        a [String: Data] dictionary
```

What follows from that, and is worth knowing before you enable it:

- The bookmark lives in **your app's own `UserDefaults`**, not in a container this
  package owns. It survives app launches and updates, and it is removed when the
  app is deleted.
- Because it is in `UserDefaults`, it is included in device and iCloud backups. A
  bookmark restored onto a *different* device will not resolve, and
  `openPersisted()` returns `null` for it, which is the correct outcome rather
  than an error.
- `releasePersistedAccess()` **deletes the stored bookmark**, so it is a real
  release and not just a dropped reference. After it, `openPersisted()` for that
  URI returns `null` in this and every later session.
- `openPersisted()` resolves the bookmark and refreshes it in place when the
  system reports it stale, which is what happens when the user moves or renames
  the document. The returned `PlatformFile.uri` is **the URI you passed in**, not
  the document's new location: it is the key the grant is stored under, so it is
  what later reads, copies and releases need. `name` and `size` do reflect the
  document's current state, which is how you notice it moved. Nothing to update
  on your side after a rename.
- A deleted document is not recoverable. `openPersisted()` returns `null` rather
  than pretending, and does not throw.
- Keep the `uri` string yourself (in preferences, a database, wherever). It is the
  key, and without it there is nothing to pass to `openPersisted()`.

One implementation note, since it is a documented Apple inconsistency: on iOS the
bookmark is created with **no** `.withSecurityScope` option, because that option
is macOS-only and is marked `@available(iOS, unavailable)` in the SDK. On iOS the
scope travels with a bookmark to a document-picker URL implicitly, and is claimed
by calling `startAccessingSecurityScopedResource()` on the **resolved** URL, which
is what this package does. Compiling proves only that the option is absent; the
behaviour is what the cold-relaunch device test in
`doc/manual-test-matrix.md` exists to prove.

## Platform differences

These are real and are not papered over:

| | iOS | Android |
|---|---|---|
| `localOnly` | **ignored** — `UIDocumentPickerViewController` has no equivalent | `EXTRA_LOCAL_ONLY`, cloud providers excluded |
| Unknown extension in `allowedExtensions` | filtered exactly, via a dynamic UTI | the filter **widens** to a wildcard rather than hiding your file, so check `extension` yourself if it matters |
| `persistAccess` mechanism | security-scoped bookmark in app preferences | `takePersistableUriPermission`, which the provider may refuse |
| Grant cap | none | 512 persisted grants per app; Android releases the oldest beyond that |
| Reference-mode lifetime | the retained picked URL, read inside a security scope | a plugin-owned persisted grant, released at the next process start |
| `copyToCache` source | the picker's own `asCopy` copy, moved into the cache | streamed through `ContentResolver` |
| `path` non-null when | the document is already inside your container, or after a copy | only after a copy |
| `uri` in `copyToCache` mode | the **app-owned copy**: the system's `asCopy` picker returns only the copy's URL and never the original's | the **original `content://`** document, which stays readable |

On `localOnly`: this package does not emulate it by discarding a cloud file
after the user picked it. If your app cannot wait for a download, use
`accessMode: copyToCache`, which forces the bytes to be materialized before the
future completes.

## Permissions

**None.** This package declares no permission on either platform, and an app
that depends on it inherits none.

The Storage Access Framework grants access to the documents the user picks, which
is the whole point of it. Adding `READ_EXTERNAL_STORAGE`, `READ_MEDIA_*` or
`MANAGE_EXTERNAL_STORAGE` would ask for broad storage access this package does
not need and must not have.

Nothing to add to `Info.plist` either.

## Migrating from Flutter's `file_picker`

| Flutter `file_picker` | Here |
|---|---|
| `FilePickerResult?` + `result.files` | `PlatformFile?` from `pickFile()`, `List<PlatformFile>` from `pickFiles()` |
| `result == null` for cancel | `null` / `[]` for cancel |
| `PlatformFile.path` | **`PlatformFile.uri`**, and `await file.copyToCache()` when you truly need a path |
| `PlatformFile.bytes` (eager) | `await file.readAsBytes()`, or better `file.readAsByteStream()` |
| `withData: true` | nothing: never load eagerly. Read when you need it. |
| `withReadStream: true` | `readAsByteStream()`, always available |
| `FileType.any/image/video/audio/custom` | the same enum |
| `allowedExtensions` | the same, but validated and normalized |
| `allowMultiple: true` | `pickFiles()` |
| `lockParentWindow`, desktop options | not applicable: iOS and Android only |

The one habit to unlearn: `file.path!`. It is `null` for most documents on
Android by design, and that is the OS being honest, not the package being
incomplete.

## Error handling

```dart
try {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['pdf'],
  );
} on FilePickerException catch (e) {
  switch (e.code) {
    case FilePickerErrorCode.pickerBusy:
      return;                                  // a double tap; ignore it
    case FilePickerErrorCode.accessDenied:
    case FilePickerErrorCode.providerUnavailable:
      showRetry();
    default:
      report(e.message, e.nativeCode);         // nativeCode is for your logs
  }
}
```

Switch on `code`. `message` is developer-facing and not localized, and
`nativeCode` (an `NSError` domain, a Java exception name) is useful in a bug
report but explicitly unstable.

Every failure arrives as an error on the returned future, including argument
validation, so one `try`/`await` covers all of them.

Codes: `pickerBusy`, `invalidFilter`, `unsupportedType`, `accessDenied`,
`providerUnavailable`, `readFailed`, `copyFailed`, `persistenceFailed`,
`nativeFailure`, `noPresentationContext`.

## Large files

The default pick reads nothing. Metadata only.

| Document | `pickFile()` | `readAsBytes()` | `readAsByteStream()` | `copyToCache()` |
|---|---|---|---|---|
| 2 KB note | instant | fine | fine | fine |
| 10 MB PDF | instant | fine | fine | fine |
| 500 MB ZIP | instant | 500 MB of RAM | constant memory | disk only |
| 4 GB video | instant | **will exhaust the process** | constant memory | disk only |
| cloud document | instant | downloads it | downloads it as it streams | downloads it |

Rule of thumb: if you did not choose the file's size, stream it.

### Throughput, measured

Each chunk costs one asynchronous native-to-Dart delivery, and that round trip is
the bottleneck on **both** platforms, independent of chunk size: ~35 ms per chunk
on a physical iPhone 15 Pro Max (iOS 26.6), ~43 ms on an Android 14 emulator, for
a local app-owned file just as much as for a provider's document. So streaming
throughput is latency-bound at about `chunkSize / 40 ms`:

| `chunkSize` | iOS | Android | 600 MB document |
|---|---|---|---|
| 32 KiB | 0.63 MB/s (measured) | — | ~16 min |
| 64 KiB | ~1.3 MB/s | ~1.5 MB/s | ~8 min |
| **1 MiB (default)** | **28.7 MB/s (measured)** | **23.3 MB/s (measured)** | **21-26 s** |
| 4 MiB | ~80 MB/s | ~70 MB/s | ~8 s |

Three practical consequences:

- The default is 1 MiB for this reason, not for memory reasons. Peak memory is
  one chunk, so raising it costs little and buys a lot.
- For **progress reporting** on a small file, lower it; you get finer updates at
  a throughput you will not notice.
- For a **multi-gigabyte** document you only need on disk, `copyToCache()` beats
  streaming outright: the copy runs entirely in native code with no per-chunk
  round trip. A 600 MB copy completed in seconds on the same device.

## Support matrix

| | Supported |
|---|---|
| iOS | 15.0 and later (podspec target; `dn` builds pods at 15.0) |
| Android | minSdk 26, compileSdk 36, 64-bit (`arm64-v8a`, `x86_64`) |
| DartNative | `^1.0.0` |
| Dart SDK | `^3.9.0-0` |
| Other platforms | none. macOS, Windows, Linux and web are not supported. |

Dependencies: `dartnative`, `ffi`, and `mime` (BSD-3-Clause, pure Dart, from the
Dart team) for extension to MIME resolution. Nothing else.

## Privacy

- The picker UI is provided by the operating system.
- This package **does not upload** selected files, or any part of them.
- No file content, filename or URI leaves the device through this package.
- No analytics, no telemetry, no crash reporting, no ad SDK.
- No network dependency, and no networking code at all.
- Temporary copies are only ever created by an explicit `copyToCache()` or
  `accessMode: copyToCache`, in your app's own cache directory.

## Limitations

Stated precisely, because a vague limitation is not a limitation:

1. `FilePickerOptions.localOnly` is ignored on iOS. No `UIDocumentPicker` API
   expresses it.
2. On Android, a `FileType.custom` filter containing an extension with no known
   MIME type widens the *picker* to a wildcard, so the user is shown more than
   you asked for. The *result* is still enforced against your extension list, so
   nothing outside it is ever returned; the cost is a picker that offers files it
   will then refuse.
3. No directory picker. `ACTION_OPEN_DOCUMENT_TREE` and the iOS folder picker are
   not implemented in 0.1.0.
4. No save or create flow. `ACTION_CREATE_DOCUMENT` is not implemented.
5. No write support. Documents are opened for reading only.
6. `PlatformFile.mimeType` is whatever the provider claims. Do not make a
   security decision from it, or from the extension.
7. `copyToCache()` called twice produces two independent copies; this package
   does not deduplicate or garbage-collect them.
8. The same document picked twice in one multi-selection arrives twice. That is
   what the user did; deduplicate on `uri` if you would rather not.
9. iOS 15.0 is the floor, inherited from what the current toolchain builds pods
   against.
10. This is 0.1.0: the API may change before 1.0.0 under semantic versioning.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). `tool/check.sh` runs the full local
quality gate, and `doc/plugin-pattern-findings.md` records why the plugin is
built the way it is, with the first-party sources each decision came from.

## License

MIT. See [LICENSE](LICENSE).
