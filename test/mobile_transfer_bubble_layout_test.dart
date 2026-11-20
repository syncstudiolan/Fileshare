import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/main.dart' show TransferBubble;

void main() {
  Future<Rect> paintRect(WidgetTester tester,{required bool incoming}) async {
    final key=ValueKey(incoming?'incoming':'outgoing');
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:Center(
      child:SizedBox(width:400,child:TransferBubble(
        key:key,incoming:incoming,
        child:const SizedBox(height:95,child:Text('File Transfer'))))))));
    final node=find.descendant(
      of:find.byKey(key),matching:find.byType(CustomPaint)).first;
    return tester.getRect(node);
  }

  testWidgets('Incoming mobile card leaves space on the right', (tester) async {
    tester.view.physicalSize=const Size(400,800);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rect=await paintRect(tester,incoming:true);
    expect(rect.width,inInclusiveRange(362,366));
    expect(rect.left,lessThan(30));
    expect(400-rect.right,greaterThan(35));
  });

  testWidgets('Outgoing mobile card leaves space on the left', (tester) async {
    tester.view.physicalSize=const Size(400,800);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rect=await paintRect(tester,incoming:false);
    expect(rect.width,inInclusiveRange(356,360));
    expect(rect.left,greaterThan(35));
    expect(400-rect.right,lessThan(30));
  });

  testWidgets('Text bubble is compact and the theme does not move cards',
      (tester) async {
    tester.view.physicalSize=const Size(400,800);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<Rect> textRect(ThemeMode mode) async {
      await tester.pumpWidget(MaterialApp(themeMode:mode,
        theme:ThemeData.light(),darkTheme:ThemeData.dark(),
        home:Scaffold(body:SizedBox(width:400,child:TransferBubble(
          key:const ValueKey('text'),incoming:true,textOnly:true,
          child:const Text('Hi'))))));
      final paint=find.descendant(of:find.byKey(const ValueKey('text')),
        matching:find.byType(CustomPaint)).first;
      return tester.getRect(paint);
    }
    final light=await textRect(ThemeMode.light);
    final dark=await textRect(ThemeMode.dark);
    expect(light.width,inInclusiveRange(338,342));
    expect(light,dark);
  });

  testWidgets('Rendered tails point left for received and right for sent',
      (tester) async {
    tester.view.physicalSize=const Size(400,200);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for(final mode in [ThemeMode.light,ThemeMode.dark]){
      for(final incoming in [true,false]){
        final key=UniqueKey();
        await tester.pumpWidget(MaterialApp(themeMode:mode,
          theme:ThemeData.light(),darkTheme:ThemeData.dark(),
          home:RepaintBoundary(key:key,child:ColoredBox(
            color:Colors.white,child:SizedBox(width:400,height:200,
              child:TransferBubble(incoming:incoming,
                child:const SizedBox(height:95)))))));
        await tester.pump();
        final paint=find.descendant(of:find.byType(TransferBubble),
          matching:find.byType(CustomPaint)).first;
        final rect=tester.getRect(paint);
        final frame=tester.getRect(find.byKey(key));
        final image=await tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key)).toImage(pixelRatio:1);
        final bytes=(await image.toByteData(format:ui.ImageByteFormat.rawRgba))!;
        int lightAt(int x,int y){
          final index=(y*image.width+x)*4;
          return bytes.getUint8(index)+bytes.getUint8(index+1)+
            bytes.getUint8(index+2);
        }
        final y=(rect.top-frame.top+52).round();
        final tail=(incoming?rect.left-frame.left+2:rect.right-frame.left-2)
          .round();
        final blank=incoming?image.width-2:2;
        expect(lightAt(tail,y),lessThan(lightAt(blank,y)-10));
        image.dispose();
      }
    }
  });
}
