/// FFI bindings for the dartnative_file_picker native layer (iOS + Android).
///
/// On iOS the `@_cdecl` symbols are linked into the app binary by CocoaPods, so
/// they resolve through `DynamicLibrary.process()`. On Android the JNI bridge
/// lives in `libdartnative_file_picker.so`.
///
/// [FilePickerFFIBindings.loadSymbols] is called for you by
/// `DartNativePluginRegistrant.registerAll()` — the generated registrant picks
/// it up from this package's `dartnative.registrant` pubspec block. Apps use
/// [FilePicker] and never touch this class.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../exceptions.dart';
import 'native_codec.dart';
import 'resource_gateway.dart';

// ── Native C typedefs ────────────────────────────────────────────────────────

typedef _SetDispatcherC = Void Function(Int64);
typedef _SetDispatcherDart = void Function(int);

typedef _ResetC = Void Function();
typedef _ResetDart = void Function();

typedef _PickC = Void Function(Int64, Pointer<Utf8>);
typedef _PickDart = void Function(int, Pointer<Utf8>);

typedef _OpenC = Void Function(Int64, Pointer<Utf8>);
typedef _OpenDart = void Function(int, Pointer<Utf8>);

typedef _ReadNextC = Void Function(Int64, Int64, Int32);
typedef _ReadNextDart = void Function(int, int, int);

typedef _CloseC = Void Function(Int64);
typedef _CloseDart = void Function(int);

typedef _CopyC = Void Function(Int64, Pointer<Utf8>, Pointer<Utf8>);
typedef _CopyDart = void Function(int, Pointer<Utf8>, Pointer<Utf8>);

typedef _ReleaseC = Void Function(Int64, Pointer<Utf8>);
typedef _ReleaseDart = void Function(int, Pointer<Utf8>);

typedef _ResolveC = Void Function(Int64, Pointer<Utf8>);
typedef _ResolveDart = void Function(int, Pointer<Utf8>);

// ── The one dispatcher for the whole plugin ──────────────────────────────────
//
// The dispatcher-slot pattern ("option 3" in DartNative's
// plugin_async_callbacks.md), as implemented by the first-party
// dartnative_share plugin:
//
//   * ONE Pointer.fromFunction for the entire plugin, never one per request.
//   * Native keeps its address in a single slot it registers once with the
//     framework (iOS: DNRegisterAsyncDispatcherSlot; Android: the pointer
//     paired with DN_IsolateGen()), re-reads it before every fire, and always
//     fires on the main thread.
//   * On hot restart the framework invalidates the slot BEFORE the old
//     isolate's trampolines die, so a picker still on screen across a restart
//     delivers into a zeroed slot and is dropped rather than calling freed
//     memory ("Callback invoked after it has been deleted" → SIGABRT).
//
// Every reply is routed by `token`, so a token minted before a hot restart
// simply finds no handler in the new session and is ignored.
//
// Deviation from the doc's sketch, deliberate: the payload is length-delimited
// bytes (`const uint8_t*`, `int32 len`) rather than a NUL-terminated C string,
// so JSON replies (UTF-8 bytes) and file chunks (arbitrary bytes, NULs
// included) share the same single slot. Base64 would otherwise be needed to
// push binary through a C string, inflating every chunk by a third for nothing.

/// A JSON payload: a result envelope, or an error envelope.
const int _eventJson = 1;

/// A chunk of file bytes.
const int _eventChunk = 2;

/// End of the current read.
const int _eventEof = 3;

typedef _DispatchC = Void Function(Int64, Int32, Pointer<Uint8>, Int32);

/// One reply from native code.
///
/// Inert by design: the dispatcher runs *inside* the native call, so it must
/// never throw and never decode. It copies what arrived and completes the
/// waiting future; interpretation happens later, in async Dart.
final class _NativeEvent {
  const _NativeEvent(this.type, {this.json, this.bytes});

  final int type;
  final String? json;
  final Uint8List? bytes;
}

/// The single dispatcher. Must stay a top-level function:
/// `Pointer.fromFunction` accepts nothing else.
void _dispatch(int token, int type, Pointer<Uint8> data, int length) {
  final completer = FilePickerFFIBindings._pending.remove(token);
  if (completer == null || completer.isCompleted) return;

  // The buffer belongs to native code and is valid only for this call, which
  // is synchronous (Pointer.fromFunction, not NativeCallable.listener). Copy
  // before returning; never hand the view onwards.
  if (type == _eventChunk) {
    final bytes = (data == nullptr || length <= 0)
        ? Uint8List(0)
        : Uint8List.fromList(data.asTypedList(length));
    completer.complete(_NativeEvent(_eventChunk, bytes: bytes));
    return;
  }
  if (type == _eventEof) {
    completer.complete(const _NativeEvent(_eventEof));
    return;
  }
  final json = (data == nullptr || length <= 0)
      ? ''
      : utf8.decode(data.asTypedList(length), allowMalformed: true);
  completer.complete(_NativeEvent(_eventJson, json: json));
}

