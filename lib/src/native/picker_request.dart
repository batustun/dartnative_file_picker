/// The Dart to native request envelope.
///
/// Pure Dart and pure data: building a request performs no I/O and touches no
/// FFI, so every validation and widening rule below is unit-testable.
library;

import 'dart:convert';

import '../exceptions.dart';
import '../file_picker_options.dart';
import '../file_type.dart';
import '../filters/extension_filter.dart';
import '../filters/mime_types.dart';

/// A validated, fully resolved picker request ready to cross to native code.
///
/// Build it with [PickerRequest.build], which is where every argument rule is
/// enforced. The constructor is private precisely so an unvalidated request
/// cannot exist.
final class PickerRequest {
  const PickerRequest._({
    required this.type,
    required this.extensions,
    required this.mimeTypes,
    required this.unresolvedExtensions,
    required this.allowMultiple,
    required this.options,
  });

  /// Builds and validates a request.
  ///
  /// Throws a [FilePickerException] with [FilePickerErrorCode.invalidFilter]
  /// when:
  ///
  /// - [type] is [FileType.custom] and [allowedExtensions] is null or empty;
  /// - any extension is malformed (see [normalizeExtensions]).
  ///
  /// When [type] is **not** [FileType.custom], [allowedExtensions] is
  /// deliberately **ignored** rather than rejected or quietly combined. The two
  /// filters describe different things — a broad category versus an exact list
  /// — and no platform picker can express "images, but only PDFs". Silently
  /// intersecting them would produce an empty picker; silently preferring one
  /// would be a guess. The caller gets the category they named, and
  /// [ignoredExtensions] records what was dropped so the API can say so.
  factory PickerRequest.build({
    required FileType type,
    required bool allowMultiple,
    List<String>? allowedExtensions,
    FilePickerOptions options = const FilePickerOptions(),
  }) {
    if (type != FileType.custom) {
      return PickerRequest._(
        type: type,
        extensions: const <String>[],
        mimeTypes: const <String>[],
        unresolvedExtensions: const <String>[],
        allowMultiple: allowMultiple,
        options: options,
      );
    }

    if (allowedExtensions == null) {
      throw const FilePickerException(
        FilePickerErrorCode.invalidFilter,
        'FileType.custom requires allowedExtensions. Pass the extensions you '
        "accept, for example allowedExtensions: ['pdf', 'xlsx'], or use a "
        'broader FileType.',
      );
    }

    final normalized = normalizeExtensions(allowedExtensions);
    final resolution = resolveMimeTypes(normalized.values);
    return PickerRequest._(
      type: type,
      extensions: normalized.values,
      mimeTypes: resolution.mimeTypes,
      unresolvedExtensions: resolution.unresolved,
      allowMultiple: allowMultiple,
      options: options,
    );
  }

  /// The requested document category.
  final FileType type;

  /// Normalized extensions, empty unless [type] is [FileType.custom].
  final List<String> extensions;

  /// MIME types resolved from [extensions], for the Android filter.
  final List<String> mimeTypes;

  /// Extensions with no known MIME type.
  ///
  /// Non-empty means the Android filter had to widen — see
  /// [androidFilterIsExact].
  final List<String> unresolvedExtensions;

  /// Whether the user may select more than one document.
  final bool allowMultiple;

  /// The access, persistence and locality options for this pick.
  final FilePickerOptions options;

  /// Extensions that were supplied but do not apply to [type].
  ///
  /// Always empty today: a non-custom [type] discards them at build time, and
  /// this getter exists so the public API can warn in an assertion rather than
  /// pretend the argument was used.
  List<String> get ignoredExtensions => const <String>[];

  /// Whether Android can express this filter exactly.
  ///
  /// `false` when at least one requested extension has no MIME type. The
  /// Android side then falls back to a wildcard rather than excluding the file
  /// the user came for, which means the picker shows more than was asked for
  /// and the selection must be checked against [extensions] by the caller if
  /// it matters. iOS is unaffected: it builds a dynamic Uniform Type
  /// Identifier straight from the extension.
  bool get androidFilterIsExact =>
      type != FileType.custom || unresolvedExtensions.isEmpty;

  /// The request as the UTF-8 JSON the native side parses.
  String toJson() => jsonEncode(<String, Object?>{
    'type': type.name,
    'extensions': extensions,
    'mimeTypes': mimeTypes,
    'unresolvedExtensions': unresolvedExtensions,
    'allowMultiple': allowMultiple,
    'accessMode': options.accessMode.name,
    'persistAccess': options.persistAccess,
    'localOnly': options.localOnly,
  });

  @override
  String toString() =>
      'PickerRequest(${type.name}, extensions: $extensions, '
      'allowMultiple: $allowMultiple, $options)';
}
