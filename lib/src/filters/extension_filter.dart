/// Normalization and validation of caller-supplied file extensions.
///
/// Pure Dart on purpose: every rule in here is enforced *before* any native
/// call, so an invalid filter costs nothing and fails with a precise message
/// instead of presenting a picker that cannot work.
library;

import '../exceptions.dart';

/// The longest extension this package accepts.
///
/// Real extensions are short; a very long one is a sign of a path or a
/// filename having been passed by mistake.
const int maxExtensionLength = 32;

/// Extensions that survived [normalizeExtensions], paired with what was
/// rejected on the way.
///
/// Returned instead of a bare list so the caller can report *which* input was
/// malformed rather than just that something was.
final class NormalizedExtensions {
  /// Wraps an already-normalized [values] list.
  const NormalizedExtensions(this.values);

  /// Lowercase, dot-free, de-duplicated extensions in first-seen order.
  final List<String> values;
}

/// Normalizes [input] into comparable extensions, or throws.
///
/// Applied to every entry, in order:
///
/// 1. surrounding whitespace is trimmed;
/// 2. leading dots are stripped, so `.pdf`, `..pdf` and `pdf` are one thing;
/// 3. the result is lowercased, so `PDF` and `pdf` are one thing;
/// 4. duplicates are dropped, keeping the first occurrence's position.
///
/// After that each entry must match `[a-z0-9]+` and be at most
/// [maxExtensionLength] characters. Anything else throws a
/// [FilePickerException] with [FilePickerErrorCode.invalidFilter], naming the
/// offending value.
///
/// Compound extensions such as `tar.gz` are **rejected** rather than silently
/// reinterpreted: pass the final component (`gz`). An extension containing a
/// path separator, a wildcard, a space or any other punctuation is rejected
/// for the same reason — these are the shapes that indicate a MIME type
/// (`image/png`), a glob (`*.pdf`) or a whole filename was passed instead of
/// an extension.
///
/// Throws if [input] is empty, or if every entry normalizes away to nothing.
NormalizedExtensions normalizeExtensions(Iterable<String> input) {
  final raw = input.toList(growable: false);
  if (raw.isEmpty) {
    throw const FilePickerException(
      FilePickerErrorCode.invalidFilter,
      'allowedExtensions is empty. FileType.custom needs at least one '
      'extension, for example: allowedExtensions: [\'pdf\', \'csv\'].',
    );
  }

  final seen = <String>{};
  final result = <String>[];
  for (final entry in raw) {
    final normalized = _normalizeOne(entry);
    if (seen.add(normalized)) result.add(normalized);
  }
  return NormalizedExtensions(List<String>.unmodifiable(result));
}

String _normalizeOne(String entry) {
  final trimmed = entry.trim();
  // Strip every leading dot: '.pdf' and the occasional '..pdf' both mean pdf.
  var stripped = trimmed;
  while (stripped.startsWith('.')) {
    stripped = stripped.substring(1);
  }
  final lowered = stripped.toLowerCase();

  if (lowered.isEmpty) {
    throw FilePickerException(
      FilePickerErrorCode.invalidFilter,
      'Extension "$entry" is empty after normalization. Pass an extension '
      'without dots, for example \'pdf\'.',
    );
  }
  if (lowered.length > maxExtensionLength) {
    throw FilePickerException(
      FilePickerErrorCode.invalidFilter,
      'Extension "$entry" is ${lowered.length} characters, longer than the '
      '$maxExtensionLength-character limit. Pass an extension, not a '
      'filename or path.',
    );
  }
  if (!_validExtension.hasMatch(lowered)) {
    throw FilePickerException(
      FilePickerErrorCode.invalidFilter,
      'Extension "$entry" is not a plain extension. Expected letters and '
      'digits only (got "$lowered"). Pass \'pdf\', not \'.pdf\', '
      '\'*.pdf\', \'application/pdf\' or \'tar.gz\' — for a compound '
      'extension pass its last component, \'gz\'.',
    );
  }
  return lowered;
}

final RegExp _validExtension = RegExp(r'^[a-z0-9]+$');
