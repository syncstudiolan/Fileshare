import 'app_top_notice.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'file_share_doc_engine.dart';
import 'file_share_doc_page.dart';
import 'file_share_windows_pdf_viewer.dart';
import 'image_editing_page.dart';
import 'main.dart' show FileTheme,FileCardOpenRouter;
import 'transfer_downloads.dart';

/// Local ZIP browser/editor. Archive members never escape the app temp folder
/// through their untrusted entry paths; edits produce a new ZIP, never overwrite.
class GanderArchiveBrowserPage extends StatefulWidget {
  const GanderArchiveBrowserPage({super.key,required this.archive});
  final File archive;
  @override State<GanderArchiveBrowserPage> createState()=>
    _GanderArchiveBrowserPageState();
}
class _GanderArchiveBrowserPageState
    extends State<GanderArchiveBrowserPage>{
  Archive? _archive;
  String _folder='';
  String? _error,_notice;
  bool _busy=false,_dirty=false;
  final _deleted=<String>{};
  final _renamed=<String,String>{};
  final _added=<String,Uint8List>{};
  @override void initState(){super.initState();_load();}
  Future<void> _load()async{
    try{
      if(await widget.archive.length()>32*1024*1024){
        throw StateError('Archive exceeds 32 MB browse limit');
      }
      final zip=ZipDecoder().decodeBytes(await widget.archive.readAsBytes());
      if(zip.length>10000||
        zip.fold<int>(0,(n,f)=>n+f.size)>256*1024*1024){
        throw StateError('ZIP contents exceed safety limits');
      }
      if(mounted)setState(()=>_archive=zip);
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }
  static String _safe(String name)=>name
    .replaceAll(RegExp(r'[/\\\x00-\x1f]'),'_')
    .replaceAll('..','_').trim();
  String _display(String name)=>_renamed[name]??name;
  List<String> get _children{
    final all=<String>{};
    for(final entry in _archive??<ArchiveFile>[]){
      if(!_deleted.contains(entry.name))all.add(_display(entry.name));
    }
    all.addAll(_added.keys);
    final shown=<String>{};
    for(final path in all){
      if(!path.startsWith(_folder)||path==_folder)continue;
      final relative=path.substring(_folder.length);
      final slash=relative.indexOf('/');
      if(slash>=0)shown.add(_folder+relative.substring(0,slash+1));
      else shown.add(_folder+relative);
    }
    return shown.toList()..sort((a,b){
      final d=a.endsWith('/'),e=b.endsWith('/');
      return d!=e?(d?-1:1):a.compareTo(b);
    });
  }
  ArchiveFile? _find(String path){
    for(final item in _archive??<ArchiveFile>[]){
      if(!_deleted.contains(item.name)&&_display(item.name)==path){
        return item;
      }
    }
    return null;
  }
  void _noticeUser(String value){
    if(mounted){
      setState(()=>_notice=value);
      FileShareTopNotice.show(context,value);
    }
  }
  Future<void> _open(String path)async{
    if(path.endsWith('/')){setState(()=>_folder=path);return;}
    if(_busy)return;
    final bytes=_added[path]??_find(path)?.content;
    if(bytes==null)return;
    if(bytes.length>32*1024*1024){
      _noticeUser('Entry too large to preview');return;
    }
    setState(()=>_busy=true);
    try{
      final temp=await getTemporaryDirectory();
      final directory=Directory(temp.path+
        Platform.pathSeparator+'file_share_archive');
      await directory.create(recursive:true);
      final name=_safe(path.split('/').last);
      final file=File(directory.path+Platform.pathSeparator+
        DateTime.now().microsecondsSinceEpoch.toString()+'_'+name);
      await file.writeAsBytes(bytes,flush:true);
      if(!mounted)return;
      final type=FileShareDocEngine.ext(name);
      if(type=='zip'){
        await Navigator.push(context,MaterialPageRoute<void>(
          builder:(_)=>GanderArchiveBrowserPage(archive:file)));
      }else if(FileCardOpenRouter.isImage(name)){
        await Navigator.push(context,MaterialPageRoute<void>(
          builder:(_)=>ImageEditingPage(
            sourcePath:file.path,sourceName:name)));
      }else if(type=='pdf'&&Platform.isWindows){
        await Navigator.push(context,MaterialPageRoute<void>(
          builder:(_)=>FileShareWindowsPdfViewer(file:file,name:name)));
      }else if(type=='pdf'&&Platform.isAndroid){
        await FileCardOpenRouter.openEditor(context,file.path,name);
      }else if(FileShareDocEngine.canView(name)){
        await Navigator.push(context,MaterialPageRoute<void>(
          builder:(_)=>FileShareDocPage(
            sourcePath:file.path,sourceName:name)));
      }else{
        final result=await OpenFilex.open(file.path);
        if(result.type!=ResultType.done)_noticeUser(result.message);
      }
    }catch(e){_noticeUser('Cannot open ZIP entry: '+e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _rename(String path)async{
    if(_busy)return;
    final item=_find(path);
    if(item==null||!item.isFile)return;
    final controller=TextEditingController(text:path.split('/').last);
    final okay=await showDialog<bool>(context:context,builder:(dialog)=>
      AlertDialog(title:const Text('Rename ZIP entry'),
        content:TextField(controller:controller,
          decoration:const InputDecoration(labelText:'Filename')),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog,false),
            child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(dialog,true),
            child:const Text('Rename'))]));
    if(okay==true&&mounted){
      final safe=_safe(controller.text);
      final target=_folder+safe;
      if(safe.isEmpty||_children.contains(target)){
        _noticeUser('Duplicate or invalid ZIP filename');
      }else setState((){
        _renamed[item.name]=target;
        _dirty=true;
      });
    }
    controller.dispose();
  }
  void _delete(String path){
    final item=_find(path);
    setState((){
      if(item!=null)_deleted.add(item.name);
      else _added.remove(path);
      _dirty=true;
    });
  }
  Future<void> _chooseFiles()async{
    if(_busy)return;
    try{
      final result=await FilePicker.pickFiles(
        type:FileType.any);
      var count=0;
      for(final item in result){
        final name=_safe(item.name),target=_folder+_safe(item.name);
        if(name.isEmpty||_children.contains(target))continue;
        final bytes=await item.readAsBytes();
        if(bytes.length>16*1024*1024){
          _noticeUser('Skipped oversized file: '+item.name);continue;
        }
        _added[target]=bytes;
        count++;
      }
      if(mounted)setState((){
        if(count>0)_dirty=true;
        _notice='Added '+count.toString()+' file(s)';
      });
    }catch(e){_noticeUser('ZIP import failed: '+e.toString());}
  }
  Future<void> _save()async{
    if(_busy||!_dirty||_archive==null)return;
    setState(()=>_busy=true);
    try{
      final output=Archive();
      for(final item in _archive!){
        if(_deleted.contains(item.name))continue;
        final path=_display(item.name);
        if(item.isFile)output.add(ArchiveFile.bytes(path,item.content));
        else output.add(ArchiveFile.directory(path));
      }
      for(final entry in _added.entries){
        output.add(ArchiveFile.bytes(entry.key,entry.value));
      }
      final root=await getApplicationSupportDirectory();
      final directory=Directory(root.path+
        Platform.pathSeparator+'file_share_doc_saved');
      await directory.create(recursive:true);
      final safe=_safe(widget.archive.uri.pathSegments.last);
      final filename=safe.toLowerCase().endsWith('.zip')
        ?safe.substring(0,safe.length-4)+'_edited.zip':safe+'_edited.zip';
      final out=File(directory.path+Platform.pathSeparator+
        DateTime.now().microsecondsSinceEpoch.toString()+'_'+filename);
      await out.writeAsBytes(ZipEncoder().encodeBytes(output),flush:true);
      final decoded=ZipDecoder().decodeBytes(await out.readAsBytes());
      if(decoded.length!=output.length){
        await out.delete();
        throw StateError('ZIP save verification failed');
      }
      final exported=await TransferDownloads.instance.export(out,filename);
      _noticeUser(exported==null?'Saved in File Share (export canceled)'
        :'ZIP saved: '+exported);
    }catch(e){_noticeUser('ZIP save failed: '+e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  @override Widget build(BuildContext context){
    final entries=_children;
    return Scaffold(
      appBar:AppBar(title:const Text('ZIP Archive'),
        actions:[
          IconButton(tooltip:'Add files',onPressed:_busy?null:_chooseFiles,
            icon:const Icon(Icons.add_circle_outline)),
          IconButton(tooltip:'Save edited ZIP copy',
            onPressed:_busy||!_dirty?null:_save,
            icon:const Icon(Icons.save_outlined)),
        ]),
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:_error!=null?Center(child:Text(_error!)):
          _archive==null?const Center(child:CircularProgressIndicator()):
          Column(children:[
            ListTile(leading:const Icon(Icons.folder_zip_outlined),
              title:Text(widget.archive.uri.pathSegments.last),
              subtitle:Text(_folder.isEmpty?'/':_folder)),
            if(_folder.isNotEmpty)
              ListTile(leading:const Icon(Icons.arrow_upward),
                title:const Text('.. Parent folder'),
                onTap:()=>setState((){
                  final last=_folder.substring(0,_folder.length-1);
                  final slash=last.lastIndexOf('/');
                  _folder=slash<0?'':last.substring(0,slash+1);
                })),
            Expanded(child:ListView.builder(itemCount:entries.length,
              itemBuilder:(context,index){
                final path=entries[index],dir=path.endsWith('/');
                return ListTile(
                  leading:Icon(dir?Icons.folder_outlined:
                    Icons.insert_drive_file_outlined),
                  title:Text(path.substring(_folder.length)),
                  onTap:()=>_open(path),
                  trailing:dir?null:Row(mainAxisSize:MainAxisSize.min,
                    children:[
                      IconButton(tooltip:'Rename',onPressed:_busy?null:
                        ()=>_rename(path),
                        icon:const Icon(Icons.edit_outlined)),
                      IconButton(tooltip:'Delete',onPressed:_busy?null:
                        ()=>_delete(path),
                        icon:const Icon(Icons.delete_outline)),
                    ]),
                );
              })),
            if(_busy)const LinearProgressIndicator(),
            if(_notice!=null)Padding(padding:const EdgeInsets.all(10),
              child:Text(_notice!)),
          ]),
      ),
    );
  }
}
