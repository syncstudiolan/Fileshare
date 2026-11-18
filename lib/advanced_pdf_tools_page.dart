import 'pdf_signature_pad.dart';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'pdf_document_scanner_page.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'image_editing_storage.dart' show ImageEditingCart;
import 'main.dart' show FileTheme;
import 'pdf_history.dart';

/// All PDF native code is Android-only. Desktop never calls or links PDFBox.
class AdvancedPdfEngine {
  static const MethodChannel _channel=MethodChannel('file_share.native');
  static bool get available=>Platform.isAndroid;
  static Future<int> pages(String path)async=>
    await _channel.invokeMethod<int>('pdf.countPages',{'path':path})??0;
  static Future<Uint8List> pageImage(String path,int page)async=>
    await _channel.invokeMethod<Uint8List>('pdf.renderPage',
      {'path':path,'page':page,'width':1000})??Uint8List(0);
  static Future<String> fromImages(List<String> paths)async=>
    await _channel.invokeMethod<String>('pdf.fromImages',{'paths':paths})??
      (throw StateError('No scanned PDF output'));
  static Future<List<Map<String,String>>> multiple(String path,String tool,
      Map<String,dynamic> opts)async{
    final data=await _channel.invokeMethod<List<dynamic>>('pdf.processMany',
      {'path':path,'tool':tool,...opts})??[];
    return data.map((item)=>Map<String,String>.from(
      Map<dynamic,dynamic>.from(item as Map))).toList();
  }
  static Future<String> edit(String path,String tool,Map<String,dynamic> opts)async=>
    await _channel.invokeMethod<String>('pdf.process',
      {'path':path,'tool':tool,...opts})??(throw StateError('No PDF output'));
}

class PdfFeature {
  const PdfFeature(this.id,this.name,this.category,this.icon,{this.active=false});
  final String id,name,category;
  final IconData icon;
  final bool active;
}

const pdfFeatures=<PdfFeature>[
  PdfFeature('scan','Scan Document','Capture',Icons.document_scanner_outlined,active:true),
  PdfFeature('merge','Merge PDFs','Combine',Icons.layers_outlined,active:true),
  PdfFeature('alternate','Alternate & Mix','Combine',Icons.shuffle,active:true),
  PdfFeature('split','Split PDF','Combine',Icons.call_split,active:true),
  PdfFeature('splitText','Split by Text','Combine',Icons.text_snippet_outlined,active:true),
  PdfFeature('splitBookmarks','Split by Bookmarks','Combine',Icons.bookmark_outline,active:true),
  PdfFeature('splitHalf','Split in Half','Combine',Icons.splitscreen,active:true),
  PdfFeature('splitSize','Split by Size','Combine',Icons.data_usage_outlined,active:true),
  PdfFeature('zip','PDF to ZIP','Combine',Icons.folder_zip_outlined,active:true),
  PdfFeature('organize','Organize Pages','Organize',Icons.view_carousel_outlined,active:true),
  PdfFeature('rotate','Rotate PDF','Organize',Icons.rotate_right,active:true),
  PdfFeature('flip','Flip PDF','Organize',Icons.flip,active:true),
  PdfFeature('nup','Multiple Pages per Sheet','Organize',Icons.grid_view,active:true),
  PdfFeature('crop','Crop & Resize','Organize',Icons.crop,active:true),
  PdfFeature('fillSign','Fill & Sign','Edit',Icons.draw_outlined,active:true),
  PdfFeature('watermark','Watermark','Edit',Icons.branding_watermark_outlined,active:true),
  PdfFeature('pageNumbers','Page Numbers','Edit',Icons.format_list_numbered,active:true),
  PdfFeature('redact','Redact PDF','Edit',Icons.security_outlined,active:true),
  PdfFeature('metadata','Edit PDF Details','Edit',Icons.info_outline,active:true),
  PdfFeature('compress','Compress PDF','Secure',Icons.compress_rounded,active:true),
  PdfFeature('ocr','OCR Scanned PDF','Secure',Icons.document_scanner,active:true),
  PdfFeature('password','Set Password','Secure',Icons.lock_outline,active:true),
  PdfFeature('unlock','Remove Password','Secure',Icons.lock_open_outlined,active:true),
  PdfFeature('workflow','Workflow Builder','Automate',Icons.account_tree_outlined,active:true),
];

String pdfDisplayName(String s)=>PdfHistory.validName(s);
Future<String?> askPdfName(BuildContext context,String current)async{
  final controller=TextEditingController(text:current.replaceFirst(RegExp(r'\.pdf$',caseSensitive:false),''));
  try{
    return await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Rename PDF'),
      content:TextField(controller:controller,autofocus:true,maxLength:100,
        decoration:const InputDecoration(labelText:'PDF filename',suffixText:'.pdf')),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,pdfDisplayName(controller.text)),
          child:const Text('Rename')),
      ],
    ));
  }finally{controller.dispose();}
}

