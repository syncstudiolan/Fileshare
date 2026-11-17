import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'main.dart' show FileTheme, fadePage;
import 'image_editing_engine.dart';
import 'image_editing_storage.dart';
import 'image_editing_windows_ai.dart';

/// File Share's native-feeling editing workspace. The main canvas, transition
/// animations and controls are Flutter GPU rendered; expensive file encodes and
/// pixel operations happen on a worker isolate.
class ImageEditingPage extends StatefulWidget {
  const ImageEditingPage({super.key,this.sourcePath,this.sourceName,this.draft});
  final String? sourcePath,sourceName;
  final ImageEditingDraft? draft;
  @override
  State<ImageEditingPage> createState()=>_ImageEditingPageState();
}

class _ImageEditingPageState extends State<ImageEditingPage> {
  Uint8List? _bytes;
  Uint8List? _originalBytes;
  Uint8List? _cutoutBytes;
  String? _error;
  bool _busy=false, _cropResize=false, _showOriginal=false;
  bool _imagePickerBusy=false;
  String? _selectedFilter;
  Uint8List? _filterBase;
  final TransformationController _transformController=TransformationController();
  double _zoom=1.0;
  String _tool='Background';
  String _format='PNG';
  String? _draftId;
  late String _name;
  final List<Uint8List> _undo=[], _redo=[];
  final List<String> _steps=[];
  double _ratio=1, _brightness=1, _contrast=1,_saturation=1,_exposure=0;
  double _eraseRadius=.035,_softness=.45, _tolerance=42;
  Rect _crop=const Rect.fromLTWH(.06,.06,.88,.88);
  List<Offset> _cropCorners=[const Offset(.06,.06),const Offset(.94,.06),
    const Offset(.94,.94),const Offset(.06,.94)];
  int? _activeCropHandle;
  final List<Offset> _stroke=[];
  int _quality=85,_targetKb=500;
  Color _background=Colors.white;
  Color _custom=const Color(0xFF7D5BE3);

  static const _tools=['Background','Compress','Crop','Filters','Erase','Adjust'];
  static const _colors=[Colors.transparent,Colors.white,Colors.black,
    Color(0xFFE84D9F), Color(0xFF765ADB),Color(0xFFE53935),
    Color(0xFF1E88E5),Color(0xFF43A047),Color(0xFFFFEB3B)];