final Pointer<NativeFunction<_DispatchC>> _dispatchPtr =
    Pointer.fromFunction<_DispatchC>(_dispatch);

/// Loads and owns this plugin's native symbols.
///
/// Also the [FileResourceGateway] implementation that [PlatformFile] reads,
/// copies and releases through.
final class FilePickerFFIBindings implements FileResourceGateway {
  FilePickerFFIBindings._();

  /// The single instance. The native layer keeps one dispatcher slot and one
  /// presentation state machine, so a second instance would be a lie.
  static final FilePickerFFIBindings instance = FilePickerFFIBindings._();

  static late final _PickDart _pick;
  static late final _OpenDart _open;
  static late final _ReadNextDart _readNext;
  static late final _CloseDart _close;
  static late final _CopyDart _copy;
  static late final _ReleaseDart _release;
  static late final _ResolveDart _resolve;

  static bool _loaded = false;

  /// Whether [loadSymbols] has run and the native layer is usable.
  static bool get isLoaded => _loaded;

  /// token to the future awaiting that token's single reply.
  ///
  /// Exactly one reply per token: a streamed read mints a fresh token for every
  /// chunk, which keeps the protocol uniform and makes a stale or duplicated
  /// delivery a no-op rather than a cross-wired completion.
  static final Map<int, Completer<_NativeEvent>> _pending =
      <int, Completer<_NativeEvent>>{};

  /// Seeded from the wall clock so a token can never repeat across isolate runs.
  ///
  /// Picks are already safe across a hot restart: `DNFilePickerReset` runs before
  /// the new dispatcher is installed, and it abandons the iOS presentation and
  /// clears Android's pending map, so an old picker's result is neutralized at
  /// its source.
  ///
  /// A read in flight is the one case that is not. Its native task is already
  /// running on an I/O queue; reset closes the stream under it, the resulting
  /// failure is posted to the main thread, and the main thread is busy running
  /// `loadSymbols` — so the post lands *after* the new dispatcher is installed,
  /// when the generation gate legitimately passes. With a counter restarting at 1
  /// every run, that stale token could equal a live token in the new session and
  /// complete an unrelated operation.
  ///
  /// Seeding from microseconds-since-epoch closes it: the base always moves
  /// forward between runs, so the old session's token space and the new one's
  /// cannot overlap. A stale reply then finds no handler and is dropped, which is
  /// the intended behaviour. Still monotonic within a run, and far inside int64.
  static int _nextToken = DateTime.now().microsecondsSinceEpoch;

  /// Resolves every native symbol. Idempotent; safe on unsupported platforms.
  ///
  /// Called by the generated `DartNativePluginRegistrant.registerAll()`. Must
  /// start with a platform guard, because `registerAll()` runs unconditionally
  /// on every platform.
  static void loadSymbols() {
    if (_loaded) return;
    if (!Platform.isIOS && !Platform.isAndroid) return;

    final lib = Platform.isAndroid
        ? DynamicLibrary.open('libdartnative_file_picker.so')
        : DynamicLibrary.process();

    _pick = lib.lookupFunction<_PickC, _PickDart>('DNFilePickerPick');
    _open = lib.lookupFunction<_OpenC, _OpenDart>('DNFilePickerOpen');
    _readNext = lib.lookupFunction<_ReadNextC, _ReadNextDart>(
      'DNFilePickerReadNext',
    );
    _close = lib.lookupFunction<_CloseC, _CloseDart>('DNFilePickerClose');
    _copy = lib.lookupFunction<_CopyC, _CopyDart>('DNFilePickerCopyToCache');
    _release = lib.lookupFunction<_ReleaseC, _ReleaseDart>(
      'DNFilePickerRelease',
    );
    _resolve = lib.lookupFunction<_ResolveC, _ResolveDart>(
      'DNFilePickerResolve',
    );

    // Close read handles and clear presentation state left behind by a previous
    // isolate (hot restart): native code was not restarted with Dart. This is
    // the documented iOS-side equivalent of Android's reset hooks, and it runs
    // on both platforms for one behaviour everywhere.
    lib.lookupFunction<_ResetC, _ResetDart>('DNFilePickerReset')();

    // Hand native the dispatcher address last, so a reply can never arrive
    // before the symbols it needs are resolved.
    lib.lookupFunction<_SetDispatcherC, _SetDispatcherDart>(
      'DNFilePickerSetDispatcher',
    )(_dispatchPtr.address);

    _loaded = true;
  }

