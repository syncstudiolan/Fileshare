import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Shared lifecycle: persist an editable session separately from the
/// immutable file snapshot placed in File Share's Send cart.
enum EditingFileKind { image, pdf, office, unsupported }

class EditingFileRouter {
  static const images={'jpg','jpeg','png','webp','bmp','gif','heic','heif'};
  static const office={'doc','docx','xls','xlsx','odt','ods'};
  static String extension(String name){
    final clean=name.toLowerCase().split('?').first;
    final dot=clean.lastIndexOf('.');
    return dot<0?'':clean.substring(dot+1);
  }
  static EditingFileKind classify(String name){
    final ext=extension(name);
    if(images.contains(ext))return EditingFileKind.image;
    if(ext=='pdf')return EditingFileKind.pdf;
    if(office.contains(ext))return EditingFileKind.office;
    return EditingFileKind.unsupported;
  }
  static bool acceptsImageTool(String name)=>classify(name)==EditingFileKind.image;
  static bool acceptsPdfTool(String name)=>classify(name)!=EditingFileKind.unsupported;
}

/// A single API for current and future editing tools. JSON is persisted locally
/// with a replace-on-write file. Do not use the cart file as a draft.
class EditorSessionStore {
  EditorSessionStore._();
  static final instance=EditorSessionStore._();
  Future<File> _file(String tool,String id)async{
    final root=await getApplicationSupportDirectory();
    final dir=Directory('${root.path}${Platform.pathSeparator}editor_sessions');
    await dir.create(recursive:true);
    final safeTool=tool.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'),'_');
    final safeId=id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'),'_');
    return File('${dir.path}${Platform.pathSeparator}${safeTool}_${safeId}.json');
  }
  Future<void> save(String tool,String id,Map<String,dynamic> state)async{
    final file=await _file(tool,id);
    final temp=File('${file.path}.new');
    await temp.writeAsString(jsonEncode({
      'version':1,'tool':tool,'id':id,
      'updated':DateTime.now().toIso8601String(),
      'state':state,
    }),flush:true);
    final backup=File('${file.path}.bak');
    if(await backup.exists())await backup.delete();
    if(await file.exists())await file.rename(backup.path);
    try{
      await temp.rename(file.path);
      if(await backup.exists())await backup.delete();
    }catch(_){
      if(!await file.exists()&&await backup.exists()){
        await backup.rename(file.path);
      }
      rethrow;
    }
  }
  Future<Map<String,dynamic>?> load(String tool,String id)async{
    final file=await _file(tool,id);
    var source=file;
    if(!await source.exists()){
      source=File('${file.path}.bak');
      if(!await source.exists())return null;
    }
    try{
      final json=jsonDecode(await source.readAsString());
      if(json is! Map||json['version']!=1)return null;
      return Map<String,dynamic>.from(json['state'] as Map);
    }catch(_){return null;}
  }
  Future<void> delete(String tool,String id)async{
    final file=await _file(tool,id);
    for(final path in [file.path,'${file.path}.bak','${file.path}.new']){
      final current=File(path);
      if(await current.exists())await current.delete();
    }
  }
}

/// True only after staging succeeds. Navigates back to the existing single
/// dashboard/inbox instead of creating a second Cart UI or transferring files.
void returnToFileShareCart(BuildContext context){
  if(!context.mounted)return;
  Navigator.of(context).popUntil((route)=>route.isFirst);
}
