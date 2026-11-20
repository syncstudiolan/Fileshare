import 'app_top_notice.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'file_share_doc_engine.dart';
import 'gander_docx_preview_page.dart';
import 'gander_markup_preview_page.dart';
import 'gander_spreadsheet_preview_page.dart';
import 'gander_presentation_preview_page.dart';
import 'file_share_windows_pdf_viewer.dart';
import 'gander_epub_preview_page.dart';
import 'gander_archive_browser_page.dart';
import 'gander_prose_preview_page.dart';
import 'image_editing_page.dart';
import 'main.dart' show FileTheme, FileCardOpenRouter, appLan;
import 'transfer_downloads.dart';

/// File Share Doc: offline document file picker, editable OOXML text blocks,
/// copy-safe saves, preview, and existing LAN queue integration.
/// Rich media/legacy formats are VIEW-ONLY until their specialized editor is ported.
class FileShareDocPage extends StatefulWidget {
  const FileShareDocPage({super.key,this.sourcePath,this.sourceName});
  final String? sourcePath,sourceName;
  @override
  State<FileShareDocPage> createState()=>_FileShareDocPageState();
}
class _FileShareDocPageState extends State<FileShareDocPage>{
  File? _source;
  File? _saved;
  String? _displayName;
  FileShareDocEngine? _document;
  final _controllers=<String,TextEditingController>{};
  final _wordStyles=<String,Set<String>>{};
  final _wordAlignments=<String,String>{};
  final _newWordParagraphs=<String,List<String>>{};
  final _newWordTables=<String,List<WordTableSpec>>{};
  final _deletedWordParagraphs=<String>{};
  String _paperSize='A4';
  bool _landscape=false;
  double _pageMarginMm=25.4;
  bool _pageLayoutDirty=false;
  bool _showWordLayout=false;
  String? _selectedWordParagraph;
  bool _busy=false;
  bool _dirty=false;
  String? _status;
  String _search='';
  @override
  void initState(){
    super.initState();
    if(widget.sourcePath!=null){
      unawaited(_openFile(File(widget.sourcePath!),
        name:widget.sourceName));
    }
  }
  @override
  void dispose(){
    for(final c in _controllers.values)c.dispose();
    super.dispose();
  }
  void _toggleWordStyle(String format){
    final id=_selectedWordParagraph;
    if(id==null||_busy)return;
    setState((){
      final old=_wordStyles[id]??<String>{};
      final updated=Set<String>.of(old);
      if(updated.contains(format)){updated.remove(format);}
      else{updated.add(format);}
      _wordStyles[id]=updated;
      _dirty=true;
    });
  }
  void _setWordAlignment(String align){
    final id=_selectedWordParagraph;
    if(id==null||_busy)return;
    setState((){
      _wordAlignments[id]=align;
      _dirty=true;
    });
  }
  Future<void> _insertWordParagraph()async{
    final selected=_selectedWordParagraph;
    if(selected==null||_busy)return;
    final controller=TextEditingController();
    final accepted=await showDialog<bool>(context:context,builder:(dialog)=>
      AlertDialog(
        title:const Text('Insert Word paragraph'),
        content:TextField(controller:controller,maxLines:5,minLines:2,
          autofocus:true,
          decoration:const InputDecoration(
            border:OutlineInputBorder(),
            hintText:'Type the new paragraph')),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog,false),
            child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(dialog,true),
            child:const Text('Insert')),
        ]));
    if(mounted && accepted==true && controller.text.trim().isNotEmpty){
      setState((){
        _newWordParagraphs.putIfAbsent(selected,()=>[]).add(controller.text);
        _dirty=true;
      });
    }
    controller.dispose();
  }
  Future<void> _insertWordTable() async {
    final selected=_selectedWordParagraph;
    if(selected==null||_busy)return;
    final rows=TextEditingController(text:'3');
    final cols=TextEditingController(text:'3');
    final accepted=await showDialog<bool>(context:context,builder:(dialog)=>
      AlertDialog(
        title:const Text('Insert Word table'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:rows,
            keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'Rows (1–20)')),
          TextField(controller:cols,
            keyboardType:TextInputType.number,
            decoration:const InputDecoration(labelText:'Columns (1–12)')),
        ]),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog,false),
            child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(dialog,true),
            child:const Text('Insert Table')),
        ]));
    if(accepted==true&&mounted){
      final countRows=int.tryParse(rows.text)??0;
      final countCols=int.tryParse(cols.text)??0;
      if(countRows<1||countRows>20||countCols<1||countCols>12){
        _message('Choose 1–20 rows and 1–12 columns');
      }else{
        setState((){
          _newWordTables.putIfAbsent(selected,()=>[]).add(
            WordTableSpec(countRows,countCols,
              List.generate(countRows*countCols,
                (index)=>'Cell '+(index+1).toString())));
          _dirty=true;
        });
      }
    }
    rows.dispose();cols.dispose();
  }
  void _removeWordParagraph(){
    final selected=_selectedWordParagraph;
    if(selected==null||_busy)return;
    setState((){
      if(_deletedWordParagraphs.contains(selected)){
        _deletedWordParagraphs.remove(selected);
      }else{
        _deletedWordParagraphs.add(selected);
      }
      _dirty=true;
    });
  }
  Widget _wordToolbar(){
    final selected=_selectedWordParagraph;
    final active=_wordStyles[selected]??<String>{};
    Widget item(String name,IconData icon,String label)=>
      OutlinedButton.icon(
        onPressed:selected==null||_busy?null:()=>_toggleWordStyle(name),
        style:OutlinedButton.styleFrom(
          backgroundColor:active.contains(name)
            ?FileTheme.violet.withValues(alpha:.18):null),
        icon:Icon(icon,size:17),label:Text(label));
    return SingleChildScrollView(scrollDirection:Axis.horizontal,
      child:Row(children:[
      item('bold',Icons.format_bold_rounded,'Bold'),
      item('italic',Icons.format_italic_rounded,'Italic'),
      item('underline',Icons.format_underlined_rounded,'Underline'),
      OutlinedButton.icon(
        onPressed:selected==null||_busy?null:_insertWordParagraph,
        icon:const Icon(Icons.add,size:17),
        label:const Text('Add paragraph')),
      OutlinedButton.icon(
        onPressed:selected==null||_busy?null:_insertWordTable,
        icon:const Icon(Icons.table_chart_outlined,size:17),
        label:const Text('Insert Table')),
      OutlinedButton.icon(
        onPressed:selected==null||_busy?null:_removeWordParagraph,
        icon:Icon(_deletedWordParagraphs.contains(selected)
          ?Icons.restore:Icons.delete_outline,size:17),
        label:Text(_deletedWordParagraphs.contains(selected)
          ?'Restore paragraph':'Delete paragraph')),
      SegmentedButton<String>(
        showSelectedIcon:false,
        segments:const [
          ButtonSegment(value:'left',icon:Icon(Icons.format_align_left),
            tooltip:'Left aligned'),
          ButtonSegment(value:'center',icon:Icon(Icons.format_align_center),
            tooltip:'Center aligned'),
          ButtonSegment(value:'right',icon:Icon(Icons.format_align_right),
            tooltip:'Right aligned'),
          ButtonSegment(value:'both',icon:Icon(Icons.format_align_justify),
            tooltip:'Justified'),
        ],
        selected:{_wordAlignments[selected]??'left'},
        onSelectionChanged:selected==null||_busy?null:(choices)=>
          _setWordAlignment(choices.first)),

      OutlinedButton.icon(onPressed:()=>setState(
        ()=>_showWordLayout=!_showWordLayout),
        icon:const Icon(Icons.description_outlined),
        label:const Text('Page Layout')),
    ]));
  }
  /// Editable paged paper view. Preserves text controllers and OOXML Save Copy.
  /// Rich Word layout is approximated here, not a pixel-identical MS Word renderer.
  Widget _wordPaperView(List<DocBlock> blocks){
    final (w,h)=switch(_paperSize){
      'Letter'=>(215.9,279.4),
      'Legal'=>(215.9,355.6),
      _=>(210.0,297.0),
    };
    final paperWidth=_landscape?h:w;
    final paperHeight=_landscape?w:h;
    final viewWidth=math.min(MediaQuery.sizeOf(context).width-36,780.0);
    final viewHeight=viewWidth*paperHeight/paperWidth;
    final margin=(_pageMarginMm*viewWidth/paperWidth).clamp(12.0,viewWidth*.22).toDouble();
    final charsPerLine=math.max(18,((viewWidth-2*margin)/7.8).floor());
    final maxLines=math.max(6,((viewHeight-2*margin)/22).floor());
    final pages=<List<DocBlock>>[];
    var current=<DocBlock>[];
    var used=0;
    for(final block in blocks){
      final value=_controllers[block.id]?.text??block.original;
      final lines=value.split('\n').fold<int>(0,(sum,line)=>
        sum+math.max(1,(line.length/charsPerLine).ceil()))+1;
      if(current.isNotEmpty && used+lines>maxLines){
        pages.add(current);current=<DocBlock>[];used=0;
      }
      current.add(block);used+=lines;
    }
    if(current.isNotEmpty)pages.add(current);
    if(pages.isEmpty)pages.add(<DocBlock>[]);
    return Column(children:[
      for(var i=0;i<pages.length;i++)...[
        Container(width:viewWidth,
          constraints:BoxConstraints(minHeight:viewHeight),
          decoration:BoxDecoration(color:Colors.white,boxShadow:[
            BoxShadow(color:Colors.black.withValues(alpha:.2),
              blurRadius:10,offset:const Offset(0,3))]),
          child:Padding(padding:EdgeInsets.all(margin),
            child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,
              children:[for(final block in pages[i])...[
                TextField(key:ValueKey('word-paper-${block.id}'),
                  onTap:()=>setState(()=>_selectedWordParagraph=block.id),
                  controller:_controllers[block.id],
                  enabled:!_busy,maxLines:null,minLines:1,
                  textAlign:switch(_wordAlignments[block.id]??'left'){
                    'center'=>TextAlign.center,
                    'right'=>TextAlign.right,
                    'both'=>TextAlign.justify,
                    _=>TextAlign.left,
                  },
                  style:TextStyle(fontSize:14,height:1.45,color:Colors.black87,
                    fontWeight:(_wordStyles[block.id]??{}).contains('bold')
                      ?FontWeight.bold:FontWeight.normal,
                    fontStyle:(_wordStyles[block.id]??{}).contains('italic')
                      ?FontStyle.italic:FontStyle.normal,
                    decoration:(_wordStyles[block.id]??{}).contains('underline')
                      ?TextDecoration.underline:null),
                  decoration:const InputDecoration(isDense:true,
                    border:InputBorder.none,
                    contentPadding:EdgeInsets.symmetric(vertical:4),
                    hintText:'Type document text')),
                for(final added in _newWordParagraphs[block.id]??<String>[])
                  Text(added,style:const TextStyle(color:Colors.black87,fontSize:14)),
                for(final table in _newWordTables[block.id]??<WordTableSpec>[])
                  const Text('Inserted table (included on Save Copy)',
                    style:TextStyle(color:Colors.black54,fontSize:12)),
              ]]),
            )),
        const SizedBox(height:6),
        Text('Page ${i+1} of ${pages.length} · $_paperSize',
          style:TextStyle(fontSize:11,color:FileTheme.muted(context))),
        const SizedBox(height:18),
      ],
    ]);
  }

  Widget _wordPageOptions(){
    return Card(child:Padding(padding:const EdgeInsets.all(12),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('Page Layout',style:TextStyle(fontWeight:FontWeight.bold)),
        const SizedBox(height:10),
        Wrap(spacing:12,runSpacing:12,crossAxisAlignment:WrapCrossAlignment.center,
          children:[
            SizedBox(width:150,child:DropdownButtonFormField<String>(
              initialValue:_paperSize,
              decoration:const InputDecoration(labelText:'Paper',
                border:OutlineInputBorder(),isDense:true),
              items:const [
                DropdownMenuItem(value:'A4',child:Text('A4')),
                DropdownMenuItem(value:'Letter',child:Text('Letter')),
                DropdownMenuItem(value:'Legal',child:Text('Legal')),
              ],
              onChanged:_busy?null:(v){
                if(v!=null)setState((){
                  _paperSize=v;_pageLayoutDirty=true;_dirty=true;
                });
              },
            )),
            ChoiceChip(label:const Text('Landscape'),
              selected:_landscape,
              onSelected:_busy?null:(v)=>setState((){
                _landscape=v;_pageLayoutDirty=true;_dirty=true;
              })),
            Text('Margin: '+_pageMarginMm.toStringAsFixed(1)+' mm'),
          ]),
        Slider(value:_pageMarginMm,min:0,max:50,divisions:100,
          label:_pageMarginMm.toStringAsFixed(1)+' mm',
          onChanged:_busy?null:(v)=>setState((){
            _pageMarginMm=v;_pageLayoutDirty=true;_dirty=true;
          })),
      ])));
  }

  Future<void> _newDocument()async{
    if(_busy)return;
    try{
      final root=await getApplicationSupportDirectory();
      final folder=Directory(root.path+
        Platform.pathSeparator+'file_share_doc_new');
      final file=await FileShareDocEngine.createBlankDocx(folder);
      await _openFile(file);
    }catch(e){_message('New document could not be created: '+e.toString());}
  }
  Future<void> _selectFile()async{
    if(_busy)return;
    if(_dirty){
      final discard=await showDialog<bool>(context:context,builder:(dialog)=>
        AlertDialog(title:const Text('Unsaved edits'),
          content:const Text('Open another file without saving your changes?'),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog,false),
              child:const Text('Keep Editing')),
            FilledButton(onPressed:()=>Navigator.pop(dialog,true),
              child:const Text('Discard Changes')),
          ]));
      if(discard!=true)return;
    }
    try{
      final selected=await FilePicker.pickFiles(type:FileType.any);
      if(selected.isEmpty)return;
      final entry=selected.first;
      final path=entry.path;
      File file;
      if(path!=null && await File(path).exists()){
        file=File(path);
      }else{
        final root=await getApplicationSupportDirectory();
        final folder=Directory(root.path+Platform.pathSeparator+'file_share_doc_imports');
        await folder.create(recursive:true);
        final name=entry.name.replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'),'_');
        file=File(folder.path+Platform.pathSeparator+
          DateTime.now().microsecondsSinceEpoch.toString()+'_'+name);
        await file.writeAsBytes(await entry.readAsBytes(),flush:true);
      }
      await _openFile(file,name:entry.name);
    }catch(e){_message('Cannot open file: '+e.toString());}
  }
  Future<void> _openFile(File file,{String? name}) async {
    if(_busy)return;
    setState((){_busy=true;_status='Opening document…';});
    try{
      if(!await file.exists())throw StateError('Selected document is unavailable');
      final allowed=FileShareDocEngine.canView(name??file.path);
      if(!allowed)throw UnsupportedError('Unsupported file type');
      final edit=FileShareDocEngine.canEdit(name??file.path);
      FileShareDocEngine? doc;
      if(edit)doc=await FileShareDocEngine.open(file,filename:name);
      for(final c in _controllers.values)c.dispose();
      _controllers.clear();
      _wordStyles.clear();
      _wordAlignments.clear();
      _newWordParagraphs.clear();
      _newWordTables.clear();
      _deletedWordParagraphs.clear();
      _paperSize='A4';
      _landscape=false;
      _pageMarginMm=25.4;
      _pageLayoutDirty=false;
      _selectedWordParagraph=doc?.blocks.firstOrNull?.id;
      if(doc!=null){
        for(final block in doc.blocks){
          final controller=TextEditingController(text:block.original);
          controller.addListener((){
            if(mounted&&!_dirty)setState(()=>_dirty=true);
          });
          _controllers[block.id]=controller;
        }
      }
      if(!mounted)return;
      setState((){
        _source=file;_saved=null;_document=doc;
        _displayName=name??file.uri.pathSegments.last;
        _dirty=false;
        _status=edit
          ?'Edit the displayed text fields, then Save Copy. Complex Office '
            'layouts and unsupported embedded objects remain unchanged.'
          :'View-only format. Open with a compatible viewer or specialized tool.';
      });
    }catch(e){_message('Document open failed: '+e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  void _message(String value){
    if(mounted){
      setState(()=>_status=value);
      FileShareTopNotice.show(context,value);
    }
  }
  Future<void> _findAndReplace()async{
    final find=TextEditingController(text:_search);
    final replace=TextEditingController();
    final confirmed=await showDialog<bool>(context:context,builder:(dialog)=>
      AlertDialog(
        title:const Text('Find and replace'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:find,autofocus:true,
            decoration:const InputDecoration(labelText:'Find')),
          const SizedBox(height:8),
          TextField(controller:replace,
            decoration:const InputDecoration(labelText:'Replace with')),
        ]),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog,false),
            child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(dialog,true),
            child:const Text('Replace All')),
        ],
      ));
    if(confirmed==true && find.text.isNotEmpty){
      var count=0;
      for(final controller in _controllers.values){
        final previous=controller.text;
        if(previous.contains(find.text)){
          count+=find.text.allMatches(previous).length;
          controller.text=previous.replaceAll(find.text,replace.text);
        }
      }
      _message('Replaced '+count.toString()+' occurrence(s)');
    }
    find.dispose();replace.dispose();
  }
  int get _wordCount=>_controllers.values.fold<int>(0,(count,c)=>
    count+c.text.trim().split(RegExp(r'\s+'))
      .where((s)=>s.isNotEmpty).length);

  Future<void> _save() async {
    final doc=_document;
    if(_busy||doc==null)return;
    setState((){_busy=true;_status='Saving edited copy…';});
    try{
      final folder=await getApplicationSupportDirectory();
      final destination=Directory(folder.path+
        Platform.pathSeparator+'file_share_doc_saved');
      final values={for(final e in _controllers.entries)e.key:e.value.text};
      final saved=await doc.saveCopy(values,destination,
        formatChanges:_wordStyles,
        alignmentChanges:_wordAlignments,
        insertedAfter:_newWordParagraphs,
        tablesAfter:_newWordTables,
        deletedParagraphs:_deletedWordParagraphs,
        pagePaper:_pageLayoutDirty?_paperSize:null,
        pageLandscape:_landscape,
        pageMarginTwips:(_pageMarginMm*1440/25.4).round());
      // Export through existing public Android Downloads / Windows folder picker.
      final exported=await TransferDownloads.instance.export(
        saved,saved.uri.pathSegments.last);
      if(!mounted)return;
      // Re-open the persisted copy as the new editing base. This refreshes
      // Word paragraph indices after insert/delete and prevents stale DOM
      // edits when the user saves more than once.
      setState(()=>_busy=false);
      await _openFile(saved,name:saved.uri.pathSegments.last);
      if(mounted){
        setState(()=>_status=exported==null
          ?'Edited copy saved inside File Share Doc. External export canceled.'
          :'Edited copy saved and exported: '+saved.uri.pathSegments.last);
      }
    }catch(e){_message('Save failed: '+e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _send() async{
    final file=_saved??_source;
    if(file==null||_busy)return;
    if(_dirty){
      _message('Save your edits before sending to File Share.');
      return;
    }
    setState((){_busy=true;_status='Adding document to LAN queue…';});
    try{
      if(!appLan.started)await appLan.start();
      await appLan.enqueue([file],names:[_saved==null
        ?(_displayName??file.uri.pathSegments.last)
        :file.uri.pathSegments.last]);
      _message('Document added to the unified LAN transfer dashboard');
    }catch(e){_message('Send failed: '+e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _viewSpecialized()async{
    final file=_saved??_source;
    if(file==null||_busy)return;
    if(_dirty){
      _message('Save a copy to preview the latest edits.');
      return;
    }
    final ext=FileShareDocEngine.ext(
      _saved==null?(_displayName??file.path):file.path);
    try{
      if(['doc','rtf','odt'].contains(ext)){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>GanderProsePreviewPage(document:file,
            name:_saved==null?_displayName:null)));
        return;
      }
      if(['ods'].contains(ext)){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>GanderSpreadsheetPreviewPage(document:file)));
        return;
      }
      if(['xlsx','xlsm','xltx','xls','xlsb'].contains(ext)){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>GanderSpreadsheetPreviewPage(document:file)));
        return;
      }
      if(['pptx','pptm','ppsx','potx'].contains(ext)){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>GanderPresentationPreviewPage(document:file)));
        return;
      }
      if(['md','markdown','html','htm'].contains(ext)){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>GanderMarkupPreviewPage(document:file)));
        return;
      }
      if(ext=='docx'||ext=='docm'||ext=='dotx'){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>GanderDocxPreviewPage(document:file,
            displayName:_saved==null?_displayName:null)));
        return;
      }
      if(ext=='pdf'&&Platform.isWindows){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>FileShareWindowsPdfViewer(file:file,
            name:_saved==null?_displayName:null)));
        return;
      }
      if(ext=='pdf'){
        final consumed=await FileCardOpenRouter.openEditor(
          context,file.path,_displayName??file.uri.pathSegments.last);
        if(consumed)return;
      }
      if(['jpg','png','jpeg','webp','bmp','gif','heic'].contains(ext)){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>ImageEditingPage(sourcePath:file.path,
            sourceName:file.uri.pathSegments.last)));
        return;
      }
      if(ext=='epub'){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>GanderEpubPreviewPage(document:file,
            name:_saved==null?_displayName:null)));
        return;
      }
      if(ext=='zip'){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>GanderArchiveBrowserPage(archive:file)));
        return;
      }
      final result=await OpenFilex.open(file.path);
      if(result.type!=ResultType.done){
        _message('No compatible installed viewer: '+result.message);
      }
    }catch(e){_message('Could not open preview: '+e.toString());}
  }
  @override
  Widget build(BuildContext context){
    final theme=Theme.of(context);
    final doc=_document;
    final file=_source;
    final blocks=doc?.blocks.where((b)=>!_deletedWordParagraphs.contains(b.id) && (
      b.title.toLowerCase().contains(_search.toLowerCase()) ||
      (_controllers[b.id]?.text??'').toLowerCase().contains(_search.toLowerCase()))
    ).toList()??[];
    return Scaffold(
      appBar:AppBar(title:const Text('File Share Doc'),
        actions:[
          if(file!=null)IconButton(
            onPressed:_busy?null:_selectFile,tooltip:'Open another file',
            icon:const Icon(Icons.folder_open_outlined)),
          if(doc!=null)IconButton(
            onPressed:_busy?null:_save,tooltip:'Save edited copy',
            icon:const Icon(Icons.save_outlined)),
        ]),
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:Center(child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:1060),
          child:ListView(padding:const EdgeInsets.all(16),children:[
            if(file==null)...[
              const SizedBox(height:52),
              const Icon(Icons.description_outlined,size:64,color:FileTheme.violet),
              const SizedBox(height:14),
              Text('Open a document in File Share Doc',
                textAlign:TextAlign.center,
                style:theme.textTheme.titleLarge),
              const SizedBox(height:12),
              const Text('DOCX, XLSX, PPTX, ODT, ODS, ODP, HTML, '
                'Markdown, text and more. Editing varies by file format.',
                textAlign:TextAlign.center),
              const SizedBox(height:22),
              FilledButton.icon(onPressed:_busy?null:_selectFile,
                icon:const Icon(Icons.folder_open_outlined),
                label:const Text('Browse files')),
              const SizedBox(height:10),
              OutlinedButton.icon(onPressed:_busy?null:_newDocument,
                icon:const Icon(Icons.note_add_outlined),
                label:const Text('New Word Document')),
            ]else...[
              Text(_saved==null?(_displayName??file.uri.pathSegments.last)
                :file.uri.pathSegments.last,
                style:theme.textTheme.titleMedium?.copyWith(
                  fontWeight:FontWeight.w800)),
              const SizedBox(height:6),
              Text(doc==null?'Viewer only':'Editable text content · Offline',
                style:TextStyle(color:FileTheme.muted(context))),
              const SizedBox(height:14),
              Wrap(spacing:8,runSpacing:8,children:[
                OutlinedButton.icon(onPressed:_busy?null:_viewSpecialized,
                  icon:const Icon(Icons.visibility_outlined),
                  label:const Text('View')),
                if(doc!=null)FilledButton.icon(
                  onPressed:_busy?null:_save,
                  icon:const Icon(Icons.save_outlined),
                  label:const Text('Save Copy')),
                if(doc!=null)OutlinedButton.icon(
                  onPressed:_busy?null:_findAndReplace,
                  icon:const Icon(Icons.find_replace),
                  label:const Text('Replace')),
                OutlinedButton.icon(onPressed:_busy?null:_send,
                  icon:const Icon(Icons.send_outlined),
                  label:const Text('Send to LAN')),
                OutlinedButton.icon(onPressed:_busy?null:_selectFile,
                  icon:const Icon(Icons.folder_open_outlined),
                  label:const Text('Open Another')),
              ]),
              if(_dirty)Padding(padding:const EdgeInsets.only(top:9),
                child:Text('Unsaved changes — saving creates a new file',
                  style:TextStyle(color:theme.colorScheme.error))),
              if(doc!=null)...[
                const SizedBox(height:14),
                Text('Sections: '+doc.blocks.length.toString()+
                  ' · Words: '+_wordCount.toString(),
                  style:theme.textTheme.labelMedium),
                const SizedBox(height:8),
                TextField(
                  onChanged:(v)=>setState(()=>_search=v),
                  decoration:const InputDecoration(
                    prefixIcon:Icon(Icons.search),
                    labelText:'Search document paragraphs / cells / slides',
                    border:OutlineInputBorder())),
                const SizedBox(height:14),
                if(['docx','docm','dotx'].contains(doc.kind))...[
                  _wordToolbar(),
                  const SizedBox(height:10),
                  if(_showWordLayout)_wordPageOptions(),
                  const SizedBox(height:10),
                ],
                if(doc.blocks.isEmpty)
                  const Text('No supported editable text was found in this file.'),
                if(blocks.isNotEmpty && ['docx','docm','dotx'].contains(doc.kind))
                  _wordPaperView(blocks),
                if(blocks.isNotEmpty && !['docx','docm','dotx'].contains(doc.kind))
                  SizedBox(height:(MediaQuery.sizeOf(context).height*.63)
                    .clamp(280.0,760.0).toDouble(),
                    child:ListView.builder(
                      keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount:blocks.length,
                      itemBuilder:(context,index){
                        final block=blocks[index];
                        return Padding(padding:const EdgeInsets.only(bottom:7),
                          child:Card(child:Padding(padding:const EdgeInsets.all(12),
                            child:Column(
                              crossAxisAlignment:CrossAxisAlignment.start,
                              children:[
                                Text(block.title,style:theme.textTheme.labelMedium),
                                if((_newWordParagraphs[block.id]??[]).isNotEmpty)
                                  Text('New paragraphs after: '+
                                    _newWordParagraphs[block.id]!.join(' | '),
                                    style:TextStyle(
                                      color:FileTheme.muted(context),
                                      fontSize:11)),
                                if((_newWordTables[block.id]??[]).isNotEmpty)
                                  Text('Tables to insert: '+
                                    _newWordTables[block.id]!.length.toString(),
                                    style:TextStyle(
                                      color:FileTheme.muted(context),
                                      fontSize:11)),

                                const SizedBox(height:7),
                                TextField(
                                  onTap:()=>setState(
                                    ()=>_selectedWordParagraph=block.id),
                                  style:TextStyle(
                                    fontWeight:(_wordStyles[block.id]??{})
                                      .contains('bold')?FontWeight.bold:null,
                                    fontStyle:(_wordStyles[block.id]??{})
                                      .contains('italic')?FontStyle.italic:null,
                                    decoration:(_wordStyles[block.id]??{})
                                      .contains('underline')
                                        ?TextDecoration.underline:null),
                                  controller:_controllers[block.id],
                                  enabled:!_busy,
                                  maxLines:null,minLines:1,
                                  decoration:const InputDecoration(
                                    isDense:true,border:OutlineInputBorder())),
                              ]))));
                      })),
              ]else...[
                const SizedBox(height:24),
                const Icon(Icons.visibility_outlined,size:54),
                const SizedBox(height:8),
                const Text('This file has no built-in editing engine. '
                  'Tap View to open a compatible local viewer.'),
              ],
            ],
            if(_busy)const Padding(padding:EdgeInsets.symmetric(vertical:18),
              child:LinearProgressIndicator()),
            if(_status!=null)Padding(padding:const EdgeInsets.only(top:14),
              child:Text(_status!,style:TextStyle(
                color:FileTheme.muted(context)))),
          ]))),
      ),
    );
  }
}
