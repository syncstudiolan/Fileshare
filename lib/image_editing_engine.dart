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
      // PNG is lossless. If the requested size is impossible at the original
      // dimensions, explicitly reduce dimensions rather than pretending the
      // slider alone changes PNG quality.
      Uint8List result=Uint8List.fromList(img.encodePng(source,level:6));
      if(result.length<=target)return result;
      for(var step=0;step<22;step++){
        final factor=math.sqrt(target/result.length).clamp(.62,.88);
        final width=math.max(1,(source.width*factor).floor());
        final height=math.max(1,(source.height*factor).floor());
        if(width==source.width && height==source.height)break;
        source=img.copyResize(source,width:width,height:height,
          interpolation:img.Interpolation.average);
        result=Uint8List.fromList(img.encodePng(source,level:6));
        if(result.length<=target)return result;
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
    Uint8List encode(int quality)=>
      Uint8List.fromList(img.encodeJpg(source,quality:quality));
    Uint8List search(){
      var low=35,high=preferred;
      Uint8List? best;
      // Favor a useful quality floor; shrink resolution if the target cannot
      // hold 35+ quality, instead of rendering faces at JPEG quality 5.
      if(preferred<35){low=preferred;high=preferred;}
      for(var iteration=0;iteration<8 && low<=high;iteration++){
        final mid=(low+high)~/2;
        final sample=encode(mid);
        if(sample.length<=target){best=sample;low=mid+1;}
        else {high=mid-1;}
      }
      return best??Uint8List(0);
    }
    var result=search();
    if(result.isNotEmpty)return result;
    // Estimate the next dimensions using the actual measured compressed
    // size, not a constant 18% repeated blind shrink. This retains more
    // face detail for extremely small size targets.
    for(var step=0;step<18;step++){
      final trial=encode(math.min(preferred,50));
      final factor=math.sqrt(target/trial.length).clamp(.65,.90);
      final width=math.max(1,(source.width*factor).floor());
      final height=math.max(1,(source.height*factor).floor());
      if(width==source.width&&height==source.height)break;
      source=img.copyResize(source,width:width,height:height,
        interpolation:img.Interpolation.average);
      result=search();
      if(result.isNotEmpty)return result;
    }
    throw StateError('Cannot meet this size without losing all detail. '
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
