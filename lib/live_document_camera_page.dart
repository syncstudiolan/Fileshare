import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LiveScanResult {
  const LiveScanResult(this.paths,this.mode);
  final List<String> paths;
  final String mode;
}

/// Camera preview stays inside File Share. Native OpenCV/DocAligner identifies
/// the document on a throttled preview stream; full resolution capture still
/// happens with CameraController.takePicture.
class LiveDocumentCameraPage extends StatefulWidget {
  const LiveDocumentCameraPage({super.key,required this.initialMode});
  final String initialMode;
  @override State<LiveDocumentCameraPage> createState()=>_LiveDocumentCameraPageState();
}
class _LiveDocumentCameraPageState extends State<LiveDocumentCameraPage>
    with WidgetsBindingObserver {
  static const native=MethodChannel('file_share.native');
  CameraController? controller;
  List<CameraDescription> cameras=[];
  int cameraIndex=0;
  bool autoCapture=false,processing=false,capturing=false,streaming=false,flash=false;
  String mode='Document';
  String? error;
  List<double>? corners;
  final captures=<String>[];
  DateTime lastScan=DateTime.fromMillisecondsSinceEpoch(0);
  List<double>? previousCorners;
  int stable=0;
  double zoom=1,minZoom=1,maxZoom=1;

  static const modes=['Document','Book','ID Card','Business Card','Whiteboard'];

  @override void initState(){
    super.initState();
    mode=widget.initialMode;
    WidgetsBinding.instance.addObserver(this);
    unawaited(initialize());
  }
  @override void dispose(){
    WidgetsBinding.instance.removeObserver(this);
    final old=controller;
    controller=null;
    unawaited(old?.dispose()??Future<void>.value());
    super.dispose();
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state){
    if(state==AppLifecycleState.inactive||state==AppLifecycleState.paused){
      final old=controller;
      controller=null;
      unawaited(old?.dispose()??Future<void>.value());
      if(mounted)setState((){});
    }else if(state==AppLifecycleState.resumed){
      unawaited(initialize());
    }
  }
  Future<void> initialize()async{
    try{
      cameras=await availableCameras();
      if(cameras.isEmpty)throw StateError('No camera is available');
      final back=cameras.indexWhere((x)=>x.lensDirection==CameraLensDirection.back);
      if(back>=0&&controller==null)cameraIndex=back;
      final cam=CameraController(cameras[cameraIndex],
        ResolutionPreset.high,enableAudio:false,
        imageFormatGroup:ImageFormatGroup.nv21);
      await cam.initialize();
      minZoom=await cam.getMinZoomLevel();
      maxZoom=await cam.getMaxZoomLevel();
      zoom=minZoom;
      if(!mounted){await cam.dispose();return;}
      setState(()=>controller=cam);
      await startStream();
    }catch(e){
      if(mounted)setState(()=>error='Camera could not start: $e');
    }
  }
  Future<void> startStream()async{
    final cam=controller;
    if(cam==null||!cam.value.isInitialized||cam.value.isStreamingImages||capturing)return;
    try{
      await cam.startImageStream(onFrame);
      streaming=true;
    }catch(e){if(mounted)setState(()=>error='Live detection unavailable: $e');}
  }
  void onFrame(CameraImage image){
    if(processing||capturing||image.planes.length!=1)return;
    final now=DateTime.now();
    if(now.difference(lastScan).inMilliseconds<550)return;
    lastScan=now;
    processing=true;
    unawaited(()async{
      try{
        final found=await native.invokeMethod<List<dynamic>>('pdf.detectFrame',{
          'bytes':image.planes.first.bytes,
          'width':image.width,'height':image.height,
          'rotation':controller?.description.sensorOrientation??90,
        });
        final points=found?.whereType<num>().map((e)=>e.toDouble()).toList();
        if(points!=null&&points.length==8){
          if(previousCorners!=null){
            var drift=0.0;
            for(var i=0;i<8;i++)drift+=(points[i]-previousCorners![i]).abs();
            stable=drift<.13?stable+1:0;
          }
          previousCorners=points;
          if(mounted)setState(()=>corners=points);
          if(autoCapture&&stable>=3&&!capturing){
            stable=0;
            await capture();
          }
        }else{
          previousCorners=null;stable=0;
          if(mounted)setState(()=>corners=null);
        }
      }catch(_){/* Camera manual shutter remains usable. */}
      finally{processing=false;}
    }());
  }
  Future<void> capture()async{
    final cam=controller;
    if(cam==null||capturing||!cam.value.isInitialized)return;
    capturing=true;
    if(mounted)setState((){});
    try{
      if(cam.value.isStreamingImages){
        await cam.stopImageStream();
        streaming=false;
      }
      final photo=await cam.takePicture();
      captures.add(photo.path);
      if(mounted)setState(()=>corners=null);
      // Let the shutter settle before analyzing the next frame.
      if(mounted)await startStream();
    }catch(e){if(mounted)setState(()=>error='Capture failed: $e');}
    finally{
      capturing=false;
      if(mounted)setState((){});
    }
  }
  Future<void> switchCamera()async{
    if(cameras.length<2)return;
    final old=controller;
    controller=null;
    if(mounted)setState((){});
    await old?.dispose();
    cameraIndex=(cameraIndex+1)%cameras.length;
    await initialize();
  }
  Future<void> flashToggle()async{
    final cam=controller;
    if(cam==null)return;
    try{
      flash=!flash;
      await cam.setFlashMode(flash?FlashMode.torch:FlashMode.off);
      if(mounted)setState((){});
    }catch(_){}
  }
  void finish(){
    Navigator.pop(context,LiveScanResult(List.unmodifiable(captures),mode));
  }
  @override Widget build(BuildContext context){
    final cam=controller;
    final ready=cam!=null&&cam.value.isInitialized;
    return Scaffold(
      backgroundColor:const Color(0xFF171426),
      appBar:AppBar(title:const Text('Live Document Scanner'),
        actions:[
          IconButton(tooltip:'Flash',onPressed:ready?flashToggle:null,
            icon:Icon(flash?Icons.flash_on:Icons.flash_off)),
          IconButton(tooltip:'Switch camera',
            onPressed:cameras.length>1?switchCamera:null,
            icon:const Icon(Icons.cameraswitch_outlined)),
        ]),
      body:Column(children:[
        SizedBox(height:58,child:ListView(scrollDirection:Axis.horizontal,
          padding:const EdgeInsets.symmetric(horizontal:10),
          children:[for(final item in modes)Padding(
            padding:const EdgeInsets.symmetric(horizontal:5,vertical:6),
            child:ChoiceChip(label:Text(item),selected:mode==item,
              onSelected:(_)=>setState(()=>mode=item)))])),
        Expanded(child:Padding(padding:const EdgeInsets.symmetric(horizontal:8),
          child:ClipRRect(borderRadius:BorderRadius.circular(18),
            child:Container(color:Colors.black,
              child:ready?LayoutBuilder(builder:(ctx,size)=>
                Stack(fit:StackFit.expand,children:[
                  CameraPreview(cam),
                  if(corners!=null)CustomPaint(
                    painter:_LiveEdgesPainter(corners!)),
                  Positioned(left:12,top:12,child:DecoratedBox(
                    decoration:BoxDecoration(color:Colors.black54,
                      borderRadius:BorderRadius.circular(20)),
                    child:Padding(padding:const EdgeInsets.symmetric(
                      horizontal:12,vertical:7),
                      child:Text(corners==null?'Align document in frame':
                        stable>=2?'Hold steady • document detected':
                        'Document edges detected',
                        style:const TextStyle(color:Colors.white,fontSize:12))))),
                  if(capturing)const Center(child:CircularProgressIndicator()),
                ])):
                const Center(child:CircularProgressIndicator()))))),
        if(error!=null)Padding(padding:const EdgeInsets.all(8),
          child:Text(error!,style:const TextStyle(color:Colors.orangeAccent))),
        if(ready&&maxZoom>minZoom+0.1)
          Row(children:[
            const Padding(padding:EdgeInsets.only(left:16),child:Icon(Icons.zoom_out,size:17)),
            Expanded(child:Slider(min:minZoom,max:maxZoom,value:zoom,
              onChanged:(v){setState(()=>zoom=v);unawaited(cam.setZoomLevel(v));})),
            const Padding(padding:EdgeInsets.only(right:16),child:Icon(Icons.zoom_in,size:17)),
          ]),
        SwitchListTile.adaptive(title:const Text('Auto capture when document is steady',
          style:TextStyle(fontSize:13)),value:autoCapture,
          activeTrackColor:const Color(0xFFBDA9F9),
          onChanged:(value)=>setState(()=>autoCapture=value)),
        Padding(padding:const EdgeInsets.fromLTRB(16,6,16,14),
          child:Row(children:[
            Expanded(child:Text('${captures.length} captured',
              style:const TextStyle(fontWeight:FontWeight.bold))),
            IconButton(tooltip:'Take photo',onPressed:ready&&!capturing?capture:null,
              icon:const Icon(Icons.radio_button_checked,size:55,
                color:Color(0xFFD0BFFF))),
            const Spacer(),
            FilledButton.icon(onPressed:captures.isEmpty?null:finish,
              icon:const Icon(Icons.check),
              label:Text('Review (${captures.length})')),
          ])),
      ]),
    );
  }
}
class _LiveEdgesPainter extends CustomPainter {
  const _LiveEdgesPainter(this.corners);
  final List<double> corners;
  @override void paint(Canvas canvas,Size size){
    if(corners.length!=8)return;
    final points=List<Offset>.generate(4,(i)=>
      Offset(corners[i*2]*size.width,corners[i*2+1]*size.height));
    final border=Path()..moveTo(points[0].dx,points[0].dy);
    for(final p in points.skip(1))border.lineTo(p.dx,p.dy);
    border.close();
    canvas.drawPath(border,Paint()..color=const Color(0xFFC8ADFF)
      ..strokeWidth=3..style=PaintingStyle.stroke);
    for(final p in points){
      canvas.drawCircle(p,7,Paint()..color=Colors.white);
      canvas.drawCircle(p,4,Paint()..color=const Color(0xFF8054DB));
    }
  }
  @override bool shouldRepaint(covariant _LiveEdgesPainter old)=>corners!=old.corners;
}
