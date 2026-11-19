import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Gander's real DOCX rendering/pagination engine, adapted for Flutter.
///
/// The Gander document HTML/JS/CSS files run unchanged, except app.js resolves
/// its document URL to the private local endpoint and docx.html rewrites
/// asset paths. Includes Gander's Word page splitting, line-spacing fixes,
/// night mode and full-text search. No network upload or remote assets.
class GanderDocxPreviewPage extends StatefulWidget {
  const GanderDocxPreviewPage({super.key,required this.document,
    this.displayName});
  final File document;
  final String? displayName;
  @override State<GanderDocxPreviewPage> createState()=>
    _GanderDocxPreviewPageState();
}
class _GanderDocxPreviewPageState extends State<GanderDocxPreviewPage>{
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requests;
  WebViewEnvironment? _environment;
  InAppWebViewController? _controller;
  String? _url,_error;
  late final String _token;
  Uint8List? _docx;
  final _assets=<String,Uint8List>{};
  final _search=TextEditingController();
  int _page=0,_totalPages=0;
  bool _night=false;
  static const _files=[
    'docx.html','docx.js','docx-pages.js','docx-lines.js',
    'night.js','night.css','app.js','app.css','find.js'
  ];

  @override void initState(){
    super.initState();
    final random=Random.secure();
    _token=List<int>.generate(24,(_)=>random.nextInt(256))
      .map((v)=>v.toRadixString(16).padLeft(2,'0')).join();
    unawaited(_prepare());
  }
  Future<void> _prepare()async{
    try{
      if(!await widget.document.exists()){
        throw StateError('DOCX file not found');
      }
      if(await widget.document.length()>24*1024*1024){
        throw StateError('DOCX exceeds the 24 MB preview limit');
      }
      _docx=await widget.document.readAsBytes();
      for(final name in _files){
        final asset=await rootBundle.load('assets/gander/docx/'+name);
        _assets[name]=asset.buffer.asUint8List(
          asset.offsetInBytes,asset.lengthInBytes);
      }
      for(final name in ['jszip3.min.js','docx-preview.min.js']){
        final asset=await rootBundle.load('assets/gander/'+name);
        _assets[name]=asset.buffer.asUint8List(
          asset.offsetInBytes,asset.lengthInBytes);
      }
      if(Platform.isWindows){
        if(await WebViewEnvironment.getAvailableVersion()==null){
          throw StateError('Edge WebView2 Runtime is required for Word preview');
        }
        final root=await getApplicationSupportDirectory();
        final data=Directory(root.path+Platform.pathSeparator+
          'file_share_doc_webview2');
        await data.create(recursive:true);
        _environment=await WebViewEnvironment.create(
          settings:WebViewEnvironmentSettings(userDataFolder:data.path));
      }
      final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
      _server=server;
      _requests=server.listen(_handle,
        onError:(Object e){if(mounted)setState(()=>_error=e.toString());});
      if(mounted){
        final name=Uri.encodeComponent(widget.displayName??
          widget.document.uri.pathSegments.last);
        setState(()=>_url='http://127.0.0.1:'+server.port.toString()+
          '/'+_token+'/index?name='+name+'&ext=docx&night=0');
      }
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }
  static const _bridge=r'''(function(){
'use strict';
const channel=new MessageChannel();
channel.port1.onmessage=function(e){
  if(window.flutter_inappwebview && window.flutter_inappwebview.callHandler){
    window.flutter_inappwebview.callHandler('fileShareDocStatus',String(e.data));
  }
};
channel.port1.start();
window.postMessage('fileshare-doc-channel',location.origin,[channel.port2]);
window.fileShareDocCommand=function(command){
  channel.port1.postMessage(String(command));
};
})();''';

  Future<void> _handle(HttpRequest request)async{
    final response=request.response;
    response.headers.set('X-Content-Type-Options','nosniff');
    response.headers.set('Cache-Control','no-store');
    response.headers.set('Referrer-Policy','no-referrer');
    final parts=request.uri.pathSegments;
    if(request.method!='GET'||parts.length!=2||parts[0]!=_token){
      response.statusCode=HttpStatus.notFound;
      await response.close();return;
    }
    try{
      final name=parts[1];
      if(name=='index'){
        response.headers.contentType=ContentType.html;
        response.headers.set('Content-Security-Policy',
          "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; "+
          "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "+
          "font-src 'self' data: blob:; connect-src 'self'; "+
          "frame-src 'none'; worker-src 'none'; "+
          "object-src 'none'; form-action 'none'; base-uri 'none'");
        // The final bridge connects search/page events to Flutter controls.
        final page=utf8.decode(_assets['docx.html']!);
        response.write(page.replaceFirst(
          '</body>','<script src="bridge.js"></script></body>'));
      }else if(name=='document'){
        response.headers.contentType=ContentType.binary;
        response.add(_docx!);
      }else if(name=='bridge.js'){
        response.headers.contentType=ContentType('text','javascript');
        response.write(_bridge);
      }else if(_assets.containsKey(name)){
        response.headers.contentType=name.endsWith('.css')
          ?ContentType('text','css'):ContentType('text','javascript');
        response.add(_assets[name]!);
      }else response.statusCode=HttpStatus.notFound;
      await response.close();
    }catch(_){
      try{await response.close();}catch(_){}
    }
  }

  Future<void> _command(String command)async{
    final controller=_controller;
    if(controller==null)return;
    try{
      await controller.evaluateJavascript(
        source:'window.fileShareDocCommand?.('+jsonEncode(command)+');');
    }catch(_){}
  }
  void _onStatus(String message){
    if(!mounted)return;
    if(message.startsWith('page ')){
      final parts=message.split(' ');
      if(parts.length>=3){
        setState((){
          _page=int.tryParse(parts[1])??0;
          _totalPages=int.tryParse(parts[2])??0;
        });
      }
    }
  }
  @override void dispose(){
    _search.dispose();
    unawaited(_requests?.cancel());
    unawaited(_server?.close(force:true));
    super.dispose();
  }

  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(
      title:Text(widget.displayName??widget.document.uri.pathSegments.last),
      actions:[
        if(_totalPages>0)
          Center(child:Text('$_page / $_totalPages',
            style:Theme.of(context).textTheme.labelMedium)),
        IconButton(tooltip:'Previous search result',
          onPressed:()=>_command('p'),
          icon:const Icon(Icons.keyboard_arrow_up)),
        IconButton(tooltip:'Next search result',
          onPressed:()=>_command('n'),
          icon:const Icon(Icons.keyboard_arrow_down)),
        IconButton(tooltip:'Night mode',
          onPressed:(){
            setState(()=>_night=!_night);
            unawaited(_command(_night?'i1':'i0'));
          },
          icon:Icon(_night?Icons.light_mode_outlined:Icons.dark_mode_outlined)),
      ]),
    body:Column(children:[
      Padding(padding:const EdgeInsets.fromLTRB(10,5,10,7),
        child:TextField(
          controller:_search,
          onChanged:(value)=>unawaited(_command('q'+value)),
          decoration:InputDecoration(
            isDense:true,
            prefixIcon:const Icon(Icons.search_rounded),
            hintText:'Find in Word document',
            suffixIcon:IconButton(onPressed:(){
              _search.clear();unawaited(_command('c'));
            },icon:const Icon(Icons.close_rounded)),
            border:const OutlineInputBorder()))),
      Expanded(child:_error!=null
        ?Center(child:Text(_error!,textAlign:TextAlign.center))
        :_url==null
          ?const Center(child:CircularProgressIndicator())
          :InAppWebView(
              webViewEnvironment:_environment,
              initialUrlRequest:URLRequest(url:WebUri(_url!)),
              initialSettings:InAppWebViewSettings(
                javaScriptEnabled:true,
                useShouldOverrideUrlLoading:true,
                javaScriptCanOpenWindowsAutomatically:false,
                supportMultipleWindows:false,
                allowFileAccess:false,
                allowContentAccess:false,
                domStorageEnabled:false,cacheEnabled:false),
              onWebViewCreated:(controller){
                _controller=controller;
                controller.addJavaScriptHandler(
                  handlerName:'fileShareDocStatus',
                  callback:(args){
                    if(args.isNotEmpty)_onStatus(args.first.toString());
                    return null;
                  });
              },
              shouldOverrideUrlLoading:(controller,action)async{
                final target=action.request.url?.toString()??'';
                final root=_url!.substring(0,_url!.indexOf('/index')+1);
                return target.startsWith(root)
                  ?NavigationActionPolicy.ALLOW
                  :NavigationActionPolicy.CANCEL;
              },
            )),
    ]));
}
