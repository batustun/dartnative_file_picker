/// The public entry point for presenting the system document picker.
library;

import 'dart:async';

import 'exceptions.dart';
import 'file_picker_options.dart';
import 'file_type.dart';
import 'filters/selection_filter.dart';
import 'native/file_picker_ffi_bindings.dart';
import 'native/picker_request.dart';
import 'native/resource_gateway.dart';
import 'platform_file.dart';

/// Presents the operating system's own document picker.
///
/// `UIDocumentPickerViewController` on iOS, `Intent.ACTION_OPEN_DOCUMENT` —
/// the Storage Access Framework — on Android. The UI belongs to the OS: this
/// package draws nothing, uploads nothing, and asks for no storage permission.
///
/// ```dart
/// final file = await FilePicker.pickFile();
/// if (file == null) return;            // the user closed the picker
/// print('${file.name} at ${file.uri}');
/// ```
///
/// ## Cancellation is not an error
///
/// Closing the picker is something users do on purpose, so it is reported as
/// `null` from [pickFile] and as an empty list from [pickFiles] — never as a
/// thrown exception. Exceptions are reserved for things that are actually
/// wrong; see [FilePickerErrorCode].
///
/// ## One picker at a time
///
/// Two overlapping calls would stack two system pickers, which neither platform
/// handles sensibly. The second call therefore fails immediately with
/// [FilePickerErrorCode.pickerBusy] rather than queueing behind the first or
/// presenting on top of it. The guard clears on every outcome — success,
/// cancellation, native error — so a failed pick never wedges the picker shut.
abstract final class FilePicker {
  /// The in-flight pick, or `null` when the picker is idle.
  ///
  /// A single future rather than a boolean, so the state cannot be left set by
  /// a path that forgot to clear it: it is assigned once and cleared in a
  /// `finally`.
  static Future<List<PlatformFile>>? _inFlight;

  /// Whether a picker is currently presented.
  ///
  /// Useful for disabling a button. Do not use it to decide whether to call
  /// [pickFile] — between the check and the call the state can change, and the
  /// call reports [FilePickerErrorCode.pickerBusy] anyway.
  static bool get isPresenting => _inFlight != null;

  /// Presents the picker for a single document.
  ///
  /// Returns the chosen document, or `null` if the user closed the picker
  /// without choosing one.
  ///
  /// [type] narrows what the picker offers; with [FileType.custom], pass the
  /// extensions you accept in [allowedExtensions]. [options] controls whether
  /// the document is referenced or copied, whether access is persisted, and
  /// whether cloud providers are offered — see [FilePickerOptions].
  ///
  /// ```dart
  /// final sheet = await FilePicker.pickFile(
  ///   type: FileType.custom,
  ///   allowedExtensions: ['xlsx', 'csv'],
  /// );
  /// ```
  ///
  /// Extensions are normalized before use: `'.PDF'`, `'pdf'` and `' pdf '` are
  /// the same filter, and duplicates collapse.
  ///
  /// Throws a [FilePickerException] with:
  ///
  /// - [FilePickerErrorCode.invalidFilter] for an unusable filter — a
  ///   [FileType.custom] request without extensions, or a malformed extension.
  ///   Thrown before the picker is presented;
  /// - [FilePickerErrorCode.pickerBusy] if a picker is already on screen;
  /// - [FilePickerErrorCode.noPresentationContext] if the app has no
  ///   foreground UI to present from;
  /// - [FilePickerErrorCode.accessDenied] if the chosen document could not be
  ///   opened for reading.
  ///
  /// [allowedExtensions] is ignored unless [type] is [FileType.custom]: no
  /// platform picker can express "images, but only PDFs", and guessing which
  /// half of a contradiction to honour would be worse than documenting it. An
  /// assertion fires in debug builds if you pass both.
  ///
  /// ## `allowedExtensions` is enforced, not merely requested
  ///
  /// The platform picker's filter is a hint. Android cannot express an extension
  /// with no known MIME type and widens to a wildcard rather than hiding your
  /// file, and a provider's MIME types are not reliable even when it can. So the
  /// filter is also checked after selection, against each document's filename:
  ///
  /// * documents whose extension is not in [allowedExtensions] are **dropped**;
  /// * if that leaves nothing, a [FilePickerException] with
  ///   [FilePickerErrorCode.unsupportedType] is thrown, naming what was picked
  ///   and what is allowed, so you can tell the user rather than showing an
  ///   empty result that looks like a silent failure;
  /// * a document with no extension never satisfies a filter.
  ///
  /// The upshot: for a [FileType.custom] pick, every [PlatformFile.extension] you
  /// receive is one you asked for, on both platforms and against every provider.
  /// With [pickFiles] a partially valid selection returns the valid subset, so
  /// compare the length if that matters to you.
  ///
  /// This cannot be done for [FileType.image], [FileType.video] or
  /// [FileType.audio]: those are categories, and the authority on what counts as
  /// an image is the platform, not a list of extensions this package made up.
  static Future<PlatformFile?> pickFile({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    FilePickerOptions options = const FilePickerOptions(),
  }) async {
    final files = await _present(
      type: type,
      allowedExtensions: allowedExtensions,
      options: options,
      allowMultiple: false,
    );
    return files.isEmpty ? null : files.first;
  }

