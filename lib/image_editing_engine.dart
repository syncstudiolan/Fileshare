import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// CPU-intensive raster operations run in an isolate, never inside a frame.
/// Flutter/Impeller renders the zoomable canvas, animated controls and gestures.
class ImageEditingEngine {
  /// Only feed a bounded preview to ML Kit. Returned mask coordinates are
  /// scaled to the full edited image when the background action is applied.
  /// This avoids native segmentation OOM on 12/48 MP phone photos.
  static Future<Uint8List> segmentationInput(Uint8List bytes)=>
    compute(_segmentationInput,bytes);
  static Uint8List _segmentationInput(Uint8List bytes){
    final source=img.decodeImage(bytes);
    if(source==null)throw const FormatException('Invalid image');
    const maxSide=1280;
    final length=math.max(source.width,source.height);
    final scaled=length>maxSide
      ?img.copyResize(source,
        width:math.max(1,(source.width*maxSide/length).round()),
        height:math.max(1,(source.height*maxSide/length).round()),
        interpolation:img.Interpolation.average)
      :source;
    if(scaled.numChannels==4){
      final base=img.Image(width:scaled.width,height:scaled.height,
        numChannels:3);
      img.fill(base,color:img.ColorRgb8(255,255,255));
      img.compositeImage(base,scaled);
      return Uint8List.fromList(img.encodeJpg(base,quality:85));
    }
    return Uint8List.fromList(img.encodeJpg(scaled,quality:85));
  }

  /// One-time bounded edit copy. Preserve the untouched high-resolution
  /// original separately for restoration. Typical photos remain full-size.
  static Future<Uint8List> prepareWorkingImage(Uint8List bytes)=>
    compute(_prepareWorkingImage,bytes);
  static Uint8List _prepareWorkingImage(Uint8List bytes){
    final source=img.decodeImage(bytes);
    if(source==null)throw const FormatException('Invalid image');
    const maxPixels=6000000;
    final pixels=source.width*source.height;
    if(pixels<=maxPixels)return bytes;
    final ratio=math.sqrt(maxPixels/pixels);
    final scaled=img.copyResize(source,
      width:math.max(1,(source.width*ratio).floor()),
      height:math.max(1,(source.height*ratio).floor()),
      interpolation:img.Interpolation.average);
    if(scaled.numChannels==4){
      return Uint8List.fromList(img.encodePng(scaled,level:1));
    }
    return Uint8List.fromList(img.encodeJpg(scaled,quality:95));
  }

  static Future<List<int>> dimensions(Uint8List bytes)=>compute(_readSize,bytes);
  static List<int> _readSize(Uint8List bytes){
    final source=img.decodeImage(bytes);
    if(source==null)throw const FormatException('Unsupported or damaged image');
    return [source.width,source.height];
  }
  static Future<Uint8List> edit(Uint8List bytes, String action,
      Map<String, Object?> options) => compute(_runOperation, <String, Object?>{
        'bytes': bytes, 'action': action, 'options': options,
      });

