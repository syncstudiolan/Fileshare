import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart' show FileTheme, fadePage;
import 'image_editing_engine.dart';
import 'app_top_notice.dart';
import 'image_editing_storage.dart';
import 'editor_transfer_session.dart';
import 'image_editing_windows_ai.dart';
import 'photo_enhancer_engine.dart';
import 'face_restoration_engine.dart';

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
  String? _pendingFilter;
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
  String _cropMode='Normal Crop';
  final List<Offset> _stroke=[];
  final ValueNotifier<int> _strokeRepaint=ValueNotifier<int>(0);
  final List<_LiveEraseStroke> _pendingErase=[];
  Future<void> _eraseQueue=Future<void>.value();
  Future<void> _historyQueue=Future<void>.value();
  final ScrollController _controlScroll=ScrollController();
  int _previewDecodeVersion=0;
  ui.Image? _erasePreview;
  ui.Image? _eraseRestoration;
  double _fineAngle=0;
  bool _straightenAutoCrop=true;
  String? _processingAction;
  Rect? _instantCrop;
  int _quality=85,_targetKb=500;
  Color _background=Colors.white;
  List<Color> _recentColors=[];
  Color? _pendingBackgroundColor;
  Color _custom=const Color(0xFF7D5BE3);
  String _backgroundEngine='Auto (ML Kit first)';
  int _enhanceScale=2;
  double _enhanceStrength=.8;
  double _enhanceProgress=0;
  bool _enhanceFaceMode=false;
  bool _faceUseCrop=false;

  static const _tools=['Background','Erase','Photo Enhancer','Crop','Filters','Straighten','Adjust','Compress'];
  static const _colors=[Colors.transparent,Colors.white,Colors.black,
    Color(0xFFE84D9F), Color(0xFF765ADB),Color(0xFFE53935),
    Color(0xFF1E88E5),Color(0xFF43A047),Color(0xFFFFEB3B)];

  @override
  void initState(){
    super.initState();
    _name=widget.sourceName??widget.draft?.name??'edited-image.png';
    unawaited(_load());
    unawaited(_loadRecentColors());
  }
  @override void dispose(){
    _erasePreview?.dispose();
    _eraseRestoration?.dispose();
    _transformController.dispose();
    _controlScroll.dispose();
    _strokeRepaint.dispose();
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
  Future<void> _cacheEraseImage(Uint8List bytes,{bool original=false})async{
    final revision=original?-1:++_previewDecodeVersion;
    try{
      final codec=await ui.instantiateImageCodec(bytes,targetWidth:1000);
      final frame=await codec.getNextFrame();
      codec.dispose();
      if(!mounted || (!original && revision!=_previewDecodeVersion)){
        frame.image.dispose();return;
      }
      // Keep the previous GPU frame alive until Flutter has painted the new
      // bitmap. Disposing it inside setState can race a raster-thread frame.
      ui.Image? replaced;
      setState((){
        if(original){
          replaced=_eraseRestoration;
          _eraseRestoration=frame.image;
        }else{
          replaced=_erasePreview;
          _erasePreview=frame.image;
        }
      });
      if(replaced!=null)WidgetsBinding.instance.addPostFrameCallback((_){
        replaced?.dispose();
      });
    }catch(_){/* Image.memory still renders any supported file. */}
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
      Uint8List original=bytes;
      final savedOriginal=widget.draft?.originalFilePath;
      if(savedOriginal!=null&&await File(savedOriginal).exists()){
        original=await File(savedOriginal).readAsBytes();
      }
      if(mounted)setState((){
        _bytes=Uint8List.fromList(bytes);
        _originalBytes=Uint8List.fromList(original);
        _cutoutBytes=null;
      });
      unawaited(_cacheEraseImage(bytes));
      unawaited(_cacheEraseImage(bytes,original:true));
      await _restoreSession();
      if(widget.draft==null)await _saveDraft();
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }

  Future<void> _loadRecentColors() async {
    try {
      final stored = await SharedPreferencesAsync().getStringList(
        'file_share_recent_background_colors') ?? <String>[];
      if(mounted)setState(() {
        _recentColors=stored.map(int.tryParse).whereType<int>()
          .map(Color.new).toList();
      });
    }catch(_){}
  }
  Future<void> _rememberColor(Color selected) async {
    if(selected==Colors.transparent)return;
    final value=selected.toARGB32();
    setState(() {
      _recentColors=[selected,
        ..._recentColors.where((c)=>c.toARGB32()!=value)].take(10).toList();
    });
    try {
      await SharedPreferencesAsync().setStringList(
        'file_share_recent_background_colors',
        _recentColors.map((x)=>x.toARGB32().toString()).toList());
    }catch(_){}
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
        _pendingFilter=null;_selectedFilter=null;_pendingBackgroundColor=null;
        _crop=const Rect.fromLTWH(.06,.06,.88,.88);
      _cropCorners=[const Offset(.06,.06),const Offset(.94,.06),
        const Offset(.94,.94),const Offset(.06,.94)];
        _error=null;
        _showOriginal=false;
      });
      unawaited(_cacheEraseImage(bytes));
      unawaited(_cacheEraseImage(bytes,original:true));
      await _saveDraft();
    }catch(_){
      _message('Could not open this image. Try a JPG or PNG.');
    }finally{if(mounted)setState(()=>_imagePickerBusy=false);}
  }

  Future<void> _saveSession()async{
    final id=_draftId;
    if(id==null)return;
    await EditorSessionStore.instance.save('image',id,{
      'tool':_tool,'format':_format,
      'cropMode':_cropMode,'crop':[_crop.left,_crop.top,_crop.right,_crop.bottom],
      'cropRatio':_cropRatio,
      'cropCorners':[for(final p in _cropCorners)[p.dx,p.dy]],
      'eraseRadius':_eraseRadius,'softness':_softness,'eraseMode':_eraseMode,
      'fineAngle':_fineAngle,'straightenAutoCrop':_straightenAutoCrop,
      'quality':_quality,'targetKb':_targetKb,
      'brightness':_brightness,'contrast':_contrast,
      'saturation':_saturation,'exposure':_exposure,
      'backgroundColor':_background.toARGB32(),
      'backgroundEngine':_backgroundEngine,
      'enhanceScale':_enhanceScale,
      'enhanceStrength':_enhanceStrength,
      'enhanceFaceMode':_enhanceFaceMode,
      'faceUseCrop':_faceUseCrop,
      'zoom':_zoom,
    });
  }
  Future<void> _restoreSession()async{
    final id=_draftId;
    if(id==null)return;
    final state=await EditorSessionStore.instance.load('image',id);
    if(state==null||!mounted)return;
    double number(dynamic v,double fallback)=>
      v is num?v.toDouble():fallback;
    setState((){
      final tool=state['tool'] as String?;
      if(tool!=null&&_tools.contains(tool))_tool=tool;
      _format=state['format'] as String? ??_format;
      _cropMode=state['cropMode'] as String? ??_cropMode;
      _cropRatio=state['cropRatio'] as String? ??_cropRatio;
      final crop=state['crop'];
      if(crop is List&&crop.length==4)_crop=Rect.fromLTRB(
        number(crop[0],.06),number(crop[1],.06),
        number(crop[2],.94),number(crop[3],.94));
      final corners=state['cropCorners'];
      if(corners is List&&corners.length==4){
        _cropCorners=[for(final item in corners)
          if(item is List&&item.length==2)
            Offset(number(item[0],.5),number(item[1],.5))];
        if(_cropCorners.length!=4)_cropCorners=[
          _crop.topLeft,_crop.topRight,_crop.bottomRight,_crop.bottomLeft];
      }
      _eraseRadius=number(state['eraseRadius'],_eraseRadius);
      _softness=number(state['softness'],_softness);
      _eraseMode=state['eraseMode'] as String? ??_eraseMode;
      _fineAngle=number(state['fineAngle'],0);
      _straightenAutoCrop=state['straightenAutoCrop'] as bool? ??true;
      _backgroundEngine=state['backgroundEngine'] as String? ?? _backgroundEngine;
      _enhanceScale=(state['enhanceScale'] as num?)?.toInt() ?? 2;
      _enhanceStrength=(state['enhanceStrength'] as num?)?.toDouble() ?? .8;
      _enhanceFaceMode=state['enhanceFaceMode'] as bool? ?? false;
      _faceUseCrop=state['faceUseCrop'] as bool? ?? false;
      _quality=(state['quality'] as num?)?.toInt()??_quality;
      _targetKb=(state['targetKb'] as num?)?.toInt()??_targetKb;
      _brightness=number(state['brightness'],_brightness);
      _contrast=number(state['contrast'],_contrast);
      _saturation=number(state['saturation'],_saturation);
      _exposure=number(state['exposure'],_exposure);
      if(state['backgroundColor'] is int){
        _background=Color(state['backgroundColor'] as int);
      }
    });
  }

  Future<void> _saveDraft() {
    final bytes=_bytes,id=_draftId;
    if(bytes==null||id==null)return _historyQueue;
    // Snapshot before enqueueing; subsequent strokes cannot mutate this save.
    final name=_name, steps=List<String>.of(_steps);
    final original=_originalBytes;
    _historyQueue=_historyQueue.catchError((Object _) {}).then((_) async {
      await ImageEditingHistory.instance.save(id:id,name:name,
        bytes:bytes,steps:steps,originalBytes:original);
    });
    return _historyQueue;
  }

  Future<void> _apply(String action, Map<String,Object?> options,
      {String? description}) async {
    if(_busy)return;
    await _eraseQueue;
    final bytes=_bytes;
    if(bytes==null||_busy)return;
    _processingAction=action;
    setState(()=>_busy=true);
    try{
      final next=await ImageEditingEngine.edit(bytes,action,options);
      await _commit(bytes,next,description??action);
    }catch(e){_message('Editing failed: $e');}
    finally{_processingAction=null;if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _commit(Uint8List previous,Uint8List next,String step) async {
    if(!mounted){
      // A user may send the last completed snapshot to Cart while AI is
      // processing. The late result belongs in the draft history, not lost
      // because the Editor route was closed.
      final id=_draftId;
      if(id!=null)await ImageEditingHistory.instance.save(
        id:id,name:_name,bytes:next,steps:[..._steps,step],
        originalBytes:_originalBytes);
      return;
    }
    _undo.add(previous);
    if(_undo.length>15)_undo.removeAt(0);
    _redo.clear();
    _steps.add(step);
    if(!step.startsWith('Background') && !step.startsWith('Remove plain-color')){
      _cutoutBytes=null; // A crop or other transform changed image geometry.
    }
    // Keep geometry from the last decoded image for color/erase/filter edits.
    // These do not change pixels dimensions; decoding them a second time for
    // every tool Apply was unnecessarily stalling frame delivery.
    final geometryChanged=step.toLowerCase().contains('crop') ||
      step.toLowerCase().contains('straighten') ||
      step.toLowerCase().contains('rotate') ||
      step.toLowerCase().contains('resize');
    final dimensions=geometryChanged
      ?await ImageEditingEngine.dimensions(next):null;
    if(!mounted)return;
    setState((){
      _bytes=next;
      if(dimensions!=null)_ratio=dimensions[0]/dimensions[1];
      _crop=const Rect.fromLTWH(.06,.06,.88,.88);
      _cropCorners=[const Offset(.06,.06),const Offset(.94,.06),
        const Offset(.94,.94),const Offset(.06,.94)];
    });
    // Only the Erase tool needs decoded UI images. Decode asynchronously
    // and cache when selected; the active image is already GPU-rendered.
    if(_tool=='Erase')unawaited(_cacheEraseImage(next));
    if(!step.startsWith('Manual ')&&!step.startsWith('Background')&&_tool=='Erase'){
      unawaited(_cacheEraseImage(next,original:true));
    }
    // IO failures should not interrupt GPU interaction or surface as an
    // unhandled asynchronous exception; the next save may still succeed.
    unawaited(_saveDraft().catchError((Object _) {}));
  }

  Future<void> _historyStep(bool undo) async {
    await _eraseQueue;
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
    await _cacheEraseImage(next);
    await _saveDraft();
  }

  /// Prefer ML Kit for portraits. If the installed Android ML Kit/R8 stack
  /// throws (as on the reported release device), run a verified portable
  /// ONNX model instead of surfacing a raw Java stack trace.
  Future<void> _removeBackground() async {
    await _eraseQueue;
    final data=_bytes;
    if(data==null||_busy)return;
    // Keep image canvas still: do not run a full-screen rendering animation.
    _processingAction='background';
    setState(()=>_busy=true);
    try{
      late Uint8List mask;
      late int width,height;
      var engine='';
      Future<void> mlKit() async {
        if(!Platform.isAndroid) {
          throw UnsupportedError('Google ML Kit segmentation is Android-only');
        }
        final dir=await getTemporaryDirectory();
        final temporary=File('${dir.path}/segment_${DateTime.now().microsecondsSinceEpoch}.png');
        final bounded=await ImageEditingEngine.segmentationInput(data);
        await temporary.writeAsBytes(bounded,flush:true);
        final segmenter=SelfieSegmenter(mode:SegmenterMode.single);
        try {
          final result=await segmenter.processImage(
            InputImage.fromFilePath(temporary.path));
          if(result==null || result.width<=0 || result.height<=0 ||
             result.confidences.length!=result.width*result.height){
            throw const FormatException('Google ML Kit mask invalid');
          }
          width=result.width;height=result.height;
          mask=Uint8List.fromList(result.confidences.map(
            (v)=>(v.clamp(0.0,1.0)*255).round()).toList());
          engine='Google ML Kit';
        }finally {
          await segmenter.close();
          if(await temporary.exists())await temporary.delete();
        }
      }
      Future<void> u2NetP() async {
        width=WindowsBackgroundAi.modelSize;
        height=WindowsBackgroundAi.modelSize;
        mask=await WindowsBackgroundAi.segmentationMask(data);
        engine='U²-NetP (ONNX)';
      }
      Future<void> plain() async {
        final bounded=await ImageEditingEngine.segmentationInput(data);
        final dimensions=await ImageEditingEngine.dimensions(bounded);
        width=dimensions[0];height=dimensions[1];
        mask=await ImageEditingEngine.simpleBackgroundMask(
          bounded,tolerance:_tolerance);
        engine='Plain-color edge segmentation';
      }
      if(_backgroundEngine=='Google ML Kit'){
        await mlKit();
      }else if(_backgroundEngine=='U²-NetP (ONNX)'){
        // Android's native ONNX backend can terminate the process before
        // Dart catches an exception. Use stable ML Kit there instead.
        if(Platform.isAndroid)await mlKit();
        else {try{await u2NetP();}catch(_){await plain();}}
      }else if(_backgroundEngine=='Plain-color'){
        await plain();
      }else if(Platform.isAndroid){
        try{await mlKit();}
        catch(_){await plain();}
      }else if(Platform.isWindows){
        try{await u2NetP();}catch(_){await plain();}
      }else{
        await plain();
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
      _processingAction=null;
      if(mounted)setState(()=>_busy=false);
    }
  }

  Future<void> _runPhotoEnhancer() async {
    await _eraseQueue;
    final current=_bytes;
    if(current==null||_busy)return;
    _processingAction='photo_enhance';
    setState((){_busy=true;_enhanceProgress=0;});
    try{
      final Uint8List result;
      if(_enhanceFaceMode){
        // Face mode uses a deliberately chosen face region. The existing
        // Crop selection can be reused without cropping the full image.
        final roi=_faceUseCrop
          ? <double>[_crop.left,_crop.top,_crop.right,_crop.bottom]
          : <double>[.15,.15,.85,.85];
        result=await FaceRestorationEngine.restore(current,
          normalizedRoi:roi,strength:_enhanceStrength);
      }else{
        result=await PhotoEnhancerEngine.enhance(current,
          scale:_enhanceScale,blend:_enhanceStrength,
          onProgress:(p){if(mounted)setState(()=>_enhanceProgress=p);});
      }
      await _commit(current,result,_enhanceFaceMode
        ? 'GFPGAN Face Restoration'
        : 'Photo Enhancer Real-ESRGAN ${_enhanceScale}x');
      _message(_enhanceFaceMode
        ? 'Face restoration applied to the selected area'
        : 'Photo enhanced with Real-ESRGAN ${_enhanceScale}x');
    }catch(e){
      _message('Photo Enhancer could not finish: $e');
    }finally{
      _processingAction=null;
      if(mounted)setState(()=>_busy=false);
    }
  }

  Future<void> _removePlainBackground()async{
    final data=_bytes;
    if(data==null||_busy)return;
    _processingAction='background';
    setState(()=>_busy=true);
    try {
      final bounded=await ImageEditingEngine.segmentationInput(data);
      final dimensions=await ImageEditingEngine.dimensions(bounded);
      final mask=await ImageEditingEngine.simpleBackgroundMask(
        bounded,tolerance:_tolerance);
      final result=await ImageEditingEngine.edit(data,'background',{
        'mask':mask,'maskWidth':dimensions[0],'maskHeight':dimensions[1],
      });
      await _commit(data,result,'Remove plain-color background');
      _cutoutBytes=result;
      _format='PNG';
    }catch(e){_message('Plain background removal failed: $e');}
    finally{
      _processingAction=null;
      if(mounted)setState(()=>_busy=false);
    }
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
    if(picture==null){
      // Changing a swatch is just GPU compositing; no large-image encode.
      setState((){
        _pendingBackgroundColor=selected;
        _background=selected;
        _format='PNG';
      });
      unawaited(_rememberColor(selected));
      return;
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
        _pendingBackgroundColor=null;
        _background=selected;
        _format='PNG';
      });
      unawaited(_rememberColor(selected));
    }catch(_){
      _message('Could not replace this background. Try a different image.');
    }finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _finalizeBackgroundPreview()async{
    final selected=_pendingBackgroundColor,cutout=_cutoutBytes;
    if(selected==null||cutout==null||_busy||_bytes==null)return;
    final previous=_bytes!;
    setState(()=>_busy=true);
    try{
      final next=selected==Colors.transparent?cutout:
        await ImageEditingEngine.edit(cutout,'flatten',{
          'color':selected.toARGB32(),
        });
      await _commit(previous,next,'Background replacement');
      if(mounted)setState(()=>_pendingBackgroundColor=null);
    }catch(_){_message('Could not apply this background.');}
    finally{if(mounted)setState(()=>_busy=false);}
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
    final cart=action=='cart';
    if(_bytes==null)return;
    try{
      // Do not lose a live brush stroke if Send is pressed mid-edit.
      if(_tool=='Erase'&&_stroke.isNotEmpty)_finishGesture();
      await _eraseQueue;
      if(!_busy){
        if(_pendingFilter!=null)await _finalizeFilter();
        if(_fineAngle.abs()>=.001)await _commitStraighten();
        if(_pendingBackgroundColor!=null)await _finalizeBackgroundPreview();
        if(_tool=='Crop'&&(_cropMode=='Perspective Crop'||
            _crop!=const Rect.fromLTWH(.06,.06,.88,.88))){
          await _commitCrop();
        }
        if(_brightness!=1||_contrast!=1||
            _saturation!=1||_exposure!=0){
          await _commitAdjust();
        }
      }
      if(cart){
        await _saveDraft();
        await _saveSession();
      }
      // Every outgoing action must use the LAST COMMITTED EDITED snapshot.
      // The original is preserved separately only for Restore Original.
      // If a processing operation is underway, use the most recent finished
      // snapshot rather than selecting the untouched import.
      final data=_bytes;
      if(data==null)return;
      final type=data.length>=2&&data[0]==0xff&&data[1]==0xd8
        ?'jpg':'png';
      final name='edited_${DateTime.now().microsecondsSinceEpoch}.$type';
      if(cart){
        final directory=await getApplicationSupportDirectory();
        final folder=Directory('${directory.path}${Platform.pathSeparator}image_editing_cart');
        await folder.create(recursive:true);
        final file=File('${folder.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(data,flush:true);
        ImageEditingCart.instance.add(file,name);
        if(mounted)returnToFileShareCart(context);
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
    FileShareTopNotice.show(context,value);
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

  Widget _colorSwatch(Color color)=>Tooltip(
    message:color==Colors.transparent?'Transparent background':
      '#${color.toARGB32().toRadixString(16).padLeft(8,'0').substring(2).toUpperCase()}',
    child:InkWell(
      borderRadius:BorderRadius.circular(28),
      onTap:_busy?null:()=>_replaceBackground(color:color),
      child:Container(width:41,height:41,
        decoration:BoxDecoration(
          color:color==Colors.transparent?Colors.grey.shade200:color,
          shape:BoxShape.circle,
          border:Border.all(color:color==_background?
            FileTheme.violet:Colors.grey.withValues(alpha:.5),
            width:color==_background?3:1)),
        child:color==_background?const Icon(Icons.check_rounded,size:19):null),
    ),
  );

  Widget _toolControls(){
    switch(_tool){
      case 'Background':
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('Background removal engine',
            style:TextStyle(fontWeight:FontWeight.w700,fontSize:12)),
          const SizedBox(height:7),
          DropdownButtonFormField<String>(
            initialValue:_backgroundEngine,
            isExpanded:true,
            decoration:const InputDecoration(
              border:OutlineInputBorder(),
              helperText:'Auto uses ML Kit first on Android, then U²-NetP.'),
            items:[
              const DropdownMenuItem(value:'Auto (ML Kit first)',
                child:Text('Auto · ML Kit first')),
              if(Platform.isAndroid)
                const DropdownMenuItem(value:'Google ML Kit',
                  child:Text('Google ML Kit · Portrait')),
              const DropdownMenuItem(value:'U²-NetP (ONNX)',
                child:Text('U²-NetP · AI subject removal')),
              const DropdownMenuItem(value:'Plain-color',
                child:Text('Plain-color · Edge flood fill')),
            ],
            onChanged:_busy?null:(value){
              if(value!=null)setState(()=>_backgroundEngine=value);
            },
          ),
          const SizedBox(height:12),
          const Text('AI Background Removal',
            style:TextStyle(fontWeight:FontWeight.w800,fontSize:15)),
          const SizedBox(height:8),
          Text('Remove a portrait background or erase unwanted areas.',
            style:TextStyle(color:FileTheme.muted(context),fontSize:12)),
          const SizedBox(height:12),
          SizedBox(width:double.infinity,child:FilledButton.icon(
            onPressed:_busy?null:_removeBackground,
            icon:_busy?const SizedBox(width:18,height:18,
              child:CircularProgressIndicator(strokeWidth:2)):
              const Icon(Icons.auto_fix_high_rounded),
            label:const Text('AI Remove Background'))),
          const SizedBox(height:14),
          const Text('Plain-color background',
            style:TextStyle(fontWeight:FontWeight.w700)),
          _slider('Color tolerance',_tolerance,5,120,
            (v)=>setState(()=>_tolerance=v),(){}),
          SizedBox(width:double.infinity,child:OutlinedButton.icon(
            onPressed:_busy?null:_removePlainBackground,
            icon:const Icon(Icons.colorize_outlined),
            label:const Text('Remove plain-color background'))),
          const SizedBox(height:14),
          SizedBox(width:double.infinity,child:OutlinedButton.icon(
            onPressed:()=>_selectTool('Erase'),
            icon:const Icon(Icons.auto_fix_off_rounded),
            label:const Text('Manual Erase / Restore'))),
          const Divider(height:30),
          Row(children:[
            const Expanded(child:Text('Replace Background',
              style:TextStyle(fontWeight:FontWeight.w800,fontSize:15))),
            Container(height:27,width:27,decoration:BoxDecoration(
              color:_background,shape:BoxShape.circle,
              border:Border.all(color:FileTheme.violet))),
          ]),
          const SizedBox(height:10),
          const Text('Preset colors',style:TextStyle(fontSize:12)),
          const SizedBox(height:7),
          Wrap(spacing:9,runSpacing:9,children:[
            for(final color in _colors)_colorSwatch(color),
          ]),
          if(_recentColors.isNotEmpty) ...[
            const SizedBox(height:14),
            const Text('Recently used colors',
              style:TextStyle(fontSize:12,fontWeight:FontWeight.w600)),
            const SizedBox(height:8),
            Wrap(spacing:9,runSpacing:9,children:[
              for(final color in _recentColors)_colorSwatch(color),
            ]),
          ],
          const SizedBox(height:13),
          Wrap(spacing:9,runSpacing:8,children:[
            OutlinedButton.icon(onPressed:_busy?null:_pickBackground,
              icon:const Icon(Icons.photo_library_outlined),
              label:const Text('Gallery')),
            FilledButton.tonalIcon(
              onPressed:_busy?null:_customColorDialog,
              icon:const Icon(Icons.palette_outlined),
              label:const Text('Full Spectrum Color Picker')),
          ]),
        ]);
      case 'Photo Enhancer':
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('AI Photo Enhancer',
            style:TextStyle(fontWeight:FontWeight.w800,fontSize:15)),
          const SizedBox(height:8),
          SegmentedButton<bool>(
            segments:const [
              ButtonSegment(value:false,label:Text('Photo HD')),
              ButtonSegment(value:true,label:Text('Face Restore')),
            ],selected:{_enhanceFaceMode},
            onSelectionChanged:_busy?null:(v)=>
              setState(()=>_enhanceFaceMode=v.first)),
          const SizedBox(height:12),
          if(!_enhanceFaceMode)...[
            Text('Real-ESRGAN ONNX: 2× resolution, or 4× with two '
              '2× passes. First use downloads a verified model (~67 MB). '
              'Following edits run entirely offline.',
              style:TextStyle(color:FileTheme.muted(context),fontSize:12)),
            const SizedBox(height:12),
            SegmentedButton<int>(
              segments:const [
                ButtonSegment(value:2,label:Text('2× HD')),
                ButtonSegment(value:4,label:Text('4× Ultra HD')),
              ],selected:{_enhanceScale},
              onSelectionChanged:_busy?null:(v)=>
                setState(()=>_enhanceScale=v.first)),
          ]else...[
            Text('GFPGAN v1.4 restores one front-facing, approximately '
              'aligned face. First use downloads a verified model (~170 MB). '
              'Face details are AI estimates and may alter identity.',
              style:TextStyle(color:FileTheme.muted(context),fontSize:12)),
            const SizedBox(height:10),
            SwitchListTile.adaptive(
              dense:true,contentPadding:EdgeInsets.zero,
              title:const Text('Use Crop selection as face region'),
              subtitle:const Text('Select the face in Crop first, '
                'then return here without applying Crop.'),
              value:_faceUseCrop,
              onChanged:_busy?null:(v)=>setState(()=>_faceUseCrop=v)),
            if(!_faceUseCrop)
              Text('Otherwise uses the central 70% of the picture. '
                'Best for a centered single-face portrait.',
                style:TextStyle(color:FileTheme.muted(context),fontSize:11)),
            OutlinedButton.icon(
              onPressed:_busy?null:()=>_selectTool('Crop'),
              icon:const Icon(Icons.crop_free_rounded),
              label:const Text('Select face area with Crop')),
          ],
          const SizedBox(height:12),
          _slider('AI strength',_enhanceStrength,0,1,
            (v)=>setState(()=>_enhanceStrength=v),(){}),
          Text('Less strength preserves more of the original photo. '
            'AI reconstruction does not guarantee authentic lost detail.',
            style:TextStyle(color:FileTheme.muted(context),fontSize:11)),
          if(_processingAction=='photo_enhance')...[
            const SizedBox(height:12),
            LinearProgressIndicator(
              value:_enhanceFaceMode?null:_enhanceProgress,
              minHeight:5,borderRadius:BorderRadius.circular(4)),
            if(!_enhanceFaceMode)
              Text('${(_enhanceProgress*100).round()}%'),
          ],
          const SizedBox(height:14),
          SizedBox(width:double.infinity,child:FilledButton.icon(
            onPressed:_busy?null:_runPhotoEnhancer,
            icon:const Icon(Icons.auto_awesome_rounded),
            label:Text(_enhanceFaceMode
              ? 'Restore Face' : 'Enhance Photo'))),
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
          const Text('Drag corners or side handles in Normal Crop. Align document corners in Perspective Crop.'),
          const SizedBox(height:8),
          SegmentedButton<String>(
            segments:const [
              ButtonSegment(value:'Normal Crop',label:Text('Normal Crop')),
              ButtonSegment(value:'Perspective Crop',label:Text('Perspective Crop')),
            ],
            selected:{_cropMode},
            onSelectionChanged:(value)=>setState((){
              _cropMode=value.first;
              if(_cropMode=='Normal Crop'){
                final left=_cropCorners.map((p)=>p.dx).reduce(math.min);
                final right=_cropCorners.map((p)=>p.dx).reduce(math.max);
                final top=_cropCorners.map((p)=>p.dy).reduce(math.min);
                final bottom=_cropCorners.map((p)=>p.dy).reduce(math.max);
                _crop=Rect.fromLTRB(left,top,right,bottom);
                _cropCorners=[_crop.topLeft,_crop.topRight,_crop.bottomRight,_crop.bottomLeft];
              }
            })),
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
      case 'Straighten':
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('Fine rotation in 0.5° increments',
            style:TextStyle(fontSize:12)),
          Center(child:Text('${_fineAngle.toStringAsFixed(1)}°',
            style:const TextStyle(fontWeight:FontWeight.w700,fontSize:19))),
          Slider(min:-45,max:45,divisions:180,value:_fineAngle,
            onChanged:(v)=>setState(()=>_fineAngle=v)),
          Row(children:[
            TextButton.icon(onPressed:()=>setState(()=>_fineAngle=0),
              icon:const Icon(Icons.restart_alt),label:const Text('Reset')),
            Expanded(child:SwitchListTile(dense:true,
              title:const Text('Auto-crop corners'),
              value:_straightenAutoCrop,
              onChanged:(v)=>setState(()=>_straightenAutoCrop=v))),
          ]),
          FilledButton.icon(onPressed:_busy?null:()=>unawaited(_commitStraighten()),
            icon:const Icon(Icons.straighten),
            label:const Text('Apply Straighten')),
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
    // GPU preview updates instantly; defer full-resolution raster until Apply or export.
    setState((){_selectedFilter=type;_pendingFilter=type;});
  }
  Future<void> _finalizeFilter()async{
    final type=_pendingFilter;
    if(type==null||_bytes==null||_busy)return;
    if(type=='Normal'){setState(()=>_pendingFilter=null);return;}
    final previous=_bytes!;
    setState(()=>_busy=true);
    try{
      final next=await ImageEditingEngine.edit(previous,'filter',{'name':type});
      await _commit(previous,next,'Filter: $type');
      if(mounted)setState(()=>_pendingFilter=null);
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
  Future<void> _commitStraighten()async{
    final degrees=_fineAngle;
    if(degrees.abs()<.001)return;
    await _apply('straighten',{'degrees':degrees,'autoCrop':_straightenAutoCrop},
      description:'Straighten ${degrees.toStringAsFixed(1)}°');
    if(mounted)setState(()=>_fineAngle=0);
  }
  Future<void> _commitAdjust()async{
    if(_busy)return;
    final options=<String,Object?>{
      'brightness':_brightness,'contrast':_contrast,
      'saturation':_saturation,'exposure':_exposure,
    };
    setState((){
      _brightness=1;_contrast=1;_saturation=1;_exposure=0;
    });
    await _apply('adjust',options);
  }
  Future<void> _commitCrop()async{
    if(_busy)return;
    if(_cropMode=='Normal Crop'){
      final crop=_crop;
      final before=_bytes;
      final ratio=_ratio;
      if(before==null)return;
      setState((){
        _instantCrop=crop;
        _ratio=ratio*crop.width/crop.height;
      });
      await _apply('crop',{
        'x':crop.left,'y':crop.top,'w':crop.width,'h':crop.height,
      },description:'Normal crop').whenComplete((){
        if(mounted)setState((){
          _instantCrop=null;
          if(identical(_bytes,before))_ratio=ratio;
        });
      });
      return;
    }
    final points=_cropCorners;
    await _apply('perspective',{
      'tlx':points[0].dx,'tly':points[0].dy,
      'trx':points[1].dx,'try':points[1].dy,
      'brx':points[2].dx,'bry':points[2].dy,
      'blx':points[3].dx,'bly':points[3].dy,
    },description:'Perspective freeform crop');
  }

  Future<void> _customColorDialog() async {
    var picked=_custom;
    var mode='HSV';
    final hex=TextEditingController();
    final rgb=List.generate(3,(_)=>TextEditingController());
    final hsvFields=List.generate(3,(_)=>TextEditingController());
    void syncFields(Color color){
      hex.text=color.toARGB32().toRadixString(16).padLeft(8,'0')
        .substring(2).toUpperCase();
      final channels=[color.r,color.g,color.b];
      for(var i=0;i<3;i++)rgb[i].text=(channels[i]*255).round().toString();
      final v=HSVColor.fromColor(color);
      final values=[v.hue,v.saturation*100,v.value*100];
      for(var i=0;i<3;i++)hsvFields[i].text=values[i].toStringAsFixed(i==0?1:0);
    }
    syncFields(picked);
    try {
      final selected=await showDialog<Color>(context:context,
        builder:(dialog)=>StatefulBuilder(builder:(context,refresh){
          void choose(Color color,{bool updateText=true}){
            refresh(()=>picked=color);
            if(updateText)syncFields(color);
          }
          final hsv=HSVColor.fromColor(picked);
          return AlertDialog(
            title:const Text('Full Spectrum Color Picker'),
            insetPadding:const EdgeInsets.symmetric(horizontal:14,vertical:20),
            content:SizedBox(width:340,child:SingleChildScrollView(
              child:Column(mainAxisSize:MainAxisSize.min,children:[
                Container(height:44,decoration:BoxDecoration(color:picked,
                  borderRadius:BorderRadius.circular(9),
                  border:Border.all(color:Colors.white54))),
                const SizedBox(height:10),
                AspectRatio(aspectRatio:1.1,
                  child:LayoutBuilder(builder:(context,box){
                    final side=math.min(box.maxWidth,box.maxHeight);
                    void at(Offset p){
                      final center=Offset(side/2,side/2);
                      final dx=p.dx-center.dx,dy=p.dy-center.dy;
                      final radius=side*.46;
                      final distance=math.sqrt(dx*dx+dy*dy);
                      final hue=(math.atan2(dy,dx)*180/math.pi+360)%360;
                      final saturation=(distance/radius).clamp(0.0,1.0).toDouble();
                      choose(HSVColor.fromAHSV(hsv.alpha,hue,saturation,
                        hsv.value).toColor());
                    }
                    return Center(child:SizedBox(width:side,height:side,
                      child:GestureDetector(
                        behavior:HitTestBehavior.opaque,
                        onPanDown:(d)=>at(d.localPosition),
                        onPanUpdate:(d)=>at(d.localPosition),
                        child:CustomPaint(painter:_FullSpectrumWheel(hsv))),
                    ));
                  })),
                const SizedBox(height:9),
                Row(children:[
                  const Text('Brightness'),
                  Expanded(child:Slider(value:hsv.value,min:0,max:1,
                    onChanged:(value)=>choose(hsv.withValue(value).toColor()))),
                  Text('${(hsv.value*100).round()}%'),
                ]),
                SegmentedButton<String>(
                  showSelectedIcon:false,
                  segments:const [
                    ButtonSegment(value:'RGB',label:Text('RGB')),
                    ButtonSegment(value:'HSV',label:Text('HSV')),
                    ButtonSegment(value:'HEX',label:Text('HEX')),
                  ],
                  selected:{mode},
                  onSelectionChanged:(v)=>refresh(()=>mode=v.first)),
                const SizedBox(height:12),
                if(mode=='RGB')
                  Row(children:[for(var i=0;i<3;i++)
                    Expanded(child:Padding(
                      padding:EdgeInsets.only(right:i==2?0:7),
                      child:TextField(controller:rgb[i],
                        keyboardType:TextInputType.number,
                        decoration:InputDecoration(
                          isDense:true,labelText:['R','G','B'][i],
                          border:const OutlineInputBorder()),
                        onChanged:(_){
                          final values=rgb.map((t)=>int.tryParse(t.text)).toList();
                          if(values.any((n)=>n==null||n<0||n>255))return;
                          choose(Color.fromARGB(255,
                            values[0]!,values[1]!,values[2]!),
                            updateText:false);
                          hex.text=picked.toARGB32().toRadixString(16)
                            .padLeft(8,'0').substring(2).toUpperCase();
                        }),
                    )),
                  ])
                else if(mode=='HSV')
                  Row(children:[for(var i=0;i<3;i++)
                    Expanded(child:Padding(
                      padding:EdgeInsets.only(right:i==2?0:7),
                      child:TextField(controller:hsvFields[i],
                        keyboardType:const TextInputType.numberWithOptions(decimal:true),
                        decoration:InputDecoration(
                          isDense:true,labelText:['H°','S%','V%'][i],
                          border:const OutlineInputBorder()),
                        onChanged:(_){
                          final v=hsvFields.map((t)=>double.tryParse(t.text)).toList();
                          if(v.any((n)=>n==null)||v[0]!<0||v[0]!>360||
                              v[1]!<0||v[1]!>100||v[2]!<0||v[2]!>100)return;
                          choose(HSVColor.fromAHSV(1,v[0]!,v[1]!/100,
                            v[2]!/100).toColor(),updateText:false);
                          hex.text=picked.toARGB32().toRadixString(16)
                            .padLeft(8,'0').substring(2).toUpperCase();
                          final rgbValues=[picked.r,picked.g,picked.b];
                          for(var j=0;j<3;j++)rgb[j].text=
                            (rgbValues[j]*255).round().toString();
                        }),
                    )),
                  ])
                else TextField(controller:hex,
                  textCapitalization:TextCapitalization.characters,
                  decoration:const InputDecoration(
                    labelText:'HEX — six digits',prefixText:'#',
                    border:OutlineInputBorder(),isDense:true),
                  onChanged:(text){
                    final normalized=text.replaceFirst('#','');
                    if(!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(normalized))return;
                    choose(Color(0xff000000|int.parse(normalized,radix:16)),
                      updateText:false);
                    final channels=[picked.r,picked.g,picked.b];
                    for(var j=0;j<3;j++)rgb[j].text=
                      (channels[j]*255).round().toString();
                  }),
                const SizedBox(height:8),
                const Text('Move anywhere on the wheel to choose hue and '
                  'saturation. Adjust brightness or enter an exact color.',
                  style:TextStyle(fontSize:11)),
              ]),
            )),
            actions:[
              TextButton(onPressed:()=>Navigator.pop(dialog),
                child:const Text('Cancel')),
              FilledButton(onPressed:()=>Navigator.pop(dialog,picked),
                child:const Text('Use Color')),
            ],
          );
        }));
      if(selected!=null){
        _custom=selected;
        await _replaceBackground(color:selected);
      }
    }finally{
      hex.dispose();
      for(final t in rgb)t.dispose();
      for(final t in hsvFields)t.dispose();
    }
  }

  void _startGesture(DragStartDetails d,Size size){
    final point=Offset((d.localPosition.dx/size.width).clamp(0.0,1.0),
      (d.localPosition.dy/size.height).clamp(0.0,1.0));
    if(_tool=='Crop'){
      _activeCropHandle=null;
      final corners=_cropCorners;
      final handles=<Offset>[
        ...corners,
        if(_cropMode=='Normal Crop') ...[
          Offset((corners[0].dx+corners[1].dx)/2,corners[0].dy),
          Offset(corners[1].dx,(corners[1].dy+corners[2].dy)/2),
          Offset((corners[2].dx+corners[3].dx)/2,corners[2].dy),
          Offset(corners[3].dx,(corners[3].dy+corners[0].dy)/2),
        ],
      ];
      final touch=math.max(22.0,math.min(size.width,size.height)*.025);
      var best=double.infinity;
      for(var i=0;i<handles.length;i++){
        final hp=Offset(handles[i].dx*size.width,handles[i].dy*size.height);
        final distance=(hp-d.localPosition).distance;
        if(distance<=touch && distance<best){
          best=distance;_activeCropHandle=i;
        }
      }
    }else if(_tool=='Erase'){
      if(_busy)return;
      _stroke..clear()..add(point);
      _strokeRepaint.value++;
    }
  }
  void _changeGesture(DragUpdateDetails d,Size size){
    if(_tool=='Crop'){
      final dx=d.delta.dx/size.width,dy=d.delta.dy/size.height;
      setState((){
        final index=_activeCropHandle;
        if(_cropMode=='Normal Crop'&&index!=null){
          const minimum=.025;
          var left=_crop.left,right=_crop.right,top=_crop.top,bottom=_crop.bottom;
          if(index==0||index==3||index==7)left=(left+dx).clamp(0.0,right-minimum).toDouble();
          if(index==1||index==2||index==5)right=(right+dx).clamp(left+minimum,1.0).toDouble();
          if(index==0||index==1||index==4)top=(top+dy).clamp(0.0,bottom-minimum).toDouble();
          if(index==2||index==3||index==6)bottom=(bottom+dy).clamp(top+minimum,1.0).toDouble();
          _crop=Rect.fromLTRB(left,top,right,bottom);
          _cropCorners=[_crop.topLeft,_crop.topRight,_crop.bottomRight,_crop.bottomLeft];
        }else if(index!=null){
          final old=_cropCorners[index];
          _cropCorners[index]=Offset((old.dx+dx).clamp(0.0,1.0).toDouble(),
            (old.dy+dy).clamp(0.0,1.0).toDouble());
        }else{
          final left=_cropCorners.map((p)=>p.dx).reduce(math.min);
          final right=_cropCorners.map((p)=>p.dx).reduce(math.max);
          final top=_cropCorners.map((p)=>p.dy).reduce(math.min);
          final bottom=_cropCorners.map((p)=>p.dy).reduce(math.max);
          final tx=dx.clamp(-left,1-right).toDouble();
          final ty=dy.clamp(-top,1-bottom).toDouble();
          _cropCorners=[for(final p in _cropCorners)p+Offset(tx,ty)];
          if(_cropMode=='Normal Crop')_crop=_crop.shift(Offset(tx,ty));
        }
      });
    }else if(_tool=='Erase'){
      final point=Offset((d.localPosition.dx/size.width).clamp(0,1).toDouble(),
        (d.localPosition.dy/size.height).clamp(0,1).toDouble());
      if(_stroke.isEmpty || (_stroke.last-point).distanceSquared>0.00000025){
        _stroke.add(point);
        _strokeRepaint.value++;
      }
    }
  }
  void _finishGesture(){
    if(_tool!='Erase'||_stroke.isEmpty)return;
    final pending=_LiveEraseStroke(List.unmodifiable(_stroke),_eraseMode,
      _eraseRadius,_softness);
    setState((){
      _pendingErase.add(pending);
      _stroke.clear();
    });
    _eraseQueue=_eraseQueue.then((_)async{
      final before=_bytes;
      if(before==null)return;
      final next=await ImageEditingEngine.edit(before,
        pending.mode.toLowerCase(),{
          'points':[for(final p in pending.points){'x':p.dx,'y':p.dy}],
          'radius':pending.radius,'softness':pending.softness,
        });
      await _commit(before,next,'Manual ${pending.mode.toLowerCase()}');
      if(mounted)setState(()=>_pendingErase.remove(pending));
    }).catchError((Object e){
      if(mounted){
        setState(()=>_pendingErase.remove(pending));
        _message('Could not complete this erase stroke.');
      }
    });
  }

  /// Slider feedback uses the GPU color-matrix while dragging; final
  /// full-quality pixels are processed off the UI isolate on release.
  Widget _liveAdjustment(Widget child){
    if(_brightness==1&&_contrast==1&&_saturation==1&&_exposure==0)return child;
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
        if(_pendingBackgroundColor!=null && _pendingBackgroundColor!=Colors.transparent)
          ColoredBox(color:_pendingBackgroundColor!),
        _liveAdjustment(_fastFilterPreview(
          Transform.rotate(angle:_fineAngle*math.pi/180,
            child:(_instantCrop!=null&&_erasePreview!=null)
              ?CustomPaint(painter:_InstantCropPainter(
                image:_erasePreview!,crop:_instantCrop!))
              :(_tool=='Erase'&&_erasePreview!=null)
              ?CustomPaint(painter:_RealtimeEraserPainter(
                image:_erasePreview!,restoration:_eraseRestoration,
                pending:_pendingErase,active:_stroke,mode:_eraseMode,
                radius:_eraseRadius,softness:_softness,
                repaintTrigger:_strokeRepaint))
              :Image.memory(
                  _pendingBackgroundColor!=null&&_cutoutBytes!=null?
                    _cutoutBytes!:_bytes!,fit:BoxFit.fill,
                  cacheWidth:(width*MediaQuery.devicePixelRatioOf(context))
                    .round().clamp(1,1920),
                  gaplessPlayback:true,filterQuality:FilterQuality.medium)))),
        if(_tool=='Crop'&&_instantCrop==null)
          CustomPaint(painter:_CropPainter(_cropCorners,
          showSideHandles:_cropMode=='Normal Crop')),

        if(_showOriginal && _originalBytes!=null)
          Image.memory(_originalBytes!,fit:BoxFit.fill),
      ]);
      if(_tool=='Crop'||_tool=='Erase'){
        canvas=GestureDetector(
          onPanStart:(d)=>_startGesture(d,size),
          onPanUpdate:(d)=>_changeGesture(d,size),
          onPanEnd:(_)=>_finishGesture(),
          onPanCancel:_finishGesture,
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

  Widget _fastFilterPreview(Widget child){
    final type=_pendingFilter;
    final matrix=switch(type){
      'B&W'=><double>[.2126,.7152,.0722,0,0,.2126,.7152,.0722,0,0,.2126,.7152,.0722,0,0,0,0,0,1,0],
      'Vivid'=><double>[1.18,0,0,0,0,0,1.12,0,0,0,0,0,1.1,0,0,0,0,0,1,0],
      'Warm'=><double>[1.13,0,0,0,4,0,1.04,0,0,2,0,0,.83,0,0,0,0,0,1,0],
      'Cool'=><double>[.85,0,0,0,0,0,1.02,0,0,0,0,0,1.15,0,3,0,0,0,1,0],
      'Vintage'=><double>[.393,.769,.189,0,0,.349,.686,.168,0,0,.272,.534,.131,0,0,0,0,0,1,0],
      _=>null,
    };
    return matrix==null?child:ColorFiltered(
      colorFilter:ColorFilter.matrix(matrix),child:child);
  }
  String _toolTitle(String tool)=>switch(tool){
    'Background'=>'Background Removal',
    'Photo Enhancer'=>'Photo Enhancer',
    'Compress'=>'Compression',
    'Crop'=>'Freeform Crop',
    'Erase'=>'Manual Erase',
    'Adjust'=>'Adjustments',
    'Straighten'=>'Straighten',
    _=>tool,
  };
  IconData _toolIcon(String tool)=>switch(tool){
    'Background'=>Icons.auto_fix_high_rounded,
    'Photo Enhancer'=>Icons.auto_awesome_rounded,
    'Compress'=>Icons.compress_rounded,
    'Crop'=>Icons.crop_free_rounded,
    'Straighten'=>Icons.straighten_rounded,
    'Filters'=>Icons.filter_rounded,
    'Erase'=>Icons.auto_fix_off_rounded,
    _=>Icons.tune_rounded,
  };
  void _selectTool(String tool){
    if(_tool==tool)return;
    // No worker job, image re-encode or full-screen animated crossfade on tab
    // changes. Lazy-build the brush bitmap only when Erase is first selected.
    setState(()=>_tool=tool);
    if(_controlScroll.hasClients)_controlScroll.jumpTo(0);
    if(tool=='Erase' && _bytes!=null){
      unawaited(_cacheEraseImage(_bytes!));
      if(_eraseRestoration==null && _originalBytes!=null){
        unawaited(_cacheEraseImage(_originalBytes!,original:true));
      }
    }
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

  Widget _toolStrip()=>Padding(
    padding:const EdgeInsets.fromLTRB(10,4,10,10),
    child:Container(height:78,
      decoration:BoxDecoration(
        color:Theme.of(context).colorScheme.surface.withValues(alpha:.94),
        borderRadius:BorderRadius.circular(19),
        border:Border.all(color:FileTheme.violet.withValues(alpha:.24)),
        boxShadow:[BoxShadow(color:Colors.black.withValues(alpha:.08),
          blurRadius:12,offset:const Offset(0,4))]),
      child:ListView(scrollDirection:Axis.horizontal,
        padding:const EdgeInsets.symmetric(horizontal:7,vertical:7),
        children:[for(final tool in _tools)Padding(
          padding:const EdgeInsets.symmetric(horizontal:3),
          child:_professionalTool(tool))]),
    ));
  Widget _professionalTool(String tool){
    final selected=_tool==tool;
    return Material(color:selected?FileTheme.violet.withValues(alpha:.17):
      Colors.transparent,borderRadius:BorderRadius.circular(12),
      child:InkWell(onTap:()=>_selectTool(tool),
        borderRadius:BorderRadius.circular(12),
        child:Container(width:76,padding:const EdgeInsets.symmetric(
          horizontal:3,vertical:5),
          child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
            Icon(_toolIcon(tool),size:25,color:selected?
              FileTheme.violet:FileTheme.foreground(context)),
            const SizedBox(height:5),
            Text(tool,maxLines:1,overflow:TextOverflow.ellipsis,
              style:TextStyle(fontSize:10.5,fontWeight:selected?
                FontWeight.w800:FontWeight.w500,
                color:FileTheme.foreground(context))),
          ]))),
    );
  }

  Widget _controls()=>SingleChildScrollView(
    controller:_controlScroll,
    physics:const ClampingScrollPhysics(),
    padding:const EdgeInsets.fromLTRB(16,12,16,14),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(_toolTitle(_tool),style:Theme.of(context).textTheme.titleMedium
        ?.copyWith(fontWeight:FontWeight.w800)),
      const SizedBox(height:8),
      // Avoid dual-page AnimatedSwitcher layouts during every tool change.
      _toolControls(),
    ]));

  Widget _emptyCanvas({required bool wide}){
    return Center(child:SingleChildScrollView(
      child:ConstrainedBox(
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
    )));
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
        if(_busy&&_processingAction!='background'&&
          _processingAction!='crop'&&_processingAction!='straighten')
          const LinearProgressIndicator(minHeight:2),
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
    if(_tool=='Filters'){
      await _finalizeFilter();
    }else if(_tool=='Background'&&_pendingBackgroundColor!=null){
      await _finalizeBackgroundPreview();
    }else if(_tool=='Crop'){
      await _commitCrop();
    }else if(_tool=='Adjust'){
      await _commitAdjust();
    }else if(_tool=='Straighten'){
      await _commitStraighten();
    }else if(_tool=='Compress'){
      await _compress();
    }else{
      await _saveDraft();
      _message('Current image saved in Image History');
    }
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

  Widget _desktopWorkspace()=>Column(children:[
    Expanded(child:Row(children:[
      Expanded(flex:8,child:_previewArea(wide:true)),
      SizedBox(width:365,child:ListView(children:[
        _controls(),
        const Divider(height:24),
        _desktopHistory(),
      ])),
    ])),
    _toolStrip(),
  ]);

  Widget _mobileWorkspace(){
    // Do not consume the preview with controls before an image is selected.
    if(_bytes==null){
      return Column(children:[
        Expanded(child:_previewArea(wide:false)),
        _toolStrip(),
      ]);
    }
    return Column(children:[
      Expanded(flex:7,child:_previewArea(wide:false)),
      SizedBox(height:210,child:_controls()),
      _toolStrip(),
    ]);
  }

  Widget _menu()=>PopupMenuButton<String>(
    tooltip:'More Image Editing options',
    icon:const Icon(Icons.more_vert_rounded),
    onSelected:(value){
      if(value=='history')Navigator.of(context).push(
        fadePage<void>(const ImageEditingHistoryPage()));
      if(value=='share' && _bytes!=null)unawaited(_export('share'));
      if(value=='save' && _bytes!=null)unawaited(_export('save'));
      if(value=='close')Navigator.of(context).maybePop();
      if(value=='apply' && _bytes!=null)unawaited(_applyCurrent());
      if(value=='compare' && _bytes!=null)setState(()=>_showOriginal=!_showOriginal);
    },
    itemBuilder:(_)=>const [
      PopupMenuItem(value:'history',child:Row(children:[
        Icon(Icons.history),SizedBox(width:12),Text('Image History')])),
      PopupMenuItem(value:'share',child:Row(children:[
        Icon(Icons.ios_share_outlined),SizedBox(width:12),
        Text('Share / Export')])),
      PopupMenuItem(value:'save',child:Row(children:[
        Icon(Icons.download_outlined),SizedBox(width:12),Text('Save image')])),
      PopupMenuItem(value:'apply',child:Row(children:[
        Icon(Icons.check),SizedBox(width:12),Text('Apply changes')])),
      PopupMenuItem(value:'compare',child:Row(children:[
        Icon(Icons.compare),SizedBox(width:12),Text('Before / After')])),
      PopupMenuItem(value:'close',child:Row(children:[
        Icon(Icons.close),SizedBox(width:12),Text('Close editor')])),
    ]);

  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(
      titleSpacing:0,
      actionsIconTheme:const IconThemeData(size:19),
      title:const Text('Image Editing',style:TextStyle(fontSize:14)),
      actions:[
        if(MediaQuery.sizeOf(context).width>=580)
        IconButton(tooltip:'Cancel / Close',visualDensity:VisualDensity.compact,
          onPressed:()=>Navigator.of(context).maybePop(),
          icon:const Icon(Icons.close_rounded,size:19)),
        IconButton(tooltip:'Undo',visualDensity:VisualDensity.compact,
          onPressed:_undo.isEmpty||_busy?null:()=>_historyStep(true),
          icon:const Icon(Icons.undo_rounded,size:19)),
        IconButton(tooltip:'Redo',visualDensity:VisualDensity.compact,
          onPressed:_redo.isEmpty||_busy?null:()=>_historyStep(false),
          icon:const Icon(Icons.redo_rounded,size:19)),
        IconButton(tooltip:'Apply',visualDensity:VisualDensity.compact,
          onPressed:_bytes==null||_busy?null:_applyCurrent,
          icon:const Icon(Icons.check_rounded,size:19)),
        if(MediaQuery.sizeOf(context).width>=580)
        IconButton(tooltip:'Share',visualDensity:VisualDensity.compact,
          onPressed:_bytes==null||_busy?null:()=>_export('share'),
          icon:const Icon(Icons.share_outlined,size:19)),
        if(MediaQuery.sizeOf(context).width>=580)
        IconButton(tooltip:'Download',visualDensity:VisualDensity.compact,
          onPressed:_bytes==null||_busy?null:()=>_export('save'),
          icon:const Icon(Icons.download_rounded,size:19)),
        IconButton(tooltip:'Send to File Share Cart',visualDensity:VisualDensity.compact,
          onPressed:_bytes==null?null:()=>_export('cart'),
          icon:const Icon(Icons.shopping_cart_outlined,size:19)),
        _menu(),
      ]),
    body:Container(
      decoration:BoxDecoration(gradient:FileTheme.background(context)),
      child:LayoutBuilder(builder:(context,constraints)=>
        constraints.maxWidth>=900?_desktopWorkspace():_mobileWorkspace()),
    ),
  );
}

/// Full hue range around the circle; radius represents saturation.
class _FullSpectrumWheel extends CustomPainter {
  const _FullSpectrumWheel(this.hsv);
  final HSVColor hsv;
  @override void paint(Canvas canvas,Size size){
    final center=Offset(size.width/2,size.height/2);
    final radius=math.min(size.width,size.height)*.46;
    final bounds=Rect.fromCircle(center:center,radius:radius);
    canvas.drawCircle(center,radius,Paint()..shader=SweepGradient(
      colors:[for(var i=0;i<=12;i++)
        HSVColor.fromAHSV(1,i*30.0,1,1).toColor()],
      stops:[for(var i=0;i<=12;i++)i/12],
    ).createShader(bounds));
    canvas.drawCircle(center,radius,Paint()..shader=RadialGradient(
      colors:[Colors.white,Colors.white.withValues(alpha:0)],
      stops:const [0,1],
    ).createShader(bounds));
    final a=hsv.hue*math.pi/180;
    final pos=center+Offset(math.cos(a),math.sin(a))*radius*hsv.saturation;
    canvas.drawCircle(pos,8,Paint()..color=Colors.white
      ..style=PaintingStyle.stroke..strokeWidth=3);
    canvas.drawCircle(pos,9,Paint()..color=Colors.black87
      ..style=PaintingStyle.stroke..strokeWidth=1);
  }
  @override bool shouldRepaint(covariant _FullSpectrumWheel old)=>old.hsv!=hsv;
}
class _SaturationValuePicker extends CustomPainter {
  const _SaturationValuePicker(this.color);
  final HSVColor color;
  @override void paint(Canvas canvas,Size size){
    final rect=Offset.zero & size;
    canvas.drawRect(rect,Paint()..shader=ui.Gradient.linear(
      const Offset(0,0),Offset(size.width,0),
      [Colors.white,HSVColor.fromAHSV(1,color.hue,1,1).toColor()]));
    canvas.drawRect(rect,Paint()..shader=ui.Gradient.linear(
      const Offset(0,0),Offset(0,size.height),
      [Colors.transparent,Colors.black]));
    final point=Offset(color.saturation*size.width,
      (1-color.value)*size.height);
    canvas.drawCircle(point,8,Paint()..color=Colors.white
      ..style=PaintingStyle.stroke..strokeWidth=3);
    canvas.drawCircle(point,9.5,Paint()..color=Colors.black54
      ..style=PaintingStyle.stroke..strokeWidth=1);
  }
  @override bool shouldRepaint(covariant _SaturationValuePicker old)=>
    old.color!=color;
}
class _HueColorPicker extends CustomPainter {
  const _HueColorPicker(this.hue);
  final double hue;
  @override void paint(Canvas canvas,Size size){
    canvas.drawRRect(RRect.fromRectAndRadius(
      Offset.zero & size,const Radius.circular(10)),
      Paint()..shader=ui.Gradient.linear(
        const Offset(0,0),Offset(size.width,0),[
          for(var i=0;i<=6;i++)
            HSVColor.fromAHSV(1,i*60.0,1,1).toColor(),
        ]));
    final x=(hue/360).clamp(0,1)*size.width;
    canvas.drawCircle(Offset(x,size.height/2),size.height*.44,
      Paint()..color=Colors.white..style=PaintingStyle.stroke
        ..strokeWidth=3);
  }
  @override bool shouldRepaint(covariant _HueColorPicker old)=>old.hue!=hue;
}

class _InstantCropPainter extends CustomPainter{
  const _InstantCropPainter({required this.image,required this.crop});
  final ui.Image image;
  final Rect crop;
  @override void paint(Canvas canvas,Size size){
    final source=Rect.fromLTRB(crop.left*image.width,
      crop.top*image.height,crop.right*image.width,
      crop.bottom*image.height);
    canvas.drawImageRect(image,source,Offset.zero&size,
      Paint()..filterQuality=FilterQuality.medium);
  }
  @override bool shouldRepaint(covariant _InstantCropPainter old)=>
    old.image!=image||old.crop!=crop;
}

class _LiveEraseStroke {
  const _LiveEraseStroke(this.points,this.mode,this.radius,this.softness);
  final List<Offset> points;
  final String mode;
  final double radius,softness;
}

/// Low-resolution cached bitmap stays on the GPU. Each touch updates only
/// the stroke mask; the full-resolution pixel operation is queued separately.
class _RealtimeEraserPainter extends CustomPainter {
  _RealtimeEraserPainter({required this.image,required this.restoration,
    required this.pending,required this.active,required this.mode,
    required this.radius,required this.softness,
    required this.repaintTrigger}):super(repaint:repaintTrigger);
  final Listenable repaintTrigger;
  final ui.Image image;
  final ui.Image? restoration;
  final List<_LiveEraseStroke> pending;
  final List<Offset> active;
  final String mode;
  final double radius,softness;

  @override void paint(Canvas canvas,Size size){
    final bounds=Offset.zero & size;
    final imageRect=Rect.fromLTWH(0,0,image.width.toDouble(),image.height.toDouble());
    canvas.saveLayer(bounds,Paint());
    canvas.clipRect(bounds);
    canvas.drawImageRect(image,imageRect,bounds,Paint()..filterQuality=FilterQuality.medium);
    void stroke(List<Offset> points,String operation,double r,double feather){
      if(points.isEmpty)return;
      final width=r*math.min(size.width,size.height)*2;
      final path=Path()..moveTo(points.first.dx*size.width,points.first.dy*size.height);
      for(final point in points.skip(1)){
        path.lineTo(point.dx*size.width,point.dy*size.height);
      }
      if(operation=='Restore'&&restoration!=null){
        final original=restoration!;
        final p=Paint()..style=PaintingStyle.stroke
          ..strokeWidth=width..strokeCap=StrokeCap.round
          ..strokeJoin=StrokeJoin.round
          ..shader=ui.ImageShader(original,ui.TileMode.clamp,ui.TileMode.clamp,
            Matrix4.diagonal3Values(size.width/original.width,
              size.height/original.height,1).storage);
        if(points.length==1){
          canvas.drawCircle(Offset(points.first.dx*size.width,
            points.first.dy*size.height),width/2,p..style=PaintingStyle.fill);
        }else{
          canvas.drawPath(path,p);
        }
      }else{
        final p=Paint()..blendMode=BlendMode.clear
          ..isAntiAlias=true..color=Colors.black
          ..strokeWidth=width..strokeCap=StrokeCap.round
          ..strokeJoin=StrokeJoin.round..style=PaintingStyle.stroke;
        if(points.length==1){
          canvas.drawCircle(Offset(points.first.dx*size.width,
            points.first.dy*size.height),width/2,p..style=PaintingStyle.fill);
        }else{
          canvas.drawPath(path,p);
        }
      }
    }
    for(final item in pending)stroke(
      item.points,item.mode,item.radius,item.softness);
    stroke(active,mode,radius,softness);
    canvas.restore();
  }
  @override bool shouldRepaint(covariant _RealtimeEraserPainter old)=>true;
}
class _FullMagicPainter extends CustomPainter {
  const _FullMagicPainter(this.progress);
  final double progress;
  @override void paint(Canvas canvas,Size size){
    final sweep=progress*1.4-.2;
    final x=sweep*size.width;
    final area=Rect.fromLTWH(x-size.width*.26,0,
      size.width*.52,size.height);
    canvas.drawRect(area,Paint()..shader=ui.Gradient.linear(
      Offset(area.left,0),Offset(area.right,0),[
        const Color(0x008E69FF),const Color(0x667D5BE3),
        const Color(0x22F8DFFF),const Color(0x008E69FF)]));
    for(var i=0;i<22;i++){
      final t=i*1.618;
      final px=(progress*size.width*1.3 + i*size.width/22)%(size.width+40)-20;
      final py=(.5+.46*math.sin(t+progress*math.pi*2))*size.height;
      final brightness=(.5+.5*math.sin(progress*math.pi*4+i)).clamp(0.0,1.0);
      final radius=1.2+brightness*3.8;
      final p=Paint()..color=Colors.white.withValues(alpha:.25+.65*brightness);
      canvas.drawCircle(Offset(px,py),radius,p);
      canvas.drawLine(Offset(px-radius*2.5,py),
        Offset(px+radius*2.5,py),p..strokeWidth=1.3);
      canvas.drawLine(Offset(px,py-radius*2.5),
        Offset(px,py+radius*2.5),p);
    }
  }
  @override bool shouldRepaint(covariant _FullMagicPainter old)=>
    old.progress!=progress;
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
  _CropPainter(this.corners,{this.showSideHandles=false});
  final List<Offset> corners;
  final bool showSideHandles;
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
    if(showSideHandles){
      for(var i=0;i<4;i++){
        final p=Offset.lerp(points[i],points[(i+1)%4],.5)!;
        final rect=Rect.fromCenter(center:p,width:i.isEven?30:13,height:i.isEven?13:30);
        canvas.drawRRect(RRect.fromRectAndRadius(rect,const Radius.circular(6)),Paint()..color=Colors.white);
        canvas.drawRRect(RRect.fromRectAndRadius(rect.deflate(2),const Radius.circular(4)),handle);
      }
    }
  }
  @override bool shouldRepaint(covariant _CropPainter old){
    if(old.showSideHandles!=showSideHandles||old.corners.length!=corners.length)return true;
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
    // History's Cart always sends the saved edited stage, not import bytes.
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
