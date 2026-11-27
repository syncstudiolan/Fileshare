import 'app_top_notice.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'main.dart' show FileTheme, WindowsBackground;
import 'secure_http.dart';

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
        !url.endsWith(platform=='android' ? '.apk' : platform=='ios' ? '.ipa' : platform=='macos' ? '.dmg' : '.exe') ||
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
  bool get supported=>Platform.isAndroid||Platform.isWindows||Platform.isIOS||Platform.isMacOS;
  String get _extension=>Platform.isAndroid?'apk':Platform.isIOS?'ipa':Platform.isMacOS?'dmg':'exe';

  void initializeVersion(String version,int build){
    _currentVersion=version;
    _currentBuild=build;
  }

  /// Resolve the one current platform entry; upgrades supersede, never queue.
  Future<UpdateRelease> _fetchLatestRelease() async {
    return SecureHttp.run((client) async {
      final uri = Uri.parse(fileShareUpdateManifest).replace(queryParameters: {
        't': DateTime.now().millisecondsSinceEpoch.toString(),
      });
      final request = await client.getUrl(uri);
      request.headers.set('cache-control', 'no-cache, no-store, max-age=0');
      request.headers.set('pragma', 'no-cache');
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw HttpException('Update manifest HTTP ${response.statusCode}');
      const cap = 100 * 1024;
      final chunks = <int>[];
      await for (final part in response) {
        chunks.addAll(part);
        if (chunks.length > cap) throw const FormatException('Update manifest too large');
      }
      final data = jsonDecode(utf8.decode(chunks));
      if (data is! Map<String, dynamic> || data['schema'] != 1) throw const FormatException('Unsupported update manifest');
      final platform = Platform.isAndroid ? 'android' : Platform.isIOS ? 'ios' : Platform.isMacOS ? 'macos' : 'windows';
      final parsed = UpdateRelease.fromJson(data[platform], platform);
      if (parsed == null) throw const FormatException('Invalid latest release metadata');
      return parsed;
    });
  }

  /// New session: clear a previous "Update later" only when the app restarts.
  Future<void> check({bool startup=false}) async {
    if(!supported||_checking||_downloading||stage==UpdateStage.installing)return;
    _checking=true;
    stage=UpdateStage.checking;error=null;notifyListeners();
    try {
      final parsed = await _fetchLatestRelease();
      if (parsed.build > _currentBuild) {
        release = parsed;
        final cached = downloaded;
        final matchingCache = cached != null && cached.path.endsWith('-${parsed.build}.' + _extension);
        if (!matchingCache) downloaded = null;
        stage = matchingCache && await cached!.exists() ? UpdateStage.ready : UpdateStage.available;
        if (startup && _suppressedBuild != parsed.build) showPopup = true;
      } else {
        release = null; downloaded = null; showPopup = false; stage = UpdateStage.current;
      }
    } catch(e) {
      stage=UpdateStage.failed;
      error='Could not check for updates: $e';
      showPopup=false;
    } finally {
      _checking=false;notifyListeners();
    }
  }

  void later(){_suppressedBuild=release?.build;showPopup=false;notifyListeners();}
  void startNewForegroundSession(){
    _suppressedBuild=null;
  }

  Future<void> download() async {
    final current = release;
    // AppleJR-installed unsigned IPAs cannot be installed by an iOS app.
    // Signing and installation must happen outside the iOS sandbox.
    if (!supported || current == null || _downloading || _checking || stage == UpdateStage.installing) return;
    _downloading = true;
    var next = current;
    showPopup=false;
    stage=UpdateStage.downloading;progress=0;error=null;
    notifyListeners();
    File? partial;
    try {
      // Re-resolve just before download so a queued older release is skipped.
      final latest = await _fetchLatestRelease();
      if (latest.build <= _currentBuild) { release = null; downloaded = null; stage = UpdateStage.current; return; }
      if (latest.build > next.build) next = latest;
      release = next;
      await SecureHttp.run((client) async {
      final directory=await getApplicationSupportDirectory();
      final folder=Directory('${directory.path}${Platform.pathSeparator}updates');
      await folder.create(recursive:true);
      final extension=_extension;
      final name='FileShare-${Platform.isAndroid?'Android':Platform.isIOS?'iOS':Platform.isMacOS?'macOS':'Windows'}-${next.build}.$extension';
      final file=File('${folder.path}${Platform.pathSeparator}$name');
      final partialFile=File('${file.path}.download');
      partial=partialFile;
      if(await partialFile.exists())await partialFile.delete();
      final request=await client.getUrl(Uri.parse(next.url));
      final response=await request.close().timeout(const Duration(seconds:30));
      if(response.statusCode!=200)throw HttpException(
        'Update download HTTP ${response.statusCode}');
      final sink=partialFile.openWrite();
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
      final actual=(await sha256.bind(partialFile.openRead()).first).toString();
      if(actual.toLowerCase()!=next.sha256) {
        throw const FormatException('Update SHA-256 mismatch; installation blocked');
      }
      if(await file.exists())await file.delete();
      await partialFile.rename(file.path);
      downloaded=file;progress=1;
      stage=UpdateStage.ready;
      });
    } catch(e) {
      error='Download failed: $e';
      stage=UpdateStage.failed;
      final incomplete=partial;
      if(incomplete!=null&&await incomplete.exists())await incomplete.delete();
    } finally {
      _downloading=false;notifyListeners();
    }
  }

  Future<void> install({Rect? sharePositionOrigin}) async {
    final file=downloaded;
    if(stage!=UpdateStage.ready||file==null)return;
    // Lock the install action before any await: no duplicate UAC prompts.
    stage=UpdateStage.installing;error=null;notifyListeners();
    try {
      // A newer manifest entry supersedes this package; never install the stale build.
      final latest = await _fetchLatestRelease();
      if (latest.build > _currentBuild && (release == null || latest.build > release!.build)) {
        release = latest; downloaded = null; stage = UpdateStage.available;
        error = 'A newer update is available. Download the latest version.';
        notifyListeners(); return;
      }
      // Revalidate immediately before install; another process may have touched the file.
      final selected=release;
      if(selected==null || !await file.exists() ||
          await file.length()!=selected.size ||
          (await sha256.bind(file.openRead()).first).toString().toLowerCase()!=
              selected.sha256){
        stage=UpdateStage.failed;
        error='Downloaded installer failed final SHA-256 verification. Download again.';
        downloaded=null;notifyListeners();return;
      }
      if(Platform.isIOS) {
        // A verified unsigned IPA can be exported to Files or a compatible
        // signing app. The iOS share sheet does not sign or install it.
        await SharePlus.instance.share(ShareParams(files:[XFile(file.path)],
          sharePositionOrigin:sharePositionOrigin));
        stage=UpdateStage.ready;
        notifyListeners();
      } else if(Platform.isAndroid) {
        // PackageInstaller is the only supported user-approved sideload path;
        // the operating system shows an Install confirmation.
        await androidChannel.invokeMethod<void>(
          'installDownloadedApk',{'path':file.path});
      } else if(Platform.isWindows) {
        await _installWindows(file);
      } else if(Platform.isMacOS) {
        await _installMacOS(file);
      }
    }catch(e) {
      // Keep the verified Windows download available for a retry if UAC or
      // the Shell rejects launch. The existing app remains running.
      stage=Platform.isWindows?UpdateStage.ready:UpdateStage.failed;
      if(Platform.isIOS)stage=UpdateStage.ready;
      error='Could not open installer: $e';
      notifyListeners();
    }
  }

  /// On macOS a DMG is a Finder disk image, not an Inno/PKG installer.
  /// A sandboxed, unsigned app must not silently overwrite itself in
  /// /Applications or bypass Gatekeeper/authorization. The user performs the
  /// normal Finder Replace confirmation after this app fully quits.
  Future<void> _installMacOS(File dmg) async {
    if(!Platform.isMacOS)return;
    if(!await dmg.exists())throw StateError('Downloaded Mac DMG is missing.');
    // LaunchServices mounts and opens the disk image; the user can then drag
    // File Share.app over Applications and approve Replace in Finder.
    final opened=await Process.run('/usr/bin/open',[dmg.path]);
    if(opened.exitCode!=0){
      throw StateError('macOS could not open the DMG: ${opened.stderr}');
    }
    showPopup=false;
    notifyListeners();
    // Closing the window alone hides the desktop tray. Exit the *entire*
    // running File Share process to release the old application bundle.
    await WindowsBackground.instance.exitCompletely();
  }

  Future<void> _installWindows(File installer) async {
    // Use the Windows Shell directly rather than a hidden PowerShell script
    // and a fragile file-based acknowledgement. Run UAC on a worker isolate
    // so the Flutter UI stays responsive while the user approves elevation.
    final installerPath=installer.path;
    await _requestWindowsSetup(installerPath);
    // The native Shell accepted the launch. Only now release LAN/tray and
    // the installed executable. Inno's normal Finish page offers relaunch.
    await WindowsBackground.instance.exitCompletely();
  }

}