  static Uint8List _runOperation(Map<String, Object?> request) {
    final source = img.decodeImage(request['bytes'] as Uint8List);
    if (source == null) throw const FormatException('Unsupported or damaged image');
    final options = request['options'] as Map<String, Object?>;
    final action = request['action'] as String;
    var output = source.convert(numChannels: 4);
    int number(String key, int fallback) =>
        (options[key] as num?)?.round() ?? fallback;
    double decimal(String key, double fallback) =>
        (options[key] as num?)?.toDouble() ?? fallback;
    switch (action) {
      case 'crop':
        final x = (decimal('x', 0) * output.width).round().clamp(0, output.width - 1).toInt();
        final y = (decimal('y', 0) * output.height).round().clamp(0, output.height - 1).toInt();
        final w = (decimal('w', 1) * output.width).round().clamp(1, output.width - x).toInt();
        final h = (decimal('h', 1) * output.height).round().clamp(1, output.height - y).toInt();
        output = img.copyCrop(output, x: x, y: y, width: w, height: h);
      case 'perspective':
        double point(String key) =>
            ((options[key] as num?)?.toDouble()??0).clamp(0.0,1.0);
        final tl=img.Point(point('tlx')*output.width,point('tly')*output.height);
        final tr=img.Point(point('trx')*output.width,point('try')*output.height);
        final br=img.Point(point('brx')*output.width,point('bry')*output.height);
        final bl=img.Point(point('blx')*output.width,point('bly')*output.height);
        final width=(math.max(math.sqrt(math.pow(tr.x-tl.x,2)+math.pow(tr.y-tl.y,2)),
          math.sqrt(math.pow(br.x-bl.x,2)+math.pow(br.y-bl.y,2))))
          .round().clamp(1,8192).toInt();
        final height=(math.max(math.sqrt(math.pow(bl.x-tl.x,2)+math.pow(bl.y-tl.y,2)),
          math.sqrt(math.pow(br.x-tr.x,2)+math.pow(br.y-tr.y,2))))
          .round().clamp(1,8192).toInt();
        output=img.copyRectify(output,topLeft:tl,topRight:tr,
          bottomLeft:bl,bottomRight:br,
          interpolation:img.Interpolation.linear,
          toImage:img.Image(width:width,height:height,numChannels:4));
      case 'rotate':
        output = img.copyRotate(output, angle: decimal('degrees', 90));
      case 'straighten':
        final degrees=decimal('degrees',0).clamp(-45.0,45.0);
        if(degrees.abs()<0.001)break;
        final originalW=output.width.toDouble();
        final originalH=output.height.toDouble();
        output=img.copyRotate(output,angle:degrees,
          interpolation:img.Interpolation.linear);
        if(options['autoCrop']!=false){
          final radians=degrees.abs()*math.pi/180;
          final sin=math.sin(radians),cos=math.cos(radians);
          final shortSide=math.min(originalW,originalH);
          final longSide=math.max(originalW,originalH);
          double croppedW,croppedH;
          if(shortSide<=2*sin*cos*longSide){
            final x=shortSide/2;
            if(originalW>=originalH){
              croppedW=x/sin;croppedH=x/cos;
            }else{
              croppedW=x/cos;croppedH=x/sin;
            }
          }else{
            final denom=cos*cos-sin*sin;
            if(denom.abs()<1e-6){
              croppedW=originalW*.70;croppedH=originalH*.70;
            }else{
              croppedW=(originalW*cos-originalH*sin)/denom;
              croppedH=(originalH*cos-originalW*sin)/denom;
            }
          }
          final w=croppedW.round().clamp(1,output.width);
          final h=croppedH.round().clamp(1,output.height);
          output=img.copyCrop(output,
            x:(output.width-w)~/2,y:(output.height-h)~/2,
            width:w,height:h);
        }
      case 'flip':
        output = img.flipHorizontal(output);
      case 'adjust':
        output = img.adjustColor(output,
          brightness: decimal('brightness', 1),
          contrast: decimal('contrast', 1),
          saturation: decimal('saturation', 1),
          exposure: decimal('exposure', 0));
      case 'filter':
        switch (options['name']) {
          case 'B&W':
            output = img.grayscale(output);
          case 'Vivid':
            output = img.adjustColor(output, saturation: 1.35, contrast: 1.12);
          case 'Warm':
            output = img.adjustColor(output, hue: 12, saturation: 1.10);
          case 'Cool':
            output = img.adjustColor(output, hue: -14, saturation: 1.08);
          case 'Vintage':
            output = img.sepia(output);
          case 'Soft':
            output = img.gaussianBlur(output, radius: 2);
        }
      case 'background':
        final data = options['mask'] as Uint8List?;
        final maskWidth = number('maskWidth', 0);
        final maskHeight = number('maskHeight', 0);
        if (data == null || maskWidth < 1 || maskHeight < 1 ||
            data.length != maskWidth * maskHeight) {
          throw const FormatException('Subject mask is unavailable');
        }
        final maskColumns=Int32List(output.width);
        for(var x=0;x<maskColumns.length;x++){
          maskColumns[x]=math.min(maskWidth-1,x*maskWidth~/output.width);
        }
        for(var y=0;y<output.height;y++){
          final row=math.min(maskHeight-1,
            y*maskHeight~/output.height)*maskWidth;
          for(var x=0;x<output.width;x++){
            final px=output.getPixel(x,y);
            final alpha=(px.a*data[row+maskColumns[x]]/255).round();
            output.setPixelRgba(x,y,px.r,px.g,px.b,alpha);
          }
        }
      case 'erase':
      case 'restore':
        final points=(options['points'] as List?) ?? [
          {'x': decimal('x', .5), 'y': decimal('y', .5)},
        ];
        final radius = (decimal('radius', .03) *
          math.min(output.width, output.height)).round().clamp(1, 240).toInt();
        final softness = decimal('softness', .4).clamp(0.01, 1.0);
        final erase=action=='erase';
        // Sample the path on the worker isolate; sparse touch events must not
        // become a row of separate dots. Pixel work never blocks Flutter UI.
        final samples=<({int x,int y})>[];
        for(final raw in points){
          if(raw is! Map)continue;
          final px=(((raw['x'] as num).toDouble()).clamp(0.0,1.0)
            *output.width).round();
          final py=(((raw['y'] as num).toDouble()).clamp(0.0,1.0)
            *output.height).round();
          final previous=samples.isEmpty?null:samples.last;
          if(previous!=null){
            final dx=px-previous.x,dy=py-previous.y;
            final gap=math.sqrt(dx*dx+dy*dy);
            // Dense 120 Hz pointer samples already overlap substantially.
            // Avoid applying the same large brush to near-identical pixels.
            if(gap<math.max(1.0,radius*.28))continue;
            final steps=(gap/math.max(1.0,radius*.35)).ceil().clamp(1,128);
            for(var k=1;k<steps;k++){
              final t=k/steps;
              samples.add((x:(previous.x+(px-previous.x)*t).round(),
                y:(previous.y+(py-previous.y)*t).round()));
            }
          }
          samples.add((x:px,y:py));
        }
        for(final point in samples){
          final x=point.x,y=point.y;
          for(var py=math.max(0,y-radius);py<=math.min(output.height-1,y+radius);py++){
            for(var px=math.max(0,x-radius);px<=math.min(output.width-1,x+radius);px++){
              final dx=px-x,dy=py-y;
              final distanceSq=dx*dx+dy*dy;
              if(distanceSq>radius*radius)continue;
              final distance=math.sqrt(distanceSq);
              final feather=((radius-distance)/(radius*softness)).clamp(0.0,1.0);
              final pixel=output.getPixel(px,py);
              final alpha=erase?pixel.a*(1-feather):
                pixel.a+(255-pixel.a)*feather;
              output.setPixelRgba(px,py,pixel.r,pixel.g,pixel.b,alpha.round());
            }
          }
        }
      case 'resize':
        final targetWidth = number('width', output.width).clamp(1, 8192).toInt();
        final targetHeight = number('height', output.height).clamp(1, 8192).toInt();
        output = img.copyResize(output, width: targetWidth, height: targetHeight,
          interpolation: img.Interpolation.cubic);
      case 'flatten':
        final color = number('color', 0xffffffff);
        final backgroundBytes = options['backgroundBytes'] as Uint8List?;
        final background = backgroundBytes == null
            ? img.Image(width: output.width, height: output.height, numChannels: 4)
            : img.copyResize(img.decodeImage(backgroundBytes)!,
                width: output.width, height: output.height);
        if (backgroundBytes == null) {
          img.fill(background, color: img.ColorRgba8(
            (color >> 16) & 255, (color >> 8) & 255, color & 255, 255));
        }
        img.compositeImage(background, output);
        output = background;
    }
    // Editing snapshots are temporary, lossless working images. PNG's default
    // zlib effort is costly on large phone photos and blocks Apply even after
    // the pixel operation has finished. Level 1 keeps pixels lossless while
    // avoiding expensive background compression on every tool change.
    return Uint8List.fromList(img.encodePng(output,level:1));
  }

