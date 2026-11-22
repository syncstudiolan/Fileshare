import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/universal_tool_switcher.dart';

void main(){
  testWidgets('Tool switch occupies one compact button and never picks current editor',
      (tester)async{
    var snapshots=0;
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      appBar:AppBar(actions:[
        ToolSwitchButton(current:EditorDestination.image,
          snapshot:(target)async{
            snapshots++;
            throw StateError('No source');
          }),
      ]))));
    expect(find.byTooltip('Switch editing tool'),findsOneWidget);
    await tester.tap(find.byTooltip('Switch editing tool'));
    await tester.pumpAndSettle();
    expect(find.text('Switch Editing Tool'),findsOneWidget);
    expect(find.text('Image Editing'),findsNothing);
    expect(find.text('Signature Editing'),findsOneWidget);
    expect(find.text('Advanced PDF Pro'),findsOneWidget);
    expect(find.text('File Share Doc'),findsOneWidget);
    expect(snapshots,0);
    await tester.tapAt(const Offset(2,2));
    await tester.pumpAndSettle();
    expect(snapshots,0);
  });

  testWidgets('Disabled switch cannot open any tool', (tester)async{
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      appBar:AppBar(actions:[
        ToolSwitchButton(current:EditorDestination.signature,
          enabled:false,snapshot:(_)=>Future<File>.error('disabled')),
      ]))));
    await tester.tap(find.byIcon(Icons.swap_horiz_rounded),
      warnIfMissed:false);
    await tester.pumpAndSettle();
    expect(find.text('Switch Editing Tool'),findsNothing);
  });
}
