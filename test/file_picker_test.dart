import 'package:dartnative_file_picker/dartnative_file_picker.dart';
import 'package:test/test.dart';

/// Tests the behaviour that happens *before* and *around* the native call.
///
/// These run on the Dart VM, where no native library is loaded, so a pick that
/// gets past validation fails with [FilePickerErrorCode.nativeFailure]. That is
/// exactly what makes the busy-guard test meaningful: it proves the guard is
/// released on a failure path, not only on success.
void main() {
  setUp(() {
    expect(
      FilePicker.isPresenting,
      isFalse,
      reason: 'a previous test leaked the busy guard',
    );
  });

  group('argument validation happens before the picker is presented', () {
    test('FileType.custom with no extensions throws invalidFilter', () {
      expect(
        FilePicker.pickFile(type: FileType.custom),
        throwsA(
          isA<FilePickerException>().having(
            (e) => e.code,
            'code',
            FilePickerErrorCode.invalidFilter,
          ),
        ),
      );
    });

    test('FileType.custom with an empty list throws invalidFilter', () {
      expect(
        FilePicker.pickFiles(
          type: FileType.custom,
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

    test('a malformed extension throws invalidFilter', () {
      expect(
        FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: const ['application/pdf'],
        ),
        throwsA(isA<FilePickerException>()),
      );
    });

    test('an invalid request never makes the picker look busy', () async {
      await expectLater(
        FilePicker.pickFile(type: FileType.custom),
        throwsA(isA<FilePickerException>()),
      );
      expect(FilePicker.isPresenting, isFalse);
    });

    test('extensions with a non-custom type trip an assertion', () {
      // Debug-build guidance rather than a runtime failure: the combination is
      // meaningless, and silently honouring one half would be a guess.
      expect(
        () => FilePicker.pickFile(
          type: FileType.image,
          allowedExtensions: const ['pdf'],
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('without a loaded native library', () {
    test('pickFile reports nativeFailure with actionable guidance', () async {
      await expectLater(
        FilePicker.pickFile(),
        throwsA(
          isA<FilePickerException>()
              .having((e) => e.code, 'code', FilePickerErrorCode.nativeFailure)
              .having(
                (e) => e.message,
                'message',
                contains('DartNativePluginRegistrant.registerAll()'),
              ),
        ),
      );
    });

    test('the busy guard is released after a native failure', () async {
      await expectLater(FilePicker.pickFile(), throwsA(isA<Exception>()));
      expect(FilePicker.isPresenting, isFalse);

      // And the next call is allowed to proceed to the same honest failure,
      // rather than being rejected as pickerBusy by a stuck guard.
      await expectLater(
        FilePicker.pickFile(),
        throwsA(
          isA<FilePickerException>().having(
            (e) => e.code,
            'code',
            FilePickerErrorCode.nativeFailure,
          ),
        ),
      );
    });
  });

  group('FilePickerOptions', () {
    test('defaults to the cheap, safe combination', () {
      const options = FilePickerOptions();
      expect(options.accessMode, FilePickerAccessMode.reference);
      expect(options.persistAccess, isFalse);
      expect(options.localOnly, isFalse);
    });

    test('is const-constructible, so it can be a default argument', () {
      const a = FilePickerOptions();
      const b = FilePickerOptions();
      expect(identical(a, b), isTrue);
    });

    test('toString names every field', () {
      const options = FilePickerOptions(
        accessMode: FilePickerAccessMode.copyToCache,
        persistAccess: true,
        localOnly: true,
      );
      expect(options.toString(), contains('copyToCache'));
      expect(options.toString(), contains('persistAccess: true'));
      expect(options.toString(), contains('localOnly: true'));
    });
  });

  group('FilePickerException', () {
    test('toString carries the code and the message', () {
      const e = FilePickerException(
        FilePickerErrorCode.accessDenied,
        'no access',
      );
      expect(e.toString(), contains('accessDenied'));
      expect(e.toString(), contains('no access'));
    });

    test('toString includes the native detail when present', () {
      const e = FilePickerException(
        FilePickerErrorCode.readFailed,
        'read failed',
        nativeCode: 'FileNotFoundException',
      );
      expect(e.toString(), contains('FileNotFoundException'));
    });

    test('omits the native detail when absent', () {
      const e = FilePickerException(FilePickerErrorCode.readFailed, 'x');
      expect(e.toString(), isNot(contains('native:')));
    });
  });
}
