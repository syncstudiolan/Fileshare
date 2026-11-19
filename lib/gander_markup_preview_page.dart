import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Offline HTML/Markdown preview with Gander-vendored marked + DOMPurify.
/// Content is sanitized, remote resources and navigation are blocked.
class GanderMarkupPreviewPage extends StatefulWidget {
  const GanderMarkupPreviewPage({super.key,required this.document});
  final File document;
  @override
  State<GanderMarkupPreviewPage> createState()=>_GanderMarkupPreviewPageState();
}
class _GanderMarkupPreviewPageState extends State<GanderMarkupPreviewPage>{
  String? _html,_error;
  WebViewEnvironment? _environment;
  @override
  void initState(){super.initState();_prepare();}
  Future<void> _prepare()async{
    try{
      if(await widget.document.length()>650000){
        throw StateError('Safe inline preview supports text under 650 KB');
      }
      final text=await widget.document.readAsString();
      final libraries=await Future.wait([
        rootBundle.loadString('assets/gander/marked.umd.js'),
        rootBundle.loadString('assets/gander/purify.min.js')
      ]);
      if(Platform.isWindows){
        final version=await WebViewEnvironment.getAvailableVersion();
        if(version==null)throw StateError('WebView2 Runtime is required');
        final root=await getApplicationSupportDirectory();
        final folder=Directory(root.path+Platform.pathSeparator+
          'file_share_doc_webview2');
        await folder.create(recursive:true);
        _environment=await WebViewEnvironment.create(settings:
          WebViewEnvironmentSettings(userDataFolder:folder.path));
      }
      final isMarkdown=['md','markdown'].contains(
        widget.document.path.toLowerCase().split('.').last);
      // Never let untrusted HTML close the trusted inline script tag.
      final quoted=jsonEncode(text).replaceAll('<',r'\u003C');
      final html=StringBuffer()
        ..write('<!doctype html><html><head><meta charset="utf-8">')
        ..write('<meta name="viewport" content="width=device-width,initial-scale=1">')
        ..write('<meta http-equiv="Content-Security-Policy" content="')
        ..write("default-src 'none'; script-src 'unsafe-inline'; ")
        ..write("style-src 'unsafe-inline'; img-src data: blob:; ")
        ..write("font-src data: blob:; connect-src 'none'; ")
        ..write("frame-src 'none'; object-src 'none'; form-action 'none';")
        ..write('">')
        ..write('<style>html,body{margin:0;background:#fff;color:#20202a;')
        ..write('font:16px/1.6 system-ui,sans-serif;}main{padding:18px;')
        ..write('max-width:920px;margin:auto;overflow-wrap:anywhere;}')
        ..write('img{max-width:100%}pre{white-space:pre-wrap;background:#f4f4f4;')
        ..write('padding:12px}table{border-collapse:collapse;width:100%}')
        ..write('td,th{border:1px solid #aaa;padding:6px}')
        ..write('@media(prefers-color-scheme:dark){html,body{')
        ..write('background:#181620;color:#eee}pre{background:#2b2933}}')
        ..write('</style><script>')
        ..write(libraries[0])
        ..write('</script><script>')
        ..write(libraries[1])
        ..write('</script></head><body><main id="doc"></main><script>')
        ..write('const raw=')
        ..write(quoted)
        ..write(';const html=')
        ..write(isMarkdown
          ?'marked.parse(raw,{gfm:true,breaks:false})':'raw')
        ..write(';const out=DOMPurify.sanitize(html,{')
        ..write('FORBID_TAGS:["script","iframe","form","object","embed"],')
        ..write('FORBID_ATTR:["srcset"]});')
        ..write('const root=document.getElementById("doc");')
        ..write('root.innerHTML=out;')
        ..write('root.querySelectorAll("a[href]").forEach(a=>a.removeAttribute("href"));')
        ..write('root.querySelectorAll("img[src]").forEach(i=>{')
        ..write('if(!/^(data:image\\/|blob:)/.test(i.getAttribute("src")||""))i.removeAttribute("src");')
        ..write('});')
        ..write('</script></body></html>');
      if(mounted)setState(()=>_html=html.toString());
    }catch(e){if(mounted)setState(()=>_error=e.toString());}
  }
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text(widget.document.uri.pathSegments.last)),
    body:_error!=null?Center(child:Text(_error!)):
      _html==null?const Center(child:CircularProgressIndicator()):
      InAppWebView(
        webViewEnvironment:_environment,
        initialData:InAppWebViewInitialData(data:_html!),
        initialSettings:InAppWebViewSettings(
          javaScriptEnabled:true,
          domStorageEnabled:false,cacheEnabled:false,blockNetworkLoads:true,
          allowFileAccess:false,allowContentAccess:false,
          supportMultipleWindows:false,
          javaScriptCanOpenWindowsAutomatically:false,
          useShouldOverrideUrlLoading:true,
        ),
        shouldOverrideUrlLoading:(controller,action)async=>
          NavigationActionPolicy.CANCEL,
      ),
  );
}