  @override
  void initState(){
    super.initState();
    _name=widget.sourceName??widget.draft?.name??'edited-image.png';
    unawaited(_load());
  }
  @override void dispose(){
    _transformController.dispose();
    super.dispose();
  }
  void _changeZoom(double factor){
    _zoom=(_zoom*factor).clamp(1.0,6.0).toDouble();
    _transformController.value=Matrix4.diagonal3Values(_zoom,_zoom,1);
    if(mounted)setState((){});
  }
  void _resetZoom(){
    _zoom=1.0;
    _transformController.value=Matrix4.identity();
    if(mounted)setState((){});
  }
  Future<void> _load() async {
    try {
      await ImageEditingHistory.instance.load();
      final path=widget.draft?.filePath??widget.sourcePath;
      if(path==null)return; // Empty canvas: Camera and Browse stay visible.
      final bytes=await File(path).readAsBytes();
      final dimensions=await ImageEditingEngine.dimensions(bytes);
      _draftId=widget.draft?.id??
        DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      _steps.addAll(widget.draft?.steps??[]);
      _ratio=dimensions[0]/dimensions[1];
      if(mounted)setState((){
        _bytes=Uint8List.fromList(bytes);
        _originalBytes=Uint8List.fromList(bytes);
        _cutoutBytes=null;
      });
      if(widget.draft==null)await _saveDraft();
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }

  Future<void> _chooseSource({required bool camera}) async {
    if(_busy || _imagePickerBusy)return;
    setState(()=>_imagePickerBusy=true);
    try{
      String? path;
      String? name;
      if(camera){
        if(!Platform.isAndroid && !Platform.isIOS){
          _message('Camera capture is available on Android. Use Browse on Windows.');
          return;
        }
        final taken=await ImagePicker().pickImage(source:ImageSource.camera,
          imageQuality:100);
        if(taken==null)return;
        path=taken.path;
        name=taken.name;
      }else{
        final selection=await FilePicker.pickFiles(type:FileType.image);
        if(selection.isEmpty)return;
        final picked=selection.first;
        path=picked.path;
        name=picked.name;
        if(path==null){
          final folder=await getApplicationSupportDirectory();
          final target=File('${folder.path}${Platform.pathSeparator}'
            'editing_import_${DateTime.now().microsecondsSinceEpoch}.bin');
          await target.writeAsBytes(await picked.readAsBytes(),flush:true);
          path=target.path;
        }
      }
      if(path==null)throw StateError('No file selected');
      final bytes=await File(path).readAsBytes();
      final dimensions=await ImageEditingEngine.dimensions(bytes);
      if(!mounted)return;
      setState((){
        _bytes=Uint8List.fromList(bytes);
        _originalBytes=Uint8List.fromList(bytes);
        _ratio=dimensions[0]/dimensions[1];
        _name=name??'image.png';
        _draftId=DateTime.now().microsecondsSinceEpoch.toRadixString(36);
        _undo.clear();_redo.clear();_steps.clear();
        _crop=const Rect.fromLTWH(.06,.06,.88,.88);
      _cropCorners=[const Offset(.06,.06),const Offset(.94,.06),
        const Offset(.94,.94),const Offset(.06,.94)];
        _error=null;
        _showOriginal=false;
      });
      await _saveDraft();
    }catch(_){
      _message('Could not open this image. Try a JPG or PNG.');
    }finally{if(mounted)setState(()=>_imagePickerBusy=false);}
  }

  Future<void> _saveDraft() async {
    final bytes=_bytes,id=_draftId;
    if(bytes==null||id==null)return;
    await ImageEditingHistory.instance.save(id:id,name:_name,
      bytes:bytes,steps:_steps);
  }

  Future<void> _apply(String action, Map<String,Object?> options,
      {String? description}) async {
    final bytes=_bytes;
    if(bytes==null||_busy)return;
    setState(()=>_busy=true);
    try{
      final next=await ImageEditingEngine.edit(bytes,action,options);
      await _commit(bytes,next,description??action);
    }catch(e){_message('Editing failed: $e');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _commit(Uint8List previous,Uint8List next,String step) async {
    if(!mounted)return;
    _undo.add(previous);
    if(_undo.length>15)_undo.removeAt(0);
    _redo.clear();
    _steps.add(step);
    final dimensions=await ImageEditingEngine.dimensions(next);
    if(!mounted)return;
    setState((){
      _bytes=next;
      _ratio=dimensions[0]/dimensions[1];
      _crop=const Rect.fromLTWH(.06,.06,.88,.88);
      _cropCorners=[const Offset(.06,.06),const Offset(.94,.06),
        const Offset(.94,.94),const Offset(.06,.94)];
    });
    await _saveDraft();
  }

  Future<void> _historyStep(bool undo) async {
    final source=undo?_undo:_redo;
    final current=_bytes;
    if(source.isEmpty||current==null||_busy)return;
    final next=source.removeLast();
    (undo?_redo:_undo).add(current);
    if(_steps.isNotEmpty && undo)_steps.removeLast();
    final size=await ImageEditingEngine.dimensions(next);
    if(!mounted)return;
    setState((){
      _bytes=next;
      _ratio=size[0]/size[1];
      _crop=const Rect.fromLTWH(.06,.06,.88,.88);
      _cropCorners=[const Offset(.06,.06),const Offset(.94,.06),
        const Offset(.94,.94),const Offset(.06,.94)];
    });
    await _saveDraft();
  }

  /// Prefer ML Kit for portraits. If the installed Android ML Kit/R8 stack
  /// throws (as on the reported release device), run a verified portable
  /// ONNX model instead of surfacing a raw Java stack trace.
  Future<void> _removeBackground() async {
    final data=_bytes;
    if(data==null||_busy)return;
    setState(()=>_busy=true);
    try{
      late Uint8List mask;
      late int width,height;
      var engine='U²-NetP AI';
      if(Platform.isAndroid){
        try{
          final dir=await getTemporaryDirectory();
          final temporary=File('${dir.path}/segment_${DateTime.now().microsecondsSinceEpoch}.png');
          await temporary.writeAsBytes(data,flush:true);
          final segmenter=SelfieSegmenter(mode:SegmenterMode.single);
          try{
            final result=await segmenter.processImage(
              InputImage.fromFilePath(temporary.path));
            if(result==null || result.width<=0 || result.height<=0 ||
               result.confidences.length!=result.width*result.height){
              throw const FormatException('ML Kit subject mask is invalid');
            }
            width=result.width;height=result.height;
            mask=Uint8List.fromList(result.confidences.map(
              (confidence)=>(confidence.clamp(0.0,1.0)*255).round()).toList());
            engine='Google ML Kit';
          }finally{
            await segmenter.close();
            if(await temporary.exists())await temporary.delete();
          }
        }catch(_){
          // A failed Android platform call is not a user-facing crash.
          // The model is downloaded once, hash-verified, then used offline.
          width=WindowsBackgroundAi.modelSize;
          height=WindowsBackgroundAi.modelSize;
          mask=await WindowsBackgroundAi.segmentationMask(data);
        }
      }else if(Platform.isWindows){
        width=WindowsBackgroundAi.modelSize;
        height=WindowsBackgroundAi.modelSize;
        mask=await WindowsBackgroundAi.segmentationMask(data);
      }else{
        final dimensions=await ImageEditingEngine.dimensions(data);
        width=dimensions[0];height=dimensions[1];
        mask=await ImageEditingEngine.simpleBackgroundMask(
          data,tolerance:_tolerance);
        engine='Plain background remover';
      }
      final edited=await ImageEditingEngine.edit(data,'background',{
        'mask':mask,'maskWidth':width,'maskHeight':height,
      });
      await _commit(data,edited,'Background removal — $engine');
      _cutoutBytes=edited; // Preserve transparency for switching colors.
      if(mounted)setState(()=>_format='PNG');
      _message('Background removed with $engine');
    }catch(_){
      _message('AI background removal could not finish. Check internet for '
        'the first AI model download, or try Remove Plain Background.');
    }finally{
      if(mounted)setState(()=>_busy=false);
    }
  }

  Future<void> _removePlainBackground()async{
    final data=_bytes;
    if(data==null||_busy)return;
    setState(()=>_busy=true);
    try {
      final dimensions=await ImageEditingEngine.dimensions(data);
      final mask=await ImageEditingEngine.simpleBackgroundMask(
        data,tolerance:_tolerance);
      final result=await ImageEditingEngine.edit(data,'background',{
        'mask':mask,'maskWidth':dimensions[0],'maskHeight':dimensions[1],
      });
      await _commit(data,result,'Remove plain-color background');
      _format='PNG';
    }catch(e){_message('Plain background removal failed: $e');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _replaceBackground({Uint8List? picture,Color? color})async {
    if(_busy||_bytes==null)return;
    final selected=color??_background;
    // A preset or Gallery background must work even if the user has not
    // explicitly pressed Remove Background beforehand.
    if(_cutoutBytes==null){
      await _removeBackground();
      if(_cutoutBytes==null)return;
    }
    final previous=_bytes!;
    setState(()=>_busy=true);
    try{
      final next=selected==Colors.transparent && picture==null
        ?_cutoutBytes!
        :await ImageEditingEngine.edit(_cutoutBytes!,'flatten',{
          'color':selected.toARGB32(),
          if(picture!=null)'backgroundBytes':picture,
        });
      await _commit(previous,next,'Background replacement');
      if(mounted)setState((){
        _background=selected;
        _format='PNG';
      });
    }catch(_){
      _message('Could not replace this background. Try a different image.');
    }finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _pickBackground()async{
    try{
      final picked=await FilePicker.pickFiles(type:FileType.image);
      if(picked.isEmpty)return;
      final first=picked.first;
      final path=first.path;
      await _replaceBackground(picture:path==null
        ?await first.readAsBytes():await File(path).readAsBytes());
    }catch(e){_message('Choose background failed: $e');}
  }

  Future<void> _compress()async{
    final bytes=_bytes;
    if(bytes==null||_busy)return;
    setState(()=>_busy=true);
    try{
      final result=await ImageEditingEngine.compress(bytes,
        targetKb:_targetKb,quality:_quality,format:_format);
      if(_format=='JPEG')_name=_name.replaceAll(
        RegExp(r'\.[^.]+$'),'.jpg');
      if(_format=='PNG')_name=_name.replaceAll(
        RegExp(r'\.[^.]+$'),'.png');
      await _commit(bytes,result,'Compress $_targetKb KB ($_format)');
      _message('Exported ${(result.length/1024).toStringAsFixed(1)} KB');
    }catch(e){_message('Compression failed: $e');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _export(String action)async {
    final data=_bytes;
    if(data==null||_busy)return;
    try{
      final type=data.length>=2 && data[0]==0xff && data[1]==0xd8
        ?'jpg':'png';
      final name='edited_${DateTime.now().millisecondsSinceEpoch}.$type';
      if(action=='cart'){
        final directory=await getApplicationSupportDirectory();
        final cart=Directory('${directory.path}${Platform.pathSeparator}image_editing_cart');
        await cart.create(recursive:true);
        final path=File('${cart.path}${Platform.pathSeparator}$name');
        await path.writeAsBytes(data,flush:true);
        ImageEditingCart.instance.add(path,name);
        _message('Image added to File Share Cart');
      }else if(action=='share'){
        final directory=await getTemporaryDirectory();
        final file=File('${directory.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(data);
        await SharePlus.instance.share(ShareParams(files:[XFile(file.path)]));
      }else{
        final saved=await FilePicker.saveFile(
          fileName:name,bytes:data,
          mimeType:type=='jpg'?'image/jpeg':'image/png');
        if(saved!=null)_message('Image saved successfully');
      }
    }catch(e){_message('Export failed: $e');}
  }

  void _message(String value){
    if(!mounted)return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content:Text(value),duration:const Duration(seconds:3)));
  }

  Widget _slider(String title,double value,double min,double max,
      ValueChanged<double> onChanged,VoidCallback onCommit){
    return Padding(padding:const EdgeInsets.symmetric(vertical:4),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
          Text(title,style:const TextStyle(fontWeight:FontWeight.w600)),
          Text(value.toStringAsFixed(2)),
        ]),
        Slider(value:value,min:min,max:max,onChanged:onChanged,
          onChangeEnd:(_)=>onCommit()),
      ]));
  }

  Widget _toolControls(){
    switch(_tool){
      case 'Background':
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(Platform.isAndroid?'Fast recommended: Google ML Kit':
            Platform.isWindows?'Windows: U²-NetP on-device AI (4.6 MB first download)':
            'Plain-color background remover',
            style:TextStyle(color:FileTheme.muted(context))),
          const SizedBox(height:10),
          FilledButton.icon(onPressed:_busy?null:_removeBackground,
            icon:const Icon(Icons.auto_fix_high),
            label:const Text('AI Remove Background')),
          if(true) ...[
            const SizedBox(height:8),
            _slider('Plain background tolerance',_tolerance,5,120,
              (v)=>setState(()=>_tolerance=v),(){}),
            OutlinedButton.icon(
              onPressed:_busy?null:_removePlainBackground,
              icon:const Icon(Icons.colorize_outlined),
              label:const Text('Remove plain-color background')),
          ],
          const SizedBox(height:16),
          const Text('Replace background',style:TextStyle(fontWeight:FontWeight.bold)),
          const SizedBox(height:7),
          Wrap(spacing:8,runSpacing:8,children:[
            for(final color in _colors)
              InkWell(onTap:_busy?null:()=>_replaceBackground(color:color),
                child:CircleAvatar(radius:18,backgroundColor:color==Colors.transparent
                  ?Colors.grey.shade300:color,
                  child:color==_background?const Icon(Icons.check,size:18):null)),
          ]),
          const SizedBox(height:8),
          Wrap(spacing:8,runSpacing:8,children:[
            OutlinedButton.icon(onPressed:_busy?null:_pickBackground,
              icon:const Icon(Icons.photo_library_outlined),
              label:const Text('Gallery background')),
            const SizedBox(width:8),
            OutlinedButton.icon(onPressed:_busy?null:()=>_customColorDialog(),
              icon:const Icon(Icons.palette_outlined),label:const Text('Custom')),
          ]),
        ]);
      case 'Compress':
        return Column(children:[
          Row(children:[
            const Text('Format'),const SizedBox(width:20),
            DropdownButton<String>(value:_format,
              items:const ['PNG','JPEG'].map((x)=>DropdownMenuItem(
                value:x,child:Text(x))).toList(),
              onChanged:(x){if(x!=null)setState(()=>_format=x);}),
          ]),
          _slider('Quality',_quality.toDouble(),5,100,
            (v)=>setState(()=>_quality=v.round()),(){}),
          TextFormField(
            initialValue:_targetKb.toString(),
            keyboardType:TextInputType.number,
            decoration:const InputDecoration(
              labelText:'Target file size (KB)',
              helperText:'Enter any value from 1 to 500000 KB; quality may need to decrease.'),
            onChanged:(v){
              final n=int.tryParse(v);
              if(n!=null && n>=1 && n<=500000)_targetKb=n;
            }),
          const SizedBox(height:12),
          FilledButton.icon(onPressed:_busy?null:_compress,
            icon:const Icon(Icons.compress_rounded),label:const Text('Compress')),
        ]);
      case 'Crop':
        return Column(children:[
          const Text('Drag the crop rectangle or its corner to resize'),
          const SizedBox(height:12),
          Wrap(spacing:8,children:[
            for(final label in ['Free','1:1','4:3','16:9','A4'])
              ChoiceChip(label:Text(label),
                selected:_cropRatio==label,
                onSelected:(_)=>_setCropRatio(label)),
          ]),
          const SizedBox(height:8),
          Wrap(spacing:8,children:[
            OutlinedButton.icon(onPressed:()=>_apply('rotate',{'degrees':90}),
              icon:const Icon(Icons.rotate_right),label:const Text('Rotate')),
            OutlinedButton.icon(onPressed:()=>_apply('flip',{}),
              icon:const Icon(Icons.flip),label:const Text('Flip')),
            FilledButton.icon(onPressed:_busy?null:_commitCrop,
              icon:const Icon(Icons.crop),label:const Text('Apply Crop')),
          ]),
        ]);
      case 'Filters':
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('Live filter previews',style:TextStyle(fontSize:12)),
          const SizedBox(height:12),
          SizedBox(height:112,
            child:ListView(scrollDirection:Axis.horizontal,children:[
              for(final type in const ['Normal','Vivid','Warm','Cool','B&W','Vintage','Soft'])
                Padding(padding:const EdgeInsets.only(right:10),
                  child:InkWell(
                    onTap:_busy?null:()=>_applyFilter(type),
                    borderRadius:BorderRadius.circular(14),
                    child:Column(children:[
                      Container(width:76,height:76,clipBehavior:Clip.antiAlias,
                        decoration:BoxDecoration(
                          borderRadius:BorderRadius.circular(12),
                          border:Border.all(
                            color:_selectedFilter==type?FileTheme.violet:
                              FileTheme.violet.withValues(alpha:.2),width:2)),
                        child:_filterThumbnail(type)),
                      const SizedBox(height:5),
                      Text(type,style:TextStyle(fontSize:11,
                        color:FileTheme.foreground(context))),
                    ]),
                  )),
            ])),
        ]);
      case 'Erase':
        return Column(children:[
          Text('Drag on the photo to erase pixels. Restore uses the same brush.',
            style:TextStyle(color:FileTheme.muted(context))),
          _slider('Brush size',_eraseRadius,.005,.15,
            (v)=>setState(()=>_eraseRadius=v),(){}),
          _slider('Softness',_softness,.03,1,
            (v)=>setState(()=>_softness=v),(){}),
          SegmentedButton<String>(segments:const [
            ButtonSegment(value:'Erase',label:Text('Erase')),
            ButtonSegment(value:'Restore',label:Text('Restore')),
          ],selected:{_eraseMode},onSelectionChanged:(v)=>
            setState(()=>_eraseMode=v.first)),
        ]);
      case 'Adjust':
        return Column(children:[
          _slider('Brightness',_brightness,.4,1.6,
            (v)=>setState(()=>_brightness=v),_commitAdjust),
          _slider('Contrast',_contrast,.3,1.8,
            (v)=>setState(()=>_contrast=v),_commitAdjust),
          _slider('Saturation',_saturation,0,2,
            (v)=>setState(()=>_saturation=v),_commitAdjust),
          _slider('Exposure',_exposure,-2,2,
            (v)=>setState(()=>_exposure=v),_commitAdjust),
        ]);
      default:return const SizedBox.shrink();
    }
  }
  Future<void> _applyFilter(String type)async{
    if(_busy||_bytes==null)return;
    final current=_bytes!;
    _filterBase??=current;
    setState(()=>_busy=true);
    try{
      final next=type=='Normal'?_filterBase!:
        await ImageEditingEngine.edit(_filterBase!,'filter',{'name':type});
      await _commit(current,next,'Filter: $type');
      if(mounted)setState(()=>_selectedFilter=type);
    }catch(_){_message('This filter could not be applied.');}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  Widget _filterThumbnail(String type){
    final bytes=_bytes;
    if(bytes==null)return const Icon(Icons.image_outlined);
    final child=Image.memory(bytes,fit:BoxFit.cover,cacheWidth:140,
      gaplessPlayback:true);
    final matrix=switch(type){
      'B&W'=><double>[.2126,.7152,.0722,0,0,.2126,.7152,.0722,0,0,
        .2126,.7152,.0722,0,0,0,0,0,1,0],
      'Vivid'=><double>[1.18,0,0,0,0,0,1.12,0,0,0,0,0,1.1,0,0,0,0,0,1,0],
      'Warm'=><double>[1.13,0,0,0,4,0,1.04,0,0,2,0,0,.83,0,0,0,0,0,1,0],
      'Cool'=><double>[.85,0,0,0,0,0,1.02,0,0,0,0,0,1.15,0,3,0,0,0,1,0],
      'Vintage'=><double>[.393,.769,.189,0,0,.349,.686,.168,0,0,
        .272,.534,.131,0,0,0,0,0,1,0],
      _=>null,
    };
    return matrix==null?child:ColorFiltered(
      colorFilter:ColorFilter.matrix(matrix),child:child);
  }

  String _cropRatio='Free',_eraseMode='Erase';
  void _setCropRatio(String ratio){
    setState((){
      _cropRatio=ratio;
      final value=switch(ratio){
        '1:1'=>1.0,'4:3'=>4/3,'16:9'=>16/9,'A4'=>210/297,
        _=>_ratio,
      };
      final w=math.min(.9,.8*value/_ratio);
      final h=math.min(.9,w*_ratio/value);
      _crop=Rect.fromLTWH((1-w)/2,(1-h)/2,w,h);
      _cropCorners=[_crop.topLeft,_crop.topRight,_crop.bottomRight,
        _crop.bottomLeft];
    });
  }
  void _commitAdjust(){
    if(_busy)return;
    final options=<String,Object?>{
      'brightness':_brightness,'contrast':_contrast,
      'saturation':_saturation,'exposure':_exposure,
    };
    setState((){
      _brightness=1;_contrast=1;_saturation=1;_exposure=0;
    });
    unawaited(_apply('adjust',options));
  }
  void _commitCrop(){
    final points=_cropCorners;
    unawaited(_apply('perspective',{
      'tlx':points[0].dx,'tly':points[0].dy,
      'trx':points[1].dx,'try':points[1].dy,
      'brx':points[2].dx,'bry':points[2].dy,
      'blx':points[3].dx,'bly':points[3].dy,
    },description:'Perspective freeform crop'));
  }

  Future<void> _customColorDialog()async{
    var red=_custom.r*255,green=_custom.g*255,
      blue=_custom.b*255;
    final color=await showDialog<Color>(context:context,builder:(context)=>
      StatefulBuilder(builder:(context,update)=>AlertDialog(
        title:const Text('Custom background color'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          for(final channel in [0,1,2])
            Slider(value:[red,green,blue][channel],min:0,max:255,
              onChanged:(v)=>update((){
                if(channel==0)red=v;
                if(channel==1)green=v;
                if(channel==2)blue=v;
              })),
          Container(height:35,color:Color.fromARGB(255,
            red.round(),green.round(),blue.round())),
        ]),
        actions:[TextButton(onPressed:()=>Navigator.pop(context),
          child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(context,
            Color.fromARGB(255,red.round(),green.round(),blue.round())),
            child:const Text('Apply'))],
      )));
    if(color!=null){
      _custom=color;
      await _replaceBackground(color:color);
    }
  }

  void _startGesture(DragStartDetails d,Size size){
    final point=Offset(d.localPosition.dx/size.width,
      d.localPosition.dy/size.height);
    if(_tool=='Crop'){
      _activeCropHandle=null;
      for(var i=0;i<_cropCorners.length;i++){
        if((point-_cropCorners[i]).distance<.12){
          _activeCropHandle=i;break;
        }
      }
    }else if(_tool=='Erase'){
      _stroke..clear()..add(point);
    }
  }
  void _changeGesture(DragUpdateDetails d,Size size){
    if(_tool=='Crop'){
      final dx=d.delta.dx/size.width,dy=d.delta.dy/size.height;
      setState((){
        final index=_activeCropHandle;
        if(index!=null){
          final old=_cropCorners[index];
          _cropCorners[index]=Offset(
            (old.dx+dx).clamp(0.0,1.0).toDouble(),
            (old.dy+dy).clamp(0.0,1.0).toDouble());
        }else{
          // Drag inside polygon to move the entire crop, without changing
          // its shape or dragging individual corner handles by accident.
          final left=_cropCorners.map((p)=>p.dx).reduce(math.min);
          final right=_cropCorners.map((p)=>p.dx).reduce(math.max);
          final top=_cropCorners.map((p)=>p.dy).reduce(math.min);
          final bottom=_cropCorners.map((p)=>p.dy).reduce(math.max);
          final tx=dx.clamp(-left,1-right).toDouble();
          final ty=dy.clamp(-top,1-bottom).toDouble();
          _cropCorners=[
            for(final point in _cropCorners)point+Offset(tx,ty),
          ];
        }
      });
    }else if(_tool=='Erase'){
      final point=Offset((d.localPosition.dx/size.width).clamp(0,1).toDouble(),
        (d.localPosition.dy/size.height).clamp(0,1).toDouble());
      _stroke.add(point);
    }
  }
  void _finishGesture(){
    if(_tool!='Erase'||_stroke.isEmpty)return;
    final points=_stroke.map((p)=><String,Object?>{
      'x':p.dx,'y':p.dy}).toList();
    _stroke.clear();
    unawaited(_apply(_eraseMode.toLowerCase(),{
      'points':points,'radius':_eraseRadius,'softness':_softness,
    }));
  }

  /// Slider feedback uses the GPU color-matrix while dragging; final
  /// full-quality pixels are processed off the UI isolate on release.
  Widget _liveAdjustment(Widget child){
    if(_tool!='Adjust')return child;
    final saturation=_saturation;
    const lr=.2126,lg=.7152,lb=.0722;
    final scale=_brightness*_contrast*math.pow(2,_exposure).toDouble();
    final shift=128*(1-_contrast)*_brightness;
    final sr=(1-saturation)*lr,sg=(1-saturation)*lg,sb=(1-saturation)*lb;
    return ColorFiltered(colorFilter:ColorFilter.matrix([
      (sr+saturation)*scale,sg*scale,sb*scale,0,shift,
      sr*scale,(sg+saturation)*scale,sb*scale,0,shift,
      sr*scale,sg*scale,(sb+saturation)*scale,0,shift,
      0,0,0,1,0,
    ]),child:child);
  }

  Widget _preview(){
    return LayoutBuilder(builder:(context,constraints){
      final width=math.min(constraints.maxWidth,
        constraints.maxHeight*_ratio).clamp(1.0,double.infinity).toDouble();
      final height=width/_ratio;
      final size=Size(width,height);
      Widget canvas=Stack(fit:StackFit.expand,children:[
        DecoratedBox(decoration:BoxDecoration(
          border:Border.all(color:FileTheme.violet.withValues(alpha:.18))),
          child:CustomPaint(painter:_CheckerPainter())),
        _liveAdjustment(Image.memory(_bytes!,fit:BoxFit.fill,
          gaplessPlayback:true,filterQuality:FilterQuality.medium)),
        if(_tool=='Crop')CustomPaint(painter:_CropPainter(_cropCorners)),
        if(_showOriginal && _originalBytes!=null)
          Image.memory(_originalBytes!,fit:BoxFit.fill),
      ]);
      if(_tool=='Crop'||_tool=='Erase'){
        canvas=GestureDetector(
          onPanStart:(d)=>_startGesture(d,size),
          onPanUpdate:(d)=>_changeGesture(d,size),
          onPanEnd:(_)=>_finishGesture(),
          child:canvas,
        );
      }else{
        canvas=InteractiveViewer(
          transformationController:_transformController,
          minScale:1,maxScale:6,panEnabled:true,
          scaleEnabled:true,child:canvas,
        );
      }
      return Center(child:SizedBox(width:width,height:height,child:canvas));
    });
  }

  Widget _menu()=>PopupMenuButton<String>(tooltip:'Image Editing menu',
    icon:const Icon(Icons.more_vert),
    onSelected:(value){
      if(value=='history')Navigator.of(context).push(fadePage<void>(
        const ImageEditingHistoryPage()));
      if(value=='share')unawaited(_export('share'));
    },itemBuilder:(_)=>const [
      PopupMenuItem(value:'history',child:Text('Image History')),
      PopupMenuItem(value:'share',child:Text('Share / Export')),
    ]);

  String _toolTitle(String tool)=>switch(tool){
    'Background'=>'Background Removal',
    'Compress'=>'Compression',
    'Crop'=>'Freeform Crop',
    'Erase'=>'Manual Erase',
    'Adjust'=>'Adjustments',
    _=>tool,
  };
  IconData _toolIcon(String tool)=>switch(tool){
    'Background'=>Icons.person_outline_rounded,
    'Compress'=>Icons.compress_rounded,
    'Crop'=>Icons.crop_rotate_rounded,
    'Filters'=>Icons.filter_vintage_outlined,
    'Erase'=>Icons.auto_fix_off,
    _=>Icons.tune_rounded,
  };
  void _selectTool(String tool){
    if(_busy)return;
    if(_tool=='Filters'&&tool!='Filters'){
      _filterBase=null;
      _selectedFilter=null;
    }
    setState(()=>_tool=tool);
  }

  Widget _toolTab(String tool,{bool vertical=false}){
    final selected=_tool==tool;
    final title=_toolTitle(tool);
    return Material(color:selected?FileTheme.violet:
      Theme.of(context).colorScheme.surface.withValues(alpha:.8),
      borderRadius:BorderRadius.circular(14),
      child:InkWell(borderRadius:BorderRadius.circular(14),
        onTap:()=>_selectTool(tool),
        child:Container(
          padding:EdgeInsets.symmetric(horizontal:vertical?14:12,
            vertical:vertical?13:10),
          decoration:BoxDecoration(borderRadius:BorderRadius.circular(14),
            border:Border.all(color:selected?FileTheme.violet:
              FileTheme.violet.withValues(alpha:.22))),
          child:Row(mainAxisSize:MainAxisSize.min,children:[
            Icon(_toolIcon(tool),size:19,
              color:selected?Colors.white:FileTheme.violet),
            const SizedBox(width:9),
            Text(title,maxLines:1,overflow:TextOverflow.ellipsis,
              style:TextStyle(fontWeight:FontWeight.w600,fontSize:13,
                color:selected?Colors.white:FileTheme.foreground(context))),
          ]),
        ),
      ),
    );
  }

  Widget _toolStrip()=>SizedBox(height:54,
    child:ListView(scrollDirection:Axis.horizontal,
      padding:const EdgeInsets.symmetric(horizontal:12,vertical:4),
      children:[
        for(final tool in _tools)
          Padding(padding:const EdgeInsets.only(right:7),
            child:_toolTab(tool)),
      ]));

  Widget _controls()=>SingleChildScrollView(
    key:ValueKey('panel-'+_tool),
    padding:const EdgeInsets.fromLTRB(16,12,16,14),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(_toolTitle(_tool),style:Theme.of(context).textTheme.titleMedium
        ?.copyWith(fontWeight:FontWeight.w800)),
      const SizedBox(height:8),
      AnimatedSwitcher(duration:const Duration(milliseconds:220),
        switchInCurve:Curves.easeOutCubic,
        child:KeyedSubtree(key:ValueKey(_tool),child:_toolControls())),
    ]));

  Widget _emptyCanvas({required bool wide}){
    return Center(child:ConstrainedBox(
      constraints:const BoxConstraints(maxWidth:460),
      child:Padding(padding:const EdgeInsets.all(24),
        child:Column(mainAxisSize:MainAxisSize.min,children:[
          Container(padding:const EdgeInsets.all(28),
            decoration:BoxDecoration(
              color:FileTheme.violet.withValues(alpha:.13),
              shape:BoxShape.circle),
            child:const Icon(Icons.add_photo_alternate_outlined,
              color:FileTheme.violet,size:55)),
          const SizedBox(height:18),
          Text('Choose an image',style:Theme.of(context).textTheme.titleLarge
            ?.copyWith(fontWeight:FontWeight.w800)),
          const SizedBox(height:7),
          Text('Your live editing preview will appear here.',
            style:TextStyle(color:FileTheme.muted(context)),
            textAlign:TextAlign.center),
          if(_error!=null)...[
            const SizedBox(height:8),
            Text('This file could not be opened. Choose another image.',
              textAlign:TextAlign.center,
              style:TextStyle(color:Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height:20),
          Wrap(alignment:WrapAlignment.center,
            spacing:12,runSpacing:12,children:[
              OutlinedButton.icon(
                onPressed:_imagePickerBusy?null:()=>_chooseSource(camera:true),
                icon:const Icon(Icons.photo_camera_outlined),
                label:const Text('Camera')),
              FilledButton.icon(
                onPressed:_imagePickerBusy?null:()=>_chooseSource(camera:false),
                icon:const Icon(Icons.folder_open_outlined),
                label:const Text('Browse images')),
            ]),
          if(_imagePickerBusy)...[
            const SizedBox(height:14),
            const LinearProgressIndicator(),
          ],
        ]),
      ),
    ));
  }

  Widget _previewArea({required bool wide}){
    final isDark=Theme.of(context).brightness==Brightness.dark;
    return Container(
      margin:EdgeInsets.all(wide?14:10),
      clipBehavior:Clip.antiAlias,
      decoration:BoxDecoration(
        color:isDark?const Color(0xFF141223):const Color(0xFFF7F4FF),
        borderRadius:BorderRadius.circular(wide?22:18),
        border:Border.all(color:FileTheme.violet.withValues(alpha:.15))),
      child:Column(children:[
        if(_busy)const LinearProgressIndicator(minHeight:3),
        Expanded(child:_bytes==null?_emptyCanvas(wide:wide):
          Padding(padding:EdgeInsets.all(wide?14:8),
            child:RepaintBoundary(child:_preview()))),
        Container(height:52,
          padding:const EdgeInsets.symmetric(horizontal:9),
          decoration:BoxDecoration(
            color:Theme.of(context).colorScheme.surface.withValues(alpha:.75),
            border:Border(top:BorderSide(
              color:FileTheme.violet.withValues(alpha:.12)))),
          child:Row(children:[
            IconButton(tooltip:'Fit image',onPressed:_resetZoom,
              icon:const Icon(Icons.fit_screen_outlined)),
            IconButton(tooltip:'Zoom out',
              onPressed:_bytes==null?null:()=>_changeZoom(.8),
              icon:const Icon(Icons.zoom_out_outlined)),
            Text('${(_zoom*100).round()}%',
              style:const TextStyle(fontSize:12,fontWeight:FontWeight.w700)),
            IconButton(tooltip:'Zoom in',
              onPressed:_bytes==null?null:()=>_changeZoom(1.25),
              icon:const Icon(Icons.zoom_in_outlined)),
            const Spacer(),
            IconButton(tooltip:'Browse another image',
              onPressed:()=>_chooseSource(camera:false),
              icon:const Icon(Icons.add_photo_alternate_outlined)),
            IconButton(tooltip:'Image History',
              onPressed:()=>Navigator.of(context).push(
                fadePage<void>(const ImageEditingHistoryPage())),
              icon:const Icon(Icons.history)),
          ]),
        ),
      ]),
    );
  }

  Future<void> _applyCurrent() async {
    if(_busy || _bytes==null)return;
    if(_tool=='Crop'){
      _commitCrop();
    }else if(_tool=='Adjust'){
      _commitAdjust();
    }else if(_tool=='Compress'){
      await _compress();
    }else{
      await _saveDraft();
      _message('Current image saved in Image History');
    }
  }

  Widget _actions({bool wide=false}){
    final available=_bytes!=null && !_busy;
    return SafeArea(top:false,child:Container(
      padding:EdgeInsets.fromLTRB(wide?15:8,7,wide?15:8,9),
      decoration:BoxDecoration(
        color:Theme.of(context).colorScheme.surface.withValues(alpha:.8),
        border:Border(top:BorderSide(
          color:FileTheme.violet.withValues(alpha:.15)))),
      child:Column(mainAxisSize:MainAxisSize.min,children:[
        Row(children:[
          IconButton(tooltip:'Close editor',
            onPressed:()=>Navigator.of(context).maybePop(),
            icon:const Icon(Icons.close_rounded)),
          IconButton(tooltip:'Undo',onPressed:_undo.isEmpty||_busy?null:
            ()=>_historyStep(true),icon:const Icon(Icons.undo_rounded)),
          IconButton(tooltip:'Redo',onPressed:_redo.isEmpty||_busy?null:
            ()=>_historyStep(false),icon:const Icon(Icons.redo_rounded)),
          const Spacer(),
          IconButton(tooltip:'Save image',onPressed:available?
            ()=>_export('save'):null,
            icon:const Icon(Icons.file_download_outlined)),
          IconButton(tooltip:'Share image',onPressed:available?
            ()=>_export('share'):null,icon:const Icon(Icons.share_outlined)),
          FilledButton.icon(onPressed:available?_applyCurrent:null,
            icon:const Icon(Icons.check_rounded),label:const Text('Apply')),
        ]),
        const SizedBox(height:5),
        SizedBox(width:double.infinity,child:FilledButton.icon(
          onPressed:available?()=>_export('cart'):null,
          icon:const Icon(Icons.send_outlined),
          label:const Text('Send to File Share Cart')),
        ),
      ]),
    ));
  }

  Widget _desktopHistory(){
    return ListenableBuilder(listenable:ImageEditingHistory.instance,
      builder:(context,_){
        final drafts=ImageEditingHistory.instance.drafts.take(5).toList();
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Row(children:[
            const Icon(Icons.history,color:FileTheme.violet),
            const SizedBox(width:9),
            const Expanded(child:Text('Image History',style:
              TextStyle(fontWeight:FontWeight.w800,fontSize:17))),
            TextButton(onPressed:()=>Navigator.of(context).push(
              fadePage<void>(const ImageEditingHistoryPage())),
              child:const Text('View all')),
          ]),
          const SizedBox(height:9),
          if(drafts.isEmpty)Padding(
            padding:const EdgeInsets.symmetric(vertical:15),
            child:Text('Edited images appear here automatically.',
              style:TextStyle(color:FileTheme.muted(context)))),
          for(final entry in drafts)
            Padding(padding:const EdgeInsets.only(bottom:9),
              child:Material(
                color:Theme.of(context).colorScheme.surface,
                borderRadius:BorderRadius.circular(14),
                child:InkWell(
                  onTap:()=>Navigator.of(context).push(fadePage<void>(
                    ImageEditingPage(draft:entry))),
                  borderRadius:BorderRadius.circular(14),
                  child:Padding(padding:const EdgeInsets.all(8),
                    child:Row(children:[
                      ClipRRect(borderRadius:BorderRadius.circular(9),
                        child:Image.file(File(entry.filePath),width:55,height:55,
                          fit:BoxFit.cover,cacheWidth:110)),
                      const SizedBox(width:9),
                      Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,
                        children:[
                          Text(entry.name,maxLines:1,overflow:TextOverflow.ellipsis,
                            style:const TextStyle(fontWeight:FontWeight.w700)),
                          Text('${entry.steps.length} edit steps',
                            style:TextStyle(fontSize:11,
                              color:FileTheme.muted(context))),
                        ])),
                      const Icon(Icons.chevron_right_rounded,color:FileTheme.violet),
                    ])),
                ),
              )),
        ]);
      });
  }

  Widget _desktopWorkspace(){
    return Row(children:[
      Expanded(flex:8,child:Column(children:[
        Expanded(child:_previewArea(wide:true)),
        _actions(wide:true),
      ])),
      Container(width:365,
        decoration:BoxDecoration(border:Border(left:BorderSide(
          color:FileTheme.violet.withValues(alpha:.2)))),
        child:Column(children:[
          Expanded(child:ListView(padding:const EdgeInsets.all(14),children:[
            Row(children:[
              IconButton(tooltip:'Undo',onPressed:_undo.isEmpty?null:
                ()=>_historyStep(true),icon:const Icon(Icons.undo)),
              IconButton(tooltip:'Redo',onPressed:_redo.isEmpty?null:
                ()=>_historyStep(false),icon:const Icon(Icons.redo)),
              const Spacer(),_menu(),
            ]),
            for(final tool in _tools)
              Padding(padding:const EdgeInsets.only(bottom:7),
                child:_toolTab(tool,vertical:true)),
            const Divider(height:24),
            _controls(),
            const Divider(height:24),
            _desktopHistory(),
          ])),
        ]),
      ),
    ]);
  }

  Widget _mobileWorkspace(){
    return Column(children:[
      Expanded(flex:7,child:_previewArea(wide:false)),
      _toolStrip(),
      SizedBox(height:210,child:_controls()),
      _actions(),
    ]);
  }

  Widget _menu()=>PopupMenuButton<String>(
    tooltip:'More Image Editing options',
    icon:const Icon(Icons.more_vert_rounded),
    onSelected:(value){
      if(value=='history')Navigator.of(context).push(
        fadePage<void>(const ImageEditingHistoryPage()));
      if(value=='share' && _bytes!=null)unawaited(_export('share'));
    },
    itemBuilder:(_)=>const [
      PopupMenuItem(value:'history',child:Row(children:[
        Icon(Icons.history),SizedBox(width:12),Text('Image History')])),
      PopupMenuItem(value:'share',child:Row(children:[
        Icon(Icons.ios_share_outlined),SizedBox(width:12),
        Text('Share / Export')])),
    ]);

  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Image Editing'),actions:[
      IconButton(tooltip:'Before / After',onPressed:_bytes==null?null:
        ()=>setState(()=>_showOriginal=!_showOriginal),
        icon:Icon(_showOriginal?Icons.visibility_off_outlined:
          Icons.compare)),
      _menu(),
    ]),
    body:Container(
      decoration:BoxDecoration(gradient:FileTheme.background(context)),
      child:LayoutBuilder(builder:(context,constraints)=>
        constraints.maxWidth>=900?_desktopWorkspace():_mobileWorkspace()),
    ),
  );
}

