import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Offline SheetJS spreadsheet viewer, using Gander's exact SheetJS CE bundle.
/// It is an independent viewer surface: cell edits save through FileShareDoc.
class GanderSpreadsheetPreviewPage extends StatefulWidget {
  const GanderSpreadsheetPreviewPage({super.key,required this.document});
  final File document;
  @override State<GanderSpreadsheetPreviewPage> createState()=>
    _GanderSpreadsheetPreviewPageState();
}
class _GanderSpreadsheetPreviewPageState
    extends State<GanderSpreadsheetPreviewPage>{
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  WebViewEnvironment? _environment;
  Uint8List? _workbook;
  Uint8List? _sheetJs;
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
      if(!await widget.document.exists())throw StateError('File missing');
      if(await widget.document.length()>24*1024*1024)
        throw StateError('Spreadsheet exceeds 24 MB preview limit');
      final data=await rootBundle.load('assets/gander/xlsx.full.min.js');
      _sheetJs=data.buffer.asUint8List(data.offsetInBytes,data.lengthInBytes);
      _workbook=await widget.document.readAsBytes();
      if(Platform.isWindows){
        if(await WebViewEnvironment.getAvailableVersion()==null)
          throw StateError('Microsoft Edge WebView2 Runtime is missing');
        final root=await getApplicationSupportDirectory();
        final folder=Directory(root.path+Platform.pathSeparator+
          'file_share_doc_webview2');
        await folder.create(recursive:true);
        _environment=await WebViewEnvironment.create(settings:
          WebViewEnvironmentSettings(userDataFolder:folder.path));
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
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{font-family:system-ui,sans-serif;color-scheme:light dark}
body{margin:0;background:#f7f6fc;color:#29233a}
#tabs{display:flex;gap:5px;overflow-x:auto;position:sticky;top:0;
padding:8px;background:#eae5fa;z-index:4}
#tabs button{border:1px solid #b9a9e9;border-radius:7px;padding:9px;
background:white;color:#423064;white-space:nowrap;cursor:pointer}
#tabs button.on{background:#6750a4;color:white}
#search{margin:8px;min-width:210px;padding:9px;border:1px solid #ccc}
#sheet{padding:8px;overflow:auto;height:calc(100vh - 110px)}
table{border-collapse:collapse;background:white;white-space:nowrap;font-size:13px}
td,th{border:1px solid #ccc;min-width:60px;padding:5px 9px;text-align:left}
th{background:#eee9fb;position:sticky;top:0;z-index:2}
tr>th:first-child{position:sticky;left:0;z-index:3}
td.active{outline:2px solid #8a57dc;background:#f2e9ff}
#notice{margin:8px;color:#666}
@media(prefers-color-scheme:dark){
body{background:#191723;color:#eee}
#tabs{background:#29243c}#tabs button{background:#302d42;color:#eee}
#tabs button.on{background:#7257bf}
table{background:#292638}th{background:#403855;color:#fff}
td{border-color:#5c5467}td.active{background:#564873}
#notice{color:#aaa}}
</style>
<script src="xlsx.js" defer></script>
<script src="app.js" defer></script>
</head><body>
<div id="tabs"></div><input id="search" type="search" placeholder="Find text in sheet">
<div id="notice" role="status">Loading spreadsheet…</div>
<div id="sheet"></div>
</body></html>''';

  static const _app=r'''(async function(){
'use strict';
try{
  const source=await fetch('document',{credentials:'omit',cache:'no-store'});
  if(!source.ok)throw Error('File cannot be read');
  const buffer=await source.arrayBuffer();
  const book=XLSX.read(new Uint8Array(buffer),{type:'array',dense:true,
    cellDates:true,cellStyles:true});
  const tabs=document.getElementById('tabs');
  const screen=document.getElementById('sheet');
  const notice=document.getElementById('notice');
  const search=document.getElementById('search');
  if(!book.SheetNames.length)throw Error('No worksheet found');
  function showSheet(name){
    const sheet=book.Sheets[name];
    const ref=sheet['!ref'];
    screen.replaceChildren();
    if(!ref){notice.textContent='Empty worksheet';return;}
    const bounds=XLSX.utils.decode_range(ref);
    // Cap a malformed/huge sheet's DOM; render a bounded window.
    const rows=Math.min(1000,bounds.e.r-bounds.s.r+1);
    const cols=Math.min(100,bounds.e.c-bounds.s.c+1);
    notice.textContent='Viewing '+name+' · '+rows+' rows × '+cols+
      ' columns (up to 1000 rows / 100 columns per preview).';
    const table=document.createElement('table');
    const header=document.createElement('tr');
    const corner=document.createElement('th');corner.textContent='#';
    header.appendChild(corner);
    for(let c=bounds.s.c;c<bounds.s.c+cols;c++){
      const th=document.createElement('th');
      th.textContent=XLSX.utils.encode_col(c);
      header.appendChild(th);
    }
    table.appendChild(header);
    for(let r=bounds.s.r;r<bounds.s.r+rows;r++){
      const row=document.createElement('tr');
      const head=document.createElement('th');head.textContent=String(r+1);
      row.appendChild(head);
      for(let c=bounds.s.c;c<bounds.s.c+cols;c++){
        const td=document.createElement('td');
        const key=XLSX.utils.encode_cell({r:r,c:c});
        const cell=sheet[key];
        td.textContent=cell==null?'':XLSX.utils.format_cell(cell);
        td.title=key;
        td.addEventListener('click',()=>{
          screen.querySelectorAll('.active').forEach(el=>el.classList.remove('active'));
          td.classList.add('active');
          notice.textContent=name+' · '+key+' = '+td.textContent;
        });
        row.appendChild(td);
      }
      table.appendChild(row);
    }
    screen.appendChild(table);
    tabs.querySelectorAll('button').forEach(b=>
      b.classList.toggle('on',b.textContent===name));
  }
  for(const name of book.SheetNames){
    const button=document.createElement('button');
    button.textContent=name;
    button.addEventListener('click',()=>showSheet(name));
    tabs.appendChild(button);
  }
  search.addEventListener('input',()=>{
    const term=search.value.trim().toLocaleLowerCase();
    screen.querySelectorAll('td').forEach(td=>{
      td.style.background=term&&td.textContent.toLocaleLowerCase().includes(term)
        ?'#fbd38d':'';
    });
  });
  showSheet(book.SheetNames[0]);
}catch(error){
  document.getElementById('notice').textContent=
    'Could not display spreadsheet: '+String(error);
}
})();''';

  Future<void> _handle(HttpRequest request)async{
    final response=request.response;
    response.headers.set('X-Content-Type-Options','nosniff');
    response.headers.set('Cache-Control','no-store');
    final parts=request.uri.pathSegments;
    if(request.method!='GET'||parts.length!=2||parts[0]!=_token){
      response.statusCode=HttpStatus.notFound;
      await response.close();return;
    }
    final path=parts[1];
    if(path=='index'){
      response.headers.contentType=ContentType.html;
      response.headers.set('Content-Security-Policy',
        "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "+
        "connect-src 'self'; img-src data: blob:; font-src data:; "+
        "frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'");
      response.write(_html);
    }else if(path=='xlsx.js'){
      response.headers.contentType=ContentType('text','javascript');
      response.add(_sheetJs!);
    }else if(path=='app.js'){
      response.headers.contentType=ContentType('text','javascript');
      response.write(_app);
    }else if(path=='document'){
      response.headers.contentType=ContentType.binary;
      response.add(_workbook!);
    }else response.statusCode=HttpStatus.notFound;
    await response.close();
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
        javaScriptEnabled:true,useShouldOverrideUrlLoading:true,
        domStorageEnabled:false,cacheEnabled:false,
        javaScriptCanOpenWindowsAutomatically:false,supportMultipleWindows:false,
        allowFileAccess:false,allowContentAccess:false),
      shouldOverrideUrlLoading:(controller,action)async{
        final path=action.request.url?.toString()??'';
        final url=_url!;
        final root=url.substring(0,url.lastIndexOf('/')+1);
        return path.startsWith(root)
          ?NavigationActionPolicy.ALLOW:NavigationActionPolicy.CANCEL;
      },
    ));
}
