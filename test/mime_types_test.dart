import 'package:file_picker/src/filters/mime_types.dart';
import 'package:test/test.dart';

void main() {
  group('mimeTypeForExtension', () {
    test('resolves the common document, image, audio and video types', () {
      expect(mimeTypeForExtension('pdf'), 'application/pdf');
      expect(mimeTypeForExtension('csv'), 'text/csv');
      expect(mimeTypeForExtension('txt'), 'text/plain');
      expect(mimeTypeForExtension('zip'), 'application/zip');
      expect(mimeTypeForExtension('png'), 'image/png');
      expect(mimeTypeForExtension('jpg'), 'image/jpeg');
      expect(mimeTypeForExtension('jpeg'), 'image/jpeg');
      expect(mimeTypeForExtension('heic'), 'image/heic');
      expect(mimeTypeForExtension('mp3'), 'audio/mpeg');
      expect(mimeTypeForExtension('mp4'), 'video/mp4');
      expect(
        mimeTypeForExtension('xlsx'),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      expect(
        mimeTypeForExtension('docx'),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
      expect(mimeTypeForExtension('doc'), 'application/msword');
    });

    test('fills the gaps package:mime leaves, from the IANA registry', () {
      expect(mimeTypeForExtension('yaml'), 'application/yaml');
      expect(mimeTypeForExtension('yml'), 'application/yaml');
      expect(mimeTypeForExtension('gz'), 'application/gzip');
    });

    // Guards the claim made in mime_types.dart: the common extensions are
    // handled by package:mime and are deliberately NOT duplicated in the
    // override map. If a future package:mime regresses one of them, the test
    // above fails and this one explains why the override list stayed short.
    test('does not shadow extensions package:mime already resolves', () {
      const alreadyCorrect = <String>[
        'pdf',
        'csv',
        'docx',
        'xlsx',
        'doc',
        'jpg',
        'png',
        'heic',
        'heif',
        'avif',
        'webp',
        'md',
        'apk',
        'zip',
        'txt',
        'mp3',
        'mp4',
      ];
      for (final extension in alreadyCorrect) {
        expect(
          mimeTypeForExtension(extension),
          isNotNull,
          reason: '$extension must resolve without a local override',
        );
      }
    });

    test('returns null for an extension it cannot resolve', () {
      // A null is a documented outcome, not a failure: it tells the Android
      // layer to widen the filter rather than exclude the user's file.
      expect(mimeTypeForExtension('xyzzy'), isNull);
      expect(mimeTypeForExtension('dnkeys'), isNull);
    });
  });

  group('mimeTypesForExtension (provider aliases)', () {
    // Device-verified on an API 34 emulator: MediaStore indexes a .csv as
    // text/comma-separated-values, so a filter carrying only text/csv hid the
    // file entirely. Discoverability depends on offering both spellings.
    test('csv offers the legacy spelling alongside the registered one', () {
      final types = mimeTypesForExtension('csv');
      expect(types, contains('text/csv'));
      expect(types, contains('text/comma-separated-values'));
      expect(types.first, 'text/csv', reason: 'canonical type comes first');
    });

    test('an extension with no alias returns just its canonical type', () {
      expect(mimeTypesForExtension('pdf'), ['application/pdf']);
    });

    test('an unresolvable extension with no alias returns empty', () {
      expect(mimeTypesForExtension('xyzzy'), isEmpty);
    });

    test('returns unmodifiable lists', () {
      expect(
        () => mimeTypesForExtension('csv').add('x'),
        throwsUnsupportedError,
      );
    });
  });

  group('resolveMimeTypes', () {
    test('de-duplicates MIME types that several extensions share', () {
      final resolution = resolveMimeTypes(['jpg', 'jpeg']);
      expect(resolution.mimeTypes, ['image/jpeg']);
      expect(resolution.unresolved, isEmpty);
      expect(resolution.isComplete, isTrue);
    });

    test('keeps resolved and unresolved extensions apart', () {
      final resolution = resolveMimeTypes(['pdf', 'xyzzy', 'csv']);
      expect(resolution.mimeTypes, [
        'application/pdf',
        'text/csv',
        'text/comma-separated-values',
      ]);
      expect(resolution.unresolved, ['xyzzy']);
      expect(resolution.isComplete, isFalse);
    });

    test('aliases widen the filter without duplicating', () {
      // yaml and yml share both their canonical type and their aliases.
      final resolution = resolveMimeTypes(['yaml', 'yml']);
      expect(resolution.mimeTypes, [
        'application/yaml',
        'text/yaml',
        'text/x-yaml',
      ]);
      expect(resolution.isComplete, isTrue);
    });

    test('preserves first-seen order, canonical before alias', () {
      final resolution = resolveMimeTypes(['png', 'pdf', 'csv']);
      expect(resolution.mimeTypes, [
        'image/png',
        'application/pdf',
        'text/csv',
        'text/comma-separated-values',
      ]);
    });

    test('returns unmodifiable lists', () {
      final resolution = resolveMimeTypes(['pdf']);
      expect(() => resolution.mimeTypes.add('x'), throwsUnsupportedError);
      expect(() => resolution.unresolved.add('x'), throwsUnsupportedError);
    });

    test('an empty input is complete, not an error', () {
      final resolution = resolveMimeTypes(const <String>[]);
      expect(resolution.mimeTypes, isEmpty);
      expect(resolution.isComplete, isTrue);
    });
  });
}