  /// Presents the picker for any number of documents.
  ///
  /// Returns the chosen documents in the order the platform reported them, or
  /// an empty list if the user closed the picker without choosing any.
  ///
  /// ```dart
  /// final images = await FilePicker.pickFiles(type: FileType.image);
  /// for (final image in images) {
  ///   await upload(image.readAsByteStream());
  /// }
  /// ```
  ///
  /// The same document selected twice arrives twice: the platform permits it
  /// and silently collapsing duplicates would misreport what the user did.
  /// De-duplicate on [PlatformFile.uri] if that matters to you.
  ///
  /// Throws the same exceptions as [pickFile], for the same reasons.
  ///
  /// Like [pickFile], every failure — including argument validation — arrives as
  /// an error on the returned [Future] rather than as a synchronous throw, so
  /// one `try`/`await` or one `catchError` handles all of them.
  static Future<List<PlatformFile>> pickFiles({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    FilePickerOptions options = const FilePickerOptions(),
  }) async => _present(
    type: type,
    allowedExtensions: allowedExtensions,
    options: options,
    allowMultiple: true,
  );

  /// Reopens a document this app persisted access to in an earlier session.
  ///
  /// This is the other half of [FilePickerOptions.persistAccess]: persisting
  /// access is only useful if the document can be reached again after a restart,
  /// and a [PlatformFile] cannot otherwise be obtained without presenting the
  /// picker. Store [PlatformFile.uri] yourself (it is a plain string), then pass
  /// it back here on the next launch.
  ///
  /// ```dart
  /// final saved = prefs.getString('watched_document');
  /// final file = saved == null
  ///     ? null
  ///     : await FilePicker.openPersisted(Uri.parse(saved));
  /// if (file == null) {
  ///   // The grant or the document is gone. Ask the user to pick again.
  /// }
  /// ```
  ///
  /// Returns `null` — rather than throwing — whenever the document cannot be
  /// reopened, because every reason for that is ordinary and outside your
  /// control: the user revoked the grant, deleted the document, uninstalled the
  /// provider, or [PlatformFile.releasePersistedAccess] was called. Treat `null`
  /// as "ask the user to pick it again".
  ///
  /// - **Android** checks the app's persisted URI permissions and confirms the
  ///   document can still be opened.
  /// - **iOS** resolves the security-scoped bookmark, refreshing it when the
  ///   system reports it stale (the document moved), and confirms the file is
  ///   still there.
  ///
  /// ## The returned [PlatformFile.uri] is the [uri] you passed in
  ///
  /// Even when the document has been renamed or moved. A bookmark tracks a
  /// document by identity, not by path, so iOS can still find it — and
  /// [PlatformFile.name] and [PlatformFile.size] describe it as it is *now*,
  /// which is how you detect that it moved.
  ///
  /// The URI stays your stable handle on purpose: it is the key the persisted
  /// grant is stored under, so it is what every later [PlatformFile.readAsBytes],
  /// [PlatformFile.copyToCache] and [PlatformFile.releasePersistedAccess] needs
  /// in order to find that grant. Keep storing the same string; there is nothing
  /// to update after a rename. On Android the question does not arise, because a
  /// `content://` URI does not change when a document is renamed.
  ///
  /// Does not present any UI and does not take the one-picker-at-a-time guard.
  static Future<PlatformFile?> openPersisted(Uri uri) async {
    final outcome = await FilePickerFFIBindings.resolvePersisted(uri);
    if (outcome.files.isEmpty) return null;
    return PlatformFile.fromRecord(
      outcome.files.first,
      FilePickerFFIBindings.instance,
    );
  }

