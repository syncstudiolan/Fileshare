import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'file_share_doc_engine.dart';
import 'gander_docx_preview_page.dart';
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
  FileShareDocEngine? _document;
  final _controllers=<String,TextEditingController>{};
  bool _busy=false;
  bool _dirty=false;
  String? _status;
  String _search='';
  @override
  void initState(){
    super.initState();
    if(widget.sourcePath!=null){
      unawaited(_openFile(File(widget.sourcePath!)));
    }
  }
  @override
  void dispose(){
    for(final c in _controllers.values)c.dispose();
    super.dispose();
  }
  Future<void> _selectFile()async{
    if(_busy)return;
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
      await _openFile(file);
    }catch(e){_message('Cannot open file: '+e.toString());}
  }
  Future<void> _openFile(File file) async {
    if(_busy)return;
    setState((){_busy=true;_status='Opening document…';});
    try{
      if(!await file.exists())throw StateError('Selected document is unavailable');
      final allowed=FileShareDocEngine.canView(file.path);
      if(!allowed)throw UnsupportedError('Unsupported file type');
      final edit=FileShareDocEngine.canEdit(file.path);
      FileShareDocEngine? doc;
      if(edit)doc=await FileShareDocEngine.open(file);
      for(final c in _controllers.values)c.dispose();
      _controllers.clear();
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(value)));
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
    count+c.text.trim().split(RegExp(r'\\s+'))
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
      final saved=await doc.saveCopy(values,destination);
      // Export through existing public Android Downloads / Windows folder picker.
      final exported=await TransferDownloads.instance.export(
        saved,saved.uri.pathSegments.last);
      if(!mounted)return;
      setState((){
        _saved=saved;_dirty=false;
        _status=exported==null
          ?'Edited copy saved inside File Share Doc. External export canceled.'
          :'Edited copy saved and exported: '+saved.uri.pathSegments.last;
      });
    }catch(e){_message('Save failed: '+e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _send() async{
    final file=_saved??_source;
    if(file==null||_busy)return;
    setState((){_busy=true;_status='Adding document to LAN queue…';});
    try{
      if(!appLan.started)await appLan.start();
      await appLan.enqueue([file],names:[file.uri.pathSegments.last]);
      _message('Document added to the unified LAN transfer dashboard');
    }catch(e){_message('Send failed: '+e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _viewSpecialized()async{
    final file=_source;
    if(file==null||_busy)return;
    final ext=FileShareDocEngine.ext(file.path);
    try{
      if(ext=='docx'||ext=='docm'||ext=='dotx'){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>GanderDocxPreviewPage(document:file)));
        return;
      }
      if(ext=='pdf'){
        final consumed=await FileCardOpenRouter.openEditor(
          context,file.path,file.uri.pathSegments.last);
        if(consumed)return;
      }
      if(['jpg','png','jpeg','webp','bmp','gif','heic'].contains(ext)){
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder:(_)=>ImageEditingPage(sourcePath:file.path,
            sourceName:file.uri.pathSegments.last)));
        return;
      }
      if(ext=='zip'||ext=='epub'){
        if(await file.length()>32*1024*1024){
          throw StateError('Archive too large for in-app listing');
        }
        final entries=ZipDecoder().decodeBytes(await file.readAsBytes());
        if(!mounted)return;
        await showDialog<void>(context:context,builder:(dialog)=>AlertDialog(
          title:Text('Archive · '+file.uri.pathSegments.last),
          content:SizedBox(width:500,height:420,
            child:ListView.builder(itemCount:entries.length,
              itemBuilder:(_,i)=>ListTile(
                dense:true,leading:Icon(entries[i].isFile
                  ?Icons.insert_drive_file_outlined:Icons.folder_outlined),
                title:Text(entries[i].name)))),
          actions:[TextButton(onPressed:()=>Navigator.pop(dialog),
            child:const Text('Close'))]));
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
    final blocks=doc?.blocks.where((b)=>
      b.title.toLowerCase().contains(_search.toLowerCase()) ||
      (_controllers[b.id]?.text??'').toLowerCase().contains(_search.toLowerCase())
    ).toList()??[];
    return Scaffold(
      appBar:AppBar(title:const Text('File Share Doc'),
        actions:[
          if(file!=null)IconButton(
            onPressed:_busy?null:_selectFile,tooltip:'Open another file',
            icon:const Icon(Icons.folder_open_outlined)),
          if(doc!=null)IconButton(
            onPressed:_busy||!_dirty?null:_save,tooltip:'Save edited copy',
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
            ]else...[
              Text(file.uri.pathSegments.last,
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
                  onPressed:_busy||!_dirty?null:_save,
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
                if(doc.blocks.isEmpty)
                  const Text('No supported editable text was found in this file.'),
                for(final block in blocks)...[
                  Card(child:Padding(padding:const EdgeInsets.all(12),
                    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                      Text(block.title,style:theme.textTheme.labelMedium),
                      const SizedBox(height:7),
                      TextField(
                        controller:_controllers[block.id],
                        enabled:!_busy,
                        maxLines:null,minLines:1,
                        decoration:const InputDecoration(
                          isDense:true,border:OutlineInputBorder())),
                    ]))),
                  const SizedBox(height:6),
                ],
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