  /// Cart exports are snapshots, not edits. Keep the edited raster size and
  /// reuse its encoded bytes whenever possible. A selected target is exact,
  /// using valid format metadata padding only after a real encode fits.
  static Future<Uint8List> cartExport(Uint8List bytes,String format,
      {int? targetKb,int quality=85})=>compute(_cartExportOperation,{
        'bytes':bytes,'format':format,'targetKb':targetKb,'quality':quality,
      });

  static bool isJpeg(List<int> bytes)=>bytes.length>=2 &&
      bytes[0]==0xff && bytes[1]==0xd8;
  static bool isPng(List<int> bytes)=>bytes.length>=8 &&
      bytes[0]==137 && bytes[1]==80 && bytes[2]==78 && bytes[3]==71 &&
      bytes[4]==13 && bytes[5]==10 && bytes[6]==26 && bytes[7]==10;

  static int? appliedTargetKb(Iterable<String> steps){
    for(final step in steps.toList().reversed){
      final match=RegExp(r'^Compress (\d+) KB \((JPEG|PNG)\)$').firstMatch(step);
      if(match!=null)return int.tryParse(match.group(1)!);
    }
    return null;
  }

  static Uint8List _cartExportOperation(Map<String,Object?> request){
    final bytes=request['bytes'] as Uint8List;
    final format=request['format'] as String;
    if(format!='JPEG'&&format!='PNG')throw ArgumentError('Unsupported output format');
    final png=format=='PNG';
    final targetKb=request['targetKb'] as int?;
    if(targetKb!=null && (targetKb<1||targetKb>500000)){
      throw ArgumentError('Invalid compression target');
    }
    final target=targetKb==null?null:targetKb*1024;
    final same=png?isPng(bytes):isJpeg(bytes);
    final decoded=img.decodeImage(bytes);
    if(decoded==null)throw const FormatException('Invalid image snapshot');
    if(same && target==null)return bytes;
    if(same && target!=null){
      final padded=_padCartImage(bytes,target,png);
      if(padded!=null)return padded;
    }
    var source=decoded;
    if(!png && source.numChannels==4){
      final white=img.Image(width:source.width,height:source.height,numChannels:3);
      img.fill(white,color:img.ColorRgb8(255,255,255));
      img.compositeImage(white,source);
      source=white;
    }
    final quality=(request['quality'] as int).clamp(5,100).toInt();
    if(png){
      // Different DEFLATE levels may avoid a 1–11 byte padding gap.
      for(final level in [9,8,7,6,5,4,3,2,1,0]){
        final result=Uint8List.fromList(img.encodePng(source,level:level));
        if(target==null)return result;
        final exact=_padCartImage(result,target,true);
        if(exact!=null)return exact;
      }
    }else{
      if(target==null)return Uint8List.fromList(img.encodeJpg(source,quality:quality));
      // Keep geometry, avoid silent destructive resizing. Try lower quality
      // only when required by the explicitly selected byte target.
      for(var q=quality;q>=math.min(68,quality);q--){
        final result=Uint8List.fromList(img.encodeJpg(source,quality:q));
        final exact=_padCartImage(result,target,false);
        if(exact!=null)return exact;
      }
    }
    throw StateError('This format cannot fit the applied size without changing the edited dimensions. Choose the original format or apply a larger compression target.');
  }

