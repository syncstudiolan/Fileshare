import 'app_top_notice.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'file_share_text.dart';

class TextTransferCard extends StatefulWidget {
  const TextTransferCard({super.key,required this.readMessage,
    required this.onDelete,required this.incoming,
    required this.source,required this.created,required this.wrap,this.status});
  final Future<File> Function() readMessage;
  final Future<void> Function() onDelete;
  final bool incoming;
  final String source;
  final Widget Function(Widget content) wrap;
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
      if(mounted)FileShareTopNotice.show(context,'Text copied');
    }catch(e){
      if(mounted)FileShareTopNotice.show(context,'Copy failed: $e');
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
      if(mounted)FileShareTopNotice.show(context,'Could not open text: $e');
    }
  }
  @override Widget build(BuildContext context){
    final dark=Theme.of(context).brightness==Brightness.dark;
    final ink=widget.incoming?Colors.white:
      (dark?const Color(0xFFEAF9FC):const Color(0xFF0A5262));
    Widget action(String title,IconData icon,VoidCallback tap)=>
      Expanded(child:Container(
        height:34,
        decoration:BoxDecoration(
          gradient:LinearGradient(begin:Alignment.topLeft,
            end:Alignment.bottomRight,
            colors:widget.incoming
              ?const [Color(0xFF2B7954),Color(0xFF11452F)]
              :dark
                ?const [Color(0xFF245768),Color(0xFF103A47)]
                :const [Color(0xFFF0FCFF),Color(0xFFBCE8EC)]),
          borderRadius:BorderRadius.circular(17),
          boxShadow:[BoxShadow(color:Colors.black.withValues(alpha:.17),
            blurRadius:6,offset:const Offset(0,4))]),
        child:TextButton.icon(onPressed:tap,
          style:TextButton.styleFrom(
            padding:const EdgeInsets.symmetric(horizontal:4),
            foregroundColor:ink,
            shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(17))),
          icon:Icon(icon,size:17),
          label:FittedBox(fit:BoxFit.scaleDown,
            child:Text(title,style:const TextStyle(
              fontSize:12,fontWeight:FontWeight.w700))))));
    return widget.wrap(DefaultTextStyle.merge(
      style:TextStyle(color:widget.incoming?Colors.white:null),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Row(children:[
                CircleAvatar(radius:15,
                  backgroundColor:widget.incoming
                    ?Colors.white.withValues(alpha:.18):const Color(0xFF89EEE5),
                  child:Icon(widget.incoming?Icons.download_rounded
                    :Icons.send_rounded,
                    color:widget.incoming?Colors.white:const Color(0xFF087F87),
                    size:19)),
                const SizedBox(width:8),
                Expanded(child:Text(widget.source,maxLines:1,
                  overflow:TextOverflow.ellipsis,
                  style:const TextStyle(fontSize:13,fontWeight:FontWeight.w700))),
                Container(
                  padding:const EdgeInsets.symmetric(horizontal:9,vertical:5),
                  decoration:BoxDecoration(
                    color:const Color(0xFF009A9C).withValues(alpha:.10),
                    boxShadow:[BoxShadow(color:Colors.black.withValues(alpha:.12),
                      blurRadius:5,offset:const Offset(0,2))],
                    borderRadius:BorderRadius.circular(22)),
                  child:Row(mainAxisSize:MainAxisSize.min,children:[
                    Text('${widget.created.toLocal().hour.toString().padLeft(2,'0')}:'
                         '${widget.created.toLocal().minute.toString().padLeft(2,'0')}',
                      style:const TextStyle(fontSize:11,fontWeight:FontWeight.w700)),
                    if(widget.status!=null)...[
                      const SizedBox(width:4),widget.status!,
                    ],
                  ])),
              ]),
              const SizedBox(height:10),
              FutureBuilder<String>(future:_preview,builder:(context,snapshot)=>
                snapshot.hasError?const Text('Text not available yet')
                :!snapshot.hasData?const LinearProgressIndicator()
                :InkWell(onTap:_view,child:Text(snapshot.data!,
                    style:const TextStyle(fontSize:16)))),
              const SizedBox(height:8),
              Row(children:[
                action('Copy Text',Icons.copy_rounded,()=>unawaited(_copy())),
                const SizedBox(width:16),
                action('Delete Text',Icons.delete_outline_rounded,
                  ()=>unawaited(widget.onDelete())),
              ]),
            ])));
  }
}
