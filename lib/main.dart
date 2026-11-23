import 'dart:async';
import 'file_share_text.dart';
import 'text_transfer_card.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:image/image.dart' as desktop_image;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'file_transfer_camera_page.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart' as desktop_tray;
import 'package:local_notifier/local_notifier.dart';

import 'lan_engine.dart';
import 'transfer_route.dart';
import 'auto_cloud_transfer_preference.dart';
import 'guest_qr_print.dart';
import 'transfer_downloads.dart';
import 'image_editing_page.dart';
import 'signature_edit_page.dart';
import 'toolbox_page.dart';
import 'file_share_doc_page.dart';
import 'file_share_doc_engine.dart';
import 'profile_avatar.dart';
import 'android_lan_background_setting.dart';
import 'image_editing_storage.dart';
import 'editor_transfer_session.dart';
import 'personal_cloud.dart';
import 'cloudflare_provisioning.dart';
import 'cloud_connect_guide_page.dart';
import 'file_share_updates.dart';
import 'app_top_notice.dart';
import 'account_directory.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Phase 1: native-feeling UI shell only. Authentication and transfer engines are
// intentionally NOT simulated. No network polling or cloud API calls occur.
Future<void> main([List<String> args = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = SharedPreferencesAsync();
  final mode = await prefs.getString('appearance');
  final previousOffline = await prefs.getBool('offline_start') ?? false;
  await TransferDownloads.instance.init();
  // No network call: restore the per-device preference before the first Send.
  try{await AutoCloudTransferPreference.instance.load();}
  catch(e){debugPrint('Auto Cloud preference restore failed: $e');}
  // CI emulator only: run the real LAN backend without first-use tapping.
  const ciLanTest = bool.fromEnvironment('FILE_SHARE_BACKGROUND_VALIDATION');
  // Explicit CI Windows smoke only; never changes ordinary first-run behavior.
  final windowsSmoke = Platform.isWindows && args.contains('--lan-smoke');
  final desktop = Platform.isWindows || Platform.isMacOS;
  // The default macOS Flutter runner does not reliably forward NSProcessInfo
  // command-line arguments to Dart. Read the native login flag directly.
  var macBackgroundLaunch=false;
  if(Platform.isMacOS){
    try{
      macBackgroundLaunch=await const MethodChannel('file_share.desktop')
        .invokeMethod<bool>('isBackgroundLaunch')??false;
    }catch(e){debugPrint('macOS startup argument unavailable: $e');}
  }
  final backgroundLaunch=desktop &&
    (args.contains('--background') || macBackgroundLaunch);
  final androidBackgroundEnabled = Platform.isAndroid &&
    (await prefs.getBool('android_receive_background') ?? true);
  // Receiver availability is independent from the first-run login screen.
  final offline = ciLanTest || previousOffline || windowsSmoke ||
    desktop;
  // Restore the encrypted session before drawing Profile/Login, without a
  // network call. The dashboard may re-check the restored session later.
  try { await PersonalCloud.instance.restore(); }
  catch (e) { debugPrint('Saved cloud session unavailable: $e'); }
  appLan.onReceived = (file) => Platform.isAndroid
      ? const MethodChannel('file_share.native').invokeMethod<void>(
          'notifyReceived', {'name': file.name, 'sender': file.peer})
      : desktop ? WindowsBackground.instance.notifyReceived(file)
          : Future<void>.value();
  if (desktop) {
    // No second process may steal the LAN listener. Only an explicit open
    // should focus a running app; login launches must remain silent.
    if (!await WindowsBackground.instance.acquireSingleInstance(
        showExisting:!backgroundLaunch)) {
      exit(0);
    }
    try {
      await WindowsBackground.instance.initialize(launchHidden:backgroundLaunch);
      await WindowsBackground.instance.enableDefaultStart(prefs);
    }catch (e) { debugPrint('Desktop tray/startup unavailable: $e'); }
  }
  // iPhone LAN receiver/discovery must start even before sign-in; local
  // file transfer is independent of the cloud account and login flow.
  if (Platform.isIOS ||
      ((offline || androidBackgroundEnabled) &&
       (Platform.isAndroid || desktop))) {
    unawaited(appLan.start().catchError((Object e) {
      debugPrint('Background LAN start failed: $e');
    }));
  }
  if (backgroundLaunch) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(windowManager.hide());
    });
  }
  runApp(FileShareApp(
    initialMode: switch (mode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    },
    offlineDefault: offline || PersonalCloud.instance.signedIn,
  ));
}


/// Windows and macOS: one live Flutter process with background LAN receiving.
class WindowsBackground with WindowListener, desktop_tray.TrayListener {
  WindowsBackground._();
  static final instance = WindowsBackground._();
  final ValueNotifier<bool> autoStartEnabled = ValueNotifier(false);
  bool _trayReady = false, _exiting = false, _notificationsReady = false;
  RandomAccessFile? _instanceLock;
  ServerSocket? _controlChannel;

  /// A private OS file lock prevents two copies of the Windows EXE from
  /// owning the fixed LAN TCP listener. If a copy is already active, ask it
  /// to open its tray window rather than showing a second broken dashboard.
  Future<bool> acquireSingleInstance({bool showExisting=true}) async {
    if (!Platform.isWindows && !Platform.isMacOS) return true;
    final folder = await getApplicationSupportDirectory();
    final lockFile = File(folder.path + Platform.pathSeparator +
      'file_share_process.lock');
    RandomAccessFile? handle;
    try {
      handle = await lockFile.open(mode: FileMode.append);
      // Nonblocking exclusive lock; OS releases it after a process crash.
      await handle.lock(FileLock.exclusive, 0, 1);
      _instanceLock = handle;
    } on FileSystemException {
      await handle?.close();
      if(showExisting){
        try {
          final existing = await Socket.connect(
            InternetAddress.loopbackIPv4, 49312,
            timeout: const Duration(milliseconds: 600));
          existing.write('SHOW\\n');
          await existing.flush();
          existing.destroy();
        } catch (e) {
          debugPrint('Existing File Share window could not be focused: $e');
        }
      }
      return false;
    }
    try {
      _controlChannel = await ServerSocket.bind(
        InternetAddress.loopbackIPv4, 49312);
      _controlChannel!.listen((socket) {
        socket.destroy();
        unawaited(showWindow());
      });
    } catch (e) {
      debugPrint('Optional local show-window channel unavailable: $e');
    }
    return true;
  }

  Future<void> initialize({bool launchHidden=false}) async {
    if (!Platform.isWindows && !Platform.isMacOS) return;
    await windowManager.ensureInitialized();
    // Window remains hidden on login; manual launch opens normally.
    if(launchHidden){
      await windowManager.hide();
    }else{
      await windowManager.maximize();
    }
    final icon=await _writeTrayIcon();
    await desktop_tray.trayManager.setIcon(icon.path,isTemplate:false);
    await desktop_tray.trayManager.setToolTip('File Share — LAN receiver');
    await desktop_tray.trayManager.setContextMenu(desktop_tray.Menu(items: [
      desktop_tray.MenuItem(key: 'show', label: 'View'),
      desktop_tray.MenuItem(key: 'exit', label: 'Exit'),
    ]));
    desktop_tray.trayManager.addListener(this);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    _trayReady = true;
    try {
      if(Platform.isWindows){
        final result=await Process.run('reg',[
          'query',_windowsRunKey,'/v','FileShare']);
        final registered=result.exitCode==0 &&
          result.stdout.toString().toLowerCase()
            .contains(Platform.resolvedExecutable.toLowerCase());
        if(registered && !result.stdout.toString().contains('--background')){
          // Migrate an old foreground startup entry without changing a user's
          // explicit opt-out; only existing enabled entries are updated.
          await setAutoStart(true);
        }
        autoStartEnabled.value=registered;
      }else{
        final agent=await _macLoginAgent();
        autoStartEnabled.value=await agent.exists();
      }
    }catch(e){debugPrint('Startup preference error: $e');}
    try {
      await localNotifier.setup(appName: 'File Share',
        shortcutPolicy: ShortcutPolicy.requireCreate);
      _notificationsReady = true;
    } catch (e) { debugPrint('Windows toast setup error: $e'); }
  }

  static const _windowsRunKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  Future<void> setAutoStart(bool value) async {
    if(Platform.isMacOS){
      final agent=await _macLoginAgent();
      if(value){
        final executable=Platform.resolvedExecutable;
        final normalized=executable.replaceAll('\\','/');
        final marker='/Contents/MacOS/';
        final index=normalized.lastIndexOf(marker);
        if(index<0 || !normalized.substring(0,index).endsWith('.app')){
          throw StateError('Install File Share as a macOS .app before enabling login startup.');
        }
        final app=normalized.substring(0,index);
        final plist=_macLoginPlist(app);
        await agent.parent.create(recursive:true);
        await agent.writeAsString(plist,flush:true);
      }else if(await agent.exists()){
        await agent.delete();
      }
      autoStartEnabled.value=value;
      return;
    }
    if(!Platform.isWindows)return;
    final args = value
      ? ['add', _windowsRunKey, '/v', 'FileShare', '/t', 'REG_SZ',
          '/d', '"' + Platform.resolvedExecutable + '" --background', '/f']
      : ['delete', _windowsRunKey, '/v', 'FileShare', '/f'];
    final result = await Process.run('reg', args);
    if (result.exitCode != 0) {
      throw ProcessException('reg', args, result.stderr.toString(), result.exitCode);
    }
    autoStartEnabled.value = value;
  }

  /// Configure login startup once and respect subsequent explicit opt-outs.
  /// macOS uses a per-user LaunchAgent; Windows uses the HKCU Run key.
  Future<void> enableDefaultStart(SharedPreferencesAsync prefs) async {
    if(!Platform.isWindows && !Platform.isMacOS)return;
    final preferenceKey=Platform.isMacOS
      ?'macos_autostart_decided':'windows_autostart_decided';
    if(await prefs.getBool(preferenceKey)==true)return;
    final executable=Platform.resolvedExecutable.toLowerCase();
    // Avoid registering Flutter debug/test binaries or an uninstalled EXE.
    final normalized=executable.replaceAll(String.fromCharCode(92),'/');
    if(normalized.contains('flutter_tester') ||
       normalized.contains('/temp/') ||
       normalized.contains('/debug/'))return;
    try {
      await setAutoStart(true);
      await prefs.setBool(preferenceKey,true);
    }catch(e){
      debugPrint('Windows autorun could not be registered: $e');
    }
  }

  Future<void> notifyReceived(LanFile file) async {
    if (!Platform.isWindows || !_notificationsReady) return;
    try {
      final notification = LocalNotification(
        title: 'File received from ' + file.peer, body: file.name);
      notification.onClick = () { unawaited(showWindow()); };
      await notification.show();
    } catch (e) { debugPrint('Windows toast error: $e'); }
  }

  Future<void> showWindow() async {
    if(!Platform.isWindows && !Platform.isMacOS)return;
    if(Platform.isMacOS){
      // Unlock native first-show suppression only for an explicit View.
      try{
        await const MethodChannel('file_share.desktop')
          .invokeMethod<void>('allowShow');
      }catch(e){debugPrint('macOS explicit window show: $e');}
    }
    await windowManager.show();
    await windowManager.maximize();
    await windowManager.focus();
  }

