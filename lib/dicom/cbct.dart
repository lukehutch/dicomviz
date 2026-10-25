import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'dicom_parser.dart';
import 'series.dart';

// Cone-beam CT reconstruction (FDK: Feldkamp, Davis and Kress, 1984) from
// the projection series of i-CAT scanners (Imaging Sciences International).

/// Rotation direction and gantry angle of the first frame. The tags do not
/// record them; they were found by matching a reconstruction against the
/// scanner's own volume from the same scan (17-19DX, correlation 0.95-0.97
/// on axial slices at z = +60, 0 and -30 mm).
const _direction = -1.0;
const _startAngleDeg = 147.0;

/// Linear attenuation of water at the effective energy of a 120 kVp beam,
/// 1/mm. A linear fit of the reconstruction against the scanner's HU gave
/// 0.0200.
const _muWater = 0.02;

/// Reconstruction voxel size, mm.
const reconVoxelMm = 0.4;

/// Width of the cosine taper that extends each detector row beyond its
/// last measured pixel, so that a head wider than the beam does not leave a
/// step for the ramp filter to turn into a bright rim.
const _taper = 100;

/// Length of the filter FFT; must exceed twice the tapered row length.
const _fftSize = 2048;

/// Scanner geometry, read from the vendor's private tags.
class ConeBeamGeometry {
  ConeBeamGeometry({
    required this.sourceToAxis,
    required this.sourceToDetector,
    required this.pixel,
    required this.u0,
    required this.v0,
    required this.degreesPerFrame,
    required this.airLevel,
    required this.radius,
    required this.zTop,
    required this.zBottom,
  });

  final double sourceToAxis;
  final double sourceToDetector;

  /// Detector pixel size, mm (after binning).
  final double pixel;

  /// Detector column and row hit by the ray through the rotation axis
  /// that is perpendicular to the detector.
  final double u0;
  final double v0;
  final double degreesPerFrame;

  /// Pixel value with no object in the beam.
  final double airLevel;

  /// Reconstructed cylinder: radius and height range, mm at the axis.
  final double radius;
  final double zTop;
  final double zBottom;

  int get nxy => (2 * radius / reconVoxelMm).round();
  int get nz => ((zTop - zBottom) / reconVoxelMm).round() + 1;

  /// Reads the geometry of an i-CAT projection series, or returns null if
  /// [f] is not one. (The scanner's other images carry the same tags.) The tags (0023,2302) and (0023,2303) hold
  /// base64 text of a 4-byte big-endian length and zlib-compressed JSON.
  static ConeBeamGeometry? of(DicomFile f) {
    try {
      final cal = _vendorJson(f, 0x00232302);
      final kv = _vendorJson(f, 0x00232303)?['keyValuePairs'] as Map?;
      if (cal == null || kv == null) return null;
      final g = (cal['geometric'] as Map)[kv['Orientation']] as Map;
      double number(Object? v) =>
          v is num ? v.toDouble() : double.parse(v as String);
      List<double> list(String key) =>
          (kv[key] as String).split('\\').map(double.parse).toList();
      final pixel = list('DICOM.ImagerPixelSpacing').first;
      final degreesPerFrame = number(kv['DegreesPerFrame']);
      if (f.numberOfFrames < 2 || degreesPerFrame <= 0) return null;
      // Shutter limits at the axis, mm: right, left, top, bottom.
      final sh = list('ShutterGantry');
      return ConeBeamGeometry(
        sourceToAxis: number(g['distanceToObject']),
        sourceToDetector: number(g['distanceToDetector']),
        pixel: pixel,
        u0: (f.columns - 1) / 2 + number(g['detectorOffsetX']) / pixel,
        v0: (f.rows - 1) / 2 + number(g['detectorOffsetY']) / pixel,
        degreesPerFrame: degreesPerFrame,
        airLevel: number(kv['PanelAirLevel']),
        radius: math.min(sh[0], -sh[1]),
        zTop: sh[2],
        zBottom: sh[3],
      );
    } catch (_) {
      return null;
    }
  }
}

Map<String, dynamic>? _vendorJson(DicomFile f, int tag) {
  final e = f.elements[tag];
  if (e == null) return null;
  final raw = base64.decode(ascii.decode(e.bytes).trim());
  final text = utf8.decode(ZLibDecoder().convert(raw.sublist(4)));
  return json.decode(text) as Map<String, dynamic>;
}

