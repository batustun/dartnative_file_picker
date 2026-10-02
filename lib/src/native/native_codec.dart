/// Decoding of the native to Dart payloads.
///
/// Pure Dart: every rule about trusting, or refusing to trust, what a document
/// provider reported is enforced here and unit-tested without a device.
library;

import 'dart:convert';

import '../exceptions.dart';

/// The error key native code uses to signal failure inside a payload.
///
/// The async channel carries one payload per reply, so a failure travels *in*
/// the payload rather than beside it — the convention DartNative's
/// `plugin_async_callbacks.md` prescribes.
const String errorKey = '__error';

/// A document as the native side described it, before it is given behaviour.
///
/// Deliberately inert: no reading, no copying, no native handles. [PlatformFile]
/// wraps one of these together with a gateway that can act on it.
final class NativeFileRecord {
  /// Creates a record. Only [name] and [uri] are guaranteed by both platforms.
  const NativeFileRecord({
    required this.name,
    required this.uri,
    required this.persistedAccess,
    this.path,
    this.mimeType,
    this.size,
  });

  /// The document's display name, never empty — see [decodeFileRecord].
  final String name;

  /// The canonical resource reference.
  final Uri uri;

  /// A real local path, or `null` when none exists.
  final String? path;

  /// The provider's MIME type, or `null` when it reported none.
  final String? mimeType;

  /// The size in bytes, or `null` when the provider reported none.
  final int? size;

  /// Whether access was actually persisted, as reported by native code.
  final bool persistedAccess;
}

/// The outcome of a pick: either a cancellation or a list of documents.
final class PickOutcome {
  /// Creates an outcome.
  const PickOutcome({required this.cancelled, required this.files});

  /// Whether the user dismissed the picker without choosing anything.
  final bool cancelled;

  /// The chosen documents, empty when [cancelled].
  final List<NativeFileRecord> files;
}

/// Decodes a native JSON payload, throwing when it carries an error.
///
/// Returns the decoded object on success. Throws a [FilePickerException]:
///
/// - mapped from the error envelope when the payload contains [errorKey];
/// - with [FilePickerErrorCode.nativeFailure] when the payload is not a JSON
///   object at all, which would otherwise surface as an opaque cast error far
///   from its cause.
Map<String, Object?> decodeEnvelope(String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException catch (e) {
    throw FilePickerException(
      FilePickerErrorCode.nativeFailure,
      'The native side sent a payload that is not valid JSON: ${e.message}',
    );
  }
  if (decoded is! Map<String, Object?>) {
    throw const FilePickerException(
      FilePickerErrorCode.nativeFailure,
      'The native side sent a JSON value that is not an object.',
    );
  }
  final error = decoded[errorKey];
  if (error != null) throw _decodeError(error);
  return decoded;
}

FilePickerException _decodeError(Object? error) {
  if (error is! Map<String, Object?>) {
    return FilePickerException(
      FilePickerErrorCode.nativeFailure,
      'The native side reported a failure: $error',
    );
  }
  final rawCode = error['code'];
  final message = error['message'];
  return FilePickerException(
    _codeByName[rawCode] ?? FilePickerErrorCode.nativeFailure,
    message is String && message.isNotEmpty
        ? message
        : 'The native side reported a failure without a message.',
    nativeCode: switch (error['nativeCode']) {
      final String n when n.isNotEmpty => n,
      _ => null,
    },
  );
}

/// Maps the wire name of an error back onto [FilePickerErrorCode].
///
/// Built from the enum so a new code cannot be forgotten here. An unrecognized
/// name — an older Dart side paired with a newer native build — degrades to
/// [FilePickerErrorCode.nativeFailure] instead of throwing while throwing.
final Map<String, FilePickerErrorCode> _codeByName =
    <String, FilePickerErrorCode>{
      for (final code in FilePickerErrorCode.values) code.name: code,
    };

/// Decodes a pick reply.
///
/// A payload with no `files` key, or an empty list, is a cancellation: the two
/// are the same outcome to a caller and both platforms report dismissal that
/// way.
PickOutcome decodePickResult(String payload) {
  final map = decodeEnvelope(payload);
  final rawFiles = map['files'];
  if (rawFiles == null) {
    return const PickOutcome(cancelled: true, files: <NativeFileRecord>[]);
  }
  if (rawFiles is! List) {
    throw const FilePickerException(
      FilePickerErrorCode.nativeFailure,
      'The native side sent a pick result whose "files" is not a list.',
    );
  }
  final files = <NativeFileRecord>[
    for (final entry in rawFiles) decodeFileRecord(entry),
  ];
  return PickOutcome(cancelled: files.isEmpty, files: files);
}

/// Decodes one document entry, defending against incomplete provider metadata.
///
/// A `DocumentsProvider` is not obliged to answer any particular column, so
/// every field except the URI is treated as optional:
///
/// - a missing, empty or whitespace-only display name falls back to the URI's
///   last path segment, and then to `'document'`, so [NativeFileRecord.name] is
///   never empty;
/// - a missing size stays `null` rather than becoming `0`, because "unknown"
///   and "empty file" are different facts and a zero would make a progress bar
///   lie;
/// - a negative size is discarded as unknown;
/// - a blank MIME type or path becomes `null` rather than an empty string;
/// - a path is accepted only when it is absolute, so a provider cannot talk
///   this package into reporting a relative path as a real file location.
///
/// Throws [FilePickerErrorCode.nativeFailure] when the URI itself is missing or
/// unparseable — without it there is no document to speak of.
NativeFileRecord decodeFileRecord(Object? entry) {
  if (entry is! Map<String, Object?>) {
    throw const FilePickerException(
      FilePickerErrorCode.nativeFailure,
      'The native side sent a file entry that is not a JSON object.',
    );
  }
  final rawUri = entry['uri'];
  if (rawUri is! String || rawUri.isEmpty) {
    throw const FilePickerException(
      FilePickerErrorCode.nativeFailure,
      'The native side sent a file entry without a uri.',
    );
  }
  final Uri uri;
  try {
    uri = Uri.parse(rawUri);
  } on FormatException catch (e) {
    throw FilePickerException(
      FilePickerErrorCode.nativeFailure,
      'The native side sent an unparseable uri "$rawUri": ${e.message}',
    );
  }

  return NativeFileRecord(
    name: _displayName(entry['name'], uri),
    uri: uri,
    path: switch (entry['path']) {
      final String p when p.trim().isNotEmpty && p.startsWith('/') => p,
      _ => null,
    },
    mimeType: switch (entry['mimeType']) {
      final String m when m.trim().isNotEmpty => m.trim(),
      _ => null,
    },
    size: switch (entry['size']) {
      final int s when s >= 0 => s,
      _ => null,
    },
    persistedAccess: entry['persistedAccess'] == true,
  );
}

String _displayName(Object? raw, Uri uri) {
  if (raw is String && raw.trim().isNotEmpty) return raw.trim();
  final segments = uri.pathSegments;
  for (final segment in segments.reversed) {
    final decoded = segment.trim();
    if (decoded.isNotEmpty) return decoded;
  }
  return 'document';
}
