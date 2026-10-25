import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../dicom/series.dart';
import '../render/camera.dart';
import '../render/transfer_function.dart';

Future<ui.Image> imageFromRgba(Uint8List pixels, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(buffer,
      width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

ui.FragmentProgram? _program;
Future<ui.FragmentProgram> raycastProgram() async =>
    _program ??= await ui.FragmentProgram.fromAsset('shaders/raycast.frag');

/// Rendering settings shared with the control panel.
class RenderSettings extends ChangeNotifier {
  /// Ray step in voxels.
  double stepVoxels = 0.5;
  bool shading = true;

  void changed() => notifyListeners();
}

/// Interactive 3D view of a volume.
class VolumeView extends StatefulWidget {
  const VolumeView({
    super.key,
    required this.volume,
    required this.volumeImage,
    required this.tf,
    required this.tfVersion,
    required this.settings,
  });

  final VolumeData volume;
  final ui.Image volumeImage;
  final TransferFunction tf;

  /// Incremented by the owner whenever [tf] changes.
  final int tfVersion;
  final RenderSettings settings;

  @override
  State<VolumeView> createState() => VolumeViewState();
}

class VolumeViewState extends State<VolumeView> {
  late OrbitCamera camera;
  final _repaint = ValueNotifier<int>(0);
  ui.FragmentShader? _shader;
  ui.Image? _table;
  int _tableVersion = -1;
  bool _tableBusy = false;
  int _buttons = 0;

  @override
  void initState() {
    super.initState();
    camera = _makeCamera();
    raycastProgram().then((p) {
      if (!mounted) return;
      setState(() => _shader = p.fragmentShader());
    });
    widget.settings.addListener(_bump);
    _updateTable();
  }

  @override
  void didUpdateWidget(VolumeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (!identical(old.volume, widget.volume)) camera = _makeCamera();
    if (old.settings != widget.settings) {
      old.settings.removeListener(_bump);
      widget.settings.addListener(_bump);
    }
    if (old.tfVersion != widget.tfVersion || !identical(old.volume, widget.volume)) {
      _updateTable();
    }
  }

  @override
  void dispose() {
    widget.settings.removeListener(_bump);
    _shader?.dispose();
    _table?.dispose();
    super.dispose();
  }

  void _bump() => _repaint.value++;

  /// Box half-size in mm.
  vm.Vector3 get _extent {
    final v = widget.volume;
    return vm.Vector3(v.dims[0] * v.spacing[0], v.dims[1] * v.spacing[1],
            v.dims[2] * v.spacing[2]) *
        0.5;
  }

  OrbitCamera _makeCamera() {
    // Anterior view with the patient's head up. Patient axes (DICOM LPS):
    // look toward +y (posterior), up is +z (superior).
    final a = widget.volume.axes;
    final ax = [vm.Vector3(a[0], a[1], a[2]), vm.Vector3(a[3], a[4], a[5]),
      vm.Vector3(a[6], a[7], a[8])];
    vm.Vector3 toVolume(vm.Vector3 p) =>
        vm.Vector3(p.dot(ax[0]), p.dot(ax[1]), p.dot(ax[2]));
    final fwd = toVolume(vm.Vector3(0, 1, 0));
    final up = toVolume(vm.Vector3(0, 0, 1));
    final right = fwd.cross(up);
    final home = vm.Matrix3.zero()
      ..setRow(0, right)
      ..setRow(1, up)
      ..setRow(2, -fwd);
    // Distance at which the bounding sphere fills the view height.
    return OrbitCamera(
        home: home, homeDistance: _extent.length / math.sin(OrbitCamera.defaultFovY / 2));
  }

  void resetView() {
    camera.reset();
    _bump();
  }

  Future<void> _updateTable() async {
    if (_tableBusy) return; // the latest version is picked up when done
    _tableBusy = true;
    try {
      while (_tableVersion != widget.tfVersion) {
        final version = widget.tfVersion;
        final bytes = widget.tf.buildTable(widget.volume.map);
        final img = await imageFromRgba(bytes, 256, 256);
        if (!mounted) {
          img.dispose();
          return;
        }
        final old = _table;
        setState(() {
          _table = img;
          _tableVersion = version;
        });
        old?.dispose();
      }
    } finally {
      _tableBusy = false;
    }
  }

  void _onPointerDown(PointerDownEvent e) => _buttons = e.buttons;

  void _onPointerMove(PointerMoveEvent e) {
    final d = e.delta;
    final keys = HardwareKeyboard.instance;
    final size = context.size ?? const Size(1, 1);
    final panButtons = kSecondaryMouseButton | kMiddleMouseButton;
    if ((_buttons & panButtons) != 0 ||
        ((_buttons & kPrimaryMouseButton) != 0 && keys.isShiftPressed)) {
      final s = camera.worldPerPixel(size.height);
      camera.pan -= vm.Vector2(d.dx * s, -d.dy * s);
    } else if ((_buttons & kPrimaryMouseButton) != 0 && keys.isControlPressed) {
      _zoom(math.exp(d.dy * 0.01));
    } else if ((_buttons & kPrimaryMouseButton) != 0) {
      const radPerPixel = 0.008;
      camera.rotate(d.dx * radPerPixel, d.dy * radPerPixel);
    }
    _bump();
  }

  void _zoom(double factor) {
    final r = _extent.length;
    camera.distance = (camera.distance * factor).clamp(r * 0.3, r * 20);
    _bump();
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
        _zoom(math.exp((ev as PointerScrollEvent).scrollDelta.dy * 0.0015));
      });
    }
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    // Touchpad: two-finger drag rotates, pinch zooms.
    const radPerPixel = 0.008;
    camera.rotate(e.panDelta.dx * radPerPixel, e.panDelta.dy * radPerPixel);
    _bump();
  }

  double _lastScale = 1;
  void _onPanZoomStart(PointerPanZoomStartEvent e) => _lastScale = 1;
  void _onPanZoomScale(PointerPanZoomUpdateEvent e) {
    if (e.scale != _lastScale) {
      _zoom(_lastScale / e.scale);
      _lastScale = e.scale;
    }
    _onPanZoomUpdate(e);
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final table = _table;
    if (shader == null || table == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerSignal: _onSignal,
      onPointerPanZoomStart: _onPanZoomStart,
      onPointerPanZoomUpdate: _onPanZoomScale,
      child: GestureDetector(
        onDoubleTap: resetView,
        child: CustomPaint(
          size: Size.infinite,
          painter: _RaycastPainter(
            shader: shader,
            volume: widget.volume,
            volumeImage: widget.volumeImage,
            table: table,
            camera: camera,
            extent: _extent,
            settings: widget.settings,
            surfaces: widget.tf.mode == RenderMode.surfaces,
            repaint: _repaint,
          ),
        ),
      ),
    );
  }
}

