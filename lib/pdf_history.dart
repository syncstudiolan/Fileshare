import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'editor_transfer_session.dart';

/// Local-only PDF history. Drafts store the actual PDF so unfinished edits can
/// be sent to the File Share cart or resumed after a process restart.
class PdfDraft {
  const PdfDraft({required this.id,required this.name,required this.path,
    required this.updated,required this.actions,this.page=0});
  final String id,name,path;
  final DateTime updated;
  final List<String> actions;
  final int page;
  Map<String,dynamic> toJson()=>{'id':id,'name':name,'path':path,
    'updated':updated.toIso8601String(),'actions':actions,'page':page};
  factory PdfDraft.fromJson(Map<String,dynamic> x)=>PdfDraft(
    id:x['id'] as String,name:x['name'] as String,path:x['path'] as String,
    updated:DateTime.parse(x['updated'] as String),
    actions:(x['actions'] as List? ?? []).whereType<String>().toList(),
    page:(x['page'] as num?)?.toInt()??0);
  PdfDraft copyWith({String? name,String? path,List<String>? actions,int? page})=>
    PdfDraft(id:id,name:name??this.name,path:path??this.path,
      updated:DateTime.now(),actions:actions??this.actions,page:page??this.page);
}

class PdfHistory extends ChangeNotifier {
  PdfHistory._();
  static final instance=PdfHistory._();
  final List<PdfDraft> _items=[];
  List<PdfDraft> get items=>List.unmodifiable(_items);
  bool _loaded=false;
  Future<Directory> get directory async{
    final base=await getApplicationSupportDirectory();
    final dir=Directory('${base.path}${Platform.pathSeparator}advanced_pdf');
    await dir.create(recursive:true);return dir;
  }
  Future<File> get manifest async{
    final dir=await directory;
    return File('${dir.path}${Platform.pathSeparator}history.json');
  }
  static String validName(String name){
    var value=name.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'),'_');
    if(value.toLowerCase().endsWith('.pdf'))value=value.substring(0,value.length-4);
    if(value.isEmpty)value='Document';
    value=value.length>100?value.substring(0,100):value;
    return '$value.pdf';
  }
  Future<void> load()async{
    if(_loaded)return;
    _loaded=true;
    final file=await manifest;
    if(!await file.exists())return;
    try{
      final data=jsonDecode(await file.readAsString()) as List;
      for(final raw in data){
        if(raw is! Map)continue;
        final item=PdfDraft.fromJson(Map<String,dynamic>.from(raw));
        if(await File(item.path).exists())_items.add(item);
      }
      _items.sort((a,b)=>b.updated.compareTo(a.updated));
    }catch(_){_items.clear();}
    notifyListeners();
  }
  Future<void> _persist()async{
    final file=await manifest;
    final temporary=File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(_items.map((e)=>e.toJson()).toList()),flush:true);
    if(await file.exists())await file.delete();
    await temporary.rename(file.path);
    notifyListeners();
  }
  Future<PdfDraft> save({required String id,required String name,
    required String sourcePath,required List<String> actions,int page=0})async{
    await load();
    final dir=await directory;
    final file=File('${dir.path}${Platform.pathSeparator}${id}_${DateTime.now().microsecondsSinceEpoch}.pdf');
    await File(sourcePath).copy(file.path);
    final old=_items.where((e)=>e.id==id).firstOrNull;
    final item=PdfDraft(id:id,name:validName(name),path:file.path,
      updated:DateTime.now(),actions:List.unmodifiable(actions),page:page);
    _items.removeWhere((e)=>e.id==id);
    _items.insert(0,item);
    await _persist();
    if(old!=null&&old.path!=file.path)try{await File(old.path).delete();}catch(_){}
    return item;
  }
  /// Rename changes the user-visible name without deleting the preserved edit.
  Future<PdfDraft> rename(PdfDraft draft,String value)async{
    await load();
    final next=draft.copyWith(name:validName(value));
    final i=_items.indexWhere((e)=>e.id==draft.id);
    if(i<0)throw StateError('PDF history entry not found');
    _items[i]=next;_items.sort((a,b)=>b.updated.compareTo(a.updated));
    await _persist();return next;
  }
  Future<void> delete(PdfDraft draft)async{
    await load();_items.removeWhere((e)=>e.id==draft.id);
    await _persist();
    try{await File(draft.path).delete();}catch(_){}
    await EditorSessionStore.instance.delete('pdf',draft.id);
  }
}
