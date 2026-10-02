// DNFilePickerBridge.swift
// @_cdecl FFI entry points for the dartnative_file_picker plugin.
//
// Exposes UIDocumentPickerViewController and security-scoped document access as
// a small set of C functions, so DartNative apps can pick documents with no
// Flutter platform channels.
//
// Architecture notes that matter:
//
//  * Dart runs on the platform MAIN thread in DartNative, so every delivery
//    into Dart happens there. File I/O does NOT: that would block the UI
//    thread, so reads and copies run on their own queues and only the delivery
//    hops back to main.
//  * Replies travel through ONE dispatcher pointer kept in a framework-
//    registered slot. See the "Result dispatcher" section for why.
//  * The picker is presented in a window of its own rather than from the app's
//    top-most view controller, matching the first-party dartnative_share
//    plugin. UIKit dismisses a presented controller together with its
//    presenter, so a modal that picks and closes in the same tap would
//    otherwise take the picker down with it.

import Foundation
import UIKit
import UniformTypeIdentifiers

private func dnLog(_ message: String) {
  print("[DNFilePicker] \(message)")
}

// MARK: - Error codes
//
// These strings are the wire contract with FilePickerErrorCode in Dart.
// native_codec_test.dart asserts every Dart code round-trips, so a name added
// on one side without the other is caught by the test suite rather than in
// production.

private enum DNErr {
  static let unsupportedType = "unsupportedType"
  static let accessDenied = "accessDenied"
  static let providerUnavailable = "providerUnavailable"
  static let readFailed = "readFailed"
  static let copyFailed = "copyFailed"
  static let persistenceFailed = "persistenceFailed"
  static let nativeFailure = "nativeFailure"
  static let noPresentationContext = "noPresentationContext"
  static let pickerBusy = "pickerBusy"
}

// MARK: - Result dispatcher (the framework-invalidated slot)
//
// Dart hands us ONE dispatcher address for the whole plugin. We never capture
// it in a closure: it lives in a heap slot registered with the framework via
// DNRegisterAsyncDispatcherSlot, which zeroes it BEFORE the old isolate dies on
// hot restart. A picker still open across a restart therefore delivers into 0
// and is dropped, instead of calling a freed trampoline ("Callback invoked
// after it has been deleted" → SIGABRT). Every fire re-reads the slot and runs
// on the main thread.
//
// Payload is length-delimited bytes rather than a C string, so JSON replies and
// raw file chunks share one slot without base64 inflating every chunk.

private let eventJson: Int32 = 1
private let eventChunk: Int32 = 2
private let eventEof: Int32 = 3

private typealias DNDispatch =
  @convention(c) (Int64, Int32, UnsafePointer<UInt8>?, Int32) -> Void

private let dispatcherSlot: UnsafeMutablePointer<Int64> = {
  let pointer = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
  pointer.pointee = 0
  return pointer
}()
private var slotRegistered = false

@_cdecl("DNFilePickerSetDispatcher")
public func DNFilePickerSetDispatcher(_ callbackPtr: Int64) {
  dispatcherSlot.pointee = callbackPtr
  if !slotRegistered {
    slotRegistered = true
    typealias RegisterFn = @convention(c) (UnsafeMutablePointer<Int64>) -> Void
    // RTLD_DEFAULT; the framework symbol is already in the process image.
    if let symbol = dlsym(
      UnsafeMutableRawPointer(bitPattern: -2),
      "DNRegisterAsyncDispatcherSlot"
    ) {
      unsafeBitCast(symbol, to: RegisterFn.self)(dispatcherSlot)
    } else {
      dnLog("DNRegisterAsyncDispatcherSlot not found — is dartnative_ios linked?")
    }
  }
}