// SHELLEXECUTEINFOW: pointer-sized fields preserve the native x64 layout.
final class _WindowsShellExecuteInfo extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;
  @ffi.Uint32()
  external int fMask;
  external ffi.Pointer<ffi.Void> hwnd;
  external ffi.Pointer<ffi.Uint16> lpVerb;
  external ffi.Pointer<ffi.Uint16> lpFile;
  external ffi.Pointer<ffi.Uint16> lpParameters;
  external ffi.Pointer<ffi.Uint16> lpDirectory;
  @ffi.Int32()
  external int nShow;
  external ffi.Pointer<ffi.Void> hInstApp;
  external ffi.Pointer<ffi.Void> lpIDList;
  external ffi.Pointer<ffi.Uint16> lpClass;
  external ffi.Pointer<ffi.Void> hkeyClass;
  @ffi.Uint32()
  external int dwHotKey;
  external ffi.Pointer<ffi.Void> hIconOrMonitor;
  external ffi.Pointer<ffi.Void> hProcess;
}

Future<void> _requestWindowsSetup(String path) =>
    Isolate.run(() => _launchWindowsSetup(path));

void _launchWindowsSetup(String path) {
  if(!Platform.isWindows)throw UnsupportedError('Windows Setup requires Windows.');
  final ole=ffi.DynamicLibrary.open('ole32.dll');
  final shell=ffi.DynamicLibrary.open('shell32.dll');
  final kernel=ffi.DynamicLibrary.open('kernel32.dll');
  final allocate=ole.lookupFunction<
    ffi.Pointer<ffi.Void> Function(ffi.IntPtr),
    ffi.Pointer<ffi.Void> Function(int)>('CoTaskMemAlloc');
  final free=ole.lookupFunction<
    ffi.Void Function(ffi.Pointer<ffi.Void>),
    void Function(ffi.Pointer<ffi.Void>)>('CoTaskMemFree');
  final initialize=ole.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<ffi.Void>,ffi.Uint32),
    int Function(ffi.Pointer<ffi.Void>,int)>('CoInitializeEx');
  final uninitialize=ole.lookupFunction<ffi.Void Function(),void Function()>(
    'CoUninitialize');
  final execute=shell.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<_WindowsShellExecuteInfo>),
    int Function(ffi.Pointer<_WindowsShellExecuteInfo>)>('ShellExecuteExW');
  final getError=kernel.lookupFunction<ffi.Uint32 Function(),int Function()>(
    'GetLastError');
  final closeHandle=kernel.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<ffi.Void>),
    int Function(ffi.Pointer<ffi.Void>)>('CloseHandle');
  final allocations=<ffi.Pointer<ffi.Void>>[];
  ffi.Pointer<ffi.Void> memory(int size) {
    final pointer=allocate(size);
    if(pointer.address==0)throw StateError('Could not allocate Windows installer parameters.');
    allocations.add(pointer);
    pointer.cast<ffi.Uint8>().asTypedList(size).fillRange(0,size,0);
    return pointer;
  }
  ffi.Pointer<ffi.Uint16> wide(String value) {
    final units=value.codeUnits;
    final pointer=memory((units.length+1)*2).cast<ffi.Uint16>();
    pointer.asTypedList(units.length).setAll(0,units);
    return pointer;
  }
  // Shell extensions may require a single-threaded COM apartment.
  final initialized=initialize(ffi.nullptr,0x2);
  if(initialized<0)throw StateError('Could not initialize Windows Shell (HRESULT ${initialized.toUnsigned(32)}).');
  try {
    final info=memory(ffi.sizeOf<_WindowsShellExecuteInfo>())
      .cast<_WindowsShellExecuteInfo>();
    info.ref
      ..cbSize=ffi.sizeOf<_WindowsShellExecuteInfo>()
      ..fMask=0x00000100 | 0x00000040 // NOASYNC | NOCLOSEPROCESS
      ..lpVerb=wide('runas')
      ..lpFile=wide(path)
      ..lpParameters=wide('/NORESTART /CLOSEAPPLICATIONS /LOG')
      ..lpDirectory=wide(File(path).parent.path)
      ..nShow=1; // SW_SHOWNORMAL: keep the normal wizard interactive.
    final started=execute(info);
    final error=started==0?getError():0;
    if(info.ref.hProcess.address!=0)closeHandle(info.ref.hProcess);
    if(started==0) {
      if(error==1223)throw StateError('Windows administrator approval was cancelled. Retry Install and choose Yes.');
      throw StateError('Windows could not start Setup (Win32 error $error). Retry or run the verified installer manually.');
    }
  } finally {
    for(final pointer in allocations.reversed){free(pointer);}
    uninitialize();
  }
}

