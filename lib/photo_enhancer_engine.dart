import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Real-ESRGAN x2plus, CPU ONNX; no face swap, upload or cloud inference.
/// Download-once model with fixed, published SHA-256. Tiled to bound RAM use.
/// Uses the standard [1,3,H,W] RGB/[0,1] input and x2 planar RGB output.
/// 4x is two x2 stages, not an independently trained 4x model.
class PhotoEnhancerEngine {
  static const modelUrl =
    'https://huggingface.co/skillsafe-ai/realesrgan-x2plus/resolve/main/model.onnx';
  static const expectedSha256 =
    '7eb5e9eb507df603c0c04b49b23c86a362e0a01575bfbbac891d970f9c331888';

  static Future<File> _model() async {
    final root=await getApplicationSupportDirectory();
    final dir=Directory('${root.path}${Platform.pathSeparator}image_editing_models');
    await dir.create(recursive:true);
    final file=File('${dir.path}${Platform.pathSeparator}realesrgan_x2plus.onnx');
    Future<bool> valid(File f) async {
      if(!await f.exists())return false;
      if(await f.length()<60000000 || await f.length()>75000000)return false;
      return sha256.convert(await f.readAsBytes()).toString()==expectedSha256;
    }
    if(await valid(file))return file;
    final partial=File('${file.path}.part');
    if(await partial.exists())await partial.delete();
    final client=HttpClient()..connectionTimeout=const Duration(seconds:20);
    try {
      final request=await client.getUrl(Uri.parse(modelUrl));
      final response=await request.close().timeout(const Duration(minutes:2));
      if(response.statusCode!=200)throw HttpException('Model download HTTP ${response.statusCode}');
      if(response.contentLength>75000000)throw StateError('Invalid model size');
      // Stream the large model without retaining network data in memory.
      await response.pipe(partial.openWrite());
      if(!await valid(partial))throw const FormatException('Model SHA-256 mismatch');
      if(await file.exists())await file.delete();
      await partial.rename(file.path);
      return file;
    }finally{
      client.close(force:true);
      if(await partial.exists())await partial.delete();
    }
  }

  static Future<Uint8List> enhance(
    Uint8List source, {int scale=2, double blend=1,
      void Function(double)? onProgress}) async {
    if(!Platform.isWindows&&!Platform.isAndroid){
      throw UnsupportedError('AI Photo Enhancer is supported on Android/Windows');
    }
    if(scale!=2&&scale!=4)throw ArgumentError.value(scale,'scale');
    final decoded=img.decodeImage(source);
    if(decoded==null)throw const FormatException('Unsupported image');
    if(decoded.width*decoded.height>8000000){
      throw StateError('Image too large for this device-safe AI pass (max 8 MP)');
    }
    final model=await _model();
    final runtime=OnnxRuntime();
    final session=await runtime.createSession(model.path,
      options:OrtSessionOptions(intraOpNumThreads:2,interOpNumThreads:1,
        providers:[OrtProvider.CPU]));
    try {
      var original=decoded;
      final stages=scale==4?2:1;
      for(var stage=0;stage<stages;stage++) {
        if(original.width*original.height>8000000){
          throw StateError('4x output exceeds device-safe processing limit');
        }
        original=await _stage(original,session,(p)=>
          onProgress?.call((stage+p)/stages));
      }
      // Blend with a traditionally resized original to reduce AI artifacts.
      if(blend<.999) {
        final normal=img.copyResize(decoded,
          width:original.width,height:original.height,
          interpolation:img.Interpolation.cubic);
        final amount=blend.clamp(0.0,1.0);
        for(var y=0;y<original.height;y++){
          for(var x=0;x<original.width;x++){
            final a=original.getPixel(x,y),b=normal.getPixel(x,y);
            original.setPixelRgba(x,y,
              (b.r+(a.r-b.r)*amount).round().clamp(0,255),
              (b.g+(a.g-b.g)*amount).round().clamp(0,255),
              (b.b+(a.b-b.b)*amount).round().clamp(0,255),
              (b.a+(a.a-b.a)*amount).round().clamp(0,255));
          }
        }
      }
      return Uint8List.fromList(img.encodePng(original,level:1));
    }finally{await session.close();}
  }

  static Future<img.Image> _stage(
    img.Image input,OrtSession session,void Function(double)? progress) async {
    final output=img.Image(width:input.width*2,height:input.height*2,numChannels:4);
    const core=64, overlap=10;
    final nx=(input.width+core-1)~/core,ny=(input.height+core-1)~/core;
    for(var ty=0;ty<ny;ty++){
      for(var tx=0;tx<nx;tx++){
        final x0=tx*core,y0=ty*core;
        final cw=math.min(core,input.width-x0);
        final ch=math.min(core,input.height-y0);
        final pw=cw+2*overlap,ph=ch+2*overlap,area=pw*ph;
        final tensor=Float32List(area*3);
        for(var y=0;y<ph;y++) {
          for(var x=0;x<pw;x++) {
            final ix=(x0+x-overlap).clamp(0,input.width-1);
            final iy=(y0+y-overlap).clamp(0,input.height-1);
            final p=input.getPixel(ix,iy), idx=y*pw+x;
            tensor[idx]=p.r/255;
            tensor[area+idx]=p.g/255;
            tensor[2*area+idx]=p.b/255;
          }
        }
        OrtValue? inputTensor;
        try {
          inputTensor=await OrtValue.fromList(tensor,[1,3,ph,pw]);
          final values=await session.run({session.inputNames.first:inputTensor});
          try{
            final flat=await values[session.outputNames.first]!.asFlattenedList();
            final w=pw*2,h=ph*2,plane=w*h;
            if(flat.length<plane*3)throw StateError('Unexpected Real-ESRGAN model output');
            for(var y=0;y<ch*2;y++){
              for(var x=0;x<cw*2;x++){
                final pixel=(y+overlap*2)*w+(x+overlap*2);
                int channel(int c)=>
                  (((flat[c*plane+pixel] as num).toDouble()*255).round()).clamp(0,255);
                final sourceAlpha=input.getPixel(
                  (x0+x~/2).clamp(0,input.width-1),
                  (y0+y~/2).clamp(0,input.height-1)).a.toInt();
                output.setPixelRgba(x0*2+x,y0*2+y,
                  channel(0),channel(1),channel(2),sourceAlpha);
              }
            }
          }finally{
            for(final v in values.values){await v.dispose();}
          }
        }finally{if(inputTensor!=null)await inputTensor.dispose();}
        progress?.call((ty*nx+tx+1)/(nx*ny));
      }
    }
    return output;
  }
}
