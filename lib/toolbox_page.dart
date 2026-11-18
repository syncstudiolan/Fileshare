import 'dart:io';
import 'package:flutter/material.dart';
import 'image_editing_page.dart';
import 'package:flutter/services.dart';
import 'editor_transfer_session.dart';
import 'main.dart' show FileTheme,fadePage;

/// File Share's extensible Toolbox landing page. Future tool names remain
/// discoverable without pretending that their processing engines exist yet.
class FileShareToolboxPage extends StatefulWidget {
  const FileShareToolboxPage({super.key,this.sourcePath,this.sourceName});
  final String? sourcePath,sourceName;
  @override State<FileShareToolboxPage> createState()=>_FileShareToolboxPageState();
}

class _ToolEntry {
  const _ToolEntry(this.name,this.description,this.icon,
      {this.available=false,this.acceptsImages=false});
  final String name,description;
  final IconData icon;
  final bool available,acceptsImages;
}

const _entries=[
  _ToolEntry('Image Editing','Background removal, crop, filters, compression',
    Icons.photo_filter_outlined,available:true,acceptsImages:true),
  _ToolEntry('Signature Editing','Crop, clean and enhance handwritten signatures',
    Icons.draw_outlined),
  _ToolEntry('Advanced PDF Editing Tools','Android-only PDF processing, scanner, OCR and history',
    Icons.picture_as_pdf_outlined,available:true),
];

class _FileShareToolboxPageState extends State<FileShareToolboxPage> {
  final _search=TextEditingController();
  @override void initState(){super.initState();_search.addListener(_rebuild);}
  void _rebuild(){if(mounted)setState((){});}
  @override void dispose(){_search.removeListener(_rebuild);_search.dispose();super.dispose();}

