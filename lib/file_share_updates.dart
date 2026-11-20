import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart' show FileTheme, WindowsBackground;

/// The only trusted manifest is the one maintained by the GitHub release
/// workflow on main. No arbitrary remote binary URLs are accepted.
final fileShareNavigatorKey=GlobalKey<NavigatorState>();

const fileShareUpdateManifest =
    'https://raw.githubusercontent.com/syncstudiolan/Fileshare/main/update_manifest.json';
const _allowedDownloadPrefix =
    'https://github.com/syncstudiolan/Fileshare/releases/download/';

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.build,
    required this.url,
    required this.sha256,
    required this.size,
    required this.notes,
  });
  final String version, url, sha256, notes;
  final int build, size;

  static UpdateRelease? fromJson(Object? raw, String platform) {
    if (raw is! Map<String, dynamic>) return null;
    final version=raw['version'];
    final build=raw['build'];
    final url=raw['url'];
    final hash=raw['sha256'];
    final size=raw['size'];
    if(version is! String || version.isEmpty ||
        build is! int || build<1 ||
        size is! int || size<1 ||
        url is! String || !url.startsWith(_allowedDownloadPrefix) ||
        !Uri.tryParse(url)!.hasScheme ||
        !url.endsWith(platform=='android' ? '.apk' : '.exe') ||
        hash is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      return null;
    }
    return UpdateRelease(version:version,build:build,url:url,
      sha256:hash.toLowerCase(),size:size,
      notes:raw['notes'] is String ? raw['notes'] as String : '');
  }
}

enum UpdateStage { idle, checking, available, downloading, ready, installing, failed, current }

class FileShareUpdates extends ChangeNotifier {
  FileShareUpdates._();
  static final instance=FileShareUpdates._();
  static const androidChannel=MethodChannel('file_share.native');
  UpdateStage stage=UpdateStage.idle;
  UpdateRelease? release;
  double progress=0;
  String? error;
  File? downloaded;
  bool showPopup=false, _checking=false, _downloading=false;
  int? _suppressedBuild;
  int _currentBuild=1;
  String _currentVersion='0.1.0';
  String get currentLabel=>'$_currentVersion (build $_currentBuild)';
  bool get supported=>Platform.isAndroid||Platform.isWindows;

  void initializeVersion(String version,int build){
    _currentVersion=version;
    _currentBuild=build;
  }

  /// New session: clear a previous "Update later" only when the app restarts.
  Future<void> check({bool startup=false}) async {
    if(!supported||_checking||_downloading)return;
    _checking=true;
    stage=UpdateStage.checking;error=null;notifyListeners();
    final client=HttpClient()..connectionTimeout=const Duration(seconds:12);
    try {
      final uri=Uri.parse(fileShareUpdateManifest);
      final request=await client.getUrl(uri);
      request.headers.set('cache-control','no-cache');
      final response=await request.close().timeout(const Duration(seconds:20));
      if(response.statusCode!=200)throw HttpException(
        'Update manifest HTTP ${response.statusCode}');
      const cap=100*1024;
      final chunks=<int>[];
      await for(final part in response){
        chunks.addAll(part);
        if(chunks.length>cap)throw const FormatException('Update manifest too large');
      }
      final data=jsonDecode(utf8.decode(chunks));
      if(data is! Map<String,dynamic>||data['schema']!=1){
        throw const FormatException('Unsupported update manifest');
      }
      final platform=Platform.isAndroid?'android':'windows';
      final parsed=UpdateRelease.fromJson(data[platform],platform);
      if(parsed==null)throw const FormatException('Invalid release metadata');
      if(parsed.build>_currentBuild) {
        release=parsed;
        stage=downloaded!=null && await downloaded!.exists()
          ?UpdateStage.ready:UpdateStage.available;
        if(startup && _suppressedBuild!=parsed.build)showPopup=true;
      } else {
        release=null;downloaded=null;showPopup=false;
        stage=UpdateStage.current;
      }
    } catch(e) {
      stage=UpdateStage.failed;
      error='Could not check for updates: $e';
      showPopup=false;
    } finally {
      _checking=false;notifyListeners();client.close(force:true);
    }
  }

  void later(){_suppressedBuild=release?.build;showPopup=false;notifyListeners();}
  void startNewForegroundSession(){
    _suppressedBuild=null;
  }

