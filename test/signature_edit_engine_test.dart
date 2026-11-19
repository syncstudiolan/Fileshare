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

}
