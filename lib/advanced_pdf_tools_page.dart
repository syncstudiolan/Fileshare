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
  PdfFeature('splitBookmarks','Split by Bookmarks','Combine',Icons.bookmark_outline),
  PdfFeature('splitHalf','Split in Half','Combine',Icons.splitscreen),
  PdfFeature('splitSize','Split by Size','Combine',Icons.data_usage_outlined),
  PdfFeature('zip','PDF to ZIP','Combine',Icons.folder_zip_outlined,active:true),
  PdfFeature('organize','Organize Pages','Organize',Icons.view_carousel_outlined,active:true),
  PdfFeature('rotate','Rotate PDF','Organize',Icons.rotate_right,active:true),
  PdfFeature('flip','Flip PDF','Organize',Icons.flip,active:true),
  PdfFeature('nup','Multiple Pages per Sheet','Organize',Icons.grid_view),
  PdfFeature('crop','Crop & Resize','Organize',Icons.crop,active:true),
  PdfFeature('fillSign','Fill & Sign','Edit',Icons.draw_outlined),
  PdfFeature('watermark','Watermark','Edit',Icons.branding_watermark_outlined,active:true),
  PdfFeature('pageNumbers','Page Numbers','Edit',Icons.format_list_numbered,active:true),
  PdfFeature('redact','Redact PDF','Edit',Icons.security_outlined),
  PdfFeature('metadata','Edit PDF Details','Edit',Icons.info_outline,active:true),
  PdfFeature('compress','Compress PDF','Secure',Icons.compress_rounded,active:true),
  PdfFeature('ocr','OCR Scanned PDF','Secure',Icons.document_scanner),
  PdfFeature('password','Set Password','Secure',Icons.lock_outline,active:true),
  PdfFeature('unlock','Remove Password','Secure',Icons.lock_open_outlined,active:true),
  PdfFeature('workflow','Workflow Builder','Automate',Icons.account_tree_outlined),
];

