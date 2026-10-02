import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/filters/extension_filter.dart';
import 'package:test/test.dart';

/// Matches a [FilePickerException] carrying [code].
Matcher throwsPickerError(FilePickerErrorCode code) =>
    throwsA(isA<FilePickerException>().having((e) => e.code, 'code', code));

void main() {
  group('normalizeExtensions', () {
    test('lowercases', () {
      expect(normalizeExtensions(['PDF', 'XlsX']).values, ['pdf', 'xlsx']);
    });

    test('strips a leading dot, and repeated leading dots', () {
      expect(normalizeExtensions(['.pdf', '..csv']).values, ['pdf', 'csv']);
    });

    test('trims surrounding whitespace', () {
      expect(normalizeExtensions(['  pdf  ', '\tcsv\n']).values, [
        'pdf',
        'csv',
      ]);
    });

    test('de-duplicates across normalization, keeping first-seen order', () {
      // '.PDF', 'pdf' and ' Pdf ' are one filter; csv must stay in position.
      final result = normalizeExtensions(['.PDF', 'csv', 'pdf', ' Pdf ']);
      expect(result.values, ['pdf', 'csv']);
    });

    test('accepts digits and alphanumeric mixes', () {
      expect(normalizeExtensions(['mp3', 'mp4', '7z', 'x3d']).values, [
        'mp3',
        'mp4',
        '7z',
        'x3d',
      ]);
    });

    test('returns an unmodifiable list', () {
      final values = normalizeExtensions(['pdf']).values;
      expect(() => values.add('csv'), throwsUnsupportedError);
    });

    test('rejects an empty input list', () {
      expect(
        () => normalizeExtensions(const <String>[]),
        throwsPickerError(FilePickerErrorCode.invalidFilter),
      );
    });

    test('rejects entries that normalize away to nothing', () {
      for (final bad in ['', '   ', '.', '..']) {
        expect(
          () => normalizeExtensions([bad]),
          throwsPickerError(FilePickerErrorCode.invalidFilter),
          reason: 'expected "$bad" to be rejected',
        );
      }
    });

    test('rejects a MIME type passed where an extension belongs', () {
      expect(
        () => normalizeExtensions(['application/pdf']),
        throwsPickerError(FilePickerErrorCode.invalidFilter),
      );
    });

    test('rejects a glob', () {
      expect(
        () => normalizeExtensions(['*.pdf']),
        throwsPickerError(FilePickerErrorCode.invalidFilter),
      );
      expect(
        () => normalizeExtensions(['*']),
        throwsPickerError(FilePickerErrorCode.invalidFilter),
      );
    });

    test('rejects a compound extension, naming the component to use', () {
      expect(
        () => normalizeExtensions(['tar.gz']),
        throwsA(
          isA<FilePickerException>()
              .having((e) => e.code, 'code', FilePickerErrorCode.invalidFilter)
              .having((e) => e.message, 'message', contains("'gz'")),
        ),
      );
    });

    test('rejects a path or a whole filename', () {
      for (final bad in ['/etc/passwd', 'report.pdf', '../secret']) {
        expect(
          () => normalizeExtensions([bad]),
          throwsPickerError(FilePickerErrorCode.invalidFilter),
          reason: 'expected "$bad" to be rejected',
        );
      }
    });

    test('rejects anything longer than the documented limit', () {
      final tooLong = 'a' * (maxExtensionLength + 1);
      expect(
        () => normalizeExtensions([tooLong]),
        throwsPickerError(FilePickerErrorCode.invalidFilter),
      );
      // The boundary itself is allowed.
      expect(
        normalizeExtensions(['a' * maxExtensionLength]).values.single.length,
        maxExtensionLength,
      );
    });

    test('names the offending value in the message', () {
      expect(
        () => normalizeExtensions(['pdf', 'image/png']),
        throwsA(
          isA<FilePickerException>().having(
            (e) => e.message,
            'message',
            contains('image/png'),
          ),
        ),
      );
    });
  });
}
