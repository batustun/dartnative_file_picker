/// The kind of document the picker should offer.
library;

/// Which documents the picker lets the user choose.
///
/// The value is translated into a platform filter: Uniform Type Identifiers
/// passed to `UIDocumentPickerViewController` on iOS, and
/// `Intent.setType` + `Intent.EXTRA_MIME_TYPES` on Android.
///
/// Filtering is a *hint to the system picker*, not a security boundary. A
/// document provider is free to offer whatever it likes, so always validate
/// what you receive — see [FilePicker.pickFile] for the guarantees that do
/// hold.
enum FileType {
  /// Every document the providers can offer.
  ///
  /// iOS: `UTType.item`. Android: `*/*`.
  any,

  /// Still images, for example JPEG, PNG, HEIC, GIF, WebP.
  ///
  /// iOS: `UTType.image`. Android: `image/*`.
  ///
  /// For photos and videos out of the user's photo library, the first-party
  /// `dartnative_media_picker` is the better tool — it uses `PHPicker` and the
  /// Android Photo Picker, which need no permission and are built for media.
  /// Use [image] here when you want the *document* browser (Files, Drive,
  /// Downloads) rather than the photo library.
  image,

  /// Movies, for example MP4, MOV, M4V.
  ///
  /// iOS: `UTType.movie`. Android: `video/*`.
  video,

  /// Sound files, for example MP3, M4A, WAV, AAC.
  ///
  /// iOS: `UTType.audio`. Android: `audio/*`.
  audio,

  /// Only the extensions listed in `allowedExtensions`.
  ///
  /// `allowedExtensions` is required and must be non-empty for this value;
  /// anything else throws a [FilePickerException] with
  /// [FilePickerErrorCode.invalidFilter] before the picker is presented.
  custom,
}