  static Uint8List? _padCartImage(Uint8List bytes,int target,bool png){
    final extra=target-bytes.length;
    if(extra==0)return bytes;
    if(extra< (png?12:4))return null;
    // Do not allocate hundreds of MB of empty metadata merely to inflate
    // a tiny photo. Report the limit instead of risking a mobile OOM.
    if(extra>32*1024*1024)throw StateError('Exact-size padding exceeds 32 MB; select a smaller target');
    final output=BytesBuilder(copy:false);
    if(png){
      if(!isPng(bytes)||bytes.length<20||
          String.fromCharCodes(bytes.sublist(bytes.length-8,bytes.length-4))!='IEND')return null;
      // Private, ancillary, safe-to-copy PNG chunk, immediately before IEND.
      // A real CRC32 is required for strict PNG readers.
      final type=<int>[102,115,80,97]; // fsPa
      final length=extra-12;
      final data=Uint8List(length);
      var crc=0xffffffff;
      for(final b in type){crc=_cartCrcByte(crc,b);}
      for(var j=0;j<length;j++){crc=_cartCrcByte(crc,0);}
      crc=(crc^0xffffffff)&0xffffffff;
      List<int> be(int n)=>[(n>>>24)&255,(n>>>16)&255,(n>>>8)&255,n&255];
      output.add(bytes.sublist(0,bytes.length-12));
      output.add(be(length));output.add(type);output.add(data);output.add(be(crc));
      output.add(bytes.sublist(bytes.length-12));
    }else{
      if(!isJpeg(bytes)||bytes.length<4||bytes[bytes.length-2]!=0xff||bytes.last!=0xd9)return null;
      output.add(bytes.sublist(0,2));
      var remaining=extra;
      while(remaining>0){
        var chunk=math.min(remaining,65537);
        if(remaining-chunk>0&&remaining-chunk<4)chunk=remaining-4;
        if(chunk<4)return null;
        final size=chunk-2;
        output.add([0xff,0xfe,(size>>>8)&255,size&255]);
        output.add(Uint8List(chunk-4));
        remaining-=chunk;
      }
      output.add(bytes.sublist(2));
    }
    final result=output.takeBytes();
    if(result.length!=target)throw StateError('Exact export length verification failed');
    return result;
  }

