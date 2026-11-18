import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:file_share/image_editing_engine.dart';
import 'package:file_share/pdf_document_scanner_page.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List sample(){
    final photo=img.Image(width:120,height:80,numChannels:4);
    img.fill(photo,color:img.ColorRgba8(50,120,200,255));
    return Uint8List.fromList(img.encodePng(photo));
  }

  test('Fine straighten changes geometry and preserves nonempty output',()async{
    final input=sample();
    final result=await ImageEditingEngine.edit(input,'straighten',{
      'degrees':2.5,'autoCrop':true,
    });
    final decoded=img.decodePng(result);
    expect(decoded,isNotNull);
    expect(decoded!.width,greaterThan(20));
    expect(decoded.height,greaterThan(20));
    expect(decoded.getPixel(decoded.width~/2,decoded.height~/2).a,greaterThan(0));
  });

  test('Straighten with no auto-crop retains the rotation expansion',()async{
    final input=sample();
    final cropped=img.decodeImage(await ImageEditingEngine.edit(
      input,'straighten',{'degrees':10,'autoCrop':true}))!;
    final expanded=img.decodeImage(await ImageEditingEngine.edit(
      input,'straighten',{'degrees':10,'autoCrop':false}))!;
    expect(cropped.width,lessThanOrEqualTo(expanded.width));
    expect(cropped.height,lessThanOrEqualTo(expanded.height));
  });

  test('Manual eraser removes the touched pixels and restore recovers alpha',()async{
    final initial=sample();
    final erased=await ImageEditingEngine.edit(initial,'erase',{
      'points':[{'x':.5,'y':.5}], 'radius':.15,'softness':.5,
    });
    final e=img.decodeImage(erased)!;
    expect(e.getPixel(60,40).a,lessThan(100));
    final restored=await ImageEditingEngine.edit(erased,'restore',{
      'points':[{'x':.5,'y':.5}], 'radius':.15,'softness':.5,
    });
    final r=img.decodeImage(restored)!;
    expect(r.getPixel(60,40).a,greaterThan(e.getPixel(60,40).a));
  });

  test('Scanner supports separate normal and perspective crop settings',(){
    final shot=ScanSheet(path:'test.jpg');
    expect(shot.cropMode,'Perspective');
    shot.cropMode='Normal';
    shot.crop=const Rect.fromLTWH(.1,.2,.7,.6);
    expect(shot.crop.left,.1);
    expect(shot.crop.width,.7);
  });
}