/// Every delivery to Dart goes through here: main thread, slot read fresh.
private func fire(_ token: Int64, _ type: Int32, _ bytes: [UInt8]) {
  let deliver = {
    let address = dispatcherSlot.pointee  // fresh — nulled before teardown
    guard address != 0 else { return }    // hot restart happened → drop
    let dispatch = unsafeBitCast(address, to: DNDispatch.self)
    if bytes.isEmpty {
      dispatch(token, type, nil, 0)
    } else {
      // Dart copies during this synchronous call; nothing is handed over.
      bytes.withUnsafeBufferPointer { buffer in
        dispatch(token, type, buffer.baseAddress, Int32(bytes.count))
      }
    }
  }
  if Thread.isMainThread {
    deliver()
  } else {
    DispatchQueue.main.async(execute: deliver)
  }
}

private func fireJson(_ token: Int64, _ json: String) {
  fire(token, eventJson, Array(json.utf8))
}

private func fireChunk(_ token: Int64, _ data: Data) {
  fire(token, eventChunk, [UInt8](data))
}

private func fireEof(_ token: Int64) {
  fire(token, eventEof, [])
}

private func fireError(
  _ token: Int64,
  _ code: String,
  _ message: String,
  nativeCode: String? = nil
) {
  var error: [String: Any] = ["code": code, "message": message]
  if let nativeCode = nativeCode { error["nativeCode"] = nativeCode }
  fireJson(token, jsonString(["__error": error]))
}

/// Encodes [value] as JSON, falling back to a hand-built error envelope.
///
/// JSONSerialization can only fail here if a value is not representable, which
/// would be a bug on this side; reporting it as a native failure beats
/// delivering nothing and hanging the Dart future forever.
private func jsonString(_ value: [String: Any]) -> String {
  guard
    let data = try? JSONSerialization.data(withJSONObject: value),
    let text = String(data: data, encoding: .utf8)
  else {
    dnLog("failed to encode a reply as JSON")
    return
      "{\"__error\":{\"code\":\"nativeFailure\",\"message\":\"The iOS side could not encode its reply.\"}}"
  }
  return text
}

private func cString(_ pointer: UnsafePointer<CChar>?) -> String? {
  guard let pointer = pointer else { return nil }
  let value = String(cString: pointer)
  return value.isEmpty ? nil : value
}

private func nsErrorCode(_ error: Error) -> String {
  let nsError = error as NSError
  return "\(nsError.domain) \(nsError.code)"
}

/// Maps a Cocoa error onto the closest Dart error code.
private func mappedCode(_ error: Error, fallback: String) -> String {
  let nsError = error as NSError
  guard nsError.domain == NSCocoaErrorDomain else { return fallback }
  switch nsError.code {
  case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
    return DNErr.accessDenied
  case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
    return DNErr.providerUnavailable
  default:
    return fallback
  }
}

// MARK: - Request model

private struct PickRequest {
  let type: String
  let extensions: [String]
  let allowMultiple: Bool
  let copyToCache: Bool
  let persistAccess: Bool

  init?(json: String) {
    guard
      let data = json.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data),
      let map = root as? [String: Any],
      let type = map["type"] as? String
    else { return nil }
    self.type = type
    extensions = (map["extensions"] as? [String]) ?? []
    allowMultiple = (map["allowMultiple"] as? Bool) ?? false
    copyToCache = (map["accessMode"] as? String) == "copyToCache"
    persistAccess = (map["persistAccess"] as? Bool) ?? false
    // `localOnly` is deliberately unread: UIDocumentPickerViewController has no
    // way to hide cloud providers, and filtering the result afterwards would
    // silently discard a file the user deliberately chose. Documented in
    // FilePickerOptions.localOnly.
  }

  /// The content types to open, never empty.
  var contentTypes: [UTType] {
    switch type {
    case "image": return [.image]
    case "video": return [.movie]
    case "audio": return [.audio]
    case "custom":
      // UTType(filenameExtension:) returns a *dynamic* identifier for an
      // extension the system does not know, which still filters correctly — so
      // iOS can express exactly what was asked for even when Android cannot.
      let types = extensions.compactMap { UTType(filenameExtension: $0) }
      return types.isEmpty ? [.item] : types
    default: return [.item]
    }
  }
}

// MARK: - Security-scoped bookmarks (persisted access)

private let bookmarkDefaultsKey = "dartnative_file_picker.bookmarks"

