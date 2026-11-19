import 'dart:async';
import 'package:flutter/material.dart';

/// Show an app-owned notice under the top app header instead of a bottom
/// SnackBar that obscures the send cart, safe areas or editing controls.
class FileShareTopNotice {
  FileShareTopNotice._();
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(BuildContext context,String message,
      {Duration duration=const Duration(seconds:5)}) {
    final overlay=Overlay.maybeOf(context,rootOverlay:true);
    if(overlay==null)return;
    dismiss();
    final theme=Theme.of(context);
    final top=MediaQuery.paddingOf(context).top+72;
    _entry=OverlayEntry(builder:(ctx)=>Positioned(
      top:top,left:16,right:16,
      child:IgnorePointer(
        ignoring:true,
        child:Center(child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:540),
          child:Material(elevation:10,
            color:theme.colorScheme.inverseSurface,
            borderRadius:BorderRadius.circular(16),
            child:Padding(padding:const EdgeInsets.symmetric(
              horizontal:16,vertical:13),
              child:Row(mainAxisSize:MainAxisSize.min,children:[
                Icon(Icons.info_outline_rounded,
                  size:19,color:theme.colorScheme.onInverseSurface),
                const SizedBox(width:11),
                Flexible(child:Text(message,
                  style:TextStyle(color:theme.colorScheme.onInverseSurface,
                    fontSize:13,fontWeight:FontWeight.w500))),
              ])),
          )),
        )),
      ),
    );
    overlay.insert(_entry!);
    _timer=Timer(duration,dismiss);
  }

  static void dismiss(){
    _timer?.cancel();_timer=null;
    _entry?.remove();_entry=null;
  }
}
