import 'dart:convert';

import 'package:dartnative_file_picker/dartnative_file_picker.dart';
import 'package:dartnative_file_picker/src/native/native_codec.dart';
import 'package:test/test.dart';

String envelope(Object? value) => jsonEncode(value);

Matcher throwsPickerError(FilePickerErrorCode code) =>
    throwsA(isA<FilePickerException>().having((e) => e.code, 'code', code));

void main() {
  group('decodeEnvelope', () {
    test('returns the decoded object on success', () {
      expect(decodeEnvelope('{"handle":7}'), {'handle': 7});
    });

    test('maps a native error envelope onto the typed code', () {
      expect(
        () => decodeEnvelope(
          envelope({
            errorKey: {
              'code': 'accessDenied',
              'message': 'Permission revoked',
              'nativeCode': 'SecurityException',
            },
          }),
        ),
        throwsA(
          isA<FilePickerException>()
              .having((e) => e.code, 'code', FilePickerErrorCode.accessDenied)
              .having((e) => e.message, 'message', 'Permission revoked')
              .having((e) => e.nativeCode, 'nativeCode', 'SecurityException'),
        ),
      );
    });

    test('every error code survives the round trip', () {
      // Guards against a code that exists in Dart but is unreachable from
      // native because the two spellings drifted apart.
      for (final code in FilePickerErrorCode.values) {
        expect(
          () => decodeEnvelope(
            envelope({
              errorKey: {'code': code.name, 'message': 'x'},
            }),
          ),
          throwsPickerError(code),
          reason: code.name,
        );
      }
    });

    test('an unknown error code degrades instead of throwing twice', () {
      expect(
        () => decodeEnvelope(
          envelope({
            errorKey: {
              'code': 'somethingNewerThanThisDartSide',
              'message': 'x',
            },
          }),
        ),
        throwsPickerError(FilePickerErrorCode.nativeFailure),
      );
    });

    test('an error with no message still produces a usable exception', () {
      expect(
        () => decodeEnvelope(envelope({errorKey: <String, Object?>{}})),
        throwsA(
          isA<FilePickerException>().having(
            (e) => e.message,
            'message',
            isNotEmpty,
          ),
        ),
      );
    });

    test('a non-object error value is still reported', () {
      expect(
        () => decodeEnvelope(envelope({errorKey: 'plain string failure'})),
        throwsA(
          isA<FilePickerException>().having(
            (e) => e.message,
            'message',
            contains('plain string failure'),
          ),
        ),
      );
    });

    test('an empty nativeCode becomes null rather than an empty string', () {
      expect(
        () => decodeEnvelope(
          envelope({
            errorKey: {'code': 'readFailed', 'message': 'x', 'nativeCode': ''},
          }),
        ),
        throwsA(
          isA<FilePickerException>().having(
            (e) => e.nativeCode,
            'nativeCode',
            isNull,
          ),
        ),
      );
    });

    test(
      'malformed JSON fails with a native failure, not a FormatException',
      () {
        expect(
          () => decodeEnvelope('{not json'),
          throwsPickerError(FilePickerErrorCode.nativeFailure),
        );
      },
    );

    test('a JSON value that is not an object is rejected', () {
      expect(
        () => decodeEnvelope('[1,2,3]'),
        throwsPickerError(FilePickerErrorCode.nativeFailure),
      );
    });
  });

  group('decodePickResult', () {
    test('no files key means cancelled', () {
      final outcome = decodePickResult('{}');
      expect(outcome.cancelled, isTrue);
      expect(outcome.files, isEmpty);
    });

    test('an empty files list means cancelled', () {
      final outcome = decodePickResult('{"files":[]}');
      expect(outcome.cancelled, isTrue);
      expect(outcome.files, isEmpty);
    });

    test('decodes a full record', () {
      final outcome = decodePickResult(
        envelope({
          'files': [
            {
              'name': 'Q3 Report.pdf',
              'uri': 'content://com.android.providers.downloads/document/42',
              'path': '/data/user/0/app/cache/dn_file_picker/1/Q3.pdf',
              'mimeType': 'application/pdf',
              'size': 1024,
              'persistedAccess': true,
            },
          ],
        }),
      );
      expect(outcome.cancelled, isFalse);
      final file = outcome.files.single;
      expect(file.name, 'Q3 Report.pdf');
      expect(file.uri.scheme, 'content');
      expect(file.path, '/data/user/0/app/cache/dn_file_picker/1/Q3.pdf');
      expect(file.mimeType, 'application/pdf');
      expect(file.size, 1024);
      expect(file.persistedAccess, isTrue);
    });

    test('keeps duplicates rather than misreporting the selection', () {
      final outcome = decodePickResult(
        envelope({
          'files': [
            {'name': 'a.pdf', 'uri': 'content://p/1'},
            {'name': 'a.pdf', 'uri': 'content://p/1'},
          ],
        }),
      );
      expect(outcome.files, hasLength(2));
    });

    test('a non-list files value is rejected', () {
      expect(
        () => decodePickResult('{"files":"nope"}'),
        throwsPickerError(FilePickerErrorCode.nativeFailure),
      );
    });
  });

  group('decodeFileRecord defends against incomplete provider metadata', () {
    test('a missing size stays null rather than becoming zero', () {
      final record = decodeFileRecord({
        'name': 'a.pdf',
        'uri': 'content://p/1',
      });
      expect(record.size, isNull);
    });

    test('a zero size is kept, because empty is not unknown', () {
      final record = decodeFileRecord({
        'name': 'empty.txt',
        'uri': 'content://p/1',
        'size': 0,
      });
      expect(record.size, 0);
    });

    test('a negative size is discarded as unknown', () {
      final record = decodeFileRecord({
        'name': 'a.pdf',
        'uri': 'content://p/1',
        'size': -1,
      });
      expect(record.size, isNull);
    });

    test('a missing display name falls back to the last URI segment', () {
      final record = decodeFileRecord({'uri': 'content://provider/doc/report'});
      expect(record.name, 'report');
    });

    test('a blank display name also falls back', () {
      final record = decodeFileRecord({
        'name': '   ',
        'uri': 'content://provider/doc/report',
      });
      expect(record.name, 'report');
    });

    test('a nameless URI with no usable segment falls back to "document"', () {
      final record = decodeFileRecord({'uri': 'content://provider'});
      expect(record.name, 'document');
    });

    test('a blank MIME type becomes null', () {
      final record = decodeFileRecord({
        'name': 'a',
        'uri': 'content://p/1',
        'mimeType': '  ',
      });
      expect(record.mimeType, isNull);
    });

    test('a relative path is refused, so no fake location is reported', () {
      final record = decodeFileRecord({
        'name': 'a',
        'uri': 'content://p/1',
        'path': 'relative/not/real',
      });
      expect(record.path, isNull);
    });

    test('a blank path becomes null', () {
      final record = decodeFileRecord({
        'name': 'a',
        'uri': 'content://p/1',
        'path': '   ',
      });
      expect(record.path, isNull);
    });

    test('persistedAccess defaults to false when absent', () {
      final record = decodeFileRecord({'name': 'a', 'uri': 'content://p/1'});
      expect(record.persistedAccess, isFalse);
    });

    test('a non-ASCII, spaced, right-to-left name survives intact', () {
      const name = 'تقرير نهائي ٢٠٢٦.pdf';
      final record = decodeFileRecord({'name': name, 'uri': 'content://p/1'});
      expect(record.name, name);
    });

    test('a missing uri is a hard failure', () {
      expect(
        () => decodeFileRecord({'name': 'a.pdf'}),
        throwsPickerError(FilePickerErrorCode.nativeFailure),
      );
    });

    test('a non-object entry is a hard failure', () {
      expect(
        () => decodeFileRecord('a.pdf'),
        throwsPickerError(FilePickerErrorCode.nativeFailure),
      );
    });
  });
}
