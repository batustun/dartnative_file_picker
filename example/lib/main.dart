/// file_picker example.
///
/// Exercises every public API against the real system picker, so this app is
/// also the manual verification harness:
///
///   * FilePicker.pickFile()                       single selection, any type
///   * FilePicker.pickFiles()                      multiple selection
///   * FileType.custom + allowedExtensions         PDF / spreadsheet filter
///   * FileType.image                              category filter
///   * FilePickerAccessMode.copyToCache            path is non-null
///   * FilePickerOptions.persistAccess             survives a restart
///   * FilePicker.openPersisted(uri)               reopen after a restart
///   * PlatformFile.readAsBytes()                  whole document in memory
///   * PlatformFile.readAsByteStream()             chunked, constant memory
///   * PlatformFile.copyToCache()                  materialize a real file
///   * PlatformFile.releasePersistedAccess()       give the grant back
///   * cancellation                                null / empty, never a throw
///   * FilePickerException                         typed, actionable errors
library;

import 'dart:io';

import 'package:dartnative/dartnative.dart';
import 'package:file_picker/file_picker.dart';

import 'dartnative_plugin_registrant.dart';

void main() {
  DartNativePluginRegistrant.registerAll();
  SystemChrome.defaultStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.light,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
  );
  runApp(const FilePickerDemo());
}

/// Validation instrumentation.
///
/// Every observable value is echoed to the Dart log under one prefix, so a
/// device-validation run can be read from `dn run` output instead of transcribed
/// off the phone screen. `dn screenshot` does not work on a physical iPhone and
/// the libimobiledevice screenshot service is unavailable on iOS 26, so this is
/// how the results in doc/validation/ get their values.
void _t(String line) => debugPrint('DNFP-TEST $line');

void _logFile(PlatformFile f, {required int index}) {
  _t(
    'file[$index] name="${f.name}" ext=${f.extension} '
    'size=${f.size} mime=${f.mimeType} '
    'persisted=${f.persistedAccess} path=${f.path} uri=${f.uri}',
  );
}

/// Keeps the stored URI after `releasePersistedAccess()`, which a real app should
/// **not** do: once a grant is released the URI is useless and should go with it,
/// which is what the default here does.
///
/// Set it to true only to re-run the device check for the released-grant path.
/// `openPersisted` must answer `null` for a URI whose grant is gone, and proving
/// that after a cold launch requires the app to still be holding the URI. It was
/// on for validation rows 1.3.4 and 2.1.6; see `doc/validation/`.
const bool _keepUriAfterRelease = false;

const Color _ink = Color(0xFF111111);
const Color _muted = Color(0xFF6B7280);
const Color _line = Color(0xFFE5E7EB);
const Color _accent = Color(0xFF2563EB);

class FilePickerDemo extends StatefulWidget {
  const FilePickerDemo({super.key});

  @override
  State<FilePickerDemo> createState() => _FilePickerDemoState();
}

class _FilePickerDemoState extends State<FilePickerDemo> {
  List<PlatformFile> _files = const <PlatformFile>[];
  String _status = 'Pick a document to begin.';

  /// The URI of the last document picked with persistAccess.
  ///
  /// Written to disk, not just held in memory: the whole point of
  /// `persistAccess` is that the document outlives the process, so a harness
  /// that kept this in a field could never test it — after a force quit the
  /// field is null and `openPersisted` is never reached.
  ///
  /// A temp file keeps the example dependency-free. A real app would use
  /// `dartnative_shared_preferences` or its own database; the package itself
  /// stores nothing on your behalf, it only hands you `PlatformFile.uri`.
  Uri? _persistedUri;

  File get _persistedUriFile =>
      File('${Directory.systemTemp.path}/dnfp_persisted_uri.txt');

  Uri? _referenceUri;
  File get _referenceUriFile =>
      File('${Directory.systemTemp.path}/dnfp_reference_uri.txt');

