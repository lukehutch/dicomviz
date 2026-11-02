import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Sends a message to the owner of a task.
typedef Send = void Function(Object? message);

/// Largest texture side the atlas may use, limited by the GPU. Workers have no
/// document, so [serveWorker] sets it from the main thread's value.
int maxTextureSide = () {
  final gl = web.HTMLCanvasElement().getContext('webgl2') as web.WebGL2RenderingContext?;
  final side = gl?.getParameter(web.WebGLRenderingContext.MAX_TEXTURE_SIZE) as JSNumber?;
  return math.min(side?.toDartInt ?? 4096, 16384);
}();

/// Whether the engine takes raw RGBA8888 images as premultiplied.
const rawImagesArePremultiplied = false;

/// Scanning and volume loading run on the browser's main thread.
const processorCount = 1;

@JS('crossOriginIsolated')
external bool? get _crossOriginIsolated;

@JS('navigator.hardwareConcurrency')
external int get _hardwareConcurrency;

@JS('document')
external JSAny? get _document;

final _inWorker = _document == null;

// Browsers offer SharedArrayBuffer only with the COOP and COEP headers. The
// main thread keeps plain lists: wasm reads a JS-backed list through a call
// to JavaScript, which is about 3 times slower (measured).
final _shareable = _inWorker && _crossOriginIsolated == true;

/// Worker threads that can share memory; see [runWorkerTask].
final int workerThreads = _shareable ? _hardwareConcurrency : 1;

/// Set once the worker script fails to load.
var _noWorkerScript = false;

/// Add ?perf to the URL.
final logFrameTimes = Uri.base.queryParameters.containsKey('perf');

/// A file chosen by the user.
class SourceFile {
  SourceFile(this._file);

  /// The file passed to a worker as [shared].
  SourceFile.attach(Object shared) : _file = shared as web.File;
  final web.File _file;

  Object get shared => _file;

  // Frames of a multi-frame file are shown one at a time, and each needs the
  // whole file, so the last whole file is kept.
  static (web.File, Uint8List)? _last;

  String get path => _file.webkitRelativePath.isEmpty ? _file.name : _file.webkitRelativePath;

  Future<int> length() async => _file.size;

  /// Bytes from [start] to [end], by default the whole file.
  Future<Uint8List> read([int start = 0, int? end]) async {
    final whole = start == 0 && end == null;
    if (whole && identical(_last?.$1, _file)) return _last!.$2;
    final blob = whole ? _file : _file.slice(start, end ?? _file.size);
    final bytes = (await blob.arrayBuffer().toDart).toDart.asUint8List();
    if (whole) _last = (_file, bytes);
    return bytes;
  }
}

class PickedFolder {
  PickedFolder(this.name, this.files);
  final String name;
  final List<SourceFile> files;
}

/// Asks the browser for a folder. Files stay on this computer: they are read
/// here and never sent anywhere. Browsers without folder selection offer a
/// multiple-file selection instead.
Future<PickedFolder?> pickFolder(String? initial) {
  final done = Completer<PickedFolder?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true
    ..setAttribute('webkitdirectory', '');
  input.onchange = (web.Event _) {
    final list = input.files;
    final files = [for (var i = 0; i < (list?.length ?? 0); i++) SourceFile(list!.item(i)!)];
    if (files.isEmpty) return done.complete(null);
    done.complete(PickedFolder(files.first.path.split('/').first, files));
  }.toJS;
  input.oncancel = (web.Event _) {
    done.complete(null);
  }.toJS;
  input.click();
  return done.future;
}

/// Web pages cannot open a folder by path.
Future<PickedFolder> listFolder(String dir) => throw UnsupportedError('listFolder');

String? lastFolder() => null;

void saveLastFolder(String p) {}

/// Runs [task] here; it calls [breathe] to let the UI run.
Future<T> runTask<T>(
  FutureOr<T> Function(Send send) task, [
  void Function(Object? message)? onMessage,
]) async =>
    task((m) => onMessage?.call(m));

