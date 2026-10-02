/// Extension to MIME-type resolution for the Android filter.
///
/// The bulk of the work is done by `package:mime`, the Dart team's
/// BSD-3-Clause table — this package deliberately does not ship a large
/// hand-written mapping of its own. What lives here is only the short,
/// commented list of cases where the generic table is not the value an
/// Android `DocumentsProvider` matches against.
library;

import 'package:mime/mime.dart' show lookupMimeType;

/// Extensions `package:mime` does not resolve, filled in from the IANA registry.
///
/// Every entry needs two things: a verified gap in the generic table, and a
/// registered MIME type to fill it with. Guessing is worse than leaving a gap —
/// a wrong MIME type hides the user's file from the picker, while an unresolved
/// extension merely widens the filter (see [MimeResolution.unresolved]).
///
/// Deliberately short. The common document, image, audio and video extensions —
/// `pdf`, `csv`, `docx`, `xlsx`, `doc`, `jpg`, `png`, `heic`, `heif`, `avif`,
/// `webp`, `md`, `apk`, `zip`, `txt`, `mp3`, `mp4` — are all resolved correctly
/// by `package:mime` and are **not** duplicated here; the unit tests assert that
/// so this list cannot quietly rot into a shadow table.
const Map<String, String> _overrides = <String, String>{
  // RFC 9512 registered application/yaml in 2024; package:mime 2.1.0 still
  // answers null for both spellings.
  'yaml': 'application/yaml',
  'yml': 'application/yaml',
  // RFC 6713. package:mime answers null because it keys compound archive
  // extensions off the full '.tar.gz' form.
  'gz': 'application/gzip',
};

/// The MIME type an Android provider is expected to report for [extension],
/// or `null` when it cannot be resolved.
///
/// [extension] must already be normalized (lowercase, no leading dot) — see
/// `normalizeExtensions`.
///
/// A `null` result is meaningful rather than an error: it tells the Android
/// layer that this extension cannot be expressed as a MIME filter, so the
/// filter has to widen instead of excluding the file the user is looking for.
/// See `PickerRequest` for what that widening does.
String? mimeTypeForExtension(String extension) {
  final override = _overrides[extension];
  if (override != null) return override;
  // package:mime keys off a filename, so give it the cheapest possible one.
  return lookupMimeType('a.$extension');
}

/// Extra MIME spellings real document providers use for the same extension.
///
/// A filter is matched by `DocumentsUI` against the MIME type the *provider*
/// indexed the file under, as an exact string. So a single registered type is not
/// enough: if the provider disagrees about the spelling, the user's file is
/// simply **not shown**, which is the worst failure mode this package can have —
/// the caller asked for CSVs and the picker offers none.
///
/// Device-verified: Android's MediaStore reports a `.csv` file as
/// `text/comma-separated-values`, while `package:mime` and RFC 4180 say
/// `text/csv`. Observed on an API 34 emulator, where `allowedExtensions:
/// ['pdf','csv','xlsx','docx']` showed the PDF and **hid the CSV**.
///
/// The other entries are defensive rather than individually device-verified:
/// they are long-standing legacy spellings that providers and media scanners are
/// known to use. They are safe to add because over-showing cannot produce a wrong
/// result — `FilePicker` enforces `allowedExtensions` against the filename after
/// selection, so a surplus type costs the user one extra row in the picker, while
/// a missing one costs them the file.
const Map<String, List<String>> _aliases = <String, List<String>>{
  'csv': ['text/comma-separated-values'],
  'md': ['text/x-markdown'],
  'yaml': ['text/yaml', 'text/x-yaml'],
  'yml': ['text/yaml', 'text/x-yaml'],
  'zip': ['application/x-zip-compressed'],
  'rar': ['application/x-rar-compressed'],
  '7z': ['application/x-7z-compressed'],
  'gz': ['application/x-gzip'],
  'mp3': ['audio/mp3'],
  'm4a': ['audio/m4a', 'audio/x-m4a'],
  'wav': ['audio/x-wav', 'audio/vnd.wave'],
  'xls': ['application/vnd.ms-excel'],
  'js': ['application/javascript'],
  'txt': ['text/x-log'],
};

/// Every MIME type worth offering the picker for [extension].
///
/// The canonical type first, then any alias from [_aliases]. Empty when the
/// extension resolves to nothing at all.
List<String> mimeTypesForExtension(String extension) {
  final canonical = mimeTypeForExtension(extension);
  final extra = _aliases[extension] ?? const <String>[];
  if (canonical == null) return List<String>.unmodifiable(extra);
  return List<String>.unmodifiable(<String>[canonical, ...extra]);
}

/// Resolves [extensions] to MIME types, keeping the two outcomes apart.
///
/// Returns the de-duplicated MIME types that could be resolved in
/// [MimeResolution.mimeTypes], and the extensions that could not in
/// [MimeResolution.unresolved].
MimeResolution resolveMimeTypes(List<String> extensions) {
  final mimeTypes = <String>[];
  final seen = <String>{};
  final unresolved = <String>[];
  for (final extension in extensions) {
    final types = mimeTypesForExtension(extension);
    if (types.isEmpty) {
      unresolved.add(extension);
      continue;
    }
    for (final mime in types) {
      if (seen.add(mime)) mimeTypes.add(mime);
    }
  }
  return MimeResolution(
    mimeTypes: List<String>.unmodifiable(mimeTypes),
    unresolved: List<String>.unmodifiable(unresolved),
  );
}

/// The outcome of mapping a set of extensions onto MIME types.
final class MimeResolution {
  /// Wraps a completed resolution.
  const MimeResolution({required this.mimeTypes, required this.unresolved});

  /// De-duplicated MIME types, in first-seen order.
  final List<String> mimeTypes;

  /// Extensions that have no known MIME type.
  ///
  /// Non-empty means the Android filter cannot be expressed precisely.
  final List<String> unresolved;

  /// Whether every extension resolved to a MIME type.
  bool get isComplete => unresolved.isEmpty;
}