/// Serializes the bookmark store.
///
/// `UserDefaults` is thread-safe per operation, but every mutation here is a
/// read-modify-write of one dictionary, and that sequence is not atomic. The
/// three callers genuinely run on different threads: a pick persists from a
/// global queue, `DNFilePickerRelease` removes synchronously on the Dart main
/// thread, and a stale-bookmark refresh runs from whichever global queue
/// resolved it. Interleaved, two of those lose an update — and the bad direction
/// is a released bookmark being resurrected by a concurrent write, which would
/// retain access the user explicitly gave up.
private let bookmarkStoreQueue = DispatchQueue(
  label: "com.dartnative.file_picker.bookmarks"
)

/// Reads the store. MUST already be on `bookmarkStoreQueue`.
private func bookmarksLocked() -> [String: Data] {
  (UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey)
    as? [String: Data]) ?? [:]
}

private func storedBookmarks() -> [String: Data] {
  bookmarkStoreQueue.sync { bookmarksLocked() }
}

private func storeBookmark(_ data: Data, for url: URL) {
  bookmarkStoreQueue.sync {
    var all = bookmarksLocked()
    all[url.absoluteString] = data
    UserDefaults.standard.set(all, forKey: bookmarkDefaultsKey)
  }
}

private func removeBookmark(for key: String) -> Bool {
  bookmarkStoreQueue.sync {
    var all = bookmarksLocked()
    guard all.removeValue(forKey: key) != nil else { return false }
    UserDefaults.standard.set(all, forKey: bookmarkDefaultsKey)
    return true
  }
}

/// Replaces an existing entry with a freshly minted bookmark.
///
/// Refreshes only a key that is still present. A release that landed while the
/// stale bookmark was being re-minted must not be undone by this write, so a
/// missing key means "it was released, leave it released" rather than "insert".
private func refreshBookmark(_ data: Data, forKey key: String) {
  bookmarkStoreQueue.sync {
    var all = bookmarksLocked()
    guard all[key] != nil else { return }
    all[key] = data
    UserDefaults.standard.set(all, forKey: bookmarkDefaultsKey)
  }
}

