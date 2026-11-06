import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../dicom/series.dart';
import '../platform/platform.dart';
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

/// Divides the color of RGBA8888 [pixels] by their alpha.
void _unpremultiply(Uint8List pixels) {
  for (var i = 0; i < pixels.length; i += 4) {
    final a = pixels[i + 3];
    if (a == 0 || a == 255) continue;
    for (var c = i; c < i + 3; c++) {
      pixels[c] = math.min(pixels[c] * 255 / a, 255).round();
    }
  }
}

ui.FragmentProgram? _program;
Future<ui.FragmentProgram> raycastProgram() async =>
    _program ??= await ui.FragmentProgram.fromAsset('shaders/raycast.frag');

/// Rendering settings shared with the control panel.
class RenderSettings extends ChangeNotifier {
  /// Ray step in voxels.
  double stepVoxels = 0.5;
  bool shading = true;

  /// Half-width in voxels of the gradient stencil used for lighting.
  double normalSmoothing = 2;

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
  final _touches = <int, Offset>{};

  /// A finger held still drifts by a few pixels, and moves again as it lifts.
  /// Once it has rested for [_restTime], movements are ignored until it is
  /// [_restSlop] pixels from where it stopped, so the view does not turn
  /// slightly after the user has stopped turning it.
  static const _restTime = Duration(milliseconds: 100);
  static const _restSlop = 8.0;
  Offset _turnPos = Offset.zero;
  Duration _turnTime = Duration.zero;

  @override
  void initState() {
    super.initState();
    camera = _makeCamera();
    raycastProgram().then((p) {
      if (!mounted) return;
      setState(() => _shader = p.fragmentShader());
      _bump();
    });
    widget.settings.addListener(_bump);
    _updateTable();
  }

  @override
  void didUpdateWidget(VolumeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (!identical(old.volume, widget.volume)) {
      camera = _makeCamera();
      _fittedSize = null;
      _bump();
    }
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

  void _bump() {
    _repaint.value++;
  }

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
    // Distance at which the bounding sphere fills the view height. It is
    // replaced by [_fitDistance] once the view's size is known.
    return OrbitCamera(
        home: home, homeDistance: _extent.length / math.sin(OrbitCamera.defaultFovY / 2));
  }

  /// Distance at which the slice through the volume center, perpendicular to
  /// the home view direction, just fits a view of [size]. On a narrow screen
  /// its width then fills the screen width.
  double _fitDistance(Size size) {
    final e = _extent;
    double halfWidth(vm.Vector3 u) => u.x.abs() * e.x + u.y.abs() * e.y + u.z.abs() * e.z;
    // Tangent of the view angle per pixel; the field of view spans the shortest side.
    final t = camera.tanHalfFov / size.shortestSide;
    return math.max(halfWidth(camera.home.row0) / (t * size.width),
        halfWidth(camera.home.row1) / (t * size.height));
  }

  /// Size the home distance was last fitted to; null after a new camera.
  Size? _fittedSize;

  void _fitHome(Size size) {
    if (_fittedSize != null || size.isEmpty) return;
    _fittedSize = size;
    camera.homeDistance = _fitDistance(size);
    camera.distance = camera.homeDistance;
  }

  void resetView() {
    final size = context.size;
    if (size != null && !size.isEmpty) camera.homeDistance = _fitDistance(size);
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
        if (!rawImagesArePremultiplied) _unpremultiply(bytes);
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
        _bump();
      }
    } finally {
      _tableBusy = false;
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    _buttons = e.buttons;
    if (e.kind == ui.PointerDeviceKind.touch) _touches[e.pointer] = e.localPosition;
    _turnPos = e.localPosition;
    _turnTime = e.timeStamp;
  }

  void _onPointerEnd(PointerEvent e) => _touches.remove(e.pointer);

  /// Centroid of [_touches] and their mean distance from it.
  (Offset, double) _touchSpread() {
    var c = Offset.zero;
    for (final p in _touches.values) {
      c += p;
    }
    c /= _touches.length.toDouble();
    var r = 0.0;
    for (final p in _touches.values) {
      r += (p - c).distance;
    }
    return (c, r / _touches.length);
  }

  /// Two or more fingers: spreading them zooms and moving them together pans.
  void _onTouchesMoved(PointerMoveEvent e) {
    final (c0, r0) = _touchSpread();
    _touches[e.pointer] = e.localPosition;
    final (c1, r1) = _touchSpread();
    final d = c1 - c0;
    final s = camera.worldPerPixel((context.size ?? const Size(1, 1)).shortestSide);
    camera.pan -= vm.Vector2(d.dx * s, -d.dy * s);
    if (r0 > 0 && r1 > 0) _zoom(r0 / r1);
    _bump();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_touches.containsKey(e.pointer) && _touches.length >= 2) {
      _onTouchesMoved(e);
      return;
    }
    if (e.kind == ui.PointerDeviceKind.touch) {
      if (e.timeStamp - _turnTime > _restTime &&
          (e.localPosition - _turnPos).distance < _restSlop) {
        return;
      }
      _turnPos = e.localPosition;
      _turnTime = e.timeStamp;
    }
    final d = e.delta;
    final keys = HardwareKeyboard.instance;
    final size = context.size ?? const Size(1, 1);
    final panButtons = kSecondaryMouseButton | kMiddleMouseButton;
    if ((_buttons & panButtons) != 0 ||
        ((_buttons & kPrimaryMouseButton) != 0 && keys.isShiftPressed)) {
      final s = camera.worldPerPixel(size.shortestSide);
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
    return LayoutBuilder(builder: (context, c) {
      _fitHome(c.biggest);
      return _input(shader, table);
    });
  }

  Widget _input(ui.FragmentShader shader, ui.Image table) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      onPointerSignal: _onSignal,
      onPointerPanZoomStart: _onPanZoomStart,
      onPointerPanZoomUpdate: _onPanZoomScale,
      child: GestureDetector(
        onDoubleTap: resetView,
        child: CustomPaint(
          size: Size.infinite,
          painter: _RaycastPainter(
            shader: shader,
            raycast: _raycast(shader, table),
            repaint: _repaint,
          ),
        ),
      ),
    );
  }

  _Raycast _raycast(ui.FragmentShader shader, ui.Image table) => _Raycast(
        volume: widget.volume,
        volumeImage: widget.volumeImage,
        table: table,
        camera: camera,
        extent: _extent,
        settings: widget.settings,
        surfaces: widget.tf.mode == RenderMode.surfaces,
      );
}

