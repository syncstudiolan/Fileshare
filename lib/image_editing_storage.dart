import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'editor_transfer_session.dart';

class ImageEditingDraft {
  const ImageEditingDraft({required this.id, required this.name,
    required this.filePath, required this.created, required this.updated,
    required this.steps,this.originalFilePath});
  final String id, name, filePath;
  final String? originalFilePath;
  final DateTime created, updated;
  final List<String> steps;
  Map<String,dynamic> toJson()=>{
    'id':id,'name':name,'filePath':filePath,
    if(originalFilePath!=null)'originalFilePath':originalFilePath,
    'created':created.toIso8601String(),
    'updated':updated.toIso8601String(),'steps':steps,
  };
  factory ImageEditingDraft.fromJson(Map<String,dynamic> json)=>
    ImageEditingDraft(
      id:json['id'] as String,name:json['name'] as String,
      originalFilePath:json['originalFilePath'] as String?,
      filePath:json['filePath'] as String,
      created:DateTime.parse(json['created'] as String),
      updated:DateTime.parse(json['updated'] as String),
      steps:(json['steps'] as List).whereType<String>().toList());
}

/// Local-only project drafts survive closing the editor and application.
/// No data is uploaded, and files are not silently purged at QR midnight.
class ImageEditingHistory extends ChangeNotifier {
  ImageEditingHistory._();
  static final instance=ImageEditingHistory._();
  List<ImageEditingDraft> drafts=[];
  bool _loaded=false;
  Future<Directory> get directory async {
    final app=await getApplicationSupportDirectory();
    final directory=Directory('${app.path}${Platform.pathSeparator}image_editing');
    await directory.create(recursive:true);
    return directory;
  }
  Future<File> get _manifest async {
    final folder=await directory;
    return File('${folder.path}${Platform.pathSeparator}history.json');
  }
  Future<void> load() async {
    if(_loaded)return;
    _loaded=true;
    final manifest=await _manifest;
    if(!await manifest.exists())return;
    try{
      final data=jsonDecode(await manifest.readAsString()) as List;
      final results=<ImageEditingDraft>[];
      for(final raw in data){
        if(raw is! Map<String,dynamic>)continue;
        final entry=ImageEditingDraft.fromJson(raw);
        if(await File(entry.filePath).exists())results.add(entry);
      }
      drafts=results..sort((a,b)=>b.updated.compareTo(a.updated));
      notifyListeners();
    }catch(_){drafts=[];}
  }
  Future<void> _persist() async {
    final manifest=await _manifest;
    final next=File('${manifest.path}.tmp');
    await next.writeAsString(jsonEncode(drafts.map((e)=>e.toJson()).toList()),
      flush:true);
    if(await manifest.exists())await manifest.delete();
    await next.rename(manifest.path);
    notifyListeners();
  }
  Future<ImageEditingDraft> save({
    required String id,required String name,required List<int> bytes,
    required List<String> steps,List<int>? originalBytes,
  })async{
    await load();
    final root=await directory;
    final previous=drafts.where((x)=>x.id==id).firstOrNull;
    final old=previous?.filePath;
    final extension=bytes.length>=2 && bytes[0]==0xff && bytes[1]==0xd8
      ?'jpg':'png';
    final path='${root.path}${Platform.pathSeparator}${id}_${DateTime.now().microsecondsSinceEpoch}.$extension';
    final file=File(path);
    await file.writeAsBytes(bytes,flush:true);
    // Preserve the original import independently of the edited history
    // snapshot so Cart/Global Share can always send the untouched source.
    String? originalPath=previous?.originalFilePath;
    if(originalBytes!=null && (originalPath==null ||
        !await File(originalPath).exists())){
      final jpeg=originalBytes.length>1&&
        originalBytes[0]==0xff&&originalBytes[1]==0xd8;
      final original=File('${root.path}${Platform.pathSeparator}'
        'original_${id}.${jpeg?'jpg':'png'}');
      await original.writeAsBytes(originalBytes,flush:true);
      originalPath=original.path;
    }
    final now=DateTime.now();
    final draft=ImageEditingDraft(
      id:id,name:name,filePath:path,originalFilePath:originalPath,
      created:previous?.created??now,
      updated:now,steps:List.unmodifiable(steps));
    drafts=[draft,...drafts.where((x)=>x.id!=id)];
    await _persist();
    if(old!=null && old!=path){
      try{await File(old).delete();}catch(_){}
    }
    return draft;
  }
  Future<void> delete(ImageEditingDraft draft)async {
    await load();
    drafts.removeWhere((item)=>item.id==draft.id);
    await _persist();
    try{await File(draft.filePath).delete();}catch(_){}
    if(draft.originalFilePath!=null){
      try{await File(draft.originalFilePath!).delete();}catch(_){}
    }
    await EditorSessionStore.instance.delete('image',draft.id);
  }
}

class ImageEditingCartEntry {
  const ImageEditingCartEntry(this.file,this.name,{required this.versionId});
  final File file;
  final String name,versionId;
}

/// An edited output is a NEW transfer version, even when derived from a file
/// already present in LAN history, Cloud history, or the unsent Cart.
/// Never compare by source path, display name, or original transfer ID.
class ImageEditingCart extends ChangeNotifier {
  ImageEditingCart._();
  static final instance=ImageEditingCart._();
  final List<ImageEditingCartEntry> _pending=[];
  int _sequence=0;

  String _newVersionId(){
    final time=DateTime.now().microsecondsSinceEpoch;
    return '${time}_${_sequence++}';
  }

  Future<File> _versionFile(String name,String version)async{
    final root=await getApplicationSupportDirectory();
    final folder=Directory('${root.path}${Platform.pathSeparator}editor_cart_versions');
    await folder.create(recursive:true);
    final safe=name.replaceAll(RegExp(r'[\\/\x00-\x1f]'),'_');
    return File('${folder.path}${Platform.pathSeparator}${version}_${safe.isEmpty?'edited_file':safe}');
  }

  /// Persist fresh edited bytes before notifying the Dashboard listener.
  /// The source image/draft and any previous Cart snapshot stay untouched.
  Future<ImageEditingCartEntry> addEditedBytes(
      List<int> bytes,String name)async{
    if(bytes.isEmpty)throw StateError('Edited file is empty');
    final version=_newVersionId();
    final file=await _versionFile(name,version);
    try{
      await file.writeAsBytes(bytes,flush:true);
      final item=ImageEditingCartEntry(file,name,versionId:version);
      _pending.add(item);
      notifyListeners();
      return item;
    }catch(_){
      if(await file.exists())await file.delete();
      rethrow;
    }
  }

  /// History and other editors can re-add the SAME source any number of times.
  Future<ImageEditingCartEntry> addEditedFile(
      File source,String name)async{
    if(!await source.exists())throw StateError('Edited file unavailable');
    final version=_newVersionId();
    final file=await _versionFile(name,version);
    try{
      await source.copy(file.path);
      if(await file.length()==0)throw StateError('Edited file is empty');
      final item=ImageEditingCartEntry(file,name,versionId:version);
      _pending.add(item);
      notifyListeners();
      return item;
    }catch(_){
      if(await file.exists())await file.delete();
      rethrow;
    }
  }

  // Legacy callers keep their API; every call is a distinct version.
  void add(File file,String name) {
    _pending.add(ImageEditingCartEntry(file,name,versionId:_newVersionId()));
    notifyListeners();
  }

  List<ImageEditingCartEntry> takeAll() {
    final items=List<ImageEditingCartEntry>.from(_pending);
    _pending.clear();
    return items;
  }
}
