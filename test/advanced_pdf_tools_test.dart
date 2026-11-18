import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/advanced_pdf_tools_page.dart';
import 'package:file_share/pdf_history.dart';

void main(){
  test('PDF tool IDs are unique and Android catalogue has 24 entries',(){
    expect(pdfFeatures.length,24);
    expect(pdfFeatures.map((t)=>t.id).toSet().length,24);
    expect(pdfFeatures.singleWhere((t)=>t.id=='scan').active,isTrue);
  });
  test('PDF names are normalized for rename and saved history',(){
    expect(PdfHistory.validName('Document'),'Document.pdf');
    expect(PdfHistory.validName('statement.PDF'),'statement.pdf');
    expect(PdfHistory.validName('bad:name.pdf'),'bad_name.pdf');
    expect(PdfHistory.validName(''),'Document.pdf');
  });
  testWidgets('PDF tools cannot run on non-Android platforms',(tester)async{
    if(Platform.isAndroid)return;
    await tester.pumpWidget(const MaterialApp(home:AdvancedPdfToolsPage()));
    expect(find.textContaining('Only Available on Android'),findsOneWidget);
    expect(find.byType(FloatingActionButton),findsNothing);
  });
}