class _CheckerPainter extends CustomPainter {
  @override void paint(Canvas canvas,Size size){
    const cell=14.0;
    final paint=Paint();
    for(var y=0.0;y<size.height;y+=cell){
      for(var x=0.0;x<size.width;x+=cell){
        paint.color=((x/cell).floor()+(y/cell).floor()).isEven
          ?const Color(0xFFE9E9E9):const Color(0xFFF9F9F9);
        canvas.drawRect(Rect.fromLTWH(x,y,cell,cell),paint);
      }
    }
  }
  @override bool shouldRepaint(covariant CustomPainter old)=>false;
}
class _CropPainter extends CustomPainter {
  _CropPainter(this.corners);
  final List<Offset> corners;
  Offset _point(Offset p,Size size)=>
    Offset(p.dx*size.width,p.dy*size.height);
  @override void paint(Canvas canvas,Size size){
    if(corners.length!=4)return;
    final points=[for(final p in corners)_point(p,size)];
    final outside=Path()..addRect(Offset.zero & size);
    final polygon=Path()..moveTo(points[0].dx,points[0].dy);
    for(var i=1;i<4;i++)polygon.lineTo(points[i].dx,points[i].dy);
    polygon.close();
    canvas.drawPath(Path.combine(PathOperation.difference,outside,polygon),
      Paint()..color=Colors.black54);
    final border=Paint()..color=Colors.white
      ..style=PaintingStyle.stroke..strokeWidth=2;
    canvas.drawPath(polygon,border);
    for(var i=1;i<3;i++){
      final f=i/3.0;
      Offset interpolate(Offset a,Offset b)=>Offset.lerp(a,b,f)!;
      canvas.drawLine(interpolate(points[0],points[3]),
        interpolate(points[1],points[2]),border);
      canvas.drawLine(interpolate(points[0],points[1]),
        interpolate(points[3],points[2]),border);
    }
    final handle=Paint()..color=FileTheme.violet;
    for(final p in points){
      canvas.drawCircle(p,9,Paint()..color=Colors.white);
      canvas.drawCircle(p,6,handle);
    }
  }
  @override bool shouldRepaint(covariant _CropPainter old){
    if(old.corners.length!=corners.length)return true;
    for(var i=0;i<corners.length;i++){
      if(old.corners[i]!=corners[i])return true;
    }
    return false;
  }
}

