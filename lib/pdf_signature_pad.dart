import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

/// Hand-drawn signature uses an isolated transparent canvas. The resulting
/// PNG is only embedded after the user taps the PDF preview to place it.
class PdfSignaturePad extends StatefulWidget{
  const PdfSignaturePad({super.key});
  @override State<PdfSignaturePad> createState()=>_PdfSignaturePadState();
}
class _PdfSignaturePadState extends State<PdfSignaturePad>{
  final key=GlobalKey();
  final strokes=<List<Offset>>[];
  Color ink=const Color(0xFF24223A);
  double width=3.0;
  bool saving=false;
  void begin(DragStartDetails d)=>setState(()=>
    strokes.add([d.localPosition]));
  void move(DragUpdateDetails d){
    if(strokes.isEmpty)return;
    setState(()=>strokes.last.add(d.localPosition));
  }
  Future<void> finish()async{
    if(strokes.isEmpty||saving)return;
    setState(()=>saving=true);
    try{
      final obj=key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image=await obj.toImage(pixelRatio:3);
      final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
      image.dispose();
      if(bytes==null)throw StateError('Cannot export signature');
      final dir=await getTemporaryDirectory();
      final file=File('${dir.path}${Platform.pathSeparator}pdf_signature_${DateTime.now().microsecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes.buffer.asUint8List(),flush:true);
      if(mounted)Navigator.pop(context,file.path);
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content:Text('Signature could not be saved: $e')));}
    finally{if(mounted)setState(()=>saving=false);}
  }
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Draw Signature'),actions:[
      IconButton(tooltip:'Undo last stroke',onPressed:strokes.isEmpty?null:
        ()=>setState(()=>strokes.removeLast()),icon:const Icon(Icons.undo)),
      IconButton(tooltip:'Clear',onPressed:strokes.isEmpty?null:
        ()=>setState(strokes.clear),icon:const Icon(Icons.delete_outline)),
    ]),
    body:SafeArea(child:Column(children:[
      Expanded(child:Center(child:Padding(padding:const EdgeInsets.all(16),
        child:AspectRatio(aspectRatio:2.1,child:ClipRRect(
          borderRadius:BorderRadius.circular(16),
          child:RepaintBoundary(key:key,child:ColoredBox(
            color:Colors.transparent,
            child:GestureDetector(
              behavior:HitTestBehavior.opaque,
              onPanStart:begin,onPanUpdate:move,
              child:CustomPaint(painter:_SignaturePainter(strokes,ink,width),
                child:const SizedBox.expand()))))))))),
      Row(children:[
        const SizedBox(width:14),const Text('Pen width'),
        Expanded(child:Slider(value:width,min:1,max:8,
          onChanged:(v)=>setState(()=>width=v))),
        const SizedBox(width:14),
      ]),
      Padding(padding:const EdgeInsets.all(15),child:SizedBox(
        width:double.infinity,child:FilledButton.icon(
          onPressed:saving||strokes.isEmpty?null:finish,
          icon:const Icon(Icons.check),label:const Text('Use signature')))),
    ])));
}
class _SignaturePainter extends CustomPainter{
  _SignaturePainter(this.strokes,this.color,this.width);
  final List<List<Offset>> strokes;
  final Color color;
  final double width;
  @override void paint(Canvas canvas,Size size){
    final paint=Paint()..color=color..strokeWidth=width
      ..strokeCap=StrokeCap.round..strokeJoin=StrokeJoin.round
      ..style=PaintingStyle.stroke;
    for(final stroke in strokes){
      if(stroke.isEmpty)continue;
      final path=Path()..moveTo(stroke.first.dx,stroke.first.dy);
      for(final point in stroke.skip(1))path.lineTo(point.dx,point.dy);
      if(stroke.length==1)canvas.drawCircle(stroke.first,width/2,paint);
      else canvas.drawPath(path,paint);
    }
  }
  @override bool shouldRepaint(covariant _SignaturePainter old)=>true;
}
