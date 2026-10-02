/// The typed error model for document picking.
library;

/// Why a file-picker operation failed.
///
/// User cancellation is **not** in this list: closing the picker is a normal
/// outcome and is reported as `null` or an empty list, never as an error.
enum FilePickerErrorCode {
  /// A picker is already on screen.
  ///
  /// Only one system picker may be presented at a time, so a second
  /// concurrent call fails immediately rather than stacking native UI. Wait
  /// for the first [Future] to complete and try again.
  pickerBusy,

  /// The arguments could not describe a valid filter.
  ///
  /// Raised before any native call: `FileType.custom` without
  /// `allowedExtensions`, an extension that is not alphanumeric, an empty
  /// extension list after normalization, or a non-positive `chunkSize`.
  invalidFilter,

  /// The platform cannot offer the requested type of document.
  ///
  /// Raised when the requested filter has no representation on the running
  /// OS version.
  unsupportedType,

  /// The resource exists but this app may not read it.
  ///
  /// Typically a `content://` permission grant that was revoked, or an iOS
  /// security-scoped resource whose scope could not be acquired. On Android
  /// this is the mapped form of `SecurityException`.
  accessDenied,

  /// The document provider is not reachable.
  ///
  /// A cloud provider that is offline or has been uninstalled, or a
  /// `ContentResolver` that returned no provider for the authority. The
  /// document may well come back later — this is not necessarily permanent.
  providerUnavailable,

  /// Reading the document's bytes failed partway through.
  ///
  /// Includes a document deleted after selection, a cancelled cloud download
  /// and an I/O error from the provider.
  readFailed,

  /// Copying the document into app-owned storage failed.
  ///
  /// The partial copy has already been deleted when this is thrown, so no
  /// truncated file is left in the cache.
  copyFailed,

  /// Persisted access could not be taken, or could not be given back.
  ///
  /// On Android the provider did not grant
  /// `FLAG_GRANT_PERSISTABLE_URI_PERMISSION`; on iOS the security-scoped
  /// bookmark could not be created or had gone stale beyond recovery.
  persistenceFailed,

  /// The native side failed in a way that has no more specific code.
  ///
  /// [FilePickerException.nativeCode] carries the platform detail when one
  /// was available.
  nativeFailure,

  /// There was no foreground UI to present the picker from.
  ///
  /// On iOS no `UIWindowScene` was available; on Android the proxy activity
  /// could not be started. Usually means the call was made while the app was
  /// in the background.
  noPresentationContext,
}

/// Thrown when a file-picker operation fails.
///
/// Cancellation never throws. See [FilePickerErrorCode] for what each [code]
/// means and [FilePicker.pickFile] for the full contract.
///
/// ```dart
/// try {
///   final file = await FilePicker.pickFile(
///     type: FileType.custom,
///     allowedExtensions: ['pdf'],
///   );
/// } on FilePickerException catch (e) {
///   if (e.code == FilePickerErrorCode.pickerBusy) return;
///   report(e.message, e.nativeCode);
/// }
/// ```
final class FilePickerException implements Exception {
  /// Creates an exception with a stable [code] and a human-readable [message].
  const FilePickerException(this.code, this.message, {this.nativeCode});

  /// What went wrong, as a value you can branch on.
  ///
  /// This is the stable part of the contract: switch on [code], not on
  /// [message] or [nativeCode].
  final FilePickerErrorCode code;

  /// A developer-facing explanation.
  ///
  /// Written for a log or a bug report, not for an end user, and not
  /// localized. Its wording may change between releases.
  final String message;

  /// The underlying platform detail, when native code supplied one.
  ///
  /// For example an `NSError` domain and code, or the simple name of a Java
  /// exception such as `FileNotFoundException`. Useful in a bug report;
  /// **unstable**, so never branch on it.
  final String? nativeCode;

  @override
  String toString() {
    final native = nativeCode == null ? '' : ' (native: $nativeCode)';
    return 'FilePickerException(${code.name}): $message$native';
  }
}