  /// Remembers the URI of a pick that did **not** ask for persistence.
  ///
  /// Exists to test the one thing `persistedAccess == false` promises on
  /// Android: the grant the plugin took so the document could be read this
  /// session must not survive a restart, and `openPersisted` must refuse it
  /// even while it does survive. Without storing this URI there is nothing to
  /// call `openPersisted` with after a force stop.
  void _rememberReference(Uri uri) {
    _referenceUri = uri;
    try {
      _referenceUriFile.writeAsStringSync(uri.toString());
    } on FileSystemException catch (e) {
      _t('reference uri store FAILED: ${e.message}');
    }
  }

  void _rememberPersisted(Uri? uri) {
    _persistedUri = uri;
    try {
      if (uri == null) {
        if (_persistedUriFile.existsSync()) _persistedUriFile.deleteSync();
        _t('persisted uri forgotten');
      } else {
        _persistedUriFile.writeAsStringSync(uri.toString());
        _t('persisted uri saved to ${_persistedUriFile.path}');
      }
    } on FileSystemException catch (e) {
      _t('persisted uri store FAILED: ${e.message}');
    }
  }

  @override
  void initState() {
    super.initState();
    try {
      if (_persistedUriFile.existsSync()) {
        final saved = _persistedUriFile.readAsStringSync().trim();
        _persistedUri = saved.isEmpty ? null : Uri.tryParse(saved);
      }
    } on FileSystemException catch (e) {
      _t('persisted uri load FAILED: ${e.message}');
    }
    try {
      if (_referenceUriFile.existsSync()) {
        final saved = _referenceUriFile.readAsStringSync().trim();
        _referenceUri = saved.isEmpty ? null : Uri.tryParse(saved);
      }
    } on FileSystemException catch (e) {
      _t('reference uri load FAILED: ${e.message}');
    }
    _t('startup: persistedUri=${_persistedUri ?? 'none'}');
    _t('startup: referenceUri=${_referenceUri ?? 'none'}');
  }

  /// Per-file result lines, keyed by URI: the outcome of a read, stream or copy.
  final Map<String, String> _results = <String, String>{};

  // ── Actions ────────────────────────────────────────────────────────────────

  /// Runs [action] and turns every outcome into something visible on screen.
  ///
  /// This is the whole error-handling story for the API: cancellation comes back
  /// as an empty selection and is reported as such, while a real failure is a
  /// FilePickerException carrying a code worth branching on.
  Future<void> _pick(
    String label,
    Future<List<PlatformFile>> Function() action,
  ) async {
    setState(() => _status = '$label…');
    try {
      final picked = await action();
      _t('pick "$label" → ${picked.length} file(s)');
      for (var i = 0; i < picked.length; i++) {
        _logFile(picked[i], index: i);
      }
      if (!mounted) return;
      setState(() {
        _files = picked;
        _results.clear();
        _status = picked.isEmpty
            ? 'Cancelled. Nothing was selected, and nothing was thrown.'
            : '$label: ${picked.length} document(s).';
      });
    } on FilePickerException catch (e) {
      _t(
        'pick "$label" FAILED code=${e.code.name} native=${e.nativeCode} '
        'message="${e.message}"',
      );
      if (!mounted) return;
      setState(
        () => _status = e.code == FilePickerErrorCode.unsupportedType
            ? 'Enforced: ${e.message}'
            : 'Failed (${e.code.name}): ${e.message}',
      );
      // pickerBusy is the one a user can trip by double-tapping, so show it.
      if (e.code == FilePickerErrorCode.pickerBusy) {
        await showAlert(
          context: context,
          title: 'A picker is already open',
          message: e.message,
        );
      }
    }
  }

  Future<void> _pickSingle() => _pick('Single, any type', () async {
    final file = await FilePicker.pickFile();
    if (file == null) return const <PlatformFile>[];
    _rememberReference(file.uri);
    return <PlatformFile>[file];
  });

