# Manual device test matrix

What `tool/check.sh` cannot prove. Everything here needs a **real device**: the
iOS Simulator and the Android emulator have no cloud document providers, so they
cannot exercise the cases that actually break in production.

Run the example app (`cd example && dn run -d <device-id>`). Record device model
and OS version next to the run.

Legend: `[ ]` not run · `[x]` passed · `[!]` failed, with a note.

---

## The release gate: the minimum that must pass

The full matrix below is the thorough version. **This** is the short list that
blocks a stable 0.1.0. Nothing here is optional, and all of it needs real
hardware.

### 1. iPhone, physical device

- [ ] Pick a local document from Files (On My iPhone)
- [ ] Pick an **iCloud Drive** document, including one not yet downloaded
- [ ] Cancel returns `null` / `[]`
- [ ] Multi-selection returns several documents
- [ ] **Cold-relaunch persistence** — the single most important test in this
      package, because it is the one thing compiling cannot prove:
      - [ ] pick an external iCloud/Files document with `persistAccess: true`
      - [ ] confirm `persistedAccess == true`
      - [ ] **force quit** the app from the app switcher
      - [ ] relaunch, call `openPersisted(savedUri)`
      - [ ] read the **entire** file and verify the bytes against the original
      - [ ] move or rename the original, relaunch, `openPersisted` again: the
            stale bookmark is refreshed and the read still succeeds
      - [ ] `releasePersistedAccess()`, force quit, relaunch, `openPersisted`
            returns `null` predictably
- [ ] Stream a large document (500 MB or more) with flat memory

### 2. Android, physical device

- [ ] Pick from Downloads, then `readAsBytes` **after** the pick returns
- [ ] Pick from **Google Drive**, then `readAsBytes` after the pick returns
- [ ] Cancel returns `null` / `[]`
- [ ] Multi-selection (arrives via `ClipData`)
- [ ] A provider that reports **no size**: `size` is `null`, nothing crashes
- [ ] A `reference`-mode read **after** the pick returns, from a local provider
      and from Drive: this is what the grant-lifetime fix exists for
- [ ] Persisted grant: pick with `persistAccess: true`, **force stop** the app,
      relaunch, `openPersisted` returns the document and it reads
- [ ] `releasePersistedAccess()`, force stop, relaunch, `openPersisted` returns
      `null`

### 3. Both platforms: lifecycle under load

- [ ] 500 MB or larger streamed read completes with flat memory
- [ ] Background the app with the picker open, return, pick completes
- [ ] Android: rotate the device with the picker open, then select
- [ ] Android: "Don't keep activities" enabled, pick a document, result still
      arrives or fails cleanly
- [ ] Hot restart (capital `R`) with the picker open, on both platforms

### 4. Extension enforcement

- [ ] `allowedExtensions: ['pdf']`, pick a PDF: accepted
- [ ] `allowedExtensions: ['abcxyz']` (no known MIME type): the Android picker
      widens to everything, pick a JPG, and the call fails with
      `unsupportedType` rather than returning the JPG
- [ ] Multi-pick with `['pdf']` and a mixed selection: the valid subset comes
      back, the rest is dropped
- [ ] A file with no extension is refused when a filter is in force
- [ ] iOS with an unknown extension filters precisely via the dynamic UTI

### 5. Concurrency

- [ ] Second `pickFile()` while the first picker is open fails with `pickerBusy`,
      and only one picker is ever on screen
- [ ] After that rejection, a later pick still works

### 6. copyToCache contract

- [ ] `accessMode: copyToCache` returns `path != null` for **every** file, on
      both platforms
- [ ] The file at that path exists and its size matches the original
- [ ] `copyToCache()` on a `reference`-mode file returns a valid new path
- [ ] A failed copy leaves nothing behind in the cache directory

---

## iOS

Device: ____________________  iOS version: __________  Date: __________

### Selection

- [ ] Single selection returns one document
- [ ] Multiple selection returns several, in the order shown
- [ ] Cancel (swipe down / Cancel) returns `null` from `pickFile`, no exception
- [ ] Cancel returns `[]` from `pickFiles`, no exception
- [ ] Second picker while the first is open fails with `pickerBusy`, and only one
      picker is ever on screen
- [ ] After a `pickerBusy` rejection, a later pick still works (the guard was
      released)

### Types

- [ ] PDF
- [ ] JPG and PNG, via `FileType.image`
- [ ] Video, via `FileType.video`
- [ ] CSV, via `FileType.custom`
- [ ] XLSX, via `FileType.custom`
- [ ] `FileType.custom` with an extension iOS does not know (e.g. `dnkeys`) still
      filters to it, via the dynamic UTI
- [ ] `FileType.any` offers everything

### Sources

- [ ] Files app, On My iPhone
- [ ] iCloud Drive, a document already downloaded
- [ ] iCloud Drive, a document **not** yet downloaded: the read materializes it
      rather than failing
- [ ] A third-party provider (Google Drive, Dropbox, OneDrive) if installed

### Names

- [ ] Unicode filename (e.g. `rapor-özet.pdf`)
- [ ] Filename with spaces
- [ ] Right-to-left filename (e.g. Arabic)
- [ ] Very long filename: the copy succeeds and the name is truncated, not
      rejected
- [ ] No extension at all: `extension` is `null`
- [ ] Uppercase extension: `extension` is lowercased
- [ ] Filename starting with a dot

### Reading

- [ ] `readAsBytes` on a small document matches its size
- [ ] `readAsByteStream` on a large document (500 MB or more) completes, and
      memory in Xcode's gauge stays flat rather than climbing with the file
