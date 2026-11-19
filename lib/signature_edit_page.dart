import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'file_transfer_camera_page.dart';
import 'signature_edit_engine.dart';
import 'image_editing_storage.dart';
import 'editor_transfer_session.dart';
import 'main.dart' show FileTheme;

/// Compact sibling of Image Editing: familiar preview + lower tool strip,
/// restricted to source, signature crop, filters and exact-size JPEG export.
class SignatureEditPage extends StatefulWidget {
  const SignatureEditPage({super.key,this.sourcePath,this.sourceName});
  final String? sourcePath,sourceName;
  @override State<SignatureEditPage> createState()=>_SignatureEditPageState();
}

class _SignatureEditPageState extends State<SignatureEditPage> {
  Uint8List? _original,_preview;
  String? _error;
  bool _busy=false;
  double _aspect=1.8;
  SignatureCrop _crop=SignatureCrop.full;
  String _filter='Original',_tool='Crop';
  int _target=20;
  final _targetController=TextEditingController(text:'20');
  final _picker=ImagePicker();
  static const _filters=['Original','Black & White','Grayscale',
    'Blue Ink','Dark Ink'];
  static const _tabs=['Crop','Compress','Filters'];
  String _cropMode='Normal';
  int _corner=-1; // 0..3 corners, 4..7 edge midpoints, -2 interior drag.
  Offset? _lastDrag;
  List<Offset> _quad=[const Offset(.08,.08),const Offset(.92,.08),
    const Offset(.92,.92),const Offset(.08,.92)];

  @override
  void initState(){
    super.initState();
    if(widget.sourcePath!=null) {
      unawaited(_load(File(widget.sourcePath!)));
    }
  }

