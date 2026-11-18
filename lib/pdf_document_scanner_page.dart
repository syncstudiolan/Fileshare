import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'pdf_history.dart';

class ScanSheet {
  ScanSheet({required this.path,this.corners,this.ratio=0.75,this.filter='Color',
    this.rotation=0});
  final String path;
  List<double>? corners;
  double ratio;
  String filter;
  int rotation;
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
      final captures=camera
        ?[if(await picker.pickImage(source:ImageSource.camera,
            imageQuality:96,maxWidth:4000) case final XFile photo)photo]
        :await picker.pickMultiImage(imageQuality:96,maxWidth:4000);
      if(captures.isEmpty)return;
      setState(()=>busy=true);
      for(final capture in captures){
        final sheet=ScanSheet(path:capture.path,ratio:await aspect(capture.path));
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
    }catch(e){if(mounted)setState(()=>problem='$e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  void rearrange(int offset){
    if(sheets.length<2)return;
    final target=(selected+offset).clamp(0,sheets.length-1);
    if(target==selected)return;
    setState((){final shot=sheets.removeAt(selected);sheets.insert(target,shot);selected=target;});
  }
  Future<PdfDraft?> export()async{
    if(sheets.isEmpty||busy)return null;
    setState(()=>busy=true);
    final intermediates=<File>[];
    try{
      for(final shot in sheets){
        final processed=await _native.invokeMethod<String>('pdf.processScan',{
          'path':shot.path,'corners':shot.corners,'filter':shot.filter,
          'rotate':shot.rotation,
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
      if(!mounted)return entry;
      final renamed=await _renameAfterScan(entry);
      return renamed;
    }catch(e){
      if(mounted)setState(()=>problem='PDF export failed: $e');
      return null;
    }finally{
      for(final file in intermediates)try{await file.delete();}catch(_){}
      if(mounted)setState(()=>busy=false);
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
                return GestureDetector(
                  onPanUpdate:(details){
                    final x=details.localPosition.dx/box.maxWidth;
                    final y=details.localPosition.dy/box.maxHeight;
                    if(_dragCorner<0)return;
                    setState((){
                      final moved=List<double>.from(corners);
                      moved[2*_dragCorner]=x.clamp(0,1).toDouble();
                      moved[2*_dragCorner+1]=y.clamp(0,1).toDouble();
                      shot.corners=moved;
                    });
                  },
                  onPanStart:(details){
                    final x=details.localPosition.dx;
                    final y=details.localPosition.dy;
                    var d=double.infinity;_dragCorner=-1;
                    for(var i=0;i<4;i++){
                      final dx=x-corners[i*2]*box.maxWidth;
                      final dy=y-corners[i*2+1]*box.maxHeight;
                      final length=math.sqrt(dx*dx+dy*dy);
                      if(length<d&&length<55){d=length;_dragCorner=i;}
                    }
                  },
                  onPanEnd:(_)=>_dragCorner=-1,
                  child:Stack(fit:StackFit.expand,children:[
                    Image.file(File(shot.path),fit:BoxFit.fill),
                    CustomPaint(painter:_ScanCornersPainter(corners)),
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
              ()=>shot.corners=[0,0,1,0,1,1,0,1]),
              icon:const Icon(Icons.restart_alt)),
          ])),
        ],
        Padding(padding:const EdgeInsets.fromLTRB(15,6,15,14),
          child:SizedBox(width:double.infinity,child:FilledButton.icon(
            onPressed:busy||sheets.isEmpty?null:()async{
              final entry=await export();
              if(entry!=null&&context.mounted)Navigator.pop(context,entry);
            },icon:const Icon(Icons.picture_as_pdf),
            label:Text('Create PDF (${sheets.length} pages)')))),
      ]),
    );
  }
  int _dragCorner=-1;
}

class _ScanCornersPainter extends CustomPainter{
  const _ScanCornersPainter(this.corners);
  final List<double> corners;
  @override void paint(Canvas canvas,Size size){
    final p=List<Offset>.generate(4,(i)=>Offset(
      corners[i*2]*size.width,corners[i*2+1]*size.height));
    final path=Path()..moveTo(p[0].dx,p[0].dy);
    for(var i=1;i<4;i++)path.lineTo(p[i].dx,p[i].dy);
    path.close();
    canvas.drawPath(path,Paint()..color=const Color(0xFF9B74FF)
      ..style=PaintingStyle.stroke..strokeWidth=3);
    for(final point in p){
      canvas.drawCircle(point,10,Paint()..color=Colors.white);
      canvas.drawCircle(point,6,Paint()..color=const Color(0xFF7A4BDB));
    }
  }
  @override bool shouldRepaint(covariant _ScanCornersPainter old)=>
    !identical(corners,old.corners);
}
