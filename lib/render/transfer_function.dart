import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/painting.dart';

import '../dicom/series.dart';

enum RenderMode {
  /// Translucent level-set surfaces at the lower edge of each band.
  surfaces,

  /// Direct volume rendering; a band's opacity applies per
  /// [volumeOpacityDepth] voxels of depth.
  volume,
}

/// Depth in voxels over which a band's opacity applies in volume mode. Per
/// single voxel, the default soft-tissue opacities would make skin opaque.
const volumeOpacityDepth = 10.0;

/// A density interval with its color and opacity.
class Band {
  Band(this.lo, this.hi, this.color, this.opacity, {this.enabled = true});
  double lo;
  double hi;
  Color color;
  double opacity;
  bool enabled;
}

/// Rainbow color for t in 0..1 (violet at 0, red at 1).
Color rainbow(double t) {
  final hue = 270.0 * (1 - t.clamp(0.0, 1.0));
  return HSVColor.fromAHSV(1, hue, 0.85, 1).toColor();
}

class TransferFunction {
  TransferFunction({
    required this.bands,
    required this.showMin,
    required this.showMax,
    this.mode = RenderMode.surfaces,
  });

  List<Band> bands;

  /// Densities outside [showMin, showMax] are hidden.
  double showMin;
  double showMax;
  RenderMode mode;

  /// [count] rainbow bands of equal width from [from] to [to]; the last band
  /// extends to [dataMax] so metal stays visible.
  factory TransferFunction.rainbow({
    required double from,
    required double to,
    required int count,
    required double dataMin,
    required double dataMax,
  }) {
    final bands = <Band>[];
    final width = (to - from) / count;
    for (var i = 0; i < count; i++) {
      final lo = from + i * width;
      final hi = i == count - 1 ? math.max(to, dataMax) : lo + width;
      final t = count == 1 ? 0.0 : i / (count - 1);
      // Low densities (soft tissue) faint, dense bone and metal opaque.
      final opacity = 0.04 + 0.96 * t * t;
      bands.add(Band(lo, hi, rainbow(t), opacity));
    }
    return TransferFunction(bands: bands, showMin: dataMin, showMax: dataMax);
  }

  bool _shown(Band b) =>
      b.enabled && b.opacity > 0 && b.hi > showMin && b.lo < showMax;

  /// Builds the 256x256 RGBA8888 pre-integrated table the shader samples
  /// with x = code at the segment's front and y = code at its back. Colors
  /// are premultiplied by alpha.
  Uint8List buildTable(DensityMap map) {
    final out = Uint8List(256 * 256 * 4);
    if (mode == RenderMode.surfaces) {
      _buildSurfaceTable(map, out);
    } else {
      _buildVolumeTable(map, out);
    }
    return out;
  }

  /// Per-code color and per-step opacity, with the visibility range applied.
  (Float64List, Float64List, Float64List, Float64List) _perCode(DensityMap map) {
    final r = Float64List(256), g = Float64List(256), b = Float64List(256);
    final a = Float64List(256);
    for (var c = 0; c < 256; c++) {
      final v = map.decode(c.toDouble());
      if (v < showMin || v > showMax) continue;
      for (final band in bands) {
        if (v >= band.lo && (v < band.hi || identical(band, bands.last) && v <= band.hi)) {
          if (!band.enabled) break;
          r[c] = band.color.r;
          g[c] = band.color.g;
          b[c] = band.color.b;
          a[c] = band.opacity.clamp(0.0, 0.999);
          break;
        }
      }
    }
    return (r, g, b, a);
  }

  void _buildVolumeTable(DensityMap map, Uint8List out) {
    final (r, g, b, a) = _perCode(map);
    // Prefix integrals of extinction (tau) and tau-weighted color. A segment
    // from code f to code b passes the codes between them in equal parts.
    final tau = Float64List(256);
    for (var c = 0; c < 256; c++) {
      tau[c] = -math.log(1 - a[c]);
    }
    final pt = Float64List(257), pr = Float64List(257);
    final pg = Float64List(257), pb = Float64List(257);
    for (var c = 0; c < 256; c++) {
      pt[c + 1] = pt[c] + tau[c];
      pr[c + 1] = pr[c] + tau[c] * r[c];
      pg[c + 1] = pg[c] + tau[c] * g[c];
      pb[c + 1] = pb[c] + tau[c] * b[c];
    }
    for (var sb = 0; sb < 256; sb++) {
      for (var sf = 0; sf < 256; sf++) {
        final lo = math.min(sf, sb), hi = math.max(sf, sb) + 1;
        final count = hi - lo;
        final t = pt[hi] - pt[lo];
        final i = (sb * 256 + sf) * 4;
        if (t <= 0) continue;
        final alpha = 1 - math.exp(-t / count);
        out[i] = (alpha * (pr[hi] - pr[lo]) / t * 255).round();
        out[i + 1] = (alpha * (pg[hi] - pg[lo]) / t * 255).round();
        out[i + 2] = (alpha * (pb[hi] - pb[lo]) / t * 255).round();
        out[i + 3] = (alpha * 255).round();
      }
    }
  }

  void _buildSurfaceTable(DensityMap map, Uint8List out) {
    // One surface at the lower edge of each shown band, in code units.
    final surfaces = <(double, Band)>[];
    for (final band in bands) {
      if (!_shown(band)) continue;
      final edge = math.max(band.lo, showMin);
      final code = map.encode(edge);
      if (code <= 0.0 || code >= 255) continue;
      surfaces.add((code, band));
    }
    surfaces.sort((x, y) => x.$1.compareTo(y.$1));
    for (var sb = 0; sb < 256; sb++) {
      for (var sf = 0; sf < 256; sf++) {
        if (sf == sb) continue;
        // Surfaces crossed, in order from front (sf) to back (sb).
        final rising = sb > sf;
        var ar = 0.0, ag = 0.0, ab = 0.0, aa = 0.0;
        for (var k = 0; k < surfaces.length; k++) {
          final (code, band) = surfaces[rising ? k : surfaces.length - 1 - k];
          final crossed = rising ? (sf < code && code <= sb) : (sb < code && code <= sf);
          if (!crossed) continue;
          final al = band.opacity.clamp(0.0, 1.0) * (1 - aa);
          ar += al * band.color.r;
          ag += al * band.color.g;
          ab += al * band.color.b;
          aa += al;
        }
        if (aa <= 0) continue;
        final i = (sb * 256 + sf) * 4;
        out[i] = (ar * 255).round();
        out[i + 1] = (ag * 255).round();
        out[i + 2] = (ab * 255).round();
        out[i + 3] = (aa * 255).round();
      }
    }
  }
}
