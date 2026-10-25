import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../dicom/series.dart';
import '../render/transfer_function.dart';
import 'volume_view.dart';

enum Palette { rainbow, grayscale }

/// Number of rainbow bands, as in the 3D view's default.
const _bandCount = 12;

/// Viewer for 2D series: single images or multi-frame stacks.
class ImageStackView extends StatefulWidget {
  const ImageStackView({super.key, required this.stack});
  final ImageStack stack;

  @override
  State<ImageStackView> createState() => _ImageStackViewState();
}

class _ImageStackViewState extends State<ImageStackView> {
  int _index = 0;
  ui.Image? _image;
  Frame2D? _frame;
  int _loading = 0;
  int _rendering = 0;
  final _transform = TransformationController();
  Palette _palette = Palette.rainbow;

  /// Display range, taken from the first frame shown and kept for the whole
  /// stack so colors mean the same on every frame.
  (double, double)? _window;
  bool _invert = false;

  /// Histogram equalization: each display level gets an equal share of
  /// the pixels. [_quantiles] holds evenly spaced quantiles of the first
  /// frame's values, kept for the whole stack like [_window].
  bool _equalize = true;
  Float32List? _quantiles;

  @override
  void initState() {
    super.initState();
    _load(0);
  }

  @override
  void didUpdateWidget(ImageStackView old) {
    super.didUpdateWidget(old);
    if (!identical(old.stack, widget.stack)) {
      _index = 0;
      _window = null;
      _quantiles = null;
      _transform.value = Matrix4.identity();
      _load(0);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load(int index) async {
    final token = ++_loading;
    final (path, frame) = widget.stack.frameRefs[index];
    final f = await loadFrame(path, frame);
    if (!mounted || token != _loading) return;
    _window ??= (f.windowCenter - f.windowWidth / 2, f.windowWidth);
    _quantiles ??= _quantilesOf(f.values);
    _frame = f;
    await _render();
  }

  static Float32List _quantilesOf(Float32List v) {
    final s = Float32List.fromList(v.where((x) => !x.isNaN).toList())..sort();
    const n = 1024;
    return Float32List.fromList([
      for (var i = 0; i < n; i++)
        s.isEmpty ? 0 : s[(i * (s.length - 1) / (n - 1)).round()],
    ]);
  }

  /// Fraction of [_quantiles] below [v], in 0..1.
  double _rank(double v) {
    final q = _quantiles!;
    var lo = 0, hi = q.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (q[mid] < v) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo / q.length;
  }

  /// Colors the current frame so that red is densest in rainbow mode and
  /// white is densest in grayscale.
  Future<void> _render() async {
    final token = ++_rendering;
    final f = _frame!;
    final (lo, width) = _window!;
    final colors = [
      for (var b = 0; b < _bandCount; b++) rainbow(b / (_bandCount - 1)),
    ];
    final px = Uint8List(f.width * f.height * 4);
    for (var i = 0; i < f.values.length; i++) {
      px[i * 4 + 3] = 255;
      if (f.values[i].isNaN) continue; // no data: black
      var t = _equalize
          ? _rank(f.values[i])
          : ((f.values[i] - lo) / width).clamp(0.0, 1.0);
      if (_invert) t = 1 - t;
      if (_palette == Palette.grayscale) {
        final g = (t * 255).round();
        px[i * 4] = g;
        px[i * 4 + 1] = g;
        px[i * 4 + 2] = g;
      } else {
        final c = colors[math.min((t * _bandCount).floor(), _bandCount - 1)];
        px[i * 4] = (c.r * 255).round();
        px[i * 4 + 1] = (c.g * 255).round();
        px[i * 4 + 2] = (c.b * 255).round();
      }
    }
    final img = await imageFromRgba(px, f.width, f.height);
    if (!mounted || token != _rendering) {
      img.dispose();
      return;
    }
    final old = _image;
    setState(() => _image = img);
    old?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.stack.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              SegmentedButton<Palette>(
                segments: const [
                  ButtonSegment(value: Palette.rainbow, label: Text('Rainbow')),
                  ButtonSegment(
                    value: Palette.grayscale,
                    label: Text('Grayscale'),
                  ),
                ],
                selected: {_palette},
                onSelectionChanged: (s) {
                  setState(() => _palette = s.first);
                  if (_frame != null) _render();
                },
              ),
              const SizedBox(width: 24),
              const Text('Invert'),
              const SizedBox(width: 8),
              Switch(
                value: _invert,
                onChanged: (v) {
                  setState(() => _invert = v);
                  if (_frame != null) _render();
                },
              ),
              const SizedBox(width: 24),
              const Text('Equalize'),
              const SizedBox(width: 8),
              Switch(
                value: _equalize,
                onChanged: (v) {
                  setState(() => _equalize = v);
                  if (_frame != null) _render();
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: InteractiveViewer(
            transformationController: _transform,
            maxScale: 20,
            child: Center(
              child: _image == null
                  ? const CircularProgressIndicator()
                  : RawImage(
                      image: _image,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          ),
        ),
        if (n > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text('Frame ${_index + 1} / $n'),
                Expanded(
                  child: Slider(
                    value: _index.toDouble(),
                    max: (n - 1).toDouble(),
                    divisions: n - 1,
                    onChanged: (v) {
                      setState(() => _index = v.round());
                      _load(_index);
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