  static int _cartCrcByte(int crc,int b){
    var value=crc^b;
    for(var i=0;i<8;i++){
      value=(value>>>1)^((value&1)!=0?0xedb88320:0);
    }
    return value;
  }

  static Future<Uint8List> compress(Uint8List bytes,
      {int targetKb = 500, int quality = 85, String format = 'JPEG'}) =>
    compute(_compressOperation, <String, Object?>{
      'bytes': bytes, 'targetKb': targetKb, 'quality': quality, 'format': format,
    });

  static Uint8List _compressOperation(Map<String, Object?> request) {
    final decoded=img.decodeImage(request['bytes'] as Uint8List);
    if(decoded==null)throw const FormatException('Invalid image');
    var source=decoded;
    final format=request['format'] as String;
    final target=(request['targetKb'] as int).clamp(1,500000).toInt()*1024;
    final preferred=(request['quality'] as int).clamp(5,100).toInt();
    if(format=='PNG'){
      // PNG uses lossless DEFLATE compression. Try its strongest level first:
      // this can meet a small target without deleting any pixels or alpha.
      // Only if the full-resolution image does not fit, resize from the
      // ORIGINAL source at every step (never resample a resampled image).
      final original=source;
      Uint8List result=Uint8List.fromList(img.encodePng(original,level:9));
      if(result.length<=target)return result;
      var scale=1.0;
      for(var step=0;step<26;step++){
        final ratio=math.sqrt(target/result.length).clamp(.72,.94).toDouble();
        scale*=ratio;
        final width=math.max(1,(original.width*scale).round());
        final height=math.max(1,(original.height*scale).round());
        if(width==source.width&&height==source.height)break;
        source=img.copyResize(original,width:width,height:height,
          interpolation:img.Interpolation.cubic);
        result=Uint8List.fromList(img.encodePng(source,level:9));
        if(result.length<=target)return result;
        if(width<=16&&height<=16)break;
      }
      throw StateError('Target too small for a usable lossless PNG; '
        'try JPEG or choose a larger size');
    }
    // JPEG has no alpha channel; flatten a cutout onto white instead of
    // emitting black/undefined pixels where the background was removed.
    if(source.numChannels==4){
      final white=img.Image(width:source.width,height:source.height,
        numChannels:3);
      img.fill(white,color:img.ColorRgb8(255,255,255));
      img.compositeImage(white,source);
      source=white;
    }
    // IMPORTANT: resize from the ORIGINAL decoded pixels at each candidate
    // resolution. Repeatedly resizing the previous candidate irreversibly
    // blurs eyes, hair, lettering and signature strokes.
    final original=source;
    final minQuality=math.min(68,preferred);
    Uint8List? best;
    var bestArea=-1;
    var bestQuality=-1;
    var factor=1.0;
    for(var pass=0;pass<28;pass++){
      final width=math.max(1,(original.width*factor).round());
      final height=math.max(1,(original.height*factor).round());
      source=(width==original.width&&height==original.height)
        ?original:img.copyResize(original,width:width,height:height,
          interpolation:img.Interpolation.cubic);
      var low=minQuality,high=preferred;
      Uint8List? fitting;
      var fittingQuality=-1;
      for(var iteration=0;iteration<8 && low<=high;iteration++){
        final mid=(low+high)~/2;
        final encoded=Uint8List.fromList(img.encodeJpg(source,quality:mid));
        if(encoded.length<=target){
          fitting=encoded;fittingQuality=mid;low=mid+1;
        }else{high=mid-1;}
      }
      if(fitting!=null){
        final area=width*height;
        if(area>bestArea || (area==bestArea&&fittingQuality>bestQuality)){
          best=fitting;bestArea=area;bestQuality=fittingQuality;
        }
        // At the highest available resolution the fitting quality is optimal.
        // Do not shrink further just to fill the entire KB budget.
        break;
      }
      if(width<=32&&height<=32)break;
      final measured=img.encodeJpg(source,quality:minQuality).length;
      final ratio=math.sqrt(target/measured).clamp(.72,.94).toDouble();
      factor*=ratio;
      if((original.width*factor).round()==width &&
          (original.height*factor).round()==height)factor*=.9;
    }
    if(best!=null)return best;
    throw StateError('Cannot meet this size at readable JPEG quality. '
      'Try a slightly larger target.');

  }