  @override
  void onWindowClose() {
    if (_trayReady && !_exiting) unawaited(windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() { unawaited(showWindow()); }

  @override
  void onTrayIconRightMouseDown(){
    unawaited(desktop_tray.trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(desktop_tray.MenuItem item) {
    if (item.key == 'show') unawaited(showWindow());
    if (item.key == 'exit') unawaited(exitCompletely());
  }

  Future<void> exitCompletely() async {
    if (_exiting) return;
    _exiting = true;
    // The updater cannot replace installed DLLs until the ENTIRE process,
    // including tray, LAN sockets and single-instance lock, is terminated.
    // Do not let a stalled network shutdown or window manager prevent exit.
    try { await appLan.stop().timeout(const Duration(seconds:8)); } catch (e) {
      debugPrint('LAN shutdown before exit: $e');
    }
    try { await _controlChannel?.close().timeout(const Duration(seconds:3)); } catch (_) { }
    _controlChannel = null;
    try { await _instanceLock?.unlock().timeout(const Duration(seconds:3)); } catch (_) { }
    try { await _instanceLock?.close().timeout(const Duration(seconds:3)); } catch (_) { }
    _instanceLock = null;
    try { await desktop_tray.trayManager.destroy().timeout(const Duration(seconds:3)); } catch (_) { }
    try { await windowManager.setPreventClose(false).timeout(const Duration(seconds:3)); } catch (_) { }
    try { await windowManager.destroy().timeout(const Duration(seconds:3)); } catch (_) { }
    // A hidden window can otherwise leave a live process in the system tray.
    exit(0);
  }

  /// Both platform tray icons originate from the approved bundled FS logo.
  /// No missing file_share_tray.ico asset or default Flutter icon is used.
  Future<File> _writeTrayIcon() async {
    final bytes=await rootBundle.load('assets/branding/file_share_icon.webp');
    final source=desktop_image.decodeImage(bytes.buffer.asUint8List(
      bytes.offsetInBytes,bytes.lengthInBytes));
    if(source==null)throw StateError('File Share logo could not be decoded');
    final resized=desktop_image.copyResize(source,width:64,height:64);
    final png=Uint8List.fromList(desktop_image.encodePng(resized));
    final folder=await getApplicationSupportDirectory();
    if(Platform.isMacOS){
      final file=File('${folder.path}${Platform.pathSeparator}file-share-tray.png');
      await file.writeAsBytes(png,flush:true);
      return file;
    }
    // Windows ICO containing an embedded PNG (supported since Vista).
    final header=ByteData(22);
    header.setUint16(0,0,Endian.little);
    header.setUint16(2,1,Endian.little);
    header.setUint16(4,1,Endian.little);
    header.setUint8(6,64);
    header.setUint8(7,64);
    header.setUint8(8,0);
    header.setUint8(9,0);
    header.setUint16(10,1,Endian.little);
    header.setUint16(12,32,Endian.little);
    header.setUint32(14,png.length,Endian.little);
    header.setUint32(18,22,Endian.little);
    final file=File('${folder.path}${Platform.pathSeparator}file-share-tray.ico');
    await file.writeAsBytes([...header.buffer.asUint8List(),...png],flush:true);
    return file;
  }

  Future<File> _macLoginAgent() async {
    final home=Platform.environment['HOME'];
    if(home==null||home.isEmpty)throw StateError('macOS HOME is unavailable');
    return File('$home/Library/LaunchAgents/com.fileshare.desktop.plist');
  }

  String _macLoginPlist(String appPath) {
    // XML escaping is required: an app path can contain & or quotes.
    final path=const HtmlEscape(HtmlEscapeMode.element).convert(appPath);
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.fileshare.desktop</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-gj</string>
    <string>-a</string>
    <string>$path</string>
    <string>--args</string>
    <string>--background</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>''';
  }
}

class FileShareApp extends StatefulWidget {
  const FileShareApp({
    super.key,
    this.initialMode = ThemeMode.system,
    this.offlineDefault = false,
    this.enableBackends = true,
  });
  final ThemeMode initialMode;
  final bool offlineDefault;
  final bool enableBackends;

  @override
  State<FileShareApp> createState() => _FileShareAppState();
}

class _FileShareAppState extends State<FileShareApp> with WidgetsBindingObserver {
  late ThemeMode _mode = widget.initialMode;
  Timer? _updateCheckTimer;
  bool _wasBackgrounded=false;

  @override void initState(){
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if(widget.enableBackends) {
      _updateCheckTimer=Timer.periodic(const Duration(minutes:45),(_)=>
        unawaited(FileShareUpdates.instance.check(startup:true)));
    }
    FileShareUpdates.instance.initializeVersion(
      const String.fromEnvironment('FILE_SHARE_VERSION',defaultValue:'0.1.0'),
      const int.fromEnvironment('FILE_SHARE_BUILD_NUMBER',defaultValue:1));
    if(widget.enableBackends) {
      WidgetsBinding.instance.addPostFrameCallback((_) =>
        unawaited(FileShareUpdates.instance.check(startup:true)));
    }
  }

  @override void didChangeAppLifecycleState(AppLifecycleState state){
    if(state==AppLifecycleState.paused || state==AppLifecycleState.detached)
      _wasBackgrounded=true;
    if(state==AppLifecycleState.resumed && _wasBackgrounded){
      _wasBackgrounded=false;
      FileShareUpdates.instance.startNewForegroundSession();
      if(widget.enableBackends)
        unawaited(FileShareUpdates.instance.check(startup:true));
    }
  }

  @override void dispose(){
    _updateCheckTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }


  void _setMode(ThemeMode value) {
    setState(() => _mode = value);
    SharedPreferencesAsync().setString('appearance', value.name);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'File Share',
        navigatorKey:fileShareNavigatorKey,
        scrollBehavior:const FileShareSmoothScroll(),
        builder:(context,child)=>Stack(children:[
          child??const SizedBox.shrink(),
          const FileShareUpdateBanner(),
        ]),
        debugShowCheckedModeBanner: false,
        theme: FileTheme.build(Brightness.light),
        darkTheme: FileTheme.build(Brightness.dark),
        themeMode: _mode,
        themeAnimationDuration: const Duration(milliseconds: 280),
        themeAnimationCurve: Curves.easeInOutCubic,
        home: widget.offlineDefault
            ? DashboardPage(mode: _mode, onMode: _setMode,
                enableBackends: widget.enableBackends)
            : WelcomePage(mode: _mode, onMode: _setMode),
      );
}

class FileTheme {
  // Product palette derived from the approved blue/teal raised-surface design.
  // Retained identifiers keep existing tool widgets using the same palette.
  static const pink = Color(0xFF087F87);
  static const violet = Color(0xFF5867A2);
  static const night = Color(0xFF000000);
  static const turquoise = Color(0xFF009A9C);

  static bool dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color surface(BuildContext context) =>
      dark(context) ? const Color(0xFF111318) : const Color(0xFFE7F1FA);

  static Color foreground(BuildContext context) =>
      dark(context) ? const Color(0xFFF5F6FF) : const Color(0xFF17263A);

  static Color muted(BuildContext context) =>
      dark(context) ? const Color(0xFFB8C1D0) : const Color(0xFF617086);

  static Gradient background(BuildContext context) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: dark(context)
            ? const [Color(0xFF000000), Color(0xFF06080B), Color(0xFF000000)]
            : const [Color(0xFFEAF3FB), Color(0xFFDCEBF8), Color(0xFFCFE3F3)],
      );

  static Gradient dashboardBackground(BuildContext context) => LinearGradient(
    begin:Alignment.topCenter,end:Alignment.bottomCenter,
    colors:dark(context)
      ?const [Color(0xFF000000),Color(0xFF05070A),Color(0xFF000000)]
      :const [Color(0xFFEAF4FC),Color(0xFFDCECF9),Color(0xFFCFE4F4)],
  );

  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: turquoise,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: dark ? night : const Color(0xFFDFEDF8),
      pageTransitionsTheme: const PageTransitionsTheme(builders:{
        TargetPlatform.android:FileSharePageTransitions(),
        TargetPlatform.iOS:FileSharePageTransitions(),
        TargetPlatform.windows:FileSharePageTransitions(),
        TargetPlatform.macOS:FileSharePageTransitions(),
        TargetPlatform.linux:FileSharePageTransitions(),
      }),
      appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF111318) : const Color(0xFFE5F1FB),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 17,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}

class AppearanceButton extends StatelessWidget {
  const AppearanceButton({
    super.key,
    required this.mode,
    required this.onChange,
    this.compact=false,
  });
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChange;
  final bool compact;

  @override
  Widget build(BuildContext context) => PopupMenuButton<ThemeMode>(
        tooltip: 'Choose light or dark appearance',
        onSelected: (value) {
          HapticFeedback.selectionClick();
          onChange(value);
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: ThemeMode.light,
            child: Row(children: [
              Icon(Icons.light_mode_outlined),
              SizedBox(width: 12),
              Text('Light mode'),
            ]),
          ),
          const PopupMenuItem(
            value: ThemeMode.dark,
            child: Row(children: [
              Icon(Icons.dark_mode_outlined),
              SizedBox(width: 12),
              Text('Dark mode'),
            ]),
          ),
          const PopupMenuItem(
            value: ThemeMode.system,
            child: Row(children: [
              Icon(Icons.brightness_auto_outlined),
              SizedBox(width: 12),
              Text('Follow system'),
            ]),
          ),
        ],
        child: Semantics(
          label: 'Change appearance',
          button: true,
          child: Container(
            width: compact ? 36 : 46,
            height: compact ? 38 : 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: compact ? Colors.transparent
                : FileTheme.surface(context).withValues(alpha: .9),
            ),
            child: Icon(
              FileTheme.dark(context)
                  ? Icons.dark_mode_rounded
                  : Icons.light_mode_rounded,
              color: FileTheme.violet,
            ),
          ),
        ),
      );
}

// Motion automatically advances at the device's available display refresh
// rate. Keep the animated properties cheap to paint and respect user settings.
class FileSharePageTransitions extends PageTransitionsBuilder {
  const FileSharePageTransitions();
  @override
  Widget buildTransitions<T>(PageRoute<T> route,BuildContext context,
      Animation<double> animation,Animation<double> secondaryAnimation,
      Widget child) {
    if(MediaQuery.disableAnimationsOf(context))return child;
    final progress=CurvedAnimation(parent:animation,curve:Curves.easeOutCubic,
      reverseCurve:Curves.easeInCubic);
    return FadeTransition(opacity:progress,child:SlideTransition(
      position:Tween<Offset>(begin:const Offset(.025,.012),
        end:Offset.zero).animate(progress),
      child:RepaintBoundary(child:child)));
  }
}

// Preserve each operating system's natural gesture physics and avoid costly
// platform overscroll glow paints on every scroll update.
class FileShareSmoothScroll extends MaterialScrollBehavior {
  const FileShareSmoothScroll();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    switch(getPlatform(context)) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return const BouncingScrollPhysics(parent:AlwaysScrollableScrollPhysics());
      default:
        return const ClampingScrollPhysics(parent:AlwaysScrollableScrollPhysics());
    }
  }
  @override
  Widget buildOverscrollIndicator(BuildContext context,Widget child,
      ScrollableDetails details)=>child;
}

Route<T> fadePage<T>(Widget child) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 230),
      reverseTransitionDuration: const Duration(milliseconds: 190),
      pageBuilder: (_, _, _) => child,
      transitionsBuilder: (_, animation, __, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(.025, .012),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );

class RootBackGuard extends StatefulWidget {
  const RootBackGuard({super.key, required this.child});
  final Widget child;
  @override
  State<RootBackGuard> createState() => _RootBackGuardState();
}

class _RootBackGuardState extends State<RootBackGuard> {
  DateTime? _lastBack;
  int _backCount = 0;

  Future<void> _handle(bool didPop) async {
    if (didPop || !Platform.isAndroid) return;
    final now = DateTime.now();
    if (_lastBack == null ||
        now.difference(_lastBack!) > const Duration(seconds: 2)) {
      _backCount = 0;
    }
    _lastBack = now;
    _backCount++;
    if (_backCount < 3) {
      FileShareTopNotice.show(context,'Press Back ${3-_backCount} more time(s) to exit');
      return;
    }
    _backCount = 0;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close File Share?'),
        content: const Text('Are you sure you want to close this app?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, close'),
          ),
        ],
      ),
    );
    if (result == true) SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) => _handle(didPop),
        child: widget.child,
      );
}

class AppLogo extends StatelessWidget {
  const AppLogo({super.key,this.size=48});
  final double size;
  @override Widget build(BuildContext context)=>ClipRRect(
    borderRadius:BorderRadius.circular(size*.22),
    child:Image.asset('assets/branding/file_share_icon.webp',
      width:size,height:size,fit:BoxFit.cover,
      filterQuality:FilterQuality.medium,
      semanticLabel:'File Share logo'),
  );
}

class WelcomePage extends StatelessWidget {
  const WelcomePage({
    super.key,
    required this.mode,
    required this.onMode,
  });
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 680;
    return RootBackGuard(
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(gradient: FileTheme.background(context)),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 56 : 22,
                    vertical: 24,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        const AppLogo(),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('File Share',
                                  style: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w800,
                                    color: FileTheme.foreground(context),
                                  )),
                              Text('Fast file transfer',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: FileTheme.muted(context),
                                  )),
                            ],
                          ),
                        ),
                        AppearanceButton(mode: mode, onChange: onMode),
                      ]),
                      SizedBox(height: wide ? 40 : 60),
                      Center(
                        child: Container(
                          width: 118,
                          height: 118,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [
                              FileTheme.pink, FileTheme.violet,
                            ]),
                            borderRadius: BorderRadius.circular(34),
                            boxShadow: [
                              BoxShadow(
                                color: FileTheme.pink.withValues(alpha: .19),
                                blurRadius: 40,
                                offset: const Offset(0, 15),
                              ),
                            ],
                          ),
                          child: const Icon(Icons.send_rounded,
                              color: Colors.white, size: 58),
                        ),
                      ),
                      const SizedBox(height: 30),
                      Text('Your files. All your devices.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: wide ? 33 : 28,
                            height: 1.18,
                            fontWeight: FontWeight.w800,
                            color: FileTheme.foreground(context),
                          )),
                      const SizedBox(height: 12),
                      Text(
                        'Share over local Wi-Fi. Login only to enable your personal QR cloud.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: FileTheme.muted(context),
                        ),
                      ),
                      const SizedBox(height: 40),
                      ActionCard(
                        icon: Icons.person_outline_rounded,
                        title: 'Login / Create Account',
                        subtitle: 'Personal cloud, permanent QR and guest files',
                        primary: true,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          Navigator.push(
                            context,
                            fadePage(LoginPage(mode: mode, onMode: onMode)),
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                      ActionCard(
                        icon: Icons.wifi_rounded,
                        title: 'Skip to Offline LAN',
                        subtitle: 'Local transfer without login or internet',
                        onTap: () {
                          HapticFeedback.selectionClick();
                          SharedPreferencesAsync().setBool('offline_start', true);
                          Navigator.pushReplacement(
                            context,
                            fadePage(DashboardPage(mode: mode, onMode: onMode)),
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                      Text('No account is required for local sharing.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: FileTheme.muted(context),
                          )),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Material(
        color: FileTheme.surface(context).withValues(alpha: .88),
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: primary
                    ? FileTheme.pink.withValues(alpha: .4)
                    : FileTheme.violet.withValues(alpha: .12),
              ),
            ),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (primary ? FileTheme.pink : FileTheme.violet)
                      .withValues(alpha: .11),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon,
                    color: primary ? FileTheme.pink : FileTheme.violet),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: FileTheme.foreground(context),
                        )),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: FileTheme.muted(context),
                        )),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ]),
          ),
        ),
      );
}

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.mode,
    required this.onMode,
  });
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _key=GlobalKey<FormState>();
  final _email=TextEditingController();
  final _password=TextEditingController();
  final _workerUrl=TextEditingController();
  bool _register=false,_hidden=true,_busy=false;
  bool _personalAccountRegistered=false;
  bool _manualWorkerLogin=false;
  String? _error;

  @override void initState(){
    super.initState();
    final cloud=PersonalCloud.instance;
    _workerUrl.text=cloud.workerOrigin??'';
    _register=cloud.canRegisterAccount && cloud.accountEmail==null && !cloud.signedIn;
    _email.text=cloud.accountEmail??'';
  }
  @override void dispose(){
    _email.dispose();_password.dispose();_workerUrl.dispose();
    super.dispose();
  }
  Future<void> _enterDashboard()async{
    await SharedPreferencesAsync().setBool('offline_start',true);
    if(!mounted)return;
    Navigator.of(context).pushAndRemoveUntil(fadePage(
      DashboardPage(mode:widget.mode,onMode:widget.onMode)),(_)=>false);
  }

  Future<void> _submit()async{
    if(_busy||!(_key.currentState?.validate()??false))return;
    final cloud=PersonalCloud.instance;
    final directory=AccountDirectory.instance;
    setState((){_busy=true;_error=null;});
    try{
      if(_register){
        if(!_personalAccountRegistered && !cloud.signedIn){
          await cloud.registerAccount(_email.text,_password.text);
          _personalAccountRegistered=true;
        }
        if(directory.enabled) {
          await cloud.linkAccountDirectory();
        }
      }else if(directory.enabled && !_manualWorkerLogin){
        // Second device: only email/password. Locate Worker automatically.
        await cloud.loginByEmail(_email.text,_password.text);
      }else{
        // Existing installations can migrate their personal Worker once.
        await cloud.loginAccount(_workerUrl.text,_email.text,_password.text);
        if(directory.enabled && _manualWorkerLogin) {
          await cloud.linkAccountDirectory();
        }
      }
      await _enterDashboard();
    }catch(e){
      if(mounted)setState(()=>_error=e.toString().replaceFirst('Bad state: ',''));
    }finally{if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _linkExistingAccount()async{
    if(_busy)return;
    setState((){_busy=true;_error=null;});
    try{await PersonalCloud.instance.linkAccountDirectory();
      if(mounted) FileShareTopNotice.show(context,'Account linked to your personal Cloudflare Worker');
    }
    catch(e){if(mounted)setState(()=>_error=e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }

  void _openCloudSetup(){
    Navigator.push(context,fadePage(
      CloudConnectPage(mode:widget.mode,onMode:widget.onMode)
    )).then((_){
      if(mounted)setState((){
        _workerUrl.text=PersonalCloud.instance.workerOrigin??'';
        _register=PersonalCloud.instance.canRegisterAccount &&
          PersonalCloud.instance.accountEmail==null;
      });
    });
  }
  @override
  Widget build(BuildContext context)=>Scaffold(
    body:Container(
      decoration:BoxDecoration(gradient:FileTheme.background(context)),
      child:SafeArea(child:Column(children:[
        Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:8),
          child:Row(children:[
            IconButton(tooltip:'Back',onPressed:()=>Navigator.maybePop(context),
              icon:const Icon(Icons.arrow_back_rounded)),
            Expanded(child:Text('File Share Account',
              style:Theme.of(context).textTheme.titleLarge)),
            AppearanceButton(mode:widget.mode,onChange:widget.onMode),
          ])),
        Expanded(child:Center(child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:520),
          child:ListView(shrinkWrap:true,
            padding:const EdgeInsets.all(24),children:[
              const Center(child:AppLogo(size:68)),
              const SizedBox(height:22),
              Text(_register?'Create your account':'Welcome back',
                textAlign:TextAlign.center,style:TextStyle(
                  fontSize:28,fontWeight:FontWeight.w800,
                  color:FileTheme.foreground(context))),
              const SizedBox(height:9),
              Text('Use email and password on your linked devices. '
                'Your first personal cloud is bound to this account; '
                'email ownership is not verified.',
                textAlign:TextAlign.center,
                style:TextStyle(color:FileTheme.muted(context),height:1.4)),
              const SizedBox(height:24),
              Form(key:_key,child:Column(children:[
                if((!AccountDirectory.instance.enabled || _manualWorkerLogin) && !_register)...[
                  TextFormField(
                    controller:_workerUrl,enabled:!_register&&!_busy,
                    keyboardType:TextInputType.url,
                    decoration:const InputDecoration(
                      labelText:'Personal Worker URL',
                      hintText:'https://name.account.workers.dev',
                      prefixIcon:Icon(Icons.cloud_outlined)),
                    validator:(value)=>_register?null:
                      ((value??'').contains('.workers.dev')?null:
                        'Enter your own Worker URL or connect Cloudflare first'),
                  ),
                  const SizedBox(height:12),
                ],
                TextFormField(
                  controller:_email,enabled:!_busy,
                  keyboardType:TextInputType.emailAddress,
                  autofillHints:const [AutofillHints.email],
                  decoration:const InputDecoration(labelText:'Email address',
                    prefixIcon:Icon(Icons.mail_outline_rounded)),
                  validator:(value)=>RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                    .hasMatch(value?.trim()??'')?null:'Enter valid email'),
                const SizedBox(height:12),
                TextFormField(controller:_password,
                  obscureText:_hidden,enabled:!_busy,
                  autofillHints:[_register?AutofillHints.newPassword:
                    AutofillHints.password],
                  decoration:InputDecoration(
                    labelText:'Password (10+ characters)',
                    prefixIcon:const Icon(Icons.lock_outline_rounded),
                    suffixIcon:IconButton(
                      tooltip:_hidden?'Show password':'Hide password',
                      onPressed:()=>setState(()=>_hidden=!_hidden),
                      icon:Icon(_hidden?Icons.visibility_outlined:
                        Icons.visibility_off_outlined))),
                  validator:(value)=>(value??'').length>=10?null:
                    'Use at least 10 characters'),
                const SizedBox(height:16),
                if(_register&&!PersonalCloud.instance.canRegisterAccount)
                  Padding(padding:const EdgeInsets.only(bottom:12),
                    child:Text('First connect or provision your personal '
                      'Cloudflare Worker to register the account securely.',
                      textAlign:TextAlign.center,
                      style:TextStyle(color:FileTheme.muted(context)))),
                if(_error!=null)Padding(
                  padding:const EdgeInsets.only(bottom:10),
                  child:Text(_error!,textAlign:TextAlign.center,
                    style:const TextStyle(color:Colors.deepOrange))),
                if(_register && _personalAccountRegistered &&
                   PersonalCloud.instance.signedIn) ...[
                  const SizedBox(height:8),
                  OutlinedButton(
                    onPressed:_busy?null:_enterDashboard,
                    child:const Text('Continue on this device (directory linking pending)')),
                  const SizedBox(height:8),
                ],
                SizedBox(height:52,width:double.infinity,
                  child:FilledButton(
                    onPressed:_busy?null:_submit,
                    child:_busy?const SizedBox(width:22,height:22,
                      child:CircularProgressIndicator(strokeWidth:2)):
                      Text(_register?'Create account':'Login'))),
                const SizedBox(height:11),
                TextButton(
                  onPressed:_busy?null:()=>setState(()=>_register=!_register),
                  child:Text(_register?'Already registered? Login':
                    'New here? Create account')),
                OutlinedButton.icon(
                  onPressed:_busy?null:_openCloudSetup,
                  icon:const Icon(Icons.cloud_sync_outlined),
                  label:const Text('Set up or connect personal Cloudflare')),
                if(AccountDirectory.instance.enabled && !_register)
                  TextButton(
                    onPressed:_busy?null:()=>setState(()=>
                      _manualWorkerLogin=!_manualWorkerLogin),
                    child:Text(_manualWorkerLogin
                      ? 'Use automatic email-only login'
                      : 'Existing Worker? Link it once')),
                if(AccountDirectory.instance.enabled &&
                   PersonalCloud.instance.signedIn && !_register)
                  TextButton.icon(
                    onPressed:_busy?null:_linkExistingAccount,
                    icon:const Icon(Icons.link_rounded),
                    label:const Text('Link this account to its personal cloud')),
              ])),
              const SizedBox(height:15),
              Text(AccountDirectory.instance.enabled
                ? 'Once this account is linked to its first personal cloud, '
                  'Android and Windows can sign in with email and password. '
                  'The email address itself is not verified.'
                : 'Email-only sign-in needs the official File Share directory '
                  'deployment. Until configured, use your Worker URL too.',
                textAlign:TextAlign.center,
                style:TextStyle(fontSize:12,color:FileTheme.muted(context))),
            ])))),
      ])),
    ),
  );
}

/* Full UI design preview: all transfer items, counts, progress and devices
   below are sample-only. There is no actual network, upload or delete action. */

class MockTransfer {
  const MockTransfer(this.title, this.source, this.size, this.time,
      {this.sent = false, this.group = false, this.video = false,
       this.document = false, this.art = 0});
  final String title, source, size, time;
  final bool sent, group, video, document;
  final int art;
}

const mockTransfers = <MockTransfer>[
  MockTransfer('4 Photos (Group)', 'From Android B · Offline LAN',
      '16.72 MB', '12:59 PM', group: true),
  MockTransfer('nature_view.jpg', 'To Windows PC · Offline LAN',
      '1.93 MB', '06:37 PM', sent: true),
  MockTransfer('2026111_report.pdf', 'From Android device · Offline LAN',
      '3.94 MB', '01:02 PM', document: true),
  MockTransfer('demo_video.mp4', 'To Android C · Offline LAN',
      '377.6 KB', '07:44 PM', sent: true, video: true, art: 2),
  MockTransfer('travel_clip.mp4', 'From Guest mobile · Guest QR · Online',
      '4.55 MB', '02:18 PM', video: true, art: 1),
];

class DesignPanel extends StatelessWidget {
  const DesignPanel({super.key, required this.child,
    this.padding = const EdgeInsets.all(16),this.dashboard=false});
  final Widget child;
  final EdgeInsets padding;
  final bool dashboard;

  @override
  Widget build(BuildContext context) {
    final dark=FileTheme.dark(context);
    return Container(
      padding:padding,
      decoration:BoxDecoration(
        gradient:LinearGradient(
          begin:Alignment.topLeft,end:Alignment.bottomRight,
          colors:dark
            ? const [Color(0xFF1C4654),Color(0xFF113140),Color(0xFF092430)]
            : dashboard
              ? const [Color(0xFFEAF8FC),Color(0xFFD8EFF7),Color(0xFFCDEAF5)]
              : const [Color(0xFFE9F5F9),Color(0xFFD3E7EF),Color(0xFFB9D4E1)],
        ),
        border:Border.all(
          color:dark?const Color(0xFF468895):const Color(0xFFF6FDFF),
          width:1.25),
        borderRadius:BorderRadius.circular(24),
        boxShadow:[
          BoxShadow(color:Colors.black.withValues(alpha:dark ? .46 : .19),
            offset:const Offset(0,9),blurRadius:18,spreadRadius:-3),
          BoxShadow(color:const Color(0xFF6AA3B2).withValues(alpha:dark ? .15 : .25),
            offset:const Offset(-2,-2),blurRadius:8),
        ],
      ),
      child:child,
    );
  }
}

class DesignTag extends StatelessWidget {
  const DesignTag(this.text, {super.key, this.received = false});
  final String text;
  final bool received;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 9),
    decoration: BoxDecoration(
      color: (received ? FileTheme.pink : FileTheme.violet).withValues(alpha: .13),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Text(text, style: TextStyle(
      fontWeight: FontWeight.w800, fontSize: 10,
      color: received ? FileTheme.pink : FileTheme.violet,
    )),
  );
}

// Visual button only: no file actions can run from this preview.
class DesignAction extends StatelessWidget {
  const DesignAction(this.icon, this.label, {super.key, this.size = 32});
  final IconData icon;
  final String label;
  final double size;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: label + ' · not enabled',
    child: Semantics(
      label: label + ' (disabled)',
      enabled: false,
      button: true,
      child: Container(
        width: size, height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: FileTheme.pink.withValues(alpha: .11),
        ),
        child: Icon(icon, color: FileTheme.pink.withValues(alpha: .80),
          size: size * .55),
      ),
    ),
  );
}

class DemoLandscape extends StatelessWidget {
  const DemoLandscape({super.key, this.variant = 0, this.video = false});
  final int variant;
  final bool video;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Stack(fit: StackFit.expand, children: [
      CustomPaint(painter: DemoLandscapePainter(variant)),
      if (video)
        Center(child: Container(width: 38, height: 38,
          decoration: BoxDecoration(shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: .38),
            border: Border.all(color: Colors.white70)),
          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 27))),
      if (video)
        Positioned(bottom: 4, right: 5,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.black54,
              borderRadius: BorderRadius.circular(6)),
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              child: Text('00:15', style: TextStyle(color: Colors.white, fontSize: 10))))),
    ]),
  );
}

class DemoLandscapePainter extends CustomPainter {
  const DemoLandscapePainter(this.variant);
  final int variant;

  @override
  void paint(Canvas canvas, Size s) {
    final palettes = [
      [const Color(0xFFF19ABA), const Color(0xFF8992D1), const Color(0xFF3F518B)],
      [const Color(0xFFDA9BBF), const Color(0xFF77B0B1), const Color(0xFF317D79)],
      [const Color(0xFFF5B38C), const Color(0xFFB77EA6), const Color(0xFF4B5B9B)],
      [const Color(0xFF9FCF92), const Color(0xFF6CABB2), const Color(0xFF315D81)],
    ];
    final colors = palettes[variant % palettes.length];
    canvas.drawRect(Offset.zero & s,
      Paint()..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: colors,
      ).createShader(Offset.zero & s));
    canvas.drawCircle(Offset(s.width * .73, s.height * .25),
      s.height * .11, Paint()..color = const Color(0xFFFFE6CC));
    final mountains = Path()
      ..moveTo(0, s.height * .72)
      ..lineTo(s.width * .19, s.height * .27)
      ..lineTo(s.width * .37, s.height * .62)
      ..lineTo(s.width * .59, s.height * .23)
      ..lineTo(s.width * .80, s.height * .53)
      ..lineTo(s.width, s.height * .40)
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(mountains, Paint()..color = colors[2].withValues(alpha: .74));
    final nearest = Path()
      ..moveTo(0, s.height * .82)
      ..lineTo(s.width * .23, s.height * .61)
      ..lineTo(s.width * .48, s.height * .76)
      ..lineTo(s.width * .77, s.height * .55)
      ..lineTo(s.width, s.height * .80)
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(nearest, Paint()..color = const Color(0xFF25355F).withValues(alpha: .48));
    canvas.drawRect(Rect.fromLTWH(0, s.height * .85, s.width, s.height * .15),
      Paint()..color = colors[1].withValues(alpha: .56));
  }

  @override
  bool shouldRepaint(covariant DemoLandscapePainter oldDelegate) =>
      oldDelegate.variant != variant;
}

class DesignFileCard extends StatelessWidget {
  const DesignFileCard({super.key, required this.transfer});
  final MockTransfer transfer;

  Widget _actions(bool receiving) => Wrap(
    spacing: 5, runSpacing: 5,
    children: [
      if (receiving) const DesignAction(Icons.download_rounded, 'Download'),
      const DesignAction(Icons.delete_outline_rounded, 'Delete'),
      const DesignAction(Icons.ios_share_rounded, 'Share externally'),
      const DesignAction(Icons.auto_fix_high_rounded, 'Send to toolbox'),
    ],
  );

  Widget _footer(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      Text(transfer.time + ' · sample', style: TextStyle(
        color: FileTheme.muted(context), fontSize: 10)),
      const SizedBox(width: 6),
      Icon(transfer.sent ? Icons.done_all_rounded : Icons.done_rounded,
        color: FileTheme.violet, size: 18),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final sent = transfer.sent;
    final w=MediaQuery.sizeOf(context).width;
    final maxWidth=w>740?(sent?565.0:610.0):w*(sent ? .75 : .86);
    return Align(
      alignment: sent ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient:LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,
            colors:FileTheme.dark(context)
              ?(sent?const [Color(0xFF236EAA),Color(0xFF123F72)]
                  :const [Color(0xFFB08A27),Color(0xFF705514)])
              :(sent?const [Color(0xFFE2F4FF),Color(0xFF8DCBFF)]
                  :const [Color(0xFFFFF6D5),Color(0xFFFFD65C)])),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(24), topRight: const Radius.circular(23),
            bottomLeft: Radius.circular(sent ? 23 : 6),
            bottomRight: Radius.circular(sent ? 6 : 23),
          ),
          border:Border.all(color:FileTheme.dark(context)
              ?const Color(0xFF43949B):Colors.white.withValues(alpha:.90),width:1.3),
          boxShadow:[BoxShadow(color:Colors.black.withValues(alpha:.24),
            blurRadius:14,offset:const Offset(0,8))],
        ),
        child: transfer.group ? _group(context) : _single(context),
      ),
    );
  }

  Widget _title(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(transfer.title, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800,
            color: FileTheme.foreground(context))),
        const SizedBox(height: 3),
        Text(transfer.size + ' · ' + transfer.source,
          maxLines: 3, style: TextStyle(fontSize: 11,
            height: 1.25, color: FileTheme.muted(context))),
      ])),
      const SizedBox(width: 5),
      DesignTag(transfer.sent ? 'Sent' : 'Received', received: !transfer.sent),
    ],
  );

  Widget _group(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _title(context),
      const SizedBox(height: 12),
      GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        itemCount: 4,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: MediaQuery.sizeOf(context).width < 390 ? .76 : 1.13,
        ),
        itemBuilder: (context, i) => Column(children: [
          Expanded(child: SizedBox(width: double.infinity,
            child: DemoLandscape(variant: i))),
          const SizedBox(height: 5),
          _actions(true),
        ]),
      ),
      const SizedBox(height: 11),
      Divider(height: 12, color: FileTheme.violet.withValues(alpha: .18)),
      Row(children: [
        const Icon(Icons.download_for_offline_outlined,
          color: FileTheme.pink, size: 21),
        const SizedBox(width: 7),
        const Expanded(child: Text('Download All · 4 files · 16.72 MB',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
            color: FileTheme.pink))),
        const DesignAction(Icons.delete_sweep_outlined, 'Delete entire group'),
      ]),
      _footer(context),
    ],
  );

  Widget _single(BuildContext context) => Column(children: [
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 104, height: 100,
        child: transfer.document
          ? DecoratedBox(decoration: BoxDecoration(
                color: FileTheme.violet.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.picture_as_pdf_outlined,
                color: FileTheme.pink, size: 45))
          : DemoLandscape(variant: transfer.art, video: transfer.video)),
      const SizedBox(width: 10),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_title(context), const SizedBox(height: 8),
          _actions(!transfer.sent)],
      )),
    ]),
    _footer(context),
  ]);
}


class PendingBatch {
  PendingBatch(this.id, this.sources, this.labels, this.sizes);
  final String id;
  final List<File> sources;
  final List<String> labels;
  final List<int> sizes;
}

/// This singleton stays active while the user navigates between pages.
final LanEngine appLan = LanEngine();


/// Central tap policy for every LAN/QR/Cart/History card.
/// Pictures are only previewed; PDF opens File Share's own Android editor.
class FileCardOpenRouter {
  static bool isPdf(String name) => name.toLowerCase().endsWith('.pdf');
  static bool isDocx(String name) => name.toLowerCase().endsWith('.docx');
  static bool isImage(String name) {
    final lower=name.toLowerCase();
    return ['.jpg','.jpeg','.png','.webp','.gif','.bmp','.heic']
      .any(lower.endsWith);
  }

  static Future<bool> openEditor(
    BuildContext context,String path,String name) async {
    if(FileShareDocEngine.canEdit(name) ||
      (FileShareDocEngine.canView(name) &&
        !isImage(name) && (!isPdf(name)||Platform.isWindows))){
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder:(_)=>FileShareDocPage(
          sourcePath:path,sourceName:name)));
      return true;
    }
    if (!isPdf(name))return false;
    if (Platform.isIOS) {
      try {
        await const MethodChannel('file_share.ios_pdf').invokeMethod<void>(
          'open',{'path':path});
      } on PlatformException catch(e) {
        if(context.mounted){
          FileShareTopNotice.show(context,'iPhone PDF editor could not open: ${e.message ?? e.code}');
        }
      }
      return true;
    }
    if (!Platform.isAndroid) {
      await showDialog<void>(context:context,builder:(dialog)=>AlertDialog(
        title:const Text('PDF tools not available on Windows'),
        content:const Text('These tools are available on Android and iPhone.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(dialog),
          child:const Text('OK'))]));
      return true;
    }
    try{
      final theme=Theme.of(context).brightness==Brightness.dark?'dark':'light';
      final pdfPath=path;
      if(!context.mounted)return true;
      await const MethodChannel('file_share.native').invokeMethod<void>(
        'openUpstreamPdfTools',{
          'path':pdfPath,
          'theme':theme,
        });
    }catch(e){
      if(context.mounted)FileShareTopNotice.show(context,'Cannot open this document in PDF Tools: $e');
    }
    return true;
  }
}

/// Real file preview. Uses a zoomable full-screen image and the same actions
/// as the file card; no duplicate upload is initiated from here.
class FullScreenFilePreview extends StatelessWidget {
  const FullScreenFilePreview({super.key, required this.file,
    required this.onSave, required this.onDelete, required this.onShare,
    required this.onTools});
  final LanFile file;
  final Future<void> Function(LanFile) onSave, onDelete, onShare, onTools;

  bool get isPicture => FileCardOpenRouter.isImage(file.name);

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(file.name,maxLines:1,overflow:TextOverflow.ellipsis),
    ),
    body:SafeArea(child:Column(children:[
      Expanded(child:Center(
        child:isPicture
          ? InteractiveViewer(
              minScale:.8,maxScale:5,
              child:Image.file(File(file.path),
                fit:BoxFit.contain,
                errorBuilder:(_,__,___)=>const Icon(
                  Icons.broken_image_outlined,size:80,color:Colors.white70)),
            )
          : Column(mainAxisAlignment:MainAxisAlignment.center,children:[
              const Icon(Icons.insert_drive_file_outlined,
                color:Colors.white,size:92),
              const SizedBox(height:12),
              Text(file.name,style:const TextStyle(color:Colors.white)),
              const SizedBox(height:6),
              Text(_formatBytes(file.size),
                style:const TextStyle(color:Colors.white70)),
            ]),
      )),
      Container(
        padding:const EdgeInsets.symmetric(horizontal:12,vertical:9),
        color:const Color(0xFF20172F),
        child:Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:[
          if(file.incoming)
            IconButton(
              tooltip:'Download file',
              onPressed:file.state==TransferState.delivered
                ?()=>onSave(file):null,
              icon:const Icon(Icons.download_rounded,color:Colors.white)),
          IconButton(
            tooltip:'Delete file',
            onPressed:()async{
              await onDelete(file);
              if(context.mounted)Navigator.pop(context);
            },
            icon:const Icon(Icons.delete_outline_rounded,color:Colors.white)),
          IconButton(
            tooltip:'Share to another app',
            onPressed:File(file.path).existsSync() &&
              (!file.incoming || file.state==TransferState.delivered)
              ?()=>onShare(file):null,
            icon:const Icon(Icons.ios_share_rounded,color:Colors.white)),
          IconButton(
            tooltip:'Open in Tools',
            onPressed:File(file.path).existsSync()?()=>onTools(file):null,
            icon:const Icon(Icons.auto_fix_high_rounded,color:Colors.white)),
        ]),
      ),
    ])),
  );
}

/// Every supported file goes through the same searchable Toolbox catalog.
/// Choosing Image Editing carries the selected image straight into the editor.
class SelectedFileToolsPage extends StatelessWidget {
  const SelectedFileToolsPage({super.key,required this.file});
  final LanFile file;
  @override
  Widget build(BuildContext context)=>FileShareToolboxPage(
    sourcePath:file.path,sourceName:file.name);
}


/* Compact, direction-aware transfer bubble used by LAN and Guest QR.
   Draw the side tail with the card itself so it scales on both platforms. */
class TransferBubble extends StatelessWidget {
  const TransferBubble({super.key,required this.incoming,required this.child,
    this.textOnly=false});
  final bool incoming;
  final Widget child;
  final bool textOnly;

  @override
  Widget build(BuildContext context) {
    final dark=FileTheme.dark(context);
    final fill=dark
        ? (incoming?const Color(0xFF94721A):const Color(0xFF14517F))
        : (incoming?const Color(0xFFFFDC72):const Color(0xFF9DD7FF));
    final accent=incoming?FileTheme.violet:FileTheme.turquoise;
    return LayoutBuilder(builder:(context,constraints){
      final width=constraints.hasBoundedWidth
        ?constraints.maxWidth:MediaQuery.sizeOf(context).width;
      final compact=width<760;
      // The file cards use most of the content width, with opposite gutters.
      final cardWidth=compact
        ?width*(textOnly ? .85 : (incoming ? .91 : .895))
        :(textOnly?490.0:(incoming?610.0:565.0));
      return Align(
        alignment:incoming?Alignment.centerLeft:Alignment.centerRight,
        child:SizedBox(width:cardWidth,
          child:Padding(padding:const EdgeInsets.symmetric(vertical:10),
            child:CustomPaint(
              painter:_TransferBubblePainter(incoming,fill,accent,dark),
              child:Padding(
                padding:EdgeInsets.fromLTRB(incoming?16:13,
                  textOnly?8:12,incoming?13:16,textOnly?8:12),
                child:child),
            ),
          ),
        ),
      );
    });
  }
}

class _TransferBubblePainter extends CustomPainter {
  const _TransferBubblePainter(this.incoming,this.fill,this.accent,this.dark);
  final bool incoming;
  final Color fill,accent;
  final bool dark;

  @override
  void paint(Canvas canvas,Size size) {
    // Received tail points left; sent tail points right.
    final left=incoming?13.0:0.0;
    final right=incoming?size.width:size.width-13.0;
    final rect=RRect.fromRectAndRadius(
      Rect.fromLTRB(left,0,right,size.height),const Radius.circular(21));
    final path=Path()..addRRect(rect);
    final mid=size.height>95?52.0:size.height*.35;
    if(incoming) {
      path.moveTo(left+1,mid-12);
      path.lineTo(0,mid);
      path.lineTo(left+1,mid+12);
    }else{
      path.moveTo(right-1,mid-12);
      path.lineTo(size.width,mid);
      path.lineTo(right-1,mid+12);
    }
    path.close();
    // Raised 3D depth, subtle bevel and cool top-left highlight.
    canvas.drawShadow(path,Colors.black.withValues(alpha:dark ? .46 : .23),13,false);
    canvas.drawShadow(path,accent.withValues(alpha:dark ? .18 : .19),6,false);
    final gradient=LinearGradient(
      begin:Alignment.topLeft,end:Alignment.bottomRight,
      colors:[
        Color.lerp(fill,Colors.white,dark ? .08 : .37)!,
        fill,
        Color.lerp(fill,Colors.black,dark ? .15 : .06)!,
      ]);
    canvas.drawPath(path,Paint()..shader=gradient.createShader(
      Rect.fromLTWH(0,0,size.width,size.height)));
    canvas.drawPath(path,Paint()
      ..style=PaintingStyle.stroke
      ..strokeWidth=1.5
      ..color=dark?const Color(0xFFDFE5FF):const Color(0xFFFFFFFF));
  }

  @override
  bool shouldRepaint(covariant _TransferBubblePainter old)=>
    old.incoming!=incoming||old.fill!=fill||old.accent!=accent||old.dark!=dark;
}

class TransferCardActions extends StatelessWidget {
  const TransferCardActions({super.key,required this.actions});
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder:(context,constraints){
      if(actions.isEmpty)return const SizedBox.shrink();
      final available=constraints.hasBoundedWidth
        ?constraints.maxWidth:actions.length*44.0+7*(actions.length-1);
      final gap=available<175?3.0:7.0;
      final buttonWidth=((available-gap*(actions.length-1))/actions.length)
        .clamp(24.0,44.0).toDouble();
      return Align(alignment:Alignment.center,
        child:Row(mainAxisSize:MainAxisSize.min,
        children:[
        for(var i=0;i<actions.length;i++)...[
        if(i>0)SizedBox(width:gap),
        Container(
          width:buttonWidth,height:40,
          decoration:BoxDecoration(
            gradient:LinearGradient(
              begin:Alignment.topLeft,end:Alignment.bottomRight,
              colors:FileTheme.dark(context)
                ?const [Color(0xFF245768),Color(0xFF103A47)]
                :const [Color(0xFFF0FCFF),Color(0xFFBCE8EC)]),
            borderRadius:BorderRadius.circular(15),
            border:Border.all(
              color:FileTheme.dark(context)
                ?const Color(0xFF367987):Colors.white,width:1.25),
            boxShadow:[BoxShadow(
              color:Colors.black.withValues(alpha:.20),
              offset:const Offset(0,5),blurRadius:7)],
          ),
          child:Center(child:actions[i])),
      ],
    ]));
    });
}

class TransferCardTime extends StatelessWidget {
  const TransferCardTime({super.key, required this.created,
    required this.status});
  final DateTime created;
  final Widget status;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: FileTheme.turquoise.withValues(alpha: .10),
      border:Border.all(color:FileTheme.dark(context)
        ?const Color(0xFF58939D):Colors.white,width:1.1),
      borderRadius: BorderRadius.circular(22)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(created.toLocal().toString().substring(11, 16),
        style: TextStyle(fontSize: 11,fontWeight:FontWeight.w700,
          color: FileTheme.foreground(context))),
      const SizedBox(width: 4),
      status,
    ]),
  );
}

class LiveTransferCard extends StatelessWidget {
  const LiveTransferCard({
    super.key, required this.items, required this.onSave,
    required this.onDelete, required this.onShare, required this.onTools,
    this.isFileSelected, this.fileSelectionActive=false, this.onFileSelect,
  });
  final bool Function(LanFile)? isFileSelected;
  final bool fileSelectionActive;
  final void Function(LanFile)? onFileSelect;
  final List<LanFile> items;
  final Future<void> Function(LanFile) onSave;
  final Future<void> Function(LanFile) onDelete;
  final Future<void> Function(LanFile) onShare;
  final Future<void> Function(LanFile) onTools;
  bool get incoming => items.first.incoming;

  static bool _photo(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.jpg') || n.endsWith('.jpeg') ||
      n.endsWith('.png') || n.endsWith('.webp') || n.endsWith('.gif');
  }

  Widget _visual(LanFile file) {
    if (_photo(file.name) && File(file.path).existsSync()) {
      return ClipRRect(borderRadius: BorderRadius.circular(12),
        child: Image.file(File(file.path), fit: BoxFit.cover,
          cacheWidth: 280,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.image_not_supported_outlined,
            color: FileTheme.pink, size: 34)));
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: FileTheme.pink.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(12)),
      child: Center(child: Icon(
        file.name.toLowerCase().endsWith('.pdf')
          ? Icons.picture_as_pdf_outlined
          : (file.name.toLowerCase().endsWith('.mp4')
             ? Icons.play_circle_outline_rounded
             : Icons.insert_drive_file_outlined),
        color: FileTheme.pink, size: 42)));
  }

  void _preview(BuildContext context, LanFile file) {
    if (!File(file.path).existsSync() ||
        (file.incoming && file.state != TransferState.delivered)) return;
    unawaited(FileCardOpenRouter.openEditor(
      context,file.path,file.name).then((handled){
      if(handled||!context.mounted)return;
      Navigator.push(context,MaterialPageRoute<void>(builder:(_) =>
        FullScreenFilePreview(file:file,onSave:onSave,
          onDelete:onDelete,onShare:onShare,onTools:onTools)));
    }));
  }

  Widget _buttons(BuildContext context, LanFile file) {
    final exists = File(file.path).existsSync();
    final canUse = exists &&
      (file.state == TransferState.delivered || !file.incoming);
    Widget action(String title, IconData icon, VoidCallback? onTap) =>
      IconButton(
        tooltip: title, onPressed: onTap,
        iconSize: 22,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 38),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, color: onTap == null
          ? FileTheme.pink.withValues(alpha: .25) : FileTheme.pink));
    return TransferCardActions(actions: [
      // NEW disappears only after a successful export, never after preview.
      if (file.incoming)
        Stack(clipBehavior: Clip.none,children: [
          action('Download', Icons.download_rounded,
            canUse ? () => onSave(file) : null),
          if (file.state == TransferState.delivered)
            Positioned(top: -8, right: -4,
              child: NewDownloadBadge(id: 'lan_${file.id}')),
        ]),
      action('Delete', Icons.delete_outline_rounded, () => onDelete(file)),
      action('Share', Icons.ios_share_rounded,
        canUse ? () => onShare(file) : null),
      action('Open in Tools', Icons.auto_fix_high_rounded,
        canUse ? () => onTools(file) : null),
    ]);
  }

  Widget _status(LanFile file) {
    final delivered = file.state == TransferState.delivered;
    return Icon(
      delivered ? Icons.done_all_rounded
        : file.state == TransferState.queued ? Icons.schedule_rounded
        : file.state == TransferState.failed ? Icons.error_outline_rounded
        : Icons.done_rounded,
      size: 15,
      color: delivered ? FileTheme.pink : FileTheme.violet);
  }

  Widget _file(BuildContext context, LanFile file) {
    final active=file.state==TransferState.sending ||
      file.state==TransferState.receiving ||
      file.state==TransferState.preparing;
    return Padding(padding:const EdgeInsets.only(top:8),
      child:LayoutBuilder(builder:(context,constraints){
        final compact=constraints.maxWidth<460;
        final side=compact?(constraints.maxWidth<290?70.0:84.0):88.0;
        final selected=isFileSelected?.call(file)??false;
        final preview=GestureDetector(
          onLongPress:onFileSelect==null?null:()=>onFileSelect!(file),
          onTap:fileSelectionActive&&onFileSelect!=null
            ?()=>onFileSelect!(file):()=>_preview(context,file),
          child:Stack(children:[
            SizedBox(width:side,height:side,child:_visual(file)),
            if(fileSelectionActive)Positioned(right:2,top:2,
              child:Icon(selected?Icons.check_circle_rounded:
                Icons.radio_button_unchecked_rounded,
                color:selected?FileTheme.turquoise:FileTheme.violet)),
          ]));
        final details=Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          InkWell(onTap:()=>_preview(context,file),
            child:Text(file.name,maxLines:2,overflow:TextOverflow.ellipsis,
              style:TextStyle(fontSize:13,fontWeight:FontWeight.w700,
                color:FileTheme.foreground(context)))),
          const SizedBox(height:3),
          Text(_formatBytes(file.size),
            style:TextStyle(color:FileTheme.muted(context),fontSize:11)),
          if(active||file.state==TransferState.failed)...[
            const SizedBox(height:3),
            Text(file.state.name,style:const TextStyle(fontSize:10,
              color:FileTheme.pink)),
            if(active)LinearProgressIndicator(value:file.progress,minHeight:2),
          ]
        ]);
        if(compact && constraints.maxWidth-side-10 < (incoming?110:85)){
          return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
              preview,const SizedBox(width:10),Expanded(child:details)]),
            const SizedBox(height:8),_buttons(context,file),
          ]);
        }
        if(compact) return Row(
          crossAxisAlignment:CrossAxisAlignment.start,children:[
            preview,const SizedBox(width:10),
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,
              children:[details,const SizedBox(height:8),
                _buttons(context,file)])),
          ]);
        return Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
          preview,const SizedBox(width:10),
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            details,const SizedBox(height:7),_buttons(context,file),
          ]))
        ]);
      }));
  }

  @override
  Widget build(BuildContext context) {
    final first = items.first;
    final multiple = items.length > 1;
    final peer = first.peer.trim().isEmpty
      ? 'Unknown device' : first.peer.trim();
    final origin = incoming ? 'From $peer · Received' : 'Sent · Offline LAN';
    final delivered = items.every((f) => f.state == TransferState.delivered);
    return TransferBubble(
      incoming: incoming,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(radius: 15,
            backgroundColor: const Color(0xFF89EEE5),
            child: Icon(incoming ? Icons.download_rounded : Icons.send_rounded,
              size: 19, color: FileTheme.pink)),
          const SizedBox(width: 8),
          Expanded(child: Text(origin,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: FileTheme.foreground(context),
              fontWeight: FontWeight.w700, fontSize: 13))),
          TransferCardTime(created:first.created,
            status:_status(first)),
        ]),
        if(multiple) Text('${items.length} files',
          style:TextStyle(color:FileTheme.muted(context),fontSize:10)),
        for (final file in items) _file(context, file),
        if (incoming && multiple)
          Align(alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: delivered
                ? () async { for (final f in items) { await onSave(f); } }
                : null,
              icon: const Icon(Icons.download_for_offline_outlined, size: 17),
              label: const Text('Download All'))),
      ]),
    );
  }
}

String _formatBytes(int bytes) {
  double value = bytes.toDouble();
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return value.toStringAsFixed(i == 0 ? 0 : 1) + ' ' + units[i];
}


bool _isCloudImage(String name) {
  final lower=name.toLowerCase();
  return lower.endsWith('.jpg') || lower.endsWith('.jpeg') ||
    lower.endsWith('.png') || lower.endsWith('.webp') ||
    lower.endsWith('.gif');
}

/// Preview images stream from the authenticated Worker to private app cache.
class CloudImageThumbnail extends StatefulWidget {
  const CloudImageThumbnail({super.key,required this.file,required this.onOpen});
  final CloudFile file;
  final VoidCallback onOpen;
  @override
  State<CloudImageThumbnail> createState()=>_CloudImageThumbnailState();
}
class _CloudImageThumbnailState extends State<CloudImageThumbnail> {
  Future<File>? _image;
  @override
  void initState(){super.initState();_load();}
  @override
  void didUpdateWidget(covariant CloudImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if(oldWidget.file.id!=widget.file.id)_load();
  }
  void _load(){
    _image=_isCloudImage(widget.file.name) && widget.file.size<=10*1024*1024
      ?PersonalCloud.instance.download(widget.file):null;
  }
  @override
  Widget build(BuildContext context)=>InkWell(
    onTap:widget.onOpen,
    borderRadius:BorderRadius.circular(10),
    child:ClipRRect(borderRadius:BorderRadius.circular(10),
      child:SizedBox.expand(
        child:_image==null
          ?const Icon(Icons.insert_drive_file_outlined,
              color:FileTheme.pink,size:30)
          :FutureBuilder<File>(
              future:_image,
              builder:(context,snapshot){
                if(snapshot.hasData){
                  return Image.file(snapshot.data!,fit:BoxFit.cover,
                    cacheWidth:240,
                    errorBuilder:(_,__,___)=>const Icon(
                      Icons.broken_image_outlined,color:FileTheme.pink));
                }
                if(snapshot.hasError)return const Icon(
                  Icons.broken_image_outlined,color:FileTheme.pink);
                return const Center(child:SizedBox(width:24,height:24,
                  child:CircularProgressIndicator(strokeWidth:2)));
              }),
      ),
    ),
  );
}

class CloudInboxCard extends StatelessWidget {
  const CloudInboxCard({super.key, required this.items,
    required this.onSave, required this.onDelete, required this.onShare,
    required this.onPreview, required this.onTools,
    this.isFileSelected,this.fileSelectionActive=false,this.onFileSelect});
  final bool Function(CloudFile)? isFileSelected;
  final bool fileSelectionActive;
  final void Function(CloudFile)? onFileSelect;
  final List<CloudFile> items;
  final Future<void> Function(CloudFile) onSave, onDelete, onShare,
    onPreview, onTools;

  @override
  Widget build(BuildContext context) {
    final grouped = items.length > 1;
    final device = items.first.deviceTransfer;
    final sent = device && items.first.senderId == appLan.deviceId;
    Widget action(String name, IconData icon, VoidCallback onPressed) =>
      IconButton(
        tooltip: name, onPressed: onPressed, iconSize: 22,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 38),
        padding: EdgeInsets.zero,
        icon: Icon(icon, color: FileTheme.pink));
    return TransferBubble(
      incoming: !sent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(radius: 15,
            backgroundColor: const Color(0xFF89EEE5),
            child: Icon(sent?Icons.send_rounded:Icons.download_rounded,
              size:19,color:FileTheme.pink)),
          const SizedBox(width: 8),
          Expanded(child: Text(device ? (sent ? 'Sent · Online / Cloud' : 'From '+items.first.senderName+' · Online / Cloud') : 'From Guest browser · Guest QR · Online',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: FileTheme.foreground(context),
              fontWeight: FontWeight.w700, fontSize: 13))),
          TransferCardTime(created:items.first.created,
            status:Icon(device && items.first.receivedAt==null
              ?Icons.done_rounded:Icons.done_all_rounded,
              size:17,color:FileTheme.turquoise)),
        ]),
        if(grouped)Text('${items.length} files',
          style:TextStyle(color:FileTheme.muted(context),fontSize:10)),
        for(final file in items)
          Padding(padding:const EdgeInsets.only(top:8),
            child:LayoutBuilder(builder:(context,constraints){
              final compact=constraints.maxWidth<460;
              final side=compact?(constraints.maxWidth<290?70.0:84.0):88.0;
              final selected=isFileSelected?.call(file)??false;
              final preview=GestureDetector(
                onLongPress:onFileSelect==null?null:()=>onFileSelect!(file),
                child:Stack(children:[
                  SizedBox(width:side,height:side,
                    child:CloudImageThumbnail(
                      key:ValueKey('qr-thumb-'+file.id),
                      file:file,onOpen:()=>fileSelectionActive&&onFileSelect!=null
                        ?onFileSelect!(file):onPreview(file))),
                  if(fileSelectionActive)Positioned(right:2,top:2,
                    child:Icon(selected?Icons.check_circle_rounded:
                      Icons.radio_button_unchecked_rounded,
                      color:selected?FileTheme.turquoise:FileTheme.violet)),
                ]));
              final details=Column(crossAxisAlignment:CrossAxisAlignment.start,
                children:[
                  InkWell(onTap:()=>onPreview(file),
                    child:Text(file.name,maxLines:2,
                      overflow:TextOverflow.ellipsis,
                      style:TextStyle(color:FileTheme.foreground(context),
                        fontWeight:FontWeight.w700,fontSize:13))),
                  const SizedBox(height:3),
                  Text(_formatBytes(file.size),
                    style:TextStyle(color:FileTheme.muted(context),fontSize:11)),
                ]);
              final actions=TransferCardActions(actions:[
                if(!sent)Stack(clipBehavior:Clip.none,children:[
                  action(device?'Download received cloud file':'Download received QR file',
                    Icons.download_rounded,()=>onSave(file)),
                  Positioned(top:-8,right:-4,
                    child:NewDownloadBadge(id:'cloud_${file.id}')),
                ]),
                action(device?'Delete cloud file':'Delete QR file',
                  Icons.delete_outline_rounded,()=>onDelete(file)),
                action(device?'Share cloud file externally':'Share QR file externally',
                  Icons.ios_share_rounded,()=>onShare(file)),
                action('Open in Tools',Icons.auto_fix_high_rounded,
                  ()=>onTools(file)),
              ]);
              if(compact && constraints.maxWidth-side-10 < (sent?85:110)){
                return Column(crossAxisAlignment:CrossAxisAlignment.start,
                  children:[
                    Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
                      preview,const SizedBox(width:10),Expanded(child:details)]),
                    const SizedBox(height:8),actions,
                  ]);
              }
               if(compact)return Row(
                 crossAxisAlignment:CrossAxisAlignment.start,children:[
                   preview,const SizedBox(width:10),
                   Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,
                     children:[details,const SizedBox(height:8),actions])),
                 ]);
              return Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
                preview,const SizedBox(width:10),
                Expanded(child:Column(
                  crossAxisAlignment:CrossAxisAlignment.start,children:[
                     details,const SizedBox(height:7),actions,
                  ])),
              ]);
            })),
        if (grouped && !sent)
          Align(alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                for (final file in items) { await onSave(file); }
              },
              icon: const Icon(Icons.download_for_offline_outlined, size: 17),
              label: const Text('Download All'))),
      ]),
    );
  }
}

class TimelineGroup {
  const TimelineGroup({this.lan, this.cloud, this.upload});
  final List<LanFile>? lan;
  final List<CloudFile>? cloud;
  final CloudUploadJob? upload;
  DateTime get created =>
    upload?.created ?? lan?.first.created ?? cloud!.first.created;
}
// A one-shot GPU-composited entrance for genuinely new transfer messages.
// Existing messages are not replayed by scrolling or by upload progress.
class FileShareCardArrival extends StatefulWidget {
  const FileShareCardArrival({super.key,required this.child,
    required this.animate,required this.incoming});
  final Widget child;
  final bool animate,incoming;
  @override State<FileShareCardArrival> createState()=>_FileShareCardArrivalState();
}
class _FileShareCardArrivalState extends State<FileShareCardArrival>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller=AnimationController(
    vsync:this,duration:const Duration(milliseconds:290));
  late final CurvedAnimation _curve=CurvedAnimation(
    parent:_controller,curve:Curves.easeOutCubic);
  @override void initState(){
    super.initState();
    if(!widget.animate){
      _controller.value=1;
    }else{
      WidgetsBinding.instance.addPostFrameCallback((_){
        if(!mounted)return;
        if(MediaQuery.disableAnimationsOf(context)){
          _controller.value=1;
        }else{
          _controller.forward();
        }
      });
    }
  }
  @override void dispose(){
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }
  @override Widget build(BuildContext context) {
    return RepaintBoundary(child:FadeTransition(opacity:_curve,
      child:SlideTransition(position:Tween<Offset>(
        begin:Offset(widget.incoming?-.045:.045,.07),end:Offset.zero,
      ).animate(_curve),
        child:ScaleTransition(scale:Tween<double>(begin:.985,end:1)
          .animate(_curve),child:widget.child))));
  }
}


//// Compositor-friendly scroll depth: visible cards receive a tiny perspective
//// tilt and parallax, while their contents remain isolated repaint layers.
//// Never calls setState on Dashboard as the scroll offset changes.
class FileShareScrollDepth extends StatelessWidget {
  const FileShareScrollDepth({super.key,required this.position,
    required this.child});
  final ScrollController position;
  final Widget child;

  @override
  Widget build(BuildContext context){
    if(MediaQuery.disableAnimationsOf(context)){
      return RepaintBoundary(child:child);
    }
    final viewportHeight=MediaQuery.sizeOf(context).height;
    // SizedBox supplies a stable RenderBox. Using the AnimatedBuilder's own
    // context would sometimes find its ancestor RenderSliver instead.
    return SizedBox(child:Builder(builder:(cardContext){
      return AnimatedBuilder(
        animation:position,
        child:RepaintBoundary(child:child),
        builder:(context,painted){
          final render=cardContext.findRenderObject();
          if(!position.hasClients || render is! RenderBox ||
              !render.hasSize || viewportHeight<=0){
            return painted!;
          }
          final y=render.localToGlobal(
            Offset(0,render.size.height/2)).dy;
          final progress=((y-viewportHeight/2)/
            (viewportHeight*.60)).clamp(-1.0,1.0).toDouble();
          // Maximum ~1.5°: a gentle depth impression without text shimmer.
          final angle=progress*.026;
          final lift=progress.abs()*.008;
          final matrix=Matrix4.identity()
            ..setEntry(3,2,.00065)
            ..translateByDouble(0.0,-progress*2.4,0.0,1.0)
            ..rotateX(angle)
            ..scaleByDouble(1-lift,1-lift,1.0,1.0);
          return Transform(
            transform:matrix,alignment:Alignment.center,
            transformHitTests:true,child:painted);
        },
      );
    }));
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.mode, required this.onMode,
    this.enableBackends = true});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  final bool enableBackends;
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  final _scaffold = GlobalKey<ScaffoldState>();
  final List<PendingBatch> _staged = [];
  final TextEditingController _messageController=TextEditingController();
  String _filter = 'All';
  bool _choosing = false;
  bool _refreshing = false;
  bool _sending = false;
  bool _desktopSidebarVisible = true;
  bool _preparingText=false;
  String? _sendingPreview;
  bool _timelineSeeded=false;
  final Set<String> _knownTimelineKeys=<String>{};
  final Set<String> _pendingArrivalKeys=<String>{};

  final ScrollController _dashboardScroll=ScrollController();
  final Map<String,TimelineGroup> _selectedCards={};
  final Set<String> _selectedFiles=<String>{};
  bool get _selectionActive=>_selectedCards.isNotEmpty||_selectedFiles.isNotEmpty;
  String _lanFileKey(LanFile file)=>'lan:${file.id}';
  String _cloudFileKey(CloudFile file)=>'cloud:${file.id}';
  void _selectLanFile(LanFile file){
    if(_bulkBusy)return;
    setState((){
      final key=_lanFileKey(file);
      if(!_selectedFiles.add(key))_selectedFiles.remove(key);
    });
  }
  void _selectCloudFile(CloudFile file){
    if(_bulkBusy)return;
    setState((){
      final key=_cloudFileKey(file);
      if(!_selectedFiles.add(key))_selectedFiles.remove(key);
    });
  }
  void _clearSelection(){
    _selectedCards.clear();
    _selectedFiles.clear();
  }
  Iterable<LanFile> get _chosenLan sync*{
    final ids=<String>{};
    for(final g in _selectedCards.values){
      for(final f in g.lan??<LanFile>[]) {
        if(ids.add(f.id))yield f;
      }
    }
    for(final f in appLan.files){
      if(_selectedFiles.contains(_lanFileKey(f))&&ids.add(f.id))yield f;
    }
  }
  Iterable<CloudFile> get _chosenCloud sync*{
    final ids=<String>{};
    for(final g in _selectedCards.values){
      for(final f in g.cloud??<CloudFile>[]) {
        if(ids.add(f.id))yield f;
      }
    }
    for(final f in PersonalCloud.instance.files){
      if(_selectedFiles.contains(_cloudFileKey(f))&&ids.add(f.id))yield f;
    }
  }
  bool _bulkBusy=false;
  String _keyOf(TimelineGroup g)=>g.upload!=null
    ?'upload:${g.upload!.localId}'
    : g.lan!=null ?'lan:${g.lan!.first.id}':'qr:${g.cloud!.first.id}';
  void _toggleCard(TimelineGroup g){
    if(_bulkBusy)return;
    final key=_keyOf(g);
    setState((){
      if(_selectedCards.containsKey(key))_selectedCards.remove(key);
      else _selectedCards[key]=g;
    });
  }
  void _selectAllCards(List<TimelineGroup> groups){
    if(_bulkBusy)return;
    setState((){for(final g in groups)_selectedCards[_keyOf(g)]=g;});
  }


  Future<void> _openSelectedImagesInTools()async{
    if(_bulkBusy||!_selectionActive)return;
    final lan=List<LanFile>.of(_chosenLan);
    final cloud=List<CloudFile>.of(_chosenCloud);
    final paths=<String>[],names=<String>[];
    setState(()=>_bulkBusy=true);
    try{
      for(final file in lan){
        if(!EditingFileRouter.acceptsImageTool(file.name)){
          throw StateError('Select image files only');
        }
        if(file.incoming&&file.state!=TransferState.delivered){
          throw StateError('Selected received image is not downloaded');
        }
        if(!await File(file.path).exists()){
          throw StateError('An image is missing from local storage');
        }
        paths.add(file.path);names.add(file.name);
      }
      for(final file in cloud){
        if(!EditingFileRouter.acceptsImageTool(file.name)){
          throw StateError('Select image files only');
        }
        final local=await PersonalCloud.instance.download(file);
        paths.add(local.path);names.add(file.name);
      }
      if(paths.isEmpty)throw StateError('Select at least one image');
      if(!mounted)return;
      setState(_clearSelection);
      final navigator=(Platform.isWindows||Platform.isMacOS)&&
        _desktopNavigator.currentState!=null
        ?_desktopNavigator.currentState!:Navigator.of(context);
      await navigator.push(MaterialPageRoute<void>(
        builder:(_)=>FileShareToolboxPage(
          sourcePaths:paths,sourceNames:names,
          sourcePath:paths.length==1?paths.first:null,
          sourceName:names.length==1?names.first:null)));
    }catch(e){_snack('Open selected images: '+e.toString());}
    finally{if(mounted)setState(()=>_bulkBusy=false);}
  }

  Future<void> _downloadCards()async{
    if(!_selectionActive||_bulkBusy)return;
    final lan=List<LanFile>.of(_chosenLan),cloud=List<CloudFile>.of(_chosenCloud);
    setState(()=>_bulkBusy=true);
    var success=0,failed=0,skipped=0;
    try{
      for(final f in lan){
        if((f.incoming&&f.state!=TransferState.delivered)||
           !await File(f.path).exists()){skipped++;continue;}
        try{
          final saved=await TransferDownloads.instance.export(File(f.path),f.name);
          if(saved==null){skipped++;continue;}
          await TransferDownloads.instance.markSaved('lan_${f.id}');
          success++;
        }catch(_){failed++;}
      }
      for(final f in cloud){
        try{
          final file=await PersonalCloud.instance.download(f);
          final saved=await TransferDownloads.instance.export(file,f.name);
          if(saved==null){skipped++;continue;}
          await TransferDownloads.instance.markSaved('cloud_${f.id}');
          success++;
        }catch(_){failed++;}
      }
      if(mounted)_snack('${success} downloaded · ${skipped} skipped · ${failed} failed');
    }finally{
      if(mounted)setState((){
        _bulkBusy=false;_clearSelection();
      });
    }
  }

  /// Copy only selected files to an explicitly chosen local directory.
  /// Never move or delete originals, including guest uploads.
  Future<void> _copySelectedToFolder()async{
    if(!_selectionActive||_bulkBusy)return;
    final lan=List<LanFile>.of(_chosenLan),cloud=List<CloudFile>.of(_chosenCloud);
    if(Platform.isIOS||Platform.isMacOS){
      // Apple sandbox folders cannot be used as plain Dart paths. Use the
      // same security-scoped, remembered native destination as card Download.
      setState(()=>_bulkBusy=true);
      var copied=0, failed=0, cancelled=false;
      try{
        for(final file in lan){
          try{
            final path=await TransferDownloads.instance.export(
              File(file.path),file.name);
            if(path==null){cancelled=true;break;}
            copied++;
            await TransferDownloads.instance.markSaved('lan_${file.id}');
          }catch(_){failed++;}
        }
        if(!cancelled){
          for(final file in cloud){
            try{
              final local=await PersonalCloud.instance.download(file);
              final path=await TransferDownloads.instance.export(local,file.name);
              if(path==null){cancelled=true;break;}
              copied++;
              await TransferDownloads.instance.markSaved('cloud_${file.id}');
            }catch(_){failed++;}
          }
        }
        if(mounted)_snack('Saved $copied files · $failed failed'
            + (cancelled?' · folder picker cancelled':''));
      }finally{
        if(mounted)setState((){_bulkBusy=false;_clearSelection();});
      }
      return;
    }
    final target=await FilePicker.getDirectoryPath(dialogTitle:'Choose destination folder');
    if(target==null||!mounted)return;
    setState(()=>_bulkBusy=true);
    var success=0,failed=0;
    try{
      final folder=Directory(target);
      if(!await folder.exists())throw StateError('Folder is not accessible');
      Future<void> copy(File source,String name)async{
        try{
          if(!await source.exists())throw StateError('Source not available');
          final clean=name.replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'),'_');
          final safe=clean.isEmpty?'image':clean;
          var destination=File('${folder.path}${Platform.pathSeparator}${safe}');
          var index=1;
          final dot=safe.lastIndexOf('.');
          final base=dot>0?safe.substring(0,dot):safe;
          final ext=dot>0?safe.substring(dot):'';
          while(await destination.exists()){
            destination=File('${folder.path}${Platform.pathSeparator}${base} (${index})${ext}');
            index++;
          }
          await source.copy(destination.path);
          success++;
        }catch(_){failed++;}
      }
      for(final file in lan){await copy(File(file.path),file.name);}
      for(final file in cloud){
        try{
          final source=await PersonalCloud.instance.download(file);
          await copy(source,file.name);
        }catch(_){failed++;}
      }
      if(mounted)_snack('Copied ${success} files · ${failed} failed');
    }catch(e){_snack('Folder copy failed: $e');}
    finally{if(mounted)setState((){
      _bulkBusy=false;_clearSelection();
    });}
  }

  Future<void> _deleteCards()async{
    if(!_selectionActive||_bulkBusy)return;
    final lan=List<LanFile>.of(_chosenLan),cloud=List<CloudFile>.of(_chosenCloud);
    final count=lan.length+cloud.length;
    if(count==0)return;
    final confirm=await showDialog<bool>(context:context,builder:(dialog)=>
      AlertDialog(
        title:const Text('Delete selected files?'),
        content:Text('${count} selected file(s) will be deleted. '
          'Guest QR files will be removed from cloud storage if selected. '
          'Unselected images in the same card will remain. This cannot be undone.'),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialog,false),
            child:const Text('Cancel')),
          FilledButton.icon(onPressed:()=>Navigator.pop(dialog,true),
            icon:const Icon(Icons.delete_outline_rounded),
            label:const Text('Delete')),
        ]));
    if(confirm!=true||!mounted)return;
    setState(()=>_bulkBusy=true);
    var deleted=0,failed=0;
    try{
      for(final file in lan){
        try{await appLan.remove(file.id);deleted++;}catch(_){failed++;}
      }
      for(final file in cloud){
        try{await PersonalCloud.instance.deleteRemote(file);deleted++;}
        catch(_){failed++;}
      }
      if(mounted)_snack('Deleted ${deleted} files · ${failed} failed');
    }finally{
      if(mounted)setState((){
        _bulkBusy=false;_clearSelection();
      });
    }
  }
  Widget _cloudUploadCard(CloudUploadJob job) {
    final progress=job.progress.clamp(0.0,1.0).toDouble();
    return TransferBubble(
      incoming:false,
      child:Row(children:[
        SizedBox(width:44,height:44,child:job.failed
          ?IconButton(
              tooltip:'Retry failed Cloud upload',
              icon:const Icon(Icons.refresh_rounded),
              color:FileTheme.pink,
              onPressed:()=>unawaited(
                PersonalCloud.instance.retryDeviceUpload(job)))
          :job.uploading
          ?TweenAnimationBuilder<double>(
              tween:Tween<double>(begin:0,end:progress),
              duration:const Duration(milliseconds:260),
              builder:(context,value,_)=>Stack(alignment:Alignment.center,
                children:[
                  CircularProgressIndicator(value:value,strokeWidth:3,
                    color:FileTheme.pink),
                  Text('${(value*100).round()}%',style:const TextStyle(
                    fontSize:10,fontWeight:FontWeight.bold)),
                ]))
          :const Icon(Icons.done_rounded,color:FileTheme.pink)),
        const SizedBox(width:12),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,
          children:[
            Text(job.name,maxLines:1,overflow:TextOverflow.ellipsis,
              style:const TextStyle(fontWeight:FontWeight.bold)),
            const SizedBox(height:3),
            Text(job.failed?'Cloud upload failed · Tap retry'
                :job.uploading?'Online / Cloud · Uploading'
                :'Online / Cloud · Uploaded',
              style:TextStyle(fontSize:11,color:FileTheme.muted(context))),
            if(job.error!=null) Text(job.error!,maxLines:2,
              style:const TextStyle(fontSize:10,color:Colors.deepOrange)),
          ])),
        if(!job.uploading && !job.failed)
          const Icon(Icons.done_rounded,color:FileTheme.pink,size:18)
      ]),
    );
  }

  Widget _multiSelectCard(TimelineGroup g){
    final selected=_selectedCards.containsKey(_keyOf(g));
    final active=_selectionActive;
    final lanText=g.lan!=null && g.lan!.length==1 &&
      FileShareText.isText(g.lan!.first.name);
    final cloudText=g.cloud!=null && g.cloud!.length==1 &&
      FileShareText.isText(g.cloud!.first.name);
    final card=lanText
      ?TextTransferCard(
        key:ValueKey('text-lan-${g.lan!.first.id}'),
        wrap:(content)=>TransferBubble(incoming:g.lan!.first.incoming,
          textOnly:true,child:content),
        readMessage:()async=>File(g.lan!.first.path),
        onDelete:()=>_delete(g.lan!.first),
        incoming:g.lan!.first.incoming,
        source:g.lan!.first.incoming
          ?'From ${g.lan!.first.peer} · Received':'Sent · Offline LAN',
        created:g.lan!.first.created,
        status:Icon(g.lan!.first.state==TransferState.delivered
          ?Icons.done_all_rounded:Icons.schedule_rounded,size:15,color:FileTheme.pink))
      :cloudText
      ?TextTransferCard(
        key:ValueKey('text-cloud-${g.cloud!.first.id}'),
        wrap:(content)=>TransferBubble(
          incoming:g.cloud!.first.senderId!=appLan.deviceId,
          textOnly:true,child:content),
        readMessage:()=>PersonalCloud.instance.download(g.cloud!.first),
        onDelete:()=>_deleteCloud(g.cloud!.first),
        incoming:g.cloud!.first.senderId!=appLan.deviceId,
        source:g.cloud!.first.senderId==appLan.deviceId
          ?'Sent · Online / Cloud'
          :'From ${g.cloud!.first.senderName} · Online / Cloud',
        created:g.cloud!.first.created,
        status:Icon(g.cloud!.first.receivedAt==null
          ?Icons.done_rounded:Icons.done_all_rounded,size:15,color:FileTheme.pink))
      :g.upload!=null ? _cloudUploadCard(g.upload!)
      :g.lan!=null
      ?LiveTransferCard(items:g.lan!,onSave:_saveReceived,
        onDelete:_delete,onShare:_share,onTools:_openFileTools,
        isFileSelected:(f)=>_selectedFiles.contains(_lanFileKey(f)),
        fileSelectionActive:active,onFileSelect:_selectLanFile)
      :CloudInboxCard(items:g.cloud!,onSave:_saveCloud,
        onDelete:_deleteCloud,onShare:_shareCloud,
        onPreview:_previewCloud,onTools:_openCloudTools,
        isFileSelected:(f)=>_selectedFiles.contains(_cloudFileKey(f)),
        fileSelectionActive:active,onFileSelect:_selectCloudFile);
    final key=_keyOf(g);
    final arriving=_pendingArrivalKeys.remove(key);
    final incoming=g.lan?.first.incoming ??
      (g.cloud!=null && g.cloud!.first.senderId!=appLan.deviceId);
    return FileShareCardArrival(
      key:ValueKey('arrival:$key'),animate:arriving,incoming:incoming,
      child:Padding(
        padding:const EdgeInsets.symmetric(vertical:3),
        child:GestureDetector(
        behavior:HitTestBehavior.opaque,
        onLongPress:()=>_toggleCard(g),
        onTap:active?()=>_toggleCard(g):null,
        child:Stack(children:[
          AbsorbPointer(absorbing:active && _selectedFiles.isEmpty,
            child:AnimatedContainer(
              duration:const Duration(milliseconds:160),
              decoration:BoxDecoration(
                color:selected?FileTheme.violet.withValues(alpha:.08):null,
                borderRadius:BorderRadius.circular(26),
                border:Border.all(color:selected
                  ?FileTheme.violet:Colors.transparent,width:1.5)),
              child:card)),
          if(active)Positioned(top:10,right:10,
            child:AnimatedContainer(
              duration:const Duration(milliseconds:140),
              width:30,height:30,
              decoration:BoxDecoration(
                shape:BoxShape.circle,
                color:selected?FileTheme.violet:
                  Theme.of(context).colorScheme.surface,
                border:Border.all(color:FileTheme.violet,width:1.5)),
              child:Icon(selected?Icons.check_rounded:Icons.circle_outlined,
                size:18,color:selected?Colors.white:FileTheme.violet))),
        ]),
      ),
      ),
    );
  }
  final _sidebarVisibleNotifier = ValueNotifier<bool>(true);
  final _desktopNavigator = GlobalKey<NavigatorState>();

  void _toggleSidebar(){
    setState(()=>_desktopSidebarVisible=!_desktopSidebarVisible);
    _sidebarVisibleNotifier.value=_desktopSidebarVisible;
  }
  static const _native = MethodChannel('file_share.native');
  Timer? _midnight;
  bool _dashboardForeground=true;
  bool _previousSignedIn=false;
  bool _frameRefreshQueued=false;

  void _resumeCloudInbox() {
    if(!mounted || !widget.enableBackends || !_dashboardForeground)return;
    final cloud=PersonalCloud.instance;
    if(cloud.signedIn){
      // The WebSocket reconciles on connect and pushes future changes.
      // Returning from brief 'inactive' state with a healthy socket should
      // not issue another Worker/D1 request.
      cloud.startLiveInbox();
    }
  }

  void _armMidnight() {
    _midnight?.cancel();
    final next=DateTime.fromMillisecondsSinceEpoch(PersonalCloud.nextMidnightIst());
    final delay=next.difference(DateTime.now())+const Duration(milliseconds:400);
    _midnight=Timer(delay,(){
      PersonalCloud.instance.removeExpiredLocalEntries();
      _armMidnight();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if(state==AppLifecycleState.resumed){
      _dashboardForeground=true;
      if (Platform.isAndroid) unawaited(_takeSharedFiles());
      if (Platform.isIOS) appLan.refresh();
      _resumeCloudInbox();
      unawaited(appLan.cleanExpired());
      PersonalCloud.instance.removeExpiredLocalEntries();
    }else if(state==AppLifecycleState.paused ||
             state==AppLifecycleState.detached){
      // 'inactive' may be a brief system permission sheet: keep the socket.
      // Windows tray is still a running foreground-capable desktop process:
      // keep the event-driven QR inbox socket while hidden. Android releases
      // it on background to respect phone battery/platform restrictions.
      if(Platform.isWindows && state!=AppLifecycleState.detached){
        _dashboardForeground=true;
      }else{
        _dashboardForeground=false;
        PersonalCloud.instance.stopLiveInbox();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _previousSignedIn=PersonalCloud.instance.signedIn;
    _armMidnight();
    appLan.addListener(_changed);
    PersonalCloud.instance.addListener(_changed);
    ImageEditingCart.instance.addListener(_importEditedCart);
    _importEditedCart();
    if (widget.enableBackends) WidgetsBinding.instance.addPostFrameCallback((_) {
      appLan.start().then((_) async {
        if (Platform.isAndroid) {
          _native.setMethodCallHandler((call) async {
            if(call.method=='sharesReceived') {
              await _takeSharedFiles();
            }else if(call.method=='editorSwitchFromPdf'){
              final args=Map<String,dynamic>.from(call.arguments as Map);
              final paths=(args['paths'] as List?)?.whereType<String>()
                .where((path)=>path.isNotEmpty).toList()??<String>[];
              if(paths.isEmpty||!mounted)return;
              final localPaths=<String>[];
              for(final path in paths){
                if(await File(path).exists())localPaths.add(path);
              }
              if(localPaths.isEmpty){
                _snack('Selected PDF pages are not available');
                return;
              }
              final navigator=fileShareNavigatorKey.currentState;
              if(navigator==null)return;
              if(localPaths.length==1){
                final name=File(localPaths.first).uri.pathSegments.last;
                final target=args['target']?.toString()??'image';
                unawaited(navigator.push(MaterialPageRoute<void>(
                  builder:(_)=>target=='signature'
                    ?SignatureEditPage(sourcePath:localPaths.first,
                        sourceName:name)
                    :ImageEditingPage(sourcePath:localPaths.first,
                        sourceName:name))));
              }else{
                unawaited(navigator.push(MaterialPageRoute<void>(
                  builder:(_)=>FileShareToolboxPage(
                    sourcePaths:localPaths,
                    sourceNames:localPaths.map((p)=>
                      File(p).uri.pathSegments.last).toList()))));
              }
            }
          });
          try {
            final enabled=await _native.invokeMethod<bool>('getLanBootReceiver')??true;
            if(enabled){
              await _native.invokeMethod<bool>('startLanService');
              await SharedPreferencesAsync()
                .setBool('android_receive_background',true);
            }
          }catch(e){ _snack('Background LAN limited: '+e.toString()); }
          await _takeSharedFiles();
        }
        if (mounted) setState(() {});
      }).catchError((Object e) { _snack('LAN start failed: ' + e.toString()); });
      PersonalCloud.instance.cleanupLocalCache().then((_) {
        _resumeCloudInbox();
      }).catchError((Object e) {
        _snack('Personal cloud cache unavailable: ' + e.toString());
      });
    });
  }

  void _changed() {
    if(!mounted)return;
    final signedIn=PersonalCloud.instance.signedIn;
    // Reconnect immediately on login without creating a refresh loop:
    // refreshFiles() also notifies listeners.
    if(signedIn!=_previousSignedIn){
      _previousSignedIn=signedIn;
      if(signedIn){
        if(_dashboardForeground && widget.enableBackends){
          PersonalCloud.instance.startLiveInbox();
        }
      }else{
        PersonalCloud.instance.stopLiveInbox();
      }
    }
    // Incoming socket/progress events can burst many times per rendered
    // frame. Coalesce them so scrolling is not interrupted by rebuild storms.
    if(_frameRefreshQueued)return;
    _frameRefreshQueued=true;
    WidgetsBinding.instance.scheduleFrameCallback((_){
      _frameRefreshQueued=false;
      if(mounted)setState((){});
    });
  }

  Future<void> _importEditedCart() async {
    if(!mounted)return;
    final added=ImageEditingCart.instance.takeAll();
    if(added.isEmpty)return;
    final sources=<File>[],names=<String>[],sizes=<int>[];
    for(final item in added){
      if(!await item.file.exists())continue;
      sources.add(item.file);
      names.add(item.name);
      sizes.add(await item.file.length());
    }
    if(sources.isEmpty||!mounted)return;
    setState((){
      _staged.add(PendingBatch(LanEngine.newId(),sources,names,sizes));
    });
    _snack('Edited file is ready in File Share Cart. Tap Send to transfer.');
  }

  @override
  void dispose() {
    _midnight?.cancel();
    PersonalCloud.instance.stopLiveInbox();
    _dashboardScroll.dispose();
    _sidebarVisibleNotifier.dispose();
    _messageController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    appLan.removeListener(_changed);
    PersonalCloud.instance.removeListener(_changed);
    ImageEditingCart.instance.removeListener(_importEditedCart);
    super.dispose();
  }

  void _snack(String message) {
    if(!mounted)return;
    // Transient, non-intercepting top overlay; no dedicated LAN status card.
    FileShareTopNotice.show(context,message,
      duration:const Duration(seconds:4));
  }

  void _navigate(String title) {
    final Widget screen;
    if (title == 'Cloud Setup') {
      screen = CloudConnectPage(mode: widget.mode, onMode: widget.onMode);
    } else if (title == 'My QR') {
      screen = MyQrPage(mode: widget.mode, onMode: widget.onMode);
    } else if (title == 'Devices') {
      screen = NearbyDevicesPage(mode: widget.mode, onMode: widget.onMode);
    } else if (title == 'Files') {
      screen = FileCategoriesPage(mode: widget.mode, onMode: widget.onMode);
    } else if (title == 'Login') {
      screen = LoginPage(mode: widget.mode, onMode: widget.onMode);
    } else if (title == 'Toolbox') {
      screen = const FileShareToolboxPage();
    } else if (title == 'Image Editing') {
      screen = const ImageEditingPage();
    } else {
      screen = FeatureDesignPage(title: title, mode: widget.mode, onMode: widget.onMode);
    }
    if ((Platform.isWindows || Platform.isMacOS) && MediaQuery.sizeOf(context).width >= 820) {
      final nav = _desktopNavigator.currentState;
      if (nav != null) {
        nav.popUntil((route) => route.isFirst);
        if (title != 'Home') nav.push(fadePage(screen));
        return;
      }
    }
    if (title != 'Home') Navigator.of(context).push(fadePage(screen));
  }

  Widget _nav(String label, IconData icon, {bool enabled = true,
    bool pinned = false}) => ListTile(
    leading: Icon(icon, color: FileTheme.violet),
    title: Text(label),
    enabled: enabled,
    trailing: enabled ? const Icon(Icons.chevron_right_rounded)
      : const DesignTag('Later'),
    onTap: enabled ? () {
      if (!pinned) Navigator.pop(context);
      if (pinned || label != 'Home') _navigate(label);
    } : null,
  );

  Widget _navContents({required bool pinned}) => SafeArea(
    child: ListView(children: [
      Padding(padding: const EdgeInsets.all(20),
        child: Row(children: [
          const AppLogo(),
          const SizedBox(width: 12),
          Expanded(child: Text('File Share', style: TextStyle(
            fontWeight: FontWeight.w800, fontSize: 20,
            color: FileTheme.foreground(context)))),
          if (pinned) IconButton(
            tooltip: 'Hide sidebar',
            onPressed: _toggleSidebar,
            icon: const Icon(Icons.menu_open_rounded, color: FileTheme.violet)),
        ])),
      const Divider(height: 12),
      _nav('Home', Icons.home_outlined, pinned: pinned),
      _nav('Files', Icons.folder_outlined, pinned: pinned),
      _nav('Toolbox', Icons.handyman_outlined, pinned: pinned),
      _nav('Devices', Icons.devices_rounded, pinned: pinned),
      _nav('My QR', Icons.qr_code_2_rounded, pinned: pinned),
      _nav('Settings', Icons.settings_outlined, pinned: pinned),
      _nav('Profile', Icons.person_outline_rounded, pinned: pinned),
      AnimatedBuilder(
        animation: PersonalCloud.instance,
        builder: (_, __) => PersonalCloud.instance.signedIn
          ? ListTile(
              leading: const Icon(Icons.logout_rounded, color: FileTheme.violet),
              title: const Text('Logout'),
              onTap: () async {
                // A mistaken tap must never terminate the saved session.
                // Keep the drawer open until the user explicitly confirms.
                final confirmed=await showDialog<bool>(
                  context:context,
                  builder:(dialog)=>AlertDialog(
                    title:const Text('Are you sure you want to logout?'),
                    content:const Text(
                      'You will be signed out of your cloud account. '
                      'Offline LAN sharing will remain available.'),
                    actions:[
                      TextButton(
                        onPressed:()=>Navigator.of(dialog).pop(false),
                        child:const Text('No')),
                      FilledButton(
                        onPressed:()=>Navigator.of(dialog).pop(true),
                        child:const Text('Yes')),
                    ],
                  ),
                );
                // Back, outside tap, No, or a disposed route all cancel.
                if(confirmed!=true||!mounted)return;
                if(!pinned)Navigator.pop(context);
                await PersonalCloud.instance.signOutLocal();
                if(mounted)_snack(
                  'Cloud signed out. Offline LAN stays available.');
              })
          : _nav('Login', Icons.login_rounded, pinned: pinned),
      ),
    ]),
  );

  Widget _drawer() => Drawer(
    backgroundColor: FileTheme.surface(context),
    child: _navContents(pinned: false),
  );

  Widget _desktopSidebar() => Material(
    color: FileTheme.surface(context).withValues(alpha: .93),
    child: Container(
      width: 248,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(
          color: FileTheme.violet.withValues(alpha: .13))),
      ),
      child: _navContents(pinned: true),
    ),
  );


  /// Android shares from WhatsApp/File Manager are draft-only until Send.
  Future<void> _takeSharedFiles() async {
    if(!Platform.isAndroid||!mounted)return;
    try {
      final rows=await _native.invokeMethod<List<dynamic>>('takeSharedFiles');
      final sources=<File>[], names=<String>[], sizes=<int>[];
      for(final row in rows??<dynamic>[]){
        if(row is! Map)continue;
        final path=row['path'],name=row['name'];
        if(path is! String||name is! String)continue;
        final file=File(path);
        if(!await file.exists())continue;
        sources.add(file);
        names.add(name);
        sizes.add(await file.length());
      }
      if(sources.isEmpty)return;
      setState((){
        _staged.add(PendingBatch(LanEngine.newId(),sources,names,sizes));
      });
      _snack('Shared files are ready. Tap Send when you want to transmit.');
    }catch(e){_snack('Could not import shared files: '+e.toString());}
  }

  Future<void> _refreshNearby() async {
    if(_refreshing)return;
    setState(()=>_refreshing=true);
    appLan.refresh();
    if(PersonalCloud.instance.connected){
      unawaited(PersonalCloud.instance.refreshFiles());
    }
    await Future<void>.delayed(const Duration(milliseconds:1200));
    if(mounted)setState(()=>_refreshing=false);
  }

  Future<File?> _preparePickedFile(PlatformFile picked) async {
    final local = picked.path;
    if (local != null && await File(local).exists()) return File(local);
    // SAF/remote providers may expose only a stream. Save in the private
    // staging area without materializing a whole GB/TB file in memory.
    final dir = Directory((await getApplicationSupportDirectory()).path +
      Platform.pathSeparator + 'fileshare_inbox');
    await dir.create(recursive: true);
    final file = File(dir.path + Platform.pathSeparator + 'stage_' +
      LanEngine.newId() + '_' + LanEngine.safeFileName(picked.name));
    final sink = file.openWrite();
    try {
      await for (final chunk in picked.readAsByteStream()) { sink.add(chunk); }
      await sink.close();
      return file;
    } catch (_) {
      await sink.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  /// Camera button next to the + composer. Capture returns a local photo,
  /// then copies it into File Share-owned staging storage. Never auto-send.
  Future<void> _openTransferCamera() async {
    if(_choosing)return;
    setState(()=>_choosing=true);
    try {
      final captured=await Navigator.of(context).push<String>(
        MaterialPageRoute(builder:(_)=>const FileTransferCameraPage()));
      if(captured==null||!mounted)return;
      final source=File(captured);
      if(!await source.exists())throw StateError('Captured photo is missing');
      final root=await getApplicationSupportDirectory();
      final folder=Directory('${root.path}${Platform.pathSeparator}camera_cart');
      await folder.create(recursive:true);
      final originalExt=source.path.toLowerCase();
      final ext=originalExt.endsWith('.png')?'png':
        (originalExt.endsWith('.jpeg')?'jpeg':'jpg');
      final name='Camera_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final target=File('${folder.path}${Platform.pathSeparator}$name');
      await source.copy(target.path);
      final length=await target.length();
      if(length==0){await target.delete();throw StateError('Empty photo');}
      if(!mounted)return;
      setState(() {
        _staged.add(PendingBatch(LanEngine.newId(),[target],[name],[length]));
      });
      _snack('Camera photo added to Cart. Tap Send to transfer.');
    } catch(e) {
      _snack('Camera error: $e');
    } finally {
      if(mounted)setState(()=>_choosing=false);
    }
  }

  Future<void> _choose() async {
    if(_choosing)return;
    setState(()=>_choosing=true);
    try {
      final chosen=await FilePicker.pickFiles(type:FileType.any);
      if(chosen.isEmpty)return;
      final sources=<File>[],names=<String>[],sizes=<int>[];
      for(final selected in chosen){
        final f=await _preparePickedFile(selected);
        if(f==null)continue;
        sources.add(f);
        names.add(selected.name);
        sizes.add(await f.length());
      }
      if(sources.isEmpty){
        _snack('No readable files were selected.');
        return;
      }
      // IMPORTANT: Picking files MUST NOT call the transfer engine.
      setState((){
        _staged.add(PendingBatch(LanEngine.newId(),sources,names,sizes));
      });
    }catch(e){_snack('File selection failed: '+e.toString());}
    finally{if(mounted)setState(()=>_choosing=false);}
  }

  /// Remove only temporary editor-to-cart snapshots after LAN has
  /// durably copied them, never the user's original or image history.
  Future<void> _cleanupEditedCartSnapshots(Iterable<File> sources) async {
    final root=await getApplicationSupportDirectory();
    // Only our transient transfer snapshots; never remove the original,
    // received LAN/Cloud file, or editor history. LAN enqueue has already
    // durably copied the file before this cleanup is called.
    final prefixes=[
      for(final folder in ['image_editing_cart','signature_cart','editor_cart_versions'])
        root.path+Platform.pathSeparator+folder+Platform.pathSeparator,
    ];
    for(final file in sources){
      if(!prefixes.any((prefix)=>file.absolute.path.startsWith(prefix)))continue;
      try{if(await file.exists())await file.delete();}catch(_){}
    }
  }
  /// LAN has absolute priority for the whole Send batch: 1+ reachable
  /// peers means NO Cloudflare upload, regardless of how many are remote.
  /// Only a completed discovery window with zero peers permits cloud.
  Future<void> _sendTypedText() async {
    if(_preparingText||_sending)return;
    final message=_messageController.text;
    String? preparedId;
    if(message.trim().isEmpty){await _send();return;}
    // Immediate local feedback: disk write and network transport remain async.
    setState((){
      _preparingText=true;
      _sendingPreview=message;
      _messageController.clear();
    });
    if(Platform.isAndroid||Platform.isIOS){
      unawaited(HapticFeedback.selectionClick());
    }
    try{
      final id=LanEngine.newId();
      preparedId=id;
      final file=await FileShareText.create(message,id);
      final size=await file.length();
      if(!mounted)return;
      setState(()=>_staged.add(
        PendingBatch(id,[file],[file.uri.pathSegments.last],[size])));
      if(!appLan.started){
        _snack('Text queued in Cart. Send when LAN starts.');
        return;
      }
      await _send();
    }catch(e){
      if(mounted){
        // Never duplicate an already staged message when disk succeeded
        // but routing failed. The file remains in Cart for an explicit retry.
        final retained=_staged.any((batch)=>batch.id==preparedId);
        if(!retained)setState(()=>_messageController.text=message);
        _snack(retained
          ?'Send failed; your text remains in Cart: $e'
          :'Text send failed: $e');
      }
    }finally{
      if(mounted)setState((){
        _preparingText=false;
        _sendingPreview=null;
      });
    }
  }
  Future<void> _send() async {
    if(_sending || _staged.isEmpty || !appLan.started)return;
    setState((){
      _sending=true;
      // Optimistic presentation only; keep the original files in Cart until
      // a real backend queue accepts them. Never fake a delivery tick.
      _sendingPreview??=_staged.first.labels.isNotEmpty
        ?_staged.first.labels.first:'Preparing transfer…';
    });
    if(Platform.isAndroid||Platform.isIOS){
      unawaited(HapticFeedback.selectionClick());
    }
    try {
      // LAN discovery runs continuously. A refresh must not impose a fixed
      // three-second wait before sending. Latest peers still have priority.
      appLan.refresh();
      if(!mounted)return;
      final cloud=PersonalCloud.instance;
      final route=chooseTransferRoute(
        nearbyCount:appLan.peers.length,
        cloudSignedIn:cloud.signedIn,
        autoCloudEnabled:AutoCloudTransferPreference.instance.enabled);
      final useLan=route==TransferRoute.lan;
      final batches=List<PendingBatch>.from(_staged);
      if(route==TransferRoute.pending){
        // Preserve previous no-login behavior: queue locally, never upload.
        for(final batch in batches){
          try{
            await appLan.enqueue(batch.sources,names:batch.labels);
            if(mounted)setState(()=>_staged.remove(batch));
            unawaited(_cleanupEditedCartSnapshots(batch.sources));
          }catch(e){_snack('Could not queue files: '+e.toString());}
        }
        _snack('LAN Pending: auto Cloud is disabled or not logged in. '+
          'Will send when a nearby LAN device connects.');
        return;
      }
      var successful=0,failed=0;
      for(final batch in batches){
        try{
          if(useLan){
            await appLan.enqueue(batch.sources,names:batch.labels);
            successful+=batch.sources.length;
            if(mounted)setState(()=>_staged.remove(batch));
            unawaited(_cleanupEditedCartSnapshots(batch.sources));
          }else{
            final id=appLan.deviceId;
            if(id==null)throw StateError('Device ID unavailable');
            // Send moves each file straight into the Dashboard as a real
            // uploading card. Uploads continue asynchronously; no double send.
            while(batch.sources.isNotEmpty){
              if(appLan.peers.isNotEmpty){
                throw StateError('LAN device appeared. Remaining Cart files will use LAN when Send is tapped.');
              }
              final source=batch.sources.first,name=batch.labels.first;
              cloud.queueDeviceUpload(source,name,id);
              if(mounted)setState((){
                batch.sources.removeAt(0);
                batch.labels.removeAt(0);
                batch.sizes.removeAt(0);
                if(batch.sources.isEmpty)_staged.remove(batch);
              });
              successful++;
            }
          }
        }catch(e){
          failed++;
          _snack(useLan?'LAN queue failed: '+e.toString():
            'Cloud upload stopped. Remaining files kept in Cart: '+e.toString());
        }
      }
      if(failed==0){
        _snack(useLan?'Nearby devices found: sent on LAN only.':
          'No nearby devices: $successful file(s) uploading to Cloudflare.');
      }
    }finally{
      if(mounted)setState((){
        _sending=false;
        if(!_preparingText)_sendingPreview=null;
      });
    }
  }

  Future<void> _saveReceived(LanFile item) async {
    if (!item.incoming || item.state != TransferState.delivered) return;
    try {
      final result = await TransferDownloads.instance.export(
        File(item.path), item.name);
      if (result == null) return; // User cancelled Windows destination picker.
      await TransferDownloads.instance.markSaved('lan_${item.id}');
      _snack(Platform.isAndroid
        ? 'Downloaded to ${_isCloudImage(item.name) ? 'Gallery / DCIM' : 'Downloads'}'
        : 'Saved: $result');
    } catch (e) {
      _snack('Download failed: $e');
    }
  }

  Future<void> _share(LanFile file) async {
    try {
      if (!File(file.path).existsSync() ||
          (file.incoming && file.state != TransferState.delivered)) return;
      if(Platform.isAndroid && file.name.toLowerCase().endsWith('.pdf')) {
        await _native.invokeMethod<void>('openUpstreamPdfTools',{
          'path':file.path,'action':'share',
          'theme':Theme.of(context).brightness==Brightness.dark?'dark':'light',
        });
        return;
      }
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)], text: file.name));
    } catch (e) { _snack('Sharing failed: ' + e.toString()); }
  }

  Future<void> _delete(LanFile file) async {
    try { await appLan.remove(file.id); }
    catch (e) { _snack('Delete failed: ' + e.toString()); }
  }

  Future<void> _openFileTools(LanFile file) async {
    final navigator = (Platform.isWindows || Platform.isMacOS) && _desktopNavigator.currentState != null
      ? _desktopNavigator.currentState! : Navigator.of(context);
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => SelectedFileToolsPage(file: file)));
  }


  List<TimelineGroup> _timeline() {
    final hidden = _staged.map((item) => item.id).toSet();
    final visibleToPeers = appLan.files.where((e) =>
      !e.incoming && e.state != TransferState.queued)
      .map((e) => e.batch).toSet();
    final lan = appLan.files.where((f) =>
      !hidden.contains(f.batch) &&
      (f.state != TransferState.queued || !visibleToPeers.contains(f.batch)) &&
      (_filter == 'All' || (_filter == 'Sent' && !f.incoming) ||
      (_filter == 'Received' && f.incoming))).toList();
    final groupedLan = <String, List<LanFile>>{};
    for (final item in lan) {
      final key = item.batch + ':' +
        (item.peerId.isNotEmpty ? item.peerId : item.peer) + ':' +
        item.incoming.toString();
      groupedLan.putIfAbsent(key, () => []).add(item);
    }
    final timeline = groupedLan.values.map((group) =>
      TimelineGroup(lan: group)).toList();
    final groupedCloud = <String, List<CloudFile>>{};
    for (final item in PersonalCloud.instance.files) {
      final sent = item.deviceTransfer && item.senderId == appLan.deviceId;
      if((_filter == 'Sent' && !sent) ||
         (_filter == 'Received' && sent))continue;
      groupedCloud.putIfAbsent(item.session, () => []).add(item);
    }
    timeline.addAll(groupedCloud.values.map((group) =>
      TimelineGroup(cloud: group)));
    if(_filter!='Received'){
      timeline.addAll(PersonalCloud.instance.outgoingUploads.map(
        (job)=>TimelineGroup(upload:job)));
    }
    timeline.sort((a, b) => b.created.compareTo(a.created));
    return timeline;
  }

  LanFile _cloudAsLocalFile(CloudFile entry, File local) => LanFile(
    id:'cloud_'+entry.id,batch:entry.session,name:entry.name,
    path:local.path,peer:entry.deviceTransfer ? entry.senderName : 'Guest browser',
    incoming:entry.senderId!=appLan.deviceId,
    size:entry.size,created:entry.created,state:TransferState.delivered);

  Future<void> _previewCloud(CloudFile entry) async {
    try{
      final local=await PersonalCloud.instance.download(entry);
      if(!mounted)return;
      final selected=_cloudAsLocalFile(entry,local);
      if(await FileCardOpenRouter.openEditor(
        context,local.path,entry.name))return;
      if(!mounted)return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder:(_)=>FullScreenFilePreview(
          file:selected,
          onSave:(_)=>_saveCloud(entry),
          onDelete:(_)=>_deleteCloud(entry),
          onShare:(_)=>_shareCloud(entry),
          onTools:(_)=>_openCloudTools(entry))));
    }catch(e){_snack('QR Preview failed: '+e.toString());}
  }

  Future<void> _openCloudTools(CloudFile entry) async {
    try{
      final local=await PersonalCloud.instance.download(entry);
      if(!mounted)return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder:(_)=>SelectedFileToolsPage(
          file:_cloudAsLocalFile(entry,local))));
    }catch(e){_snack('QR Tools failed: '+e.toString());}
  }

  Future<void> _saveCloud(CloudFile entry) async {
    try {
      final downloaded = await PersonalCloud.instance.download(entry);
      final result = await TransferDownloads.instance.export(downloaded, entry.name);
      if (result == null) return;
      await TransferDownloads.instance.markSaved('cloud_${entry.id}');
      if(entry.deviceTransfer){
        try{
          await PersonalCloud.instance.acknowledgeDeviceReceipt(entry,appLan.deviceId);
        }catch(e){debugPrint('Delivery receipt failed: $e');}
      }
      _snack(Platform.isAndroid
        ? 'Downloaded to ${_isCloudImage(entry.name) ? 'Gallery / DCIM' : 'Downloads'}'
        : 'Saved: $result');
    } catch (e) { _snack('QR Download failed: $e'); }
  }

  Future<void> _deleteCloud(CloudFile entry) async {
    try { await PersonalCloud.instance.deleteRemote(entry); }
    catch (e) { _snack('QR Delete failed: ' + e.toString()); }
  }

  Future<void> _shareCloud(CloudFile entry) async {
    try {
      final downloaded = await PersonalCloud.instance.download(entry);
      if(Platform.isAndroid && entry.name.toLowerCase().endsWith('.pdf')){
        await _native.invokeMethod<void>('openUpstreamPdfTools',{
          'path':downloaded.path,'action':'share',
          'theme':Theme.of(context).brightness==Brightness.dark?'dark':'light',
        });
        return;
      }
      await SharePlus.instance.share(ShareParams(
        files: [XFile(downloaded.path)], text: entry.name));
    } catch (e) { _snack('QR Share failed: ' + e.toString()); }
  }

  Widget _drafts(BuildContext context) {
    if(_staged.isEmpty)return const SizedBox.shrink();
    bool isImage(String name){
      final n=name.toLowerCase();
      return n.endsWith('.jpg')||n.endsWith('.jpeg')||
        n.endsWith('.png')||n.endsWith('.webp');
    }
    return DesignPanel(child:Column(
      crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Ready to send · '+_staged.fold<int>(0,(v,e)=>v+e.sources.length).toString()+' files',
          style:TextStyle(fontWeight:FontWeight.w800,color:FileTheme.foreground(context))),
        const SizedBox(height:5),
        Text('Nothing goes to a device until you tap Send',
          style:TextStyle(color:FileTheme.muted(context),fontSize:11)),
        for(final batch in _staged)
          for(var i=0;i<batch.sources.length;i++)
            ListTile(
              dense:true,contentPadding:EdgeInsets.zero,
              leading:SizedBox(width:52,height:52,child:isImage(batch.labels[i])
                ?ClipRRect(borderRadius:BorderRadius.circular(8),
                    child:Image.file(batch.sources[i],fit:BoxFit.cover,
                      cacheWidth:120,
                      errorBuilder:(_,__,___)=>const Icon(Icons.image_outlined)))
                :const Icon(Icons.insert_drive_file_outlined,color:FileTheme.pink)),
              title:Text(batch.labels[i],maxLines:1,overflow:TextOverflow.ellipsis),
              onTap:()async{
                final name=batch.labels[i];
                final path=batch.sources[i].path;
                if(await FileCardOpenRouter.openEditor(context,path,name))return;
                if(!context.mounted)return;
                final preview=LanFile(id:batch.id,batch:batch.id,name:name,
                  path:path,peer:'Cart',incoming:false,size:batch.sizes[i],
                  created:DateTime.now(),state:TransferState.queued);
                await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder:(_)=>FullScreenFilePreview(file:preview,
                    onSave:(_ )async{},onDelete:(_ )async{},
                    onShare:(_ )async{await SharePlus.instance.share(
                      ShareParams(files:[XFile(path)]));},
                    onTools:(_ )async{
                      await Navigator.of(context).push(MaterialPageRoute<void>(
                        builder:(_)=>SelectedFileToolsPage(file:preview)));
                    })));
              },
              subtitle:Text(_formatBytes(batch.sizes[i])+' · Not sent',
                style:TextStyle(color:FileTheme.muted(context),fontSize:11)),
              trailing:IconButton(
                tooltip:'Remove selected file',icon:const Icon(Icons.close_rounded),
                onPressed:(){
                  final removed=batch.sources[i];
                  setState((){
                    batch.sources.removeAt(i);
                    batch.labels.removeAt(i);
                    batch.sizes.removeAt(i);
                    if(batch.sources.isEmpty)_staged.remove(batch);
                  });
                  unawaited(_cleanupEditedCartSnapshots([removed]));
                }),
            ),
      ],
    ));
  }

  /// This switch affects only the outgoing remote-device fallback.
  /// Guest QR, logged-in incoming Cloud cards and realtime QR notifications
  /// never observe this setting and therefore remain available at all times.
  Widget _autoCloudTransferToggle({bool compact=false}) =>
    AnimatedBuilder(
      animation:AutoCloudTransferPreference.instance,
      builder:(context,_) {
        final preference=AutoCloudTransferPreference.instance;
        void toggle() {
          unawaited(preference.setEnabled(!preference.enabled).catchError(
            (Object e){if(context.mounted)_snack('Cloud setting: $e');}));
        }
        if(compact)return Row(mainAxisSize:MainAxisSize.min,children:[
          const Icon(Icons.cloud_outlined,size:17,color:FileTheme.violet),
          const SizedBox(width:3),
          Tooltip(message:preference.enabled?'Auto Cloud ON':'Auto Cloud OFF',
            child:InkWell(onTap:toggle,borderRadius:BorderRadius.circular(20),
              child:AnimatedContainer(
                duration:const Duration(milliseconds:170),
                width:42,height:25,padding:const EdgeInsets.all(3),
                decoration:BoxDecoration(
                  borderRadius:BorderRadius.circular(20),
                  color:preference.enabled
                    ?const Color(0xFF0BA4A8):FileTheme.violet.withValues(alpha:.20),
                  border:Border.all(color:FileTheme.violet.withValues(alpha:.55))),
                child:Align(
                  alignment:preference.enabled?Alignment.centerRight:Alignment.centerLeft,
                  child:Container(width:18,height:18,decoration:BoxDecoration(
                    shape:BoxShape.circle,color:preference.enabled
                      ?const Color(0xFF063B45):FileTheme.muted(context)))))),
          ),
        ]);
        return Row(children:[
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('Auto Cloud Transfer',style:TextStyle(fontWeight:FontWeight.w700)),
            Text(preference.enabled?'LAN first; Cloud when no LAN'
                :'LAN only; pending until a device connects',
              style:TextStyle(fontSize:11,color:FileTheme.muted(context))),
          ])),
          Switch.adaptive(value:preference.enabled,onChanged:(value)=>
            unawaited(preference.setEnabled(value))),
        ]);
      },
    );

  Widget _dashboardColumn(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 730;
    final desktop = (Platform.isWindows || Platform.isMacOS) && MediaQuery.sizeOf(context).width >= 820;
    final groups = _timeline();
    final currentKeys={for(final group in groups)_keyOf(group)};
    if(!_timelineSeeded){
      // Restored history must never animate on initial dashboard load.
      _knownTimelineKeys.addAll(currentKeys);
      _timelineSeeded=true;
    }else{
      for(final key in currentKeys){
        if(_knownTimelineKeys.add(key))_pendingArrivalKeys.add(key);
      }
    }
    return Column(children: [
            Padding(
              padding: EdgeInsets.fromLTRB(wide ? 24 : 12,
                wide ? 10 : 2,wide ? 24 : 12,5),
              child: DesignPanel(
                dashboard:true,
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 5),
                child: Row(children: [
                  IconButton(
                    visualDensity:VisualDensity.compact,
                    constraints:const BoxConstraints(minWidth:36,minHeight:38),
                    padding:EdgeInsets.zero,
                    tooltip: desktop
                      ? (_desktopSidebarVisible ? 'Hide sidebar' : 'Show sidebar')
                      : 'Open navigation',
                    onPressed: desktop
                      ? _toggleSidebar
                      : () => _scaffold.currentState?.openDrawer(),
                    icon: Icon(desktop && _desktopSidebarVisible
                      ? Icons.menu_open_rounded : Icons.menu_rounded,
                      color: FileTheme.violet)),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(!_selectionActive?'File Transfer':'${_chosenLan.length+_chosenCloud.length} selected',
                        maxLines:1,overflow:TextOverflow.ellipsis,
                        style: TextStyle(fontSize: wide ? 21 : 15,
                        fontWeight: FontWeight.w800,
                        color: FileTheme.foreground(context))),
                      Text(_selectionActive?'Tap images to select or deselect':appLan.peers.length.toString() + ' nearby LAN device' +
                        (appLan.peers.length==1?'':'s'),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10,
                          color: FileTheme.muted(context))),
                    ])),
                  if(_selectionActive)...[
                    IconButton(tooltip:'Open selected images in Tools',
                      onPressed:_bulkBusy?null:_openSelectedImagesInTools,
                      icon:const Icon(Icons.handyman_outlined,
                        color:FileTheme.violet)),

                    IconButton(tooltip:'Copy selected to folder',
                      onPressed:_bulkBusy?null:_copySelectedToFolder,
                      icon:const Icon(Icons.folder_copy_outlined,
                        color:FileTheme.violet)),
                    IconButton(tooltip:'Select all visible cards',
                      onPressed:_bulkBusy?null:()=>_selectAllCards(groups),
                      icon:const Icon(Icons.select_all_rounded,
                        color:FileTheme.violet)),
                    IconButton(tooltip:'Download selected files',
                      onPressed:_bulkBusy?null:_downloadCards,
                      icon:const Icon(Icons.download_rounded,
                        color:FileTheme.violet)),
                    IconButton(tooltip:'Delete selected cards',
                      onPressed:_bulkBusy?null:_deleteCards,
                      icon:const Icon(Icons.delete_outline_rounded,
                        color:FileTheme.pink)),
                    IconButton(tooltip:'Exit selection mode',
                      onPressed:_bulkBusy?null:()=>setState(_clearSelection),
                      icon:const Icon(Icons.close_rounded)),
                    if(_bulkBusy)const SizedBox(width:17,height:17,
                      child:CircularProgressIndicator(strokeWidth:2)),
                  ]else...[
                    IconButton(visualDensity:VisualDensity.compact,
                       constraints:const BoxConstraints(minWidth:32,minHeight:38),
                       padding:EdgeInsets.zero,tooltip:'My QR',
                      onPressed:()=>_navigate('My QR'),
                      icon:const Icon(Icons.qr_code_2_rounded,
                        color:FileTheme.violet)),
                    _autoCloudTransferToggle(compact:true),
                    AppearanceButton(mode:widget.mode,onChange:widget.onMode,
                      compact:true),
                    IconButton(visualDensity:VisualDensity.compact,
                       constraints:const BoxConstraints(minWidth:34,minHeight:38),
                       padding:EdgeInsets.zero,tooltip:'Refresh nearby LAN devices',
                      onPressed:_refreshing?null:_refreshNearby,
                      icon:AnimatedRotation(
                        turns:_refreshing?2:0,
                        duration:const Duration(milliseconds:1100),
                        curve:Curves.linear,
                        child:const Icon(Icons.refresh_rounded,
                          color:FileTheme.violet))),
                  ],
                ]),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 10),
              child: Row(children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for(final choice in const ['All','Sent','Received'])
                        Padding(padding:const EdgeInsets.only(right:6),
                          child:InkWell(
                            key:ValueKey('filter-$choice'),
                            borderRadius:BorderRadius.circular(14),
                            onTap:()=>setState(()=>_filter=choice),
                            child:AnimatedContainer(
                              duration:const Duration(milliseconds:180),
                              height:32,
                              padding:const EdgeInsets.symmetric(horizontal:10),
                              decoration:BoxDecoration(
                                borderRadius:BorderRadius.circular(14),
                                gradient:LinearGradient(
                                  begin:Alignment.topLeft,end:Alignment.bottomRight,
                                  colors:choice==_filter
                                    ? const [Color(0xFF12A9AC),Color(0xFF007580)]
                                    : FileTheme.dark(context)
                                      ?const [Color(0xFF1C4755),Color(0xFF102F3B)]
                                      :const [Color(0xFFE6F7FD),Color(0xFFCBE9F3)]),
                                border:Border.all(
                                  color:FileTheme.dark(context)
                                    ?const Color(0xFF3B7783):const Color(0xFFF6FCFE)),
                                boxShadow:[BoxShadow(
                                  color:Colors.black.withValues(alpha:.18),
                                  offset:const Offset(0,3),blurRadius:5)]),
                              child:Row(mainAxisSize:MainAxisSize.min,children:[
                                Icon(choice=='All'?Icons.check_rounded
                                  :choice=='Sent'?Icons.send_rounded:Icons.download_rounded,
                                  size:14,color:choice==_filter
                                    ?Colors.white:FileTheme.foreground(context)),
                                const SizedBox(width:5),
                                Text(choice,style:TextStyle(fontSize:12,
                                  fontWeight:FontWeight.w600,
                                  color:choice==_filter
                                    ?Colors.white:FileTheme.foreground(context))),
                              ]),
                            ),
                          )),
                    ]),
                  ),
                ),
              ]),
            ),
            Expanded(child: groups.isNotEmpty
              ? ListView.builder(
                  // Lazy sliver: keep only a small surrounding cache and
                  // reuse GPU repaint layers rather than repainting the feed.
                  controller:_dashboardScroll,
                  reverse:true,
                  cacheExtent:260,
                  addAutomaticKeepAlives:false,
                  addRepaintBoundaries:false,
                  padding:EdgeInsets.fromLTRB(wide?28:15,12,wide?28:15,10),
                  itemCount:groups.length,
                  itemBuilder:(_,i){
                    final group=groups[i];
                    return FileShareScrollDepth(
                      key:ValueKey('scroll-depth:${_keyOf(group)}'),
                      position:_dashboardScroll,
                      child:_multiSelectCard(group));
                  })
              : Center(child: Text('No transfers yet. Choose files with +',
                    style: TextStyle(color: FileTheme.muted(context))))),
            if(_sendingPreview!=null)
              Padding(padding:const EdgeInsets.fromLTRB(14,1,14,5),
                child:TransferBubble(incoming:false,child:Row(children:[
                  const SizedBox(width:19,height:19,
                    child:CircularProgressIndicator(strokeWidth:2)),
                  const SizedBox(width:10),
                  Expanded(child:Text(_sendingPreview!.length>110
                    ?'${_sendingPreview!.substring(0,110)}…':_sendingPreview!,
                    maxLines:2,overflow:TextOverflow.ellipsis,
                    style:const TextStyle(fontSize:12,fontWeight:FontWeight.w600))),
                  const SizedBox(width:7),
                  const Text('Sending…',style:TextStyle(fontSize:10)),
                ]))),
            if (_staged.isNotEmpty && !_sending && !_preparingText)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                child: _drafts(context)),
            Padding(padding:EdgeInsets.fromLTRB(wide?24:10,7,
              wide?24:10,wide?10:0),
              child:DesignPanel(
                dashboard:true,
                padding:const EdgeInsets.symmetric(horizontal:8,vertical:9),
                child:LayoutBuilder(builder:(context,constraints){
                  final small=constraints.maxWidth<365;
                  Widget action(IconData icon,String label,VoidCallback? tap) =>
                    Padding(padding:EdgeInsets.only(right:small?2:4),
                      child:Tooltip(message:label,child:InkWell(
                        onTap:tap,borderRadius:BorderRadius.circular(12),
                        child:Container(
                          width:small?32:37,height:42,
                          decoration:BoxDecoration(
                            gradient:LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,
                              colors:FileTheme.dark(context)
                                ?const [Color(0xFF245667),Color(0xFF103443)]
                                :const [Color(0xFFF0FCFF),Color(0xFFBCE8EC)]),
                            borderRadius:BorderRadius.circular(12),
                            border:Border.all(color:FileTheme.dark(context)
                              ?const Color(0xFF438591):Colors.white),
                            boxShadow:[BoxShadow(color:Colors.black.withValues(alpha:.19),
                              offset:const Offset(0,3),blurRadius:5)]),
                          child:Icon(icon,size:small?19:21,color:FileTheme.violet)))));
                  return Row(children:[
                    action(Icons.add_rounded,'Choose files',_choosing?null:_choose),
                    action(Icons.camera_alt_outlined,'Camera',
                      _choosing?null:_openTransferCamera),
                    action(Icons.handyman_outlined,'Tools',
                      ()=>_navigate('Toolbox')),
                    const SizedBox(width:4),
                    Expanded(child:Container(
                      constraints:const BoxConstraints(minHeight:54),
                      decoration:BoxDecoration(
                        gradient:LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,
                          colors:FileTheme.dark(context)
                            ?const [Color(0xFF173F4D),Color(0xFF0D2D3C)]
                            :const [Color(0xFFE6F7FD),Color(0xFFCBE9F3)]),
                        borderRadius:BorderRadius.circular(15),
                        border:Border.all(color:FileTheme.dark(context)
                          ?const Color(0xFF468896):Colors.white),
                        boxShadow:[BoxShadow(color:Colors.black.withValues(alpha:.13),
                          offset:const Offset(0,3),blurRadius:5)]),
                      child:TextField(
                        controller:_messageController,
                        minLines:1,maxLines:5,
                        textCapitalization:TextCapitalization.sentences,
                        keyboardType:TextInputType.multiline,
                        textInputAction:TextInputAction.newline,
                        style:TextStyle(fontSize:13,color:FileTheme.foreground(context)),
                        decoration:InputDecoration(
                          hintText:'Type or paste a message…',
                          hintStyle:TextStyle(fontSize:small?11:12,
                            color:FileTheme.muted(context)),
                          border:InputBorder.none,
                          filled:false,
                          contentPadding:const EdgeInsets.symmetric(
                            horizontal:12,vertical:16)),
                        onChanged:null))),
                    const SizedBox(width:7),
                    // Rebuild only the Send control for each keystroke, not
                    // the whole chat feed (important for long pasted text).
                    AnimatedBuilder(animation:_messageController,
                      builder:(context,_)=>Tooltip(
                      message:'Send message or selected files',
                      child:InkWell(
                        onTap:(_messageController.text.trim().isEmpty&&_staged.isEmpty)
                            ||_sending||_preparingText?null:()=>unawaited(_sendTypedText()),
                        borderRadius:BorderRadius.circular(15),
                        child:Container(
                          width:small?39:45,height:53,
                          decoration:BoxDecoration(
                            gradient:const LinearGradient(
                              begin:Alignment.topLeft,end:Alignment.bottomRight,
                              colors:[Color(0xFF18C0BE),Color(0xFF008C93),Color(0xFF006D79)]),
                            borderRadius:BorderRadius.circular(15),
                            border:Border.all(color:const Color(0xFF62D0CE)),
                            boxShadow:[BoxShadow(color:Colors.black.withValues(alpha:.24),
                              offset:const Offset(0,5),blurRadius:8)]),
                          child:Icon(Icons.send_rounded,size:23,
                            color:(_messageController.text.trim().isEmpty&&_staged.isEmpty)
                              ?Colors.white54:Colors.white))))),
                  ]);
                }),
              ),
            ),
          ]);
  }

  @override
  Widget build(BuildContext context) {
    final desktop = (Platform.isWindows || Platform.isMacOS) && MediaQuery.sizeOf(context).width >= 820;
    return RootBackGuard(child: Scaffold(
      key: _scaffold,
      drawer: _drawer(),
      body: Container(
        decoration: BoxDecoration(gradient: FileTheme.dashboardBackground(context)),
        child: SafeArea(child: Row(children: [
          if (desktop && _desktopSidebarVisible) _desktopSidebar(),
          Expanded(child: desktop
            ? Navigator(
                key: _desktopNavigator,
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (pageContext) => ListenableBuilder(
                    listenable: _sidebarVisibleNotifier,
                    builder: (context, _) => _dashboardColumn(context))),
              )
            : _dashboardColumn(context)),
        ])),
      ),
    ));
  }
}

class FeatureDesignPage extends StatelessWidget {
  const FeatureDesignPage({
    super.key, required this.title, required this.mode, required this.onMode,
  });
  final String title;
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: BoxDecoration(gradient: FileTheme.background(context)),
      child: SafeArea(child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 6),
          child: DesignPanel(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Row(children: [
              IconButton(tooltip: 'Back to chat',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back_rounded)),
              Expanded(child: Text(title, style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w800,
                color: FileTheme.foreground(context)))),
              AppearanceButton(mode: mode, onChange: onMode),
            ]),
          ),
        ),
        Expanded(child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 750),
          child: ListView(padding: const EdgeInsets.all(15), children: [
            if (title != 'Settings')
              const DesignTag('UI DESIGN ONLY — NO ONLINE SERVICE'),
            const SizedBox(height: 15),
            if (title == 'Home') _home(context),
            if (title == 'Files') _files(context),
            if (title == 'Devices') _devices(context),
            if (title == 'My QR') _qr(context),
            if (title == 'Cloud Setup') _cloud(context),
            if (title == 'Settings') _settings(context),
            if (title == 'Profile') _profile(context),
          ]),
        ))),
      ])),
    ),
  );

  Widget _section(BuildContext c, String heading, String description, Widget content) =>
    DesignPanel(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(heading, style: TextStyle(fontSize: 18,
          fontWeight: FontWeight.w800, color: FileTheme.foreground(c))),
        const SizedBox(height: 6),
        Text(description, style: TextStyle(fontSize: 12,
          height: 1.4, color: FileTheme.muted(c))),
        const SizedBox(height: 17),
        content,
      ],
    ));

  Widget _line(BuildContext c, IconData icon, String name, String detail,
      {Widget? trailing}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 11),
    child: Row(children: [
      Icon(icon, color: FileTheme.violet, size: 24),
      const SizedBox(width: 11),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: TextStyle(
          fontWeight: FontWeight.w700, color: FileTheme.foreground(c))),
        const SizedBox(height: 4),
        Text(detail, maxLines: 3, style: TextStyle(fontSize: 11,
          color: FileTheme.muted(c))),
      ])),
      if (trailing != null) trailing,
    ]),
  );

  Widget _home(BuildContext c) => _section(c,
    'Single unified file dashboard',
    'LAN and online guest QR use the same chronological chat-style feed.',
    Column(children: [
      _line(c, Icons.swipe_left_rounded, 'Received · Left',
        'Download, delete, share externally and share to toolbox'),
      _line(c, Icons.swipe_right_rounded, 'Sent · Right',
        'Delete and share; no download action for the sender'),
      _line(c, Icons.collections_outlined, 'Grouped files',
        'Individual actions and one Download All action for received groups'),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        onPressed: () => Navigator.pop(c),
        icon: const Icon(Icons.arrow_back_rounded),
        label: const Text('Return to unified dashboard')),
    ]));

  Widget _files(BuildContext c) => Column(children: [
    _section(c, 'Selected file preview tray',
      'Visual sample of a selected file at 50%. No upload or file picker is active.',
      Column(children: [
        Row(children: [
          const SizedBox(width: 96, height: 82,
            child: DemoLandscape(variant: 1)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('sunset_photo.jpg', style: TextStyle(
                color: FileTheme.foreground(c), fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('1.93 MB · demo progress', style: TextStyle(
                color: FileTheme.muted(c), fontSize: 11)),
              const SizedBox(height: 10),
              const LinearProgressIndicator(value: .5, minHeight: 7,
                borderRadius: BorderRadius.all(Radius.circular(8))),
              const SizedBox(height: 3),
              Text('50% · not uploading', style: TextStyle(
                color: FileTheme.muted(c), fontSize: 10)),
            ]),
          ),
        ]),
        const SizedBox(height: 20),
        const Row(children: [
          DesignAction(Icons.add_rounded, 'Choose files', size: 44),
          SizedBox(width: 8),
          DesignAction(Icons.handyman_outlined, 'Tools', size: 44),
          Spacer(),
          DesignAction(Icons.send_rounded, 'Send', size: 48),
        ]),
      ]),
    ),
    const SizedBox(height: 14),
    _section(c, 'Supported card designs',
      'All file types appear as chat cards. Thumbnails are preview illustrations.',
      Column(children: [
        _line(c, Icons.photo_outlined, 'Photos', 'Thumbnail + full group preview'),
        _line(c, Icons.videocam_outlined, 'Videos', 'Play indicator and duration'),
        _line(c, Icons.headphones_outlined, 'Audio', 'Audio icon, name and size'),
        _line(c, Icons.description_outlined, 'Documents', 'PDF, ZIP and arbitrary files'),
      ]),
    ),
  ]);

  Widget _devices(BuildContext c) => Column(children: [
    _section(c, 'Nearby devices', 'Real device discovery is not active in this UI phase.',
      Column(children: [
        _line(c, Icons.wifi_off_rounded, 'Connected LAN devices',
          '0 devices detected', trailing: const DesignTag('Not scanning')),
        const Divider(),
        _line(c, Icons.smartphone_rounded, 'Android A (sample)',
          'Same Wi-Fi · Direct peer-to-peer'),
        _line(c, Icons.smartphone_rounded, 'Android B (sample)',
          'Same Wi-Fi · Direct peer-to-peer'),
        _line(c, Icons.desktop_windows_outlined, 'Windows PC (sample)',
          'Same Wi-Fi · Direct peer-to-peer'),
      ]),
    ),
  ]);

  Widget _qr(BuildContext c) => Column(children: [
    _section(c, 'Your permanent guest QR',
      'One QR per account, visible on all linked devices after login and cloud setup.',
      Column(children: [
        Center(child: Container(
          width: 204, height: 204,
          decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(22)),
          child: const Column(mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.qr_code_2_rounded, size: 136, color: Color(0xFF503C79)),
              Text('DEMO · NOT SCANNABLE', style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 10,
                color: FileTheme.pink)),
            ]),
        )),
        const SizedBox(height: 13),
        const DesignTag('QR LOCKED UNTIL LOGIN'),
        const SizedBox(height: 18),
        const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          DesignAction(Icons.copy_rounded, 'Copy QR URL', size: 42),
          SizedBox(width: 10),
          DesignAction(Icons.share_rounded, 'Share QR', size: 42),
          SizedBox(width: 10),
          DesignAction(Icons.refresh_rounded, 'Regenerate QR', size: 42),
          SizedBox(width: 10),
          DesignAction(Icons.delete_rounded, 'Delete QR', size: 42),
        ]),
      ]),
    ),
    const SizedBox(height: 14),
    _section(c, 'Guest browser upload preview',
      'File selection would start upload automatically. The main Upload button remains disabled until success.',
      Column(children: [
        _line(c, Icons.file_present_outlined, 'Selected: 4 photos',
          'Sample 130 MB of 200 MB'),
        const LinearProgressIndicator(value: .65, minHeight: 7,
          borderRadius: BorderRadius.all(Radius.circular(8))),
        const SizedBox(height: 8),
        Text('65% · preview only', style: TextStyle(
          color: FileTheme.muted(c), fontSize: 11)),
        const SizedBox(height: 12),
        const DesignTag('Upload button disabled until complete'),
        const SizedBox(height: 16),
        _line(c, Icons.shield_outlined, 'Per-guest quota',
          '200 MB and up to 4 upload sessions per IST day'),
      ]),
    ),
  ]);

  Widget _cloud(BuildContext c) => Column(children: [
    _section(c, 'Connect your personal Cloudflare',
      'A user connects their own account once through Account ID and restricted API token.',
      Column(children: [
        ListenableBuilder(
          listenable:PersonalCloud.instance,
          builder:(context,_) {
            final cloud=PersonalCloud.instance;
            return _line(c,cloud.connected
                ?Icons.cloud_done_outlined:Icons.cloud_off_outlined,
              'Cloud connection',cloud.connected
                ?'Cloud connected · '+(cloud.workerOrigin??'Personal Worker')
                :cloud.cloudSetupSaved
                  ?'Cloud configured · sign in to reconnect'
                  :'Cloud not connected',
              trailing:DesignTag(cloud.connected?'CONNECTED':'OFFLINE'));
          }),
        const SizedBox(height: 10),
        const TextField(enabled: false, decoration: InputDecoration(
          labelText: 'Cloudflare Account ID', hintText: 'Your Account ID',
          prefixIcon: Icon(Icons.person_pin_outlined))),
        const SizedBox(height: 12),
        const TextField(enabled: false, obscureText: true,
          decoration: InputDecoration(labelText: 'Restricted API Token',
            hintText: 'Never use Global API Key',
            prefixIcon: Icon(Icons.key_outlined))),
        const SizedBox(height: 14),
        const DesignTag('Verify & Auto Connect · disabled'),
      ]),
    ),
    const SizedBox(height: 14),
    _section(c, 'Automatic setup · proposed steps',
      'Account and personal Worker connection status is shown above.',
      Column(children: [
        _line(c, Icons.verified_user_outlined, '1. Verify token',
          'Check account, scope and permissions'),
        _line(c, Icons.storage_outlined, '2. Provision D1',
          'QR, guest sessions, delivery and quota records'),
        _line(c, Icons.storage_outlined, '3. Provision R2',
          'Private cloud files for this user'),
        _line(c, Icons.cloud_upload_outlined, '4. Deploy Worker',
          'Guest upload page on workers.dev'),
        _line(c, Icons.schedule_outlined, '5. Schedule cleanup',
          'Midnight IST, delayed retry if deletion fails'),
      ]),
    ),
  ]);

  Widget _settings(BuildContext c) => Column(children: [
    _section(c, 'Cloud Setup',
      'Manage the personal Cloudflare Worker, account pairing and online Guest QR service from Settings.',
      Column(children: [
        ListenableBuilder(
          listenable: PersonalCloud.instance,
          builder: (context, _) => _line(c, Icons.cloud_outlined,
            'Personal Cloudflare',
            PersonalCloud.instance.connected
              ? 'Connected · Cloud transfer and Guest QR settings'
              : PersonalCloud.instance.cloudSetupSaved
                ? 'Saved setup · Sign in to reconnect'
                : 'Not connected · Offline LAN remains available'),
        ),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity,
          child: FilledButton.icon(
            icon: const Icon(Icons.cloud_sync_outlined),
            label: const Text('Open Cloud Setup'),
            onPressed: () => Navigator.of(c).push(fadePage(
              CloudConnectPage(mode: mode, onMode: onMode))),
          )),
        const SizedBox(height:10),
        SizedBox(width:double.infinity,
          child:OutlinedButton.icon(
            icon:const Icon(Icons.menu_book_outlined),
            label:const Text('Cloud Connect Guide · Beginner to Advanced'),
            onPressed:()=>Navigator.of(c).push(fadePage(
              CloudConnectGuidePage(mode:mode,onMode:onMode))),
          )),
        const SizedBox(height:10),
        SizedBox(width:double.infinity,
          child:FilledButton.icon(
            icon:const Icon(Icons.system_update_alt_rounded),
            label:const Text('App Updates / Check for updates'),
            onPressed:()=>Navigator.of(c).push(fadePage(
              const FileShareUpdatePage())),
          )),
      ]),
    ),
    const SizedBox(height: 14),
    if (Platform.isIOS || Platform.isMacOS) ...[
      _section(c,
        Platform.isIOS ? 'iPhone Files Download Folder'
                       : 'macOS Finder Download Folder',
        'Choose a folder once using the system picker. File Share remembers '
        'the permission for later downloads. Change it here at any time.',
        const AppleDownloadLocationSetting()),
      const SizedBox(height:14),
    ],
    if (Platform.isWindows) ...[
      _section(c, 'Windows Download Destination',
        'Choose a destination each time, or make Downloads the permanent default. '
        'The last successful folder selection is remembered.',
        FutureBuilder<bool>(
          future: TransferDownloads.instance.windowsAlwaysDownloads(),
          builder:(context,snapshot) => SwitchListTile(
            title: const Text('Always save into Downloads'),
            subtitle: Text(snapshot.data==true
              ? 'Do not ask again — save everything to Windows Downloads'
              : 'Ask for a folder on every download; remember last folder'),
            value:snapshot.data??false,
            onChanged: snapshot.hasData ? (value) async {
              await TransferDownloads.instance.setWindowsAlwaysDownloads(value);
              if(c.mounted) (c as Element).markNeedsBuild();
            }:null,
          ),
        )),
      const SizedBox(height:14),
      _section(c, 'Windows Background Receiver',
        'Login starts File Share silently in the tray. Close hides the window; View reopens and Exit stops the app.',
        Column(children: [
          ValueListenableBuilder<bool>(
            valueListenable: WindowsBackground.instance.autoStartEnabled,
            builder: (context, enabled, _) => SwitchListTile(
              title: const Text('Start with Windows'),
              subtitle: const Text('Start silently in the system tray (no dashboard popup)'),
              value: enabled,
              onChanged: (value) async {
                try {
                  await WindowsBackground.instance.setAutoStart(value);
                  await SharedPreferencesAsync().setBool('windows_autostart_decided',true);
                }
                catch (e) {
                  if (c.mounted) FileShareTopNotice.show(c,'Windows startup error: $e');
                }
              },
            ),
          ),
          const ListTile(
            leading: Icon(Icons.notifications_active_outlined),
            title: Text('System notifications'),
            subtitle: Text('Windows will alert you when a LAN file is received'),
          ),
          OutlinedButton.icon(
            onPressed: () => WindowsBackground.instance.exitCompletely(),
            icon: const Icon(Icons.power_settings_new_outlined),
            label: const Text('Exit File Share Completely')),
        ]),
      ),
      const SizedBox(height: 14),
    ],
    if(Platform.isMacOS)...[
      _section(c,'macOS Menu Bar and Login',
        'Login starts File Share quietly in the menu bar. Closing the window '
        'keeps LAN reception available; right-click the FS icon for View / Exit.',
        Column(children:[
          ValueListenableBuilder<bool>(
            valueListenable:WindowsBackground.instance.autoStartEnabled,
            builder:(context,enabled,_)=>SwitchListTile(
              title:const Text('Start with macOS'),
              subtitle:const Text('Start in the menu bar without opening a window'),
              value:enabled,
              onChanged:(value)async{
                try{
                  await WindowsBackground.instance.setAutoStart(value);
                  await SharedPreferencesAsync().setBool(
                    'macos_autostart_decided',true);
                }catch(e){
                  if(c.mounted)FileShareTopNotice.show(c,'macOS startup error: $e');
                }
              },
            )),
          OutlinedButton.icon(
            onPressed:()=>WindowsBackground.instance.exitCompletely(),
            icon:const Icon(Icons.power_settings_new_outlined),
            label:const Text('Exit File Share Completely')),
        ]),
      ),
      const SizedBox(height:14),
    ],
    if (Platform.isAndroid) ...[
      _section(c, 'Android Background Receiver',
        'File Share can receive nearby LAN transfers while the screen is closed. '
        'Android may restrict background services after reboot.',
        const AndroidLanBackgroundSetting()),
      const SizedBox(height: 14),
    ],
    _section(c, 'Appearance', 'Light, dark and follow-system for Android, Windows and macOS.',
      Column(children: [
        _line(c, Icons.color_lens_outlined, 'Appearance mode',
          'Use the active header toggle', trailing:
          AppearanceButton(mode: mode, onChange: onMode)),
        _line(c, Icons.animation_rounded, 'Animations',
          'GPU-rendered transitions, device-dependent refresh rate'),
      ]),
    ),
    const SizedBox(height: 14),
    _section(c, 'Transfer and cleanup', 'These settings are planned, not active.',
      Column(children: [
        _line(c, Icons.wifi_rounded, 'Offline LAN', 'No login, PIN or internet'),
        _line(c, Icons.cloud_outlined, 'Online guest QR',
          'Requires app login and personal Cloudflare'),
        _line(c, Icons.timer_outlined, 'LAN cleanup',
          '24 hours after each transfer, grouped by send batch'),
        _line(c, Icons.nightlight_round, 'QR cleanup',
          'Midnight IST, bounded retry only on error'),
      ]),
    ),
  ]);

  Widget _profile(BuildContext c) => ListenableBuilder(
    listenable:PersonalCloud.instance,
    builder:(context,_) {
      final cloud=PersonalCloud.instance;
      final signedIn=cloud.signedIn;
      final email=cloud.accountEmail?.trim();
      final isConnected=cloud.connected;
      return _section(c,'My profile',
        signedIn?'Your signed-in File Share account and personal cloud.':
          'Use local Wi-Fi sharing as a guest, or sign in for personal cloud.',
        Column(children:[
          const Center(child:FileShareProfileAvatar()),
          const SizedBox(height:8),
          DesignTag(signedIn?'SIGNED IN':'GUEST / OFFLINE'),
          const SizedBox(height:10),
          _line(c,Icons.email_outlined,'Account',
            signedIn?(email?.isNotEmpty==true?email!:'Signed in'):
              'Not signed in'),
          _line(c,isConnected?Icons.cloud_done_outlined:
            Icons.cloud_off_outlined,'Personal Cloudflare',
            isConnected?'Cloud connected':
              cloud.cloudSetupSaved
                ?'Cloud setup saved · Sign in to connect'
                :'Cloud not connected'),
          if(isConnected && cloud.workerOrigin!=null)
            _line(c,Icons.link_rounded,'Cloud Worker',
              cloud.workerOrigin!),
          const SizedBox(height:14),
          SizedBox(width:double.infinity,
            child:OutlinedButton.icon(
              onPressed:()=>Navigator.push(c,fadePage(
                signedIn
                  ?CloudConnectPage(mode:mode,onMode:onMode)
                  :LoginPage(mode:mode,onMode:onMode))),
              icon:Icon(signedIn?Icons.manage_accounts_outlined:
                Icons.login_rounded),
              label:Text(signedIn?'Manage account / cloud':
                'Sign in to File Share'))),
        ]),
      );
    });
}


/// Manual owner-Worker pairing for integration testing. Full API-token
/// provisioning + app email/password login require a central auth service.
class CloudConnectPage extends StatefulWidget {
  const CloudConnectPage({super.key,required this.mode,required this.onMode});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  @override
  State<CloudConnectPage> createState() => _CloudConnectPageState();
}

class _CloudConnectPageState extends State<CloudConnectPage> {
  final _url=TextEditingController();
  final _secret=TextEditingController();
  final _accountId=TextEditingController();
  final _apiToken=TextEditingController();
  late final CloudflareProvisioner _provisioner;
  bool _busy=false, _show=false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _url.text=PersonalCloud.instance.endpoint ?? '';
    _provisioner=CloudflareProvisioner()..addListener(_cloudProgress);
  }

  void _cloudProgress(){if(mounted)setState((){});}

  @override
  void dispose() {
    _provisioner.removeListener(_cloudProgress);
    _provisioner.dispose();
    _accountId.dispose();
    _apiToken.dispose();
    _url.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _autoConnect() async {
    if(_busy)return;
    setState((){_busy=true;_message=null;});
    try{
      final result=await _provisioner.provision(_accountId.text,_apiToken.text);
      _apiToken.clear(); // Admin token is never persisted.
      await PersonalCloud.instance.connectWorker(
        result.workerUrl,result.ownerSecret);
      _url.text=result.workerUrl;
      if(mounted)setState(()=>_message='Worker, private D1 database, R2 bucket '
        'and guest QR page connected. Create your account below.');
    }catch(e){
      if(mounted)setState(()=>_message='Setup could not finish: '+e.toString());
    }finally{
      _apiToken.clear();
      if(mounted)setState(()=>_busy=false);
    }
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {_busy=true;_message=null;});
    try {
      await PersonalCloud.instance.connectWorker(_url.text,_secret.text);
      await PersonalCloud.instance.loadQr();
      await PersonalCloud.instance.refreshFiles();
      if(mounted)setState((){_message='Worker connected securely. Inbox loaded.';});
    }catch(e){
      if(mounted)setState((){_message='Connection failed: '+e.toString();});
    }finally{if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _disconnect() async {
    final confirm=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
      title:const Text('Disconnect this Worker?'),
      content:const Text('Only the saved app connection is removed. Files on Cloudflare remain unchanged.'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Disconnect')),
      ],
    ));
    if(confirm!=true)return;
    await PersonalCloud.instance.disconnect();
    if(mounted)setState(()=>_message='Cloud connection removed.');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body:Container(
      decoration:BoxDecoration(gradient:FileTheme.background(context)),
      child:SafeArea(child:Center(child:ConstrainedBox(
        constraints:const BoxConstraints(maxWidth:700),
        child:ListView(padding:const EdgeInsets.all(18),children:[
          Row(children:[
            IconButton(tooltip:'Back',onPressed:()=>Navigator.pop(context),
              icon:const Icon(Icons.arrow_back_rounded)),
            Expanded(child:Text('Personal Cloud Setup',style:TextStyle(
              fontWeight:FontWeight.w800,fontSize:18,
              color:FileTheme.foreground(context)))),
            AppearanceButton(mode:widget.mode,onChange:widget.onMode),
          ]),
          const SizedBox(height:18),
          DesignPanel(child:Column(
            crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              Text('One-time Cloudflare Auto Setup',textAlign:TextAlign.center,
                style:TextStyle(fontSize:20,fontWeight:FontWeight.w800,
                  color:FileTheme.foreground(context))),
              const SizedBox(height:9),
              Text('Use your own Cloudflare account. No paid domain needed. '
                'Enable your R2 bucket service and workers.dev address first.',
                textAlign:TextAlign.center,style:TextStyle(
                  fontSize:12,height:1.45,color:FileTheme.muted(context))),
              const SizedBox(height:15),
              TextField(controller:_accountId,enabled:!_busy,
                decoration:const InputDecoration(
                  labelText:'Cloudflare Account ID',
                  prefixIcon:Icon(Icons.account_tree_outlined))),
              const SizedBox(height:12),
              TextField(controller:_apiToken,enabled:!_busy,
                obscureText:!_show,autocorrect:false,
                decoration:InputDecoration(
                  labelText:'Restricted Cloudflare API Token',
                  prefixIcon:const Icon(Icons.key_outlined),
                  suffixIcon:IconButton(
                    tooltip:'Show or hide secret',
                    onPressed:()=>setState(()=>_show=!_show),
                    icon:Icon(_show?Icons.visibility_off_outlined:
                      Icons.visibility_outlined)))),
              const SizedBox(height:10),
              Text('API Token permissions: Workers Scripts Read/Write, '
                'D1 Read/Write and Workers R2 Storage Write. The token is '
                'used once and cleared; it is not stored by File Share.',
                style:TextStyle(fontSize:12,height:1.4,
                  color:FileTheme.muted(context))),
              const SizedBox(height:15),
              FilledButton.icon(onPressed:_busy?null:_autoConnect,
                icon:const Icon(Icons.verified_user_outlined),
                label:const Text('Verify & Auto Connect')),
              if(_provisioner.busy)...[
                const SizedBox(height:12),
                const LinearProgressIndicator(),
                Text(_provisioner.status,
                  style:TextStyle(color:FileTheme.muted(context))),
              ],
            ])),
          const SizedBox(height:12),
          DesignPanel(child:Column(
            crossAxisAlignment:CrossAxisAlignment.stretch,
            children:[
              const Icon(Icons.cloud_sync_outlined,color:FileTheme.violet,size:48),
              const SizedBox(height:10),
              Text('Connect your own Cloudflare Worker',
                textAlign:TextAlign.center,style:TextStyle(
                  fontWeight:FontWeight.w800,fontSize:19,
                  color:FileTheme.foreground(context))),
              const SizedBox(height:10),
              Text('Advanced option: manually pair an existing personal Worker. It must already have D1, R2 and the OWNER_TOKEN setup secret.',
                textAlign:TextAlign.center,style:TextStyle(
                  color:FileTheme.muted(context),fontSize:12,height:1.4)),
              const SizedBox(height:20),
              TextField(controller:_url,keyboardType:TextInputType.url,
                enabled:!_busy,decoration:const InputDecoration(
                  labelText:'Your Worker HTTPS URL',
                  hintText:'https://name.account.workers.dev',
                  prefixIcon:Icon(Icons.link_rounded))),
              const SizedBox(height:12),
              TextField(controller:_secret,obscureText:!_show,
                enabled:!_busy,autocorrect:false,
                decoration:InputDecoration(
                  labelText:'Worker owner secret (not API Token)',
                  prefixIcon:const Icon(Icons.lock_outline_rounded),
                  suffixIcon:IconButton(
                    tooltip:_show?'Hide owner secret':'Show owner secret',
                    onPressed:()=>setState(()=>_show=!_show),
                    icon:Icon(_show?Icons.visibility_off_outlined:Icons.visibility_outlined)))),
              const SizedBox(height:16),
              FilledButton.icon(onPressed:_busy?null:_connect,
                icon:_busy?const SizedBox(width:18,height:18,
                  child:CircularProgressIndicator(strokeWidth:2))
                    :const Icon(Icons.verified_user_outlined),
                label:const Text('Verify & Connect')),
              if(PersonalCloud.instance.connected)...[
                const SizedBox(height:12),
                OutlinedButton.icon(onPressed:_busy?null:_disconnect,
                  icon:const Icon(Icons.link_off_rounded),
                  label:const Text('Disconnect stored cloud account')),
              ],
              if(PersonalCloud.instance.cloudSetupSaved)...[
                const SizedBox(height:12),
                OutlinedButton.icon(
                  onPressed:()=>Navigator.push(context,fadePage(
                    LoginPage(mode:widget.mode,onMode:widget.onMode))),
                  icon:const Icon(Icons.person_add_alt_1_rounded),
                  label:const Text('Create account or Login')),
              ],
              if(_message!=null)...[
                const SizedBox(height:14),
                Text(_message!,style:TextStyle(
                  color:FileTheme.foreground(context),fontSize:12)),
              ],
            ],
          )),
          const SizedBox(height:14),
          DesignPanel(child:Column(crossAxisAlignment:CrossAxisAlignment.start,
            children:[
              Text('One-time deployment checklist',style:TextStyle(
                fontWeight:FontWeight.w800,color:FileTheme.foreground(context))),
              const SizedBox(height:12),
              const Text('1. Enter your Cloudflare Account ID and restricted API token above.\n'
                '2. Tap Verify & Auto Connect — the app creates D1, R2 and your private Worker.\n'
                '3. The app installs its D1 schema, binds your resources and saves the owner secret securely.\n'
                '4. After setup succeeds, create your email/password account.\n'
                '5. Verify your email to enable automatic login on another device; then open My QR and Generate.'),
            ])),
        ]),
      ))),
    ),
  );
}

class MyQrPage extends StatefulWidget {
  const MyQrPage({super.key,required this.mode,required this.onMode});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  @override
  State<MyQrPage> createState()=>_MyQrPageState();
}

class _MyQrPageState extends State<MyQrPage> {
  bool _busy=false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if(PersonalCloud.instance.signedIn){
      WidgetsBinding.instance.addPostFrameCallback((_)=>_run(()
        =>PersonalCloud.instance.loadQr()));
    }
  }

  Future<void> _run(Future<Object?> Function() work) async {
    if(_busy)return;
    setState((){_busy=true;_error=null;});
    try{await work();}
    catch(e){if(mounted)setState(()=>_error=e.toString());}
    finally{if(mounted)setState(()=>_busy=false);}
  }


  @override
  Widget build(BuildContext context) {
    final cloud=PersonalCloud.instance;
    final link=cloud.qrLink;
    return Scaffold(
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:SafeArea(child:Center(child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:690),
          child:ListView(padding:const EdgeInsets.all(19),children:[
            Row(children:[
              IconButton(tooltip:'Back',onPressed:()=>Navigator.pop(context),
                icon:const Icon(Icons.arrow_back_rounded)),
              Expanded(child:Text('My Permanent QR',
                style:TextStyle(fontWeight:FontWeight.w800,
                  fontSize:19,color:FileTheme.foreground(context)))),
              AppearanceButton(mode:widget.mode,onChange:widget.onMode),
            ]),
            const SizedBox(height:20),
            DesignPanel(child:Column(children:[
              const Icon(Icons.qr_code_2_rounded,color:FileTheme.violet,size:40),
              const SizedBox(height:13),
              Text(link==null?'No active QR yet':'Your guest upload QR',
                style:TextStyle(fontWeight:FontWeight.w800,fontSize:19,
                  color:FileTheme.foreground(context))),
              const SizedBox(height:10),
              Text(cloud.signedIn
                  ? 'Your Guest QR remains available in both Auto Cloud modes.'
                  : 'Connect your own Cloudflare Worker first.',
                style:TextStyle(color:FileTheme.muted(context),fontSize:12),
                textAlign:TextAlign.center),
              const SizedBox(height:22),
              if(link!=null)
                Container(padding:const EdgeInsets.all(14),
                  decoration:BoxDecoration(color:Colors.white,
                    borderRadius:BorderRadius.circular(17)),
                  child:QrImageView(data:link,size:235,
                    backgroundColor:Colors.white)),
              if(link==null)
                const Icon(Icons.qr_code_scanner_rounded,
                  size:130,color:FileTheme.violet),
              const SizedBox(height:16),
              if(link!=null)
                SelectableText(link,textAlign:TextAlign.center,
                  style:TextStyle(color:FileTheme.foreground(context),fontSize:12)),
              const SizedBox(height:20),
              if(!cloud.signedIn)
                FilledButton.icon(
                  onPressed:()=>Navigator.pushReplacement(context,fadePage(
                    cloud.cloudSetupSaved
                      ? LoginPage(mode:widget.mode,onMode:widget.onMode)
                      : CloudConnectPage(mode:widget.mode,onMode:widget.onMode))),
                  icon:const Icon(Icons.cloud_outlined),
                  label:Text(cloud.cloudSetupSaved
                    ? 'Login to Personal Cloud' : 'Connect Personal Cloud')),
              if(cloud.signedIn && link==null)
                FilledButton.icon(
                  onPressed:_busy?null:()=>_run(()=>cloud.createQr()),
                  icon:const Icon(Icons.add_circle_outline_rounded),
                  label:const Text('Generate Permanent QR')),
              if(cloud.signedIn && link!=null)...[
                Wrap(spacing:8,runSpacing:8,alignment:WrapAlignment.center,
                  children:[
                    OutlinedButton.icon(
                      onPressed:()=>Clipboard.setData(ClipboardData(text:link)),
                      icon:const Icon(Icons.copy_rounded),
                      label:const Text('Copy Link')),
                    OutlinedButton.icon(
                      onPressed:()=>SharePlus.instance.share(ShareParams(text:link)),
                      icon:const Icon(Icons.share_outlined),
                      label:const Text('Share QR')),
                    OutlinedButton.icon(
                      onPressed:_busy?null:()=>_run(
                        ()=>printGuestQr(link)),
                      icon:const Icon(Icons.print_rounded),
                      label:const Text('Print QR')),
                    OutlinedButton.icon(
                      onPressed:_busy?null:()=>_run(()=>cloud.regenerateQr()),
                      icon:const Icon(Icons.refresh_rounded),
                      label:const Text('Regenerate')),
                  ]),
              ],
              if(_busy)const Padding(padding:EdgeInsets.all(14),
                child:CircularProgressIndicator()),
              if(_error!=null)Padding(padding:const EdgeInsets.all(12),
                child:Text(_error!,style:const TextStyle(
                  color:Colors.deepOrange,fontSize:12))),
            ])),
            const SizedBox(height:14),
            DesignPanel(child:AnimatedBuilder(
              animation:AutoCloudTransferPreference.instance,
              builder:(context,_) {
                final pref=AutoCloudTransferPreference.instance;
                return Row(children:[
                  const Icon(Icons.cloud_outlined,color:FileTheme.violet),
                  const SizedBox(width:12),
                  Expanded(child:Column(
                    crossAxisAlignment:CrossAxisAlignment.start,children:[
                      const Text('Auto Cloud Transfer',
                        style:TextStyle(fontWeight:FontWeight.w700)),
                      Text(pref.enabled
                        ? 'ON: LAN first; Cloud if zero LAN devices and logged in'
                        : 'OFF: LAN only; files wait for a LAN device',
                        style:TextStyle(fontSize:11,
                          color:FileTheme.muted(context))),
                      const SizedBox(height:3),
                      const Text('Guest QR always works in either mode.',
                        style:TextStyle(fontSize:11,color:FileTheme.violet)),
                    ])),
                  Switch.adaptive(value:pref.enabled,
                    onChanged:(value){
                      unawaited(pref.setEnabled(value).catchError((Object e){
                        if(context.mounted)FileShareTopNotice.show(context,'Could not save Cloud setting: $e');
                      }));
                    }),
                ]);
              },
            )),
            const SizedBox(height:14),
            DesignPanel(child:Text(
              'Guest limit: 200 MB total and 4 upload sessions per IST day. '
              'Every guest has a separate browser-based quota. All temporary QR '
              'files expire at 12:00 AM IST.',
              style:TextStyle(fontSize:12,height:1.5,
                color:FileTheme.muted(context)))),
          ]),
        ))),
      ),
    );
  }
}


/// Nearby devices use Android UDP/NSD and iOS native Bonjour discovery.
class NearbyDevicesPage extends StatelessWidget {
  const NearbyDevicesPage({super.key,required this.mode,required this.onMode});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  @override
  Widget build(BuildContext context) => Scaffold(
    body:Container(
      decoration:BoxDecoration(gradient:FileTheme.background(context)),
      child:SafeArea(child:Center(child:ConstrainedBox(
        constraints:const BoxConstraints(maxWidth:750),
        child:Column(children:[
          Row(children:[
            IconButton(tooltip:'Back',onPressed:()=>Navigator.pop(context),
              icon:const Icon(Icons.arrow_back_rounded)),
            Expanded(child:Text('Nearby Devices',style:TextStyle(
              fontSize:19,fontWeight:FontWeight.w800,
              color:FileTheme.foreground(context)))),
            IconButton(tooltip:'Refresh LAN devices',
              onPressed:appLan.refresh,
              icon:const Icon(Icons.refresh_rounded,color:FileTheme.violet)),
            AppearanceButton(mode:mode,onChange:onMode),
          ]),
          Expanded(child:AnimatedBuilder(animation:appLan,builder:(context,_) {
            final peers=appLan.peers.values.toList()
              ..sort((a,b)=>a.name.compareTo(b.name));
            return ListView(padding:const EdgeInsets.all(15),children:[
              DesignPanel(child:Row(children:[
                const Icon(Icons.wifi_rounded,color:FileTheme.violet,size:32),
                const SizedBox(width:12),
                Expanded(child:Text(
                  peers.isEmpty?'No LAN devices connected'
                    :peers.length.toString()+' LAN devices nearby',
                  style:TextStyle(fontWeight:FontWeight.w800,
                    color:FileTheme.foreground(context)))),
              ])),
              const SizedBox(height:10),
              if(appLan.error != null)
                Padding(padding:const EdgeInsets.fromLTRB(12,4,12,12),
                  child:Text(appLan.error!,
                    textAlign:TextAlign.center,
                    style:const TextStyle(color:Colors.deepOrange,fontSize:12))),
              if(peers.isEmpty)
                Padding(padding:const EdgeInsets.all(22),
                  child:Text(Platform.isIOS
                    ? 'On iPhone: Settings → Privacy & Security → Local Network → allow File Share. Keep both phones on the same Wi-Fi (not a guest network), turn off VPN, and tap Refresh.'
                    : 'Keep File Share open on both phones on the same Wi-Fi. Turn off guest Wi-Fi isolation/VPN and tap Refresh. Discovery does not need internet.',
                    textAlign:TextAlign.center,
                    style:TextStyle(color:FileTheme.muted(context)))),
              for(final peer in peers)
                Padding(padding:const EdgeInsets.only(bottom:10),
                  child:DesignPanel(child:Row(children:[
                    const Icon(Icons.devices_rounded,color:FileTheme.pink,size:30),
                    const SizedBox(width:12),
                    Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,
                      children:[
                        Text(peer.name,style:TextStyle(
                          fontWeight:FontWeight.w800,
                          color:FileTheme.foreground(context))),
                        const SizedBox(height:4),
                        Text(peer.address+' · Local Wi-Fi',
                          style:TextStyle(color:FileTheme.muted(context),fontSize:11)),
                      ])),
                    const DesignTag('Nearby'),
                  ]))),
            ]);
          })),
        ]),
      ))),
    ),
  );
}

class FileCategoriesPage extends StatelessWidget {
  const FileCategoriesPage({super.key,required this.mode,required this.onMode});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  static bool _image(String name){
    final ext=name.toLowerCase();
    return ['.jpg','.jpeg','.png','.gif','.webp','.bmp','.heic']
      .any(ext.endsWith);
  }
  Future<void> _save(LanFile item) async {
    if(!item.incoming||item.state!=TransferState.delivered)return;
    final dir=await getDownloadsDirectory();
    if(dir==null)throw StateError('Downloads not available');
    await dir.create(recursive:true);
    final target=File(dir.path+Platform.pathSeparator+
      LanEngine.newId()+'_'+LanEngine.safeFileName(item.name));
    await File(item.path).openRead().pipe(target.openWrite());
  }
  Future<void> _share(LanFile item) async {
    await SharePlus.instance.share(ShareParams(files:[XFile(item.path)]));
  }
  Future<void> _delete(LanFile item)=>appLan.remove(item.id);
  Future<void> _openTools(BuildContext context, LanFile item) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SelectedFileToolsPage(file: item)));
  }

  Widget _rows(BuildContext context,List<LanFile> entries){
    if(entries.isEmpty){
      return Center(child:Text('No files in this category',
        style:TextStyle(color:FileTheme.muted(context))));
    }
    return ListView.builder(
      padding:const EdgeInsets.all(12),itemCount:entries.length,
      itemBuilder:(context,i){
        final item=entries[i];
        return Padding(padding:const EdgeInsets.only(bottom:9),
          child:DesignPanel(padding:const EdgeInsets.all(8),
            child:ListTile(
              leading:SizedBox(width:58,height:60,child:_image(item.name)
                ?ClipRRect(borderRadius:BorderRadius.circular(9),
                    child:Image.file(File(item.path),fit:BoxFit.cover,
                      cacheWidth:150,errorBuilder:(_,__,___)=>
                        const Icon(Icons.image_not_supported_outlined)))
                :const Icon(Icons.description_outlined,color:FileTheme.pink)),
              title:Text(item.name,maxLines:1,overflow:TextOverflow.ellipsis),
              subtitle:Text(_formatBytes(item.size)+' · '+item.state.name),
              trailing:const Icon(Icons.chevron_right_rounded),
              onTap:()async{
                if(await FileCardOpenRouter.openEditor(
                  context,item.path,item.name))return;
                if(!context.mounted)return;
                await Navigator.push(context,MaterialPageRoute<void>(
                  builder:(_)=>FullScreenFilePreview(
                    file:item,onSave:_save,onDelete:_delete,onShare:_share,
                    onTools:(file)=>_openTools(context,file))));
              },
            )),
        );
      },
    );
  }

  Widget _folders(BuildContext context,List<LanFile> entries){
    final grouped=<String,List<LanFile>>{};
    for(final item in entries){
      grouped.putIfAbsent(item.batch,()=>[]).add(item);
    }
    if(grouped.isEmpty)return Center(child:Text('No transfer folders yet',
      style:TextStyle(color:FileTheme.muted(context))));
    return ListView(padding:const EdgeInsets.all(12),children:[
      for(final group in grouped.values)
        Padding(padding:const EdgeInsets.only(bottom:9),
          child:DesignPanel(child:ExpansionTile(
            leading:const Icon(Icons.folder_outlined,color:FileTheme.violet),
            title:Text('Transfer group · '+group.length.toString()+' files'),
            subtitle:Text(group.first.created.toLocal().toString().split('.').first),
            children:[
              for(final item in group)
                ListTile(title:Text(item.name,maxLines:1,overflow:TextOverflow.ellipsis),
                  subtitle:Text(_formatBytes(item.size)),
                  trailing:const Icon(Icons.chevron_right_rounded),
                  onTap:()async{
                    if(await FileCardOpenRouter.openEditor(
                      context,item.path,item.name))return;
                    if(!context.mounted)return;
                    await Navigator.push(context,MaterialPageRoute<void>(
                      builder:(_)=>FullScreenFilePreview(file:item,
                        onSave:_save,onDelete:_delete,onShare:_share,
                        onTools:(file)=>_openTools(context,file))));
                  }),
            ],
          ))),
    ]);
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length:3,child:Scaffold(
      body:Container(
        decoration:BoxDecoration(gradient:FileTheme.background(context)),
        child:SafeArea(child:Column(children:[
          Row(children:[
            IconButton(onPressed:()=>Navigator.pop(context),
              tooltip:'Back',icon:const Icon(Icons.arrow_back_rounded)),
            Expanded(child:Text('Files',style:TextStyle(
              fontSize:19,fontWeight:FontWeight.w800,
              color:FileTheme.foreground(context)))),
            AppearanceButton(mode:mode,onChange:onMode),
          ]),
          const TabBar(tabs:[
            Tab(icon:Icon(Icons.image_outlined),text:'Images'),
            Tab(icon:Icon(Icons.description_outlined),text:'Documents'),
            Tab(icon:Icon(Icons.folder_outlined),text:'Folders'),
          ]),
          Expanded(child:AnimatedBuilder(
            animation:appLan,builder:(context,_){
              final all=appLan.files.where((item)=>
                (item.state==TransferState.delivered||
                item.state==TransferState.queued) &&
                File(item.path).existsSync()).toList();
              return TabBarView(children:[
                _rows(context,all.where((e)=>_image(e.name)).toList()),
                _rows(context,all.where((e)=>!_image(e.name)).toList()),
                _folders(context,all),
              ]);
            },
          )),
        ])),
      ),
    ),
  );
}
