import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// GFPGAN v1.4 ONNX face restoration. For explicit face crops only.
/// This is NOT a face detector or face-swapper; in particular no facial
/// landmarks/alignment are inferred by this module.
class FaceRestorationEngine {
  static const modelUrl =
    'https://huggingface.co/sidkonduru/gfpgan-v1.4-onnx/resolve/3777aaa/gfpgan14-fp16.onnx';
  static const modelSha256 =
    '6b12e9428c2a0983b2726604f09c4eec9e2e250370c79946a31b139f9befc1ea';
  static const side=512;

  static Future<File> _ensureModel() async {
    if(!Platform.isAndroid&&!Platform.isWindows){
      throw UnsupportedError('GFPGAN requires Android or Windows');
    }
    final root=await getApplicationSupportDirectory();
    final directory=Directory('${root.path}${Platform.pathSeparator}image_editing_models');
    await directory.create(recursive:true);
    final file=File('${directory.path}${Platform.pathSeparator}gfpgan14_fp16.onnx');
    Future<bool> verified(File item) async {
      if(!await item.exists())return false;
      final size=await item.length();
      if(size<160000000 || size>185000000)return false;
      final digest=await sha256.bind(item.openRead()).first;
      return digest.toString()==modelSha256;
    }
    if(await verified(file))return file;
    if(await file.exists())await file.delete();
    final partial=File('${file.path}.part');
    if(await partial.exists())await partial.delete();
    final client=HttpClient()..connectionTimeout=const Duration(seconds:25);
    try {
      final request=await client.getUrl(Uri.parse(modelUrl));
      final response=await request.close().timeout(const Duration(minutes:3));
      if(response.statusCode!=200){
        throw HttpException('GFPGAN model HTTP ${response.statusCode}');
      }
      if(response.contentLength>185000000){
        throw StateError('Unexpected GFPGAN model size');
      }
      var total=0;
      final sink=partial.openWrite();
      try {
        await for(final bytes in response) {
          total+=bytes.length;
          if(total>185000000)throw StateError('GFPGAN model exceeds limit');
          sink.add(bytes);
        }
        await sink.flush();
      }finally{await sink.close();}
      if(!await verified(partial)){
        throw const FormatException('GFPGAN model integrity check failed');
      }
      await partial.rename(file.path);
      return file;
    }finally {
      client.close(force:true);
      if(await partial.exists())await partial.delete();
    }
  }

  /// The caller selects a roughly front-facing, square face crop via Crop.
  /// An unaligned face can be distorted by GFPGAN: no automatic identity
  /// preservation is claimed. All original pixels outside ROI remain intact.
  static Future<Uint8List> restore(Uint8List source,{
    required List<double> normalizedRoi,
    double strength=.65,
  }) async {
    if(normalizedRoi.length!=4)throw ArgumentError('Expected face region');
    final image=img.decodeImage(source);
    if(image==null)throw const FormatException('Unsupported image');
    final left=(normalizedRoi[0]*image.width).round().clamp(0,image.width-1);
    final top=(normalizedRoi[1]*image.height).round().clamp(0,image.height-1);
    final right=(normalizedRoi[2]*image.width).round().clamp(left+1,image.width);
    final bottom=(normalizedRoi[3]*image.height).round().clamp(top+1,image.height);
    final w=right-left,h=bottom-top;
    if(w<40||h<40)throw StateError('Selected face region is too small');
    final crop=img.copyCrop(image,x:left,y:top,width:w,height:h);
    final prepared=img.copyResize(crop,width:side,height:side,
      interpolation:img.Interpolation.cubic);
    final tensor=Float32List(3*side*side);
    const area=side*side;
    for(var y=0;y<side;y++)for(var x=0;x<side;x++){
      final p=prepared.getPixel(x,y),i=y*side+x;
      tensor[i]=p.r/127.5-1;
      tensor[area+i]=p.g/127.5-1;
      tensor[area*2+i]=p.b/127.5-1;
    }
    final model=await _ensureModel();
    final runtime=OnnxRuntime();
    final session=await runtime.createSession(model.path,
      options:OrtSessionOptions(intraOpNumThreads:2,interOpNumThreads:1,
        providers:[OrtProvider.CPU]));
    OrtValue? input;
    try{
      input=await OrtValue.fromList(tensor,[1,3,side,side]);
      final outputs=await session.run({session.inputNames.first:input});
      try{
        final result=await outputs[session.outputNames.first]!.asFlattenedList();
        if(result.length<area*3)throw StateError('Invalid GFPGAN output shape');
        final restored=img.Image(width:side,height:side,numChannels:3);
        for(var y=0;y<side;y++)for(var x=0;x<side;x++){
          final i=y*side+x;
          int c(int offset)=>((((result[offset+i] as num).toDouble()+1)
            *127.5).round()).clamp(0,255).toInt();
          restored.setPixelRgb(x,y,c(0),c(area),c(area*2));
        }
        final scaled=img.copyResize(restored,width:w,height:h,
          interpolation:img.Interpolation.cubic);
        final amount=strength.clamp(0.0,1.0);
        // Feather the pasted face boundary instead of producing a hard box.
        for(var y=0;y<h;y++)for(var x=0;x<w;x++){
          final distance=math.min(math.min(x,w-1-x),math.min(y,h-1-y));
          final feather=(distance/(math.min(w,h)*.08))
            .clamp(0.0,1.0);
          final alpha=amount*feather;
          final a=image.getPixel(left+x,top+y);
          final b=scaled.getPixel(x,y);
          int mix(num oldValue,num newValue)=>
            (oldValue+(newValue-oldValue)*alpha).round().clamp(0,255).toInt();
          image.setPixelRgba(left+x,top+y,mix(a.r,b.r),
            mix(a.g,b.g),mix(a.b,b.b),a.a.toInt());
        }
        return Uint8List.fromList(img.encodePng(image,level:1));
      }finally {
        for(final output in outputs.values){await output.dispose();}
      }
    }finally{
      if(input!=null)await input.dispose();
      await session.close();
    }
  }
}
