import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'editor_transfer_session.dart';

class ImageEditingDraft {
  const ImageEditingDraft({required this.id, required this.name,
    required this.filePath, required this.created, required this.updated,
    required this.steps});
  final String id, name, filePath;
  final DateTime created, updated;
  final List<String> steps;
  Map<String,dynamic> toJson()=>{
    'id':id,'name':name,'filePath':filePath,
    'created':created.toIso8601String(),
    'updated':updated.toIso8601String(),'steps':steps,
  };
  factory ImageEditingDraft.fromJson(Map<String,dynamic> json)=>
    ImageEditingDraft(
      id:json['id'] as String,name:json['name'] as String,
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
    required List<String> steps,
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
    final now=DateTime.now();
    final draft=ImageEditingDraft(
      id:id,name:name,filePath:path,created:previous?.created??now,
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
    await EditorSessionStore.instance.delete('image',draft.id);
  }
}

class ImageEditingCartEntry {
  const ImageEditingCartEntry(this.file,this.name);
  final File file;
  final String name;
}
/// Lightweight bridge into existing Send staging. Does not upload by itself.
class ImageEditingCart extends ChangeNotifier {
  ImageEditingCart._();
  static final instance=ImageEditingCart._();
  final List<ImageEditingCartEntry> _pending=[];
  void add(File file,String name) {
    _pending.add(ImageEditingCartEntry(file,name));
    notifyListeners();
  }
  List<ImageEditingCartEntry> takeAll() {
    final items=List<ImageEditingCartEntry>.from(_pending);
    _pending.clear();
    return items;
  }
}