/// What the ray caster needs to draw a view of the volume.
class _Raycast {
  _Raycast({
    required this.volume,
    required this.volumeImage,
    required this.table,
    required this.camera,
    required this.extent,
    required this.settings,
    required this.surfaces,
  });

  final VolumeData volume;
  final ui.Image volumeImage;
  final ui.Image table;
  final OrbitCamera camera;
  final vm.Vector3 extent;
  final RenderSettings settings;
  final bool surfaces;

  /// The most pixels rendered for the whole view, and the most ray steps
  /// across the volume's diagonal.
  static const movingPixels = 60000;
  static const movingSteps = 500;

  static const background = Color.fromRGBO(18, 18, 23, 1);

  /// The part of the view the volume box covers, or null if it is off screen.
  Rect? volumeRect(Size size) {
    // Must match the ray directions in raycast.frag.
    final t = camera.tanHalfFov * size.height / size.shortestSide;
    final eye = camera.eye;
    var r = Rect.zero;
    var first = true;
    for (var c = 0; c < 8; c++) {
      final p = vm.Vector3(c & 1 == 0 ? -extent.x : extent.x,
          c & 2 == 0 ? -extent.y : extent.y, c & 4 == 0 ? -extent.z : extent.z);
      final rel = p - eye;
      final z = rel.dot(camera.forward);
      // A corner at or behind the eye: the box may cover any part of the view.
      if (z <= 1e-6) return Offset.zero & size;
      final q = Offset(size.width / 2 + rel.dot(camera.right) / (z * t) * size.height / 2,
          size.height / 2 - rel.dot(camera.up) / (z * t) * size.height / 2);
      r = first ? Rect.fromPoints(q, q) : r.expandToInclude(Rect.fromPoints(q, q));
      first = false;
    }
    r = r.inflate(1).intersect(Offset.zero & size);
    return r.isEmpty ? null : r;
  }

  /// Sets [shader]'s uniforms for the current camera and a view of [size].
  void setUniforms(ui.FragmentShader shader, Size size) {
    final v = volume;
    final minSpacing = v.spacing.reduce(math.min);
    var step = minSpacing * settings.stepVoxels;
    step = math.max(step, 2 * extent.length / movingSteps);
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
    // No random start offsets: at this step and resolution they show as
    // large grains.
    f(0);
    f(v.atlasWidth.toDouble());
    f(v.atlasHeight.toDouble());
    v3(extent);
    v3(camera.eye);
    v3(camera.right);
    v3(camera.up);
    v3(camera.forward);
    // The field of view spans the shorter side, so a tall view shows it all.
    f(camera.tanHalfFov * size.height / size.shortestSide);
    f(step);
    // Surface opacity is per crossing; volume opacity is per
    // volumeOpacityDepth voxels of depth.
    f(surfaces ? 1.0 : step / minSpacing / volumeOpacityDepth);
    f(settings.shading ? 1.0 : 0.0);
    f(settings.normalSmoothing);
    f(background.r);
    f(background.g);
    f(background.b);
    f(1.0);
    f(surfaces ? 0.0 : 1.0);
    shader.setImageSampler(0, volumeImage, filterQuality: FilterQuality.low);
    shader.setImageSampler(1, table, filterQuality: FilterQuality.none);
  }
}

class _RaycastPainter extends CustomPainter {
  _RaycastPainter({
    required this.shader,
    required this.raycast,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final ui.FragmentShader shader;
  final _Raycast raycast;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _Raycast.background);
    final rect = raycast.volumeRect(size);
    if (rect == null) return;
    raycast.setUniforms(shader, size);
    final paint = Paint()..shader = shader;
    final scale = math.sqrt(_Raycast.movingPixels / (size.width * size.height));
    if (scale >= 1) {
      canvas.drawRect(rect, paint);
      return;
    }
    // Render the covered part into a small image and stretch it over the view.
    final w = (rect.width * scale).ceil(), h = (rect.height * scale).ceil();
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..scale(w / rect.width, h / rect.height)
      ..translate(-rect.left, -rect.top)
      ..drawRect(rect, paint);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(w, h);
    picture.dispose();
    canvas.drawImageRect(image, Offset.zero & Size(w.toDouble(), h.toDouble()), rect,
        Paint()..filterQuality = FilterQuality.low);
    image.dispose();
  }

  @override
  bool shouldRepaint(_RaycastPainter old) => true;
}
