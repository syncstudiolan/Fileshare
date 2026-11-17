import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// CPU-intensive raster operations run in an isolate, never inside a frame.
/// Flutter/Impeller renders the zoomable canvas, animated controls and gestures.
class ImageEditingEngine {
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
        for (var y = 0; y < output.height; y++) {
          final my = (y * maskHeight ~/ output.height).clamp(0, maskHeight - 1).toInt();
          for (var x = 0; x < output.width; x++) {
            final mx = (x * maskWidth ~/ output.width).clamp(0, maskWidth - 1).toInt();
            final px = output.getPixel(x, y);
            final alpha = (px.a * data[my * maskWidth + mx] / 255).round();
            output.setPixelRgba(x, y, px.r, px.g, px.b, alpha);
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
        for(final point in points){
          if(point is! Map)continue;
          final x=((point['x'] as num).toDouble()*output.width).round();
          final y=((point['y'] as num).toDouble()*output.height).round();
          for(var py=math.max(0,y-radius);py<=math.min(output.height-1,y+radius);py++){
            for(var px=math.max(0,x-radius);px<=math.min(output.width-1,x+radius);px++){
              final distance=math.sqrt((px-x)*(px-x)+(py-y)*(py-y));
              if(distance>radius)continue;
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
    return Uint8List.fromList(img.encodePng(output));
  }

  static Future<Uint8List> compress(Uint8List bytes,
      {int targetKb = 500, int quality = 85, String format = 'JPEG'}) =>
    compute(_compressOperation, <String, Object?>{
      'bytes': bytes, 'targetKb': targetKb, 'quality': quality, 'format': format,
    });

  static Uint8List _compressOperation(Map<String, Object?> request) {
    final decoded = img.decodeImage(request['bytes'] as Uint8List);
    if (decoded == null) throw const FormatException('Invalid image');
    var source = decoded;
    final format = request['format'] as String;
    final targetBytes = (request['targetKb'] as int).clamp(1, 500000).toInt() * 1024;
    if(format=='PNG'){
      var result=Uint8List.fromList(img.encodePng(source,level:9));
      if(result.length<=targetBytes)return result;
      for(var i=0;i<12;i++){
        final width=(source.width*.82).round();
        final height=(source.height*.82).round();
        if(width<32||height<32)break;
        source=img.copyResize(source,width:width,height:height);
        result=Uint8List.fromList(img.encodePng(source,level:9));
        if(result.length<=targetBytes)break;
      }
      return result;
    }
    var quality = (request['quality'] as int).clamp(1, 100).toInt();
    Uint8List encode(int q) => Uint8List.fromList(img.encodeJpg(source, quality: q));
    var result = encode(quality);
    if (result.length <= targetBytes) return result;
    // Target-size search is bounded and saves the smallest valid result.
    var low = 5, high = quality;
    Uint8List? withinTarget;
    for (var i = 0; i < 8 && low <= high; i++) {
      final mid = (low + high) ~/ 2;
      final test = encode(mid);
      if (test.length <= targetBytes) {
        withinTarget = test;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (withinTarget != null) return withinTarget;
    // For very small requested files lower resolution rather than pretending
    // that a quality setting alone can always hit an arbitrary target.
    for (var i = 0; i < 7; i++) {
      final width = (source.width * .82).round();
      final height = (source.height * .82).round();
      if (width < 64 || height < 64) break;
      source = img.copyResize(source, width: width, height: height);
      result = encode(38);
      if (result.length <= targetBytes) break;
    }
    return result;
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
      final delta = math.sqrt(math.pow(pixel.r - referenceR, 2) +
          math.pow(pixel.g - referenceG, 2) + math.pow(pixel.b - referenceB, 2));
      if (delta > tolerance) continue;
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
