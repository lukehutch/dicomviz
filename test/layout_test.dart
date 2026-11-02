import 'package:dicomviz/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpAt(WidgetTester t, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const DicomVizApp());
  }

  testWidgets('wide windows keep the series panel and have no menu button', (t) async {
    await pumpAt(t, const Size(1600, 1000));
    expect(find.text('Open folder…'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byIcon(Icons.menu), findsNothing);
  });

  for (final size in const [Size(360, 740), Size(740, 360), Size(320, 480), Size(999, 700)]) {
    testWidgets('narrow window $size opens and closes the panel', (t) async {
      await pumpAt(t, size);
      expect(find.text('Open folder…'), findsOneWidget);
      await t.tap(find.byIcon(Icons.close));
      await t.pump();
      expect(find.text('Open folder…'), findsNothing);
      await t.tap(find.byIcon(Icons.menu));
      await t.pump();
      expect(find.text('Open folder…'), findsOneWidget);
    });
  }
}
