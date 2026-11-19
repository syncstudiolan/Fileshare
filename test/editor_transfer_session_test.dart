import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/editor_transfer_session.dart';
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
    for(final name in ['statement.PDF']){
      expect(EditingFileRouter.acceptsPdfTool(name),isTrue);
      expect(EditingFileRouter.acceptsImageTool(name),isFalse);
    }
    for(final name in ['report.doc','invoice.docx','sheet.xls','table.xlsx',
        'letter.odt','sheet.ods','film.mp4','clip.mov','film.mkv','archive.zip']){
      expect(EditingFileRouter.acceptsPdfTool(name),isFalse);
      expect(EditingFileRouter.acceptsImageTool(name),isFalse);
    }
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