// Native memory, so that worker isolates can share the projections and the
// volume instead of each receiving a copy.
final _malloc = DynamicLibrary.process()
    .lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >('malloc');
final _free = DynamicLibrary.process()
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'free',
    );

int _alloc(int bytes) {
  final p = _malloc(bytes);
  if (p.address == 0) throw StateError('Out of memory');
  return p.address;
}

Float32List _floats(int address, int n) =>
    Pointer<Float>.fromAddress(address).asTypedList(n);
Int16List _shorts(int address, int n) =>
    Pointer<Int16>.fromAddress(address).asTypedList(n);

/// Reconstructs a volume from the projection series [s] in background
/// isolates.
Future<VolumeData> reconstructVolume(
  SeriesInfo s, {
  Progress? onProgress,
}) async {
  final port = ReceivePort();
  port.listen((m) {
    if (onProgress != null && m is List) {
      onProgress(m[0] as double, m[1] as String);
    }
  });
  try {
    return await _runReconstruct(s.files.first, port.sendPort);
  } finally {
    port.close();
  }
}

// Isolates are started from these small functions so that each closure
// captures only its arguments.
Future<VolumeData> _runReconstruct(String path, SendPort progress) =>
    Isolate.run(() => _reconstruct(path, progress));

Future<void> _runFilter(_Job job, int first, int count, SendPort done) =>
    Isolate.run(() => _filter(job, first, count, done));

Future<void> _runBackProject(
  _Job job,
  int worker,
  int workers,
  SendPort done,
) => Isolate.run(() => _backProject(job, worker, workers, done));

/// What the workers need: the geometry, the sizes and the addresses of the
/// shared buffers.
class _Job {
  _Job(
    this.g,
    this.w,
    this.h,
    this.frames,
    this.proj,
    this.filtered,
    this.volume,
  );
  final ConeBeamGeometry g;
  final int w, h, frames;

  /// -ln(I / air) per frame, row-major; NaN where no X-rays arrived.
  final int proj;

  /// Filtered projections, column-major per frame (so a voxel column reads
  /// consecutive values).
  final int filtered;

  /// HU, slice-major, slices from bottom to top.
  final int volume;
}

Future<VolumeData> _reconstruct(String path, SendPort progress) async {
  progress.send([0.0, 'Reading projections']);
  final f = DicomFile.parse(path, File(path).readAsBytesSync());
  final g = ConeBeamGeometry.of(f)!;
  final w = f.columns, h = f.rows, n = f.numberOfFrames;
  final nxy = g.nxy, nz = g.nz;
  final frameSize = w * h;
  final job = _Job(
    g,
    w,
    h,
    n,
    _alloc(n * frameSize * 4),
    _alloc(n * frameSize * 4),
    _alloc(nxy * nxy * nz * 2),
  );
  try {
    final proj = _floats(job.proj, n * frameSize);
    final logAir = math.log(g.airLevel);
    for (var i = 0; i < n; i++) {
      final v = f.decodeFrame(i);
      final off = i * frameSize;
      for (var k = 0; k < frameSize; k++) {
        proj[off + k] = v[k] > 0 ? logAir - math.log(v[k]) : double.nan;
      }
      if (i % 30 == 0) progress.send([0.05 * i / n, 'Reading projections']);
    }

    // In a Flutter release build, at most about 8 isolates of a group run
    // at once (measured; a standalone Dart program allows about 16). Busy
    // workers beyond that starve this isolate and the UI isolate, which
    // then freeze until a worker finishes, and add no speed.
    final workers = math.max(1, math.min(Platform.numberOfProcessors, 7));
    Future<void> phase(
      String stage,
      double from,
      double to,
      int total,
      Future<void> Function(int worker, SendPort done) run,
    ) async {
      final port = ReceivePort();
      var count = 0;
      port.listen((_) {
        count++;
        progress.send([from + (to - from) * count / total, stage]);
      });
      try {
        await Future.wait([
          for (var k = 0; k < workers; k++) run(k, port.sendPort),
        ]);
      } finally {
        port.close();
      }
    }

    final per = (n + workers - 1) ~/ workers;
    await phase('Filtering projections', 0.05, 0.15, n, (k, done) {
      final first = k * per;
      return _runFilter(
        job,
        first,
        math.max(0, math.min(per, n - first)),
        done,
      );
    });
    await phase(
      'Back-projecting',
      0.15,
      0.8,
      nxy,
      (k, done) => _runBackProject(job, k, workers, done),
    );

    final vol = _shorts(job.volume, nxy * nxy * nz);
    final slices = [
      for (var z = 0; z < nz; z++)
        vol.sublist(z * nxy * nxy, (z + 1) * nxy * nxy),
    ];
    return packVolume(
      slices,
      nxy,
      nxy,
      [reconVoxelMm, reconVoxelMm, reconVoxelMm],
      [1, 0, 0, 0, 1, 0, 0, 0, 1],
      progress,
    );
  } finally {
    _free(Pointer.fromAddress(job.proj));
    _free(Pointer.fromAddress(job.filtered));
    _free(Pointer.fromAddress(job.volume));
  }
}

