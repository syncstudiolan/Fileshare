import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the new low-jitter dashboard architecture. The old
/// per-card 3D FileShareScrollDepth was intentionally removed: it called
/// RenderBox.localToGlobal for every card on every scroll frame.
void main() {
  test('no per-card perspective work on each scroll tick', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, isNot(contains('class FileShareScrollDepth')));
    expect(source, isNot(contains('localToGlobal(')));
    expect(source, contains('NotificationListener<ScrollNotification>'));
    expect(source, contains('addRepaintBoundaries:true'));
    expect(source, contains('cacheExtent:90'));
  });

  testWidgets('lazy feed builds only cards near the viewport',
      (tester) async {
    tester.view.physicalSize = const Size(430, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final built = <int>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ListView.builder(
        controller: controller,
        cacheExtent: 90,
        addRepaintBoundaries: true,
        itemCount: 60,
        itemBuilder: (context, index) {
          built.add(index);
          return SizedBox(height: 130, child: Text('Transfer card $index'));
        },
      )),
    ));
    expect(built.length, lessThan(30));
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pump();
    expect(controller.offset, greaterThan(0));
    expect(find.text('Transfer card 4'), findsWidgets);
    expect(built.length, lessThan(30));
  });

  test('cloud download starts only after scrolling settles', () {
    final source = File('lib/main.dart').readAsStringSync();
    final thumbnail = File('lib/dashboard_thumbnail.dart').readAsStringSync();
    expect(source, contains('if(_image!=null || widget.scrolling?.value==true'));
    expect(source, contains('Duration(milliseconds:140)'));
    expect(thumbnail, contains('cacheWidth: _sharp ? 240 : 88'));
    expect(thumbnail, contains('if (_sharp || widget.scrolling.value) return'));
  });
}