- [ ] Streaming reports chunks no larger than the requested `chunkSize`
- [ ] A zero-byte document yields no chunks and does not hang
- [ ] `copyToCache` returns a path that exists, with the right size
- [ ] A document deleted between picking and reading fails with a typed error,
      not a crash

### Security scope and lifetime

- [ ] After many picks and reads, the app does not accumulate open file handles
      (Xcode Debug gauges)
- [ ] Backgrounding the app with the picker open, then returning, still completes
      the pick
- [ ] **A modal sheet is already open**, then the picker is presented from it:
      the picker appears above it and is not torn down with it (this is what the
      dedicated `UIWindow` exists for)
- [ ] A modal that presents the picker and closes itself in the same tap: the
      picker survives
- [ ] Present the picker during a navigation transition, then select
      successfully
- [ ] Hot restart (capital `R`) with the picker open: no
      `Callback invoked after it has been deleted`, no SIGABRT, and the plugin
      works again afterwards
- [ ] Hot restart mid-stream: no crash

### Persisted access

- [ ] Picking with `persistAccess: true` reports `persistedAccess == true`
- [ ] **Kill and relaunch the app**, then `openPersisted(uri)` returns the
      document and it can be read
- [ ] `releasePersistedAccess()` then `openPersisted(uri)` returns `null`
- [ ] Move or rename the document on the device, then `openPersisted`: the stale
      bookmark is refreshed and the document still resolves
- [ ] Delete the document, then `openPersisted` returns `null` rather than
      throwing

## Android

Device: ____________________  Android version: __________  Date: __________

### Selection

- [ ] Single selection returns one document
- [ ] Multiple selection returns several (arrives via `ClipData`)
- [ ] Back / cancel returns `null` from `pickFile`, no exception
- [ ] Back / cancel returns `[]` from `pickFiles`, no exception
- [ ] Second picker while the first is open fails with `pickerBusy`
- [ ] The proxy activity is invisible: no flash of a blank screen opening or
      closing the picker
- [ ] The proxy activity does **not** appear in the recents list

### Types

- [ ] PDF
- [ ] Images, via `FileType.image`
- [ ] Video, via `FileType.video`
- [ ] CSV, via `FileType.custom`
- [ ] XLSX, via `FileType.custom`
- [ ] Several extensions at once (`EXTRA_MIME_TYPES`) shows all of them
- [ ] An extension with no known MIME type widens the filter rather than hiding
      the file
- [ ] `localOnly: true` hides cloud providers

### Sources

- [ ] Downloads
- [ ] Documents
- [ ] Google Drive, if installed
- [ ] A second `DocumentsProvider` (OneDrive, Dropbox, an SD card, a file manager)
- [ ] A provider that reports **no size**: `size` is `null`, nothing crashes, and
      the UI shows "unknown" rather than 0
- [ ] A provider that reports no display name: the fallback name is used

### Names

- [ ] Unicode filename
- [ ] Filename with spaces
- [ ] Right-to-left filename
- [ ] Very long filename
- [ ] No extension
- [ ] Uppercase extension

### Reading

- [ ] `readAsBytes` on a small document matches its size
- [ ] `readAsByteStream` on a large document (500 MB or more) completes with flat
      memory in Android Studio's profiler
- [ ] A zero-byte document yields no chunks
- [ ] `copyToCache` returns a real path with the right size, inside the app's
      cache directory
- [ ] The same document picked twice in one selection arrives twice
- [ ] Revoke the app's access (or delete the document) and read: a typed
      `accessDenied` / `providerUnavailable`, not a crash

### Lifecycle

- [ ] Rotate the device while the picker is open: the pick still completes and
      the picker is not relaunched
- [ ] Background the app while the picker is open, then return: the pick
      completes
- [ ] Enable "Don't keep activities" in developer options, pick a document: the
      result still arrives or fails cleanly, never silently
- [ ] Hot restart (capital `R`) with the picker open: no
      `Callback invoked after it has been deleted`, no SIGSEGV, and the plugin
      works afterwards
- [ ] Hot restart mid-stream: no crash

### Grant lifetime

The reason `AccessMode.reference` works at all on Android: a transient
activity-result grant dies with the picker's proxy activity, so a persistable
grant is taken and the plugin owns its lifetime. These rows test that ownership.

- [ ] Pick in `reference` mode, then read: the bytes arrive, no `accessDenied`
- [ ] "Append pick" twice, then read the **first** card: a later pick must not
      release an earlier reference
- [ ] `reference` + `persistAccess: false`, force stop, relaunch,
      `openPersisted(uri)` returns `null`, and the document is gone from
      Settings' per-app file access list
- [ ] Pick a document with `persistAccess: true`, pick the **same** document
      again with `persistAccess: false`, force stop, relaunch: `openPersisted`
      still returns it, because the second pick must not demote a grant the
      caller owns
- [ ] `copyToCache` mode: `path` is non-null and **no** grant appears in
      Settings' per-app file access list

### Persisted access

- [ ] `persistAccess: true` on a provider that grants it reports
      `persistedAccess == true`
- [ ] A provider that does **not** grant it reports `false`, and the pick still
      succeeds
- [ ] **Kill and relaunch**, then `openPersisted(uri)` returns the document
- [ ] `releasePersistedAccess()` then `openPersisted(uri)` returns `null`
- [ ] The grant disappears from Settings after release (persisted URI grants are
      visible per app)

## Both platforms, before release

- [ ] The example app exercises every public API without a crash
- [ ] No debug logging appears in a release build beyond the deliberate
      `print("[DNFilePicker] …")` diagnostics on native failure paths
- [ ] No temporary file is left behind by a **failed** `copyToCache`
- [ ] Repeated pick, read and copy cycles leak neither memory nor handles
