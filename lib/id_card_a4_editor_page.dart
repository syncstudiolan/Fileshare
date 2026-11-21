import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'app_top_notice.dart';
import 'image_editing_storage.dart';
import 'id_card_pdf_engine.dart';
import 'main.dart' show FileTheme;
import 'editor_transfer_session.dart' show returnToFileShareCart;

/// Android Advanced PDF Pro: crop each selected ID image first, then lay out
/// movable/resizable cards on one A4 page. Original files are never modified.
class IdCardA4EditorPage extends StatefulWidget {
  const IdCardA4EditorPage({super.key,required this.paths});
  final List<String> paths;
  @override State<IdCardA4EditorPage> createState()=>_IdCardA4EditorPageState();
}

class _IdCardA4EditorPageState extends State<IdCardA4EditorPage> {
  final _original=<Uint8List>[];
  final _cropped=<Uint8List?>[];
  final _selection=<IdCardCrop>[];
  final _completed=<bool>[];
  List<IdCardPlacement> _layout=[];
  int _active=0;
  bool _arrange=false,_busy=false;
  bool _perspective=false;
  int _handle=-1;
  String? _error;

  @override void initState(){super.initState();_load();}
  Future<void> _load()async{
    setState(()=>_busy=true);
    try{
      for(final path in widget.paths){
        final bytes=await File(path).readAsBytes();
        if(img.decodeImage(bytes)==null)continue;
        _original.add(bytes);
        _cropped.add(null);
        _completed.add(false);
        _selection.add(const IdCardCrop(
          rect:RectValues(.06,.06,.94,.94)));
      }
      if(_original.isEmpty)throw StateError('No readable image files');
      if(mounted)setState(()=>_layout=IdCardPdfEngine.initialLayout(_original.length));
    }catch(e){if(mounted)setState(()=>_error='$e');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  void _setSelection(RectValues value,List<double>? quad){
    setState((){
      _selection[_active]=IdCardCrop(rect:value,quad:quad);
      _completed[_active]=false;
      _cropped[_active]=null;
    });
  }
  void _dragCrop(DragUpdateDetails details,Size size){
    if(_busy || _handle<0)return;
    final c=_selection[_active];
    final dx=details.delta.dx/size.width,dy=details.delta.dy/size.height;
    if(_perspective){
      final points=List<double>.of(c.quad??[
        c.rect.left,c.rect.top,c.rect.right,c.rect.top,
        c.rect.right,c.rect.bottom,c.rect.left,c.rect.bottom]);
      final k=_handle.clamp(0,3)*2;
      points[k]=(points[k]+dx).clamp(0.0,1.0).toDouble();
      points[k+1]=(points[k+1]+dy).clamp(0.0,1.0).toDouble();
      _setSelection(c.rect,points);
    }else{
      double l=c.rect.left,t=c.rect.top,r=c.rect.right,b=c.rect.bottom;
      switch(_handle){
        case 0: l=(l+dx).clamp(0.0,r-.06);t=(t+dy).clamp(0.0,b-.06);
        case 1: r=(r+dx).clamp(l+.06,1.0);t=(t+dy).clamp(0.0,b-.06);
        case 2: r=(r+dx).clamp(l+.06,1.0);b=(b+dy).clamp(t+.06,1.0);
        case 3: l=(l+dx).clamp(0.0,r-.06);b=(b+dy).clamp(t+.06,1.0);
        case 4: l=(l+dx).clamp(0.0,r-.06);
        case 5: t=(t+dy).clamp(0.0,b-.06);
        case 6: r=(r+dx).clamp(l+.06,1.0);
        case 7: b=(b+dy).clamp(t+.06,1.0);
        case 8:
          final shiftX=dx.clamp(-l,1-r).toDouble();
          final shiftY=dy.clamp(-t,1-b).toDouble();
          l+=shiftX;r+=shiftX;t+=shiftY;b+=shiftY;
      }
      _setSelection(RectValues(l,t,r,b),null);
    }
  }

  void _startCrop(DragStartDetails details,Size size){
    final c=_selection[_active];
    final q=_perspective && c.quad!=null ? c.quad! :
      [c.rect.left,c.rect.top,c.rect.right,c.rect.top,
      c.rect.right,c.rect.bottom,c.rect.left,c.rect.bottom];
    final points=<Offset>[
      for(var k=0;k<8;k+=2)Offset(q[k],q[k+1])
    ];
    final p=Offset(details.localPosition.dx/size.width,
      details.localPosition.dy/size.height);
    var best=double.infinity;
    _handle=8;
    for(var i=0;i<4;i++){
      final distance=(points[i]-p).distance;
      if(distance<best){best=distance;_handle=i;}
    }
    if(!_perspective){
      final mids=<Offset>[
        Offset(c.rect.left,(c.rect.top+c.rect.bottom)/2),
        Offset((c.rect.left+c.rect.right)/2,c.rect.top),
        Offset(c.rect.right,(c.rect.top+c.rect.bottom)/2),
        Offset((c.rect.left+c.rect.right)/2,c.rect.bottom),
      ];
      for(var i=0;i<4;i++){
        final distance=(mids[i]-p).distance;
        if(distance<best){best=distance;_handle=i+4;}
      }
    }
    if(best>.095)_handle=_perspective?-1:8;
  }

  Future<void> _cropCurrent()async{
    if(_busy||_original.isEmpty)return;
    setState(()=>_busy=true);
    try{
      final current=_selection[_active];
      final output=await IdCardPdfEngine.crop(_original[_active],
        _perspective?current:IdCardCrop(rect:current.rect));
      if(!mounted)return;
      setState((){
        _cropped[_active]=output;
        _completed[_active]=true;
      });
      FileShareTopNotice.show(context,'Image ${_active+1} cropped');
    }catch(e){if(mounted)FileShareTopNotice.show(context,'Crop failed: $e');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  void _next(){
    if(_completed.every((value)=>value)){
      setState(()=>_arrange=true);
    }else{
      final i=_completed.indexWhere((value)=>!value);
      setState(()=>_active=i);
      FileShareTopNotice.show(context,'Crop every image before Next');
    }
  }

  void _move(int index,Offset delta,Size a4,{bool resize=false}){
    final old=_layout[index];
    final dx=delta.dx/a4.width,dy=delta.dy/a4.height;
    setState((){
      if(resize){
        final w=(old.width+dx).clamp(.08,1-old.x).toDouble();
        final h=(old.height+dy).clamp(.04,1-old.y).toDouble();
        _layout[index]=old.copyWith(width:w,height:h);
      }else{
        _layout[index]=old.copyWith(
          x:(old.x+dx).clamp(0.0,1-old.width).toDouble(),
          y:(old.y+dy).clamp(0.0,1-old.height).toDouble());
      }
    });
  }

  Future<void> _export(String action)async{
    if(_busy||!_arrange||_cropped.any((x)=>x==null))return;
    setState(()=>_busy=true);
    try{
      final pdf=await IdCardPdfEngine.a4Pdf(
        _cropped.cast<Uint8List>(),List.of(_layout));
      final name='FileShare_ID_Cards_${DateTime.now().millisecondsSinceEpoch}.pdf';
      if(action=='cart'){
        await ImageEditingCart.instance.addEditedBytes(pdf,name);
        if(mounted)returnToFileShareCart(context);
      }else if(action=='share'){
        final directory=await getTemporaryDirectory();
        final file=File('${directory.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(pdf,flush:true);
        await SharePlus.instance.share(
          ShareParams(files:[XFile(file.path,mimeType:'application/pdf')]));
      }else{
        await FilePicker.saveFile(fileName:name,bytes:pdf,
          mimeType:'application/pdf');
      }
    }catch(e){if(mounted)FileShareTopNotice.show(context,'A4 export failed: $e');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  Widget _cropCanvas(){
    final bytes=_original[_active];
    final dimensions=img.decodeImage(bytes)!;
    return Center(child:AspectRatio(
      aspectRatio:dimensions.width/dimensions.height,
      child:LayoutBuilder(builder:(context,bounds){
        final size=Size(bounds.maxWidth,bounds.maxHeight);
        return GestureDetector(
          onPanStart:(d)=>_startCrop(d,size),
          onPanUpdate:(d)=>_dragCrop(d,size),
          onPanEnd:(_)=>_handle=-1,
          child:Stack(fit:StackFit.expand,children:[
            Image.memory(bytes,fit:BoxFit.fill),
            CustomPaint(painter:_IdCropPainter(_selection[_active],
              perspective:_perspective)),
          ]),
        );
      }),
    ));
  }

  Widget _cropStep(){
    return Column(children:[
      Padding(padding:const EdgeInsets.all(10),
        child:Text('Crop image ${_active+1} of ${_original.length}',
          style:const TextStyle(fontWeight:FontWeight.bold))),
      SizedBox(height:54,child:ListView.builder(scrollDirection:Axis.horizontal,
        itemCount:_original.length,itemBuilder:(context,i)=>Padding(
          padding:const EdgeInsets.symmetric(horizontal:3),
          child:ChoiceChip(label:Text('${i+1} ${_completed[i]?'✓':''}'),
            selected:_active==i,onSelected:(_)=>setState(()=>_active=i))))),
      Expanded(child:Padding(padding:const EdgeInsets.all(16),
        child:_cropCanvas())),
      Padding(padding:const EdgeInsets.symmetric(horizontal:12),
        child:Row(children:[
          Expanded(child:RadioListTile<bool>(dense:true,
            title:const Text('Normal'),value:false,groupValue:_perspective,
            onChanged:(v)=>setState(()=>_perspective=v!))),
          Expanded(child:RadioListTile<bool>(dense:true,
            title:const Text('Perspective'),value:true,
            groupValue:_perspective,
            onChanged:(v)=>setState(()=>_perspective=v!))),
        ])),
      Padding(padding:const EdgeInsets.fromLTRB(12,4,12,14),
        child:Row(children:[
          Expanded(child:FilledButton.icon(
            onPressed:_busy?null:_cropCurrent,
            icon:const Icon(Icons.crop_rounded),
            label:const Text('Crop Done'))),
          const SizedBox(width:8),
          Expanded(child:FilledButton.icon(
            onPressed:_busy?null:_next,
            icon:const Icon(Icons.arrow_forward_rounded),
            label:const Text('Next · A4'))),
        ])),
    ]);
  }

  Widget _layoutStep(){
    return Column(children:[
      const Padding(padding:EdgeInsets.all(10),
        child:Text('A4 ID Card Layout · Drag to move · Corner to resize',
          textAlign:TextAlign.center)),
      Expanded(child:Center(child:AspectRatio(aspectRatio:210/297,
        child:LayoutBuilder(builder:(context,bounds){
          final size=Size(bounds.maxWidth,bounds.maxHeight);
          return Container(color:Colors.white,child:Stack(children:[
            for(var i=0;i<_layout.length;i++)
              Positioned(
                left:_layout[i].x*size.width,top:_layout[i].y*size.height,
                width:_layout[i].width*size.width,
                height:_layout[i].height*size.height,
                child:Stack(children:[
                  Positioned.fill(child:GestureDetector(
                    onPanUpdate:(d)=>_move(i,d.delta,size),
                    child:DecoratedBox(
                      decoration:BoxDecoration(border:Border.all(
                        color:Colors.teal,width:1.5)),
                      child:Image.memory(_cropped[i]!,fit:BoxFit.fill)))),
                  Positioned(right:0,bottom:0,
                    child:GestureDetector(
                      behavior:HitTestBehavior.opaque,
                      onPanUpdate:(d)=>_move(i,d.delta,size,resize:true),
                      child:Container(width:26,height:26,
                        color:Colors.teal,
                        child:const Icon(Icons.open_in_full,
                          size:17,color:Colors.white)))),
                ]),
              ),
          ]));
        }),
      ))),
      Padding(padding:const EdgeInsets.all(12),child:Wrap(
        alignment:WrapAlignment.center,spacing:8,runSpacing:8,
        children:[
          OutlinedButton.icon(onPressed:()=>setState(()=>_arrange=false),
            icon:const Icon(Icons.crop),
            label:const Text('Back to Crop')),
          OutlinedButton.icon(onPressed:()=>setState(()=>
            _layout=IdCardPdfEngine.initialLayout(_cropped.length)),
            icon:const Icon(Icons.auto_awesome),
            label:const Text('Auto Arrange')),
          FilledButton(onPressed:_busy?null:()=>_export('cart'),
            child:const Text('Send to Cart')),
          FilledButton(onPressed:_busy?null:()=>_export('share'),
            child:const Text('Share')),
          FilledButton(onPressed:_busy?null:()=>_export('save'),
            child:const Text('Save PDF')),
        ],
      )),
    ]);
  }

  @override Widget build(BuildContext context){
    return Scaffold(
      appBar:AppBar(title:const Text('ID Card A4 Editor')),
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:_busy&&_original.isEmpty
          ?const Center(child:CircularProgressIndicator())
          :_error!=null
          ?Center(child:Text(_error!))
          :_original.isEmpty
          ?const Center(child:Text('Select ID card images'))
          :Stack(children:[
            Positioned.fill(child:_arrange?_layoutStep():_cropStep()),
            if(_busy)const Positioned(top:6,right:12,
              child:CircularProgressIndicator()),
          ])),
    );
  }
}

class _IdCropPainter extends CustomPainter {
  const _IdCropPainter(this.crop,{required this.perspective});
  final IdCardCrop crop;
  final bool perspective;
  @override void paint(Canvas canvas,Size size){
    final rect=crop.rect;
    final q=crop.quad??[rect.left,rect.top,rect.right,rect.top,
      rect.right,rect.bottom,rect.left,rect.bottom];
    final points=[for(var i=0;i<8;i+=2)Offset(
      q[i]*size.width,q[i+1]*size.height)];
    final p=Path();
    if(perspective){
      p.moveTo(points[0].dx,points[0].dy);
      for(var i=1;i<4;i++)p.lineTo(points[i].dx,points[i].dy);
      p.close();
    }else{
      p.addRect(Rect.fromLTRB(rect.left*size.width,rect.top*size.height,
        rect.right*size.width,rect.bottom*size.height));
    }
    final outline=Paint()..color=Colors.tealAccent..strokeWidth=2
      ..style=PaintingStyle.stroke;
    canvas.drawPath(p,outline);
    final handles=<Offset>[...points];
    if(!perspective){
      handles.addAll([
        Offset(rect.left*size.width,(rect.top+rect.bottom)*size.height/2),
        Offset((rect.left+rect.right)*size.width/2,rect.top*size.height),
        Offset(rect.right*size.width,(rect.top+rect.bottom)*size.height/2),
        Offset((rect.left+rect.right)*size.width/2,rect.bottom*size.height),
      ]);
    }
    for(final point in handles){
      canvas.drawCircle(point,5,Paint()..color=Colors.white);
      canvas.drawCircle(point,5,outline);
    }
  }
  @override bool shouldRepaint(covariant _IdCropPainter old)=>
    old.crop!=crop||old.perspective!=perspective;
}
