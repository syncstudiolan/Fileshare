import 'package:file_share/image_editing_page.dart';
import 'package:file_share/toolbox_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main(){
  testWidgets('Toolbox search finds Image Editing and filters future tools',
    (tester)async{
    await tester.pumpWidget(const MaterialApp(home:FileShareToolboxPage()));
    expect(find.text('Search tools...'),findsOneWidget);
    expect(find.text('Image Editing'),findsOneWidget);
    expect(find.text('Signature Editing'),findsOneWidget);
    expect(find.text('Advanced PDF Editing Tools'),findsOneWidget);
    await tester.enterText(find.byType(TextField),'image');
    await tester.pump();
    expect(find.text('Image Editing'),findsOneWidget);
    expect(find.text('Signature Editing'),findsNothing);
    expect(find.text('Advanced PDF Editing Tools'),findsNothing);
  });

  testWidgets('Image Editing opens without a photo and shows Camera and Browse',
    (tester)async{
    await tester.pumpWidget(const MaterialApp(home:ImageEditingPage()));
    await tester.pump();
    expect(find.text('Choose an image'),findsOneWidget);
    expect(find.text('Camera'),findsOneWidget);
    expect(find.text('Browse images'),findsOneWidget);
    expect(find.text('Send to File Share Cart'),findsNothing);
    final cart=find.byTooltip('Send to File Share Cart');
    expect(cart,findsOneWidget);
    final cartButton=find.ancestor(of:cart,matching:find.byType(IconButton));
    expect(tester.widget<IconButton>(cartButton.first).onPressed,isNull);
    expect(find.byTooltip('Apply'),findsOneWidget);
    expect(find.byTooltip('Undo'),findsOneWidget);
    expect(find.byTooltip('Redo'),findsOneWidget);
  });

  testWidgets('Android-only PDF Toolbox provides a clear desktop warning',
    (tester)async{
    await tester.pumpWidget(const MaterialApp(home:FileShareToolboxPage()));
    await tester.tap(find.text('Advanced PDF Editing Tools'));
    await tester.pumpAndSettle();
    expect(find.textContaining('These tools are only available on Android/mobile.'),findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });
}