/// Add-to-cart is always available. Open editor asks about scope; closed
/// history/library entries go directly to the cart without a dialog.
enum PdfCartScope { current, choose, all }
Future<int?> _cartPageChoice(BuildContext context,int pages,int current)async {
  return showDialog<int>(context:context,builder:(ctx)=>AlertDialog(
    title:const Text('Send to File Share Cart'),
    content:Column(mainAxisSize:MainAxisSize.min,children:[
      ListTile(leading:const Icon(Icons.insert_drive_file_outlined),
        title:Text('Current page (${current+1})'),
        onTap:()=>Navigator.pop(ctx,current)),
      ListTile(leading:const Icon(Icons.view_list_outlined),
        title:const Text('Choose another page'),
        onTap:()=>Navigator.pop(ctx,-2)),
      ListTile(leading:const Icon(Icons.picture_as_pdf_outlined),
        title:const Text('Entire PDF'),
        subtitle:Text('$pages pages'),
        onTap:()=>Navigator.pop(ctx,-1)),
    ]),
    actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel'))],
  ));
}
Future<int?> _choosePdfPage(BuildContext context,int pages)async{
  int selected=1;
  return showDialog<int>(context:context,builder:(ctx)=>StatefulBuilder(
    builder:(ctx,setDialog)=>AlertDialog(
      title:const Text('Choose a PDF page'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        Text('Page $selected of $pages'),
        Slider(value:selected.toDouble(),min:1,max:pages.toDouble(),
          divisions:pages>1?pages-1:null,
          onChanged:(v)=>setDialog(()=>selected=v.round())),
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,selected-1),child:const Text('Send page'))],
    )));
}
Future<void> addPdfToCart(BuildContext context,PdfDraft draft,
    {required bool editorOpen,int page=0,int? pageCount})async{
  File? snapshot;
  File? extracted;
  try{
    final temp=await getTemporaryDirectory();
    snapshot=await File(draft.path).copy(
      '${temp.path}${Platform.pathSeparator}pdf_cart_snapshot_${DateTime.now().microsecondsSinceEpoch}.pdf');
    var path=snapshot.path;
    var name=draft.name;
    if(editorOpen){
      final count=pageCount??await AdvancedPdfEngine.pages(path);
      if(count<=0)throw StateError('PDF has no pages');
      var chosen=await _cartPageChoice(context,count,page.clamp(0,count-1));
      if(chosen==null)return;
      if(chosen==-2)chosen=await _choosePdfPage(context,count);
      if(chosen==null)return;
      if(chosen>=0){
        path=await AdvancedPdfEngine.edit(path,'currentPage',{'page':chosen});
        extracted=File(path);
        name=draft.name.replaceFirst(RegExp(r'\.pdf$',caseSensitive:false),'')+'_page_'+(chosen+1).toString()+'.pdf';
      }
    }
    // Make the cart file independent of the history draft. Further edits and
    // history renames must never mutate a previously staged attachment.
    final app=await getApplicationSupportDirectory();
    final dir=Directory('${app.path}${Platform.pathSeparator}pdf_cart');
    await dir.create(recursive:true);
    final file=await File(path).copy('${dir.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.pdf');
    ImageEditingCart.instance.add(file,name);
    if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content:Text('$name added to File Share Cart')));
  }catch(e){
    if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content:Text('Could not add PDF to cart: $e')));
  }finally{
    try{if(snapshot!=null&&await snapshot.exists())await snapshot.delete();}catch(_){}
    try{if(extracted!=null&&await extracted.exists())await extracted.delete();}catch(_){}
  }
}

class AdvancedPdfToolsPage extends StatefulWidget{
  const AdvancedPdfToolsPage({super.key,this.sourcePath,this.sourceName});
  final String? sourcePath,sourceName;
  @override State<AdvancedPdfToolsPage> createState()=>_AdvancedPdfToolsPageState();
}
class _AdvancedPdfToolsPageState extends State<AdvancedPdfToolsPage>{
  final search=TextEditingController();
  String category='All';
  bool importing=false;
  @override void initState(){
    super.initState();search.addListener(refresh);
    unawaited(PdfHistory.instance.load().then((_){
      if(widget.sourcePath!=null && Platform.isAndroid){
        return importPath(widget.sourcePath!,widget.sourceName);
      }
    }));
  }
  void refresh(){if(mounted)setState((){});}
  @override void dispose(){search.removeListener(refresh);search.dispose();super.dispose();}
  Future<void> importPath(String path,String? name,{String? initialTool})async{
    if(importing)return;
    setState(()=>importing=true);
    try{
      if(!path.toLowerCase().endsWith('.pdf'))throw StateError('Choose a PDF file');
      await openDraft(await PdfHistory.instance.save(
        id:DateTime.now().microsecondsSinceEpoch.toString(),
        name:name??path.split(Platform.pathSeparator).last,
        sourcePath:path,actions:['Imported PDF']),initialTool:initialTool);
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));
    }finally{if(mounted)setState(()=>importing=false);}
  }
  Future<void> pickPdf({String? initialTool})async{
    final file=await FilePicker.pickFile(type:FileType.custom,
      allowedExtensions:['pdf']);
    if(file?.path!=null)await importPath(file!.path!,file.name,
      initialTool:initialTool);
  }
  Future<void> openDraft(PdfDraft draft,{String? initialTool})async{
    if(!mounted)return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder:(_)=>PdfWorkspacePage(draft:draft,initialTool:initialTool)));
    refresh();
  }
  Future<void> scanDocument()async{
    final result=await Navigator.of(context).push<PdfDraft>(MaterialPageRoute(
      builder:(_)=>const PdfDocumentScannerPage()));
    if(result!=null && mounted)await openDraft(result);
  }
  Future<void> rename(PdfDraft draft)async{
    final next=await askPdfName(context,draft.name);
    if(next!=null){await PdfHistory.instance.rename(draft,next);refresh();}
  }
  @override Widget build(BuildContext context){
    if(!Platform.isAndroid)return Scaffold(appBar:AppBar(title:const Text('Advanced PDF Editing Tools')),
      body:const Center(child:Padding(padding:EdgeInsets.all(28),
        child:Text('Only Available on Android. Advanced PDF Editing Tools are supported on Android devices only.',
          textAlign:TextAlign.center))));
    final query=search.text.trim().toLowerCase();
    final filtered=pdfFeatures.where((t)=>
      (category=='All'||t.category==category) && t.name.toLowerCase().contains(query)).toList();
    return Scaffold(
      appBar:AppBar(title:const Text('Advanced PDF Editing Tools',
        style:TextStyle(fontWeight:FontWeight.bold,fontSize:17)),
        actions:[IconButton(tooltip:'PDF History',icon:const Icon(Icons.history),
          onPressed:()=>Navigator.push(context,MaterialPageRoute<void>(
            builder:(_)=>const PdfHistoryPage())))]),
      floatingActionButton:FloatingActionButton.extended(
        onPressed:importing?null:pickPdf,icon:const Icon(Icons.add),
        label:const Text('Open PDF')),
      body:Container(decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:ListView(padding:const EdgeInsets.fromLTRB(16,12,16,88),children:[
          TextField(controller:search,decoration:InputDecoration(
            hintText:'Search Merge, Split, OCR, Compress...',
            prefixIcon:const Icon(Icons.search),border:OutlineInputBorder(
              borderRadius:BorderRadius.circular(20)))),
          const SizedBox(height:18),
          Row(children:[
            const Icon(Icons.history,color:FileTheme.violet),
            const SizedBox(width:8),
            const Expanded(child:Text('Recent History',style:TextStyle(
              fontSize:18,fontWeight:FontWeight.bold))),
            TextButton(onPressed:()=>Navigator.push(context,
              MaterialPageRoute<void>(builder:(_)=>const PdfHistoryPage())),
              child:const Text('View All')),
          ]),
          AnimatedBuilder(animation:PdfHistory.instance,builder:(context,_){
            final recent=PdfHistory.instance.items.take(3).toList();
            if(recent.isEmpty)return const Padding(
              padding:EdgeInsets.all(12),child:Text('Edited PDF files will appear here.'));
            return SizedBox(height:132,child:ListView(scrollDirection:Axis.horizontal,
              children:recent.map((e)=>SizedBox(width:175,child:Card(child:InkWell(
                onTap:()=>openDraft(e),child:Padding(padding:const EdgeInsets.all(12),
                  child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                    const Icon(Icons.picture_as_pdf,color:Colors.red),
                    const SizedBox(height:8),
                    Text(e.name,maxLines:1,overflow:TextOverflow.ellipsis),
                    Text(e.actions.isEmpty?'Imported':e.actions.last,
                      maxLines:1,overflow:TextOverflow.ellipsis,
                      style:Theme.of(context).textTheme.bodySmall),
                    const Spacer(),
                    Row(children:[
                      IconButton(tooltip:'Add closed PDF to Cart',icon:const Icon(Icons.add_shopping_cart,size:19),
                        onPressed:()=>addPdfToCart(context,e,editorOpen:false)),
                      IconButton(tooltip:'Rename',icon:const Icon(Icons.drive_file_rename_outline,size:19),
                        onPressed:()=>rename(e)),
                    ])
                  ]))),))).toList()));
          }),
          const SizedBox(height:13),
          SizedBox(height:44,child:ListView(scrollDirection:Axis.horizontal,children:[
            for(final cat in const ['All','Capture','Combine','Organize','Edit','Secure','Automate'])
              Padding(padding:const EdgeInsets.only(right:7),child:ChoiceChip(
                label:Text(cat),selected:category==cat,
                onSelected:(_)=>setState(()=>category=cat))),
          ])),
          const SizedBox(height:14),
          LayoutBuilder(builder:(context,box){
            final width=box.maxWidth;
            final count=width>700?4:width>420?3:2;
            return GridView.builder(shrinkWrap:true,
              physics:const NeverScrollableScrollPhysics(),
              itemCount:filtered.length,
              gridDelegate:SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:count,mainAxisSpacing:9,crossAxisSpacing:9,
                mainAxisExtent:126),
              itemBuilder:(context,i){
                final t=filtered[i];
                return Card(child:InkWell(
                  onTap:()async{
                    if(!t.active){ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content:Text('${t.name}: Processing integration not yet available.')));return;}
                    if(t.id=='scan')await scanDocument();
                    else await pickPdf(initialTool:t.id);
                  },
                  borderRadius:BorderRadius.circular(16),
                  child:Padding(padding:const EdgeInsets.all(11),
                    child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
                      Icon(t.icon,color:FileTheme.violet,size:31),
                      const SizedBox(height:9),
                      Text(t.name,textAlign:TextAlign.center,maxLines:2,
                        style:const TextStyle(fontSize:12,fontWeight:FontWeight.bold)),
                      if(!t.active)const Text('Coming soon',style:TextStyle(fontSize:10)),
                    ])),
                ));
              });
          }),
        ])),
    );
  }
}

