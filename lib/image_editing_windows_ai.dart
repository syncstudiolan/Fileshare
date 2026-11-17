import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Portable U²-NetP subject segmentation for Windows; unlike ML Kit it is
/// not Android-only. A one-time 4.6 MB model download is verified by SHA256
/// before it is loaded, then all inference is on the user's local device.
class WindowsBackgroundAi {
  static const modelUrl=
    'https://huggingface.co/edgetools/u2netp/resolve/main/u2netp.onnx';
  static const digest=
    '309c8469258dda742793dce0ebea8e6dd393174f89934733ecc8b14c76f4ddd8';
  static const modelSize=320;

  static Future<File> _ensureModel() async {
    final root=await getApplicationSupportDirectory();
    final folder=Directory('${root.path}${Platform.pathSeparator}image_editing_models');
    await folder.create(recursive:true);
    final file=File('${folder.path}${Platform.pathSeparator}u2netp.onnx');
    Future<bool> verified()async {
      if(!await file.exists())return false;
      if(await file.length()<1000000 || await file.length()>7000000)return false;
      return sha256.convert(await file.readAsBytes()).toString()==digest;
    }
    if(await verified())return file;
    if(await file.exists())await file.delete();
    final temporary=File('${file.path}.part');
    final client=HttpClient()..connectionTimeout=const Duration(seconds:20);
    try{
      final request=await client.getUrl(Uri.parse(modelUrl));
      final response=await request.close().timeout(const Duration(seconds:45));
      if(response.statusCode!=200)throw HttpException(
        'AI model download HTTP ${response.statusCode}');
      if(response.contentLength>7000000)throw StateError('Unexpected AI model size');
      await response.pipe(temporary.openWrite());
      if(await temporary.length()>7000000)throw StateError('Invalid model download');
      await temporary.rename(file.path);
      if(!await verified()){
        await file.delete();
        throw const FormatException('AI model integrity check failed');
      }
      return file;
    }catch(_){
      if(await temporary.exists())await temporary.delete();
      rethrow;
    }finally{client.close(force:true);}
  }

  static Future<Uint8List> segmentationMask(Uint8List sourceBytes)async{
    if(!Platform.isWindows)throw UnsupportedError('Windows segmentation only');
    final decoded=img.decodeImage(sourceBytes);
    if(decoded==null)throw const FormatException('Unsupported image format');
    final resized=img.copyResize(decoded,width:modelSize,height:modelSize);
    const area=modelSize*modelSize;
    final planar=Float32List(area*3);
    const means=[.485,.456,.406], std=[.229,.224,.225];
    for(var y=0;y<modelSize;y++){
      for(var x=0;x<modelSize;x++){
        final p=resized.getPixel(x,y);
        final position=y*modelSize+x;
        planar[position]=((p.r/255)-means[0])/std[0];
        planar[area+position]=((p.g/255)-means[1])/std[1];
        planar[2*area+position]=((p.b/255)-means[2])/std[2];
      }
    }
    final path=await _ensureModel();
    final runtime=OnnxRuntime();
    final session=await runtime.createSession(path.path,
      options:OrtSessionOptions(intraOpNumThreads:2,interOpNumThreads:1,
        providers:[OrtProvider.CPU]));
    OrtValue? input;
    try{
      input=await OrtValue.fromList(planar,[1,3,modelSize,modelSize]);
      final outputs=await session.run({session.inputNames.first:input});
      try{
        final result=await outputs[session.outputNames.first]!.asFlattenedList();
        if(result.length<area)throw StateError('AI mask has invalid shape');
        // U²-Net model outputs raw foreground scores. Normalize to display
        // range; original channels will be retained beneath this alpha mask.
        var lower=double.infinity,upper=-double.infinity;
        for(var i=0;i<area;i++){
          final v=(result[i] as num).toDouble();
          if(v<lower)lower=v;
          if(v>upper)upper=v;
        }
        final span=(upper-lower).abs();
        final mask=Uint8List(area);
        for(var i=0;i<area;i++){
          final v=(result[i] as num).toDouble();
          mask[i]=span>1e-6
            ?(((v-lower)/span).clamp(0.0,1.0)*255).round()
            :(v.clamp(0.0,1.0)*255).round();
        }
        return mask;
      }finally{
        for(final output in outputs.values){await output.dispose();}
      }
    }finally{
      if(input!=null)await input.dispose();
      await session.close();
    }
  }
}
