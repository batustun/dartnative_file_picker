/// dartnative_file_picker — the native document picker for DartNative apps.
///
/// Presents the operating system's own document browser over FFI:
/// `UIDocumentPickerViewController` on iOS, `Intent.ACTION_OPEN_DOCUMENT` (the
/// Storage Access Framework) on Android. No Flutter platform channels, no
/// storage permissions, and no filesystem paths invented for documents that do
/// not have one.
///
/// ```dart
/// import 'package:dartnative_file_picker/dartnative_file_picker.dart';
///
/// final file = await FilePicker.pickFile(
///   type: FileType.custom,
///   allowedExtensions: ['pdf'],
/// );
/// if (file != null) {
///   await for (final chunk in file.readAsByteStream()) {
///     sink.add(chunk);
///   }
/// }
/// ```
///
/// Start at [FilePicker]; the result model is [PlatformFile], and the thing to
/// understand about it is that [PlatformFile.uri] is the document's identity
/// while [PlatformFile.path] is often `null`. Failures are
/// [FilePickerException]s carrying a [FilePickerErrorCode]; user cancellation is
/// not one of them.
library;

export 'src/exceptions.dart';
export 'src/file_picker.dart';
export 'src/file_picker_options.dart';
export 'src/file_type.dart';
export 'src/native/file_picker_ffi_bindings.dart' show FilePickerFFIBindings;
export 'src/platform_file.dart' show PlatformFile, defaultChunkSize;