  @override
  void dispose(){
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _load(File file)async{
    if(_busy)return;
    setState(()=>_busy=true);
    try {
      final bytes=await file.readAsBytes();
      final d=await compute(_signatureDimensions,bytes);
      if(!mounted)return;
      setState((){
        _original=bytes;
        _preview=bytes;
        _aspect=d[0]/d[1];
        _crop=SignatureCrop.full;
        _quad=[const Offset(.08,.08),const Offset(.92,.08),
          const Offset(.92,.92),const Offset(.08,.92)];
        _filter='Original';
        _error=null;
      });
    }catch(e){
      if(mounted)setState(()=>_error='Cannot open signature image: $e');
    }finally{if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _capture()async {
    try {
      if(Platform.isWindows) {
        final file=await Navigator.push<String>(context,
          MaterialPageRoute(builder:(_)=>const FileTransferCameraPage()));
        if(file!=null&&mounted)await _load(File(file));
      }else{
        final photo=await _picker.pickImage(source:ImageSource.camera,
          imageQuality:100);
        if(photo!=null&&mounted)await _load(File(photo.path));
      }
    }catch(e){_show('Camera failed: $e');}
  }

  Future<void> _browse()async{
    try{
      final chosen=await FilePicker.pickFiles(
        type:FileType.custom,allowedExtensions:['jpg','jpeg','png','webp','bmp']);
      if(chosen.isEmpty)return;
      final path=chosen.first.path;
      if(path==null)throw StateError('Image file was not readable');
      await _load(File(path));
    }catch(e){_show('Browse failed: $e');}
  }

  void _show(String message){
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content:Text(message)));
  }

  Future<void> _export(String action)async{
    if(_original==null||_busy)return;
    final target=int.tryParse(_targetController.text.trim());
    if(target==null||target<5||target>10240){
      _show('Enter a target between 5 KB and 10,240 KB');
      return;
    }
    setState(()=>_busy=true);
    try{
      final data=await SignatureEditEngine.exactJpeg(
        _original!,_selection,_filter,target);
      if(data.length!=target*1024)throw StateError('Exact size check failed');
      final name='Signature_${DateTime.now().millisecondsSinceEpoch}_${target}KB.jpg';
      if(action=='cart'){
        final root=await getApplicationSupportDirectory();
        final folder=Directory('${root.path}${Platform.pathSeparator}signature_cart');
        await folder.create(recursive:true);
        final file=File('${folder.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(data,flush:true);
        ImageEditingCart.instance.add(file,name);
        if(mounted)returnToFileShareCart(context);
      }else if(action=='share'){
        final cache=await getTemporaryDirectory();
        final file=File('${cache.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(data,flush:true);
        await SharePlus.instance.share(ShareParams(files:[XFile(file.path)]));
      }else{
        final path=await FilePicker.saveFile(fileName:name,bytes:data,
          mimeType:'image/jpeg');
        if(path!=null)_show('Saved exactly $target KB (${data.length} bytes)');
      }
    }catch(e){
      _show('Exact-size export unavailable: $e');
    }finally{if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _changeFilter(String filter)async{
    if(_original==null||_busy)return;
    setState(()=>_busy=true);
    try{
      final result=await SignatureEditEngine.preview(
        _original!,SignatureCrop.full,filter);
      if(mounted)setState((){
        _filter=filter;
        _preview=result;
      });
    }catch(e){_show('Filter failed: $e');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  SignatureCrop get _selection => _cropMode=='Perspective'
    ? SignatureCrop(0,0,1,1,quad:[
        for(final p in _quad)...[p.dx,p.dy],
      ]) : _crop;

  void _setMode(String value) => setState((){
    _cropMode=value;
    _corner=-1;
    _lastDrag=null;
  });

  void _gestureStart(DragStartDetails d,Size size){
    final p=Offset((d.localPosition.dx/size.width).clamp(0.0,1.0).toDouble(),
      (d.localPosition.dy/size.height).clamp(0.0,1.0).toDouble());
    final points=_cropMode=='Perspective'
      ? _quad
      : [Offset(_crop.left,_crop.top),Offset(_crop.right,_crop.top),
          Offset(_crop.right,_crop.bottom),Offset(_crop.left,_crop.bottom)];
    final edges=[for(var i=0;i<4;i++)
      (points[i]+points[(i+1)%4])/2];
    _corner=-1;
    // Screen-space hit areas are consistent on wide and tall photos.
    for(var i=0;i<8;i++){
      final c=i<4?points[i]:edges[i-4];
      if((c.dx-p.dx).abs()*size.width<24 &&
         (c.dy-p.dy).abs()*size.height<24) {
        _corner=i;break;
      }
    }
    if(_corner==-1 && _insidePolygon(p,points)) _corner=-2;
    _lastDrag=p;
  }

  bool _insidePolygon(Offset p,List<Offset> pts){
    var inside=false;
    for(var i=0,j=pts.length-1;i<pts.length;j=i++){
      final a=pts[i],b=pts[j];
      if((a.dy>p.dy)!=(b.dy>p.dy) &&
        p.dx<(b.dx-a.dx)*(p.dy-a.dy)/(b.dy-a.dy)+a.dx)inside=!inside;
    }
    return inside;
  }

  void _gestureUpdate(DragUpdateDetails d,Size size){
    if(_corner==-1)return;
    final p=Offset((d.localPosition.dx/size.width).clamp(0.0,1.0).toDouble(),
      (d.localPosition.dy/size.height).clamp(0.0,1.0).toDouble());
    final previous=_lastDrag??p;
    _lastDrag=p;
    const gap=.025;
    if(_cropMode=='Perspective'){
      final next=List<Offset>.from(_quad);
      if(_corner==-2){
        var dx=p.dx-previous.dx,dy=p.dy-previous.dy;
        dx=dx.clamp(-next.map((v)=>v.dx).reduce(math.min),
          1-next.map((v)=>v.dx).reduce(math.max)).toDouble();
        dy=dy.clamp(-next.map((v)=>v.dy).reduce(math.min),
          1-next.map((v)=>v.dy).reduce(math.max)).toDouble();
        for(var i=0;i<4;i++)next[i]+=Offset(dx,dy);
      }else if(_corner<4){
        next[_corner]=p;
      }else{
        final a=_corner-4,b=(a+1)%4;
        final delta=p-(next[a]+next[b])/2;
        next[a]=Offset((next[a].dx+delta.dx).clamp(0.0,1.0).toDouble(),
          (next[a].dy+delta.dy).clamp(0.0,1.0).toDouble());
        next[b]=Offset((next[b].dx+delta.dx).clamp(0.0,1.0).toDouble(),
          (next[b].dy+delta.dy).clamp(0.0,1.0).toDouble());
      }
      double area=0;
      for(var i=0;i<4;i++){
        final j=(i+1)%4;
        area+=next[i].dx*next[j].dy-next[j].dx*next[i].dy;
      }
      if(area.abs()>.01)setState(()=>_quad=next);
    }else{
      final c=_crop;
      var l=c.left,t=c.top,r=c.right,b=c.bottom;
      if(_corner==-2){
        final dx=(p.dx-previous.dx).clamp(-l,1-r).toDouble();
        final dy=(p.dy-previous.dy).clamp(-t,1-b).toDouble();
        l+=dx;r+=dx;t+=dy;b+=dy;
      }else{
        if(_corner==0||_corner==3||_corner==7)l=p.dx.clamp(0.0,r-gap).toDouble();
        if(_corner==1||_corner==2||_corner==5)r=p.dx.clamp(l+gap,1.0).toDouble();
        if(_corner==0||_corner==1||_corner==4)t=p.dy.clamp(0.0,b-gap).toDouble();
        if(_corner==2||_corner==3||_corner==6)b=p.dy.clamp(t+gap,1.0).toDouble();
      }
      setState(()=>_crop=SignatureCrop(l,t,r,b));
    }
  }

  Widget _editorCanvas(){
    final image=_preview??_original;
    if(image==null) {
      return Center(child:Column(mainAxisSize:MainAxisSize.min,children:[
        Icon(Icons.draw_outlined,size:75,color:FileTheme.violet),
        const SizedBox(height:12),
        const Text('Capture or browse a signature to edit'),
        const SizedBox(height:16),
        Wrap(spacing:10,children:[
          FilledButton.icon(onPressed:_capture,
            icon:const Icon(Icons.camera_alt_outlined),
            label:const Text('Camera')),
          OutlinedButton.icon(onPressed:_browse,
            icon:const Icon(Icons.folder_open_outlined),
            label:const Text('Browse')),
        ]),
      ]));
    }
    return Center(child:LayoutBuilder(builder:(context,bounds){
      final maxW=math.max(1.0,bounds.maxWidth-24);
      final maxH=math.max(1.0,bounds.maxHeight-24);
      final width=math.min(maxW,maxH*_aspect);
      final height=width/_aspect;
      final size=Size(width,height);
      return SizedBox(width:width,height:height,
        child:GestureDetector(
          behavior:HitTestBehavior.opaque,
          onPanStart:_busy?null:(d)=>_gestureStart(d,size),
          onPanUpdate:_busy?null:(d)=>_gestureUpdate(d,size),
          onPanEnd:(_){_lastDrag=null;_corner=-1;},
          child:Stack(fit:StackFit.expand,children:[
            Image.memory(image,fit:BoxFit.fill,gaplessPlayback:true,
              filterQuality:FilterQuality.medium),
            CustomPaint(painter:_SignatureCropPainter(
              _selection,showQuad:_cropMode=='Perspective')),
          ]),
        ),
      );
    }));
  }

  Widget _controls(){
    if(_tool=='Crop'){
      return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('Crop Signature',style:TextStyle(
          fontWeight:FontWeight.w800,fontSize:16)),
        const SizedBox(height:6),
        const Text('Drag corners, side-midpoints or the selection interior. '
          'Perspective moves each corner independently.'),
        const SizedBox(height:8),
        SegmentedButton<String>(
          showSelectedIcon:false,
          segments:const [
            ButtonSegment(value:'Normal',label:Text('Normal Crop')),
            ButtonSegment(value:'Perspective',label:Text('Perspective Crop')),
          ],
          selected:{_cropMode},
          onSelectionChanged:_busy?null:(choice)=>_setMode(choice.first)),
        const SizedBox(height:12),
        OutlinedButton.icon(
          onPressed:()=>setState((){
            _crop=SignatureCrop.full;
            _quad=[const Offset(.08,.08),const Offset(.92,.08),
              const Offset(.92,.92),const Offset(.08,.92)];
          }),
          icon:const Icon(Icons.restart_alt),
          label:const Text('Reset Crop')),
      ]);
    }
    if(_tool=='Compress'){
      return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('Exact Export Size',style:TextStyle(
          fontWeight:FontWeight.w800,fontSize:16)),
        const SizedBox(height:7),
        TextField(controller:_targetController,
          keyboardType:TextInputType.number,
          decoration:const InputDecoration(
            labelText:'Target size in KB',hintText:'20',
            suffixText:'KB',border:OutlineInputBorder()),
          onChanged:(value)=>setState(()=>_target=int.tryParse(value)??20)),
        const SizedBox(height:10),
        Wrap(spacing:8,runSpacing:8,children:[
          for(final kb in [5,10,20,30,50,100,200])
            ChoiceChip(label:Text('$kb KB'),
              selected:_target==kb,
              onSelected:(_){
                _targetController.text=kb.toString();
                setState(()=>_target=kb);
              }),
        ]),
        const SizedBox(height:8),
        Text('Exactly N × 1024 bytes. If a readable signature cannot fit, '
          'the export shows an error instead of creating the wrong size.',
          style:TextStyle(fontSize:12,color:FileTheme.muted(context))),
      ]);
    }
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('Signature Filters',style:TextStyle(
        fontWeight:FontWeight.w800,fontSize:16)),
      const Text('Crop handles remain active while applying filters.'),
      const SizedBox(height:10),
      Wrap(spacing:9,runSpacing:9,children:[
        for(final filter in _filters)ChoiceChip(
          label:Text(filter),selected:_filter==filter,
          onSelected:_busy?null:(_)=>_changeFilter(filter)),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context){
    final ready=_original!=null;
    return Scaffold(
      appBar:AppBar(
        title:const Text('Signature Edit',style:TextStyle(fontSize:16)),
        actions:[
          IconButton(tooltip:'Take photo',onPressed:_busy?null:_capture,
            icon:const Icon(Icons.camera_alt_outlined)),
          IconButton(tooltip:'Browse image',onPressed:_busy?null:_browse,
            icon:const Icon(Icons.folder_open_outlined)),
          IconButton(tooltip:'Save exact size',onPressed:ready&&!_busy
            ?()=>_export('save'):null,
            icon:const Icon(Icons.download_rounded)),
          IconButton(tooltip:'Share signature',onPressed:ready&&!_busy
            ?()=>_export('share'):null,
            icon:const Icon(Icons.ios_share_rounded)),
          IconButton(tooltip:'Add to File Share Cart',onPressed:ready&&!_busy
            ?()=>_export('cart'):null,
            icon:const Icon(Icons.shopping_cart_outlined)),
        ]),
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:Column(children:[
          Expanded(child:Padding(
            padding:const EdgeInsets.all(16),
            child:Container(
              decoration:BoxDecoration(
                color:Theme.of(context).cardColor,
                borderRadius:BorderRadius.circular(24),
                border:Border.all(color:FileTheme.violet.withValues(alpha:.17))),
              child:Stack(children:[
                Positioned.fill(child:_editorCanvas()),
                if(_busy)const Positioned.fill(
                  child:Center(child:CircularProgressIndicator())),
              ]),
            ))),
          if(_error!=null)Padding(
            padding:const EdgeInsets.symmetric(horizontal:16),
            child:Text(_error!,style:TextStyle(
              color:Theme.of(context).colorScheme.error))),
          ConstrainedBox(constraints:const BoxConstraints(maxHeight:220),
            child:SingleChildScrollView(
              padding:const EdgeInsets.symmetric(horizontal:18,vertical:10),
              child:_controls())),
          SafeArea(top:false,child:Container(
            margin:const EdgeInsets.fromLTRB(14,8,14,12),
            padding:const EdgeInsets.all(5),
            decoration:BoxDecoration(
              color:Theme.of(context).cardColor,
              borderRadius:BorderRadius.circular(24),
              border:Border.all(color:FileTheme.violet.withValues(alpha:.25))),
            child:Row(children:[
              for(final tab in _tabs)Expanded(child:InkWell(
                borderRadius:BorderRadius.circular(18),
                onTap:()=>setState(()=>_tool=tab),
                child:Container(
                  padding:const EdgeInsets.symmetric(vertical:13),
                  decoration:BoxDecoration(
                    color:_tool==tab?FileTheme.violet.withValues(alpha:.17):null,
                    borderRadius:BorderRadius.circular(18)),
                  child:Column(mainAxisSize:MainAxisSize.min,children:[
                    Icon(switch(tab) {
                      'Crop'=>Icons.crop_rounded,
                      'Compress'=>Icons.compress_rounded,
                      _=>Icons.filter_rounded,
                    },color:FileTheme.violet,size:24),
                    const SizedBox(height:4),
                    Text(tab,textAlign:TextAlign.center,
                      style:const TextStyle(fontSize:12,
                        fontWeight:FontWeight.w600)),
                  ]),
                ),
              )),
            ]),
          )),
        ]),
      ),
    );
  }
}

List<int> _signatureDimensions(Uint8List bytes){
  final decoded=img.decodeImage(bytes);
  if(decoded==null)throw const FormatException('Invalid image');
  return [decoded.width,decoded.height];
}

class _SignatureCropPainter extends CustomPainter {
  const _SignatureCropPainter(this.crop,{this.showQuad=false});
  final SignatureCrop crop;
  final bool showQuad;
  @override void paint(Canvas canvas,Size size){
    final pts=showQuad && crop.quad!=null
      ? [for(var i=0;i<8;i+=2)
          Offset(crop.quad![i]*size.width,crop.quad![i+1]*size.height)]
      : [Offset(crop.left*size.width,crop.top*size.height),
          Offset(crop.right*size.width,crop.top*size.height),
          Offset(crop.right*size.width,crop.bottom*size.height),
          Offset(crop.left*size.width,crop.bottom*size.height)];
    final polygon=Path()..moveTo(pts[0].dx,pts[0].dy);
    for(var i=1;i<4;i++)polygon.lineTo(pts[i].dx,pts[i].dy);
    polygon.close();
    final shade=Paint()..color=Colors.black.withValues(alpha:.40);
    final surround=Path()..addRect(Offset.zero & size);
    canvas.drawPath(Path.combine(PathOperation.difference,surround,polygon),shade);
    canvas.drawPath(polygon,Paint()..color=FileTheme.violet
      ..style=PaintingStyle.stroke..strokeWidth=2.5);
    final handles=[...pts,for(var i=0;i<4;i++)
      (pts[i]+pts[(i+1)%4])/2];
    for(final pos in handles){
      canvas.drawCircle(pos,7,Paint()..color=Colors.white);
      canvas.drawCircle(pos,7,Paint()
        ..color=FileTheme.violet..style=PaintingStyle.stroke..strokeWidth=2);
    }
  }
  @override bool shouldRepaint(covariant _SignatureCropPainter old)=>
    old.crop.left!=crop.left||old.crop.top!=crop.top||
    old.crop.right!=crop.right||old.crop.bottom!=crop.bottom||
    old.showQuad!=showQuad||old.crop.quad.toString()!=crop.quad.toString();
}