/// Creates and stores a security-scoped bookmark. Returns whether it worked.
///
/// Requires the security scope to be held while the bookmark is created.
private func persistBookmark(for url: URL) -> Bool {
  let scoped = url.startAccessingSecurityScopedResource()
  defer { if scoped { url.stopAccessingSecurityScopedResource() } }
  do {
    // No .withSecurityScope here: that option is macOS-only and is explicitly
    // unavailable on iOS. On iOS a bookmark to a URL the document picker
    // returned carries its security scope implicitly, and the scope is claimed
    // by calling startAccessingSecurityScopedResource on the RESOLVED url.
    let data = try url.bookmarkData(
      options: [],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    storeBookmark(data, for: url)
    return true
  } catch {
    dnLog("bookmark creation failed for \(url.lastPathComponent): \(error)")
    return false
  }
}

/// Resolves a stored bookmark, refreshing it when the system reports it stale.
private func resolveBookmark(_ key: String) -> URL? {
  guard let data = storedBookmarks()[key] else { return nil }
  var stale = false
  guard
    let url = try? URL(
      resolvingBookmarkData: data,
      options: [],  // .withSecurityScope is macOS-only; see persistBookmark
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
  else { return nil }
  if stale {
    // The document moved or was replaced. The resolved URL is still usable, so
    // re-record it under the original key and carry on.
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    if let fresh = try? url.bookmarkData(
      options: [],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    ) {
      refreshBookmark(fresh, forKey: key)
    }
  }
  return url
}

// MARK: - Picked URL registry
//
// The single most important object-lifetime rule on this platform: a
// security-scoped URL's access travels with the **URL instance** the picker
// handed us, not with its string. Round-tripping it through Dart as text and
// rebuilding it with `URL(string:)` yields an instance with no scope, and
// reading a document outside the app's container then fails with
// NSFileReadNoPermissionError — which surfaced on device as `accessDenied` for
// every default-mode read.
//
// So the instances are kept. One URL per picked document, for the process
// lifetime, which is exactly the access lifetime the Dart API documents ("for a
// normal pick, for as long as the app keeps running"). They cannot be evicted
// earlier without breaking that promise. The cost is one URL object per pick;
// `DNFilePickerReset` clears the lot on hot restart.

private let pickedURLLock = NSLock()
private var pickedURLs: [String: URL] = [:]

private func registerPickedURL(_ url: URL) {
  pickedURLLock.lock()
  defer { pickedURLLock.unlock() }
  pickedURLs[url.absoluteString] = url
}

private func pickedURL(for key: String) -> URL? {
  pickedURLLock.lock()
  defer { pickedURLLock.unlock() }
  return pickedURLs[key]
}

/// The URL a Dart-side URI string refers to, with its security scope intact.
///
/// Order matters, and each step exists for a reason:
///
/// 1. a stored bookmark, which carries its own scope and survives app restarts;
/// 2. the retained instance from the pick that produced this URI, which carries
///    the scope the picker granted for this process;
/// 3. a plain `URL(string:)` as a last resort. This has **no** scope, so it only
///    works for a document already inside the app's container, such as a
///    copyToCache result. Anything else fails, by design, rather than silently
///    reading the wrong thing.
private func resolveURL(_ uriString: String) -> URL? {
  if let url = resolveBookmark(uriString) { return url }
  if let url = pickedURL(for: uriString) { return url }
  guard let url = URL(string: uriString) else { return nil }
  return url.isFileURL ? url : nil
}

// MARK: - Metadata

/// Describes [url] for Dart, treating every attribute as optional.
///
/// `path` is reported only when the bytes genuinely sit somewhere this app can
/// open without a security scope: inside its own container. Anything else is a
/// document we reach through a scope or a provider, and claiming a path for it
/// would be a lie the Dart side has promised not to tell.
private func fileRecord(
  for url: URL,
  persisted: Bool,
  appOwnedPath: String? = nil
) -> [String: Any] {
  var record: [String: Any] = [
    "uri": url.absoluteString,
    "name": url.lastPathComponent,
    "persistedAccess": persisted,
  ]

  let scoped = url.startAccessingSecurityScopedResource()
  defer { if scoped { url.stopAccessingSecurityScopedResource() } }

  if let values = try? url.resourceValues(forKeys: [
    .nameKey, .fileSizeKey, .contentTypeKey,
  ]) {
    if let name = values.name, !name.isEmpty { record["name"] = name }
    if let size = values.fileSize, size >= 0 { record["size"] = size }
    if let mime = values.contentType?.preferredMIMEType, !mime.isEmpty {
      record["mimeType"] = mime
    }
  }

  if let appOwnedPath = appOwnedPath {
    record["path"] = appOwnedPath
  } else if isInsideAppContainer(url) {
    record["path"] = url.path
  }
  return record
}

private func isInsideAppContainer(_ url: URL) -> Bool {
  guard url.isFileURL else { return false }
  let path = url.standardizedFileURL.path
  let containers = [
    NSTemporaryDirectory(),
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .path,
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
      .first?.path,
    FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.path,
  ].compactMap { $0 }
  return containers.contains { path.hasPrefix($0) }
}

// MARK: - Cache destination

private let cacheSubdirectory = "dn_file_picker"

/// Strips everything from [name] that could escape the destination directory.
///
/// Path separators, `..`, control characters and leading dots are removed, the
/// result is length-capped (filesystem limit is 255 bytes, and multi-byte names
/// reach it sooner than they look), and an empty result becomes "document".
/// The extension is preserved when there is one, because consumers sniff it.
private func sanitizedFilename(_ name: String) -> String {
  let base = (name as NSString).lastPathComponent
  var allowed = CharacterSet.alphanumerics
  allowed.insert(charactersIn: ".-_ ")
  var cleaned = String(
    String.UnicodeScalarView(base.unicodeScalars.filter { allowed.contains($0) })
  )
  while cleaned.hasPrefix(".") { cleaned.removeFirst() }
  cleaned = cleaned.replacingOccurrences(of: "..", with: ".")
  cleaned = cleaned.trimmingCharacters(in: .whitespaces)
  if cleaned.isEmpty { return "document" }

  let maxBytes = 200
  guard cleaned.utf8.count > maxBytes else { return cleaned }
  let url = URL(fileURLWithPath: cleaned)
  let ext = url.pathExtension
  var stem = url.deletingPathExtension().lastPathComponent
  while stem.utf8.count + ext.utf8.count + 1 > maxBytes, !stem.isEmpty {
    stem.removeLast()
  }
  if stem.isEmpty { stem = "document" }
  return ext.isEmpty ? stem : "\(stem).\(ext)"
}

/// A fresh, collision-free directory inside the cache, and the file path in it.
///
/// Each copy gets its own numbered directory, so two documents that share a
/// display name cannot overwrite one another and the user-visible filename is
/// preserved exactly.
private func uniqueCacheDestination(for name: String) throws -> URL {
  let caches = try FileManager.default.url(
    for: .cachesDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
  )
  let directory = caches
    .appendingPathComponent(cacheSubdirectory, isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  return directory.appendingPathComponent(sanitizedFilename(name))
}

// MARK: - Picker presentation

private final class DNFilePickerHostController: UIViewController {
  var onDismissed: (() -> Void)?

  override func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
    super.dismiss(animated: animated) {
      completion?()
      self.onDismissed?()
    }
  }
}

/// The window scene the app is showing on.
private func activeWindowScene() -> UIWindowScene? {
  let scenes = UIApplication.shared.connectedScenes.compactMap {
    $0 as? UIWindowScene
  }
  return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
}

/// Holds the picker, its delegate and its window alive, and guarantees exactly
/// one completion.
///
/// A `UIDocumentPickerViewController` keeps only a weak reference to its
/// delegate, so without this object the delegate would be deallocated before
/// the user finished choosing and the callback would never arrive. The class is
/// retained by `activePresentation` for exactly as long as the picker is up.
private final class DNFilePickerPresentation: NSObject,
  UIDocumentPickerDelegate
{
  private let token: Int64
  private let request: PickRequest
  private var window: UIWindow?
  private var host: DNFilePickerHostController?
  private var finished = false
  /// Whether a delegate method has already spoken for this pick.
  ///
  /// Set synchronously in both delegate callbacks, before any async work.
  /// UIKit forwards the picker's dismissal to its PRESENTING controller,
  /// which is our host, so `onDismissed` fires on a successful pick too —
  /// and it would otherwise race the background metadata resolution and
  /// report a cancellation for a document the user actually chose.
  private var delegateReported = false

  init(token: Int64, request: PickRequest) {
    self.token = token
    self.request = request
  }

  /// Presents the picker. Returns false when there is nowhere to present it.
  func present() -> Bool {
    guard let scene = activeWindowScene() else { return false }
    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }

    let host = DNFilePickerHostController()
    host.view.backgroundColor = .clear
    let window = UIWindow(windowScene: scene)
    window.backgroundColor = .clear
    window.windowLevel = .normal + 1
    window.rootViewController = host
    window.makeKeyAndVisible()
    self.window = window
    self.host = host

    host.onDismissed = { [weak self] in
      // Only a dismissal that NO delegate method spoke for is a cancellation:
      // the app dismissing our host programmatically, or UIKit tearing it down.
      // A normal pick or a tapped Cancel has already reported through the
      // delegate, and must not be overwritten here.
      DispatchQueue.main.async {
        guard let self = self, !self.delegateReported else { return }
        self.complete(cancelled: true)
      }
      previousKeyWindow?.makeKey()
    }

    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: request.contentTypes,
      asCopy: request.copyToCache
    )
    picker.delegate = self
    picker.allowsMultipleSelection = request.allowMultiple
    picker.shouldShowFileExtensions = true
    host.present(picker, animated: true)
    return true
  }

  // MARK: UIDocumentPickerDelegate

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    delegateReported = true
    // Resolve off the main thread: a copy-mode pick moves bytes, and metadata
    // for an iCloud item can touch the disk.
    let request = self.request
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      var records: [[String: Any]] = []
      for url in urls {
        records.append(self.record(for: url, request: request))
      }
      DispatchQueue.main.async { self.complete(records: records) }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    delegateReported = true
    complete(cancelled: true)
  }

  // MARK: Completion — success, cancellation and failure converge here

  private func record(for url: URL, request: PickRequest) -> [String: Any] {
    if request.copyToCache {
      // asCopy: true already handed us a file we own, in a temporary location
      // the system may reclaim. Move it into our cache so the path we report
      // has the documented lifetime.
      do {
        let destination = try uniqueCacheDestination(for: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        registerPickedURL(destination)
        return fileRecord(
          for: destination,
          persisted: false,
          appOwnedPath: destination.path
        )
      } catch {
        dnLog("moving the picked copy into the cache failed: \(error)")
        // The system copy is still readable where it is; report that instead of
        // failing the whole pick.
        return fileRecord(for: url, persisted: false, appOwnedPath: url.path)
      }
    }
    // Reference mode. Retain the instance: its security scope is the only thing
    // that makes a later read of a document outside our container possible.
    registerPickedURL(url)
    // Persist only if asked: a bookmark is the only way a file URL survives a
    // restart with its security scope intact.
    let persisted = request.persistAccess ? persistBookmark(for: url) : false
    return fileRecord(for: url, persisted: persisted)
  }

  private func complete(records: [[String: Any]] = [], cancelled: Bool = false) {
    guard !finished else { return }
    finished = true
    tearDown()
    if cancelled {
      fireJson(token, jsonString(["files": []]))
    } else {
      fireJson(token, jsonString(["files": records]))
    }
    activePresentation = nil
  }

  private func tearDown() {
    host?.onDismissed = nil
    window?.isHidden = true
    window?.rootViewController = nil
    window = nil
    host = nil
  }

  /// Drops the presentation without delivering anything (hot restart).
  func abandon() {
    finished = true
    tearDown()
  }
}