  Future<void> _pickMultiple() =>
      _pick('Multiple, any type', () => FilePicker.pickFiles());

  /// Picks one document and **keeps the previous cards on screen**.
  ///
  /// Every other action replaces the selection, which makes one case
  /// untestable: pick A, pick B, then read A. On Android that is the regression
  /// test for grant ownership, because a referenced document's URI grant must
  /// survive a later pick. Tap this twice and read the first card.
  Future<void> _pickAppend() async {
    setState(() => _status = 'Append pick…');
    try {
      final file = await FilePicker.pickFile();
      if (file == null) {
        _t('pick "append" → cancelled');
        if (!mounted) return;
        setState(() => _status = 'Cancelled. The earlier documents are kept.');
        return;
      }
      _t('pick "append" → ${file.name}');
      _logFile(file, index: _files.length);
      if (!mounted) return;
      setState(() {
        _files = <PlatformFile>[..._files, file];
        _status =
            'Appended ${file.name}. ${_files.length} document(s) held; read '
            'the first card to prove the earlier grant survived.';
      });
    } on FilePickerException catch (e) {
      _t('pick "append" FAILED code=${e.code.name} message="${e.message}"');
      if (!mounted) return;
      setState(() => _status = 'Failed (${e.code.name}): ${e.message}');
    }
  }