  Future<void> download() async {
    final next=release;
    if(next==null||_downloading)return;
    _downloading=true;
    showPopup=false;
    stage=UpdateStage.downloading;progress=0;error=null;
    notifyListeners();
    final client=HttpClient()..connectionTimeout=const Duration(seconds:20);
    File? partial;
    try {
      final directory=await getApplicationSupportDirectory();
      final folder=Directory('${directory.path}${Platform.pathSeparator}updates');
      await folder.create(recursive:true);
      final extension=Platform.isAndroid?'apk':'exe';
      final name='FileShare-${Platform.isAndroid?'Android':'Windows'}-${next.build}.$extension';
      final file=File('${folder.path}${Platform.pathSeparator}$name');
      partial=File('${file.path}.download');
      if(await partial.exists())await partial.delete();
      final request=await client.getUrl(Uri.parse(next.url));
      final response=await request.close().timeout(const Duration(seconds:30));
      if(response.statusCode!=200)throw HttpException(
        'Update download HTTP ${response.statusCode}');
      final sink=partial.openWrite();
      var received=0;
      try {
        await for(final chunk in response){
          sink.add(chunk);received+=chunk.length;
          if(received>next.size)throw const FormatException('Invalid update size');
          progress=(received/next.size).clamp(0.0,1.0).toDouble();
          notifyListeners();
        }
        await sink.flush();
      } finally { await sink.close(); }
      if(received!=next.size)throw const FormatException('Update download truncated');
      final actual=(await sha256.bind(partial.openRead()).first).toString();
      if(actual.toLowerCase()!=next.sha256) {
        throw const FormatException('Update SHA-256 mismatch; installation blocked');
      }
      if(await file.exists())await file.delete();
      await partial.rename(file.path);
      downloaded=file;progress=1;
      stage=UpdateStage.ready;
    } catch(e) {
      error='Download failed: $e';
      stage=UpdateStage.failed;
      if(partial!=null&&await partial.exists())await partial.delete();
    } finally {
      _downloading=false;client.close(force:true);notifyListeners();
    }
  }

  Future<void> install() async {
    final file=downloaded;
    if(stage!=UpdateStage.ready||file==null||!await file.exists())return;
    // Revalidate immediately before install; another process may have touched the file.
    final selected=release;
    if(selected==null || await file.length()!=selected.size ||
        (await sha256.bind(file.openRead()).first).toString().toLowerCase()!=
            selected.sha256){
      stage=UpdateStage.failed;
      error='Downloaded installer failed final SHA-256 verification. Download again.';
      downloaded=null;notifyListeners();return;
    }
    stage=UpdateStage.installing;error=null;notifyListeners();
    try {
      if(Platform.isAndroid) {
        // PackageInstaller is the only supported user-approved sideload path;
        // the operating system shows an Install confirmation.
        await androidChannel.invokeMethod<void>(
          'installDownloadedApk',{'path':file.path});
      } else if(Platform.isWindows) {
        await _installWindows(file);
      }
    }catch(e) {
      stage=UpdateStage.failed;
      error='Could not open installer: $e';
      notifyListeners();
    }
  }

  Future<void> _installWindows(File installer) async {
    final currentPid=pid;
    final exe=Platform.resolvedExecutable;
    final scripts=await getTemporaryDirectory();
    final script=File('${scripts.path}${Platform.pathSeparator}fileshare-update-${release!.build}.ps1');
    // Literal escaping protects paths containing apostrophes.
    String quote(String value)=>"'"+value.replaceAll("'","''")+"'";
    final code="""
\$ErrorActionPreference = 'Stop'
\$oldPid = $currentPid
\$setup = ${quote(installer.path)}
\$app = ${quote(exe)}
\$limit = (Get-Date).AddSeconds(45)
while (Get-Process -Id \$oldPid -ErrorAction SilentlyContinue) {
  if ((Get-Date) -gt \$limit) { throw 'Previous File Share process did not exit.' }
  Start-Sleep -Milliseconds 350
}
try {
  # Show the real Inno Setup wizard, Install button, progress and Windows UAC.
  \$process = Start-Process -FilePath \$setup -Verb RunAs -ArgumentList '/NORESTART','/CLOSEAPPLICATIONS','/LOG' -PassThru -Wait
  if (\$process.ExitCode -ne 0) { throw "Installer exited \$(\$process.ExitCode)" }
  Start-Process -FilePath \$app
} catch {
  \$log = Join-Path \$env:TEMP 'fileshare-update-error.log'
  Add-Content -Path \$log -Value \$_.ToString()
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show('File Share installation failed: '+\$_.Exception.Message+[Environment]::NewLine+'Log: '+\$log,'File Share Update','OK','Error') | Out-Null
}
""";
    await script.writeAsString(code,flush:true);
    final process=await Process.start('powershell.exe',[
      '-NoProfile','-ExecutionPolicy','Bypass','-File',script.path,
    ],mode:ProcessStartMode.detached);
    if(process.pid<=0)throw StateError('Updater helper did not start');
    // Remove file lock, stop LAN and tray, and let the elevated installer
    // replace Program Files only after the process has fully exited.
    await WindowsBackground.instance.exitCompletely();
    exit(0);
  }
}