/// The picker currently on screen. Also the concurrency guard: the Dart side
/// refuses a second pick, and this is the backstop if one ever gets through.
private var activePresentation: DNFilePickerPresentation?

// MARK: - Read sessions

/// One open document being streamed to Dart.
///
/// Owns the security scope and the file handle for its whole life, and does its
/// I/O on a private serial queue so a multi-gigabyte read never touches the main
/// thread. Chunks are read strictly on demand: Dart asks for the next one only
/// after it has taken the previous one, so a slow consumer slows the read
/// instead of filling memory.
private final class DNReadSession {
  let handle: FileHandle
  let url: URL
  let scoped: Bool
  let queue: DispatchQueue

  init(handle: FileHandle, url: URL, scoped: Bool, id: Int64) {
    self.handle = handle
    self.url = url
    self.scoped = scoped
    queue = DispatchQueue(label: "com.dartnative.file_picker.read.\(id)")
  }

  func close() {
    try? handle.close()
    if scoped { url.stopAccessingSecurityScopedResource() }
  }
}

private let sessionLock = NSLock()
private var readSessions: [Int64: DNReadSession] = [:]
private var nextSessionId: Int64 = 1

private func session(_ id: Int64) -> DNReadSession? {
  sessionLock.lock()
  defer { sessionLock.unlock() }
  return readSessions[id]
}

