import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Perspective camera orbiting the volume center. Vectors are in volume
/// space, where the volume box is centered on the origin.
class OrbitCamera {
  OrbitCamera({required this.home, required this.homeDistance}) {
    reset();
  }

  /// Initial orientation: rows are the camera's right, up and back axes
  /// expressed in volume space.
  final Matrix3 home;
  final double homeDistance;

  /// Rows: right, up, back (= -forward), in volume space.
  late Matrix3 basis;
  late double distance;

  /// Pan offset of the eye in camera right/up units (world units).
  Vector2 pan = Vector2.zero();
  static const defaultFovY = 30 * degrees2Radians;
  double fovY = defaultFovY;

  void reset() {
    basis = home.clone();
    distance = homeDistance;
    pan = Vector2.zero();
  }

  Vector3 get right => basis.row0;
  Vector3 get up => basis.row1;
  Vector3 get forward => -basis.row2;

  Vector3 get eye =>
      right * pan.x + up * pan.y - forward * distance;

  /// The scan's vertical axis (the home up vector), in volume space.
  Vector3 get vertical => home.row1;

  /// Rotates the camera around the volume center, turntable style, so the
  /// scan's vertical axis always projects onto the screen's vertical axis:
  /// [yaw] turns around the scan's vertical axis, [pitch] tips it toward or
  /// away from the viewer, limited to top and bottom views. Radians.
  void rotate(double yaw, double pitch) {
    final v = vertical;
    // Tilt of the vertical axis from the camera's up axis toward its back
    // axis; rotating the camera by angle a about [right] changes it by -a.
    final tilt = math.atan2(v.dot(basis.row2), v.dot(up));
    final newTilt = (tilt + pitch).clamp(-math.pi / 2, math.pi / 2);
    final q = Quaternion.axisAngle(v, -yaw) * Quaternion.axisAngle(right, tilt - newTilt);
    final r = q.asRotationMatrix();
    // Keep right exactly perpendicular to the vertical axis (no roll).
    var nr = r.transformed(right);
    nr = (nr - v * nr.dot(v))..normalize();
    var nu = r.transformed(up);
    nu = (nu - nr * nu.dot(nr))..normalize();
    final nb = nr.cross(nu)..normalize();
    basis = Matrix3.zero()
      ..setRow(0, nr)
      ..setRow(1, nu)
      ..setRow(2, nb);
  }

  /// World units per screen pixel at the volume center.
  double worldPerPixel(double viewportHeight) =>
      2 * distance * tanHalfFov / viewportHeight;

  double get tanHalfFov => math.tan(fovY / 2);
}
