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

  test('Repeated edited photo and signature are new independent Cart versions',
      () async {
    final folder=await Directory.systemTemp.createTemp('edited_cart_versions_');
    addTearDown(()=>folder.delete(recursive:true));
    final cart=ImageEditingCart.instance;
    cart.takeAll();
    final first=await cart.addEditedBytes([1,2,3,4],'signature.jpg',
      destinationDirectory:folder);
    final second=await cart.addEditedBytes([1,2,3,4],'signature.jpg',
      destinationDirectory:folder);
    final third=await cart.addEditedBytes([7,8,9],'signature.jpg',
      destinationDirectory:folder);
    final items=cart.takeAll();
    expect(items.map((e)=>e.versionId).toSet().length,3);
    expect(items.map((e)=>e.file.path).toSet().length,3);
    expect(items.map((e)=>e.name).toList(),
      ['signature.jpg','signature.jpg','signature.jpg']);
    expect(await first.file.readAsBytes(),[1,2,3,4]);
    expect(await second.file.readAsBytes(),[1,2,3,4]);
    expect(await third.file.readAsBytes(),[7,8,9]);
    expect(cart.takeAll(),isEmpty);
  });

  test('Already sent or received file can be edited and re-added again',
      () async {
    final folder=await Directory.systemTemp.createTemp('editor_resend_');
    addTearDown(()=>folder.delete(recursive:true));
    final original=File('${folder.path}/received.pdf');
    await original.writeAsBytes([37,80,68,70,1,2,3]);
    final cart=ImageEditingCart.instance;
    cart.takeAll();
    final first=await cart.addEditedFile(original,'edited.pdf',
      destinationDirectory:folder);
    await original.writeAsBytes([37,80,68,70,4,5,6]);
    final second=await cart.addEditedFile(original,'edited.pdf',
      destinationDirectory:folder);
    final pending=cart.takeAll();
    expect(pending,hasLength(2));
    expect(first.file.path,isNot(second.file.path));
    expect(first.versionId,isNot(second.versionId));
    expect(await first.file.readAsBytes(),[37,80,68,70,1,2,3]);
    expect(await second.file.readAsBytes(),[37,80,68,70,4,5,6]);
    expect(await original.readAsBytes(),[37,80,68,70,4,5,6]);
  });

}
