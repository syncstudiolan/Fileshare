import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/main.dart';
import 'package:file_share/toolbox_page.dart';
import 'package:file_share/signature_edit_page.dart';

void main(){
  test('Card routing distinguishes files without accidentally editing photos',(){
    expect(FileCardOpenRouter.isPdf('invoice.PDF'),isTrue);
    expect(FileCardOpenRouter.isDocx('letter.docx'),isTrue);
    expect(FileCardOpenRouter.isImage('portrait.PNG'),isTrue);
    expect(FileCardOpenRouter.isPdf('portrait.png'),isFalse);
    expect(FileCardOpenRouter.isDocx('video.mp4'),isFalse);
  });

  testWidgets('Signature Edit opens without requiring source image',
      (tester)async{
    await tester.pumpWidget(const MaterialApp(home:SignatureEditPage()));
    expect(find.text('Signature Edit'),findsOneWidget);
    expect(find.text('Crop'),findsOneWidget);
    expect(find.text('Compress'),findsOneWidget);
    expect(find.text('Filters'),findsOneWidget);
    expect(find.text('Camera'),findsOneWidget);
    expect(find.text('Browse'),findsOneWidget);
    expect(find.byTooltip('Add to File Share Cart'),findsOneWidget);
    final cartButton=find.ancestor(
      of:find.byTooltip('Add to File Share Cart'),
      matching:find.byType(IconButton));
    expect(tester.widget<IconButton>(cartButton.first).onPressed,isNull);
  });

  testWidgets('Signature Edit target size presets are editable',
      (tester)async{
    await tester.pumpWidget(const MaterialApp(home:SignatureEditPage()));
    await tester.tap(find.text('Compress').last);
    await tester.pump();
    expect(find.text('Exact Export Size'),findsOneWidget);
    expect(find.text('5 KB'),findsOneWidget);
    await tester.tap(find.text('50 KB'));
    await tester.pump();
    expect(find.text('50'),findsWidgets);
  });

  testWidgets('Target KB choices expose temporary Apply control on all platforms',
      (tester)async{
    await tester.pumpWidget(const MaterialApp(home:SignatureEditPage()));
    await tester.tap(find.text('Compress').last);
    await tester.pump();
    final apply=find.widgetWithText(FilledButton,'Apply Target Size');
    expect(apply,findsOneWidget);
    expect(tester.widget<FilledButton>(apply).onPressed,isNull,
      reason:'No signature loaded yet; applying must not create a fake file');
    await tester.tap(find.text('10 KB'));
    await tester.pump();
    expect(find.text('10'),findsWidgets);
    expect(find.text('Apply Target Size'),findsOneWidget);
  });

  testWidgets('Toolbox exposes both image editor and Signature Edit',
      (tester)async{
    await tester.pumpWidget(
      const MaterialApp(home:FileShareToolboxPage()));
    expect(find.text('Image Editing'),findsOneWidget);
    expect(find.text('Signature Edit'),findsOneWidget);
    // PDF lives lower in the lazily built grid and has its own filter test.
    expect(find.text('Signature Edit'),findsOneWidget);
    await tester.tap(find.text('Signature Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Crop'),findsOneWidget);
  });
}