// MARK: - FFI entry points

/// Clears state left behind by a previous Dart isolate (hot restart).
///
/// Native code is not restarted with Dart: a picker can still be on screen and
/// read handles can still be open. Dart calls this from `loadSymbols()` before
/// handing over a new dispatcher.
@_cdecl("DNFilePickerReset")
public func DNFilePickerReset() {
  sessionLock.lock()
  let sessions = readSessions
  readSessions.removeAll()
  sessionLock.unlock()
  for session in sessions.values { session.close() }

  pickedURLLock.lock()
  pickedURLs.removeAll()
  pickedURLLock.unlock()

  let present = {
    activePresentation?.abandon()
    activePresentation = nil
  }
  if Thread.isMainThread { present() } else { DispatchQueue.main.sync(execute: present) }
}

/// Presents the document picker. Replies with `{"files":[…]}`; an empty list is
/// a cancellation.
@_cdecl("DNFilePickerPick")
public func DNFilePickerPick(
  _ token: Int64,
  _ requestJson: UnsafePointer<CChar>?
) {
  guard let json = cString(requestJson), let request = PickRequest(json: json)
  else {
    fireError(token, DNErr.nativeFailure, "The pick request could not be parsed.")
    return
  }

  DispatchQueue.main.async {
    guard activePresentation == nil else {
      fireError(
        token,
        DNErr.pickerBusy,
        "A document picker is already on screen."
      )
      return
    }
    if request.contentTypes.isEmpty {
      fireError(
        token,
        DNErr.unsupportedType,
        "No iOS content type matches the requested filter."
      )
      return
    }
    let presentation = DNFilePickerPresentation(token: token, request: request)
    activePresentation = presentation
    if !presentation.present() {
      activePresentation = nil
      fireError(
        token,
        DNErr.noPresentationContext,
        "No foreground window scene is available to present the picker from."
      )
    }
  }
}