/// Runs [request] in a Web Worker, for work too heavy for the main thread:
/// the worker is compiled to JavaScript (tool/reconstruct_worker.dart), since
/// wasm reads shared memory through a JS call per element, which is at least
/// 7 times slower (measured), and it does not hold up the UI. Dart isolates
/// do not exist on the web, so [request]
/// names the work instead of [task] carrying it. It is made of numbers,
/// strings, lists and [shared] handles. [decode] reads the worker's result.
/// Runs [task] here if workers are not usable: without shared memory only
/// one worker runs, and it does the work itself.
Future<T> runWorkerTask<T>(
  List<Object?> Function() request,
  FutureOr<T> Function(Send send) task,
  Send onMessage, [
  T Function(Object? result)? decode,
]) async {
  if (_noWorkerScript || (_inWorker && !_shareable)) return runTask(task, onMessage);
  final result = Completer<Object?>();
  var started = false;
  final worker = web.Worker('reconstruct_worker.js'.toJS);
  worker.onmessage = (web.MessageEvent e) {
    started = true;
    final m = e.data.dartify()! as List<Object?>;
    switch (m[0]) {
      case 'progress':
        onMessage(m[1]);
      case 'done':
        result.complete(m[1]);
      case 'failed':
        result.completeError(StateError(m[1]! as String));
    }
  }.toJS;
  worker.onerror = (web.Event e) {
    if (!result.isCompleted) result.completeError(StateError('Worker failed'));
  }.toJS;
  worker.postMessage(_toJS([maxTextureSide, request()], []));
  try {
    final r = await result.future;
    return decode == null ? r as T : decode(r);
  } on StateError {
    if (started || _inWorker) rethrow;
    _noWorkerScript = true;
    return runTask(task, onMessage);
  } finally {
    worker.terminate();
  }
}

/// Makes this worker run each request with [handle].
void serveWorker(Future<Object?> Function(List<Object?> request, Send send) handle) {
  final self = globalContext as web.DedicatedWorkerGlobalScope;
  void post(String kind, Object? value) {
    final transfer = <JSObject>[];
    final message = _toJS([kind, value], transfer);
    self.postMessage(message, transfer.toJS);
  }

  Future<void> run(List<Object?> m) async {
    maxTextureSide = (m[0]! as num).toInt();
    try {
      post('done', await handle(m[1]! as List<Object?>, (p) => post('progress', p)));
    } catch (e, stack) {
      post('failed', '$e\n$stack');
    }
  }

  self.onmessage = (web.MessageEvent e) {
    run(e.data.dartify()! as List<Object?>);
  }.toJS;
}

JSUint8Array _moved(Uint8List bytes, List<JSObject> transfer) {
  transfer.add(bytes.buffer.toJS);
  return bytes.toJS;
}

/// Converts a message for postMessage. Byte lists are moved, not copied.
JSAny? _toJS(Object? v, List<JSObject> transfer) => switch (v) {
      null => null,
      num() => v.toJS,
      String() => v.toJS,
      Uint8List() => _moved(v, transfer),
      Uint32List() => v.toJS,
      List() => [for (final e in v) _toJS(e, transfer)].toJS,
      _ => v as JSAny,
    };

final _sinceBreath = Stopwatch()..start();

/// Lets the UI run during long work, at most every 30 ms.
Future<void> breathe() async {
  if (_inWorker) return;
  if (_sinceBreath.elapsedMilliseconds < 30) return;
  await Future<void>.delayed(const Duration(milliseconds: 1));
  _sinceBreath.reset();
}

@JS('SharedArrayBuffer')
extension type _SharedBuffer._(JSObject _) implements JSObject {
  external factory _SharedBuffer(int bytes);
}

@JS('Float32Array')
extension type _SharedFloat32Array._(JSFloat32Array _) implements JSFloat32Array {
  external factory _SharedFloat32Array(JSObject buffer);
}

@JS('Int16Array')
extension type _SharedInt16Array._(JSInt16Array _) implements JSInt16Array {
  external factory _SharedInt16Array(JSObject buffer);
}

class SharedFloats {
  factory SharedFloats(int length) {
    if (!_shareable) return SharedFloats._(Float32List(length), null);
    return SharedFloats.attach(_SharedBuffer(length * 4), length);
  }

  /// The memory of another worker's [SharedFloats], given as [shared].
  SharedFloats.attach(Object shared, int length)
      : this._(_SharedFloat32Array(shared as JSObject).toDart, shared);

  SharedFloats._(this.list, this.shared);
  final Float32List list;
  final Object? shared;
  void free() {}
}

class SharedShorts {
  factory SharedShorts(int length) {
    if (!_shareable) return SharedShorts._(Int16List(length), null);
    return SharedShorts.attach(_SharedBuffer(length * 2), length);
  }

  /// The memory of another worker's [SharedShorts], given as [shared].
  SharedShorts.attach(Object shared, int length)
      : this._(_SharedInt16Array(shared as JSObject).toDart, shared);

  SharedShorts._(this.list, this.shared);
  final Int16List list;
  final Object? shared;
  void free() {}
}
