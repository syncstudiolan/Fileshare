import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Offline DOCX preview using the same Apache-licensed docx-preview +
/// MIT-licensed JSZip versions vendored by Gander.
/// There is no document upload, network request or remote script dependency.
/// This is a view surface; editing/saving uses FileShareDocEngine separately.
class GanderDocxPreviewPage extends StatefulWidget {
  const GanderDocxPreviewPage({super.key,required this.document});
  final File document;
  @override
  State<GanderDocxPreviewPage> createState()=>_GanderDocxPreviewPageState();
}
class _GanderDocxPreviewPageState extends State<GanderDocxPreviewPage> {
  String? _html,_problem;
  WebViewEnvironment? _environment;
  @override
  void initState(){super.initState();_prepare();}
  Future<void> _prepare()async{
    try{
      if(await widget.document.length()>12*1024*1024){
        throw StateError('DOCX preview supports files up to 12 MB');
      }
      final bytes=await widget.document.readAsBytes();
      if(!mounted)return;
      final libraries=await Future.wait([
        rootBundle.loadString('assets/gander/jszip3.min.js'),
        rootBundle.loadString('assets/gander/docx-preview.min.js')
      ]);
      if(Platform.isWindows){
        final version=await WebViewEnvironment.getAvailableVersion();
        if(version==null)throw StateError('Microsoft Edge WebView2 Runtime not installed');
        final directory=await getApplicationSupportDirectory();
        final userData=Directory(directory.path+
          Platform.pathSeparator+'file_share_doc_webview2');
        await userData.create(recursive:true);
        _environment=await WebViewEnvironment.create(
          settings:WebViewEnvironmentSettings(userDataFolder:userData.path));
      }
      // Trusted, packaged scripts only. A strict CSP denies all network,
      // forms, navigation/iframes and external assets.
      final payload=jsonEncode(base64Encode(bytes));
      final html=StringBuffer()
        ..write('<!doctype html><html><head><meta charset="utf-8">')
        ..write('<meta name="viewport" content="width=device-width,initial-scale=1">')
        ..write('<meta http-equiv="Content-Security-Policy" content="')
        ..write("default-src 'none'; script-src 'unsafe-inline'; ")
        ..write("style-src 'unsafe-inline'; img-src data: blob:; ")
        ..write("font-src data: blob:; connect-src 'none'; ")
        ..write("frame-src 'none'; form-action 'none'; object-src 'none';")
        ..write('">')
        ..write('<style>')
        ..write('html,body{margin:0;background:#eee;font-family:sans-serif}')
        ..write('#status{padding:10px;text-align:center;color:#444}')
        ..write('.docx-wrapper{padding:12px !important;background:#eee !important;}')
        ..write('.docx-wrapper > section.docx{box-shadow:0 2px 10px #0002;max-width:100%;}')
        ..write('@media(prefers-color-scheme:dark){html,body,.docx-wrapper{background:#16151c !important}#status{color:white}}')
        ..write('</style><script>')
        ..write(libraries[0])
        ..write('</script><script>')
        ..write(libraries[1])
        ..write('</script></head><body><div id="status">Rendering Word document…</div>')
        ..write('<div id="document"></div><script>')
        ..write('(async()=>{try{')
        ..write('const raw=atob(')
        ..write(payload)
        ..write(');const bytes=new Uint8Array(raw.length);')
        ..write('for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);')
        ..write('await docx.renderAsync(bytes,document.getElementById("document"),null,{')
        ..write('breakPages:true,renderHeadersFooters:true,inWrapper:true,')
        ..write('useBase64URL:true,ignoreLastRenderedPageBreak:false,')
        ..write('experimental:true});')
        ..write('document.getElementById("status").remove();')
        ..write('document.querySelectorAll("iframe").forEach(x=>x.remove());')
        ..write('document.querySelectorAll("a[href]").forEach(a=>a.removeAttribute("href"));')
        ..write('}catch(e){document.getElementById("status").textContent="')
        ..write('Cannot render DOCX: "+String(e);}})();')
        ..write('</script></body></html>');
      if(mounted)setState(()=>_html=html.toString());
    }catch(e){if(mounted)setState(()=>_problem=e.toString());}
  }
  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text(widget.document.uri.pathSegments.last),
      actions:[IconButton(icon:const Icon(Icons.info_outline),
        tooltip:'Preview limitations',
        onPressed:()=>showDialog<void>(context:context,builder:(dialog)=>
          AlertDialog(title:const Text('Offline DOCX preview'),
            content:const Text('Uses Gander-vendored docx-preview and JSZip. '
              'It is a read-only layout preview, not the MS Word rendering engine. '
              'Some pagination and fonts may differ. Edits are saved from the '
              'File Share Doc text workspace.'),
            actions:[TextButton(onPressed:()=>Navigator.pop(dialog),
              child:const Text('Close'))])))]),
    body:_problem!=null?Center(child:Padding(
      padding:const EdgeInsets.all(20),child:Text(_problem!))):
      _html==null?const Center(child:CircularProgressIndicator()):
      InAppWebView(
        webViewEnvironment:_environment,
        initialData:InAppWebViewInitialData(data:_html!),
        initialSettings:InAppWebViewSettings(
          javaScriptEnabled:true,domStorageEnabled:false,
          cacheEnabled:false,allowFileAccess:false,
          allowContentAccess:false,blockNetworkLoads:true,
          allowFileAccessFromFileURLs:false,
          allowUniversalAccessFromFileURLs:false,
          javaScriptCanOpenWindowsAutomatically:false,
          supportMultipleWindows:false,
          transparentBackground:false,
        ),
        shouldOverrideUrlLoading:(controller,action)async=>
          NavigationActionPolicy.CANCEL,
      ),
  );
}
