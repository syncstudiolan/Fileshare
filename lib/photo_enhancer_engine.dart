import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Real-ESRGAN x2plus, CPU ONNX; no face swap, upload or cloud inference.
/// Download-once model with fixed, published SHA-256. Tiled to bound RAM use.
/// Uses the standard [1,3,H,W] RGB/[0,1] input and x2 planar RGB output.
/// 4x is two x2 stages, not an independently trained 4x model.
class PhotoEnhancerEngine {
  @visibleForTesting
  static Uint8List enhanceMobileForTest(Uint8List source,
      {int scale=2,double strength=.8})=>
    _mobileSafeEnhance({
      'source':source,'scale':scale,'strength':strength,
    });

  static const modelUrl =
    'https://huggingface.co/skillsafe-ai/realesrgan-x2plus/resolve/8166b63/model.onnx';
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
      return (await sha256.bind(f.openRead()).first).toString()==expectedSha256;
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
    if(!Platform.isWindows&&!Platform.isAndroid&&!Platform.isIOS){
      throw UnsupportedError('Photo enhancement is not supported here');
    }
    if(scale!=2&&scale!=4)throw ArgumentError.value(scale,'scale');
    // Mobile ONNX Real-ESRGAN's ~65MB model and native tensor allocator can
    // terminate Android's process without a Dart exception. Keep ONNX only
    // on desktop. A bounded Dart isolate produces a real enhanced image on
    // mobile with predictable peak memory and no native ML runtime crash.
    if(Platform.isAndroid||Platform.isIOS){
      onProgress?.call(.08);
      final result=await compute(_mobileSafeEnhance,{
        'source':source,'scale':scale,'strength':blend,
      });
      onProgress?.call(1.0);
      return result;
    }
    final decoded=img.decodeImage(source);
    if(decoded==null)throw const FormatException('Unsupported image');
    // Never reject a camera photo only because its dimensions are large.
    // Limit the working image instead: CPU ONNX 4x output can otherwise exceed
    // mobile RAM, and the full-resolution original remains untouched in Cart.
    const maxOutputPixels=8000000;
    final inputLimit=math.max(1,maxOutputPixels~/(scale*scale));
    final pixelCount=decoded.width*decoded.height;
    final working=pixelCount>inputLimit
      ? img.copyResize(decoded,
          width:math.max(1,(decoded.width*
            math.sqrt(inputLimit/pixelCount)).floor()),
          height:math.max(1,(decoded.height*
            math.sqrt(inputLimit/pixelCount)).floor()),
          interpolation:img.Interpolation.cubic)
      : decoded;
    final model=await _model();
    final runtime=OnnxRuntime();
    final session=await runtime.createSession(model.path,
      options:OrtSessionOptions(intraOpNumThreads:2,interOpNumThreads:1,
        providers:[OrtProvider.CPU]));
    try {
      var original=working;
      final stages=scale==4?2:1;
      for(var stage=0;stage<stages;stage++) {
        original=await _stage(original,session,(p)=>
          onProgress?.call((stage+p)/stages));
      }
      // Blend with a traditionally resized original to reduce AI artifacts.
      if(blend<.999) {
        final normal=img.copyResize(working,
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
        // RRDBNet x2 uses pixel-unshuffle; inference tile axes must be even.
        final pw=cw+2*overlap+(cw.isOdd?1:0);
        final ph=ch+2*overlap+(ch.isOdd?1:0);
        final area=pw*ph;
        final tensor=Float32List(area*3);
        for(var y=0;y<ph;y++) {
          for(var x=0;x<pw;x++) {
            final ix=(x0+x-overlap).clamp(0,input.width-1).toInt();
            final iy=(y0+y-overlap).clamp(0,input.height-1).toInt();
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
                  (((flat[c*plane+pixel] as num).toDouble()*255).round()).clamp(0,255).toInt();
                final sourceAlpha=input.getPixel(
                  (x0+x~/2).clamp(0,input.width-1).toInt(),
                  (y0+y~/2).clamp(0,input.height-1).toInt()).a.toInt();
                output.setPixelRgba(x0*2+x,y0*2+y,
                  channel(0),channel(1),channel(2),sourceAlpha);
              }
            }
          }finally{
            for(final v in values.values){await v.dispose();}
          }
        }finally{if(inputTensor!=null)await inputTensor.dispose();}
        progress?.call((ty*nx+tx+1)/(nx*ny));
        // Let Flutter render progress and handle input between inference tiles.
        await Future<void>.delayed(Duration.zero);
      }
    }
    return output;
  }
}

