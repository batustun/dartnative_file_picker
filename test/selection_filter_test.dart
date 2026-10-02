import 'package:dartnative_file_picker/src/filters/selection_filter.dart';
import 'package:dartnative_file_picker/src/native/native_codec.dart';
import 'package:test/test.dart';

NativeFileRecord record(String name) => NativeFileRecord(
  name: name,
  uri: Uri.parse('content://provider/doc/${Uri.encodeComponent(name)}'),
  persistedAccess: false,
);

void main() {
  group('extensionOfName', () {
    test('takes the last dot and lowercases', () {
      expect(extensionOfName('Q3.Final.XLSX'), 'xlsx');
      expect(extensionOfName('report.pdf'), 'pdf');
    });

    test('is null without a usable extension', () {
      expect(extensionOfName('README'), isNull);
      expect(extensionOfName('.gitignore'), isNull, reason: 'a dotfile');
      expect(extensionOfName('trailing.'), isNull);
      expect(extensionOfName(''), isNull);
    });

    test('survives spaces and non-ASCII', () {
      expect(extensionOfName('my report ö.PDF'), 'pdf');
      expect(extensionOfName('تقرير.pdf'), 'pdf');
    });
  });

  group('enforceExtensions', () {
    test('accepts everything when no filter was requested', () {
      final records = [record('a.pdf'), record('b.mp4'), record('README')];
      final outcome = enforceExtensions(records, const <String>[]);
      expect(outcome.accepted, hasLength(3));
      expect(outcome.rejected, isEmpty);
    });

    test('keeps matches and drops the rest, preserving order', () {
      final outcome = enforceExtensions(
        [record('a.pdf'), record('b.mp4'), record('c.csv')],
        const ['pdf', 'csv'],
      );
      expect(outcome.accepted.map((r) => r.name), ['a.pdf', 'c.csv']);
      expect(outcome.rejected, ['b.mp4']);
    });

    test('matches case-insensitively, because the name may be uppercase', () {
      final outcome = enforceExtensions([record('LOUD.PDF')], const ['pdf']);
      expect(outcome.accepted, hasLength(1));
      expect(outcome.rejected, isEmpty);
    });

    // The case that motivated this layer: Android cannot express an unknown
    // extension, widens to a wildcard, and the user can then pick anything.
    test('rejects what a widened wildcard filter let through', () {
      final outcome = enforceExtensions(
        [record('photo.jpg'), record('movie.mp4')],
        const ['abcxyz'],
      );
      expect(outcome.accepted, isEmpty);
      expect(outcome.rejected, ['photo.jpg', 'movie.mp4']);
    });

    test('rejects a document with no extension when a filter is in force', () {
      final outcome = enforceExtensions(
        [record('README'), record('.gitignore'), record('ok.pdf')],
        const ['pdf'],
      );
      expect(outcome.accepted.map((r) => r.name), ['ok.pdf']);
      expect(outcome.rejected, ['README', '.gitignore']);
    });

    test('does not trust a MIME type over the filename', () {
      // A provider is free to claim application/pdf for a PNG. The filename is
      // the only thing enforced.
      final outcome = enforceExtensions(
        [
          NativeFileRecord(
            name: 'actually.png',
            uri: Uri.parse('content://p/1'),
            mimeType: 'application/pdf',
            persistedAccess: false,
          ),
        ],
        const ['pdf'],
      );
      expect(outcome.accepted, isEmpty);
      expect(outcome.rejected, ['actually.png']);
    });

    test('an empty selection stays empty without rejecting anything', () {
      final outcome = enforceExtensions(const [], const ['pdf']);
      expect(outcome.accepted, isEmpty);
      expect(outcome.rejected, isEmpty);
    });
  });
}