class FileShareUpdatePage extends StatefulWidget {
  const FileShareUpdatePage({super.key});
  @override State<FileShareUpdatePage> createState()=>_FileShareUpdatePageState();
}
class _FileShareUpdatePageState extends State<FileShareUpdatePage> {
  final updates=FileShareUpdates.instance;
  Future<void> _copyIosSigningLink(BuildContext context,UpdateRelease? release) async {
    if(release==null)return;
    await Clipboard.setData(ClipboardData(text:release.url));
    if(context.mounted)FileShareTopNotice.show(context,
      'IPA link copied. Re-sign with your existing AppleJR certificate and bundle ID before installing.');
  }
  Future<void> _confirmMacInstall() async {
    if(!mounted)return;
    final proceed=await showDialog<bool>(
      context:context,
      builder:(dialogContext)=>AlertDialog(
        title:const Text('Install File Share update on Mac'),
        content:const Text(
          'The verified DMG will open in Finder and File Share will quit '
          'completely, including its menu-bar LAN service. In the DMG '
          'window, drag File Share.app to Applications, select Replace '
          'if asked, then open File Share from Applications. Your files '
          'and settings are not stored inside the .app bundle.'),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialogContext,false),
            child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(dialogContext,true),
            child:const Text('Open DMG and quit')),
        ],
      ),
    );
    if(proceed==true)await updates.install();
  }

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
                label:Text(Platform.isIOS?'Download IPA':'Download now')),
            if(Platform.isIOS && release!=null && stage!=UpdateStage.downloading &&
                stage!=UpdateStage.installing)
              OutlinedButton.icon(onPressed:()=>_copyIosSigningLink(context,release),
                icon:const Icon(Icons.copy_rounded),
                label:const Text('Copy IPA link for AppleJR signing')),
            if(stage==UpdateStage.ready)
              FilledButton.icon(
                onPressed:Platform.isMacOS?_confirmMacInstall:() {
                  final render=context.findRenderObject();
                  final origin=render is RenderBox && render.hasSize
                    ?render.localToGlobal(Offset.zero)&render.size
                    :const Rect.fromLTWH(1,1,1,1);
                  unawaited(updates.install(sharePositionOrigin:origin));
                },
                icon:const Icon(Icons.install_mobile_outlined),
                label:Text(Platform.isAndroid?'Install update':
                  Platform.isIOS?'Share IPA to signing app':Platform.isMacOS?'Open DMG installer and quit':'Install and restart')),
            if(stage==UpdateStage.installing)
              Text(Platform.isMacOS
                ?'Opening the verified DMG in Finder and closing File Share. Drag File Share.app into Applications, choose Replace, then reopen File Share from Applications.'
                :'System installer is opening. Confirm when prompted.'),
            if(stage!=UpdateStage.downloading &&
                stage!=UpdateStage.installing)
              OutlinedButton.icon(
                onPressed:()=>updates.check(),
                icon:const Icon(Icons.refresh_rounded),
                label:const Text('Check for updates')),
            const SizedBox(height:10),
            Text(Platform.isIOS
              ?'iOS: download and verify the unsigned IPA, then share it to Files or a compatible signing app. Use your existing valid Apple signing identity and compatible profile with the original bundle ID. Install over File Share; do not uninstall it first. File Share cannot sign or silently install the IPA.'
              :Platform.isMacOS
                ?'macOS uses a verified DMG: tap Open DMG installer and quit. In Finder, drag File Share.app to Applications, choose Replace, and reopen the updated app. The menu-bar background process closes for replacement. Your files and settings stay in macOS Application Support. Unsigned apps may require approval in Privacy & Security.'
                :'Android needs an OS install confirmation. Windows may request administrator approval. Only verified GitHub Releases are installed.',
              textAlign:TextAlign.center,
              style:const TextStyle(fontSize:12)),
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
                    label:Text(Platform.isIOS?'Download IPA':'Download now')),
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