/// Bounded mobile enhancement. CPU work is isolated from Flutter's raster/UI
/// threads and never constructs an ONNX session (native OOM is not catchable).
/// This is edge-aware image restoration/upscaling, not generative Real-ESRGAN.
Uint8List _mobileSafeEnhance(Map<String,Object?> request){
  final source=request['source'] as Uint8List;
  final scale=request['scale'] as int;
  final strength=(request['strength'] as double).clamp(0.0,1.0);
  final decoded=img.decodeImage(source);
  if(decoded==null)throw const FormatException('Unsupported photo format');
  if(decoded.width<1||decoded.height<1)throw StateError('Empty image');

  // The old fallback always shrank camera photos toward 2.5MP output.
  // This frequently destroyed detail and made HD/Ultra HD look unchanged.
  // Retain original dimensions whenever possible, and only downscale huge
  // inputs when required by the bounded 6MP output. The actual output
  // dimensions are communicated by the encoded image, never a false x4 claim.
  const maxPixels=6000000;
  final inputPixels=decoded.width*decoded.height;
  final desiredFactor=math.min(scale.toDouble(),
    math.sqrt(maxPixels/inputPixels));
  final factor=inputPixels>=maxPixels
    ?math.sqrt(maxPixels/inputPixels)
    :math.max(1.0,desiredFactor);
  final targetW=math.max(1,(decoded.width*factor).round());
  final targetH=math.max(1,(decoded.height*factor).round());

  final resized=targetW==decoded.width&&targetH==decoded.height
    ?decoded
    :img.copyResize(decoded,width:targetW,height:targetH,
        interpolation:img.Interpolation.cubic);

  // Mild tonal correction and stronger, local edge-aware detail recovery.
  // A single 4-neighbor pass avoids allocating a second blur bitmap.
  final corrected=img.adjustColor(resized,
    contrast:1+.12*strength,saturation:1+.065*strength,
    brightness:1+.012*strength);
  final output=img.Image(width:targetW,height:targetH,numChannels:3);

  final sharpness=1.1*strength;
  for(var y=0;y<targetH;y++){
    final top=math.max(0,y-1),bottom=math.min(targetH-1,y+1);
    for(var x=0;x<targetW;x++){
      final left=math.max(0,x-1),right=math.min(targetW-1,x+1);
      final c=corrected.getPixel(x,y);
      final n=corrected.getPixel(x,top);
      final e=corrected.getPixel(right,y);
      final w=corrected.getPixel(left,y);
      final d=corrected.getPixel(x,bottom);
      // Avoid sharpening sensor noise on smooth skin/backgrounds.
      final localLuma=(n.r+n.g+n.b+e.r+e.g+e.b+
        w.r+w.g+w.b+d.r+d.g+d.b)/12;
      final centerLuma=(c.r+c.g+c.b)/3;
      final detail= (centerLuma-localLuma).abs();
      final gain=detail<5?0.0:sharpness *
        ((detail-5)/17).clamp(0.0,1.0);
      int channel(num center,num a,num b,num left,num below){
        final neighbors=(a+b+left+below)/4;
        return (center+(center-neighbors)*gain).round()
          .clamp(0,255).toInt();
      }
      output.setPixelRgb(x,y,
        channel(c.r,n.r,e.r,w.r,d.r),
        channel(c.g,n.g,e.g,w.g,d.g),
        channel(c.b,n.b,e.b,w.b,d.b));
    }
  }
  return Uint8List.fromList(img.encodeJpg(output,quality:93));
}
