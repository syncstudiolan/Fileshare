import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional local-only profile photo. No cloud upload, account API, or
/// additional permission needed (Android photo picker / Windows file picker).
class FileShareProfileAvatar extends StatefulWidget {
  const FileShareProfileAvatar({super.key});
  @override State<FileShareProfileAvatar> createState()=>_FileShareProfileAvatarState();
}
class _FileShareProfileAvatarState extends State<FileShareProfileAvatar>{
  File? _photo;
  bool _busy=false;
  static const _key='file_share_profile_avatar_path';
  @override void initState(){super.initState();_restore();}
  Future<void> _restore()async{
    final saved=await SharedPreferencesAsync().getString(_key);
    if(saved==null)return;
    final file=File(saved);
    if(await file.exists()&&mounted)setState(()=>_photo=file);
  }
  Future<void> _pick()async{
    if(_busy)return;
    setState(()=>_busy=true);
    try{
      final selected=await ImagePicker().pickImage(source:ImageSource.gallery,
        maxWidth:512,maxHeight:512,imageQuality:85);
      if(selected==null)return;
      final root=await getApplicationSupportDirectory();
      final folder=Directory(root.path+Platform.pathSeparator+'profile');
      await folder.create(recursive:true);
      final name=selected.name.toLowerCase();
      final extension=name.endsWith('.png')?'.png':
        name.endsWith('.webp')?'.webp':'.jpg';
      final dest=File(folder.path+Platform.pathSeparator+
        'avatar'+extension);
      final bytes=await selected.readAsBytes();
      if(bytes.length>8*1024*1024)throw StateError('Photo is too large');
      await dest.writeAsBytes(bytes,flush:true);
      await SharedPreferencesAsync().setString(_key,dest.path);
      if(mounted)setState(()=>_photo=dest);
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('Profile picture could not be changed: $e')));
    }finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _remove()async{
    await SharedPreferencesAsync().remove(_key);
    if(mounted)setState(()=>_photo=null);
  }
  @override Widget build(BuildContext context)=>Column(children:[
    Stack(clipBehavior:Clip.none,children:[
      CircleAvatar(radius:37,
        backgroundColor:Theme.of(context).colorScheme.primaryContainer,
        foregroundImage:_photo!=null?FileImage(_photo!):null,
        child:_photo==null
          ?const Icon(Icons.person_outline,size:37):null),
      Positioned(right:-8,bottom:-3,child:IconButton.filledTonal(
        tooltip:'Change profile picture',onPressed:_busy?null:_pick,
        icon:_busy?const SizedBox(width:17,height:17,
          child:CircularProgressIndicator(strokeWidth:2)):
          const Icon(Icons.camera_alt_outlined,size:19))),
    ]),
    const SizedBox(height:7),
    TextButton.icon(onPressed:_busy?null:_pick,
      icon:const Icon(Icons.photo_library_outlined,size:17),
      label:const Text('Change photo')),
    if(_photo!=null)TextButton(
      onPressed:_busy?null:_remove,child:const Text('Remove photo')),
  ]);
}