  Future<void> _pickDocuments() => _pick(
    'Documents only',
    () => FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'csv', 'xlsx', 'docx'],
    ),
  );

  Future<void> _pickImages() =>
      _pick('Images', () => FilePicker.pickFiles(type: FileType.image));

  /// A filter that widens **and** has a valid member, so a mixed selection can
  /// be partly accepted.
  ///
  /// `abcxyz` has no MIME type, so Android widens the picker to everything and a
  /// non-PDF becomes selectable; `pdf` is valid. Selecting a PDF together with
  /// something else must return **only** the PDF — the documented "a partly valid
  /// selection returns the valid subset". On iOS the dynamic UTI keeps the picker
  /// precise, so only the PDF is offered in the first place.
  Future<void> _pickMixedFilter() => _pick(
    'Mixed filter',
    () => FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'abcxyz'],
    ),
  );

  /// Demonstrates post-selection enforcement of `allowedExtensions`.
  ///
  /// `abcxyz` has no known MIME type, so the Android picker cannot express it and
  /// widens to everything. Pick a JPG or a PDF here and the call fails with
  /// `unsupportedType` instead of returning a file that was never allowed. iOS
  /// filters precisely via a dynamic UTI, so the picker itself shows nothing to
  /// choose.
  Future<void> _pickUnknownExtension() => _pick(
    'Unknown extension',
    () => FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['abcxyz'],
    ),
  );

  Future<void> _pickCopied() => _pick(
    'Copied to cache',
    () => FilePicker.pickFiles(
      options: const FilePickerOptions(
        accessMode: FilePickerAccessMode.copyToCache,
      ),
    ),
  );

  Future<void> _pickPersisted() => _pick('Persisted', () async {
    final file = await FilePicker.pickFile(
      options: const FilePickerOptions(persistAccess: true),
    );
    if (file == null) return const <PlatformFile>[];
    // persistedAccess is the platform's answer, not the request: an Android
    // provider may decline, and the pick still succeeds.
    _rememberPersisted(file.persistedAccess ? file.uri : null);
    return <PlatformFile>[file];
  });

  /// Deliberately starts two picks at once to show the busy guard.
  Future<void> _pickTwiceAtOnce() async {
    setState(() => _status = 'Starting two picks at once…');
    _t('concurrency: starting pick #1');
    final first = FilePicker.pickFile();
    _t('concurrency: isPresenting=${FilePicker.isPresenting}');
    try {
      _t('concurrency: starting pick #2 while #1 is open');
      await FilePicker.pickFile();
      _t('concurrency: pick #2 was NOT rejected — THIS IS A BUG');
      if (mounted) {
        setState(() => _status = 'The second pick was NOT rejected (a bug).');
      }
    } on FilePickerException catch (e) {
      _t('concurrency: pick #2 rejected with code=${e.code.name}');
      if (mounted) {
        setState(
          () => _status = 'Second pick rejected as expected: ${e.code.name}.',
        );
      }
    }
    // The first picker is still on screen; let it finish normally.
    final file = await first;
    _t(
      'concurrency: pick #1 finished with '
      '${file == null ? 'cancel' : 'a file'}; '
      'isPresenting=${FilePicker.isPresenting}',
    );
    if (file != null) _logFile(file, index: 0);
    if (!mounted) return;
    setState(() {
      _files = file == null ? const <PlatformFile>[] : <PlatformFile>[file];
      _status = file == null
          ? 'Second pick was rejected; first picker cancelled. Guard released.'
          : 'Second pick was rejected; first picker returned a file.';
    });
  }

  /// Calls `openPersisted` with a URI from a pick that asked for no persistence.
  ///
  /// The expected answer is `null`, in both situations worth distinguishing:
  /// within the session the grant still exists but was never the caller's, and
  /// after a restart it is gone altogether.
  Future<void> _reopenReference() async {
    final uri = _referenceUri;
    if (uri == null) {
      setState(() => _status = 'Pick with "Single" first.');
      return;
    }
    setState(() => _status = 'Reopening the last reference URI…');
    final file = await FilePicker.openPersisted(uri);
    _t(
      'openPersisted(reference uri) → '
      '${file == null ? 'null (correct: it was never persisted)' : 'RESOLVED (a bug)'}',
    );
    if (!mounted) return;
    setState(
      () => _status = file == null
          ? 'null, as it must be: the grant was never the caller\'s.'
          : 'BUG: a non-persisted document resolved.',
    );
  }

  Future<void> _reopenPersisted() async {
    final uri = _persistedUri;
    if (uri == null) {
      setState(() => _status = 'Pick with "Persisted" first.');
      return;
    }
    setState(() => _status = 'Reopening the persisted document…');
    final file = await FilePicker.openPersisted(uri);
    _t(
      'openPersisted($uri) → ${file == null ? 'null (grant or document gone)' : 'resolved'}',
    );
    if (file != null) _logFile(file, index: 0);
    if (!mounted) return;
    setState(() {
      if (file == null) {
        _status = 'The grant or the document is gone. Pick it again.';
        _files = const <PlatformFile>[];
      } else {
        _status = 'Reopened from a persisted grant.';
        _files = <PlatformFile>[file];
      }
    });
  }

  Future<void> _run(
    PlatformFile file,
    String label,
    Future<String> Function() body,
  ) async {
    setState(() => _results[file.uri.toString()] = '$label…');
    try {
      final message = await body();
      _t('action "$label" on "${file.name}" → $message');
      if (!mounted) return;
      setState(() => _results[file.uri.toString()] = message);
    } on FilePickerException catch (e) {
      _t(
        'action "$label" on "${file.name}" FAILED code=${e.code.name} '
        'native=${e.nativeCode} message="${e.message}"',
      );
      if (!mounted) return;
      setState(
        () => _results[file.uri.toString()] = '${e.code.name}: ${e.message}',
      );
    }
  }

  Future<void> _readAll(PlatformFile file) => _run(file, 'Reading', () async {
    final bytes = await file.readAsBytes();
    return 'readAsBytes: ${_bytes(bytes.length)} in memory.';
  });

  Future<void> _streamIt(
    PlatformFile file, {
    int chunkSize = defaultChunkSize,
  }) => _run(file, 'Streaming ${_bytes(chunkSize)} chunks', () async {
    // Progress and throughput are logged as the stream runs, not only at the
    // end. Without that, a slow stream and a stalled stream look identical from
    // outside, which is exactly the ambiguity that cost a 10-minute device run.
    final started = DateTime.now();
    var chunks = 0;
    var total = 0;
    var largest = 0;
    var nextReportAt = 8 * 1024 * 1024;

    String rate(int bytes, int ms) => ms <= 0
        ? 'n/a'
        : '${(bytes / 1048576 / (ms / 1000)).toStringAsFixed(2)} MB/s';

    await for (final chunk in file.readAsByteStream(chunkSize: chunkSize)) {
      chunks++;
      total += chunk.length;
      if (chunk.length > largest) largest = chunk.length;
      if (total >= nextReportAt) {
        final ms = DateTime.now().difference(started).inMilliseconds;
        _t(
          'stream progress: ${_bytes(total)} of ${_bytes(file.size ?? 0)} '
          'in $chunks chunk(s), ${ms}ms, ${rate(total, ms)}, '
          '${(ms / chunks).toStringAsFixed(2)}ms per chunk',
        );
        nextReportAt = total + 8 * 1024 * 1024;
      }
    }

    final ms = DateTime.now().difference(started).inMilliseconds;
    return 'Streamed ${_bytes(total)} in $chunks chunk(s), '
        'largest ${_bytes(largest)}, ${ms}ms, ${rate(total, ms)}, '
        '${chunks == 0 ? 'n/a' : (ms / chunks).toStringAsFixed(2)}ms per chunk.';
  });

  Future<void> _copy(PlatformFile file) => _run(file, 'Copying', () async {
    final path = await file.copyToCache();
    // Verifying here, not just reporting the path: the contract is that the
    // copy is complete and valid by the time the future resolves, and the only
    // way to show that is to stat it and compare against the source size.
    final copied = File(path);
    final exists = copied.existsSync();
    final length = exists ? copied.lengthSync() : -1;
    final expected = file.size;
    final verdict = !exists
        ? 'MISSING'
        : (expected == null
              ? 'size=$length (source size unknown)'
              : (length == expected
                    ? 'size matches ($length)'
                    : 'SIZE MISMATCH: copy=$length source=$expected'));
    return 'Copied to $path · $verdict';
  });

  /// Opens a native modal sheet and offers a pick from inside it.
  ///
  /// This is the case the dedicated presentation window exists for: UIKit
  /// dismisses a presented controller together with its presenter, so a picker
  /// presented *by* a modal would be torn down with that modal. The first-party
  /// share plugin hit exactly this, which is why the picker gets a window of its
  /// own rather than being presented from the top-most view controller.
  Future<void> _pickFromModal() async {
    _t('modal: opening a native modal sheet');
    await showModalSheet<void>(
      context: context,
      detent: SheetDetent.fitContent,
      builder: (sheetContext) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A modal is open',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pick from here: the picker must appear ABOVE this sheet and '
              'must not be dismissed with it.',
              style: TextStyle(fontSize: 13, color: _muted),
            ),
            const SizedBox(height: 16),
            Button(
              title: 'Pick from inside the modal',
              variant: ButtonVariant.filled,
              color: _accent,
              fontSize: 14,
              onPressed: () {
                _t('modal: picking from inside the modal');
                _pickSingle();
              },
            ),
            const SizedBox(height: 8),
            Button(
              title: 'Pick, then close this modal immediately',
              variant: ButtonVariant.tinted,
              fontSize: 14,
              onPressed: () {
                _t('modal: picking, then closing the modal in the same tap');
                _pickSingle();
                Navigator.pop(sheetContext);
              },
            ),
          ],
        ),
      ),
    );
    _t('modal: sheet closed');
  }

  Future<void> _release(PlatformFile file) => _run(file, 'Releasing', () async {
    await file.releasePersistedAccess();
    // Deliberately keeps the stored URI after releasing, which a real app would
    // not do. It is what makes the "released grant" path testable: an app that
    // still remembers a URI whose grant is gone is exactly the case
    // openPersisted must answer with null, and verifying that after a cold
    // launch proves the bookmark really left UserDefaults rather than just this
    // process's memory.
    if (_persistedUri == file.uri) {
      if (_keepUriAfterRelease) {
        _t('released the grant but kept the uri, to test openPersisted');
      } else {
        _rememberPersisted(null);
      }
    }
    return file.persistedAccess
        ? 'Persisted access released.'
        : 'Nothing was persisted, so this was a no-op.';
  });

  static String _bytes(int count) {
    if (count < 1024) return '$count B';
    if (count < 1024 * 1024) return '${(count / 1024).toStringAsFixed(1)} KB';
    return '${(count / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      brightness: Brightness.light,
      backgroundColor: const Color(0xFFFFFFFF),
      appBar: AppBar(title: const Text('file_picker')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(_status, style: const TextStyle(fontSize: 15, color: _ink)),
          const SizedBox(height: 16),
          _buttons(),
          const SizedBox(height: 8),
          if (_files.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Text(
                'Cancelling the picker returns null from pickFile and an empty '
                'list from pickFiles. It is never an exception.',
                style: TextStyle(fontSize: 13, color: _muted),
              ),
            )
          else
            ..._filesSection(),
        ],
      ),
    );
  }

  Widget _buttons() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      _action('Single', _pickSingle, primary: true),
      _action('Multiple', _pickMultiple, primary: true),
      _action('PDF / CSV / XLSX / DOCX', _pickDocuments),
      _action('Images', _pickImages),
      _action('Unknown ext (enforced)', _pickUnknownExtension),
      _action('Mixed filter (pdf + unknown)', _pickMixedFilter),
      _action('Copy to cache', _pickCopied),
      _action('Persisted', _pickPersisted),
      _action('Reopen persisted', _reopenPersisted),
      _action('Reopen reference uri (expect null)', _reopenReference),
      _action('Two at once', _pickTwiceAtOnce),
      _action('Pick from a modal', _pickFromModal),
      _action('Append pick (keeps previous)', _pickAppend),
    ],
  );

  Widget _action(
    String label,
    Future<void> Function() onPressed, {
    bool primary = false,
  }) => Button(
    title: label,
    variant: primary ? ButtonVariant.filled : ButtonVariant.tinted,
    color: primary ? _accent : null,
    fontSize: 14,
    onPressed: () {
      // Native callbacks run synchronously inside the platform event, so
      // kick the async work off directly rather than deferring it.
      onPressed();
    },
  );

  List<Widget> _filesSection() => [
    const SizedBox(height: 16),
    for (final file in _files) _fileCard(file),
  ];

  Widget _fileCard(PlatformFile file) {
    final result = _results[file.uri.toString()];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            file.name,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
          const SizedBox(height: 8),
          // The URI is the identity. The path usually is not, and is often null.
          _row('uri', file.uri.toString()),
          _row('path', file.path ?? 'null (no local file exists)'),
          _row('mimeType', file.mimeType ?? 'unknown (provider reported none)'),
          _row('size', file.size == null ? 'unknown' : _bytes(file.size!)),
          _row('extension', file.extension ?? 'none'),
          _row('persistedAccess', '${file.persistedAccess}'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _small('readAsBytes', () => _readAll(file)),
              _small('stream 32K', () => _streamIt(file)),
              _small(
                'stream 1M',
                () => _streamIt(file, chunkSize: 1024 * 1024),
              ),
              _small('copyToCache', () => _copy(file)),
              if (file.persistedAccess) _small('release', () => _release(file)),
            ],
          ),
          if (result != null) ...[
            const SizedBox(height: 10),
            Text(result, style: const TextStyle(fontSize: 12, color: _accent)),
          ],
        ],
      ),
    );
  }

  Widget _small(String label, Future<void> Function() onPressed) => Button(
    title: label,
    variant: ButtonVariant.gray,
    fontSize: 12,
    onPressed: () {
      onPressed();
    },
  );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Text(
      '$label: $value',
      style: const TextStyle(fontSize: 12, color: _muted),
    ),
  );
}