  /// Mints a token, invokes [body] with it, and awaits that token's reply.
  ///
  /// The token is always removed from [_pending], including when [body] throws
  /// before native code ever sees it, so a failed invocation cannot leak an
  /// entry that a later token might collide with.
  static Future<_NativeEvent> _request(void Function(int token) body) {
    _ensureLoaded();
    final token = _nextToken++;
    final completer = Completer<_NativeEvent>();
    _pending[token] = completer;
    try {
      body(token);
    } on Object {
      _pending.remove(token);
      rethrow;
    }
    return completer.future;
  }

  static void _ensureLoaded() {
    if (_loaded) return;
    throw const FilePickerException(
      FilePickerErrorCode.nativeFailure,
      'dartnative_file_picker is not initialized. Call '
      'DartNativePluginRegistrant.registerAll() as the first line of main(), '
      'and run `dn pub get` after adding the dependency so the registrant is '
      'regenerated.',
    );
  }

  /// Presents the native document picker and decodes its reply.
  ///
  /// [requestJson] comes from `PickerRequest.toJson`.
  static Future<PickOutcome> pick(String requestJson) async {
    final event = await _withUtf8(requestJson, (ptr) {
      return _request((token) => _pick(token, ptr));
    });
    return decodePickResult(_expectJson(event));
  }

  /// Resolves a document this app persisted access to in an earlier session.
  ///
  /// Replies with the same `{"files":[…]}` shape as a pick: a single record when
  /// the grant and the document are both still there, and an empty list when
  /// either is gone.
  static Future<PickOutcome> resolvePersisted(Uri uri) async {
    final event = await _withUtf8(uri.toString(), (ptr) {
      return _request((token) => _resolve(token, ptr));
    });
    return decodePickResult(_expectJson(event));
  }

  @override
  Stream<Uint8List> openRead(Uri uri, {required int chunkSize}) async* {
    // async* gives the backpressure for free: the generator suspends at `yield`
    // until the consumer asks for more, and only then is the next chunk
    // requested from native. Nothing is read before the first listen, and
    // `finally` runs on cancellation as well as on completion or error, so the
    // native handle (and the iOS security scope it holds) is always released.
    final handle = await _openHandle(uri);
    try {
      while (true) {
        final event = await _request(
          (token) => _readNext(token, handle, chunkSize),
        );
        if (event.type == _eventEof) return;
        if (event.type == _eventJson) {
          // An error envelope mid-read; decodeEnvelope throws it properly.
          decodeEnvelope(event.json ?? '');
          throw const FilePickerException(
            FilePickerErrorCode.readFailed,
            'The native side ended a read without data and without an error.',
          );
        }
        final bytes = event.bytes;
        if (bytes == null || bytes.isEmpty) return;
        yield bytes;
      }
    } finally {
      _close(handle);
    }
  }

  static Future<int> _openHandle(Uri uri) async {
    final event = await _withUtf8(uri.toString(), (ptr) {
      return _request((token) => _open(token, ptr));
    });
    final map = decodeEnvelope(_expectJson(event));
    final handle = map['handle'];
    if (handle is! int || handle == 0) {
      throw const FilePickerException(
        FilePickerErrorCode.readFailed,
        'The native side did not return a read handle.',
      );
    }
    return handle;
  }

  @override
  Future<String> copyToCache(Uri uri, {required String preferredName}) async {
    final uriPtr = uri.toString().toNativeUtf8();
    final namePtr = preferredName.toNativeUtf8();
    final _NativeEvent event;
    try {
      event = await _request((token) => _copy(token, uriPtr, namePtr));
    } finally {
      calloc
        ..free(uriPtr)
        ..free(namePtr);
    }
    final map = decodeEnvelope(_expectJson(event));
    final path = map['path'];
    if (path is! String || path.isEmpty) {
      throw const FilePickerException(
        FilePickerErrorCode.copyFailed,
        'The native side reported a successful copy without a path.',
      );
    }
    return path;
  }

  @override
  Future<bool> releasePersistedAccess(Uri uri) async {
    final event = await _withUtf8(uri.toString(), (ptr) {
      return _request((token) => _release(token, ptr));
    });
    final map = decodeEnvelope(_expectJson(event));
    return map['released'] == true;
  }

  /// Runs [body] with [value] as a native UTF-8 string and frees it afterwards.
  ///
  /// Dart allocates and Dart frees. Native code copies what it needs during the
  /// synchronous call, so the pointer may be released as soon as [body]'s future
  /// is created — but it is held until that future settles, which costs one
  /// small allocation and removes any doubt about the native side reading it
  /// late.
  static Future<_NativeEvent> _withUtf8(
    String value,
    Future<_NativeEvent> Function(Pointer<Utf8> ptr) body,
  ) async {
    final ptr = value.toNativeUtf8();
    try {
      return await body(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  static String _expectJson(_NativeEvent event) {
    if (event.type != _eventJson || event.json == null) {
      throw const FilePickerException(
        FilePickerErrorCode.nativeFailure,
        'The native side replied with bytes where a JSON payload was expected.',
      );
    }
    return event.json!;
  }
}
