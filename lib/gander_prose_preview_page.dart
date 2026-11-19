import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Legacy Word .doc / OpenDocument .odt / RTF read-only renderer using
/// Gander's own original offline JavaScript readers and CSS.
class GanderProsePreviewPage extends StatefulWidget {
  const GanderProsePreviewPage({super.key,required this.document,this.name});
  final File document;
  final String? name;
  @override State<GanderProsePreviewPage> createState()=>
    _GanderProsePreviewPageState();
}
class _GanderProsePreviewPageState extends State<GanderProsePreviewPage>{
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _listener;
  WebViewEnvironment? _env;
  InAppWebViewController? _controller;
  final _assets=<String,Uint8List>{};
  Uint8List? _document;
  String? _url,_error;
  late final String _token;
  final _search=TextEditingController();
  static const _proseAssets=[
    'prose.html','prose.js','prose-doc.js','prose-rtf.js',
    'prose-odt.js','prose-draw.js','prose.css'
  ];
  @override void initState(){
    super.initState();
    final random=Random.secure();
    _token=List.generate(24,(_)=>random.nextInt(256))
      .map((n)=>n.toRadixString(16).padLeft(2,'0')).join();
    unawaited(_prepare());
  }
  Future<void> _prepare()async{
    try{
      if(!await widget.document.exists())throw StateError('Document not found');
      if(await widget.document.length()>24*1024*1024){
        throw StateError('Document exceeds 24 MB preview limit');
      }
      _document=await widget.document.readAsBytes();
      for(final name in _proseAssets){
        final bytes=await rootBundle.load('assets/gander/prose/'+name);
        _assets[name]=bytes.buffer.asUint8List(
          bytes.offsetInBytes,bytes.lengthInBytes);
      }
      for(final name in ['app.js','app.css','find.js','night.js','night.css']){
        final bytes=await rootBundle.load('assets/gander/docx/'+name);
        _assets[name]=bytes.buffer.asUint8List(
          bytes.offsetInBytes,bytes.lengthInBytes);
      }
      for(final path in {
        'symbol-fonts.js':'assets/gander/pptx/symbol-fonts.js',
        'jszip3.min.js':'assets/gander/jszip3.min.js'
      }.entries){
        final bytes=await rootBundle.load(path.value);
        _assets[path.key]=bytes.buffer.asUint8List(
          bytes.offsetInBytes,bytes.lengthInBytes);
      }
      if(Platform.isWindows){
        if(await WebViewEnvironment.getAvailableVersion()==null){
          throw StateError('WebView2 Runtime is required');
        }
        final root=await getApplicationSupportDirectory();
        final data=Directory(root.path+Platform.pathSeparator+
          'file_share_doc_webview2');
        await data.create(recursive:true);
        _env=await WebViewEnvironment.create(
          settings:WebViewEnvironmentSettings(userDataFolder:data.path));
      }
      final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
      _server=server;_listener=server.listen(_serve);
      if(mounted){
        final name=widget.name??widget.document.uri.pathSegments.last;
        final ext=name.toLowerCase().split('.').last;
        setState(()=>_url='http://127.0.0.1:'+server.port.toString()+
          '/'+_token+'/index?ext='+Uri.encodeComponent(ext)+
          '&name='+Uri.encodeComponent(name));
      }
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }
  static const _bridge=r'''(function(){
const channel=new MessageChannel();
channel.port1.start();
window.postMessage('fileshare-prose',location.origin,[channel.port2]);
window.fileShareProseCommand=function(value){
  channel.port1.postMessage(String(value));
};
})();''';
  Future<void> _serve(HttpRequest request)async{
    final response=request.response;
    response.headers.set('Cache-Control','no-store');
    response.headers.set('X-Content-Type-Options','nosniff');
    final p=request.uri.pathSegments;
    if(request.method!='GET'||p.length!=2||p[0]!=_token){
      response.statusCode=HttpStatus.notFound;
      await response.close();return;
    }
    try{
      final name=p[1];
      if(name=='index'){
        response.headers.contentType=ContentType.html;
        response.headers.set('Content-Security-Policy',
          "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "+
          "img-src 'self' data: blob:; font-src 'self' data: blob:; "+
          "connect-src 'self'; frame-src 'none'; object-src 'none'; "+
          "form-action 'none'; base-uri 'none'");
        response.write(utf8.decode(_assets['prose.html']!)
          .replaceFirst('</body>','<script src="bridge.js"></script></body>'));
      }else if(name=='document'){
        response.headers.contentType=ContentType.binary;
        response.add(_document!);
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
  Future<void> _command(String value)async{
    try{
      await _controller?.evaluateJavascript(source:
        'window.fileShareProseCommand?.('+jsonEncode(value)+');');
    }catch(_){}
  }
  @override void dispose(){
    _search.dispose();unawaited(_listener?.cancel());
    unawaited(_server?.close(force:true));super.dispose();
  }
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text(widget.name??widget.document.uri.pathSegments.last)),
    body:Column(children:[
      Padding(padding:const EdgeInsets.all(8),child:TextField(
        controller:_search,
        onChanged:(v)=>unawaited(_command('q'+v)),
        decoration:InputDecoration(
          isDense:true,border:const OutlineInputBorder(),
          hintText:'Find in document',
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
          onWebViewCreated:(controller)=>_controller=controller,
          shouldOverrideUrlLoading:(controller,action)async{
            final target=action.request.url?.toString()??'';
            final root=_url!.substring(0,_url!.indexOf('/index')+1);
            return target.startsWith(root)
              ?NavigationActionPolicy.ALLOW:NavigationActionPolicy.CANCEL;
          },
        )),
    ]));
}