class PdfWorkspacePage extends StatefulWidget{
  const PdfWorkspacePage({super.key,required this.draft,this.initialTool});
  final PdfDraft draft;
  final String? initialTool;
  @override State<PdfWorkspacePage> createState()=>_PdfWorkspacePageState();
}
class _PdfWorkspacePageState extends State<PdfWorkspacePage>{
  late PdfDraft draft=widget.draft;
  final input=TextEditingController();
  final author=TextEditingController(),subject=TextEditingController(),keywords=TextEditingController();
  int page=0,total=0,angle=90,nupCount=4,compressionQuality=60;
  Uint8List? preview;
  double aspect=0.72;
  bool busy=false;
  String tool='rotate',splitMode='ranges',splitHalfMode='file',axis='h';
  String cropMode='crop',pageSize='A4',numberPosition='center',numberFormat='n';
  String compressMode='quality',sizeTarget='2';
  double watermarkOpacity=.2,watermarkScale=1;
  bool nupLines=false,reverseAlternating=false;
  String deletedPages='';
  String? signaturePath;
  final selectedPaths=<String>[];
  final redactionBoxes=<Map<String,dynamic>>[];
  final signItems=<Map<String,dynamic>>[];
  final workflowSteps=<Map<String,dynamic>>[];
  final undoStack=<File>[],redoStack=<File>[];
  final extraResults=<PdfDraft>[];
  Offset? drawingStart;
  Rect? liveRect;
  RangeValues horizontalCrop=const RangeValues(0.0,1.0);
  RangeValues verticalCrop=const RangeValues(0.0,1.0);
  static const multiTools={'split','splitText','splitBookmarks','splitHalf',
    'splitSize','zip','nup','ocr','redact','fillSign','workflow'};
  @override void initState(){
    super.initState();
    tool=widget.initialTool??'rotate';
    page=widget.draft.page;
    unawaited(load());
  }
  @override void dispose(){
    input.dispose();author.dispose();subject.dispose();keywords.dispose();
    for(final f in [...undoStack,...redoStack])unawaited(f.delete().catchError((Object _)=>f));
    super.dispose();
  }
  void message(String value){
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content:Text(value),duration:const Duration(seconds:4)));
  }
  Future<void> load()async{
    try{
      final count=await AdvancedPdfEngine.pages(draft.path);
      if(count<=0)throw StateError('PDF has no pages');
      final current=page.clamp(0,count-1);
      final bytes=await AdvancedPdfEngine.pageImage(draft.path,current);
      if(!mounted)return;
      final decoded=await ui.instantiateImageCodec(bytes,targetWidth:900);
      final frame=await decoded.getNextFrame();
      final ratio=frame.image.width/frame.image.height;
      frame.image.dispose();decoded.dispose();
      if(mounted)setState((){
        total=count;page=current;preview=bytes;aspect=ratio;
      });
    }catch(e){message('Preview unavailable: $e. You can use Remove Password if needed.');}
  }
  Future<void> turn(int delta)async{
    if(busy||page+delta<0||page+delta>=total)return;
    setState((){page+=delta;preview=null;});await load();
  }
  Future<void> rename()async{
    final name=await askPdfName(context,draft.name);
    if(name==null)return;
    draft=await PdfHistory.instance.rename(draft,name);
    if(mounted)setState((){});
  }
  Future<void> savePdf()async{
    try{
      final saved=await FilePicker.saveFile(
        dialogTitle:'Save PDF',fileName:draft.name,type:FileType.custom,
        allowedExtensions:['pdf'],bytes:await File(draft.path).readAsBytes());
      if(saved!=null)message('PDF saved');
    }catch(e){message('Save failed: $e');}
  }
  Future<void> sharePdf()async{
    try{
      await SharePlus.instance.share(ShareParams(files:[
        XFile(draft.path,name:draft.name,mimeType:'application/pdf')]));
    }catch(e){message('Share failed: $e');}
  }
  Future<void> sendToCart()async{
    // Pending on-screen annotations must not be lost when the user sends
    // before Apply. Produce an isolated export; do not alter edit history.
    final pendingSign=tool=='fillSign'&&signItems.isNotEmpty;
    final pendingRedact=tool=='redact'&&redactionBoxes.isNotEmpty;
    final pendingCrop=tool=='crop'&&cropMode=='crop'&&
      (horizontalCrop.start>0||horizontalCrop.end<1||
       verticalCrop.start>0||verticalCrop.end<1);
    if(busy){
      message('Processing is running; sending the last saved draft.');
      await addPdfToCart(context,draft,editorOpen:true,page:page,pageCount:total);
      return;
    }
    if(!pendingSign&&!pendingRedact&&!pendingCrop){
      await addPdfToCart(context,draft,editorOpen:true,page:page,pageCount:total);
      return;
    }
    File? temporary;
    try{
      if(pendingSign||pendingRedact){
        final files=await AdvancedPdfEngine.multiple(
          draft.path,tool,optionsFor(tool));
        if(files.isEmpty)throw StateError('The pending edit produced no PDF');
        temporary=File(files.first['path']!);
      }else{
        temporary=File(await AdvancedPdfEngine.edit(
          draft.path,'crop',optionsFor('crop')));
      }
      final previewDraft=PdfDraft(id:draft.id,name:draft.name,
        path:temporary.path,updated:DateTime.now(),
        actions:[...draft.actions,'Unapplied preview'],page:page);
      if(mounted)await addPdfToCart(context,previewDraft,
        editorOpen:true,page:page,pageCount:total);
    }catch(e){message('Cannot send these pending edits: $e');}
    finally{
      if(temporary!=null)try{await temporary.delete();}catch(_){}
    }
  }
  Future<File> _snapshot()async{
    final cache=await getTemporaryDirectory();
    return File(draft.path).copy(
      '${cache.path}${Platform.pathSeparator}pdf_undo_${DateTime.now().microsecondsSinceEpoch}.pdf');
  }
  Future<void> _remember()async{
    undoStack.add(await _snapshot());
    for(final f in redoStack)try{await f.delete();}catch(_){}
    redoStack.clear();
    if(undoStack.length>15){
      final old=undoStack.removeAt(0);
      try{await old.delete();}catch(_){}
    }
  }
  Future<void> undoOrRedo({required bool undo})async{
    final source=undo?undoStack:redoStack;
    final target=undo?redoStack:undoStack;
    if(busy||source.isEmpty)return;
    setState(()=>busy=true);
    try{
      target.add(await _snapshot());
      final previous=source.removeLast();
      draft=await PdfHistory.instance.save(id:draft.id,name:draft.name,
        sourcePath:previous.path,actions:[...draft.actions,undo?'Undo':'Redo'],
        page:page);
      await previous.delete();
      await load();
    }catch(e){message('History change failed: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> addMergeFiles()async{
    final result=await FilePicker.pickFiles(type:FileType.custom,
      allowedExtensions:['pdf']);
    if(result.isEmpty)return;
    setState((){
      selectedPaths
        ..clear()
        ..addAll(result.map((x)=>x.path).whereType<String>());
    });
  }
  Future<void> addSignatureImage()async{
    final method=await showModalBottomSheet<String>(context:context,
      builder:(ctx)=>SafeArea(child:Wrap(children:[
        ListTile(leading:const Icon(Icons.draw),title:const Text('Draw signature'),
          onTap:()=>Navigator.pop(ctx,'draw')),
        ListTile(leading:const Icon(Icons.photo_outlined),
          title:const Text('Import signature image'),
          onTap:()=>Navigator.pop(ctx,'gallery')),
      ])));
    if(method==null||!mounted)return;
    final path=method=='draw'
      ?await Navigator.of(context).push<String>(
          MaterialPageRoute(builder:(_)=>const PdfSignaturePad()))
      :(await ImagePicker().pickImage(source:ImageSource.gallery))?.path;
    if(path!=null&&mounted)setState(()=>signaturePath=path);
  }
  Future<void> addWorkflowStep()async{
    const excluded={'scan','workflow','password','unlock','zip',
      'organize','redact','fillSign','metadata'};
    final id=await showModalBottomSheet<String>(context:context,
      builder:(ctx)=>SafeArea(child:ListView(shrinkWrap:true,children:[
        for(final item in pdfFeatures.where((x)=>!excluded.contains(x.id)))
          ListTile(title:Text(item.name),leading:Icon(item.icon),
            onTap:()=>Navigator.pop(ctx,item.id)),
      ])));
    if(id==null||!mounted)return;
    final step=<String,dynamic>{'tool':id,...optionsFor(id)};
    if(id=='crop'){
      step['mode']='resize';step['size']='A4';
    }
    if(id=='watermark'||id=='splitText'||id=='splitSize'||id=='split'){
      final controller=TextEditingController(
        text: id=='watermark'?'DRAFT':
          id=='splitSize'?'5':id=='split'?'1-':'');
      final inputValue=await showDialog<String>(context:context,builder:(ctx)=>
        AlertDialog(
          title:Text('Configure ${pdfFeatures.firstWhere((x)=>x.id==id).name}'),
          content:TextField(controller:controller,autofocus:true,
            decoration:InputDecoration(hintText:switch(id){
              'splitText'=>'Phrase that starts a new PDF',
              'splitSize'=>'Maximum size in MB',
              'split'=>'Page ranges: 1-3,4-6',
              _=>'Watermark text',
            })),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),
            FilledButton(onPressed:()=>Navigator.pop(ctx,controller.text),
              child:const Text('Add step')),
          ],
        ));
      controller.dispose();
      if(inputValue==null)return;
      if(id=='watermark')step['text']=inputValue;
      if(id=='splitText')step['phrase']=inputValue;
      if(id=='splitSize')step['maxMB']=inputValue;
      if(id=='split'){
        step['mode']='ranges';step['ranges']=inputValue;
      }
    }
    setState(()=>workflowSteps.add(step));
  }
  void moveWorkflowStep(int index,int direction){
    final target=index+direction;
    if(target<0||target>=workflowSteps.length)return;
    setState((){
      final value=workflowSteps.removeAt(index);
      workflowSteps.insert(target,value);
    });
  }
  Map<String,dynamic> optionsFor(String id){
    final pages=input.text.trim();
    switch(id){
      case 'merge':case 'alternate':return {'paths':[draft.path,...selectedPaths],
        'reverse':reverseAlternating};
      case 'rotate':return {'degrees':angle,'pages':pages};
      case 'organize':return {'pages':pages,'deletePages':deletedPages.split(',')
        .map((s)=>int.tryParse(s.trim())).whereType<int>()
        .where((v)=>v>=1).map((v)=>v-1).toList()};
      case 'split':return {'mode':splitMode,'ranges':pages.isEmpty?'1-':pages};
      case 'splitText':return {'phrase':pages};
      case 'splitHalf':return {'mode':splitHalfMode};
      case 'splitSize':return {'maxMB':pages.isEmpty?'5':pages};
      case 'zip':return {'paths':[draft.path,...selectedPaths]};
      case 'nup':return {'perSheet':nupCount,'lines':nupLines};
      case 'flip':return {'axis':axis};
      case 'crop':return {'pages':pages,'mode':cropMode,'size':pageSize,
        'left':horizontalCrop.start,'right':horizontalCrop.end,
        'top':verticalCrop.start,'bottom':verticalCrop.end};
      case 'watermark':return {'text':pages.isEmpty?'DRAFT':pages,
        'opacity':watermarkOpacity,'scale':watermarkScale};
      case 'pageNumbers':return {'position':numberPosition,'format':numberFormat};
      case 'metadata':return {'title':pages,'author':author.text,
        'subject':subject.text,'keywords':keywords.text};
      case 'compress':return {'mode':compressMode,'quality':compressionQuality,
        'targetMB':sizeTarget};
      case 'password':case 'unlock':return {'password':pages};
      case 'fillSign':return {'items':signItems};
      case 'redact':return {'boxes':redactionBoxes};
      case 'ocr':return {};
      case 'workflow':return {'steps':workflowSteps};
      default:return {};
    }
  }
  Future<void> apply()async{
    if(busy)return;
    if(tool=='scan'){message('Use Document Scanner from the PDF Tools dashboard.');return;}
    if(tool=='fillSign'&&signItems.isEmpty){
      message('Place text or a signature by tapping the PDF preview.');return;
    }
    if(tool=='redact'&&redactionBoxes.isEmpty){
      message('Drag over an area to redact it.');return;
    }
    setState(()=>busy=true);
    try{
      final params=optionsFor(tool);
      if(multiTools.contains(tool)){
        final files=await AdvancedPdfEngine.multiple(draft.path,tool,params);
        if(files.isEmpty)throw StateError('No output generated');
        final fresh=<PdfDraft>[];
        for(final (index,item) in files.indexed){
          final result=File(item['path']!);
          final label=item['name']??tool;
          if(label.toLowerCase().endsWith('.zip') ||
              result.path.toLowerCase().endsWith('.zip')){
            final dir=await getApplicationSupportDirectory();
            final dest=await result.copy('${dir.path}${Platform.pathSeparator}pdf_bundle_${DateTime.now().microsecondsSinceEpoch}.zip');
            ImageEditingCart.instance.add(dest,label.endsWith('.zip')?label:'$label.zip');
            await result.delete();
            continue;
          }
          final same=files.length==1 && !{
            'split','splitText','splitBookmarks','splitHalf','splitSize'
          }.contains(tool);
          if(same)await _remember();
          final next=await PdfHistory.instance.save(
            id:same?draft.id:'${DateTime.now().microsecondsSinceEpoch}_$index',
            name:same?draft.name:'${draft.name.replaceFirst(RegExp(r'\.pdf$',caseSensitive:false),'')}_$label.pdf',
            sourcePath:result.path,
            actions:[...draft.actions,tool],page:same?page:0);
          await result.delete();
          fresh.add(next);
          if(same)draft=next;
        }
        if(fresh.length==1 && fresh.first.id==draft.id){
          await load();
        }else{
          extraResults.addAll(fresh);
          if(mounted)await _showResults(fresh);
        }
        message('${files.length} result(s) generated. Your original PDF remains available.');
      }else{
        // Do not change the original on error; snapshot only after success.
        final out=await AdvancedPdfEngine.edit(draft.path,tool,params);
        await _remember();
        draft=await PdfHistory.instance.save(id:draft.id,name:draft.name,
          sourcePath:out,actions:[...draft.actions,tool],page:page);
        await File(out).delete();
        await load();
        message('$tool applied. Add to Cart is available at any time.');
      }
    }catch(e){message('PDF operation failed: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> _showResults(List<PdfDraft> results)async{
    await showModalBottomSheet<void>(context:context,isScrollControlled:true,
      builder:(ctx)=>SafeArea(child:ListView(shrinkWrap:true,children:[
        const ListTile(title:Text('Generated PDFs'),subtitle:Text(
          'Open, rename or send any output to the File Share Cart')),
        for(final entry in results)
          ListTile(leading:const Icon(Icons.picture_as_pdf,color:Colors.red),
            title:Text(entry.name),
            trailing:IconButton(tooltip:'Send to Cart',onPressed:()=>
              addPdfToCart(ctx,entry,editorOpen:false),
              icon:const Icon(Icons.add_shopping_cart)),
            onTap:(){
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute<void>(
                builder:(_)=>PdfWorkspacePage(draft:entry)));
            }),
      ])));
  }
  void _stageTap(TapUpDetails details,Size size){
    if(tool!='fillSign')return;
    final x=(details.localPosition.dx/size.width).clamp(0,1).toDouble();
    final y=(details.localPosition.dy/size.height).clamp(0,1).toDouble();
    if(signaturePath==null&&input.text.trim().isEmpty){
      message('Enter text or choose a signature image first.');return;
    }
    setState(()=>signItems.add({
      'page':page,'x':x,'y':y,'w':.3,'h':.10,
      if(signaturePath!=null)'image':signaturePath,
      if(signaturePath==null)'text':input.text,
    }));
  }
  void _startRedact(DragStartDetails d,Size size){
    if(tool!='redact')return;
    setState(()=>drawingStart=Offset(
      (d.localPosition.dx/size.width).clamp(0,1).toDouble(),
      (d.localPosition.dy/size.height).clamp(0,1).toDouble()));
  }
  void _dragRedact(DragUpdateDetails d,Size size){
    if(tool!='redact'||drawingStart==null)return;
    final x=(d.localPosition.dx/size.width).clamp(0,1).toDouble();
    final y=(d.localPosition.dy/size.height).clamp(0,1).toDouble();
    setState(()=>liveRect=Rect.fromLTRB(
      math.min(x,drawingStart!.dx),math.min(y,drawingStart!.dy),
      math.max(x,drawingStart!.dx),math.max(y,drawingStart!.dy)));
  }
  void _endRedact(){
    if(liveRect==null)return;
    final b=liveRect!;
    setState((){
      if(b.width>.005&&b.height>.005)redactionBoxes.add({
        'page':page,'x':b.left,'y':b.top,'w':b.width,'h':b.height});
      liveRect=null;drawingStart=null;
    });
  }
  Widget _previewArea(){
    if(preview==null)return const Center(child:CircularProgressIndicator());
    return Center(child:Padding(padding:const EdgeInsets.all(8),
      child:AspectRatio(aspectRatio:aspect,child:LayoutBuilder(
        builder:(context,box){
          final canvas=Stack(fit:StackFit.expand,children:[
            Image.memory(preview!,fit:BoxFit.fill,gaplessPlayback:true,
              filterQuality:FilterQuality.medium),
            if(tool=='redact')CustomPaint(painter:_PdfRedactionPainter(
              redactionBoxes.where((b)=>b['page']==page).toList(),liveRect)),
            if(tool=='fillSign')CustomPaint(painter:_PdfSignaturePainter(
              signItems.where((b)=>b['page']==page).toList())),
            if(tool=='crop'&&cropMode=='crop')CustomPaint(painter:_PdfCropGuides(
              horizontalCrop,verticalCrop)),
          ]);
          if(tool=='redact'||tool=='fillSign')return GestureDetector(
            behavior:HitTestBehavior.opaque,
            onTapUp:tool=='fillSign'?(d)=>_stageTap(d,box.biggest):null,
            onPanStart:tool=='redact'?(d)=>_startRedact(d,box.biggest):null,
            onPanUpdate:tool=='redact'?(d)=>_dragRedact(d,box.biggest):null,
            onPanEnd:tool=='redact'?(_)=>_endRedact():null,
            child:canvas);
          return InteractiveViewer(minScale:.7,maxScale:5,child:canvas);
        }))));
  }
  Widget _config(){
    final dynamicTools={'scan','splitText','splitSize','rotate','watermark',
      'password','unlock','metadata','organize','split','crop',
      'fillSign','splitHalf','zip','workflow','redact','compress','nup','flip',
      'alternate','merge'};
    return Column(mainAxisSize:MainAxisSize.min,children:[
      if(tool=='merge'||tool=='alternate'||tool=='zip')
        OutlinedButton.icon(onPressed:addMergeFiles,
          icon:const Icon(Icons.add),label:Text(
            'Choose more PDFs (${selectedPaths.length} selected)')),
      if(tool=='alternate')SwitchListTile(title:const Text('Reverse later PDFs (duplex scanning)'),
        value:reverseAlternating,onChanged:(v)=>setState(()=>reverseAlternating=v)),
      if(tool=='split')
        SegmentedButton<String>(segments:const [
          ButtonSegment(value:'ranges',label:Text('Page ranges')),
          ButtonSegment(value:'every',label:Text('Every page')),
        ],selected:{splitMode},onSelectionChanged:(values)=>
          setState(()=>splitMode=values.first)),
      if(tool=='splitHalf')DropdownButton<String>(value:splitHalfMode,
        isExpanded:true,items:const [
          DropdownMenuItem(value:'file',child:Text('Split file into two parts')),
          DropdownMenuItem(value:'vertical',child:Text('Slice each page: left/right')),
          DropdownMenuItem(value:'horizontal',child:Text('Slice each page: top/bottom')),
        ],onChanged:(value)=>setState(()=>splitHalfMode=value??'file')),
      if(tool=='rotate')DropdownButton<int>(isExpanded:true,value:angle,
        items:[90,180,270].map((n)=>DropdownMenuItem(
          value:n,child:Text('Rotate $n° clockwise'))).toList(),
        onChanged:(n)=>setState(()=>angle=n??90)),
      if(tool=='nup')SwitchListTile(title:const Text('Draw page divider lines'),
        value:nupLines,onChanged:(v)=>setState(()=>nupLines=v)),
      if(tool=='nup')DropdownButton<int>(isExpanded:true,value:nupCount,
        items:[2,4,6,9,16].map((n)=>DropdownMenuItem(
          value:n,child:Text('$n pages per sheet'))).toList(),
        onChanged:(n)=>setState(()=>nupCount=n??4)),
      if(tool=='flip')DropdownButton<String>(isExpanded:true,value:axis,
        items:const [
          DropdownMenuItem(value:'h',child:Text('Flip horizontally')),
          DropdownMenuItem(value:'v',child:Text('Flip vertically')),
          DropdownMenuItem(value:'both',child:Text('Flip both directions')),
        ],onChanged:(n)=>setState(()=>axis=n??'h')),
      if(tool=='compress')Column(children:[
        SegmentedButton<String>(segments:const [
          ButtonSegment(value:'quality',label:Text('Compression level')),
          ButtonSegment(value:'size',label:Text('Target file size')),
        ],selected:{compressMode},onSelectionChanged:(v)=>
          setState(()=>compressMode=v.first)),
        if(compressMode=='quality') ...[
          Text('Image quality $compressionQuality%'),
          Slider(min:20,max:95,divisions:15,value:compressionQuality.toDouble(),
            onChanged:(v)=>setState(()=>compressionQuality=v.round())),
        ]else TextFormField(initialValue:sizeTarget,
          keyboardType:TextInputType.number,
          decoration:const InputDecoration(labelText:'Target size in MB'),
          onChanged:(v)=>sizeTarget=v),
      ]),
      if(tool=='crop')Column(children:[
        SegmentedButton<String>(segments:const [
          ButtonSegment(value:'crop',label:Text('Crop margins')),
          ButtonSegment(value:'resize',label:Text('Resize pages')),
        ],selected:{cropMode},onSelectionChanged:(v)=>
          setState(()=>cropMode=v.first)),
        if(cropMode=='crop') ...[
          const Align(alignment:Alignment.centerLeft,child:Text('Left / Right crop')),
          RangeSlider(values:horizontalCrop,min:0,max:1,
            onChanged:(v)=>setState(()=>horizontalCrop=v)),
          const Align(alignment:Alignment.centerLeft,child:Text('Top / Bottom crop')),
          RangeSlider(values:verticalCrop,min:0,max:1,
            onChanged:(v)=>setState(()=>verticalCrop=v)),
        ]else DropdownButton<String>(isExpanded:true,value:pageSize,
          items:const ['A4','A5','Letter','Legal'].map((s)=>
            DropdownMenuItem(value:s,child:Text('Page size $s'))).toList(),
          onChanged:(v)=>setState(()=>pageSize=v??'A4')),
      ]),
      if(tool=='pageNumbers')Row(children:[
        Expanded(child:DropdownButton<String>(value:numberPosition,isExpanded:true,
          items:const ['left','center','right'].map((x)=>DropdownMenuItem(
            value:x,child:Text(x))).toList(),
          onChanged:(v)=>setState(()=>numberPosition=v??'center'))),
        Expanded(child:DropdownButton<String>(value:numberFormat,isExpanded:true,
          items:const [DropdownMenuItem(value:'n',child:Text('1, 2, 3')),
            DropdownMenuItem(value:'of',child:Text('Page N of Total'))],
          onChanged:(v)=>setState(()=>numberFormat=v??'n'))),
      ]),
      if(tool=='watermark')Column(children:[
        Text('Watermark opacity ${(watermarkOpacity*100).round()}%'),
        Slider(min:.05,max:.5,value:watermarkOpacity,
          onChanged:(v)=>setState(()=>watermarkOpacity=v)),
        DropdownButton<double>(value:watermarkScale,isExpanded:true,
          items:const [DropdownMenuItem(value:.6,child:Text('Small')),
            DropdownMenuItem(value:1.0,child:Text('Medium')),
            DropdownMenuItem(value:1.4,child:Text('Large'))],
          onChanged:(v)=>setState(()=>watermarkScale=v??1)),
      ]),
      if(tool=='organize')TextField(
        decoration:const InputDecoration(labelText:'Delete pages (e.g. 2,5)',
          border:OutlineInputBorder()),onChanged:(s)=>deletedPages=s),
      if(tool=='metadata') ...[
        TextField(controller:author,decoration:const InputDecoration(labelText:'Author')),
        TextField(controller:subject,decoration:const InputDecoration(labelText:'Subject')),
        TextField(controller:keywords,decoration:const InputDecoration(labelText:'Keywords')),
      ],
      if(tool=='fillSign')Row(children:[
        TextButton.icon(onPressed:addSignatureImage,
          icon:const Icon(Icons.draw),label:const Text('Signature photo')),
        if(signItems.isNotEmpty)TextButton(
          onPressed:()=>setState(()=>signItems.removeLast()),
          child:Text('Undo placement (${signItems.length})')),
      ]),
      if(tool=='redact')Row(children:[
        const Expanded(child:Text('Drag over confidential areas on the page')),
        TextButton(onPressed:redactionBoxes.isEmpty?null:()=>
          setState(()=>redactionBoxes.removeLast()),child:const Text('Undo mark')),
      ]),
      if(tool=='workflow')Column(children:[
        OutlinedButton.icon(onPressed:addWorkflowStep,
          icon:const Icon(Icons.add),label:const Text('Add workflow step')),
        for(final (index,step) in workflowSteps.indexed)
          ListTile(dense:true,title:Text('${index+1}. ${step['tool']}'),
            trailing:Row(mainAxisSize:MainAxisSize.min,children:[
              IconButton(icon:const Icon(Icons.arrow_upward,size:18),
                tooltip:'Move step up',onPressed:index==0?null:
                  ()=>moveWorkflowStep(index,-1)),
              IconButton(icon:const Icon(Icons.arrow_downward,size:18),
                tooltip:'Move step down',
                onPressed:index+1==workflowSteps.length?null:
                  ()=>moveWorkflowStep(index,1)),
              IconButton(icon:const Icon(Icons.close,size:18),
                tooltip:'Remove step',
                onPressed:()=>setState(()=>workflowSteps.removeAt(index))),
            ])),
      ]),
      if(dynamicTools.contains(tool)&&!const {
          'nup','flip','compress','splitHalf','workflow','redact',
          'merge','alternate','zip','pageNumbers','ocr'
        }.contains(tool) &&
        !(tool=='split'&&splitMode=='every'))
        TextField(controller:input,
          obscureText:tool=='password'||tool=='unlock',
          decoration:InputDecoration(
            labelText:switch(tool){
              'split'=>'Page ranges: 1-3,5,7-',
              'splitText'=>'Text phrase that starts a new PDF',
              'splitSize'=>'Maximum MB per PDF part',
              'organize'=>'New page order: 3,1,2',
              'rotate'=>'Pages (blank means all)',
              'watermark'=>'Watermark text',
              'password'||'unlock'=>'PDF Password',
              'metadata'=>'PDF title',
              'fillSign'=>'Type text; tap preview to position',
              'crop'=>'Pages to crop (blank means all)',
              _=>'Options (optional)',
            },
            border:const OutlineInputBorder())),
      if(!const {'scan'}.contains(tool))
        Row(children:[
          Expanded(child:OutlinedButton.icon(onPressed:sendToCart,
            icon:const Icon(Icons.add_shopping_cart),
            label:const Text('Add to Cart'))),
          const SizedBox(width:10),
          Expanded(child:FilledButton.icon(onPressed:busy?null:apply,
            icon:const Icon(Icons.check),label:const Text('Apply'))),
        ]),
    ]);
  }
  @override Widget build(BuildContext context){
    return Scaffold(
      appBar:AppBar(title:Text(draft.name,overflow:TextOverflow.ellipsis,
          style:const TextStyle(fontSize:15)),
        actions:[
          IconButton(tooltip:'Undo',onPressed:undoStack.isEmpty?null:
            ()=>undoOrRedo(undo:true),icon:const Icon(Icons.undo,size:20)),
          IconButton(tooltip:'Redo',onPressed:redoStack.isEmpty?null:
            ()=>undoOrRedo(undo:false),icon:const Icon(Icons.redo,size:20)),
          IconButton(tooltip:'Send to Cart',onPressed:sendToCart,
            icon:const Icon(Icons.add_shopping_cart,size:21)),
          PopupMenuButton<String>(onSelected:(v){
            if(v=='rename')unawaited(rename());
            if(v=='save')unawaited(savePdf());
            if(v=='share')unawaited(sharePdf());
          },itemBuilder:(_)=>const [
            PopupMenuItem(value:'rename',child:Text('Rename PDF')),
            PopupMenuItem(value:'save',child:Text('Save / Download PDF')),
            PopupMenuItem(value:'share',child:Text('Share PDF')),
          ]),
        ]),
      body:Container(decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:Column(children:[
          if(busy)const LinearProgressIndicator(),
          Expanded(child:_previewArea()),
          Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
            IconButton(onPressed:()=>turn(-1),tooltip:'Previous page',
              icon:const Icon(Icons.chevron_left)),
            Text('Page ${total==0?0:page+1} / $total'),
            IconButton(onPressed:()=>turn(1),tooltip:'Next page',
              icon:const Icon(Icons.chevron_right)),
          ]),
          SizedBox(height:58,child:ListView(scrollDirection:Axis.horizontal,children:[
            for(final t in pdfFeatures.where((t)=>t.id!='scan'))
              Padding(padding:const EdgeInsets.only(right:5),child:ChoiceChip(
                label:Text(t.name),avatar:Icon(t.icon,size:17),
                selected:tool==t.id,onSelected:(_)=>setState((){
                  tool=t.id;input.clear();
                }))),
          ])),
          ConstrainedBox(constraints:const BoxConstraints(maxHeight:235),
            child:SingleChildScrollView(padding:const EdgeInsets.fromLTRB(12,4,12,10),
              child:_config())),
        ])),
    );
  }
}
class _PdfRedactionPainter extends CustomPainter{
  _PdfRedactionPainter(this.boxes,this.live);
  final List<Map<String,dynamic>> boxes;
  final Rect? live;
  @override void paint(Canvas canvas,Size size){
    final p=Paint()..color=Colors.black.withValues(alpha:.55);
    for(final b in boxes){
      canvas.drawRect(Rect.fromLTWH(
        (b['x'] as num).toDouble()*size.width,
        (b['y'] as num).toDouble()*size.height,
        (b['w'] as num).toDouble()*size.width,
        (b['h'] as num).toDouble()*size.height),p);
    }
    if(live!=null)canvas.drawRect(Rect.fromLTRB(
      live!.left*size.width,live!.top*size.height,
      live!.right*size.width,live!.bottom*size.height),p);
  }
  @override bool shouldRepaint(covariant _PdfRedactionPainter old)=>true;
}
class _PdfSignaturePainter extends CustomPainter{
  _PdfSignaturePainter(this.items);
  final List<Map<String,dynamic>> items;
  @override void paint(Canvas canvas,Size size){
    final paint=Paint()..color=const Color(0xFF8A54DF)
      ..style=PaintingStyle.stroke..strokeWidth=2;
    for(final item in items){
      final x=(item['x'] as num).toDouble()*size.width;
      final y=(item['y'] as num).toDouble()*size.height;
      canvas.drawRect(Rect.fromLTWH(x,y,
        (item['w'] as num).toDouble()*size.width,
        (item['h'] as num).toDouble()*size.height),paint);
    }
  }
  @override bool shouldRepaint(covariant _PdfSignaturePainter old)=>true;
}
class _PdfCropGuides extends CustomPainter{
  _PdfCropGuides(this.horizontal,this.vertical);
  final RangeValues horizontal,vertical;
  @override void paint(Canvas canvas,Size s){
    final clip=Rect.fromLTRB(horizontal.start*s.width,
      vertical.start*s.height,horizontal.end*s.width,
      vertical.end*s.height);
    canvas.drawRect(clip,Paint()..color=const Color(0xFF9869E5)
      ..style=PaintingStyle.stroke..strokeWidth=3);
  }
  @override bool shouldRepaint(covariant _PdfCropGuides old)=>
    horizontal!=old.horizontal||vertical!=old.vertical;
}
class PdfHistoryPage extends StatefulWidget{
  const PdfHistoryPage({super.key});
  @override State<PdfHistoryPage> createState()=>_PdfHistoryPageState();
}
class _PdfHistoryPageState extends State<PdfHistoryPage>{
  String filter='All';
  @override void initState(){super.initState();unawaited(PdfHistory.instance.load());}
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('PDF Editing History')),
    body:AnimatedBuilder(animation:PdfHistory.instance,builder:(context,_){
      final items=PdfHistory.instance.items.where((e)=>
        filter=='All'||e.actions.any((x)=>x.toLowerCase().contains(filter.toLowerCase()))).toList();
      return Column(children:[
        SizedBox(height:52,child:ListView(scrollDirection:Axis.horizontal,children:[
          for(final cat in const ['All','Edited','rotate','merge','split','watermark'])
            Padding(padding:const EdgeInsets.all(5),child:ChoiceChip(
              label:Text(cat),selected:cat==filter,onSelected:(_)=>setState(()=>filter=cat))),
        ])),
        Expanded(child:items.isEmpty?const Center(child:Text('No matching PDF history')):
          ListView.builder(itemCount:items.length,itemBuilder:(context,i){
            final e=items[i];
            return Card(child:ListTile(
              leading:const Icon(Icons.picture_as_pdf,color:Colors.red),
              title:Text(e.name),
              subtitle:Text('${e.actions.join(' • ')}\n${e.updated.toLocal()}',
                maxLines:2),
              onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(
                builder:(_)=>PdfWorkspacePage(draft:e))),
              trailing:PopupMenuButton<String>(
                onSelected:(v)async{
                  if(v=='cart')await addPdfToCart(context,e,editorOpen:false);
                  if(v=='rename'){
                    final name=await askPdfName(context,e.name);
                    if(name!=null)await PdfHistory.instance.rename(e,name);
                  }
                  if(v=='delete')await PdfHistory.instance.delete(e);
                },
                itemBuilder:(_)=>const [
                  PopupMenuItem(value:'cart',child:Text('Add entire PDF to Cart')),
                  PopupMenuItem(value:'rename',child:Text('Rename')),
                  PopupMenuItem(value:'delete',child:Text('Delete history copy')),
                ]),
            ));
          })),
      ]);
    }),
  );
}
