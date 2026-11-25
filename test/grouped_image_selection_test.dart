import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/main.dart' show LiveTransferCard;
import 'package:file_share/lan_engine.dart';

void main(){
  testWidgets('Long press selects only one image within a two-file LAN card',
    (tester)async{
    final files=List.generate(2,(i)=>LanFile(
      id:'photo-$i',batch:'same-batch',name:'image_$i.png',
      path:'/missing/image_$i.png',peer:'Guest',incoming:false,
      size:512,created:DateTime(2026,11,21),
      state:TransferState.delivered));
    final selected=<String>{};
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:
      StatefulBuilder(builder:(context,refresh)=>LiveTransferCard(
        items:files,
        onSave:(_)=>Future<void>.value(),
        onDelete:(_)=>Future<void>.value(),
        onShare:(_)=>Future<void>.value(),
        onTools:(_)=>Future<void>.value(),
        fileSelectionActive:selected.isNotEmpty,
        isFileSelected:(file)=>selected.contains(file.id),
        onFileSelect:(file)=>refresh((){
          if(!selected.add(file.id))selected.remove(file.id);
        }),
      )))));
    // Select the actual file previews, not a placeholder icon. The new lazy
    // thumbnail renderer may show a decoded photo or an error placeholder,
    // and neither choice should change selection semantics.
    final first=find.byKey(const ValueKey('lan-file-preview-photo-0'));
    final second=find.byKey(const ValueKey('lan-file-preview-photo-1'));
    expect(first,findsOneWidget);
    expect(second,findsOneWidget);
    await tester.longPress(first);
    await tester.pump();
    expect(selected,{'photo-0'});
    await tester.tap(second);
    await tester.pump();
    expect(selected,{'photo-0','photo-1'});
    await tester.tap(first);
    await tester.pump();
    expect(selected,{'photo-1'});
  });
}
