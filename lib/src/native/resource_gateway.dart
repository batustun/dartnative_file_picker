/// The boundary between the document model and the native implementation.
library;

import 'dart:typed_data';

/// Everything [PlatformFile] needs from the platform, and nothing more.
///
/// [PlatformFile] depends on this interface rather than on the FFI bindings
/// directly, which keeps the model free of `dart:ffi` and makes its behaviour —
/// chunk-size validation, stream accumulation, no-op releases — testable on the
/// Dart VM with a fake.
///
/// Implemented by `FilePickerFFIBindings`. Not exported: an app has no reason to
/// implement it, and treating it as public API would freeze the wire protocol.
abstract interface class FileResourceGateway {
  /// Streams the document at [uri] in chunks of at most [chunkSize] bytes.
  ///
  /// The returned stream is single-subscription and lazily opened: nothing is
  /// read until it is listened to, and the native read handle is closed when the
  /// stream completes, is cancelled, or fails. [chunkSize] has already been
  /// validated by the caller.
  Stream<Uint8List> openRead(Uri uri, {required int chunkSize});

  /// Copies the document at [uri] into this app's cache directory.
  ///
  /// [preferredName] is a hint for the destination filename; the native side
  /// sanitizes it and guarantees a collision-free destination. Returns the
  /// absolute path of the finished copy.
  Future<String> copyToCache(Uri uri, {required String preferredName});

  /// Gives up previously persisted access to [uri].
  ///
  /// Returns whether the platform confirmed the release.
  Future<bool> releasePersistedAccess(Uri uri);
}
