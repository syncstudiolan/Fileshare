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
  int _corner=-1;
  Offset? _lastDrag;

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
    if(target==null||target<1||target>10240){
      _show('Enter a target between 1 KB and 10,240 KB');
      return;
    }
    setState(()=>_busy=true);
    try{
      final data=await SignatureEditEngine.exactJpeg(
        _original!,_crop,_filter,target);
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
        _original!,_crop,filter);
      if(mounted)setState((){
        _filter=filter;
        _preview=result;
      });
    }catch(e){_show('Filter failed: $e');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  void _gestureStart(DragStartDetails d,Size size){
    final x=(d.localPosition.dx/size.width).clamp(0.0,1.0);
    final y=(d.localPosition.dy/size.height).clamp(0.0,1.0);
    final corners=[
      Offset(_crop.left,_crop.top),Offset(_crop.right,_crop.top),
      Offset(_crop.right,_crop.bottom),Offset(_crop.left,_crop.bottom)];
    _corner=-1;
    for(var i=0;i<corners.length;i++){
      if((corners[i]-Offset(x,y)).distance<.095){_corner=i;break;}
    }
    _lastDrag=Offset(x,y);
  }

  void _gestureUpdate(DragUpdateDetails d,Size size){
    final x=(d.localPosition.dx/size.width).clamp(0.0,1.0);
    final y=(d.localPosition.dy/size.height).clamp(0.0,1.0);
    final p=Offset(x,y),last=_lastDrag??p;
    _lastDrag=p;
    const gap=.04;
    final c=_crop;
    double l=c.left,t=c.top,r=c.right,b=c.bottom;
    if(_corner==-1){
      final dx=(x-last.dx).clamp(-1.0,1.0);
      final dy=(y-last.dy).clamp(-1.0,1.0);
      l=(l+dx).clamp(0.0,1-(r-l));
      t=(t+dy).clamp(0.0,1-(b-t));
      r=l+(c.right-c.left);
      b=t+(c.bottom-c.top);
    } else {
      if(_corner==0||_corner==3)l=x.clamp(0.0,r-gap);
      if(_corner==1||_corner==2)r=x.clamp(l+gap,1.0);
      if(_corner==0||_corner==1)t=y.clamp(0.0,b-gap);
      if(_corner==2||_corner==3)b=y.clamp(t+gap,1.0);
    }
    setState(()=>_crop=SignatureCrop(l,t,r,b));
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
          onPanStart:_tool=='Crop'?(d)=>_gestureStart(d,size):null,
          onPanUpdate:_tool=='Crop'?(d)=>_gestureUpdate(d,size):null,
          onPanEnd:_tool=='Crop'?(_)=>_lastDrag=null:null,
          child:Stack(fit:StackFit.expand,children:[
            Image.memory(image,fit:BoxFit.fill,gaplessPlayback:true,
              filterQuality:FilterQuality.medium),
            if(_tool=='Crop')CustomPaint(
              painter:_SignatureCropPainter(_crop)),
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
        const Text('Drag the corners to select the signature. Drag inside to move.'),
        const SizedBox(height:12),
        OutlinedButton.icon(
          onPressed:()=>setState(()=>_crop=SignatureCrop.full),
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
          onChanged:(value)=>_target=int.tryParse(value)??20),
        const SizedBox(height:10),
        Wrap(spacing:8,runSpacing:8,children:[
          for(final kb in [10,20,30,50,100,200])
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
      )),
    );
  }
}

List<int> _signatureDimensions(Uint8List bytes){
  final decoded=img.decodeImage(bytes);
  if(decoded==null)throw const FormatException('Invalid image');
  return [decoded.width,decoded.height];
}

class _SignatureCropPainter extends CustomPainter {
  const _SignatureCropPainter(this.crop);
  final SignatureCrop crop;
  @override
  void paint(Canvas canvas,Size size){
    final rect=Rect.fromLTRB(crop.left*size.width,crop.top*size.height,
      crop.right*size.width,crop.bottom*size.height);
    final shade=Paint()..color=Colors.black.withValues(alpha:.40);
    final hole=Path()..addRect(rect);
    final surround=Path()..addRect(Offset.zero & size);
    canvas.drawPath(Path.combine(PathOperation.difference,surround,hole),shade);
    canvas.drawRect(rect,Paint()..color=FileTheme.violet
      ..style=PaintingStyle.stroke..strokeWidth=2.5);
    final handles=[
      rect.topLeft,rect.topRight,rect.bottomRight,rect.bottomLeft];
    for(final pos in handles){
      canvas.drawCircle(pos,7,Paint()..color=Colors.white);
      canvas.drawCircle(pos,7,Paint()
        ..color=FileTheme.violet..style=PaintingStyle.stroke..strokeWidth=2);
    }
  }
  @override
  bool shouldRepaint(covariant _SignatureCropPainter old)=>
    old.crop.left!=crop.left||old.crop.top!=crop.top||
    old.crop.right!=crop.right||old.crop.bottom!=crop.bottom;
}
