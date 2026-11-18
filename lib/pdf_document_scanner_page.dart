import 'live_document_camera_page.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'pdf_history.dart';
import 'editor_transfer_session.dart';
import 'advanced_pdf_tools_page.dart' show addPdfToCart;

class ScanSheet {
  ScanSheet({required this.path,this.corners,this.ratio=0.75,this.filter='Color',
    this.rotation=0});
  final String path;
  List<double>? corners;
  double ratio;
  String filter;
  int rotation;
  String cropMode='Perspective';
  Rect crop=const Rect.fromLTWH(0,0,1,1);
}

/// Camera/image capture, manually adjustable four-point perspective and
/// non-destructive page review. Platform processing runs on a Kotlin worker.
class PdfDocumentScannerPage extends StatefulWidget{
  const PdfDocumentScannerPage({super.key});
  @override State<PdfDocumentScannerPage> createState()=>_PdfDocumentScannerPageState();
}
class _PdfDocumentScannerPageState extends State<PdfDocumentScannerPage>{
  static const _native=MethodChannel('file_share.native');
  final List<ScanSheet> sheets=[];
  int selected=0;
  bool busy=false;
  String mode='Document';
  String? problem;
  final picker=ImagePicker();
  bool _cameraOpened=false;
  static const _scannerDraftId='active_scanner';
  @override void initState(){
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_){
      if(mounted&&!_cameraOpened){
        _cameraOpened=true;
        unawaited(_resumeOrStart());
      }
    });
  }
  Future<void> _resumeOrStart()async{
    final data=await EditorSessionStore.instance.load('scanner',_scannerDraftId);
    if(data!=null){
      final restored=<ScanSheet>[];
      for(final item in (data['sheets'] as List? ?? [])){
        if(item is! Map)continue;
        final record=Map<String,dynamic>.from(item);
        final path=record['path'] as String?;
        if(path==null||!await File(path).exists())continue;
        final sheet=ScanSheet(path:path,
          ratio:(record['ratio'] as num?)?.toDouble()??.75,
          filter:record['filter'] as String? ??'Color',
          rotation:(record['rotation'] as num?)?.toInt()??0);
        sheet.cropMode=record['cropMode'] as String? ??'Perspective';
        final corners=record['corners'] as List?;
        if(corners!=null&&corners.length==8){
          sheet.corners=corners.map((v)=>(v as num).toDouble()).toList();
        }
        final rectangle=record['crop'] as List?;
        if(rectangle!=null&&rectangle.length==4){
          sheet.crop=Rect.fromLTRB(
            (rectangle[0] as num).toDouble(),(rectangle[1] as num).toDouble(),
            (rectangle[2] as num).toDouble(),(rectangle[3] as num).toDouble());
        }
        restored.add(sheet);
      }
      if(restored.isNotEmpty&&mounted){
        setState((){
          sheets.addAll(restored);
          selected=((data['selected'] as num?)?.toInt()??0).clamp(0,sheets.length-1);
          mode=data['mode'] as String? ??'Document';
        });
        return;
      }
    }
    if(mounted)await add(camera:true);
  }
  Future<void> _saveScanSession()async{
    await EditorSessionStore.instance.save('scanner',_scannerDraftId,{
      'selected':selected,'mode':mode,
      'sheets':[for(final shot in sheets){
        'path':shot.path,'ratio':shot.ratio,
        'filter':shot.filter,'rotation':shot.rotation,
        'cropMode':shot.cropMode,'corners':shot.corners,
        'crop':[shot.crop.left,shot.crop.top,shot.crop.right,shot.crop.bottom],
      }],
    });
  }
  ScanSheet? get current=>sheets.isEmpty?null:sheets[selected.clamp(0,sheets.length-1)];

  Future<double> aspect(String path)async{
    final bytes=await File(path).readAsBytes();
    final codec=await ui.instantiateImageCodec(bytes,targetWidth:900);
    final image=(await codec.getNextFrame()).image;
    final ratio=image.width/image.height;
    image.dispose();codec.dispose();
    return ratio;
  }
  Future<void> add({required bool camera})async{
    try{
      final result=camera
        ?await Navigator.of(context).push<LiveScanResult>(
            MaterialPageRoute(builder:(_)=>LiveDocumentCameraPage(initialMode:mode)))
        :null;
      final captures=camera
        ?(result?.paths.map((path)=>XFile(path)).toList()??<XFile>[])
        :await picker.pickMultiImage(imageQuality:96,maxWidth:4000);
      if(result!=null)mode=result.mode;
      if(captures.isEmpty)return;
      setState(()=>busy=true);
      final root=await getApplicationSupportDirectory();
      final folder=Directory('${root.path}${Platform.pathSeparator}scanner_session_photos');
      await folder.create(recursive:true);
      for(final capture in captures){
        final permanent=await File(capture.path).copy(
          '${folder.path}${Platform.pathSeparator}capture_'
          '${DateTime.now().microsecondsSinceEpoch}.jpg');
        final sheet=ScanSheet(path:permanent.path,
          ratio:await aspect(permanent.path));
        try{
          final found=await _native.invokeMethod<List<dynamic>>(
            'pdf.detectDocument',{'path':sheet.path});
          if(found!=null&&found.length==8){
            sheet.corners=found.map((e)=>(e as num).toDouble()).toList();
          }
        }catch(_){/* Manual selection always available without AI/OpenCV. */}
        sheets.add(sheet);
      }
      if(mounted)setState(()=>selected=sheets.length-1);
      await _saveScanSession();
    }catch(e){if(mounted)setState(()=>problem='$e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  void rearrange(int offset){
    if(sheets.length<2)return;
    final target=(selected+offset).clamp(0,sheets.length-1);
    if(target==selected)return;
    setState((){final shot=sheets.removeAt(selected);sheets.insert(target,shot);selected=target;});
  }
  Future<PdfDraft?> export({bool askName=true})async{
    if(sheets.isEmpty||busy)return null;
    setState(()=>busy=true);
    final intermediates=<File>[];
    try{
      for(final shot in sheets){
        final processed=await _native.invokeMethod<String>('pdf.processScan',{
          'path':shot.path,'corners':shot.corners,'filter':shot.filter,
          'rotate':shot.rotation,'cropMode':shot.cropMode,
          'crop':[shot.crop.left,shot.crop.top,shot.crop.right,shot.crop.bottom],
        });
        if(processed==null)throw StateError('Scanner produced no image');
        intermediates.add(File(processed));
      }
      final paths=intermediates.map((f)=>f.path).toList();
      final path=await _native.invokeMethod<String>('pdf.fromImages',{
        'paths':paths,'mode':mode
      });
      if(path==null)throw StateError('Cannot create PDF from scan');
      final entry=await PdfHistory.instance.save(
        id:DateTime.now().microsecondsSinceEpoch.toString(),
        name:'Scan_${DateTime.now().millisecondsSinceEpoch}.pdf',
        sourcePath:path,
        actions:['Document scanned','${sheets.length} pages','$mode mode']);
      await File(path).delete();
      if(!mounted||!askName)return entry;
      return _renameAfterScan(entry);
    }catch(e){
      if(mounted)setState(()=>problem='PDF export failed: $e');
      return null;
    }finally{
      for(final file in intermediates)try{await file.delete();}catch(_){}
      if(mounted)setState(()=>busy=false);
    }
  }
  Future<void> sendScanToCart()async{
    if(sheets.isEmpty)return;
    try{
      await _saveScanSession();
      final created=await export(askName:false);
      if(created==null)return;
      if(mounted)await addPdfToCart(context,created,editorOpen:false);
    }catch(e){
      if(mounted)setState(()=>problem='Could not send partial scan: $e');
    }
  }
  Future<PdfDraft> _renameAfterScan(PdfDraft draft)async{
    final controller=TextEditingController(text:draft.name.replaceFirst(RegExp(r'\.pdf$',caseSensitive:false),''));
    try{
      final name=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Name your scanned PDF'),
        content:TextField(controller:controller,autofocus:true,
          decoration:const InputDecoration(suffixText:'.pdf')),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Keep name')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,controller.text),
            child:const Text('Save name')),
        ],
      ));
      if(name==null)return draft;
      return PdfHistory.instance.rename(draft,name);
    }finally{controller.dispose();}
  }
  @override Widget build(BuildContext context){
    final shot=current;
    return Scaffold(
      appBar:AppBar(title:const Text('Document Scanner'),actions:[
        IconButton(tooltip:'Camera',onPressed:busy?null:()=>add(camera:true),
          icon:const Icon(Icons.camera_alt_outlined)),
        IconButton(tooltip:'Gallery',onPressed:busy?null:()=>add(camera:false),
          icon:const Icon(Icons.photo_library_outlined)),
      ]),
      body:Column(children:[
        if(busy)const LinearProgressIndicator(),
        if(problem!=null)MaterialBanner(content:Text(problem!),
          actions:[TextButton(onPressed:()=>setState(()=>problem=null),
            child:const Text('Dismiss'))]),
        SizedBox(height:47,child:ListView(scrollDirection:Axis.horizontal,children:[
          for(final type in const ['Document','Book','ID Card','Business Card','Whiteboard'])
            Padding(padding:const EdgeInsets.symmetric(horizontal:3),child:ChoiceChip(
              selected:mode==type,label:Text(type),
              onSelected:(_)=>setState(()=>mode=type))),
        ])),
        if(shot!=null)Padding(padding:const EdgeInsets.symmetric(horizontal:12,vertical:4),
          child:SegmentedButton<String>(
            segments:const [
              ButtonSegment(value:'Perspective',icon:Icon(Icons.crop_rotate),
                label:Text('Perspective')),
              ButtonSegment(value:'Normal',icon:Icon(Icons.crop_free),
                label:Text('Normal / Freeform')),
            ],selected:{shot.cropMode},
            onSelectionChanged:(v)=>setState(()=>shot.cropMode=v.first))),
        Expanded(child:shot==null?Center(child:Column(
          mainAxisSize:MainAxisSize.min,children:[
            const Icon(Icons.document_scanner_outlined,size:75),
            const Text('Take photos or import scanned pages'),
            FilledButton.icon(onPressed:()=>add(camera:true),
              icon:const Icon(Icons.camera_alt),label:const Text('Scan document')),
          ])):
          Center(child:Padding(padding:const EdgeInsets.all(14),
            child:AspectRatio(aspectRatio:shot.ratio,
              child:LayoutBuilder(builder:(context,box){
                final corners=shot.corners??[0.0,0.0,1.0,0.0,1.0,1.0,0.0,1.0];
                final normal=shot.cropMode=='Normal';
                final handles=normal?[
                  shot.crop.topLeft,shot.crop.topRight,
                  shot.crop.bottomRight,shot.crop.bottomLeft,
                  Offset(shot.crop.center.dx,shot.crop.top),
                  Offset(shot.crop.right,shot.crop.center.dy),
                  Offset(shot.crop.center.dx,shot.crop.bottom),
                  Offset(shot.crop.left,shot.crop.center.dy),
                ]:List<Offset>.generate(4,(i)=>
                  Offset(corners[i*2],corners[i*2+1]));
                Widget preview=Image.file(File(shot.path),fit:BoxFit.fill,
                  cacheWidth:1300,gaplessPlayback:true);
                if(shot.filter=='Gray'){
                  preview=ColorFiltered(colorFilter:const ColorFilter.matrix(
                    [.2126,.7152,.0722,0,0,.2126,.7152,.0722,0,0,
                    .2126,.7152,.0722,0,0,0,0,0,1,0]),child:preview);
                }else if(shot.filter=='B&W'){
                  // Fast GPU approximation of the native adaptive threshold.
                  preview=ColorFiltered(colorFilter:const ColorFilter.matrix(
                    [2.5,5.3,.7,0,-800,2.5,5.3,.7,0,-800,
                     2.5,5.3,.7,0,-800,0,0,0,1,0]),child:preview);
                }else if(shot.filter=='Enhance'){
                  preview=ColorFiltered(colorFilter:const ColorFilter.matrix(
                    [1.13,0,0,0,-8,0,1.13,0,0,-8,0,0,1.13,0,-8,0,0,0,1,0]),
                    child:preview);
                }
                return GestureDetector(
                  behavior:HitTestBehavior.opaque,
                  onPanStart:(details){
                    var best=double.infinity;_dragCorner=-1;
                    for(var i=0;i<handles.length;i++){
                      final point=Offset(handles[i].dx*box.maxWidth,
                        handles[i].dy*box.maxHeight);
                      final distance=(details.localPosition-point).distance;
                      if(distance<best&&distance<55){best=distance;_dragCorner=i;}
                    }
                  },
                  onPanUpdate:(details){
                    final index=_dragCorner;
                    if(index<0)return;
                    final dx=details.delta.dx/box.maxWidth;
                    final dy=details.delta.dy/box.maxHeight;
                    setState((){
                      if(normal){
                        var l=shot.crop.left,r=shot.crop.right;
                        var t=shot.crop.top,b=shot.crop.bottom;
                        if(index==0||index==3||index==7)l=(l+dx).clamp(0.0,r-.025);
                        if(index==1||index==2||index==5)r=(r+dx).clamp(l+.025,1.0);
                        if(index==0||index==1||index==4)t=(t+dy).clamp(0.0,b-.025);
                        if(index==2||index==3||index==6)b=(b+dy).clamp(t+.025,1.0);
                        shot.crop=Rect.fromLTRB(l,t,r,b);
                      }else{
                        final updated=List<double>.from(corners);
                        updated[2*index]=(updated[2*index]+dx).clamp(0.0,1.0);
                        updated[2*index+1]=(updated[2*index+1]+dy).clamp(0.0,1.0);
                        shot.corners=updated;
                      }
                    });
                  },
                  onPanEnd:(_)=>_dragCorner=-1,
                  child:Stack(fit:StackFit.expand,children:[
                    preview,
                    CustomPaint(painter:_ScanCornersPainter(normal?
                      [shot.crop.left,shot.crop.top,shot.crop.right,shot.crop.top,
                       shot.crop.right,shot.crop.bottom,shot.crop.left,shot.crop.bottom]:
                      corners,showSideHandles:normal)),
                  ]),
                );
              }))),
          )),
        if(shot!=null) ...[
          Row(children:[
            IconButton(tooltip:'Previous',onPressed:selected>0?
              ()=>setState(()=>selected--):null,
              icon:const Icon(Icons.chevron_left)),
            Expanded(child:Text('Page ${selected+1} of ${sheets.length}',
              textAlign:TextAlign.center)),
            IconButton(tooltip:'Next',onPressed:selected+1<sheets.length?
              ()=>setState(()=>selected++):null,
              icon:const Icon(Icons.chevron_right)),
            IconButton(tooltip:'Move page left',onPressed:()=>rearrange(-1),
              icon:const Icon(Icons.arrow_back)),
            IconButton(tooltip:'Move page right',onPressed:()=>rearrange(1),
              icon:const Icon(Icons.arrow_forward)),
            IconButton(tooltip:'Delete page',onPressed:()=>setState((){
              sheets.removeAt(selected);
              selected=sheets.isEmpty?0:selected.clamp(0,sheets.length-1);
            }),icon:const Icon(Icons.delete_outline)),
          ]),
          SizedBox(height:65,child:ListView(scrollDirection:Axis.horizontal,children:[
            for(final filter in const ['Color','Enhance','B&W','Gray'])
              Padding(padding:const EdgeInsets.all(4),child:ChoiceChip(
                label:Text(filter),selected:shot.filter==filter,
                onSelected:(_)=>setState(()=>shot.filter=filter))),
            IconButton(tooltip:'Rotate 90°',onPressed:()=>setState(
              ()=>shot.rotation=(shot.rotation+90)%360),
              icon:const Icon(Icons.rotate_right_outlined)),
            IconButton(tooltip:'Reset crop',onPressed:()=>setState(
              (){shot.corners=[0,0,1,0,1,1,0,1];shot.crop=const Rect.fromLTWH(0,0,1,1);}),
              icon:const Icon(Icons.restart_alt)),
          ])),
        ],
        Padding(padding:const EdgeInsets.fromLTRB(15,6,15,14),
          child:Row(children:[
            Expanded(child:OutlinedButton.icon(
              onPressed:busy||sheets.isEmpty?null:sendScanToCart,
              icon:const Icon(Icons.add_shopping_cart),
              label:const Text('Add to Cart'))),
            const SizedBox(width:10),
            Expanded(child:FilledButton.icon(
            onPressed:busy||sheets.isEmpty?null:()async{
              final entry=await export();
              if(entry!=null&&context.mounted)Navigator.pop(context,entry);
            },icon:const Icon(Icons.picture_as_pdf),
            label:Text('Create PDF (${sheets.length} pages)'))),
          ])),
      ]),
    );
  }
  int _dragCorner=-1;
}

class _ScanCornersPainter extends CustomPainter{
  const _ScanCornersPainter(this.corners,{this.showSideHandles=false});
  final List<double> corners;
  final bool showSideHandles;
  @override void paint(Canvas canvas,Size size){
    final p=List<Offset>.generate(4,(i)=>Offset(
      corners[i*2]*size.width,corners[i*2+1]*size.height));
    final path=Path()..moveTo(p[0].dx,p[0].dy);
    for(var i=1;i<4;i++)path.lineTo(p[i].dx,p[i].dy);
    path.close();
    canvas.drawPath(path,Paint()..color=const Color(0xFF9B74FF)
      ..style=PaintingStyle.stroke..strokeWidth=3);
    final handles=<Offset>[...p,
      if(showSideHandles)for(var i=0;i<4;i++)
        Offset.lerp(p[i],p[(i+1)%4],.5)!];
    for(final point in handles){
      canvas.drawCircle(point,10,Paint()..color=Colors.white);
      canvas.drawCircle(point,6,Paint()..color=const Color(0xFF7A4BDB));
    }
  }
  @override bool shouldRepaint(covariant _ScanCornersPainter old)=>
    showSideHandles!=old.showSideHandles||!identical(corners,old.corners);
}
