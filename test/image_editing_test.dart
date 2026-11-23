import 'dart:io';
import 'dart:typed_data';

import 'package:file_share/image_editing_engine.dart';
import 'package:file_share/image_editing_page.dart';
import 'package:file_share/image_editing_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main(){
  Uint8List example(){
    final source=img.Image(width:80,height:50,numChannels:4);
    for(var y=0;y<50;y++){
      for(var x=0;x<80;x++){
        source.setPixelRgba(x,y,25+x*2,60+y*2,140,255);
      }
    }
    return Uint8List.fromList(img.encodePng(source));
  }

  test('Image Editing actual crop keeps chosen region',()async{
    final bytes=await ImageEditingEngine.edit(example(),'crop',{
      'x':.25,'y':.2,'w':.5,'h':.6,
    });
    final image=img.decodeImage(bytes)!;
    expect(image.width,40);
    expect(image.height,30);
  });

  test('Four-corner perspective crop produces a real rectified image',()async{
    final bytes=await ImageEditingEngine.edit(example(),'perspective',{
      'tlx':.10,'tly':.08,
      'trx':.90,'try':.14,
      'brx':.84,'bry':.92,
      'blx':.04,'bly':.82,
    });
    final corrected=img.decodeImage(bytes)!;
    expect(corrected.width,greaterThan(40));
    expect(corrected.width,lessThan(80));
    expect(corrected.height,greaterThan(20));
    expect(corrected.height,lessThan(50));
  });

  test('Background mask removes pixels without losing subject',()async{
    final original=example();
    final mask=Uint8List.fromList(List<int>.generate(80*50,
      (index)=>index%80<30?0:255));
    final result=img.decodeImage(await ImageEditingEngine.edit(
      original,'background',{'mask':mask,'maskWidth':80,'maskHeight':50}))!;
    expect(result.getPixel(5,5).a,0);
    expect(result.getPixel(55,5).a,255);
  });

  test('Manual brush stroke erases multiple points',()async{
    final result=img.decodeImage(await ImageEditingEngine.edit(example(),
      'erase',{'radius':.10,'softness':1.0,'points':[
        {'x':.2,'y':.2},{'x':.8,'y':.8},
      ]}))!;
    expect(result.getPixel(16,10).a,0);
    expect(result.getPixel(64,40).a,0);
  });

  test('Compression outputs real JPEG data and handles target size',()async{
    final result=await ImageEditingEngine.compress(example(),
      targetKb:5,quality:85,format:'JPEG');
    expect(result[0],0xff);
    expect(result[1],0xd8);
    expect(img.decodeImage(result),isNotNull);
  });

  test('Requested JPEG output never exceeds 5KB and stays readable',()async{
    final edited=await ImageEditingEngine.edit(example(),'filter',{'name':'Warm'});
    final result=await ImageEditingEngine.compress(edited,
      targetKb:5,quality:85,format:'JPEG');
    expect(result.length,lessThanOrEqualTo(5*1024));
    final image=img.decodeJpg(result);
    expect(image,isNotNull);
    expect(image!.width,greaterThan(0));
  });

  test('Small target JPEG keeps maximum resolution when it already fits',()async{
    final input=example();
    final result=await ImageEditingEngine.compress(input,
      targetKb:20,quality:92,format:'JPEG');
    final decoded=img.decodeJpg(result)!;
    expect(result.length,lessThanOrEqualTo(20*1024));
    expect(decoded.width,80);
    expect(decoded.height,50);
  });

  test('Compression uses current edited cutout and flattens JPEG on white',()async{
    final mask=Uint8List.fromList(List<int>.generate(80*50,
      (index)=>index%80<40?0:255));
    final cutout=await ImageEditingEngine.edit(example(),'background',{
      'mask':mask,'maskWidth':80,'maskHeight':50,
    });
    final jpeg=await ImageEditingEngine.compress(cutout,
      targetKb:5,quality:90,format:'JPEG');
    final decoded=img.decodeJpg(jpeg)!;
    expect(decoded.getPixel(2,2).r,greaterThan(225));
    expect(decoded.getPixel(2,2).g,greaterThan(225));
    expect(decoded.getPixel(70,30).b,lessThan(230));
  });

  test('Small segmentation images are encoded without changing coordinates',()async{
    final bounded=await ImageEditingEngine.segmentationInput(example());
    final decoded=img.decodeJpg(bounded)!;
    expect(decoded.width,80);
    expect(decoded.height,50);
  });

  test('Local Cart bridge preserves entries until dashboard consumes',(){
    final cart=ImageEditingCart.instance;
    final file=File('image_editing_test_cart.png');
    cart.add(file,'edited.png');
    final items=cart.takeAll();
    expect(items,hasLength(1));
    expect(items.first.name,'edited.png');
    expect(cart.takeAll(),isEmpty);
  });

  test('Before/After clip tracks drag position exactly',(){
    const size=Size(400,300);
    final middle=const PhotoBeforeAfterClipper(.5).getClip(size);
    expect(middle,const Rect.fromLTWH(0,0,200,300));
    expect(const PhotoBeforeAfterClipper(0).getClip(size),
      const Rect.fromLTWH(0,0,0,300));
    expect(const PhotoBeforeAfterClipper(1).getClip(size),
      const Rect.fromLTWH(0,0,400,300));
    expect(const PhotoBeforeAfterClipper(.75).shouldReclip(
      const PhotoBeforeAfterClipper(.25)),isTrue);
    expect(const PhotoBeforeAfterClipper(.75).shouldReclip(
      const PhotoBeforeAfterClipper(.75)),isFalse);
  });

  testWidgets('Image Editing launcher presents two working entry routes',
      (tester)async{
    await tester.pumpWidget(const MaterialApp(home:ImageEditingLauncherPage()));
    expect(find.text('Choose Image'),findsOneWidget);
    expect(find.text('Image History / Continue Editing'),findsOneWidget);
    expect(find.byIcon(Icons.add_photo_alternate_outlined),findsOneWidget);
    expect(tester.takeException(),isNull);
  }); 
  test('Small JPEG targets prioritize a useful quality floor',()async{
    final source=img.Image(width:720,height:960);
    for(var y=0;y<source.height;y++){
      for(var x=0;x<source.width;x++){
        final base=(x*7+y*13+(x*y)%137)%256;
        source.setPixelRgb(x,y,base,(base+50)%256,(base+110)%256);
      }
    }
    final encoded=Uint8List.fromList(img.encodeJpg(source,quality:93));
    final result=await ImageEditingEngine.compress(encoded,
      targetKb:20,quality:90,format:'JPEG');
    expect(result.length,lessThanOrEqualTo(20*1024));
    final decoded=img.decodeJpg(result)!;
    expect(decoded.width,greaterThan(32));
    expect(decoded.height,greaterThan(32));
  });

  test('Enhance-ready cutout keeps transparency through PNG compression',()async{
    final mask=Uint8List.fromList(List<int>.generate(80*50,
      (index)=>index%80<40?0:255));
    final cutout=await ImageEditingEngine.edit(example(),'background',{
      'mask':mask,'maskWidth':80,'maskHeight':50,
    });
    final adjusted=await ImageEditingEngine.edit(cutout,'adjust',{
      'brightness':1.05,'contrast':1.1,
    });
    final png=await ImageEditingEngine.compress(adjusted,
      targetKb:100,format:'PNG');
    final image=img.decodeImage(png)!;
    expect(image.getPixel(2,2).a,0);
    expect(image.getPixel(70,30).a,255);
  });

}