class _RaycastPainter extends CustomPainter {
  _RaycastPainter({
    required this.shader,
    required this.volume,
    required this.volumeImage,
    required this.table,
    required this.camera,
    required this.extent,
    required this.settings,
    required this.surfaces,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final ui.FragmentShader shader;
  final VolumeData volume;
  final ui.Image volumeImage;
  final ui.Image table;
  final OrbitCamera camera;
  final vm.Vector3 extent;
  final RenderSettings settings;
  final bool surfaces;

  @override
  void paint(Canvas canvas, Size size) {
    final v = volume;
    final minSpacing = v.spacing.reduce(math.min);
    final step = minSpacing * settings.stepVoxels;
    var i = 0;
    void f(double x) => shader.setFloat(i++, x);
    void v3(vm.Vector3 x) {
      f(x.x);
      f(x.y);
      f(x.z);
    }

    f(size.width);
    f(size.height);
    f(v.dims[0].toDouble());
    f(v.dims[1].toDouble());
    f(v.dims[2].toDouble());
    f(v.groups.toDouble());
    f(v.atlasCols.toDouble());
    f(0);
    f(v.atlasWidth.toDouble());
    f(v.atlasHeight.toDouble());
    v3(extent);
    v3(camera.eye);
    v3(camera.right);
    v3(camera.up);
    v3(camera.forward);
    f(camera.tanHalfFov);
    f(step);
    // Surface opacity is per crossing; volume opacity is per
    // volumeOpacityDepth voxels of depth.
    f(surfaces ? 1.0 : settings.stepVoxels / volumeOpacityDepth);
    f(settings.shading ? 1.0 : 0.0);
    f(0.07);
    f(0.07);
    f(0.09);
    f(1.0);
    shader.setImageSampler(0, volumeImage, filterQuality: FilterQuality.low);
    shader.setImageSampler(1, table, filterQuality: FilterQuality.none);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_RaycastPainter old) =>
      old.table != table ||
      old.volumeImage != volumeImage ||
      old.surfaces != surfaces ||
      old.shader != shader;
}