  Future<void> _open(_ToolEntry entry) async {
    final name=widget.sourceName??widget.sourcePath??'';
    final hasSource=widget.sourcePath!=null;
    if(entry.name=='Advanced PDF Editing Tools'){
      if(!Platform.isAndroid){
        showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
          title:const Text('Only Available on Android'),
          content:const Text('These tools are only available on Android/mobile.'),
          actions:[TextButton(onPressed:()=>Navigator.pop(ctx),
            child:const Text('OK'))]));
        return;
      }
      if(hasSource&&!EditingFileRouter.acceptsPdfTool(name)){
        _unsupported(name,'Advanced PDF Editing Tools');
        return;
      }
      try {
        await const MethodChannel('file_share.native').invokeMethod<void>(
          'openUpstreamPdfTools', {'path': widget.sourcePath});
      } on PlatformException catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('PDF tools could not open: ${error.message ?? error.code}')));
      }
      return;
    }
    if(!entry.available){
      showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:Text(entry.name),
        content:const Text('This tool is planned for a future release.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),
          child:const Text('OK'))]));
      return;
    }
    if(entry.acceptsImages&&hasSource&&
       !EditingFileRouter.acceptsImageTool(name)){
      _unsupported(name,'Image Editing');
      return;
    }
    Navigator.of(context).push(fadePage<void>(ImageEditingPage(
      sourcePath:entry.acceptsImages?widget.sourcePath:null,
      sourceName:entry.acceptsImages?widget.sourceName:null,
    )));
  }
  void _unsupported(String file,String tool){
    showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('Incompatible file type'),
      content:Text('Cannot open $file in $tool. Videos do not convert to PDF.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),
        child:const Text('OK'))]));
  }

  @override Widget build(BuildContext context){
    final isDark=Theme.of(context).brightness==Brightness.dark;
    final width=MediaQuery.sizeOf(context).width;
    final wide=width>820;
    final query=_search.text.trim().toLowerCase();
    final visible=_entries.where((x)=>
      x.name.toLowerCase().contains(query) ||
      x.description.toLowerCase().contains(query)).toList();
    return Scaffold(
      appBar:AppBar(title:const Text('Toolbox')),
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:Center(child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:1150),
          child:CustomScrollView(slivers:[
            SliverPadding(padding:EdgeInsets.fromLTRB(wide?28:16,24,wide?28:16,10),
              sliver:SliverToBoxAdapter(child:Column(
                crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text('Choose a tool',style:Theme.of(context)
                    .textTheme.headlineSmall?.copyWith(fontWeight:FontWeight.w800)),
                  const SizedBox(height:6),
                  Text(widget.sourcePath==null
                    ?'Search all File Share tools'
                    :'Selected file: ${widget.sourceName??'Image'} · Choose how to edit',
                    maxLines:2,overflow:TextOverflow.ellipsis,
                    style:TextStyle(color:FileTheme.muted(context))),
                  const SizedBox(height:18),
                  TextField(controller:_search,
                    decoration:InputDecoration(
                      hintText:'Search tools...',
                      prefixIcon:const Icon(Icons.search_rounded),
                      suffixIcon:_search.text.isEmpty?null:IconButton(
                        tooltip:'Clear search',onPressed:_search.clear,
                        icon:const Icon(Icons.close_rounded)),
                      filled:true,
                      fillColor:isDark?const Color(0xFF242137):Colors.white,
                      border:OutlineInputBorder(
                        borderRadius:BorderRadius.circular(18),
                        borderSide:BorderSide(color:FileTheme.violet.withValues(alpha:.25))),
                    )),
                  const SizedBox(height:22),
                  Text('All tools',style:Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight:FontWeight.w700)),
                ]))),
            if(visible.isEmpty)
              const SliverFillRemaining(child:Center(child:Text('No matching tools')))
            else
              SliverPadding(padding:EdgeInsets.fromLTRB(wide?28:16,8,wide?28:16,30),
                sliver:SliverLayoutBuilder(builder:(context,constraints){
                  final columns=wide?3:width>=520?2:2;
                  return SliverGrid(
                    gridDelegate:SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount:columns,
                      crossAxisSpacing:12,mainAxisSpacing:12,
                      mainAxisExtent:wide?180:165),
                    delegate:SliverChildBuilderDelegate((context,index){
                      final entry=visible[index];
                      return Material(
                        color:isDark?const Color(0xFF211D32):Colors.white,
                        elevation:0,borderRadius:BorderRadius.circular(20),
                        child:InkWell(
                          key:ValueKey('tool-${entry.name}'),
                          borderRadius:BorderRadius.circular(20),
                          onTap:()=>_open(entry),
                          child:Container(
                            decoration:BoxDecoration(
                              borderRadius:BorderRadius.circular(20),
                              border:Border.all(color:entry.available
                                ?FileTheme.violet.withValues(alpha:.55)
                                :FileTheme.violet.withValues(alpha:.16))),
                            padding:const EdgeInsets.all(15),
                            child:Column(crossAxisAlignment:CrossAxisAlignment.start,
                              children:[
                                Container(padding:const EdgeInsets.all(10),
                                  decoration:BoxDecoration(
                                    color:FileTheme.violet.withValues(alpha:.15),
                                    borderRadius:BorderRadius.circular(14)),
                                  child:Icon(entry.icon,color:FileTheme.violet,size:27)),
                                const Spacer(),
                                Text(entry.name,maxLines:1,overflow:TextOverflow.ellipsis,
                                  style:const TextStyle(fontWeight:FontWeight.w800,fontSize:15)),
                                const SizedBox(height:4),
                                Text(entry.description,maxLines:2,overflow:TextOverflow.ellipsis,
                                  style:TextStyle(fontSize:11,
                                    color:FileTheme.muted(context))),
                                const SizedBox(height:6),
                                Align(alignment:Alignment.centerRight,
                                  child:Text(entry.available?'Open':'Coming soon',
                                    style:TextStyle(fontSize:11,fontWeight:FontWeight.w700,
                                      color:FileTheme.violet))),
                              ]),
                          ),
                        ),
                      );
                    },childCount:visible.length),
                  );
                })),
          ]),
        )),
      ),
    );
  }
}
