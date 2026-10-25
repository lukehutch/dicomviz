import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../dicom/series.dart';
import 'volume_view.dart';

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
  int _loading = 0;
  final _transform = TransformationController();

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
    final px = Uint8List(f.width * f.height * 4);
    final lo = f.windowCenter - f.windowWidth / 2;
    for (var i = 0; i < f.values.length; i++) {
      final g = ((f.values[i] - lo) / f.windowWidth * 255).round().clamp(0, 255);
      px[i * 4] = g;
      px[i * 4 + 1] = g;
      px[i * 4 + 2] = g;
      px[i * 4 + 3] = 255;
    }
    final img = await imageFromRgba(px, f.width, f.height);
    if (!mounted || token != _loading) {
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
    return Column(children: [
      Expanded(
        child: InteractiveViewer(
          transformationController: _transform,
          maxScale: 20,
          child: Center(
            child: _image == null
                ? const CircularProgressIndicator()
                : RawImage(image: _image, filterQuality: FilterQuality.medium),
          ),
        ),
      ),
      if (n > 1)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
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
          ]),
        ),
    ]);
  }
}
