import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Normalized signature crop. The source file is never overwritten.
class SignatureCrop {
  const SignatureCrop(this.left,this.top,this.right,this.bottom);
  final double left,top,right,bottom;
  static const full=SignatureCrop(0,0,1,1);
}

/// Only the requested signature operations, without Image Editor's
/// background-removal and unrelated photo tools.
class SignatureEditEngine {
  static Future<Uint8List> preview(Uint8List original,SignatureCrop crop,
    String filter) => compute(_signatureTransform, {
      'bytes':original,'crop':[crop.left,crop.top,crop.right,crop.bottom],
      'filter':filter,'preview':true,
    });

  static Future<Uint8List> exactJpeg(Uint8List original,SignatureCrop crop,
    String filter,int kilobytes) {
    if(kilobytes<1||kilobytes>10240) {
      throw ArgumentError('Target must be between 1 and 10,240 KB');
    }
    return compute(_signatureTransform,{
      'bytes':original,'crop':[crop.left,crop.top,crop.right,crop.bottom],
      'filter':filter,'preview':false,'target':kilobytes*1024,
    });
  }

  /// JPEG comments are standards-compliant and do not alter image pixels.
  /// This guarantees exactly N * 1024 bytes IF the actual compressed signature
  /// can fit in that target. Otherwise we throw; never silently make 19/21 KB.
  @visibleForTesting
  static Uint8List padJpegToExactSize(Uint8List jpeg,int target) {
    if(jpeg.length>target) {
      throw StateError('Image cannot fit into the requested target');
    }
    if(jpeg.length<4 || jpeg[0]!=0xff || jpeg[1]!=0xd8 ||
      jpeg[jpeg.length-2]!=0xff || jpeg.last!=0xd9) {
      throw FormatException('Expected an intact JPEG');
    }
    final remaining=target-jpeg.length;
    if(remaining==0)return jpeg;
    if(remaining<4) {
      throw StateError('Not enough room for a valid JPEG comment segment');
    }
    final output=BytesBuilder(copy:false)..add(jpeg.sublist(0,2));
    var left=remaining;
    while(left>0) {
      // 4 bytes for marker and length; max 65533 bytes of payload.
      // Avoid leaving a final remainder of 1..3 bytes.
      var chunk=math.min(left,65537);
      if(left-chunk>0 && left-chunk<4) chunk=left-4;
      if(chunk<4)throw StateError('Invalid JPEG padding segment');
      final payload=chunk-4;
      final length=payload+2;
      output.add([0xff,0xfe,(length>>8)&255,length&255]);
      output.add(Uint8List(payload));
      left-=chunk;
    }
    output.add(jpeg.sublist(2));
    final bytes=output.takeBytes();
    if(bytes.length!=target)throw StateError('Exact target encoding failed');
    return bytes;
  }
}

/// Isolate entrypoint: filters, crop and JPEG encoding off the UI thread.
/// JPEG is chosen to support reliable quality/size control. A target which
/// cannot retain a minimally legible image yields a validation error.
Uint8List _signatureTransform(Map<String,dynamic> request) {
  final original=request['bytes'] as Uint8List;
  final decoded=img.decodeImage(original);
  if(decoded==null)throw const FormatException('Unsupported image format');
  final rawCrop=(request['crop'] as List).cast<double>();
  final left=rawCrop[0].clamp(0.0,1.0);
  final top=rawCrop[1].clamp(0.0,1.0);
  final right=rawCrop[2].clamp(0.0,1.0);
  final bottom=rawCrop[3].clamp(0.0,1.0);
  final x=(left*decoded.width).floor().clamp(0,decoded.width-1).toInt();
  final y=(top*decoded.height).floor().clamp(0,decoded.height-1).toInt();
  final width=math.max(1,(right*decoded.width).ceil()-x)
    .clamp(1,decoded.width-x).toInt();
  final height=math.max(1,(bottom*decoded.height).ceil()-y)
    .clamp(1,decoded.height-y).toInt();
  var cropped=img.copyCrop(decoded,x:x,y:y,width:width,height:height);
  final filter=request['filter'] as String;
  // Flatten any transparency onto white, so ink remains a real signature.
  for(var py=0;py<cropped.height;py++) {
    for(var px=0;px<cropped.width;px++) {
      final p=cropped.getPixel(px,py);
      final alpha=p.a.toDouble()/255.0;
      final r=(p.r.toDouble()*alpha+255*(1-alpha)).round();
      final g=(p.g.toDouble()*alpha+255*(1-alpha)).round();
      final b=(p.b.toDouble()*alpha+255*(1-alpha)).round();
      final grey=(.299*r+.587*g+.114*b).round().clamp(0,255).toInt();
      var red=r,green=g,blue=b;
      switch(filter) {
        case 'Black & White':
          final mono=grey<170?0:255;
          red=mono;green=mono;blue=mono;
        case 'Grayscale':
          red=grey;green=grey;blue=grey;
        case 'Blue Ink':
          final strength=255-grey;
          red=255-strength;green=255-(strength*.72).round();
          blue=255-(strength*.12).round();
        case 'Dark Ink':
          final ink=(grey*.62).round().clamp(0,255).toInt();
          red=ink;green=ink;blue=ink;
      }
      cropped.setPixelRgb(px,py,red,green,blue);
    }
  }
  if(request['preview']==true) {
    final preview=math.max(cropped.width,cropped.height);
    if(preview>1100)cropped=img.copyResize(cropped,
      width:(cropped.width*1100/preview).round(),
      height:(cropped.height*1100/preview).round());
    return Uint8List.fromList(img.encodeJpg(cropped,quality:86));
  }
  final target=request['target'] as int;
  // Try high-quality output first; downscale only if truly needed.
  // Preserve both width and height, never resize only one axis.
  var candidate=cropped;
  for(var pass=0;pass<24;pass++) {
    for(final quality in <int>[92,82,72,60,48,36,26,18,12,7,3]) {
      final result=Uint8List.fromList(img.encodeJpg(candidate,quality:quality));
      // Leave room for a valid COM segment when delta is 1,2 or 3 bytes.
      if(result.length==target || result.length<=target-4) {
        return SignatureEditEngine.padJpegToExactSize(result,target);
      }
    }
    if(candidate.width<=24&&candidate.height<=24)break;
    // Preserve very narrow strokes; never upscale a 1–23 px dimension.
    final newWidth=candidate.width<=24?candidate.width:
      math.max(24,(candidate.width*.80).round());
    final newHeight=candidate.height<=24?candidate.height:
      math.max(24,(candidate.height*.80).round());
    if(newWidth==candidate.width&&newHeight==candidate.height)break;
    candidate=img.copyResize(candidate,width:newWidth,height:newHeight,
      interpolation:img.Interpolation.average);
  }
  throw StateError(
    'Exact ${(target/1024).round()} KB is not achievable without '
    'making this signature unreadable. Increase the target or crop more.');
}