String pdfDisplayName(String s)=>PdfHistory.validName(s);
Future<String?> askPdfName(BuildContext context,String current)async{
  final controller=TextEditingController(text:current.replaceFirst(RegExp(r'\.pdf,caseSensitive:false),''));
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
  try{
    var path=draft.path;
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
        name='${draft.name.replaceFirst(RegExp(r'\\.pdf$',caseSensitive:false),'')}_page_${chosen+1}.pdf';
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
    final files=await FilePicker.platform.pickFiles(type:FileType.custom,
      allowedExtensions:['pdf'],withData:false);
    final path=files?.files.singleOrNull?.path;
    if(path!=null)await importPath(path,files!.files.first.name,initialTool:initialTool);
  }
  Future<void> openDraft(PdfDraft draft,{String? initialTool})async{
    if(!mounted)return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder:(_)=>PdfWorkspacePage(draft:draft,initialTool:initialTool)));
    refresh();
  }
  Future<void> scanDocument()async{
    if(importing)return;
    final choice=await showModalBottomSheet<String>(context:context,
      builder:(ctx)=>SafeArea(child:Wrap(children:[
        ListTile(leading:const Icon(Icons.camera_alt_outlined),
          title:const Text('Take a photo'),onTap:()=>Navigator.pop(ctx,'camera')),
        ListTile(leading:const Icon(Icons.photo_library_outlined),
          title:const Text('Choose document photos'),onTap:()=>Navigator.pop(ctx,'gallery')),
      ])));
    if(choice==null)return;
    try{
      final picker=ImagePicker();
      final photos=choice=='camera'
        ?[if(await picker.pickImage(source:ImageSource.camera,imageQuality:95) case final XFile photo)photo]
        :await picker.pickMultiImage(imageQuality:95);
      if(photos.isEmpty)return;
      final out=await AdvancedPdfEngine.fromImages(photos.map((e)=>e.path).toList());
      final suggested='Scan_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final named=mounted?await askPdfName(context,suggested):null;
      final entry=await PdfHistory.instance.save(
        id:DateTime.now().microsecondsSinceEpoch.toString(),
        name:named??suggested,sourcePath:out,
        actions:['Scanned document']);
      await File(out).delete();
      await openDraft(entry);
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content:Text('Scanning failed: $e')));}
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
                    ]))),
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
  int page=0,total=0;
  Uint8List? preview;
  bool busy=false;
  final input=TextEditingController();
  late String tool=widget.initialTool??'rotate';
  final List<String> selectedPaths=[];
  @override void initState(){super.initState();unawaited(load());}
  @override void dispose(){input.dispose();super.dispose();}
  Future<void> load()async{
    try{
      final count=await AdvancedPdfEngine.pages(draft.path);
      if(count<=0)throw StateError('No PDF pages');
      final current=page.clamp(0,count-1);
      final bytes=await AdvancedPdfEngine.pageImage(draft.path,current);
      if(mounted)setState((){total=count;page=current;preview=bytes;});
    }catch(e){message('Cannot preview PDF: $e');}
  }
  void message(String v){if(mounted)ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content:Text(v)));}
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
    if(busy)return;
    try{
      final bytes=await File(draft.path).readAsBytes();
      final saved=await FilePicker.platform.saveFile(
        dialogTitle:'Save PDF',fileName:draft.name,
        type:FileType.custom,allowedExtensions:['pdf'],bytes:bytes);
      if(saved!=null)message('PDF saved');
    }catch(e){message('Save failed: $e');}
  }
  Future<void> sharePdf()async{
    if(busy)return;
    try{await SharePlus.instance.share(ShareParams(
      files:[XFile(draft.path,name:draft.name,mimeType:'application/pdf')]));}
    catch(e){message('Share failed: $e');}
  }
  Future<void> sendToCart()async{
    // No "Finish editing" requirement: last applied version is persisted.
    await addPdfToCart(context,draft,editorOpen:true,page:page,pageCount:total);
  }
  Future<void> edit(String operation,Map<String,dynamic> options)async{
    if(busy)return;
    setState(()=>busy=true);
    try{
      final out=await AdvancedPdfEngine.edit(draft.path,operation,options);
      draft=await PdfHistory.instance.save(id:draft.id,name:draft.name,
        sourcePath:out,actions:[...draft.actions,operation],page:page);
      await File(out).delete();
      message('$operation applied. You can rename, continue editing or send to cart.');
      await load();
    }catch(e){message('Operation failed: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> addMergeFiles()async{
    final list=await FilePicker.platform.pickFiles(type:FileType.custom,
      allowedExtensions:['pdf'],allowMultiple:true,withData:false);
    selectedPaths
      ..clear()
      ..addAll(list?.files.map((f)=>f.path).whereType<String>()??[]);
    message('${selectedPaths.length} PDF files selected to combine.');
  }
  Map<String,dynamic> optionsFor(String id){
    switch(id){
      case 'merge':case 'alternate':
        return {'paths':[draft.path,...selectedPaths]};
      case 'rotate':return {'degrees':90,'pages':input.text};
      case 'split':case 'organize':case 'crop':return {'pages':input.text};
      case 'watermark':return {'text':input.text.isEmpty?'DRAFT':input.text};
      case 'splitText':return {'text':input.text};
      case 'password':case 'unlock':return {'password':input.text};
      case 'metadata':return {'title':input.text};
      case 'compress':return {'quality':60};
      case 'flip':return {'axis':'h'};
      default:return {};
    }
  }
  @override Widget build(BuildContext context){
    return Scaffold(
      appBar:AppBar(title:Text(draft.name,overflow:TextOverflow.ellipsis,
        style:const TextStyle(fontSize:15)),actions:[
        IconButton(tooltip:'Save PDF',onPressed:busy?null:savePdf,
          icon:const Icon(Icons.download_outlined)),
        IconButton(tooltip:'Share PDF',onPressed:busy?null:sharePdf,
          icon:const Icon(Icons.share_outlined)),
        IconButton(tooltip:'Rename PDF',onPressed:rename,
          icon:const Icon(Icons.drive_file_rename_outline)),
        IconButton(tooltip:'Send to File Share Cart',onPressed:sendToCart,
          icon:const Icon(Icons.add_shopping_cart_outlined)),
        PopupMenuButton<String>(onSelected:(v){
          if(v=='cart')unawaited(sendToCart());
          if(v=='rename')unawaited(rename());
        },itemBuilder:(_)=>const [
          PopupMenuItem(value:'cart',child:Text('Add to Cart')),
          PopupMenuItem(value:'rename',child:Text('Rename PDF')),
        ]),
      ]),
      body:Container(decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:Column(children:[
          if(busy)const LinearProgressIndicator(),
          Expanded(child:Center(child:preview==null?
            const CircularProgressIndicator():
            InteractiveViewer(minScale:1,maxScale:5,
              child:Image.memory(preview!,gaplessPlayback:true,
                fit:BoxFit.contain,filterQuality:FilterQuality.medium)))),
          Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
            IconButton(tooltip:'Previous page',onPressed:()=>turn(-1),
              icon:const Icon(Icons.chevron_left)),
            Text(total==0?'Loading':'Page ${page+1} / $total'),
            IconButton(tooltip:'Next page',onPressed:()=>turn(1),
              icon:const Icon(Icons.chevron_right)),
          ]),
          SizedBox(height:55,child:ListView(scrollDirection:Axis.horizontal,children:[
            for(final t in pdfFeatures.where((e)=>e.active))
              Padding(padding:const EdgeInsets.only(right:7),child:ChoiceChip(
                avatar:Icon(t.icon,size:17),label:Text(t.name),
                selected:tool==t.id,onSelected:(_)=>setState(()=>tool=t.id))),
          ])),
          Padding(padding:const EdgeInsets.fromLTRB(12,3,12,12),
            child:Column(mainAxisSize:MainAxisSize.min,children:[
              if(tool=='merge'||tool=='alternate')
                OutlinedButton.icon(onPressed:addMergeFiles,
                  icon:const Icon(Icons.add),label:Text('Add PDFs (${selectedPaths.length})')),
              if(!const ['zip','pageNumbers','currentPage','alternate','merge'].contains(tool))
                TextField(controller:input,obscureText:tool=='password'||tool=='unlock',
                  decoration:InputDecoration(
                    labelText:switch(tool){
                      'split'=>'Page ranges (e.g. 1-3,5)',
                      'organize'=>'Order of pages (e.g. 3,1,2)',
                      'rotate'=>'Pages (blank = all)',
                      'watermark'=>'Watermark text',
                      'password'||'unlock'=>'PDF password',
                      'metadata'=>'New title',
                      'splitText'=>'Split at text phrase',
                      _=>'Tool settings (optional)',
                    },
                    border:const OutlineInputBorder())),
              const SizedBox(height:8),
              Row(children:[
                Expanded(child:OutlinedButton.icon(onPressed:sendToCart,
                  icon:const Icon(Icons.add_shopping_cart),
                  label:const Text('Add to Cart'))),
                const SizedBox(width:10),
                Expanded(child:FilledButton.icon(
                  onPressed:busy?null:()=>edit(tool,optionsFor(tool)),
                  icon:const Icon(Icons.check),
                  label:const Text('Apply'))),
              ]),
            ])),
        ])),
    );
  }
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
,caseSensitive:false),''));
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
  try{
    var path=draft.path;
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
        name='${draft.name.replaceFirst(RegExp(r'\.pdf,caseSensitive:false),'')}_page_${chosen+1}.pdf';
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
  Future<void> importPath(String path,String? name)async{
    if(importing)return;
    setState(()=>importing=true);
    try{
      if(!path.toLowerCase().endsWith('.pdf'))throw StateError('Choose a PDF file');
      await openDraft(await PdfHistory.instance.save(
        id:DateTime.now().microsecondsSinceEpoch.toString(),
        name:name??path.split(Platform.pathSeparator).last,
        sourcePath:path,actions:['Imported PDF']));
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));
    }finally{if(mounted)setState(()=>importing=false);}
  }
  Future<void> pickPdf()async{
    final files=await FilePicker.platform.pickFiles(type:FileType.custom,
      allowedExtensions:['pdf'],withData:false);
    final path=files?.files.singleOrNull?.path;
    if(path!=null)await importPath(path,files!.files.first.name);
  }
  Future<void> openDraft(PdfDraft draft)async{
    if(!mounted)return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder:(_)=>PdfWorkspacePage(draft:draft)));
    refresh();
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
                    await pickPdf();
                  },
                  borderRadius:BorderRadius.circular(16),
                  child:Padding(padding:const EdgeInsets.all(11),
                    child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
                      Icon(t.icon,color:FileTheme.violet,size:31),
                      const SizedBox(height:9),
                      Text(t.name,textAlign:TextAlign.center,maxLines:2,
                        style:const TextStyle(fontSize:12,fontWeight:FontWeight.bold)),
                      if(!t.active)const Text('Coming soon',style:TextStyle(fontSize:10)),
                    ]))),
                ));
              });
          }),
        ])),
    );
  }
}