class ImageEditingHistoryPage extends StatefulWidget {
  const ImageEditingHistoryPage({super.key});
  @override State<ImageEditingHistoryPage> createState()=>
    _ImageEditingHistoryPageState();
}
class _ImageEditingHistoryPageState extends State<ImageEditingHistoryPage> {
  @override void initState(){
    super.initState();
    unawaited(ImageEditingHistory.instance.load());
  }
  Future<void> _cart(ImageEditingDraft draft)async{
    final original=File(draft.filePath);
    final root=await getApplicationSupportDirectory();
    final cart=Directory('${root.path}${Platform.pathSeparator}image_editing_cart');
    await cart.create(recursive:true);
    final isJpg=draft.filePath.toLowerCase().endsWith('.jpg');
    final name='edited_${DateTime.now().microsecondsSinceEpoch}.${isJpg?'jpg':'png'}';
    final file=await original.copy('${cart.path}${Platform.pathSeparator}$name');
    ImageEditingCart.instance.add(file,name);
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content:Text('Added to File Share Cart')));
  }
  Future<void> _historyAction(ImageEditingDraft entry,String action)async{
    try{
      switch(action){
        case 'edit':
          await Navigator.of(context).push(fadePage<void>(
            ImageEditingPage(draft:entry)));
        case 'share':
          await SharePlus.instance.share(ShareParams(
            files:[XFile(entry.filePath)]));
        case 'cart':
          await _cart(entry);
        case 'download':
          final bytes=await File(entry.filePath).readAsBytes();
          final jpeg=bytes.length>1&&bytes[0]==0xff&&bytes[1]==0xd8;
          await FilePicker.saveFile(fileName:'edited_${entry.id}.${jpeg?'jpg':'png'}',
            bytes:bytes,mimeType:jpeg?'image/jpeg':'image/png');
        case 'delete':
          final confirmed=await showDialog<bool>(context:context,
            builder:(ctx)=>AlertDialog(
              title:const Text('Delete this image draft?'),
              content:const Text('This removes the local editing history copy. '
                'Your original file is not affected.'),
              actions:[
                TextButton(onPressed:()=>Navigator.pop(ctx,false),
                  child:const Text('Cancel')),
                FilledButton(onPressed:()=>Navigator.pop(ctx,true),
                  child:const Text('Delete')),
              ]));
          if(confirmed==true){
            await ImageEditingHistory.instance.delete(entry);
          }
      }
    }catch(_){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content:Text('Image action failed. Please retry.')));
    }
  }

  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Row(children:[
      Icon(Icons.history,color:FileTheme.violet),
      SizedBox(width:10),Text('Image History'),
    ])),
    body:Container(
      decoration:BoxDecoration(gradient:FileTheme.background(context)),
      child:ListenableBuilder(listenable:ImageEditingHistory.instance,
        builder:(context,_){
          final items=ImageEditingHistory.instance.drafts;
          if(items.isEmpty)return Center(child:Column(
            mainAxisSize:MainAxisSize.min,children:[
              const Icon(Icons.photo_library_outlined,
                size:60,color:FileTheme.violet),
              const SizedBox(height:12),
              Text('No saved images yet',
                style:Theme.of(context).textTheme.titleMedium),
              const SizedBox(height:6),
              const Text('Your edits are saved locally as you work.'),
            ]));
          return Center(child:ConstrainedBox(
            constraints:const BoxConstraints(maxWidth:850),
            child:ListView.separated(
              padding:const EdgeInsets.all(15),
              itemCount:items.length,
              separatorBuilder:(_,__)=>const SizedBox(height:12),
              itemBuilder:(context,index){
                final entry=items[index];
                return Material(
                  color:Theme.of(context).colorScheme.surface,
                  borderRadius:BorderRadius.circular(18),
                  child:Container(
                    padding:const EdgeInsets.all(12),
                    decoration:BoxDecoration(
                      borderRadius:BorderRadius.circular(18),
                      border:Border.all(color:FileTheme.violet.withValues(alpha:.2))),
                    child:Row(children:[
                      ClipRRect(borderRadius:BorderRadius.circular(12),
                        child:Image.file(File(entry.filePath),
                          width:98,height:86,fit:BoxFit.cover,cacheWidth:196,
                          errorBuilder:(_,__,___)=>const Icon(
                            Icons.broken_image_outlined,size:40))),
                      const SizedBox(width:12),
                      Expanded(child:Column(
                        crossAxisAlignment:CrossAxisAlignment.start,
                        children:[
                          Text(entry.name,maxLines:2,
                            overflow:TextOverflow.ellipsis,
                            style:const TextStyle(
                              fontWeight:FontWeight.w800,fontSize:14)),
                          const SizedBox(height:5),
                          Text(entry.updated.toLocal().toString().substring(0,16),
                            style:TextStyle(fontSize:12,
                              color:FileTheme.muted(context))),
                          const SizedBox(height:5),
                          Text('${entry.steps.length} edit steps',
                            style:const TextStyle(fontSize:11,
                              color:FileTheme.violet)),
                        ])),
                      PopupMenuButton<String>(
                        tooltip:'Image history actions',
                        onSelected:(action)=>unawaited(
                          _historyAction(entry,action)),
                        itemBuilder:(_)=>const [
                          PopupMenuItem(value:'edit',child:ListTile(
                            dense:true,leading:Icon(Icons.edit_outlined),
                            title:Text('Re-edit'))),
                          PopupMenuItem(value:'share',child:ListTile(
                            dense:true,leading:Icon(Icons.share_outlined),
                            title:Text('Share'))),
                          PopupMenuItem(value:'cart',child:ListTile(
                            dense:true,leading:Icon(Icons.send_outlined),
                            title:Text('Send to File Share'))),
                          PopupMenuItem(value:'download',child:ListTile(
                            dense:true,leading:Icon(Icons.download_outlined),
                            title:Text('Download'))),
                          PopupMenuItem(value:'delete',child:ListTile(
                            dense:true,leading:Icon(Icons.delete_outline),
                            title:Text('Delete'))),
                        ]),
                    ]),
                  ),
                );
              }),
          ));
        }),
    ),
  );
}

