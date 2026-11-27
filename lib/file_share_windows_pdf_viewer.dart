import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Windows-only embedded PDF reading using the system's Edge WebView2 PDF
/// renderer. It is intentionally NOT a PDF editor on Windows.
/// Read-only content is supplied over a private loopback origin.
class FileShareWindowsPdfViewer extends StatefulWidget {
  const FileShareWindowsPdfViewer({super.key,required this.file,this.name});
  final File file;
  final String? name;
  @override State<FileShareWindowsPdfViewer> createState()=>
    _FileShareWindowsPdfViewerState();
}
class _FileShareWindowsPdfViewerState extends State<FileShareWindowsPdfViewer>{
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requests;
  WebViewEnvironment? _env;
  String? _url,_error;
  late final String _token;
  @override void initState(){
    super.initState();
    final random=Random.secure();
    _token=List.generate(24,(_)=>random.nextInt(256))
      .map((v)=>v.toRadixString(16).padLeft(2,'0')).join();
    unawaited(_initialize());
  }
  Future<void> _initialize()async{
    try{
      if(!Platform.isWindows)throw UnsupportedError('Windows only');
      if(!await widget.file.exists())throw StateError('PDF file missing');
      if(await WebViewEnvironment.getAvailableVersion()==null){
        throw StateError('Microsoft Edge WebView2 Runtime is required');
      }
      final root=await getApplicationSupportDirectory();
      final user=Directory(root.path+Platform.pathSeparator+
        'file_share_doc_webview2');
      await user.create(recursive:true);
      _env=await WebViewEnvironment.create(
        settings:WebViewEnvironmentSettings(userDataFolder:user.path));
      final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
      _server=server;
      _requests=server.listen(_serve);
      if(mounted)setState(()=>_url='http://127.0.0.1:'+
        server.port.toString()+'/'+_token+'/document.pdf');
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }
  Future<void> _serve(HttpRequest request)async{
    final response=request.response;
    response.headers.set('X-Content-Type-Options','nosniff');
    response.headers.set('Cache-Control','no-store');
    final parts=request.uri.pathSegments;
    if(request.method!='GET'||parts.length!=2||
       parts[0]!=_token||parts[1]!='document.pdf'){
      response.statusCode=HttpStatus.notFound;
      await response.close();return;
    }
    try{
      final size=await widget.file.length();
      final range=request.headers.value(HttpHeaders.rangeHeader);
      final match=range==null?null:
        RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      var start=0,end=size-1;
      if(match!=null){
        start=int.parse(match.group(1)!);
        final explicit=match.group(2);
        if(explicit!=null&&explicit.isNotEmpty){
          end=min(size-1,int.parse(explicit));
        }
        if(start>=size||end<start){
          response.statusCode=HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set('Content-Range','bytes */'+size.toString());
          await response.close();return;
        }
        response.statusCode=HttpStatus.partialContent;
        response.headers.set('Content-Range',
          'bytes '+start.toString()+'-'+end.toString()+'/'+size.toString());
      }else if(range!=null){
        response.statusCode=HttpStatus.requestedRangeNotSatisfiable;
        await response.close();return;
      }
      response.headers.contentType=ContentType('application','pdf');
      response.headers.set('Accept-Ranges','bytes');
      response.contentLength=end-start+1;
      await response.addStream(widget.file.openRead(start,end+1));
      await response.close();
    }catch(_){
      try{await response.close();}catch(_){}
    }
  }
  @override void dispose(){
    unawaited(_requests?.cancel());
    unawaited(_server?.close(force:true));
    super.dispose();
  }
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text(widget.name??widget.file.uri.pathSegments.last)),
    body:_error!=null?Center(child:Text(_error!)):
      _url==null?const Center(child:CircularProgressIndicator()):
      InAppWebView(
        webViewEnvironment:_env,
        initialUrlRequest:URLRequest(url:WebUri(_url!)),
        initialSettings:InAppWebViewSettings(
          javaScriptEnabled:false,
          useShouldOverrideUrlLoading:true,
          supportMultipleWindows:false,
          javaScriptCanOpenWindowsAutomatically:false,
          allowFileAccess:false,allowContentAccess:false),
        shouldOverrideUrlLoading:(controller,action)async{
          return action.request.url?.toString()==_url
            ?NavigationActionPolicy.ALLOW:NavigationActionPolicy.CANCEL;
        },
      ),
  );
}