class FileShareUpdatePage extends StatefulWidget {
  const FileShareUpdatePage({super.key});
  @override State<FileShareUpdatePage> createState()=>_FileShareUpdatePageState();
}
class _FileShareUpdatePageState extends State<FileShareUpdatePage> {
  final updates=FileShareUpdates.instance;
  @override void initState(){super.initState();updates.addListener(_changed);}
  void _changed(){if(mounted)setState((){});}
  @override void dispose(){updates.removeListener(_changed);super.dispose();}
  @override Widget build(BuildContext context) {
    final release=updates.release;
    final stage=updates.stage;
    return Scaffold(
      appBar:AppBar(title:const Text('App Updates')),
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:Center(child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:560),
          child:ListView(padding:const EdgeInsets.all(20),children:[
            ClipRRect(borderRadius:BorderRadius.circular(14),
              child:Image.asset('assets/branding/file_share_icon.webp',
                width:56,height:56,fit:BoxFit.cover)),
            const SizedBox(height:14),
            Text('File Share · ${updates.currentLabel}',
              textAlign:TextAlign.center,
              style:Theme.of(context).textTheme.titleLarge),
            const SizedBox(height:20),
            if(release!=null)Card(child:Padding(
              padding:const EdgeInsets.all(18),
              child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                Text('Update ${release.version} (build ${release.build})',
                  style:Theme.of(context).textTheme.titleMedium),
                if(release.notes.isNotEmpty)...[
                  const SizedBox(height:8),Text(release.notes),
                ],
                const SizedBox(height:10),
                Text('Size: ${(release.size/1048576).toStringAsFixed(1)} MB'),
              ]))),
            const SizedBox(height:12),
            if(stage==UpdateStage.downloading)...[
              LinearProgressIndicator(value:updates.progress),
              const SizedBox(height:6),
              Text('Downloading… ${(updates.progress*100).round()}%'),
            ],
            if(stage==UpdateStage.checking)
              const Center(child:CircularProgressIndicator()),
            if(stage==UpdateStage.current)
              const Text('You already have the latest version.',
                textAlign:TextAlign.center),
            if(updates.error!=null)
              Text(updates.error!,style:TextStyle(
                color:Theme.of(context).colorScheme.error)),
            const SizedBox(height:14),
            if(stage==UpdateStage.available)
              FilledButton.icon(onPressed:updates.download,
                icon:const Icon(Icons.download_rounded),
                label:const Text('Download now')),
            if(stage==UpdateStage.ready)
              FilledButton.icon(onPressed:updates.install,
                icon:const Icon(Icons.install_mobile_outlined),
                label:Text(Platform.isAndroid?'Install update':'Install and restart')),
            if(stage==UpdateStage.installing)
              const Text('System installer is opening. Confirm when prompted.'),
            if(stage!=UpdateStage.downloading &&
                stage!=UpdateStage.installing)
              OutlinedButton.icon(
                onPressed:()=>updates.check(),
                icon:const Icon(Icons.refresh_rounded),
                label:const Text('Check for updates')),
            const SizedBox(height:10),
            const Text('Android needs an OS install confirmation. Windows may '
              'request administrator approval. Only verified GitHub Releases '
              'are installed.',textAlign:TextAlign.center,
              style:TextStyle(fontSize:12)),
          ]),
        )),
      ),
    );
  }
}

/// Modern app-owned update notification (not an OS push).
/// It reappears next time the app is launched if the user chose Later.
class FileShareUpdateBanner extends StatelessWidget {
  const FileShareUpdateBanner({super.key});
  @override Widget build(BuildContext context)=>AnimatedBuilder(
    animation:FileShareUpdates.instance,
    builder:(context,_) {
      final updater=FileShareUpdates.instance;
      final release=updater.release;
      if(!updater.showPopup || release==null)return const SizedBox.shrink();
      return Positioned(
        top:MediaQuery.paddingOf(context).top+14,
        left:18,right:18,
        child:Center(child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:480),
          child:Material(
            elevation:14,borderRadius:BorderRadius.circular(22),
            color:Theme.of(context).colorScheme.surface,
            child:Padding(padding:const EdgeInsets.all(17),
              child:Column(mainAxisSize:MainAxisSize.min,
                crossAxisAlignment:CrossAxisAlignment.start,children:[
                Row(children:[
                  ClipRRect(borderRadius:BorderRadius.circular(8),
                    child:Image.asset('assets/branding/file_share_icon.webp',
                      width:34,height:34,fit:BoxFit.cover)),
                  const SizedBox(width:10),
                  Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,
                    children:[
                    const Text('A new File Share update is ready',
                      style:TextStyle(fontWeight:FontWeight.bold,fontSize:14)),
                    Text('${release.version} · ${(release.size/1048576).toStringAsFixed(1)} MB',
                      style:const TextStyle(fontSize:12)),
                  ])),
                  IconButton(onPressed:updater.later,
                    icon:const Icon(Icons.close_rounded)),
                ]),
                if(release.notes.isNotEmpty)...[
                  const SizedBox(height:8),
                  Text(release.notes,maxLines:3,overflow:TextOverflow.ellipsis),
                ],
                const SizedBox(height:12),
                Wrap(spacing:8,runSpacing:8,children:[
                  FilledButton.icon(
                    onPressed:(){
                      updater.later();
                      fileShareNavigatorKey.currentState?.push(MaterialPageRoute<void>(
                        builder:(_)=>const FileShareUpdatePage()));
                      unawaited(updater.download());
                    },
                    icon:const Icon(Icons.download_rounded,size:18),
                    label:const Text('Download now')),
                  TextButton(onPressed:updater.later,
                    child:const Text('Install update later')),
                ]),
              ])),
          ),
        )),
      );
    },
  );
}
