import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:file_share/signature_edit_engine.dart';

void main(){
  Uint8List source(){
    final frame=img.Image(width:340,height:110);
    img.fill(frame,color:img.ColorRgb8(255,255,255));
    for(var x=22;x<315;x++){
      final y=55+(20*((x/16)%5)/5).round();
      for(var dy=-2;dy<=2;dy++){
        frame.setPixelRgb(x,(y+dy).clamp(0,109),15,15,25);
      }
    }
    return Uint8List.fromList(img.encodePng(frame));
  }

  test('JPEG metadata padding has exact bytes and remains decodable',(){
    final jpeg=Uint8List.fromList(img.encodeJpg(
      img.Image(width:30,height:10),quality:80));
    for(final target in [jpeg.length+4,jpeg.length+16,
      jpeg.length+100000]){
      final bytes=SignatureEditEngine.padJpegToExactSize(jpeg,target);
      expect(bytes.length,target);
      expect(img.decodeJpg(bytes),isNotNull);
    }
    expect(
      ()=>SignatureEditEngine.padJpegToExactSize(jpeg,jpeg.length-1),
      throwsStateError);
  });

  test('20 KB user target becomes exactly 20 * 1024 bytes',()async{
    final result=await SignatureEditEngine.exactJpeg(
      source(),SignatureCrop.full,'Black & White',20);
    expect(result.length,20*1024);
    expect(img.decodeJpg(result),isNotNull);
  });

  test('40 KB cropped blue signature stays exactly 40 KB',()async{
    final result=await SignatureEditEngine.exactJpeg(source(),
      const SignatureCrop(.05,.08,.95,.94),'Blue Ink',40);
    expect(result.length,40960);
    final image=img.decodeJpg(result);
    expect(image,isNotNull);
    expect(image!.width,lessThan(340));
  });

  test('Invalid targets fail rather than exporting a wrong size',()async{
    expect(
      ()=>SignatureEditEngine.exactJpeg(
        source(),SignatureCrop.full,'Original',0),
      throwsArgumentError);
  });
  test('5 KB export supports perspective corners and filter',()async{
    final quad=SignatureCrop(0,0,1,1,quad:[
      .10,.08, .94,.04, .89,.94, .06,.88,
    ]);
    final preview=await SignatureEditEngine.preview(source(),quad,'Blue Ink');
    final decoded=img.decodeJpg(preview);
    expect(decoded,isNotNull);
    expect(decoded!.width,greaterThan(10));
    final file=await SignatureEditEngine.exactJpeg(
      source(),quad,'Dark Ink',5);
    expect(file.length,5120);
    expect(img.decodeJpg(file),isNotNull);
  });

  test('targets below 5 KB are rejected',()async{
    expect(()=>SignatureEditEngine.exactJpeg(
      source(),SignatureCrop.full,'Original',4),throwsArgumentError);
  });

  test('Apply Crop commits full-resolution normal crop',() async {
    final applied=await SignatureEditEngine.applyCrop(
      source(),const SignatureCrop(.10,.10,.70,.90));
    final imgResult=img.decodePng(applied)!;
    expect(imgResult.width,inInclusiveRange(200,210));
    expect(imgResult.height,inInclusiveRange(85,90));
    final filtered=await SignatureEditEngine.preview(
      applied,SignatureCrop.full,'Red Ink',intensity:.7);
    expect(img.decodeJpg(filtered),isNotNull);
  });

  test('Perspective Apply Crop returns decodable full-size source',() async {
    final result=await SignatureEditEngine.applyCrop(source(),
      const SignatureCrop(0,0,1,1,
        quad:[.05,.05,.92,.03,.96,.95,.04,.90]));
    final output=img.decodePng(result)!;
    expect(output.width,greaterThan(150));
    expect(output.height,greaterThan(50));
  });

  test('Extra ink filters accept adjustable intensity',() async {
    for(final preset in ['Red Ink','Green Ink','High Contrast',
        'Soft Ink','Sepia','Invert','Clean Paper','Pencil']){
      final result=await SignatureEditEngine.preview(
        source(),SignatureCrop.full,preset,intensity:.45);
      expect(img.decodeJpg(result),isNotNull,reason:preset);
    }
    final neutral=await SignatureEditEngine.preview(
      source(),SignatureCrop.full,'Red Ink',intensity:0);
    final full=await SignatureEditEngine.preview(
      source(),SignatureCrop.full,'Red Ink',intensity:1);
    expect(neutral, isNot(equals(full)));
  });

  Uint8List coloredSignature(){
    final paper=img.Image(width:160,height:112);
    for(var y=0;y<paper.height;y++){
      for(var x=0;x<paper.width;x++){
        final shade=(x~/26+y~/28)%3;
        paper.setPixelRgb(x,y,187+shade*5,199+shade*4,180+shade*5);
      }
    }
    for(var x=19;x<143;x++){
      for(var dy=-2;dy<=2;dy++){
        paper.setPixelRgb(x,35+dy,18,20,25);
        paper.setPixelRgb(x,76+dy,24,55,147);
      }
    }
    return Uint8List.fromList(img.encodePng(paper));
  }

  test('White Background removes tinted paper and preserves black and blue ink',()async{
    final bytes=coloredSignature();
    final result=img.decodeJpg(await SignatureEditEngine.preview(
      bytes,SignatureCrop.full,'White Background',intensity:1))!;
    final clean=result.getPixel(10,12);
    expect(clean.r,greaterThan(243));
    expect(clean.g,greaterThan(243));
    expect(clean.b,greaterThan(243));
    final black=result.getPixel(80,35);
    expect(black.r,lessThan(100));
    expect(black.g,lessThan(100));
    final blue=result.getPixel(80,76);
    expect(blue.b,greaterThan(blue.r+65));
    expect(blue.b,greaterThan(blue.g+40));
  });

  test('White Background intensity zero is original and half is intermediate',()async{
    final bytes=coloredSignature();
    final zero=img.decodeJpg(await SignatureEditEngine.preview(
      bytes,SignatureCrop.full,'White Background',intensity:0))!;
    final half=img.decodeJpg(await SignatureEditEngine.preview(
      bytes,SignatureCrop.full,'White Background',intensity:.5))!;
    final full=img.decodeJpg(await SignatureEditEngine.preview(
      bytes,SignatureCrop.full,'White Background',intensity:1))!;
    expect(zero.getPixel(8,8).r,lessThan(215));
    expect(half.getPixel(8,8).r,greaterThan(zero.getPixel(8,8).r));
    expect(half.getPixel(8,8).r,lessThan(full.getPixel(8,8).r));
  });

  test('White Background works in thumbnails and exact-size JPEG export',()async{
    final source=coloredSignature();
    final thumbs=await SignatureEditEngine.thumbnails(source,
      ['Original','White Background']);
    expect(img.decodeJpg(thumbs['White Background']!),isNotNull);
    final exported=await SignatureEditEngine.exactJpeg(
      source,SignatureCrop.full,'White Background',20,intensity:.85);
    expect(exported.length,20*1024);
    expect(img.decodeJpg(exported),isNotNull);
  });

  test('Rendered signature filter previews are real images',()async{
    const labels=['Original','Black & White','Blue Ink','Red Ink',
      'Sepia','High Contrast'];
    final thumbs=await SignatureEditEngine.thumbnails(source(),labels);
    expect(thumbs.keys.toSet(),labels.toSet());
    for(final label in labels){
      final image=img.decodeJpg(thumbs[label]!);
      expect(image,isNotNull,reason:label);
      expect(image!.width,lessThanOrEqualTo(160));
      expect(image.height,greaterThan(1));
    }
    expect(thumbs['Original'],isNot(equals(thumbs['Black & White'])));
  });

  test('Rotate 90/180 degrees and fine tilt commits real pixels',()async{
    final original=source();
    final right=img.decodePng(await SignatureEditEngine.rotate(original,90))!;
    expect(right.width,110);
    expect(right.height,340);
    final half=img.decodePng(await SignatureEditEngine.rotate(original,180))!;
    expect(half.width,340);
    expect(half.height,110);
    final tilted=img.decodePng(await SignatureEditEngine.rotate(original,12.5))!;
    expect(tilted.width,greaterThan(340));
    expect(tilted.height,greaterThan(110));
    final exported=await SignatureEditEngine.exactJpeg(
      Uint8List.fromList(img.encodePng(right)),
      SignatureCrop.full,'Original',20);
    expect(exported.length,20*1024);
  });

}
