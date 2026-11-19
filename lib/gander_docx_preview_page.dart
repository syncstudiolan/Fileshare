import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Offline Gander-vendored DOCX preview using JSZip + docx-preview.
///
/// Uses a private random-capability, loopback-only HTTP server instead of
/// WebView2 NavigateToString: Windows limits navigate-to-string size to 2MB.
/// All scripts and documents are served locally; the viewer never requests a
/// remote URL. An unguessable per-session path prevents unrelated local
/// processes from casually fetching the document.
class GanderDocxPreviewPage extends StatefulWidget {
  const GanderDocxPreviewPage({super.key,required this.document});
  final File document;
  @override
  State<GanderDocxPreviewPage> createState()=>_GanderDocxPreviewPageState();
}

class _GanderDocxPreviewPageState extends State<GanderDocxPreviewPage>{
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requests;
  WebViewEnvironment? _webViewEnvironment;
  String? _url;
  String? _error;
  late final String _token;
  Uint8List? _zip;
  Uint8List? _docxLib;
  Uint8List? _jszipLib;

  @override
  void initState(){
    super.initState();
    final random=Random.secure();
    _token=List<int>.generate(24,(_)=>random.nextInt(256))
      .map((n)=>n.toRadixString(16).padLeft(2,'0')).join();
    unawaited(_prepare());
  }
  @override
  void dispose(){
    unawaited(_requests?.cancel());
    unawaited(_server?.close(force:true));
    super.dispose();
  }
  Future<void> _prepare()async{
    try{
      if(!await widget.document.exists()){
        throw StateError('Document unavailable');
      }
      final length=await widget.document.length();
      if(length>20*1024*1024){
        throw StateError('DOCX viewer supports documents up to 20 MB');
      }
      final libs=await Future.wait([
        rootBundle.load('assets/gander/jszip3.min.js'),
        rootBundle.load('assets/gander/docx-preview.min.js'),
      ]);
      _jszipLib=libs[0].buffer.asUint8List(
        libs[0].offsetInBytes,libs[0].lengthInBytes);
      _docxLib=libs[1].buffer.asUint8List(
        libs[1].offsetInBytes,libs[1].lengthInBytes);
      _zip=await widget.document.readAsBytes();
      if(Platform.isWindows){
        final version=await WebViewEnvironment.getAvailableVersion();
        if(version==null){
          throw StateError('Microsoft Edge WebView2 Runtime is required');
        }
        final root=await getApplicationSupportDirectory();
        final data=Directory(root.path+
          Platform.pathSeparator+'file_share_doc_webview2');
        await data.create(recursive:true);
        _webViewEnvironment=await WebViewEnvironment.create(
          settings:WebViewEnvironmentSettings(userDataFolder:data.path));
      }
      final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
      _server=server;
      _requests=server.listen(_serveRequest,
        onError:(Object error){if(mounted)setState(()=>_error=error.toString());});
      if(mounted){
        setState(()=>_url='http://127.0.0.1:'+server.port.toString()+
          '/'+_token+'/index');
      }
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }

  static const _page=r'''<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>File Share Doc — Word preview</title>
<style>
html,body{margin:0;background:#eee;font-family:system-ui,sans-serif}
#status{padding:15px;text-align:center;color:#444}
.docx-wrapper{padding:12px !important;background:#eee !important}
.docx-wrapper>section.docx{box-shadow:0 2px 10px #0003;max-width:100%}
@media(prefers-color-scheme:dark){
html,body{background:#181622}
#status{color:#f5f5f5}
.docx-wrapper{background:#181622 !important}}
</style>
<script src="jszip.js" defer></script>
<script src="docx.js" defer></script>
<script src="bootstrap.js" defer></script>
</head><body>
<div id="status">Rendering Word document…</div>
<div id="document"></div>
</body></html>''';

  static const _bootstrap=r'''(async function(){
  try {
    // Same sandbox-first defense for altChunk as Gander's docx.js.
    const create=document.createElement.bind(document);
    document.createElement=function(name,options){
      const element=create(name,options);
      if(String(name).toLowerCase()==='iframe')element.setAttribute('sandbox','');
      return element;
    };
    const response=await fetch('document',{credentials:'omit',cache:'no-store'});
    if(!response.ok)throw new Error('Document request failed');
    const bytes=await response.arrayBuffer();
    await docx.renderAsync(bytes,document.getElementById('document'),null,{
      breakPages:true,
      renderHeadersFooters:true,
      inWrapper:true,
      experimental:true,
      useBase64URL:true,
      ignoreLastRenderedPageBreak:false
    });
    document.querySelectorAll('iframe').forEach(el=>el.remove());
    document.querySelectorAll('a[href]').forEach(el=>el.removeAttribute('href'));
    document.getElementById('status').remove();
  } catch(error) {
    document.getElementById('status').textContent='Could not show DOCX: '+String(error);
  }
})();''';

  Future<void> _serveRequest(HttpRequest request)async{
    final response=request.response;
    response.headers.set('X-Content-Type-Options','nosniff');
    response.headers.set('Cache-Control','no-store');
    response.headers.set('Access-Control-Allow-Origin','null');
    final path=request.uri.pathSegments;
    if(request.method!='GET'||path.length!=2||path[0]!=_token){
      response.statusCode=HttpStatus.notFound;
      await response.close();
      return;
    }
    try{
      final name=path[1];
      switch(name){
        case 'index':
          response.headers.contentType=ContentType.html;
          response.headers.set('Content-Security-Policy',
            "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "+
            "img-src data: blob:; font-src data: blob:; connect-src 'self'; "+
            "frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'");
          response.write(_page);
        case 'jszip.js':
          response.headers.contentType=ContentType('text','javascript');
          response.add(_jszipLib!);
        case 'docx.js':
          response.headers.contentType=ContentType('text','javascript');
          response.add(_docxLib!);
        case 'bootstrap.js':
          response.headers.contentType=ContentType('text','javascript');
          response.write(_bootstrap);
        case 'document':
          response.headers.contentType=ContentType(
            'application','vnd.openxmlformats-officedocument.wordprocessingml.document');
          response.add(_zip!);
        default:
          response.statusCode=HttpStatus.notFound;
      }
      await response.close();
    }catch(_){
      try{await response.close();}catch(_){}
    }
  }
  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text(widget.document.uri.pathSegments.last),
      actions:[
        IconButton(icon:const Icon(Icons.info_outline),
          tooltip:'Viewer limitations',
          onPressed:()=>showDialog<void>(context:context,builder:(dialog)=>
            AlertDialog(title:const Text('Gander-based DOCX preview'),
              content:const Text('This is an offline document viewer using '
                'Gander-vendored docx-preview and JSZip. It is read-only; '
                'edit text in File Share Doc and save a new DOCX copy. '
                'Complex pagination and font metrics may differ from Word.'),
              actions:[TextButton(onPressed:()=>Navigator.pop(dialog),
                child:const Text('Close'))])))
      ]),
    body:_error!=null?Center(child:Padding(padding:const EdgeInsets.all(18),
      child:Text(_error!,textAlign:TextAlign.center))):
      _url==null?const Center(child:CircularProgressIndicator()):
      InAppWebView(
        webViewEnvironment:_webViewEnvironment,
        initialUrlRequest:URLRequest(url:WebUri(_url!)),
        initialSettings:InAppWebViewSettings(
          javaScriptEnabled:true,
          useShouldOverrideUrlLoading:true,
          javaScriptCanOpenWindowsAutomatically:false,
          supportMultipleWindows:false,
          allowFileAccess:false,
          allowContentAccess:false,
          allowFileAccessFromFileURLs:false,
          allowUniversalAccessFromFileURLs:false,
          domStorageEnabled:false,
          cacheEnabled:false,
          transparentBackground:false,
        ),
        shouldOverrideUrlLoading:(controller,action)async{
          final target=action.request.url?.toString()??'';
          final base=_url?.substring(0,_url!.lastIndexOf('/'))??'';
          return target.startsWith(base+'/')
            ?NavigationActionPolicy.ALLOW:NavigationActionPolicy.CANCEL;
        },
      ),
  );
}