class ImageEditingLauncherPage extends StatelessWidget {
  const ImageEditingLauncherPage({super.key});
  Future<void> _select(BuildContext context)async{
    try {
      final selection=await FilePicker.pickFiles(type:FileType.image);
      if(selection.isEmpty || !context.mounted)return;
      final file=selection.first;
      var path=file.path;
      if(path==null){
        final bytes=await file.readAsBytes();
        final dir=await getApplicationSupportDirectory();
        final chosen=File('${dir.path}${Platform.pathSeparator}image_pick_${DateTime.now().microsecondsSinceEpoch}.png');
        await chosen.writeAsBytes(bytes,flush:true);
        path=chosen.path;
      }
      if(!context.mounted)return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>
        ImageEditingPage(sourcePath:path,sourceName:file.name)));
    }catch(error){
      if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('Image selection failed: $error')));
    }
  }
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Image Editing')),
    body:Container(
      decoration:BoxDecoration(gradient:FileTheme.background(context)),
      child:Center(child:ConstrainedBox(
        constraints:const BoxConstraints(maxWidth:620),
        child:ListView(shrinkWrap:true,padding:const EdgeInsets.all(20),
          children:[
            const Icon(Icons.photo_filter_outlined,size:72,
              color:FileTheme.violet),
            const SizedBox(height:14),
            Text('Image Editing',textAlign:TextAlign.center,
              style:Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height:8),
            Text('Background removal, compression, freeform crop, filters, '
              'manual erase and photo adjustments.',
              textAlign:TextAlign.center,
              style:TextStyle(color:FileTheme.muted(context))),
            const SizedBox(height:26),
            FilledButton.icon(onPressed:()=>_select(context),
              icon:const Icon(Icons.add_photo_alternate_outlined),
              label:const Text('Choose Image')),
            const SizedBox(height:12),
            OutlinedButton.icon(onPressed:()=>Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder:(_)=>const ImageEditingHistoryPage())),
              icon:const Icon(Icons.history),
              label:const Text('Image History / Continue Editing')),
            const SizedBox(height:10),
            Text('All drafts stay private on this Android or Windows device. '
              'Each saved stage can be sent to the File Share Cart.',
              textAlign:TextAlign.center,
              style:TextStyle(color:FileTheme.muted(context),fontSize:12)),
          ]),
      )),
    ),
  );
}