/// Opens a document for reading. Replies with `{"handle":<id>}`.
@_cdecl("DNFilePickerOpen")
public func DNFilePickerOpen(_ token: Int64, _ uri: UnsafePointer<CChar>?) {
  guard let uriString = cString(uri), let url = resolveURL(uriString) else {
    fireError(token, DNErr.readFailed, "The document reference is not a readable file URL.")
    return
  }

  DispatchQueue.global(qos: .userInitiated).async {
    let scoped = url.startAccessingSecurityScopedResource()
    var opened: FileHandle?
    var failure: Error?

    // Coordinate the read so an iCloud item that is not on the device yet is
    // materialized before the handle is opened. The handle outlives the
    // coordination block, which is the supported way to stream a coordinated
    // document without holding the lock for the whole read.
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(
      readingItemAt: url,
      options: [],
      error: &coordinationError
    ) { readURL in
      do {
        opened = try FileHandle(forReadingFrom: readURL)
      } catch {
        failure = error
      }
    }

    guard let handle = opened else {
      if scoped { url.stopAccessingSecurityScopedResource() }
      let error = failure ?? coordinationError
      let code = error.map { mappedCode($0, fallback: DNErr.readFailed) }
        ?? DNErr.readFailed
      fireError(
        token,
        code,
        "The document could not be opened for reading.",
        nativeCode: error.map(nsErrorCode)
      )
      return
    }

    sessionLock.lock()
    let id = nextSessionId
    nextSessionId += 1
    readSessions[id] = DNReadSession(
      handle: handle,
      url: url,
      scoped: scoped,
      id: id
    )
    sessionLock.unlock()

    fireJson(token, jsonString(["handle": id]))
  }
}

/// Reads up to `chunkSize` bytes. Replies with a chunk, or EOF, or an error.
@_cdecl("DNFilePickerReadNext")
public func DNFilePickerReadNext(
  _ token: Int64,
  _ handle: Int64,
  _ chunkSize: Int32
) {
  guard let session = session(handle) else {
    fireError(token, DNErr.readFailed, "The read handle is no longer open.")
    return
  }
  let size = Int(max(chunkSize, 1))
  session.queue.async {
    do {
      let data = try session.handle.read(upToCount: size)
      if let data = data, !data.isEmpty {
        fireChunk(token, data)
      } else {
        fireEof(token)
      }
    } catch {
      fireError(
        token,
        mappedCode(error, fallback: DNErr.readFailed),
        "Reading the document failed.",
        nativeCode: nsErrorCode(error)
      )
    }
  }
}

/// Closes a read handle and releases its security scope. Idempotent.
@_cdecl("DNFilePickerClose")
public func DNFilePickerClose(_ handle: Int64) {
  sessionLock.lock()
  let session = readSessions.removeValue(forKey: handle)
  sessionLock.unlock()
  session?.close()
}

