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
    expect(rect.width,lessThan(335));
    expect(rect.left,lessThan(30));
    expect(400-rect.right,greaterThan(55));
  });

  testWidgets('Outgoing mobile card leaves space on the left', (tester) async {
    tester.view.physicalSize=const Size(400,800);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rect=await paintRect(tester,incoming:false);
    expect(rect.width,lessThan(335));
    expect(rect.left,greaterThan(55));
    expect(400-rect.right,lessThan(30));
  });
}
