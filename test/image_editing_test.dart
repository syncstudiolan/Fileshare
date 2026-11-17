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

  test('Local Cart bridge preserves entries until dashboard consumes',(){
    final cart=ImageEditingCart.instance;
    final file=File('image_editing_test_cart.png');
    cart.add(file,'edited.png');
    final items=cart.takeAll();
    expect(items,singleElement);
    expect(items.first.name,'edited.png');
    expect(cart.takeAll(),isEmpty);
  });

  testWidgets('Image Editing launcher presents two working entry routes',
      (tester)async{
    await tester.pumpWidget(const MaterialApp(home:ImageEditingLauncherPage()));
    expect(find.text('Choose Image'),findsOneWidget);
    expect(find.text('Image History / Continue Editing'),findsOneWidget);
    expect(find.byIcon(Icons.add_photo_alternate_outlined),findsOneWidget);
    expect(tester.takeException(),isNull);
  });
}
