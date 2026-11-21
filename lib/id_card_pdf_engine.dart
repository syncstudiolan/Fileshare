import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Geometry is normalized to the source (crop) or to the A4 sheet (layout).
class IdCardCrop {
  const IdCardCrop({this.rect=const RectValues(0,0,1,1),this.quad});
  final RectValues rect;
  final List<double>? quad; // x/y for top-left, top-right, bottom-right, bottom-left
}
class RectValues {
  const RectValues(this.left,this.top,this.right,this.bottom);
  final double left,top,right,bottom;
}
class IdCardPlacement {
  const IdCardPlacement({required this.x,required this.y,
    required this.width,required this.height});
  final double x,y,width,height;
  IdCardPlacement copyWith({double? x,double? y,double? width,double? height})=>
    IdCardPlacement(x:x??this.x,y:y??this.y,
      width:width??this.width,height:height??this.height);
}
class IdCardPdfEngine {
  static Future<Uint8List> crop(Uint8List bytes,IdCardCrop crop)=>
    compute(_cropIdCard,<String,Object?>{
      'bytes':bytes,
      'rect':[crop.rect.left,crop.rect.top,crop.rect.right,crop.rect.bottom],
      if(crop.quad!=null)'quad':crop.quad!,
    });

  static List<IdCardPlacement> initialLayout(int count) {
    if(count<1) return [];
    // Standard ID proportions, arranged in rows on a single A4 sheet.
    // More than six cards are scaled as needed to avoid overlapping.
    final columns=count==1?1:2;
    final rows=(count/columns).ceil();
    final gap=.035;
    final width=count==1?.54:.41;
    final idHeight=width*(210/297)/1.586;
    final height=math.min(idHeight,(.90-gap*(rows-1))/rows);
    final top=(1-(height*rows+gap*(rows-1)))/2;
    return List.generate(count,(i){
      final column=i%columns,row=i~/columns;
      return IdCardPlacement(
        x:columns==1?(1-width)/2:(column==0?.065:1-.065-width),
        y:top+row*(height+gap),width:width,height:height);
    });
  }

  /// Standard multi-page PDF: each selected image goes on its own A4 page.
  /// Unlike the ID layout, images are never forced into card-size slots.
  static Future<Uint8List> normalPdf(List<Uint8List> images)async{
    if(images.isEmpty)throw ArgumentError('No images selected');
    final document=pw.Document(compress:true);
    for(final bytes in images){
      final decoded=img.decodeImage(bytes);
      if(decoded==null)throw const FormatException('Unreadable image');
      document.addPage(pw.Page(
        pageFormat:PdfPageFormat.a4,margin:const pw.EdgeInsets.all(24),
        build:(_)=>pw.Center(child:pw.Image(pw.MemoryImage(bytes),
          fit:pw.BoxFit.contain))));
    }
    return document.save();
  }

  static Future<Uint8List> a4Pdf(List<Uint8List> images,
      List<IdCardPlacement> locations)async {
    if(images.isEmpty||images.length!=locations.length) {
      throw ArgumentError('Images and placements must match');
    }
    final document=pw.Document(compress:true);
    const page=PdfPageFormat.a4;
    final widgets=<pw.Widget>[];
    for(var i=0;i<images.length;i++){
      final position=locations[i];
      if(position.width<=0||position.height<=0)continue;
      widgets.add(pw.Positioned(
        left:position.x*page.width,top:position.y*page.height,
        child:pw.SizedBox(width:position.width*page.width,
          height:position.height*page.height,
          child:pw.Image(pw.MemoryImage(images[i]),fit:pw.BoxFit.fill))));
    }
    document.addPage(pw.Page(pageFormat:page,margin:pw.EdgeInsets.zero,
      build:(_)=>pw.Stack(children:widgets)));
    return document.save();
  }
}

Uint8List _cropIdCard(Map<String,Object?> options){
  final decoded=img.decodeImage(options['bytes'] as Uint8List);
  if(decoded==null)throw const FormatException('Unreadable ID card image');
  final quad=(options['quad'] as List?)?.cast<double>();
  img.Image cropped;
  if(quad!=null && quad.length==8){
    final points=<img.Point>[];
    for(var i=0;i<8;i+=2){
      points.add(img.Point(
        quad[i].clamp(0.0,1.0)*decoded.width,
        quad[i+1].clamp(0.0,1.0)*decoded.height));
    }
    double distance(img.Point a,img.Point b)=>math.sqrt(
      math.pow(a.x-b.x,2)+math.pow(a.y-b.y,2));
    final width=math.max(distance(points[0],points[1]),
      distance(points[3],points[2])).round().clamp(1,8192).toInt();
    final height=math.max(distance(points[0],points[3]),
      distance(points[1],points[2])).round().clamp(1,8192);
    cropped=img.copyRectify(decoded,topLeft:points[0],
      topRight:points[1],bottomRight:points[2],bottomLeft:points[3],
      interpolation:img.Interpolation.linear,
      toImage:img.Image(width:width,height:height,numChannels:4));
  }else{
    final rect=(options['rect'] as List).cast<double>();
    final x=(rect[0].clamp(0.0,1.0)*decoded.width).floor()
      .clamp(0,decoded.width-1).toInt();
    final y=(rect[1].clamp(0.0,1.0)*decoded.height).floor()
      .clamp(0,decoded.height-1).toInt();
    final width=((rect[2]-rect[0])*decoded.width).round()
      .clamp(1,decoded.width-x).toInt();
    final height=((rect[3]-rect[1])*decoded.height).round()
      .clamp(1,decoded.height-y).toInt();
    cropped=img.copyCrop(decoded,x:x,y:y,width:width,height:height);
  }
  return Uint8List.fromList(img.encodePng(cropped,level:1));
}