  static Future<List<PlatformFile>> _present({
    required FileType type,
    required List<String>? allowedExtensions,
    required FilePickerOptions options,
    required bool allowMultiple,
  }) {
    assert(
      type == FileType.custom ||
          allowedExtensions == null ||
          allowedExtensions.isEmpty,
      'allowedExtensions only applies to FileType.custom; it is ignored for '
      'FileType.${type.name}. Pass FileType.custom to filter by extension.',
    );

    // Validate and resolve the filter BEFORE taking the busy guard: a request
    // that was never presentable must not make the picker look busy.
    final request = PickerRequest.build(
      type: type,
      allowMultiple: allowMultiple,
      allowedExtensions: allowedExtensions,
      options: options,
    );

    if (_inFlight != null) {
      throw const FilePickerException(
        FilePickerErrorCode.pickerBusy,
        'A document picker is already on screen. Await the first pick before '
        'starting another one.',
      );
    }

    final pending = _run(request);
    _inFlight = pending;
    return pending;
  }

  /// Verifies the native side honoured [FilePickerAccessMode.copyToCache].
  ///
  /// That mode's whole purpose is that [PlatformFile.path] is non-null, and
  /// callers are documented to rely on it. A missing path would mean the native
  /// side reported a copy it did not make, so it is a contract violation rather
  /// than a condition to paper over with a null check at every call site.
  static void _assertCopyContract(PickerRequest request, PlatformFile file) {
    if (request.options.accessMode != FilePickerAccessMode.copyToCache) return;
    if (file.path != null) return;
    throw FilePickerException(
      FilePickerErrorCode.copyFailed,
      'The native side returned "${file.name}" without a path despite '
      'accessMode: copyToCache. This is a bug in dartnative_file_picker; '
      'please report it with the platform and OS version.',
    );
  }

  static Future<List<PlatformFile>> _run(PickerRequest request) async {
    try {
      final outcome = await FilePickerFFIBindings.pick(request.toJson());
      if (outcome.cancelled) return const <PlatformFile>[];

      // Enforce the extension filter against the filenames, because the
      // platform picker's own filter is only a hint: Android widens to a
      // wildcard for an extension with no known MIME type, and a provider's
      // MIME types are not reliable even when it does not. Without this,
      // allowedExtensions would mean "whatever the picker happened to show".
      final selection = enforceExtensions(outcome.files, request.extensions);
      if (selection.accepted.isEmpty && selection.rejected.isNotEmpty) {
        // The user chose something, and none of it qualifies. Returning an empty
        // list here would be indistinguishable from a cancellation and would
        // look like the picker silently did nothing, so this is an error the app
        // can show: "that file type is not accepted".
        throw FilePickerException(
          FilePickerErrorCode.unsupportedType,
          'The selected document does not match allowedExtensions. '
          'Allowed: ${request.extensions.join(', ')}. '
          'Selected: ${selection.rejected.join(', ')}.',
        );
      }

      final FileResourceGateway gateway = FilePickerFFIBindings.instance;
      final files = <PlatformFile>[];
      for (final record in selection.accepted) {
        final file = PlatformFile.fromRecord(record, gateway);
        _assertCopyContract(request, file);
        files.add(file);
      }
      return List<PlatformFile>.unmodifiable(files);
    } finally {
      // Cleared on every path — result, cancellation, native error, and an
      // exception thrown while decoding the reply.
      _inFlight = null;
    }
  }
}
