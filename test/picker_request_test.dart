import 'dart:convert';

import 'package:dartnative_file_picker/dartnative_file_picker.dart';
import 'package:dartnative_file_picker/src/native/picker_request.dart';
import 'package:test/test.dart';

Map<String, Object?> decoded(PickerRequest request) =>
    jsonDecode(request.toJson()) as Map<String, Object?>;

void main() {
  group('PickerRequest.build validation', () {
    test('FileType.custom without allowedExtensions is rejected', () {
      expect(
        () => PickerRequest.build(type: FileType.custom, allowMultiple: false),
        throwsA(
          isA<FilePickerException>()
              .having((e) => e.code, 'code', FilePickerErrorCode.invalidFilter)
              .having(
                (e) => e.message,
                'message',
                contains('allowedExtensions'),
              ),
        ),
      );
    });

    test('FileType.custom with an empty list is rejected', () {
      expect(
        () => PickerRequest.build(
          type: FileType.custom,
          allowMultiple: false,
          allowedExtensions: const <String>[],
        ),
        throwsA(
          isA<FilePickerException>().having(
            (e) => e.code,
            'code',
            FilePickerErrorCode.invalidFilter,
          ),
        ),
      );
    });

    test('a malformed extension is rejected before any native call', () {
      expect(
        () => PickerRequest.build(
          type: FileType.custom,
          allowMultiple: false,
          allowedExtensions: const ['pdf', '*.csv'],
        ),
        throwsA(isA<FilePickerException>()),
      );
    });

    test('extensions are normalized and de-duplicated', () {
      final request = PickerRequest.build(
        type: FileType.custom,
        allowMultiple: false,
        allowedExtensions: const ['.PDF', 'pdf', ' Csv '],
      );
      expect(request.extensions, ['pdf', 'csv']);
      // csv carries a provider alias, so the filter offers both spellings.
      expect(request.mimeTypes, [
        'application/pdf',
        'text/csv',
        'text/comma-separated-values',
      ]);
    });
  });

  group('non-custom types', () {
    test('ignore allowedExtensions instead of failing or combining', () {
      final request = PickerRequest.build(
        type: FileType.image,
        allowMultiple: true,
        allowedExtensions: const ['pdf'],
      );
      expect(request.extensions, isEmpty);
      expect(request.mimeTypes, isEmpty);
      expect(request.ignoredExtensions, isEmpty);
      expect(decoded(request)['type'], 'image');
    });

    test('are always exactly expressible on Android', () {
      for (final type in [
        FileType.any,
        FileType.image,
        FileType.video,
        FileType.audio,
      ]) {
        final request = PickerRequest.build(type: type, allowMultiple: false);
        expect(request.androidFilterIsExact, isTrue, reason: type.name);
      }
    });
  });

  group('androidFilterIsExact', () {
    test('is true when every extension resolves', () {
      final request = PickerRequest.build(
        type: FileType.custom,
        allowMultiple: false,
        allowedExtensions: const ['pdf', 'csv'],
      );
      expect(request.androidFilterIsExact, isTrue);
      expect(request.unresolvedExtensions, isEmpty);
    });

    test('is false when an extension has no MIME type', () {
      final request = PickerRequest.build(
        type: FileType.custom,
        allowMultiple: false,
        allowedExtensions: const ['pdf', 'xyzzy'],
      );
      expect(request.androidFilterIsExact, isFalse);
      expect(request.unresolvedExtensions, ['xyzzy']);
      // The resolvable half still travels, so iOS can filter precisely.
      expect(request.mimeTypes, ['application/pdf']);
      expect(request.extensions, ['pdf', 'xyzzy']);
    });
  });

  group('toJson', () {
    test('carries every field the native side reads', () {
      final request = PickerRequest.build(
        type: FileType.custom,
        allowMultiple: true,
        allowedExtensions: const ['pdf'],
        options: const FilePickerOptions(
          accessMode: FilePickerAccessMode.copyToCache,
          persistAccess: true,
          localOnly: true,
        ),
      );
      expect(decoded(request), {
        'type': 'custom',
        'extensions': ['pdf'],
        'mimeTypes': ['application/pdf'],
        'unresolvedExtensions': <String>[],
        'allowMultiple': true,
        'accessMode': 'copyToCache',
        'persistAccess': true,
        'localOnly': true,
      });
    });

    test('defaults are the cheap, safe ones', () {
      final json = decoded(
        PickerRequest.build(type: FileType.any, allowMultiple: false),
      );
      expect(json['accessMode'], 'reference');
      expect(json['persistAccess'], false);
      expect(json['localOnly'], false);
      expect(json['allowMultiple'], false);
    });

    test('is valid UTF-8 JSON for non-ASCII extensions is impossible', () {
      // Extensions are constrained to [a-z0-9], so the request JSON is always
      // ASCII — a property the native parsers rely on for the filter fields.
      final request = PickerRequest.build(
        type: FileType.custom,
        allowMultiple: false,
        allowedExtensions: const ['pdf'],
      );
      expect(utf8.encode(request.toJson()).every((b) => b < 128), isTrue);
    });
  });
}
