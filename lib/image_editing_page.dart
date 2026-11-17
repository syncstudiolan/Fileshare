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
  String? _error;
  bool _busy=false, _cropResize=false, _showOriginal=false;
  bool _imagePickerBusy=false;
  String? _selectedFilter;
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
    final selected=color??_background;
    if(color!=null)setState(()=>_background=color);
    if(selected==Colors.transparent && picture==null){
      _message('Transparent background retained');
      return;
    }
    await _apply('flatten',{
      'color':selected.toARGB32(),
      if(picture!=null)'backgroundBytes':picture,
    },description:'Replace background');
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
                    onTap:_busy?null:(){
                      setState(()=>_selectedFilter=type);
                      unawaited(_apply('filter',{'name':type},
                        description:'Filter: $type'));
                    },
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
  void _commitCrop()=>unawaited(_apply('crop',{
    'x':_crop.left,'y':_crop.top,'w':_crop.width,'h':_crop.height,
  }));

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
      _cropResize=(point-_crop.bottomRight).distance<.15;
    }else if(_tool=='Erase'){
      _stroke..clear()..add(point);
    }
  }
  void _changeGesture(DragUpdateDetails d,Size size){
    if(_tool=='Crop'){
      final dx=d.delta.dx/size.width,dy=d.delta.dy/size.height;
      setState((){
        if(_cropResize){
          _crop=Rect.fromLTRB(_crop.left,_crop.top,
            (_crop.right+dx).clamp(_crop.left+.05,1).toDouble(),
            (_crop.bottom+dy).clamp(_crop.top+.05,1).toDouble());
        }else{
          final l=(_crop.left+dx).clamp(0,1-_crop.width).toDouble();
          final t=(_crop.top+dy).clamp(0,1-_crop.height).toDouble();
          _crop=Rect.fromLTWH(l,t,_crop.width,_crop.height);
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
        if(_tool=='Crop')CustomPaint(painter:_CropPainter(_crop)),
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

  Widget _toolbar()=>Wrap(spacing:7,runSpacing:6,children:[
    for(final t in _tools)
      ChoiceChip(label:Text(t),selected:_tool==t,
        onSelected:(_)=>setState(()=>_tool=t)),
  ]);

  Widget _controls()=>SingleChildScrollView(
    padding:const EdgeInsets.all(14),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('$_tool',style:Theme.of(context).textTheme.titleLarge),
      const SizedBox(height:12),
      AnimatedSwitcher(
        duration:const Duration(milliseconds:250),
        switchInCurve:Curves.easeOutCubic,
        switchOutCurve:Curves.easeInCubic,
        child:KeyedSubtree(key:ValueKey(_tool),child:_toolControls()),
      ),
    ]));

  Widget _actions()=>SafeArea(top:false,child:Padding(
    padding:const EdgeInsets.all(8),
    child:Wrap(alignment:WrapAlignment.center,spacing:10,runSpacing:8,children:[
      OutlinedButton.icon(onPressed:_undo.isEmpty?null:()=>_historyStep(true),
        icon:const Icon(Icons.undo),label:const Text('Undo')),
      OutlinedButton.icon(onPressed:_redo.isEmpty?null:()=>_historyStep(false),
        icon:const Icon(Icons.redo),label:const Text('Redo')),
      OutlinedButton.icon(onPressed:_busy?null:()=>_export('save'),
        icon:const Icon(Icons.download),label:const Text('Save')),
      OutlinedButton.icon(onPressed:_busy?null:()=>_export('share'),
        icon:const Icon(Icons.share),label:const Text('Share')),
      FilledButton.icon(onPressed:_busy?null:()=>_export('cart'),
        icon:const Icon(Icons.send),label:const Text('Send to Cart')),
    ]),
  ));

  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Image Editing'),actions:[
      IconButton(tooltip:'Before / After',
        onPressed:()=>setState(()=>_showOriginal=!_showOriginal),
        icon:Icon(_showOriginal?Icons.visibility_off:Icons.compare)),
      _menu(),
    ]),
    body:Container(
      decoration:BoxDecoration(gradient:FileTheme.background(context)),
      child:_bytes==null
        ?Center(child:_error!=null?Text(_error!):
          const CircularProgressIndicator())
        :LayoutBuilder(builder:(context,constraints){
          final wide=constraints.maxWidth>=850;
          final canvas=Column(children:[
            Padding(padding:const EdgeInsets.all(10),child:_toolbar()),
            if(_busy)const LinearProgressIndicator(minHeight:3),
            Expanded(child:Padding(padding:const EdgeInsets.all(12),
              child:RepaintBoundary(child:_preview()))),
            if(!wide)SizedBox(height:230,child:_controls()),
            _actions(),
          ]);
          return wide?Row(children:[
            Expanded(flex:3,child:canvas),
            VerticalDivider(width:1,color:FileTheme.violet.withValues(alpha:.2)),
            SizedBox(width:315,child:_controls()),
          ]):canvas;
        }),
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
  _CropPainter(this.region);
  final Rect region;
  @override void paint(Canvas canvas,Size size){
    final r=Rect.fromLTRB(region.left*size.width,region.top*size.height,
      region.right*size.width,region.bottom*size.height);
    final shadow=Paint()..color=Colors.black54;
    canvas.drawRect(Rect.fromLTWH(0,0,size.width,r.top),shadow);
    canvas.drawRect(Rect.fromLTRB(0,r.bottom,size.width,size.height),shadow);
    canvas.drawRect(Rect.fromLTRB(0,r.top,r.left,r.bottom),shadow);
    canvas.drawRect(Rect.fromLTRB(r.right,r.top,size.width,r.bottom),shadow);
    final pen=Paint()..color=Colors.white..style=PaintingStyle.stroke
      ..strokeWidth=2;
    canvas.drawRect(r,pen);
    for(var i=1;i<3;i++){
      canvas.drawLine(Offset(r.left+r.width*i/3,r.top),
        Offset(r.left+r.width*i/3,r.bottom),pen);
      canvas.drawLine(Offset(r.left,r.top+r.height*i/3),
        Offset(r.right,r.top+r.height*i/3),pen);
    }
    final handle=Paint()..color=FileTheme.violet;
    for(final point in [r.topLeft,r.topRight,r.bottomLeft,r.bottomRight]){
      canvas.drawCircle(point,7,handle);
      canvas.drawCircle(point,4,Paint()..color=Colors.white);
    }
  }
  @override bool shouldRepaint(covariant _CropPainter old)=>old.region!=region;
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
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Image History')),
    body:ListenableBuilder(listenable:ImageEditingHistory.instance,
      builder:(context,_) {
        final items=ImageEditingHistory.instance.drafts;
        if(items.isEmpty)return const Center(child:Text('No image drafts yet'));
        return ListView.builder(itemCount:items.length,
          itemBuilder:(context,index){
            final entry=items[index];
            return Card(margin:const EdgeInsets.symmetric(horizontal:10,vertical:6),
              child:Padding(padding:const EdgeInsets.all(10),child:Column(children:[
                Row(children:[
                  ClipRRect(borderRadius:BorderRadius.circular(12),
                    child:Image.file(File(entry.filePath),width:85,height:85,
                      fit:BoxFit.cover,cacheWidth:170)),
                  const SizedBox(width:12),
                  Expanded(child:Column(
                    crossAxisAlignment:CrossAxisAlignment.start,children:[
                      Text(entry.name,maxLines:2,overflow:TextOverflow.ellipsis),
                      Text(entry.updated.toLocal().toString().substring(0,16),
                        style:TextStyle(color:FileTheme.muted(context))),
                      Text('${entry.steps.length} edits',
                        style:TextStyle(color:FileTheme.muted(context))),
                    ])),
                ]),
                Wrap(spacing:3,runSpacing:3,children:[
                  TextButton.icon(onPressed:()=>Navigator.push(context,
                    MaterialPageRoute<void>(builder:(_)=>ImageEditingPage(draft:entry))),
                    icon:const Icon(Icons.edit),label:const Text('Re-edit')),
                  TextButton.icon(onPressed:()=>SharePlus.instance.share(
                    ShareParams(files:[XFile(entry.filePath)])),
                    icon:const Icon(Icons.share),label:const Text('Share')),
                  TextButton.icon(onPressed:()=>_cart(entry),
                    icon:const Icon(Icons.send),label:const Text('Cart')),
                  TextButton.icon(onPressed:()async{
                    final data=await File(entry.filePath).readAsBytes();
                    final isJpg=data.length>1 && data[0]==0xff && data[1]==0xd8;
                    await FilePicker.saveFile(
                      fileName:'edited_${entry.id}.${isJpg?'jpg':'png'}',
                      bytes:data,mimeType:isJpg?'image/jpeg':'image/png');
                  },icon:const Icon(Icons.download),label:const Text('Download')),
                  TextButton.icon(onPressed:()async{
                    await ImageEditingHistory.instance.delete(entry);
                  },icon:const Icon(Icons.delete_outline),label:const Text('Delete')),
                ]),
              ])));
          });
      }),
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
