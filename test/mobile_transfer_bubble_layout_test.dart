import 'package:flutter/material.dart';
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


}
