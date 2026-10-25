import 'dart:math' as math;

import 'package:dicomviz/render/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  // An oblique home orientation, so the test does not depend on axis-aligned
  // special cases.
  final q = Quaternion.axisAngle(Vector3(1, 2, 3)..normalize(), 0.7);
  final r = q.asRotationMatrix();
  final home = Matrix3.zero()
    ..setRow(0, r.transformed(Vector3(1, 0, 0)))
    ..setRow(1, r.transformed(Vector3(0, 1, 0)))
    ..setRow(2, r.transformed(Vector3(0, 0, 1)));

  double tilt(OrbitCamera c) =>
      math.atan2(c.vertical.dot(c.basis.row2), c.vertical.dot(c.up));

  test('vertical axis stays in the screen up/view plane', () {
    final c = OrbitCamera(home: home, homeDistance: 1);
    final rnd = math.Random(1);
    for (var i = 0; i < 5000; i++) {
      c.rotate((rnd.nextDouble() - 0.5) * 0.4, (rnd.nextDouble() - 0.5) * 0.4);
      expect(c.right.dot(c.vertical).abs(), lessThan(1e-9));
      expect(c.up.dot(c.vertical), greaterThan(-1e-9));
      expect(c.right.length, closeTo(1, 1e-9));
      expect(c.up.dot(c.right).abs(), lessThan(1e-9));
    }
  });

  test('yaw keeps the tilt; pitch changes it and stops at 90 degrees', () {
    final c = OrbitCamera(home: home, homeDistance: 1);
    c.rotate(0, 0.3);
    expect(tilt(c), closeTo(0.3, 1e-9));
    c.rotate(1.2, 0);
    expect(tilt(c), closeTo(0.3, 1e-9));
    c.rotate(0, 5);
    expect(tilt(c), closeTo(math.pi / 2, 1e-9));
    c.rotate(0, -10);
    expect(tilt(c), closeTo(-math.pi / 2, 1e-9));
  });
}
