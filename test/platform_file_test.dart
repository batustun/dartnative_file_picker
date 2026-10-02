import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/native/resource_gateway.dart';
import 'package:test/test.dart';

/// A gateway that records calls and serves canned bytes.
///
/// Exists so [PlatformFile]'s own behaviour — chunk validation, stream
/// accumulation, lazy opening, no-op releases — can be tested on the Dart VM,
/// with no device and no FFI.
final class FakeGateway implements FileResourceGateway {
  FakeGateway({
    this.bytes = const <int>[],
    this.copyResult = '/cache/copy.bin',
    this.releaseResult = true,
    this.readError,
  });

  final List<int> bytes;
  final String copyResult;
  final bool releaseResult;
  final Object? readError;

  int openReadCalls = 0;
  int copyCalls = 0;
  int releaseCalls = 0;
  final List<int> requestedChunkSizes = <int>[];
  String? lastPreferredName;

  /// Mirrors the real implementation's shape: an `async*` generator whose body
  /// does not run until the stream is listened to. The counters therefore
  /// measure "reading started", not "the method was called" — which is the
  /// property the laziness test is about.
  @override
  Stream<Uint8List> openRead(Uri uri, {required int chunkSize}) async* {
    openReadCalls++;
    requestedChunkSizes.add(chunkSize);
    if (readError != null) throw readError!;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      yield Uint8List.fromList(bytes.sublist(offset, end));
    }
  }

  @override
  Future<String> copyToCache(Uri uri, {required String preferredName}) async {
    copyCalls++;
    lastPreferredName = preferredName;
    return copyResult;
  }

  @override
  Future<bool> releasePersistedAccess(Uri uri) async {
    releaseCalls++;
    return releaseResult;
  }
}

PlatformFile fileWith({
  String name = 'report.pdf',
  String uri = 'content://provider/doc/1',
  bool persistedAccess = false,
  String? path,
  String? mimeType,
  int? size,
  FakeGateway? gateway,
}) => PlatformFile(
  name: name,
  uri: Uri.parse(uri),
  persistedAccess: persistedAccess,
  gateway: gateway ?? FakeGateway(),
  path: path,
  mimeType: mimeType,
  size: size,
);