/// Weights and ramp-filters frames [first] to [first] + [count] - 1 along
/// detector rows. Two rows go through one complex FFT (one as the real
/// part, one as the imaginary part), which works because the filter is
/// real and even.
void _filter(_Job job, int first, int count, SendPort done) {
  final g = job.g;
  final w = job.w, h = job.h;
  final proj = _floats(job.proj, job.frames * w * h);
  final out = _floats(job.filtered, job.frames * w * h);
  final fft = _Fft(_fftSize);

  // Detector coordinates are scaled to the rotation axis.
  final da = g.pixel * g.sourceToAxis / g.sourceToDetector;
  final d = g.sourceToAxis;

  // Ram-Lak kernel sampled at da (Kak and Slaney, eq. 3.61), Hann window.
  final re = Float64List(_fftSize), im = Float64List(_fftSize);
  re[0] = 1 / (4 * da * da);
  for (var k = 1; k < _fftSize ~/ 2; k += 2) {
    re[k] = re[_fftSize - k] = -1 / (math.pi * math.pi * k * k * da * da);
  }
  fft.transform(re, im, false);
  final filter = Float64List(_fftSize);
  for (var k = 0; k < _fftSize; k++) {
    final freq = (k <= _fftSize ~/ 2 ? k : _fftSize - k) / _fftSize;
    filter[k] = re[k].abs() * da * 0.5 * (1 + math.cos(2 * math.pi * freq));
  }

  final row = Float64List(w);
  final taper = Float64List.fromList([
    for (var j = 1; j <= _taper; j++)
      0.5 * (1 + math.cos(math.pi * j / _taper)),
  ]);

  // Loads row r of frame i into buf, weighted and tapered. Returns the
  // first and last measured columns, or (-1, -1) if the row has none.
  (int, int) load(int i, int r, Float64List buf) {
    buf.fillRange(0, _fftSize, 0);
    final off = i * w * h + r * w;
    var a = -1, b = -1;
    for (var c = 0; c < w; c++) {
      final v = proj[off + c];
      if (!v.isNaN) {
        if (a < 0) a = c;
        b = c;
      }
    }
    if (a < 0) return (-1, -1);
    final bv = (g.v0 - r) * da;
    for (var c = a; c <= b; c++) {
      final v = proj[off + c];
      final u = (c - g.u0) * da;
      row[c] =
          (v.isNaN ? 0.0 : math.max(v, 0.0)) *
          d /
          math.sqrt(d * d + u * u + bv * bv);
    }
    // Columns a..b start at buf[_taper], with a taper on each side.
    for (var c = a; c <= b; c++) {
      buf[_taper + c - a] = row[c];
    }
    for (var j = 0; j < _taper; j++) {
      buf[_taper + b - a + 1 + j] = row[b] * taper[j];
      buf[_taper - 1 - j] = row[a] * taper[j];
    }
    return (a, b);
  }

  void store(int i, int r, Float64List buf, (int, int) range) {
    final (a, b) = range;
    final base = i * w * h;
    for (var c = 0; c < w; c++) {
      out[base + c * h + r] = a >= 0 && c >= a && c <= b
          ? buf[_taper + c - a]
          : 0;
    }
  }

  for (var i = first; i < first + count; i++) {
    for (var r = 0; r < h; r += 2) {
      final ra = load(i, r, re);
      final rb = r + 1 < h ? load(i, r + 1, im) : (-1, -1);
      if (r + 1 >= h) im.fillRange(0, _fftSize, 0);
      fft.transform(re, im, false);
      for (var k = 0; k < _fftSize; k++) {
        re[k] *= filter[k];
        im[k] *= filter[k];
      }
      fft.transform(re, im, true);
      store(i, r, re, ra);
      if (r + 1 < h) store(i, r + 1, im, rb);
    }
    done.send(1);
  }
}