class PdfWorkspacePage extends StatefulWidget{
  const PdfWorkspacePage({super.key,required this.draft});
  final PdfDraft draft;
  @override State<PdfWorkspacePage> createState()=>_PdfWorkspacePageState();
}
class _PdfWorkspacePageState extends State<PdfWorkspacePage>{
  late PdfDraft draft=widget.draft;
  int page=0,total=0;
  Uint8List? preview;
  bool busy=false;
  final input=TextEditingController();
  String tool='rotate';
  final List<String> selectedPaths=[];
  @override void initState(){super.initState();unawaited(load());}
  @override void dispose(){input.dispose();super.dispose();}
  Future<void> load()async{
    try{
      final count=await AdvancedPdfEngine.pages(draft.path);
      if(count<=0)throw StateError('No PDF pages');
      final current=page.clamp(0,count-1);
      final bytes=await AdvancedPdfEngine.pageImage(draft.path,current);
      if(mounted)setState((){total=count;page=current;preview=bytes;});
    }catch(e){message('Cannot preview PDF: $e');}
  }
  void message(String v){if(mounted)ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content:Text(v)));}
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
  Future<void> sendToCart()async{
    // No "Finish editing" requirement: last applied version is persisted.
    await addPdfToCart(context,draft,editorOpen:true,page:page,pageCount:total);
  }
  Future<void> edit(String operation,Map<String,dynamic> options)async{
    if(busy)return;
    setState(()=>busy=true);
    try{
      final out=await AdvancedPdfEngine.edit(draft.path,operation,options);
      draft=await PdfHistory.instance.save(id:draft.id,name:draft.name,
        sourcePath:out,actions:[...draft.actions,operation],page:page);
      await File(out).delete();
      message('$operation applied. You can rename, continue editing or send to cart.');
      await load();
    }catch(e){message('Operation failed: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> addMergeFiles()async{
    final list=await FilePicker.platform.pickFiles(type:FileType.custom,
      allowedExtensions:['pdf'],allowMultiple:true,withData:false);
    selectedPaths
      ..clear()
      ..addAll(list?.files.map((f)=>f.path).whereType<String>()??[]);
    message('${selectedPaths.length} PDF files selected to combine.');
  }
  Map<String,dynamic> optionsFor(String id){
    switch(id){
      case 'merge':case 'alternate':
        return {'paths':[draft.path,...selectedPaths]};
      case 'rotate':return {'degrees':90,'pages':input.text};
      case 'split':case 'organize':case 'crop':return {'pages':input.text};
      case 'watermark':return {'text':input.text.isEmpty?'DRAFT':input.text};
      case 'splitText':return {'text':input.text};
      case 'password':case 'unlock':return {'password':input.text};
      case 'metadata':return {'title':input.text};
      default:return {};
    }
  }
  @override Widget build(BuildContext context){
    return Scaffold(
      appBar:AppBar(title:Text(draft.name,overflow:TextOverflow.ellipsis,
        style:const TextStyle(fontSize:15)),actions:[
        IconButton(tooltip:'Rename PDF',onPressed:rename,
          icon:const Icon(Icons.drive_file_rename_outline)),
        IconButton(tooltip:'Send to File Share Cart',onPressed:busy?null:sendToCart,
          icon:const Icon(Icons.add_shopping_cart_outlined)),
        PopupMenuButton<String>(onSelected:(v){
          if(v=='cart')unawaited(sendToCart());
          if(v=='rename')unawaited(rename());
        },itemBuilder:(_)=>const [
          PopupMenuItem(value:'cart',child:Text('Add to Cart')),
          PopupMenuItem(value:'rename',child:Text('Rename PDF')),
        ]),
      ]),
      body:Container(decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:Column(children:[
          if(busy)const LinearProgressIndicator(),
          Expanded(child:Center(child:preview==null?
            const CircularProgressIndicator():
            InteractiveViewer(minScale:1,maxScale:5,
              child:Image.memory(preview!,gaplessPlayback:true,
                fit:BoxFit.contain,filterQuality:FilterQuality.medium)))),
          Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
            IconButton(tooltip:'Previous page',onPressed:()=>turn(-1),
              icon:const Icon(Icons.chevron_left)),
            Text(total==0?'Loading':'Page ${page+1} / $total'),
            IconButton(tooltip:'Next page',onPressed:()=>turn(1),
              icon:const Icon(Icons.chevron_right)),
          ]),
          SizedBox(height:55,child:ListView(scrollDirection:Axis.horizontal,children:[
            for(final t in pdfFeatures.where((e)=>e.active))
              Padding(padding:const EdgeInsets.only(right:7),child:ChoiceChip(
                avatar:Icon(t.icon,size:17),label:Text(t.name),
                selected:tool==t.id,onSelected:(_)=>setState(()=>tool=t.id))),
          ])),
          Padding(padding:const EdgeInsets.fromLTRB(12,3,12,12),
            child:Column(mainAxisSize:MainAxisSize.min,children:[
              if(tool=='merge'||tool=='alternate')
                OutlinedButton.icon(onPressed:addMergeFiles,
                  icon:const Icon(Icons.add),label:Text('Add PDFs (${selectedPaths.length})')),
              if(!const ['zip','pageNumbers','currentPage','alternate','merge'].contains(tool))
                TextField(controller:input,obscureText:tool=='password'||tool=='unlock',
                  decoration:InputDecoration(
                    labelText:switch(tool){
                      'split'=>'Page ranges (e.g. 1-3,5)',
                      'organize'=>'Order of pages (e.g. 3,1,2)',
                      'rotate'=>'Pages (blank = all)',
                      'watermark'=>'Watermark text',
                      'password'||'unlock'=>'PDF password',
                      'metadata'=>'New title',
                      'splitText'=>'Split at text phrase',
                      _=>'Tool settings (optional)',
                    },
                    border:const OutlineInputBorder())),
              const SizedBox(height:8),
              Row(children:[
                Expanded(child:OutlinedButton.icon(onPressed:busy?null:sendToCart,
                  icon:const Icon(Icons.add_shopping_cart),
                  label:const Text('Add to Cart'))),
                const SizedBox(width:10),
                Expanded(child:FilledButton.icon(
                  onPressed:busy?null:()=>edit(tool,optionsFor(tool)),
                  icon:const Icon(Icons.check),
                  label:const Text('Apply'))),
              ]),
            ])),
        ])),
    );
  }
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
,caseSensitive:false),'')}_page_${chosen+1}.pdf';
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
  Future<void> importPath(String path,String? name)async{
    if(importing)return;
    setState(()=>importing=true);
    try{
      if(!path.toLowerCase().endsWith('.pdf'))throw StateError('Choose a PDF file');
      await openDraft(await PdfHistory.instance.save(
        id:DateTime.now().microsecondsSinceEpoch.toString(),
        name:name??path.split(Platform.pathSeparator).last,
        sourcePath:path,actions:['Imported PDF']));
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));
    }finally{if(mounted)setState(()=>importing=false);}
  }
  Future<void> pickPdf()async{
    final files=await FilePicker.platform.pickFiles(type:FileType.custom,
      allowedExtensions:['pdf'],withData:false);
    final path=files?.files.singleOrNull?.path;
    if(path!=null)await importPath(path,files!.files.first.name);
  }
  Future<void> openDraft(PdfDraft draft)async{
    if(!mounted)return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder:(_)=>PdfWorkspacePage(draft:draft)));
    refresh();
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
                    await pickPdf();
                  },
                  borderRadius:BorderRadius.circular(16),
                  child:Padding(padding:const EdgeInsets.all(11),
                    child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
                      Icon(t.icon,color:FileTheme.violet,size:31),
                      const SizedBox(height:9),
                      Text(t.name,textAlign:TextAlign.center,maxLines:2,
                        style:const TextStyle(fontSize:12,fontWeight:FontWeight.bold)),
                      if(!t.active)const Text('Coming soon',style:TextStyle(fontSize:10)),
                    ]))),
                ));
              });
          }),
        ])),
    );
  }
}

