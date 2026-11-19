import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Gander's own complete EPUB reader and CSS isolation engine, on Android
/// and Windows. Reads non-DRM EPUB without uploading it or opening web links.
class GanderEpubPreviewPage extends StatefulWidget {
  const GanderEpubPreviewPage({super.key,required this.document,this.name});
  final File document;
  final String? name;
  @override State<GanderEpubPreviewPage> createState()=>
    _GanderEpubPreviewPageState();
}
class _GanderEpubPreviewPageState extends State<GanderEpubPreviewPage>{
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requests;
  WebViewEnvironment? _env;
  InAppWebViewController? _controller;
  String? _url,_error;
  late final String _token;
  Uint8List? _book;
  final _assets=<String,Uint8List>{};
  final _search=TextEditingController();
  int _page=0,_totalPages=0;
  static const _files=['epub.html','epub.js','epub-css.js','epub.css'];

  @override void initState(){
    super.initState();
    final random=Random.secure();
    _token=List<int>.generate(24,(_)=>random.nextInt(256))
      .map((v)=>v.toRadixString(16).padLeft(2,'0')).join();
    unawaited(_prepare());
  }
  Future<void> _prepare()async{
    try{
      if(!await widget.document.exists())throw StateError('Book not found');
      if(await widget.document.length()>24*1024*1024){
        throw StateError('EPUB exceeds 24 MB reader memory limit');
      }
      _book=await widget.document.readAsBytes();
      for(final name in _files){
        final bytes=await rootBundle.load('assets/gander/epub/'+name);
        _assets[name]=bytes.buffer.asUint8List(
          bytes.offsetInBytes,bytes.lengthInBytes);
      }
      for(final name in ['app.js','app.css','find.js']){
        final bytes=await rootBundle.load('assets/gander/docx/'+name);
        _assets[name]=bytes.buffer.asUint8List(
          bytes.offsetInBytes,bytes.lengthInBytes);
      }
      for(final name in ['jszip3.min.js','purify.min.js']){
        final bytes=await rootBundle.load('assets/gander/'+name);
        _assets[name]=bytes.buffer.asUint8List(
          bytes.offsetInBytes,bytes.lengthInBytes);
      }
      if(Platform.isWindows){
        if(await WebViewEnvironment.getAvailableVersion()==null){
          throw StateError('Microsoft Edge WebView2 Runtime is required');
        }
        final root=await getApplicationSupportDirectory();
        final data=Directory(root.path+Platform.pathSeparator+
          'file_share_doc_webview2');
        await data.create(recursive:true);
        _env=await WebViewEnvironment.create(
          settings:WebViewEnvironmentSettings(userDataFolder:data.path));
      }
      final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
      _server=server;
      _requests=server.listen(_serve);
      if(mounted){
        setState(()=>_url='http://127.0.0.1:'+server.port.toString()+
          '/'+_token+'/index?ext=epub&name='+
          Uri.encodeComponent(widget.name??widget.document.uri.pathSegments.last));
      }
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }
  static const _bridge=r'''(function(){
  const channel=new MessageChannel();
  channel.port1.start();
  channel.port1.onmessage=function(event){
    if(window.flutter_inappwebview&&window.flutter_inappwebview.callHandler){
      window.flutter_inappwebview.callHandler('fileShareEpubStatus',String(event.data));
    }
  };
  window.postMessage('fileshare-epub-channel',location.origin,[channel.port2]);
  window.fileShareEpubCommand=function(s){channel.port1.postMessage(String(s));};
})();''';

  Future<void> _serve(HttpRequest request)async{
    final response=request.response;
    response.headers.set('Cache-Control','no-store');
    response.headers.set('X-Content-Type-Options','nosniff');
    final segments=request.uri.pathSegments;
    if(request.method!='GET'||segments.length!=2||segments[0]!=_token){
      response.statusCode=HttpStatus.notFound;
      await response.close();return;
    }
    try{
      final name=segments[1];
      if(name=='index'){
        response.headers.contentType=ContentType.html;
        response.headers.set('Content-Security-Policy',
          "default-src 'none'; script-src 'self'; "+
          "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "+
          "font-src 'self' data: blob:; connect-src 'self'; "+
          "frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'");
        response.write(utf8.decode(_assets['epub.html']!)
          .replaceFirst('</body>','<script src="bridge.js"></script></body>'));
      }else if(name=='document'){
        response.headers.contentType=ContentType('application','epub+zip');
        response.add(_book!);
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
    try{
      await _controller?.evaluateJavascript(source:
        'window.fileShareEpubCommand?.('+jsonEncode(command)+');');
    }catch(_){}
  }
  void _status(String msg){
    if(!mounted)return;
    if(msg.startsWith('page ')){
      final words=msg.split(' ');
      if(words.length>=3)setState((){
        _page=int.tryParse(words[1])??0;
        _totalPages=int.tryParse(words[2])??0;
      });
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
      title:Text(widget.name??widget.document.uri.pathSegments.last),
      actions:[
        if(_totalPages>0)
          Center(child:Text('$_page / $_totalPages')),
        IconButton(tooltip:'Previous match or chapter',
          onPressed:()=>_command('p'),
          icon:const Icon(Icons.keyboard_arrow_up)),
        IconButton(tooltip:'Next match or chapter',
          onPressed:()=>_command('n'),
          icon:const Icon(Icons.keyboard_arrow_down)),
      ]),
    body:Column(children:[
      Padding(padding:const EdgeInsets.all(8),
        child:TextField(controller:_search,
          onChanged:(v)=>unawaited(_command('q'+v)),
          decoration:InputDecoration(
            isDense:true,
            border:const OutlineInputBorder(),
            hintText:'Find in EPUB book',
            prefixIcon:const Icon(Icons.search),
            suffixIcon:IconButton(
              onPressed:(){_search.clear();unawaited(_command('c'));},
              icon:const Icon(Icons.close))))),
      Expanded(child:_error!=null?Center(child:Text(_error!)):
        _url==null?const Center(child:CircularProgressIndicator()):
        InAppWebView(
          webViewEnvironment:_env,
          initialUrlRequest:URLRequest(url:WebUri(_url!)),
          initialSettings:InAppWebViewSettings(
            javaScriptEnabled:true,useShouldOverrideUrlLoading:true,
            supportMultipleWindows:false,
            javaScriptCanOpenWindowsAutomatically:false,
            domStorageEnabled:false,cacheEnabled:false,
            allowFileAccess:false,allowContentAccess:false),
          onWebViewCreated:(controller){
            _controller=controller;
            controller.addJavaScriptHandler(
              handlerName:'fileShareEpubStatus',callback:(args){
                if(args.isNotEmpty)_status(args.first.toString());
                return null;
              });
          },
          shouldOverrideUrlLoading:(controller,action)async{
            final target=action.request.url?.toString()??'';
            final root=_url!.substring(0,_url!.indexOf('/index')+1);
            return target.startsWith(root)
              ?NavigationActionPolicy.ALLOW:NavigationActionPolicy.CANCEL;
          },
        )),
    ]));
}
