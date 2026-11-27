import 'dart:io';

import 'package:file_share/main.dart' show FileTheme, TransferBubble;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('received messages use white readable text in light and dark',
      (tester) async {
    for(final brightness in [Brightness.light,Brightness.dark]) {
      await tester.pumpWidget(MaterialApp(
        theme:FileTheme.build(brightness),
        home:Scaffold(body:TransferBubble(
          incoming:true,
          child:Builder(builder:(context)=>Text('Received file',
            style:TextStyle(color:FileTheme.foreground(context)))),
        )),
      ));
      expect(tester.widget<Text>(find.text('Received file')).style!.color,
        Colors.white);
    }
  });

  test('received gradient retains deep leaf tones and sent blue', () {
    final source=File('lib/main.dart').readAsStringSync();
    expect(source,contains('Color(0xFF267A50)'));
    expect(source,contains('Color(0xFF0B432F)'));
    expect(source,contains('Color(0xFF9DD7FF)'));
    expect(source,contains('TransferCardInk(incoming:incoming'));
  });

  test('sent and received cards have elevation without a white stroke', () {
    final source=File('lib/main.dart').readAsStringSync();
    final painter=source.split('class _TransferBubblePainter extends CustomPainter').last
      .split('class TransferCardActions extends StatelessWidget').first;
    expect(painter,contains('canvas.drawShadow(path,'));
    expect(painter,contains('canvas.drawPath(path,Paint()..shader='));
    expect(painter,isNot(contains('PaintingStyle.stroke')));
    final panel=source.split('class DesignPanel extends StatelessWidget').last
      .split('class DesignTag extends StatelessWidget').first;
    expect(panel,contains('boxShadow:['));
    expect(panel,isNot(contains('border:Border.all(')));
  });

  test('lazy scrolling does not build/decode intermediate full thumbnails', () {
    final src=File('lib/main.dart').readAsStringSync();
    final thumbs=File('lib/dashboard_thumbnail.dart').readAsStringSync();
    expect(src,contains('cacheExtent:90'));
    expect(src,contains('addRepaintBoundaries:true'));
    expect(src,contains('NotificationListener<ScrollNotification>'));
    expect(src,contains('scrolling:_dashboardScrolling'));
    expect(src,contains('if(_image!=null || widget.scrolling?.value==true'));
    expect(thumbs,contains('cacheWidth: _sharp ? 240 : 88'));
    expect(thumbs,contains('Duration(milliseconds: 140)'));
    expect(src,contains('RepaintBoundary('));
    expect(src, isNot(contains('FileShareScrollDepth(')));
  });
}