void main() {
  group('extension', () {
    test('comes from the name and is lowercased', () {
      expect(fileWith(name: 'Q3.Final.XLSX').extension, 'xlsx');
      expect(fileWith(name: 'report.pdf').extension, 'pdf');
    });

    test('is null when the name has no dot', () {
      expect(fileWith(name: 'README').extension, isNull);
    });

    test('is null for a dotfile, which has no extension', () {
      expect(fileWith(name: '.gitignore').extension, isNull);
    });

    test('is null for a trailing dot', () {
      expect(fileWith(name: 'odd.').extension, isNull);
    });

    test('survives spaces and non-ASCII in the name', () {
      expect(fileWith(name: 'my report ö.PDF').extension, 'pdf');
    });

    test('ignores mimeType entirely', () {
      // The extension is a fact about the filename; the MIME type is a claim
      // by the provider. They must not be conflated.
      expect(
        fileWith(name: 'data', mimeType: 'application/pdf').extension,
        isNull,
      );
    });
  });

  group('readAsByteStream', () {
    test('rejects a non-positive chunkSize synchronously', () {
      final file = fileWith();
      for (final bad in [0, -1, -64]) {
        expect(
          () => file.readAsByteStream(chunkSize: bad),
          throwsA(
            isA<FilePickerException>().having(
              (e) => e.code,
              'code',
              FilePickerErrorCode.invalidFilter,
            ),
          ),
          reason: 'chunkSize $bad must be rejected',
        );
      }
    });

    test('does not open the resource until the stream is listened to', () {
      final gateway = FakeGateway(bytes: [1, 2, 3]);
      final file = fileWith(gateway: gateway);
      file.readAsByteStream();
      expect(gateway.openReadCalls, 0);
    });

    test('passes the chunk size through, defaulting to 1 MiB', () async {
      final gateway = FakeGateway(bytes: [1, 2, 3]);
      final file = fileWith(gateway: gateway);
      await file.readAsByteStream().drain<void>();
      await file.readAsByteStream(chunkSize: 8).drain<void>();
      expect(gateway.requestedChunkSizes, [defaultChunkSize, 8]);
      // Pinned deliberately. The default is a measured value, not a taste: each
      // chunk costs one ~50 ms native round trip on device, so 64 KiB capped
      // throughput at ~1.3 MB/s and made a 600 MB read take about 16 minutes.
      // 1 MiB measured 28.7 MB/s for the same document. Changing this number
      // changes that, so it should not move without a new measurement.
      expect(defaultChunkSize, 1024 * 1024);
    });

    test('never yields a chunk larger than requested', () async {
      final gateway = FakeGateway(bytes: List<int>.generate(50, (i) => i));
      final file = fileWith(gateway: gateway);
      final chunks = await file.readAsByteStream(chunkSize: 16).toList();
      expect(chunks.map((c) => c.length), [16, 16, 16, 2]);
      expect(chunks.every((c) => c.length <= 16), isTrue);
    });

    test('a zero-byte document yields no chunks and closes', () async {
      final file = fileWith(gateway: FakeGateway(bytes: const <int>[]));
      expect(await file.readAsByteStream().toList(), isEmpty);
    });
  });

  group('readAsBytes', () {
    test('accumulates the stream in order', () async {
      final bytes = List<int>.generate(1000, (i) => i % 256);
      final file = fileWith(gateway: FakeGateway(bytes: bytes));
      final read = await file.readAsBytes(chunkSize: 64);
      expect(read, bytes);
    });

    test('returns an empty list for a zero-byte document', () async {
      final file = fileWith(gateway: FakeGateway(bytes: const <int>[]));
      expect(await file.readAsBytes(), isEmpty);
    });

    test('propagates a read failure rather than returning empty bytes', () {
      final file = fileWith(
        gateway: FakeGateway(
          readError: const FilePickerException(
            FilePickerErrorCode.readFailed,
            'provider went away',
          ),
        ),
      );
      expect(
        file.readAsBytes(),
        throwsA(
          isA<FilePickerException>().having(
            (e) => e.code,
            'code',
            FilePickerErrorCode.readFailed,
          ),
        ),
      );
    });

    test('rejects a bad chunkSize as the stream does', () {
      expect(
        () => fileWith().readAsBytes(chunkSize: 0),
        throwsA(isA<FilePickerException>()),
      );
    });
  });

  group('copyToCache', () {
    test('passes the display name as the preferred name', () async {
      final gateway = FakeGateway(copyResult: '/cache/x/report.pdf');
      final file = fileWith(name: 'report.pdf', gateway: gateway);
      expect(await file.copyToCache(), '/cache/x/report.pdf');
      expect(gateway.lastPreferredName, 'report.pdf');
    });

    test('does not mutate path, because the model is immutable', () async {
      final file = fileWith(gateway: FakeGateway(copyResult: '/cache/a.pdf'));
      expect(file.path, isNull);
      await file.copyToCache();
      expect(file.path, isNull, reason: 'use the returned path instead');
    });

    test('each call produces an independent copy', () async {
      final gateway = FakeGateway();
      final file = fileWith(gateway: gateway);
      await file.copyToCache();
      await file.copyToCache();
      expect(gateway.copyCalls, 2);
    });
  });

  group('releasePersistedAccess', () {
    test('is a no-op when nothing was persisted', () async {
      final gateway = FakeGateway();
      final file = fileWith(persistedAccess: false, gateway: gateway);
      await file.releasePersistedAccess();
      expect(gateway.releaseCalls, 0);
    });

    test('releases when access was persisted', () async {
      final gateway = FakeGateway();
      final file = fileWith(persistedAccess: true, gateway: gateway);
      await file.releasePersistedAccess();
      expect(gateway.releaseCalls, 1);
    });

    test('throws persistenceFailed when the platform refuses', () {
      final file = fileWith(
        persistedAccess: true,
        gateway: FakeGateway(releaseResult: false),
      );
      expect(
        file.releasePersistedAccess(),
        throwsA(
          isA<FilePickerException>().having(
            (e) => e.code,
            'code',
            FilePickerErrorCode.persistenceFailed,
          ),
        ),
      );
    });
  });

  group('toString', () {
    test('says "unknown" for unknown metadata instead of printing null', () {
      final text = fileWith().toString();
      expect(text, contains('unknown'));
      expect(text, contains('report.pdf'));
    });

    test('includes the values when they are known', () {
      final text = fileWith(
        size: 42,
        mimeType: 'application/pdf',
        path: '/cache/a.pdf',
      ).toString();
      expect(text, contains('42'));
      expect(text, contains('application/pdf'));
      expect(text, contains('/cache/a.pdf'));
    });
  });
}
