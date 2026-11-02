import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// Sends a message to the owner of a task.
typedef Send = void Function(Object? message);

/// Largest texture side the atlas may use.
const maxTextureSide = 16384;

/// Whether the engine takes raw RGBA8888 images as premultiplied.
const rawImagesArePremultiplied = true;

final processorCount = Platform.numberOfProcessors;

final logFrameTimes = Platform.environment['DICOMVIZ_PERF'] != null;

/// A file chosen by the user. It holds only its path, so it can be sent to
/// another isolate.
class SourceFile {
  SourceFile(this.path);
  final String path;

  Future<int> length() => File(path).length();

  /// Bytes from [start] to [end], by default the whole file.
  Future<Uint8List> read([int start = 0, int? end]) async {
    if (start == 0 && end == null) return File(path).readAsBytes();
    final raf = await File(path).open();
    try {
      await raf.setPosition(start);
      return await raf.read(end! - start);
    } finally {
      await raf.close();
    }
  }
}

class PickedFolder {
  PickedFolder(this.name, this.files);
  final String name;
  final List<SourceFile> files;
}

Future<PickedFolder> listFolder(String dir) async {
  final files = [
    await for (final e in Directory(dir).list(recursive: true, followLinks: false))
      if (e is File) SourceFile(e.path),
  ];
  return PickedFolder(dir, files);
}

/// The last opened folder is kept in ~/.config/dicomviz/last_folder.
File get _lastFolderFile {
  final config = Platform.environment['XDG_CONFIG_HOME'] ??
      '${Platform.environment['HOME']}/.config';
  return File('$config/dicomviz/last_folder');
}

String? lastFolder() {
  try {
    final p = _lastFolderFile.readAsStringSync().trim();
    return p.isNotEmpty && Directory(p).existsSync() ? p : null;
  } catch (_) {
    return null;
  }
}

void saveLastFolder(String p) {
  try {
    _lastFolderFile
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(p);
  } catch (_) {}
}

/// Runs [task] in a new isolate. Its messages reach [onMessage] here. A
/// closure sent to an isolate carries its whole enclosing context, so
/// callers create [task] in a small function that holds only its arguments.
Future<T> runTask<T>(
  FutureOr<T> Function(Send send) task, [
  void Function(Object? message)? onMessage,
]) async {
  final port = ReceivePort();
  port.listen((m) => onMessage?.call(m));
  try {
    return await _spawn(task, port.sendPort);
  } finally {
    port.close();
  }
}

Future<T> _spawn<T>(FutureOr<T> Function(Send send) task, SendPort port) =>
    Isolate.run(() => task(port.send));

/// Lets the UI run during long work. Isolates do not need it.
FutureOr<void> breathe() {}

// Native memory, so that worker isolates can share the projections and the
// volume instead of each receiving a copy.
final _malloc = DynamicLibrary.process()
    .lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('malloc');
final _free = DynamicLibrary.process()
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');

int _alloc(int bytes) {
  final p = _malloc(bytes);
  if (p.address == 0) throw StateError('Out of memory');
  return p.address;
}

class SharedFloats {
  SharedFloats(this.length) : _address = _alloc(math.max(length, 1) * 4);
  final int length;
  final int _address;
  Float32List get list => Pointer<Float>.fromAddress(_address).asTypedList(length);
  void free() => _free(Pointer.fromAddress(_address));
}

class SharedShorts {
  SharedShorts(this.length) : _address = _alloc(math.max(length, 1) * 2);
  final int length;
  final int _address;
  Int16List get list => Pointer<Int16>.fromAddress(_address).asTypedList(length);
  void free() => _free(Pointer.fromAddress(_address));
}
