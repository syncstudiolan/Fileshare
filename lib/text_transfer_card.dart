import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'file_share_text.dart';

class TextTransferCard extends StatefulWidget {
  const TextTransferCard({super.key,required this.readMessage,
    required this.onDelete,required this.incoming,
    required this.source,required this.created,this.status});
  final Future<File> Function() readMessage;
  final Future<void> Function() onDelete;
  final bool incoming;
  final String source;
  final DateTime created;
  final Widget? status;
  @override State<TextTransferCard> createState()=>_TextTransferCardState();
}
class _TextTransferCardState extends State<TextTransferCard> {
  late final Future<String> _preview=_loadPreview();
  Future<String> _loadPreview()async=>
    FileShareText.preview(await widget.readMessage());
  Future<void> _copy()async{
    try{
      final message=await (await widget.readMessage()).readAsString();
      await Clipboard.setData(ClipboardData(text:message));
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content:Text('Text copied')));
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('Copy failed: $e')));
    }
  }
  Future<void> _view()async{
    try{
      final message=await (await widget.readMessage()).readAsString();
      if(!mounted)return;
      await showDialog<void>(context:context,builder:(dialog)=>AlertDialog(
        title:const Text('Text message'),
        content:SizedBox(width:550,child:SingleChildScrollView(
          child:SelectableText(message))),
        actions:[TextButton(onPressed:()=>Navigator.pop(dialog),
          child:const Text('Close'))]));
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('Could not open text: $e')));
    }
  }
  @override Widget build(BuildContext context){
    final scheme=Theme.of(context).colorScheme;
    return Align(alignment:widget.incoming?Alignment.centerLeft:Alignment.centerRight,
      child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:510),
        child:Card(color:widget.incoming?scheme.surfaceContainer:scheme.primaryContainer,
          shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(20)),
          child:Padding(padding:const EdgeInsets.all(14),
            child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Row(children:[
                const Icon(Icons.chat_bubble_outline,size:19),
                const SizedBox(width:8),
                Expanded(child:Text(widget.source,maxLines:1,
                  overflow:TextOverflow.ellipsis,
                  style:const TextStyle(fontSize:12,fontWeight:FontWeight.bold))),
              ]),
              const SizedBox(height:10),
              FutureBuilder<String>(future:_preview,builder:(context,snapshot)=>
                snapshot.hasError?const Text('Text not available yet')
                :!snapshot.hasData?const LinearProgressIndicator()
                :InkWell(onTap:_view,child:Text(snapshot.data!,
                    style:const TextStyle(fontSize:14)))),
              const SizedBox(height:8),
              Row(mainAxisAlignment:MainAxisAlignment.end,children:[
                TextButton.icon(onPressed:()=>unawaited(_copy()),
                  icon:const Icon(Icons.copy,size:16),
                  label:const Text('Copy Text')),
                TextButton.icon(onPressed:()=>unawaited(widget.onDelete()),
                  icon:const Icon(Icons.delete_outline,size:16),
                  label:const Text('Delete Text')),
              ]),
              Align(alignment:Alignment.centerRight,
                child:Row(mainAxisSize:MainAxisSize.min,children:[
                  Text('${widget.created.toLocal().hour.toString().padLeft(2,'0')}:'+
                       widget.created.toLocal().minute.toString().padLeft(2,'0'),
                    style:const TextStyle(fontSize:10)),
                  if(widget.status!=null)...[
                    const SizedBox(width:4),widget.status!,
                  ]
                ])),
            ])),
        )),
    );
  }
}
