import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'dicom_parser.dart';

/// One DICOM series found in a folder.
class SeriesInfo {
  SeriesInfo({
    required this.uid,
    required this.description,
    required this.modality,
    required this.seriesNumber,
    required this.files,
    required this.rows,
    required this.columns,
    required this.frames,
    required this.isVolume,
  });

  final String uid;
  final String description;
  final String modality;
  final int seriesNumber;
  final List<String> files;
  final int rows;
  final int columns;

  /// Total number of frames (slices, or frames of a multi-frame file).
  final int frames;

  /// True when the frames are parallel slices with known positions, so the
  /// series can be rendered in 3D.
  final bool isVolume;

  String get sizeLabel => '$columns×$rows×$frames';
}

class _Header {
  _Header(this.path, this.f);
  final String path;
  final DicomFile f;
  List<double>? get position => f.doubles(Tag.imagePositionPatient);
  List<double>? get orientation => f.doubles(Tag.imageOrientationPatient);
}

/// Finds all DICOM series under [dir] (recursively).
Future<List<SeriesInfo>> scanFolder(String dir) => Isolate.run(() => _scan(dir));

List<SeriesInfo> _scan(String dir) {
  final headers = <_Header>[];
  for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final h = _readHeader(e.path);
    if (h != null) headers.add(h);
  }
  final groups = <String, List<_Header>>{};
  for (final h in headers) {
    final uid = h.f.string(Tag.seriesInstanceUid) ?? h.path;
    (groups[uid] ??= []).add(h);
  }
  final result = <SeriesInfo>[];
  for (final MapEntry(key: uid, value: hs) in groups.entries) {
    final first = hs.first.f;
    final frames = hs.fold<int>(0, (n, h) => n + h.f.numberOfFrames);
    final singleFrame = hs.every((h) => h.f.numberOfFrames == 1);
    final isVolume = singleFrame &&
        hs.length >= 3 &&
        hs.every((h) =>
            h.position != null &&
            h.orientation?.length == 6 &&
            h.f.rows == first.rows &&
            h.f.columns == first.columns);
    result.add(SeriesInfo(
      uid: uid,
      description: first.string(Tag.seriesDescription) ?? '',
      modality: first.string(Tag.modality) ?? '',
      seriesNumber: first.intOr(Tag.seriesNumber, 0),
      files: [for (final h in hs) h.path]..sort(),
      rows: first.rows,
      columns: first.columns,
      frames: frames,
      isVolume: isVolume,
    ));
  }
  // Volumes first, then by series number.
  result.sort((a, b) {
    if (a.isVolume != b.isVolume) return a.isVolume ? -1 : 1;
    final c = a.seriesNumber.compareTo(b.seriesNumber);
    return c != 0 ? c : a.uid.compareTo(b.uid);
  });
  return result;
}

