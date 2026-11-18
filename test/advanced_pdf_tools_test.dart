import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/advanced_pdf_tools_page.dart';
import 'package:file_share/pdf_history.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Every upstream PDF tool has exactly one registered entry',(){
    expect(pdfFeatures.length,24);
    expect(pdfFeatures.map((t)=>t.id).toSet().length,24);
    expect(pdfFeatures.where((e)=>e.active).length,24);
    expect(pdfFeatures.map((e)=>e.id).toSet().containsAll({
      'scan','workflow','merge','alternate','compress','split','splitText',
      'splitBookmarks','splitHalf','splitSize','organize','rotate','flip',
      'nup','crop','zip','fillSign','watermark','pageNumbers','redact','ocr',
      'unlock','metadata','password',
    }),isTrue);
  });

  test('Rename creates safe filenames and preserves .pdf only once',(){
    expect(PdfHistory.validName('Form'),'Form.pdf');
    expect(PdfHistory.validName('report.PDF'),'report.pdf');
    expect(PdfHistory.validName('bad:name.pdf'),'bad_name.pdf');
    expect(PdfHistory.validName(''),'Document.pdf');
    expect(PdfHistory.validName('x' * 200).length,lessThanOrEqualTo(104));
  });

  test('Platform channel forwards every result in a multi-PDF operation',()async{
    const channel=MethodChannel('file_share.native');
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel,(call)async{
      received=call;
      if(call.method=='pdf.processMany')return [
        {'name':'first','path':'/temp/first.pdf'},
        {'name':'second','path':'/temp/second.pdf'},
      ];
      return null;
    });
    addTearDown(()=>messenger.setMockMethodCallHandler(channel,null));
    final outputs=await AdvancedPdfEngine.multiple(
      '/temp/original.pdf','split',{'mode':'every'});
    expect(received?.method,'pdf.processMany');
    expect(received?.arguments,containsPair('tool','split'));
    expect(outputs.map((e)=>e['name']).toList(),['first','second']);
  });

  test('Page preview API remains separate from full-quality edit',()async{
    const channel=MethodChannel('file_share.native');
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final called=<String>[];
    messenger.setMockMethodCallHandler(channel,(call)async{
      called.add(call.method);
      if(call.method=='pdf.countPages')return 3;
      if(call.method=='pdf.renderPage')return Uint8List.fromList([1,2]);
      if(call.method=='pdf.process')return '/temp/processed.pdf';
      return null;
    });
    addTearDown(()=>messenger.setMockMethodCallHandler(channel,null));
    expect(await AdvancedPdfEngine.pages('test.pdf'),3);
    expect(await AdvancedPdfEngine.pageImage('test.pdf',1),[1,2]);
    expect(await AdvancedPdfEngine.edit('test.pdf','rotate',{'degrees':90}),
      '/temp/processed.pdf');
    expect(called,['pdf.countPages','pdf.renderPage','pdf.process']);
  });

  testWidgets('PDF native UI is restricted to Android',(tester)async{
    if(Platform.isAndroid)return;
    await tester.pumpWidget(const MaterialApp(home:AdvancedPdfToolsPage()));
    expect(find.textContaining('Only Available on Android'),findsOneWidget);
    expect(find.byType(FloatingActionButton),findsNothing);
  });
}
