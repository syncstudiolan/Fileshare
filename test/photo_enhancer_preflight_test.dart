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
}
