// Reconstructs the cone-beam projection series in a DICOM folder and
// compares an axial slice with the scanner's own reconstruction. Exits with
// status 1 if they disagree.
//
// The back-projection is too slow to run under the JIT (flutter test or
// dart run take over 10 minutes), so compile it:
//   dart compile exe tool/check_reconstruction.dart -o build/check_reconstruction
//   build/check_reconstruction <folder>
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:dicomviz/dicom/series.dart';

/// HU at voxel (x, y, z) of [v], through its 8-bit code.
double hu(VolumeData v, int x, int y, int z) {
  final g = z ~/ 3, w = v.dims[0], h = v.dims[1];
  final tx = (g % v.atlasCols) * w, ty = (g ~/ v.atlasCols) * h;
  return v.map.decode(v.atlas[((ty + y) * v.atlasWidth + tx + x) * 4 + z % 3].toDouble());
}

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: check_reconstruction <DICOM folder>');
    exit(2);
  }
  final series = await scanFolder(args[0]);
  final i = series.indexWhere((s) => s.reconstruct);
  if (i <= 0 || series[i - 1].files.first != series[i].files.first) {
    stderr.writeln('no reconstruction listed after its projection series');
    exit(1);
  }

  final sw = Stopwatch()..start();
  final rec = await loadVolume(series[i]);
  print('reconstruction ${rec.dims} in ${sw.elapsedMilliseconds} ms');
  final ref = await loadVolume(series.firstWhere((s) => s.isVolume && !s.reconstruct));

  // Axial slice nearest z = 0 in both. Reconstruction slices start at the
  // bottom shutter limit (-45 mm); scanner slices at -46.7 mm.
  final zr = (45 / rec.spacing[2]).round(), z = -45 + zr * rec.spacing[2];
  final zv = ((z + 46.7) / ref.spacing[2]).round();
  final n = rec.dims[0], half = (n - 1) / 2;
  final a = <double>[], b = <double>[];
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final px = (x - half) * rec.spacing[0], py = (y - half) * rec.spacing[1];
      if (px * px + py * py > 72 * 72) continue;
      a.add(hu(rec, x, y, zr));
      b.add(hu(ref, ((px + 80.4) / ref.spacing[0]).round(), ((py + 80.4) / ref.spacing[1]).round(), zv));
    }
  }
  double mean(List<double> v) => v.reduce((p, q) => p + q) / v.length;
  final ma = mean(a), mb = mean(b);
  var sab = 0.0, saa = 0.0, sbb = 0.0;
  for (var k = 0; k < a.length; k++) {
    sab += (a[k] - ma) * (b[k] - mb);
    saa += (a[k] - ma) * (a[k] - ma);
    sbb += (b[k] - mb) * (b[k] - mb);
  }
  final r = sab / math.sqrt(saa * sbb);
  // Median HU of voxels the scanner calls air, and soft tissue.
  double median(bool Function(double) f) {
    final s = [for (var k = 0; k < a.length; k++) if (f(b[k])) a[k]]..sort();
    return s[s.length ~/ 2];
  }

  print('r = ${r.toStringAsFixed(3)}, air ${median((v) => v < -900).round()} HU, '
      'soft tissue ${median((v) => v > -100 && v < 100).round()} HU');
  if (!(r > 0.9)) exit(1);
}
