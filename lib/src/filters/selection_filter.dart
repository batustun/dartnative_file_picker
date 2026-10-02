/// Post-selection enforcement of an extension filter.
///
/// A platform picker's filter is a **hint**, not a contract. Two things make
/// that unavoidable:
///
/// * On Android an extension with no known MIME type cannot be expressed, so
///   the filter widens to a wildcard rather than hiding the very file the caller
///   came for. The picker then offers more than was asked for.
/// * A `DocumentsProvider` reports its own MIME types, and they are neither
///   guaranteed accurate nor fine-grained, so even an exact MIME filter can let
///   through something else.
///
/// So the filter is enforced here, after selection, against the one fact that is
/// actually reliable: the document's own filename. That makes
/// `allowedExtensions` mean the same thing on both platforms and against every
/// provider, instead of meaning "whatever the picker happened to show".
///
/// Pure Dart, so the whole policy is unit-testable without a device.
library;

import '../native/native_codec.dart';

/// The lowercase extension of [name], or `null` when it has none.
///
/// The single definition of "the extension of a document" in this package:
/// [PlatformFile.extension] and the filter enforcement below both call it, so
/// the value a caller sees can never disagree with the value that was enforced.
///
/// Derived from the last dot, so `Q3.Final.XLSX` gives `xlsx`. A dotfile such as
/// `.gitignore` has no extension, nor does a name with no dot or a trailing dot.
/// Comes from the filename only, never from a provider's MIME type.
String? extensionOfName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// What survived enforcement, and what did not.
final class SelectionOutcome {
  /// Wraps a completed partition.
  const SelectionOutcome({required this.accepted, required this.rejected});

  /// Documents whose extension is in the allowed list, in the platform's order.
  final List<NativeFileRecord> accepted;

  /// Documents that were dropped, with the display name the user saw.
  ///
  /// Kept so the caller can be told *what* was refused rather than just that
  /// something was.
  final List<String> rejected;
}

/// Partitions [records] into those matching [allowedExtensions] and those not.
///
/// [allowedExtensions] must already be normalized (lowercase, dot-free) by
/// `normalizeExtensions`, which is what `PickerRequest` guarantees.
///
/// An empty [allowedExtensions] accepts everything: it means no extension filter
/// was requested, not that nothing is acceptable.
///
/// A document with no extension is rejected whenever a filter is in force. There
/// is no sensible reading of `allowedExtensions: ['pdf']` under which a file
/// named `README` qualifies.
SelectionOutcome enforceExtensions(
  List<NativeFileRecord> records,
  List<String> allowedExtensions,
) {
  if (allowedExtensions.isEmpty) {
    return SelectionOutcome(accepted: records, rejected: const <String>[]);
  }
  final allowed = allowedExtensions.toSet();
  final accepted = <NativeFileRecord>[];
  final rejected = <String>[];
  for (final record in records) {
    final extension = extensionOfName(record.name);
    if (extension != null && allowed.contains(extension)) {
      accepted.add(record);
    } else {
      rejected.add(record.name);
    }
  }
  return SelectionOutcome(accepted: accepted, rejected: rejected);
}
