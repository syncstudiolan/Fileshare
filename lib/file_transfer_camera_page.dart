import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Camera in the File Transfer composer. Unlike the Android PDF scanner,
/// this is a cross-platform camera picker/capture screen for Android + Windows.
/// Every available camera exposed by the OS is selectable; physical 3x lenses
/// only appear separately when the device exposes them to the camera API.
class FileTransferCameraPage extends StatefulWidget {
  const FileTransferCameraPage({super.key});
  @override
  State<FileTransferCameraPage> createState() => _FileTransferCameraPageState();
}

class _FileTransferCameraPageState extends State<FileTransferCameraPage>
    with WidgetsBindingObserver {
  final _cameras=<CameraDescription>[];
  CameraController? _controller;
  bool _busy=false;
  bool _loading=true;
  String? _error;
  int _selected=0;
  int _generation=0;
  double _zoom=1;
  double _minZoom=1;
  double _maxZoom=1;

  @override
  void initState(){
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() { _loading=true; _error=null; });
    try {
      final devices=await availableCameras();
      if(!mounted)return;
      _cameras..clear()..addAll(devices);
      if(devices.isEmpty) {
        setState(() { _error='No camera was detected. Connect a webcam or enable camera permission.';_loading=false; });
        return;
      }
      final preferred=devices.indexWhere((c)=>c.lensDirection==CameraLensDirection.back);
      await _openCamera(preferred<0?0:preferred);
    } catch(e) {
      if(mounted)setState(() { _error='Camera unavailable: $e';_loading=false; });
    }
  }

  Future<void> _openCamera(int index) async {
    if(index<0||index>=_cameras.length)return;
    final generation=++_generation;
    final previous=_controller;
    _controller=null;
    setState(() { _loading=true;_error=null;_selected=index; });
    if(previous!=null) {
      try { await previous.dispose(); } catch (_) {}
    }
    final next=CameraController(_cameras[index],ResolutionPreset.high,
      enableAudio:false);
    try {
      await next.initialize();
      if(!mounted||generation!=_generation) {
        await next.dispose();
        return;
      }
      double min=1,max=1;
      try {
        min=await next.getMinZoomLevel();
        max=await next.getMaxZoomLevel();
      } catch (_) { // Unsupported webcam zoom: keep optical camera selector.
        min=1;max=1;
      }
      if(!mounted||generation!=_generation) {
        await next.dispose();
        return;
      }
      setState((){
        _controller=next;
        _minZoom=min;
        _maxZoom=max;
        _zoom=1.0.clamp(min,max).toDouble();
        _loading=false;
      });
    } catch(e) {
      await next.dispose();
      if(mounted&&generation==_generation) {
        setState(() { _loading=false;_error='Cannot open this camera: $e'; });
      }
    }
  }

  Future<void> _setZoom(double value) async {
    final c=_controller;
    if(c==null||!c.value.isInitialized)return;
    final requested=value.clamp(_minZoom,_maxZoom).toDouble();
    try {
      await c.setZoomLevel(requested);
      if(mounted&&identical(c,_controller))setState(()=>_zoom=requested);
    } catch (_) {
      if(mounted)setState(()=>_error='Zoom is not available on this camera.');
    }
  }

  Future<void> _capture() async {
    final c=_controller;
    if(_busy||c==null||!c.value.isInitialized||c.value.isTakingPicture)return;
    setState(()=>_busy=true);
    try {
      final result=await c.takePicture();
      if(!mounted)return;
      final image=File(result.path);
      if(!await image.exists()||await image.length()==0){
        throw StateError('Camera returned an empty image');
      }
      if(mounted)Navigator.of(context).pop<String>(result.path);
    } catch(e) {
      if(mounted)setState(()=>_error='Unable to capture photo: $e');
    } finally {
      if(mounted)setState(()=>_busy=false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if(state==AppLifecycleState.inactive||state==AppLifecycleState.paused){
      ++_generation;
      final previous=_controller;
      _controller=null;
      if(previous!=null)previous.dispose();
    } else if(state==AppLifecycleState.resumed&&_cameras.isNotEmpty){
      _openCamera(_selected);
    }
  }

  @override
  void dispose(){
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  String _label(CameraDescription camera,int index){
    final facing=switch(camera.lensDirection){
      CameraLensDirection.front=>'Front camera',
      CameraLensDirection.back=>'Rear camera',
      CameraLensDirection.external=>'External webcam',
    };
    return '$facing ${index+1} · ${camera.name}';
  }

  @override
  Widget build(BuildContext context){
    final controller=_controller;
    final ready=controller!=null&&controller.value.isInitialized;
    return Scaffold(
      backgroundColor:const Color(0xFF1B1525),
      appBar:AppBar(
        backgroundColor:const Color(0xFF281D36),
        foregroundColor:Colors.white,
        title:const Text('Camera'),
        actions:[
          IconButton(
            tooltip:'Refresh cameras',
            icon:const Icon(Icons.refresh_rounded),
            onPressed:_busy?null:_loadDevices),
        ],
      ),
      body:SafeArea(child:Column(children:[
        Expanded(child:ClipRect(child:SizedBox.expand(child:ready
          // Match the native phone camera: aspect-fill the available viewport.
          // Crop outer preview edges, never distort the image into a strip.
          ?LayoutBuilder(builder:(context,box){
              final preview=controller.value.previewSize;
              final portrait=box.maxHeight>box.maxWidth;
              final w=portrait
                ?(preview?.height??720.0):(preview?.width??1280.0);
              final h=portrait
                ?(preview?.width??1280.0):(preview?.height??720.0);
              return FittedBox(
                fit:BoxFit.cover,
                alignment:Alignment.center,
                clipBehavior:Clip.hardEdge,
                child:SizedBox(width:w,height:h,
                  child:CameraPreview(controller)));
            })
          :Center(child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
              if(_loading)const CircularProgressIndicator(color:Color(0xFFAC91F3)),
              if(!_loading)const Icon(Icons.no_photography_outlined,
                size:55,color:Colors.white70),
              const SizedBox(height:12),
              Text(_loading?'Opening camera…':(_error??'No camera available'),
                textAlign:TextAlign.center,
                style:const TextStyle(color:Colors.white70)),
            ]))))),
        if(_error!=null&&ready)Padding(
          padding:const EdgeInsets.all(8),
          child:Text(_error!,style:const TextStyle(color:Colors.amber))),
        Container(
          color:const Color(0xFF281D36),
          padding:const EdgeInsets.fromLTRB(14,12,14,16),
          child:Column(mainAxisSize:MainAxisSize.min,children:[
            if(_cameras.length>1)DropdownButtonFormField<int>(
              value:_selected,
              dropdownColor:const Color(0xFF33253F),
              decoration:const InputDecoration(
                labelText:'Choose camera / lens',
                labelStyle:TextStyle(color:Colors.white70),
                prefixIcon:Icon(Icons.cameraswitch_outlined,color:Colors.white70)),
              style:const TextStyle(color:Colors.white),
              items:[
                for(var i=0;i<_cameras.length;i++)
                  DropdownMenuItem(value:i,
                    child:Text(_label(_cameras[i],i),
                      overflow:TextOverflow.ellipsis)),
              ],
              onChanged:_busy?null:(i){if(i!=null)_openCamera(i);},
            ),
            if(ready&&_maxZoom>_minZoom)Padding(
              padding:const EdgeInsets.only(top:8),
              child:Row(children:[
                for(final factor in <double>[1,2,3])
                  if(factor>=_minZoom&&factor<=_maxZoom)
                    Padding(padding:const EdgeInsets.only(right:8),
                      child:ChoiceChip(
                        label:Text('${factor.toStringAsFixed(0)}x'),
                        selected:(_zoom-factor).abs()<.12,
                        onSelected:(_)=>_setZoom(factor))),
                Expanded(child:Slider(
                  min:_minZoom,max:_maxZoom,value:_zoom.clamp(_minZoom,_maxZoom),
                  onChanged:_busy?null:(v)=>_setZoom(v))),
              ]),
            ),
            Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
              Text(Platform.isWindows?'Desktop camera':'Phone camera',
                style:const TextStyle(color:Colors.white70)),
              FilledButton.icon(
                onPressed:ready&&!_busy?_capture:null,
                icon:_busy
                  ?const SizedBox(width:18,height:18,
                    child:CircularProgressIndicator(strokeWidth:2))
                  :const Icon(Icons.camera_alt_rounded),
                label:const Text('Capture'),
                style:FilledButton.styleFrom(
                  backgroundColor:const Color(0xFF9D82E8),
                  foregroundColor:const Color(0xFF1C1530))),
            ]),
          ]),
        ),
      ])),
    );
  }
}