_Header? _readHeader(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final len = raf.lengthSync();
      if (len < 132) return null;
      // Headers are small; read the start of the file and retry with the
      // whole file only if the needed tags were not reached.
      var bytes = raf.readSync(math.min(len, 256 * 1024));
      if (String.fromCharCodes(bytes, 128, 132) != 'DICM') return null;
      var f = DicomFile.parse(path, bytes, readPixels: false);
      if (f.elements[Tag.rows] == null && bytes.length < len) {
        raf.setPositionSync(0);
        bytes = raf.readSync(len);
        f = DicomFile.parse(path, bytes, readPixels: false);
      }
      if (f.elements[Tag.rows] == null) return null; // no image
      return _Header(path, f);
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// Piecewise-linear map from modality values (e.g. HU) to the 8-bit codes
/// stored on the GPU. Values from [lo] to [knee] get most of the codes
/// (0..[kneeCode]); the rest, up to [hi], is compressed into the remaining
/// codes, so that bright metal does not cost precision in tissue and bone.
class DensityMap {
  const DensityMap(this.lo, this.knee, this.hi, this.kneeCode);

  final double lo;
  final double knee;
  final double hi;
  final double kneeCode;

  factory DensityMap.forRange(double min, double max) {
    final lo = math.max(min, -1024.0);
    final hi = math.max(max, lo + 1);
    const preferredKnee = 3000.0;
    if (hi <= preferredKnee) return DensityMap(lo, hi, hi, 255);
    return DensityMap(lo, preferredKnee, hi, 223);
  }

  /// Code in 0..255 (fractional) for value [v].
  double encode(double v) {
    if (v <= lo) return 0;
    if (v >= hi) return 255;
    if (v <= knee) return (v - lo) / (knee - lo) * kneeCode;
    return kneeCode + (v - knee) / (hi - knee) * (255 - kneeCode);
  }

  /// Value for code [c] in 0..255.
  double decode(double c) {
    if (c <= kneeCode) return lo + c / kneeCode * (knee - lo);
    return knee + (c - kneeCode) / (255 - kneeCode) * (hi - knee);
  }
}

/// A volume ready for upload: 8-bit codes packed into an RGB atlas.
class VolumeData {
  VolumeData({
    required this.dims,
    required this.spacing,
    required this.axes,
    required this.atlas,
    required this.atlasCols,
    required this.atlasWidth,
    required this.atlasHeight,
    required this.map,
    required this.histogram,
    required this.minValue,
    required this.maxValue,
  });

  /// Size in voxels (x = columns, y = rows, z = slices).
  final List<int> dims;

  /// Voxel size in mm (x, y, z).
  final List<double> spacing;

  /// Patient-space directions of the volume's x, y and z axes (row
  /// direction, column direction, slice normal), 9 values.
  final List<double> axes;

  /// RGBA8888 pixels. Each texel holds slices 3g, 3g+1, 3g+2 in R, G, B.
  final Uint8List atlas;
  final int atlasCols;
  final int atlasWidth;
  final int atlasHeight;
  final DensityMap map;

  /// Voxel counts per 8-bit code.
  final Int64List histogram;
  final double minValue;
  final double maxValue;

  int get groups => (dims[2] + 2) ~/ 3;
}

/// Largest atlas side we create. The volume is downsampled when needed.
const maxAtlasSide = 16384;

typedef Progress = void Function(double fraction, String stage);

/// Loads a volume series in a background isolate.
Future<VolumeData> loadVolume(SeriesInfo s, {Progress? onProgress}) async {
  final port = ReceivePort();
  var decoded = 0;
  final total = s.files.length;
  port.listen((m) {
    if (onProgress == null) return;
    if (m is int) {
      decoded += m;
      onProgress(0.8 * decoded / total, 'Decoding slice $decoded of $total');
    } else if (m is List) {
      onProgress(m[0] as double, m[1] as String);
    }
  });
  try {
    return await _runLoadVolume(s.files, port.sendPort);
  } finally {
    port.close();
  }
}

// Isolates are started from these small functions so that each closure
// captures only its arguments: a closure sent to an isolate carries its
// whole enclosing context.
Future<VolumeData> _runLoadVolume(List<String> files, SendPort progress) =>
    Isolate.run(() => _loadVolume(files, progress));

Future<List<Int16List>> _runDecodeSlices(List<String> paths, SendPort progress) =>
    Isolate.run(() => _decodeSlices(paths, progress));

List<Int16List> _decodeSlices(List<String> paths, SendPort progress) {
  final out = <Int16List>[];
  for (final p in paths) {
    final f = DicomFile.parse(p, File(p).readAsBytesSync());
    final v = f.decodeFrame(0);
    final s = Int16List(v.length);
    for (var i = 0; i < v.length; i++) {
      s[i] = v[i].round().clamp(-32768, 32767);
    }
    out.add(s);
    progress.send(1);
  }
  return out;
}

Future<VolumeData> _loadVolume(List<String> files, SendPort progress) async {
  // Read geometry and sort slices along the normal.
  final headers = [for (final p in files) _readHeader(p)!];
  final o = headers.first.orientation!;
  final rowDir = [o[0], o[1], o[2]];
  final colDir = [o[3], o[4], o[5]];
  final normal = [
    rowDir[1] * colDir[2] - rowDir[2] * colDir[1],
    rowDir[2] * colDir[0] - rowDir[0] * colDir[2],
    rowDir[0] * colDir[1] - rowDir[1] * colDir[0],
  ];
  double along(_Header h) {
    final p = h.position!;
    return p[0] * normal[0] + p[1] * normal[1] + p[2] * normal[2];
  }

  headers.sort((a, b) => along(a).compareTo(along(b)));
  final first = headers.first.f;
  final w = first.columns;
  final h = first.rows;
  final n = headers.length;
  final ps = first.doubles(Tag.pixelSpacing) ?? [1.0, 1.0];
  // PixelSpacing is (row spacing, column spacing).
  final sx = ps.length > 1 ? ps[1] : ps[0];
  final sy = ps[0];
  var sz = n > 1 ? (along(headers.last) - along(headers.first)) / (n - 1) : 1.0;
  if (sz.abs() < 1e-6) sz = first.number(Tag.sliceThickness) ?? 1.0;

  // Decode slices in parallel worker isolates.
  final paths = [for (final hd in headers) hd.path];
  final workers = math.max(1, math.min(Platform.numberOfProcessors, 16));
  final slices = List<Int16List?>.filled(n, null);
  final futures = <Future<void>>[];
  for (var wi = 0; wi < workers; wi++) {
    final mine = [for (var i = wi; i < n; i += workers) i];
    final myPaths = [for (final i in mine) paths[i]];
    futures.add(() async {
      final result = await _runDecodeSlices(myPaths, progress);
      for (var k = 0; k < mine.length; k++) {
        slices[mine[k]] = result[k];
      }
    }());
  }
  await Future.wait(futures);
  progress.send([0.8, 'Packing volume']);

  // Value range.
  var mn = 32767, mx = -32768;
  for (final s in slices) {
    for (final v in s!) {
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
  }
  final map = DensityMap.forRange(mn.toDouble(), mx.toDouble());

  // Code lookup for every int16 value in range.
  final lut = Uint8List(mx - mn + 1);
  for (var v = mn; v <= mx; v++) {
    lut[v - mn] = map.encode(v.toDouble()).round().clamp(0, 255);
  }

  // Downsample by 2 in each axis if the atlas would be too large.
  var f = 1;
  int dw(int f) => (w + f - 1) ~/ f;
  int dh(int f) => (h + f - 1) ~/ f;
  int dn(int f) => (n + f - 1) ~/ f;
  (int, int, int) layout(int f) {
    final groups = (dn(f) + 2) ~/ 3;
    var best = (1, 1 << 40, 1 << 40);
    for (var cols = 1; cols <= groups; cols++) {
      final rows = (groups + cols - 1) ~/ cols;
      final aw = cols * dw(f), ah = rows * dh(f);
      if (math.max(aw, ah) < math.max(best.$2, best.$3)) best = (cols, aw, ah);
    }
    return best;
  }

  var (cols, aw, ah) = layout(f);
  while (math.max(aw, ah) > maxAtlasSide) {
    f *= 2;
    (cols, aw, ah) = layout(f);
  }
  final vw = dw(f), vh = dh(f), vn = dn(f);
  final atlas = Uint8List(aw * ah * 4);
  for (var i = 3; i < atlas.length; i += 4) {
    atlas[i] = 255;
  }
  final hist = Int64List(256);
  for (var z = 0; z < vn; z++) {
    final g = z ~/ 3, ch = z % 3;
    final tx = (g % cols) * vw, ty = (g ~/ cols) * vh;
    final src = slices[z * f]!;
    for (var y = 0; y < vh; y++) {
      final rowOff = ((ty + y) * aw + tx) * 4 + ch;
      final srcOff = y * f * w;
      for (var x = 0; x < vw; x++) {
        final c = lut[src[srcOff + x * f] - mn];
        atlas[rowOff + x * 4] = c;
        hist[c]++;
      }
    }
    if (z % 32 == 0) progress.send([0.8 + 0.2 * z / vn, 'Packing']);
  }

  return VolumeData(
    dims: [vw, vh, vn],
    spacing: [sx * f, sy * f, sz.abs() * f],
    axes: [...rowDir, ...colDir, ...normal],
    atlas: atlas,
    atlasCols: cols,
    atlasWidth: aw,
    atlasHeight: ah,
    map: map,
    histogram: hist,
    minValue: mn.toDouble(),
    maxValue: mx.toDouble(),
  );
}

/// A stack of 2D frames (single images or a multi-frame object).
class ImageStack {
  ImageStack(this.series, this.frameRefs);
  final SeriesInfo series;

  /// (file, frame index within the file) for each frame.
  final List<(String, int)> frameRefs;
  int get length => frameRefs.length;
}

Future<ImageStack> openImageStack(SeriesInfo s) => Isolate.run(() {
      final refs = <(String, int)>[];
      for (final p in s.files) {
        final h = _readHeader(p);
        final n = h?.f.numberOfFrames ?? 1;
        for (var i = 0; i < n; i++) {
          refs.add((p, i));
        }
      }
      return ImageStack(s, refs);
    });

/// A decoded 2D frame with a default display window.
class Frame2D {
  Frame2D(this.width, this.height, this.values, this.windowCenter, this.windowWidth);
  final int width;
  final int height;
  final Float32List values;
  final double windowCenter;
  final double windowWidth;
}

Future<Frame2D> loadFrame(String path, int index) => Isolate.run(() {
      final f = DicomFile.parse(path, File(path).readAsBytesSync());
      final v = f.decodeFrame(index);
      var mn = double.infinity, mx = -double.infinity;
      for (final x in v) {
        if (x < mn) mn = x;
        if (x > mx) mx = x;
      }
      final wc = f.doubles(Tag.windowCenter)?.first;
      final ww = f.doubles(Tag.windowWidth)?.first;
      // A window covering the full 16-bit range is no better than min/max.
      final useTags = wc != null && ww != null && ww > 1 && ww < 65536;
      return Frame2D(f.columns, f.rows, v, useTags ? wc : (mn + mx) / 2,
          useTags ? ww : math.max(mx - mn, 1));
    });
