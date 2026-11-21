import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:file_share/id_card_pdf_engine.dart';

void main(){
  Uint8List picture(int width,int height){
    final source=img.Image(width:width,height:height);
    img.fill(source,color:img.ColorRgb8(255,255,255));
    img.fillRect(source,x1:10,y1:10,x2:width-10,y2:height-10,
      color:img.ColorRgb8(27,90,165));
    return Uint8List.fromList(img.encodePng(source));
  }

  test('normal crop keeps selected source region',()async{
    final result=img.decodePng(await IdCardPdfEngine.crop(
      picture(300,180),const IdCardCrop(
        rect:RectValues(.1,.2,.9,.8))))!;
    expect(result.width,240);
    expect(result.height,inInclusiveRange(107,110));
  });

  test('perspective crop makes a real rectified image',()async{
    final result=img.decodePng(await IdCardPdfEngine.crop(
      picture(300,180),const IdCardCrop(
        quad:[.10,.15,.90,.12,.92,.85,.12,.90])))!;
    expect(result.width,greaterThan(200));
    expect(result.height,greaterThan(100));
  });

  test('one A4 layout fits one through five cards and preserves bounds',(){
    for(var count=1;count<=5;count++){
      final layout=IdCardPdfEngine.initialLayout(count);
      expect(layout.length,count);
      for(final box in layout){
        expect(box.x,greaterThanOrEqualTo(0));
        expect(box.y,greaterThanOrEqualTo(0));
        expect(box.x+box.width,lessThanOrEqualTo(1.0001));
        expect(box.y+box.height,lessThanOrEqualTo(1.0001));
      }
    }
  });

  test('normal PDF and single A4 ID card PDF produce real PDF bytes',()async{
    final pics=[picture(250,150),picture(240,140)];
    final normal=await IdCardPdfEngine.normalPdf(pics);
    final id=await IdCardPdfEngine.a4Pdf(pics,
      IdCardPdfEngine.initialLayout(2));
    expect(String.fromCharCodes(normal.take(5)),'%PDF-');
    expect(String.fromCharCodes(id.take(5)),'%PDF-');
  });
}