/// Streams the document into the cache. Replies with `{"path":"…"}`.
@_cdecl("DNFilePickerCopyToCache")
public func DNFilePickerCopyToCache(
  _ token: Int64,
  _ uri: UnsafePointer<CChar>?,
  _ preferredName: UnsafePointer<CChar>?
) {
  guard let uriString = cString(uri), let url = resolveURL(uriString) else {
    fireError(token, DNErr.copyFailed, "The document reference is not a readable file URL.")
    return
  }
  let name = cString(preferredName) ?? url.lastPathComponent

  DispatchQueue.global(qos: .userInitiated).async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    var destination: URL?
    do {
      let target = try uniqueCacheDestination(for: name)
      destination = target

      var coordinationError: NSError?
      var copyError: Error?
      NSFileCoordinator().coordinate(
        readingItemAt: url,
        options: [],
        error: &coordinationError
      ) { readURL in
        do {
          // FileManager.copyItem streams; it does not read the file into memory,
          // so a multi-gigabyte document copies in constant memory.
          try FileManager.default.copyItem(at: readURL, to: target)
        } catch {
          copyError = error
        }
      }
      if let error = copyError ?? coordinationError { throw error }

      guard FileManager.default.fileExists(atPath: target.path) else {
        throw NSError(
          domain: NSCocoaErrorDomain,
          code: NSFileWriteUnknownError,
          userInfo: [NSLocalizedDescriptionKey: "the copy did not appear"]
        )
      }
      fireJson(token, jsonString(["path": target.path]))
    } catch {
      // Never leave a truncated file behind for a caller to misread as complete.
      if let destination = destination {
        try? FileManager.default.removeItem(
          at: destination.deletingLastPathComponent()
        )
      }
      fireError(
        token,
        mappedCode(error, fallback: DNErr.copyFailed),
        "Copying the document into the cache failed.",
        nativeCode: nsErrorCode(error)
      )
    }
  }
}

/// Drops a stored bookmark. Replies with `{"released":true|false}`.
@_cdecl("DNFilePickerRelease")
public func DNFilePickerRelease(_ token: Int64, _ uri: UnsafePointer<CChar>?) {
  guard let uriString = cString(uri) else {
    fireError(token, DNErr.persistenceFailed, "No document reference was given.")
    return
  }
  let released = removeBookmark(for: uriString)
  fireJson(token, jsonString(["released": released]))
}

/// Resolves a previously persisted document. Replies with `{"files":[…]}`,
/// an empty list when there is no usable bookmark for it.
@_cdecl("DNFilePickerResolve")
public func DNFilePickerResolve(_ token: Int64, _ uri: UnsafePointer<CChar>?) {
  guard let uriString = cString(uri) else {
    fireJson(token, jsonString(["files": []]))
    return
  }
  DispatchQueue.global(qos: .userInitiated).async {
    guard let url = resolveBookmark(uriString) else {
      fireJson(token, jsonString(["files": []]))
      return
    }
    // A bookmark can resolve to a document that has since been deleted.
    let scoped = url.startAccessingSecurityScopedResource()
    let exists = FileManager.default.fileExists(atPath: url.path)
    if scoped { url.stopAccessingSecurityScopedResource() }
    guard exists else {
      fireJson(token, jsonString(["files": []]))
      return
    }
    // Metadata comes from the RESOLVED url, so `name` and `size` describe the
    // document as it is now, but the reported `uri` is the key the caller passed
    // in — deliberately, and this is load-bearing.
    //
    // A bookmark tracks a document by identity, so after the user renames or
    // moves it the resolved url differs from the stored key. Reporting that new
    // url would hand the caller a reference that nothing can use: the bookmark
    // store is keyed by the ORIGINAL uri, so `resolveURL` would miss it, fall
    // back to a plain file URL with no security scope, and every later read fail
    // with accessDenied while `releasePersistedAccess` silently left the grant in
    // place. Observed on device: a renamed iCloud document resolved but then
    // failed to read.
    //
    // Keeping the caller's uri as the identity makes every later call — read,
    // stream, copy, release — route back through the bookmark, and matches
    // Android, where a content:// uri does not change when a document is renamed.
    var record = fileRecord(for: url, persisted: true)
    record["uri"] = uriString
    fireJson(token, jsonString(["files": [record]]))
  }
}