  /// No AI model on Windows is silently claimed: this explicitly labeled
  /// simple-background tool is a color-distance edge connected flood fill.
  /// It works well on plain backdrops, not intricate hair or complex scenes.
  static Future<Uint8List> simpleBackgroundMask(Uint8List bytes,
      {double tolerance = 42}) => compute(_simpleMask, <String, Object?>{
        'bytes': bytes, 'tolerance': tolerance,
      });

  static Uint8List _simpleMask(Map<String, Object?> args) {
    final source = img.decodeImage(args['bytes'] as Uint8List);
    if (source == null) throw const FormatException('Invalid image');
    final width = source.width, height = source.height;
    final count = width * height;
    if (count > 24 * 1000 * 1000) {
      throw const FormatException('Image too large for local mask');
    }
    final corner = source.getPixel(0, 0);
    final referenceR = corner.r.toDouble(), referenceG = corner.g.toDouble(),
      referenceB = corner.b.toDouble();
    final tolerance = args['tolerance'] as double;
    final visited = Uint8List(count);
    final alpha = Uint8List(count)..fillRange(0, count, 255);
    final queue = Int32List(count);
    var head = 0, tail = 0;
    for (final i in [0, width - 1, count - width, count - 1]) {
      if (visited[i] == 0) { visited[i] = 1; queue[tail++] = i; }
    }
    while (head < tail) {
      final index = queue[head++];
      final x = index % width, y = index ~/ width;
      final pixel = source.getPixel(x, y);
      final dr=pixel.r-referenceR,dg=pixel.g-referenceG,
        db=pixel.b-referenceB;
      if(dr*dr+dg*dg+db*db>tolerance*tolerance)continue;
      alpha[index] = 0;
      void add(int other) {
        if (visited[other] == 0) { visited[other] = 1; queue[tail++] = other; }
      }
      if (x > 0) add(index - 1);
      if (x < width - 1) add(index + 1);
      if (y > 0) add(index - width);
      if (y < height - 1) add(index + width);
    }
    return alpha;
  }
}