/// Back-projects into the voxel rows y = worker, worker + workers, ...
void _backProject(_Job job, int worker, int workers, SendPort done) {
  final g = job.g;
  final w = job.w, h = job.h, n = job.frames;
  final q = _floats(job.filtered, n * w * h);
  final nxy = g.nxy, nz = g.nz;
  final vol = _shorts(job.volume, nxy * nxy * nz);
  final cosB = Float64List(n), sinB = Float64List(n);
  for (var i = 0; i < n; i++) {
    final b =
        (_startAngleDeg + _direction * i * g.degreesPerFrame) * math.pi / 180;
    cosB[i] = math.cos(b);
    sinB[i] = math.sin(b);
  }
  final d = g.sourceToAxis, sdd = g.sourceToDetector, pix = g.pixel;
  // Full rotation: every ray is measured twice, hence the 1/2.
  final scale = g.degreesPerFrame * math.pi / 180 / 2;
  final acc = Float64List(nz);
  final x0 = -(nxy - 1) / 2 * reconVoxelMm;
  final r2 = g.radius * g.radius;

  for (var iy = worker; iy < nxy; iy += workers) {
    final y = x0 + iy * reconVoxelMm;
    for (var ix = 0; ix < nxy; ix++) {
      final x = x0 + ix * reconVoxelMm;
      final out = iy * nxy + ix;
      if (x * x + y * y > r2) {
        for (var iz = 0; iz < nz; iz++) {
          vol[iz * nxy * nxy + out] = -1000;
        }
        continue;
      }
      acc.fillRange(0, nz, 0);
      for (var i = 0; i < n; i++) {
        // t: distance from the axis toward the source; s: across the beam.
        final t = x * cosB[i] + y * sinB[i];
        final s = -x * sinB[i] + y * cosB[i];
        final inv = 1 / (d - t);
        final m = sdd * inv / pix; // detector pixels per mm at this depth
        final col = g.u0 + s * m;
        if (col < 0 || col >= w - 1) continue;
        final c = col.floor();
        final fc = col - c;
        final weight = d * d * inv * inv;
        // Row of slice iz: rowAt0 + iz * step (rows run downward, z up).
        final rowAt0 = g.v0 - g.zBottom * m;
        final step = -reconVoxelMm * m;
        // Slices whose row lies in [0, h - 1).
        final izFirst = math.max(0, ((rowAt0 - (h - 1)) / -step).floor() + 1);
        final izLast = math.min(nz - 1, (rowAt0 / -step).floor());
        final b0 = i * w * h + c * h;
        final b1 = b0 + h;
        for (var iz = izFirst; iz <= izLast; iz++) {
          final row = rowAt0 + iz * step;
          final r = row.toInt();
          final fr = row - r;
          final a0 = q[b0 + r] + (q[b0 + r + 1] - q[b0 + r]) * fr;
          final a1 = q[b1 + r] + (q[b1 + r + 1] - q[b1 + r]) * fr;
          acc[iz] += weight * (a0 + (a1 - a0) * fc);
        }
      }
      for (var iz = 0; iz < nz; iz++) {
        final hu = 1000 * (acc[iz] * scale / _muWater - 1);
        vol[iz * nxy * nxy + out] = hu.round().clamp(-32768, 32767);
      }
    }
    done.send(1);
  }
}

/// In-place radix-2 complex FFT.
class _Fft {
  _Fft(this.n)
    : _cos = Float64List(n ~/ 2),
      _sin = Float64List(n ~/ 2),
      _rev = Int32List(n) {
    for (var k = 0; k < n ~/ 2; k++) {
      _cos[k] = math.cos(2 * math.pi * k / n);
      _sin[k] = math.sin(2 * math.pi * k / n);
    }
    final bits = n.bitLength - 1;
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  final int n;
  final Float64List _cos, _sin;
  final Int32List _rev;

  void transform(Float64List re, Float64List im, bool inverse) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i], ti = im[i];
        re[i] = re[j];
        im[i] = im[j];
        re[j] = tr;
        im[j] = ti;
      }
    }
    final sign = inverse ? 1.0 : -1.0;
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1, stride = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * stride], wi = sign * _sin[k * stride];
          final a = start + k, b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
    if (inverse) {
      for (var i = 0; i < n; i++) {
        re[i] /= n;
        im[i] /= n;
      }
    }
  }
}
