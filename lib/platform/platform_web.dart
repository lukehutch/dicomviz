import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Sends a message to the owner of a task.
typedef Send = void Function(Object? message);

/// Largest texture side the atlas may use, limited by the GPU.
final int maxTextureSide = () {
  final gl = web.HTMLCanvasElement().getContext('webgl2') as web.WebGL2RenderingContext?;
  final side = gl?.getParameter(web.WebGLRenderingContext.MAX_TEXTURE_SIZE) as JSNumber?;
  return math.min(side?.toDartInt ?? 4096, 16384);
}();

/// Whether the engine takes raw RGBA8888 images as premultiplied.
const rawImagesArePremultiplied = false;

/// All work runs on the browser's main thread.
const processorCount = 1;

/// Add ?perf to the URL.
final logFrameTimes = Uri.base.queryParameters.containsKey('perf');

/// A file chosen by the user.
class SourceFile {
  SourceFile(this._file);
  final web.File _file;

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

final _sinceBreath = Stopwatch()..start();

/// Lets the UI run during long work, at most every 30 ms.
Future<void> breathe() async {
  if (_sinceBreath.elapsedMilliseconds < 30) return;
  await Future<void>.delayed(const Duration(milliseconds: 1));
  _sinceBreath.reset();
}

class SharedFloats {
  SharedFloats(int length) : list = Float32List(length);
  final Float32List list;
  void free() {}
}

class SharedShorts {
  SharedShorts(int length) : list = Int16List(length);
  final Int16List list;
  void free() {}
}
