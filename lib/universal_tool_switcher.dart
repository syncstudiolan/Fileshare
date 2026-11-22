import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'image_editing_page.dart';
import 'signature_edit_page.dart';
import 'file_share_doc_page.dart';
import 'id_card_pdf_engine.dart';

/// One compact action in every editor's top bar. Existing toolbar actions
/// retain their positions. The origin editor stays in the Navigator stack so
/// Back restores its draft rather than opening a second dashboard.
enum EditorDestination { image,signature,pdf,document }

class ToolSwitchButton extends StatelessWidget {
  const ToolSwitchButton({super.key,required this.current,
    required this.snapshot, this.enabled=true, this.onError});
  final EditorDestination current;
  final Future<File> Function(EditorDestination target) snapshot;
  final bool enabled;
  final ValueChanged<String>? onError;

  static const _labels={
    EditorDestination.image:'Image Editing',
    EditorDestination.signature:'Signature Editing',
    EditorDestination.pdf:'Advanced PDF Pro',
    EditorDestination.document:'File Share Doc',
  };
  static const _icons={
    EditorDestination.image:Icons.image_outlined,
    EditorDestination.signature:Icons.draw_outlined,
    EditorDestination.pdf:Icons.picture_as_pdf_outlined,
    EditorDestination.document:Icons.description_outlined,
  };

  Future<void> _choose(BuildContext context)async{
    if(!enabled)return;
    final target=await showModalBottomSheet<EditorDestination>(
      context:context,isScrollControlled:true,
      showDragHandle:true,
      builder:(dialog)=>SafeArea(child:Padding(
        padding:const EdgeInsets.fromLTRB(16,0,16,14),
        child:Column(mainAxisSize:MainAxisSize.min,children:[
          const Text('Switch Editing Tool',
            style:TextStyle(fontWeight:FontWeight.w700,fontSize:17)),
          const SizedBox(height:5),
          const Text('Current edits will be copied to the next tool. '
            'Your original and this editor draft stay available.',
            textAlign:TextAlign.center),
          const SizedBox(height:12),
          for(final entry in EditorDestination.values)
            if(entry!=current)
              ListTile(
                contentPadding:const EdgeInsets.symmetric(horizontal:10),
                leading:Icon(_icons[entry],size:21),
                title:Text(_labels[entry]!),
                trailing:const Icon(Icons.chevron_right_rounded),
                onTap:()=>Navigator.pop(dialog,entry)),
        ]))));
    if(target==null||!context.mounted)return;
    // Never flatten Word formatting or silently reinterpret PDF pages as
    // office files. Unsupported destinations are disabled with clear feedback.
    if((target==EditorDestination.document && current!=EditorDestination.document) ||
       (current==EditorDestination.document && target!=EditorDestination.pdf)){
      _feedback(context,'A document conversion is not supported in this direction.');
      return;
    }
    if(target==EditorDestination.pdf&&!Platform.isAndroid){
      _feedback(context,'Advanced PDF Pro is currently available on Android only.');
      return;
    }
    try{
      final file=await snapshot(target);
      if(!context.mounted)return;
      final name=file.uri.pathSegments.last;
      if(target==EditorDestination.pdf){
        var path=file.path;
        if(!name.toLowerCase().endsWith('.pdf')){
          final pdf=await IdCardPdfEngine.normalPdf([await file.readAsBytes()]);
          final cache=await getTemporaryDirectory();
          final output=File('${cache.path}${Platform.pathSeparator}'
            'switch_${DateTime.now().microsecondsSinceEpoch}.pdf');
          await output.writeAsBytes(pdf,flush:true);
          path=output.path;
        }
        await const MethodChannel('file_share.native')
          .invokeMethod<void>('openUpstreamPdfTools',{
            'path':path,
            'theme':Theme.of(context).brightness==Brightness.dark?'dark':'light',
          });
        return;
      }
      final next=switch(target){
        EditorDestination.image=>ImageEditingPage(
          sourcePath:file.path,sourceName:name),
        EditorDestination.signature=>SignatureEditPage(
          sourcePath:file.path,sourceName:name),
        EditorDestination.document=>FileShareDocPage(
          sourcePath:file.path,sourceName:name),
        EditorDestination.pdf=>throw StateError('PDF handled natively'),
      };
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder:(_)=>next));
    }catch(error){
      if(error is StateError && error.message=='Conversion canceled')return;
      if(context.mounted)_feedback(context,'Tool switch failed: $error');
    }
  }

  void _feedback(BuildContext context,String text){
    onError?.call(text);
    if(onError==null&&context.mounted){
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text(text)));
    }
  }

  @override
  Widget build(BuildContext context)=>IconButton(
    tooltip:'Switch editing tool',visualDensity:VisualDensity.compact,
    constraints:const BoxConstraints(minWidth:40,minHeight:40),
    onPressed:enabled?()=>_choose(context):null,
    icon:const Icon(Icons.swap_horiz_rounded,size:21));
}

/// Immutable snapshot in private cache; no change to the input or draft.
Future<File> editorSnapshotFile(Uint8List bytes,{String suffix='png'})async{
  final cache=await getTemporaryDirectory();
  final folder=Directory('${cache.path}${Platform.pathSeparator}editor_switch');
  await folder.create(recursive:true);
  final name='edit_${DateTime.now().microsecondsSinceEpoch}.$suffix';
  final file=File('${folder.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes,flush:true);
  return file;
}