class PdfWorkspacePage extends StatefulWidget{
  const PdfWorkspacePage({super.key,required this.draft});
  final PdfDraft draft;
  @override State<PdfWorkspacePage> createState()=>_PdfWorkspacePageState();
}
class _PdfWorkspacePageState extends State<PdfWorkspacePage>{
  late PdfDraft draft=widget.draft;
  int page=0,total=0;
  Uint8List? preview;
  bool busy=false;
  final input=TextEditingController();
  String tool='rotate';
  final List<String> selectedPaths=[];
  @override void initState(){super.initState();unawaited(load());}
  @override void dispose(){input.dispose();super.dispose();}
  Future<void> load()async{
    try{
      final count=await AdvancedPdfEngine.pages(draft.path);
      if(count<=0)throw StateError('No PDF pages');
      final current=page.clamp(0,count-1);
      final bytes=await AdvancedPdfEngine.pageImage(draft.path,current);
      if(mounted)setState((){total=count;page=current;preview=bytes;});
    }catch(e){message('Cannot preview PDF: $e');}
  }
  void message(String v){if(mounted)ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content:Text(v)));}
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
  Future<void> sendToCart()async{
    // No "Finish editing" requirement: last applied version is persisted.
    await addPdfToCart(context,draft,editorOpen:true,page:page,pageCount:total);
  }
  Future<void> edit(String operation,Map<String,dynamic> options)async{
    if(busy)return;
    setState(()=>busy=true);
    try{
      final out=await AdvancedPdfEngine.edit(draft.path,operation,options);
      draft=await PdfHistory.instance.save(id:draft.id,name:draft.name,
        sourcePath:out,actions:[...draft.actions,operation],page:page);
      await File(out).delete();
      message('$operation applied. You can rename, continue editing or send to cart.');
      await load();
    }catch(e){message('Operation failed: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> addMergeFiles()async{
    final list=await FilePicker.platform.pickFiles(type:FileType.custom,
      allowedExtensions:['pdf'],allowMultiple:true,withData:false);
    selectedPaths
      ..clear()
      ..addAll(list?.files.map((f)=>f.path).whereType<String>()??[]);
    message('${selectedPaths.length} PDF files selected to combine.');
  }
  Map<String,dynamic> optionsFor(String id){
    switch(id){
      case 'merge':case 'alternate':
        return {'paths':[draft.path,...selectedPaths]};
      case 'rotate':return {'degrees':90,'pages':input.text};
      case 'split':case 'organize':case 'crop':return {'pages':input.text};
      case 'watermark':return {'text':input.text.isEmpty?'DRAFT':input.text};
      case 'splitText':return {'text':input.text};
      case 'password':case 'unlock':return {'password':input.text};
      case 'metadata':return {'title':input.text};
      default:return {};
    }
  }
  @override Widget build(BuildContext context){
    return Scaffold(
      appBar:AppBar(title:Text(draft.name,overflow:TextOverflow.ellipsis,
        style:const TextStyle(fontSize:15)),actions:[
        IconButton(tooltip:'Rename PDF',onPressed:rename,
          icon:const Icon(Icons.drive_file_rename_outline)),
        IconButton(tooltip:'Send to File Share Cart',onPressed:busy?null:sendToCart,
          icon:const Icon(Icons.add_shopping_cart_outlined)),
        PopupMenuButton<String>(onSelected:(v){
          if(v=='cart')unawaited(sendToCart());
          if(v=='rename')unawaited(rename());
        },itemBuilder:(_)=>const [
          PopupMenuItem(value:'cart',child:Text('Add to Cart')),
          PopupMenuItem(value:'rename',child:Text('Rename PDF')),
        ]),
      ]),
      body:Container(decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:Column(children:[
          if(busy)const LinearProgressIndicator(),
          Expanded(child:Center(child:preview==null?
            const CircularProgressIndicator():
            InteractiveViewer(minScale:1,maxScale:5,
              child:Image.memory(preview!,gaplessPlayback:true,
                fit:BoxFit.contain,filterQuality:FilterQuality.medium)))),
          Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
            IconButton(tooltip:'Previous page',onPressed:()=>turn(-1),
              icon:const Icon(Icons.chevron_left)),
            Text(total==0?'Loading':'Page ${page+1} / $total'),
            IconButton(tooltip:'Next page',onPressed:()=>turn(1),
              icon:const Icon(Icons.chevron_right)),
          ]),
          SizedBox(height:55,child:ListView(scrollDirection:Axis.horizontal,children:[
            for(final t in pdfFeatures.where((e)=>e.active))
              Padding(padding:const EdgeInsets.only(right:7),child:ChoiceChip(
                avatar:Icon(t.icon,size:17),label:Text(t.name),
                selected:tool==t.id,onSelected:(_)=>setState(()=>tool=t.id))),
          ])),
          Padding(padding:const EdgeInsets.fromLTRB(12,3,12,12),
            child:Column(mainAxisSize:MainAxisSize.min,children:[
              if(tool=='merge'||tool=='alternate')
                OutlinedButton.icon(onPressed:addMergeFiles,
                  icon:const Icon(Icons.add),label:Text('Add PDFs (${selectedPaths.length})')),
              if(!const ['zip','pageNumbers','currentPage','alternate','merge'].contains(tool))
                TextField(controller:input,obscureText:tool=='password'||tool=='unlock',
                  decoration:InputDecoration(
                    labelText:switch(tool){
                      'split'=>'Page ranges (e.g. 1-3,5)',
                      'organize'=>'Order of pages (e.g. 3,1,2)',
                      'rotate'=>'Pages (blank = all)',
                      'watermark'=>'Watermark text',
                      'password'||'unlock'=>'PDF password',
                      'metadata'=>'New title',
                      'splitText'=>'Split at text phrase',
                      _=>'Tool settings (optional)',
                    },
                    border:const OutlineInputBorder())),
              const SizedBox(height:8),
              Row(children:[
                Expanded(child:OutlinedButton.icon(onPressed:busy?null:sendToCart,
                  icon:const Icon(Icons.add_shopping_cart),
                  label:const Text('Add to Cart'))),
                const SizedBox(width:10),
                Expanded(child:FilledButton.icon(
                  onPressed:busy?null:()=>edit(tool,optionsFor(tool)),
                  icon:const Icon(Icons.check),
                  label:const Text('Apply'))),
              ]),
            ])),
        ])),
    );
  }
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
