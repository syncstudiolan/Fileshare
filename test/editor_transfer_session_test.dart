import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/editor_transfer_session.dart';
import 'package:file_share/advanced_pdf_tools_page.dart';
import 'package:file_share/image_editing_storage.dart';
import 'dart:io';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Dashboard file router distinguishes image, PDF, Office and video',(){
    for(final name in ['photo.JPG','receipt.png','scan.webp']){
      expect(EditingFileRouter.classify(name),EditingFileKind.image);
      expect(EditingFileRouter.acceptsImageTool(name),isTrue);
      expect(EditingFileRouter.acceptsPdfTool(name),isTrue);
    }
    for(final name in ['statement.PDF','report.doc','invoice.docx',
        'sheet.xls','table.xlsx','letter.odt','sheet.ods']){
      expect(EditingFileRouter.acceptsPdfTool(name),isTrue);
      expect(EditingFileRouter.acceptsImageTool(name),isFalse);
    }
    for(final name in ['film.mp4','clip.mov','film.mkv','archive.zip']){
      expect(EditingFileRouter.acceptsPdfTool(name),isFalse);
      expect(EditingFileRouter.acceptsImageTool(name),isFalse);
    }
  });

  test('Image import uses native PDF fromImages and Office uses fromOffice',()async{
    const channel=MethodChannel('file_share.native');
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls=<MethodCall>[];
    messenger.setMockMethodCallHandler(channel,(call)async{
      calls.add(call);
      if(call.method=='pdf.fromImages')return '/tmp/from_image.pdf';
      if(call.method=='pdf.fromOffice')return '/tmp/from_office.pdf';
      return null;
    });
    addTearDown(()=>messenger.setMockMethodCallHandler(channel,null));
    expect(await PdfSourceConversion.toPdf('/tmp/picture.jpg','picture.jpg'),
      '/tmp/from_image.pdf');
    expect(await PdfSourceConversion.toPdf('/tmp/notes.docx','notes.docx'),
      '/tmp/from_office.pdf');
    expect(calls.map((c)=>c.method),[
      'pdf.fromImages','pdf.fromOffice',
    ]);
    expect(calls.last.arguments,containsPair('name','notes.docx'));
    expect(await PdfSourceConversion.toPdf('/tmp/printed.pdf','printed.pdf'),
      '/tmp/printed.pdf');
    expect(()=>PdfSourceConversion.toPdf('/tmp/movie.mp4','movie.mp4'),
      throwsFormatException);
  });

  test('Cart queue records immutable source filenames and keeps staging separate',()async{
    final root=await Directory.systemTemp.createTemp('fileshare_stage_test_');
    addTearDown(()=>root.delete(recursive:true));
    final file=File('${root.path}/snapshot.png');
    await file.writeAsBytes([1,2,3]);
    final pending=ImageEditingCart.instance;
    pending.takeAll(); // Isolate test from other in-memory tests.
    pending.add(file,'edited-photo.png');
    final taken=pending.takeAll();
    expect(taken.length,1);
    expect(taken.single.name,'edited-photo.png');
    expect(await taken.single.file.readAsBytes(),[1,2,3]);
    expect(pending.takeAll(),isEmpty);
  });
}
