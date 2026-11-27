import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Offline Gander/PPTXjs read-only presentation viewer for Android & Windows.
/// Retains its original PPTX handling fixes and charts where supported.
/// The editing workspace saves slide text through FileShareDocEngine separately.
class GanderPresentationPreviewPage extends StatefulWidget {
  const GanderPresentationPreviewPage({super.key,required this.document});
  final File document;
  @override State<GanderPresentationPreviewPage> createState()=>
    _GanderPresentationPreviewPageState();
}
class _GanderPresentationPreviewPageState
    extends State<GanderPresentationPreviewPage>{
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  WebViewEnvironment? _environment;
  String? _url,_error;
  Uint8List? _presentation;
  final _assets=<String,Uint8List>{};
  late final String _token;

  static const _assetsToLoad=[
    'jquery.min.js','jszip2.min.js','filereader.js','d3.min.js',
    'nv.d3.min.js','pptxjs.js','divs2slides.js','symbol-fonts.js',
    'gander-pptx.js','pptxjs.css','nv.d3.min.css',
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
      if(!await widget.document.exists())throw StateError('File unavailable');
      if(await widget.document.length()>24*1024*1024){
        throw StateError('PowerPoint preview is limited to 24 MB files');
      }
      _presentation=await widget.document.readAsBytes();
      for(final name in _assetsToLoad){
        final data=await rootBundle.load('assets/gander/pptx/'+name);
        _assets[name]=data.buffer.asUint8List(
          data.offsetInBytes,data.lengthInBytes);
      }
      if(Platform.isWindows){
        if(await WebViewEnvironment.getAvailableVersion()==null){
          throw StateError('Microsoft Edge WebView2 Runtime is required');
        }
        final root=await getApplicationSupportDirectory();
        final folder=Directory(root.path+Platform.pathSeparator+
          'file_share_doc_webview2');
        await folder.create(recursive:true);
        _environment=await WebViewEnvironment.create(
          settings:WebViewEnvironmentSettings(userDataFolder:folder.path));
      }
      final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
      _server=server;
      _subscription=server.listen(_handle);
      if(mounted){
        setState(()=>_url='http://127.0.0.1:'+server.port.toString()+
          '/'+_token+'/index');
      }
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }

  static const _html=r'''<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Offline PowerPoint preview</title>
<link rel="stylesheet" href="pptxjs.css">
<link rel="stylesheet" href="nv.d3.min.css">
<style>
:root{color-scheme:light dark;font-family:system-ui,sans-serif}
html,body{margin:0;background:#26213b;color:#f0eef5}
#status{padding:15px;text-align:center}
#result{padding:12px;min-height:calc(100vh - 50px);
display:flex;flex-direction:column;align-items:center}
#result>.slides{width:100%;height:auto !important}
#result .slide{margin:12px auto;box-shadow:0 2px 12px #0007;background:#fff}
#result .text-block{white-space:pre-wrap}
#result svg.drawing{min-width:1px;min-height:1px}
#result .vw-missing{width:100%;height:100%;box-sizing:border-box;
background:#f5eee9;color:#584b40;border:2px dashed #b3aba5;padding:6px}
</style>
<script src="jquery.min.js" defer></script>
<script src="jszip2.min.js" defer></script>
<script src="filereader.js" defer></script>
<script src="d3.min.js" defer></script>
<script src="nv.d3.min.js" defer></script>
<script src="pptxjs.js" defer></script>
<script src="divs2slides.js" defer></script>
<script src="symbol-fonts.js" defer></script>
<script src="bridge.js" defer></script>
<script src="gander-pptx.js" defer></script>
</head><body>
<div id="status" role="status">Rendering presentation…</div>
<div id="result"></div>
</body></html>''';

  // Gander's pptx.js expects the app's status/error/navigation helpers.
  // The document remains inside this WebView with external links disabled.
  static const _bridge=r'''function vwError(title,detail) {
  const box=document.getElementById('status');
  if(box)box.textContent=title+' — '+detail;
}
function vwFitHeight() {}
function vwStatusDone() {
  const box=document.getElementById('status');
  if(box)box.remove();
}
function vwDisarmLinks(root){
  root.querySelectorAll('a[href]').forEach(a=>a.removeAttribute('href'));
  root.querySelectorAll('iframe').forEach(f=>f.remove());
}
window.addEventListener('error',e=>vwError('Presentation error',e.message));
''';

  Future<void> _handle(HttpRequest request)async{
    final response=request.response;
    response.headers.set('X-Content-Type-Options','nosniff');
    response.headers.set('Cache-Control','no-store');
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
          "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "+
          "connect-src 'self'; img-src data: blob:; font-src data: blob:; "+
          "frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'");
        response.write(_html);
      }else if(name=='bridge.js'){
        response.headers.contentType=ContentType('text','javascript');
        response.write(_bridge);
      }else if(name=='document'){
        response.headers.contentType=ContentType.binary;
        response.add(_presentation!);
      }else if(_assets.containsKey(name)){
        response.headers.contentType=name.endsWith('.css')
          ?ContentType('text','css'):ContentType('text','javascript');
        response.add(_assets[name]!);
      }else{
        response.statusCode=HttpStatus.notFound;
      }
      await response.close();
    }catch(_){
      try{await response.close();}catch(_){}
    }
  }

  @override void dispose(){
    unawaited(_subscription?.cancel());
    unawaited(_server?.close(force:true));
    super.dispose();
  }

  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text(widget.document.uri.pathSegments.last)),
    body:_error!=null?Center(child:Text(_error!)):
      _url==null?const Center(child:CircularProgressIndicator()):
      InAppWebView(
        webViewEnvironment:_environment,
        initialUrlRequest:URLRequest(url:WebUri(_url!)),
        initialSettings:InAppWebViewSettings(
          javaScriptEnabled:true,
          useShouldOverrideUrlLoading:true,
          javaScriptCanOpenWindowsAutomatically:false,
          supportMultipleWindows:false,
          domStorageEnabled:false,
          cacheEnabled:false,
          allowFileAccess:false,
          allowContentAccess:false,
        ),
        shouldOverrideUrlLoading:(controller,action)async{
          final target=action.request.url?.toString()??'';
          final start=_url!.substring(0,_url!.lastIndexOf('/')+1);
          return target.startsWith(start)
            ?NavigationActionPolicy.ALLOW:NavigationActionPolicy.CANCEL;
        },
      ),
  );
}
