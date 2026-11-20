import 'app_top_notice.dart';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart' show FileTheme, appLan;
import 'lan_engine.dart';

/// Share any file or an entire nested folder using the existing LAN queue.
/// Directory structure is retained inside a ZIP, which is safe to transport
/// over the existing file-based LAN protocol and can be opened by any OS.
class LanFolderSharePage extends StatefulWidget {
  const LanFolderSharePage({super.key, this.sourcePath, this.sourceName});
  final String? sourcePath, sourceName;
  @override State<LanFolderSharePage> createState() => _LanFolderSharePageState();
}

class _LanFolderSharePageState extends State<LanFolderSharePage> {
  final _files=<File>[];
  final _names=<String>[];
  bool _busy=false;
  String? _status;

  @override void initState() {
    super.initState();
    if(widget.sourcePath!=null && File(widget.sourcePath!).existsSync()){
      _files.add(File(widget.sourcePath!));
      _names.add(widget.sourceName??File(widget.sourcePath!).uri.pathSegments.last);
    }
  }

  Future<void> _chooseFiles() async {
    if(_busy)return;
    setState(()=>_busy=true);
    try {
      final result=await FilePicker.pickFiles(type:FileType.any);
      for(final entry in result) {
        final path=entry.path;
        File? file;
        if(path!=null && await File(path).exists()) {
          file=File(path);
        } else {
          // Some Android/remote providers supply a SAF stream, not a path.
          final root=await getApplicationSupportDirectory();
          final dir=Directory('${root.path}${Platform.pathSeparator}folder_share_cart');
          await dir.create(recursive:true);
          final safe=LanEngine.safeFileName(entry.name);
          final target=File('${dir.path}${Platform.pathSeparator}${LanEngine.newId()}_$safe');
          final sink=target.openWrite();
          try {
            await for(final chunk in entry.readAsByteStream()) {sink.add(chunk);}
            await sink.close();
            file=target;
          } catch (_) {
            await sink.close();
            if(await target.exists())await target.delete();
            rethrow;
          }
        }
        _files.add(file);
        _names.add(entry.name);
      }
      if(mounted)setState(()=>_status='Selected ${_files.length} file(s)');
    } catch(e) {
      if(mounted)setState(()=>_status='Could not browse files: $e');
    } finally {if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _chooseFolder() async {
    if(_busy)return;
    setState((){_busy=true;_status='Select a folder from the system file manager';});
    try {
      final selected=await FilePicker.getDirectoryPath(
        dialogTitle:'Select folder to share over LAN');
      if(selected==null)return;
      final root=await getTemporaryDirectory();
      final out=Directory('${root.path}${Platform.pathSeparator}lan_folders');
      await out.create(recursive:true);
      final folderName=selected.startsWith('content://')
        ?Uri.parse(selected).pathSegments.last.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'),'_')
        :Directory(selected).uri.pathSegments.where((s)=>s.isNotEmpty).last;
      final name=LanEngine.safeFileName(folderName)+'.zip';
      final archive=File('${out.path}${Platform.pathSeparator}${LanEngine.newId()}_$name');
      if(mounted)setState(()=>_status='Packing folder and subfolders…');
      if(Platform.isAndroid && selected.startsWith('content://')){
        // Android SAF tree URIs cannot be traversed with dart:io File.
        // Native DocumentsContract reads the picked tree with URI grants.
        final result=await const MethodChannel('file_share.native')
          .invokeMethod<Map<dynamic,dynamic>>('zipSafDirectory',{
            'uri':selected,'target':archive.path,'name':folderName,
          });
        if(result==null || result['path'] == null){
          throw StateError('Selected folder could not be archived');
        }
      } else {
        final dir=Directory(selected);
        if(!await dir.exists()) throw StateError('Selected folder unavailable');
        final encoder=ZipFileEncoder();
        encoder.create(archive.path);
        try {
          await encoder.addDirectory(dir, includeDirName:true, followLinks:false);
        } finally { await encoder.close(); }
      }
      if(!await archive.exists() || await archive.length()==0){
        throw StateError('Folder archive is empty');
      }
      _files.add(archive);
      _names.add(name);
      if(mounted)setState(()=>_status='Folder ready: $name (includes subfolders)');
    } catch(e) {
      if(mounted)setState(()=>_status='Could not prepare folder: $e');
    } finally {if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _send() async {
    if(_busy||_files.isEmpty)return;
    setState((){_busy=true;_status='Adding files to the LAN send queue…';});
    try{
      if(!appLan.started)await appLan.start();
      final sources=List<File>.of(_files), names=List<String>.of(_names);
      await appLan.enqueue(sources,names:names);
      // Queue has its own durable copies. Remove only app-owned staging,
      // never an original file from the user's file manager.
      final tmp=await getTemporaryDirectory();
      final support=await getApplicationSupportDirectory();
      for(final source in sources) {
        final path=source.absolute.path;
        final owned=path.startsWith(
          '${tmp.path}${Platform.pathSeparator}lan_folders${Platform.pathSeparator}') ||
          path.startsWith(
          '${support.path}${Platform.pathSeparator}folder_share_cart${Platform.pathSeparator}');
        if(owned) {
          try {if(await source.exists())await source.delete();}catch(_){}
        }
      }
      _files.clear();_names.clear();
      if(!mounted)return;
      setState(()=>_status=appLan.peers.isEmpty
        ?'Queued safely. Will send when a nearby LAN device appears.'
        :'Queued for LAN transfer. Track it in your dashboard.');
      FileShareTopNotice.show(context,'Added to unified File Share dashboard');
    }catch(e){
      if(mounted)setState(()=>_status='Could not queue transfer: $e');
    }finally{if(mounted)setState(()=>_busy=false);}
  }

  @override Widget build(BuildContext context){
    final wide=MediaQuery.sizeOf(context).width>650;
    return Scaffold(
      appBar:AppBar(title:const Text('File Share · LAN')),
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:780),
          child:ListView(padding:EdgeInsets.all(wide?26:14),children:[
            Text('Share files and entire folders',style:Theme.of(context)
              .textTheme.titleLarge?.copyWith(fontWeight:FontWeight.w800)),
            const SizedBox(height:6),
            const Text('Send any file format, ZIP archive or a complete folder '
              'with nested subfolders over nearby LAN. Folders are packaged as '
              'ZIP to preserve their structure and names. No internet required.'),
            const SizedBox(height:20),
            Wrap(spacing:10,runSpacing:10,children:[
              FilledButton.icon(onPressed:_busy?null:_chooseFiles,
                icon:const Icon(Icons.attach_file_rounded),label:const Text('Browse files')),
              OutlinedButton.icon(onPressed:_busy?null:_chooseFolder,
                icon:const Icon(Icons.folder_open_rounded),label:const Text('Browse folder')),
            ]),
            if(_busy)const Padding(padding:EdgeInsets.symmetric(vertical:12),
              child:LinearProgressIndicator()),
            if(_status!=null)Padding(padding:const EdgeInsets.only(top:12),
              child:Text(_status!,style:TextStyle(color:FileTheme.muted(context)))),
            const SizedBox(height:14),
            for(var i=0;i<_names.length;i++)
              Card(child:ListTile(
                leading:Icon(_names[i].toLowerCase().endsWith('.zip')
                  ?Icons.folder_zip_outlined:Icons.insert_drive_file_outlined,
                  color:FileTheme.violet),
                title:Text(_names[i],maxLines:2,overflow:TextOverflow.ellipsis),
                subtitle:Text(_files[i].path),
                trailing:IconButton(tooltip:'Remove from selection',
                  onPressed:_busy?null:()=>setState((){
                    _names.removeAt(i);_files.removeAt(i);
                  }),icon:const Icon(Icons.close_rounded)))),
            const SizedBox(height:14),
            FilledButton.icon(onPressed:_busy||_files.isEmpty?null:_send,
              icon:const Icon(Icons.send_rounded),
              label:Text('Send ${_files.length} selected item(s) over LAN')),
          ]))),
      ),
    );
  }
}
