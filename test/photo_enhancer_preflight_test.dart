import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:file_share/face_restoration_engine.dart';
import 'package:file_share/photo_enhancer_engine.dart';

void main() {
  group('Photo enhancement preflight', () {
    test('real ONNX model hashes are configured', () {
      expect(PhotoEnhancerEngine.expectedSha256,
        matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(FaceRestorationEngine.modelSha256,
        matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('an invalid face ROI is rejected before model download', () async {
      final photo=image.Image(width:128,height:128);
      final source=Uint8List.fromList(image.encodePng(photo));
      await expectLater(
        FaceRestorationEngine.restore(source,normalizedRoi:[.1,.2,.3]),
        throwsArgumentError);
    });

    test('a tiny face selection is rejected before model download', () async {
      final photo=image.Image(width:128,height:128);
      final source=Uint8List.fromList(image.encodePng(photo));
      await expectLater(
        FaceRestorationEngine.restore(source,
          normalizedRoi:[.45,.45,.50,.50]),
        throwsStateError);
    });

    test('corrupt input fails before model creation', () async {
      await expectLater(
        FaceRestorationEngine.restore(Uint8List.fromList([1,2,3]),
          normalizedRoi:[0,0,1,1]),
        throwsFormatException);
    });
  });
  group('Mobile enhancement quality and memory caps',(){
    Uint8List sample(){
      final photo=image.Image(width:160,height:120);
      for(var y=0;y<120;y++){
        for(var x=0;x<160;x++){
          final edge=x<80?35:205;
          final variation=(x*7+y*3)%13;
          photo.setPixelRgb(x,y,edge,80+variation,50+variation);
        }
      }
      return Uint8List.fromList(image.encodePng(photo));
    }

    test('HD creates larger, visibly processed image',(){
      final source=sample();
      final enhanced=PhotoEnhancerEngine.enhanceMobileForTest(
        source,scale:2,strength:.9);
      final after=image.decodePng(enhanced)!;
      final before=image.decodePng(source)!;
      expect(after.width,320);
      expect(after.height,240);
      expect(after.getPixel(70,60).r, isNot(equals(before.getPixel(35,30).r)));
    });

    test('Ultra HD creates bounded larger output',(){
      final result=PhotoEnhancerEngine.enhanceMobileForTest(
        sample(),scale:4,strength:.8);
      final output=image.decodePng(result)!;
      expect(output.width,640);
      expect(output.height,480);
    });

    test('Invalid source fails rather than pretending enhancement',(){
      expect(()=>PhotoEnhancerEngine.enhanceMobileForTest(
        Uint8List.fromList([1,2,3])),throwsFormatException);
    });
  });

}
