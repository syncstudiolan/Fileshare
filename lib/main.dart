import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart' as desktop_tray;
import 'package:local_notifier/local_notifier.dart';

import 'lan_engine.dart';
import 'personal_cloud.dart';
import 'cloudflare_provisioning.dart';
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
  // CI emulator only: run the real LAN backend without first-use tapping.
  const ciLanTest = bool.fromEnvironment('FILE_SHARE_BACKGROUND_VALIDATION');
  // Explicit CI Windows smoke only; never changes ordinary first-run behavior.
  final windowsSmoke = Platform.isWindows && args.contains('--lan-smoke');
  final offline = ciLanTest || previousOffline || windowsSmoke;
  appLan.onReceived = (file) => Platform.isAndroid
      ? const MethodChannel('file_share.native').invokeMethod<void>(
          'notifyReceived', {'name': file.name, 'sender': file.peer})
      : Platform.isWindows
          ? WindowsBackground.instance.notifyReceived(file)
          : Future<void>.value();
  if (Platform.isWindows) {
    try { await WindowsBackground.instance.initialize(); }
    catch (e) { debugPrint('Windows tray unavailable: $e'); }
  }
  if (offline && (Platform.isAndroid || Platform.isWindows)) {
    unawaited(appLan.start().catchError((Object e) {
      debugPrint('Background LAN start failed: $e');
    }));
  }
  if (Platform.isWindows && args.contains('--background')) {
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
    offlineDefault: offline,
  ));
}


/// Windows: one live Flutter process, even when its window is hidden.
class WindowsBackground with WindowListener, desktop_tray.TrayListener {
  WindowsBackground._();
  static final instance = WindowsBackground._();
  final ValueNotifier<bool> autoStartEnabled = ValueNotifier(false);
  bool _trayReady = false, _exiting = false, _notificationsReady = false;

  Future<void> initialize() async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    // Maximize the normal Windows window; do not hide the system taskbar.
    await windowManager.maximize();
    final icon = await _writeTrayIcon();
    await desktop_tray.trayManager.setIcon(icon.path);
    await desktop_tray.trayManager.setToolTip('File Share — LAN receiver');
    await desktop_tray.trayManager.setContextMenu(desktop_tray.Menu(items: [
      desktop_tray.MenuItem(key: 'show', label: 'Open File Share'),
      desktop_tray.MenuItem.separator(),
      desktop_tray.MenuItem(key: 'exit', label: 'Exit Completely'),
    ]));
    desktop_tray.trayManager.addListener(this);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    _trayReady = true;
    try {
      final result = await Process.run('reg', [
        'query', _windowsRunKey, '/v', 'FileShare',
      ]);
      autoStartEnabled.value = result.exitCode == 0 &&
        result.stdout.toString().contains(Platform.resolvedExecutable);
    } catch (e) { debugPrint('Startup preference error: $e'); }
    try {
      await localNotifier.setup(appName: 'File Share',
        shortcutPolicy: ShortcutPolicy.requireCreate);
      _notificationsReady = true;
    } catch (e) { debugPrint('Windows toast setup error: $e'); }
  }

  static const _windowsRunKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  Future<void> setAutoStart(bool value) async {
    if (!Platform.isWindows) return;
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
    if (!Platform.isWindows) return;
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() {
    if (_trayReady && !_exiting) unawaited(windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() { unawaited(showWindow()); }

  @override
  void onTrayMenuItemClick(desktop_tray.MenuItem item) {
    if (item.key == 'show') unawaited(showWindow());
    if (item.key == 'exit') unawaited(exitCompletely());
  }

  Future<void> exitCompletely() async {
    if (_exiting) return;
    _exiting = true;
    try { await appLan.stop(); } catch (_) { }
    try { await desktop_tray.trayManager.destroy(); } catch (_) { }
    try { await windowManager.setPreventClose(false); } catch (_) { }
    await windowManager.destroy();
  }

  // Tiny, programmatically created ICO. No image resource increases APK size.
  Future<File> _writeTrayIcon() async {
    const side = 16, pixelBytes = side * side * 4, maskBytes = side * 4;
    const imageBytes = 40 + pixelBytes + maskBytes;
    final data = ByteData(22 + imageBytes);
    data.setUint16(2, 1, Endian.little);
    data.setUint16(4, 1, Endian.little);
    data.setUint8(6, side);
    data.setUint8(7, side);
    data.setUint16(10, 1, Endian.little);
    data.setUint16(12, 32, Endian.little);
    data.setUint32(14, imageBytes, Endian.little);
    data.setUint32(18, 22, Endian.little);
    data.setUint32(22, 40, Endian.little);
    data.setInt32(26, side, Endian.little);
    data.setInt32(30, side * 2, Endian.little);
    data.setUint16(34, 1, Endian.little);
    data.setUint16(36, 32, Endian.little);
    data.setUint32(42, pixelBytes, Endian.little);
    final bytes = data.buffer.asUint8List();
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final p = 62 + (y * side + x) * 4;
        final painted = x > 1 && x < 14 && y > 1 && y < 14;
        bytes[p] = painted ? 197 : 0;
        bytes[p + 1] = painted ? 93 : 0;
        bytes[p + 2] = painted ? 224 : 0;
        bytes[p + 3] = painted ? 255 : 0;
      }
    }
    final folder = await getApplicationSupportDirectory();
    final icon = File(folder.path + Platform.pathSeparator + 'file_share_tray.ico');
    await icon.writeAsBytes(bytes, flush: true);
    return icon;
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

class _FileShareAppState extends State<FileShareApp> {
  late ThemeMode _mode = widget.initialMode;

  void _setMode(ThemeMode value) {
    setState(() => _mode = value);
    SharedPreferencesAsync().setString('appearance', value.name);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'File Share',
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
  static const pink = Color(0xFFE84D9F);
  static const violet = Color(0xFF765ADB);
  static const night = Color(0xFF171528);

  static bool dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color surface(BuildContext context) =>
      dark(context) ? const Color(0xFF2C2744) : const Color(0xFFFFFBFF);

  static Color foreground(BuildContext context) =>
      dark(context) ? const Color(0xFFF7F1FF) : const Color(0xFF251A3C);

  static Color muted(BuildContext context) =>
      dark(context) ? const Color(0xFFBBB0D0) : const Color(0xFF6D6484);

  static Gradient background(BuildContext context) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: dark(context)
            ? const [Color(0xFF171528), Color(0xFF2B2044), Color(0xFF19182D)]
            : const [Color(0xFFF5DDF4), Color(0xFFE7E3FD), Color(0xFFFFF4FA)],
      );

  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: violet,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: dark ? night : const Color(0xFFF8F0FA),
      appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF302B49) : Colors.white,
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}

class AppearanceButton extends StatelessWidget {
  const AppearanceButton({
    super.key,
    required this.mode,
    required this.onChange,
  });
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChange;

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
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: FileTheme.surface(context).withValues(alpha: .9),
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

Route<T> fadePage<T>(Widget child) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 310),
      reverseTransitionDuration: const Duration(milliseconds: 240),
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
              begin: const Offset(.045, .02),
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
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Press Back ' +
              (3 - _backCount).toString() +
              ' more time(s) to exit'),
        ),
      );
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
  const AppLogo({super.key, this.size = 48});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [FileTheme.pink, FileTheme.violet],
          ),
          borderRadius: BorderRadius.circular(size * .3),
        ),
        child: Icon(Icons.swap_horiz_rounded,
            size: size * .56, color: Colors.white),
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
  final _emailCode=TextEditingController();
  bool _register=false,_hidden=true,_busy=false;
  bool _awaitingEmailVerification=false;
  bool _personalAccountRegistered=false;
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
    _emailCode.dispose();
    super.dispose();
  }
  Future<void> _enterDashboard()async{
    await SharedPreferencesAsync().setBool('offline_start',true);
    if(!mounted)return;
    Navigator.of(context).pushAndRemoveUntil(fadePage(
      DashboardPage(mode:widget.mode,onMode:widget.onMode)),(_)=>false);
  }

  Future<void> _requestEmailVerification() async {
    final cloud=PersonalCloud.instance;
    if(!AccountDirectory.instance.enabled){
      throw StateError('Email-only login requires the File Share directory '
        'to be configured by the app publisher');
    }
    await cloud.requestEmailLink();
    if(mounted)setState(()=>_awaitingEmailVerification=true);
  }

  Future<void> _confirmEmail() async {
    if(_busy)return;
    if(!RegExp(r'^[0-9]{8}$').hasMatch(_emailCode.text.trim())){
      setState(()=>_error='Enter the 8-digit code sent to your email');
      return;
    }
    setState((){_busy=true;_error=null;});
    try {
      await PersonalCloud.instance.verifyEmailLink(_emailCode.text);
      await _enterDashboard();
    }catch(e){
      if(mounted)setState(()=>_error=e.toString());
    }finally{
      if(mounted)setState(()=>_busy=false);
    }
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
        if(directory.enabled){
          await _requestEmailVerification();
          return;
        }
      }else if(directory.enabled){
        // New devices use ONLY email/password. Directory discovers the
        // correct personal Cloudflare Worker and verifies it.
        await cloud.loginByEmail(_email.text,_password.text);
      }else{
        // Explicit backwards-compatible fallback for private installations
        // without the official global discovery service.
        await cloud.loginAccount(_workerUrl.text,_email.text,_password.text);
      }
      await _enterDashboard();
    }catch(e){
      if(mounted)setState(()=>_error=e.toString().replaceFirst('Bad state: ',''));
    }finally{if(mounted)setState(()=>_busy=false);}
  }

  Future<void> _linkExistingAccount()async{
    if(_busy)return;
    setState((){_busy=true;_error=null;});
    try{await _requestEmailVerification();}
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
              Text(_awaitingEmailVerification?'Verify your email':
                (_register?'Create your account':'Welcome back'),
                textAlign:TextAlign.center,style:TextStyle(
                  fontSize:28,fontWeight:FontWeight.w800,
                  color:FileTheme.foreground(context))),
              const SizedBox(height:9),
              Text(_awaitingEmailVerification
                ? 'We sent an 8-digit one-time code to your email. '
                  'Confirm it to enable automatic cloud recovery on every device.'
                : 'Sign in with email and password on any device. '
                  'File Share finds your personal Cloudflare Worker automatically.',
                textAlign:TextAlign.center,
                style:TextStyle(color:FileTheme.muted(context),height:1.4)),
              const SizedBox(height:24),
              if(_awaitingEmailVerification)...[
                Text('Email: ',style:TextStyle(
                  color:FileTheme.foreground(context))),
                Text(PersonalCloud.instance.accountEmail??_email.text,
                  textAlign:TextAlign.center),
                const SizedBox(height:16),
                TextField(controller:_emailCode,keyboardType:TextInputType.number,
                  maxLength:8,enabled:!_busy,
                  decoration:const InputDecoration(
                    labelText:'8-digit email verification code',
                    prefixIcon:Icon(Icons.mark_email_read_outlined))),
                if(_error!=null)Text(_error!,
                  style:const TextStyle(color:Colors.deepOrange)),
                const SizedBox(height:9),
                FilledButton(
                  onPressed:_busy?null:_confirmEmail,
                  child:Text(_busy?'Checking…':'Verify and finish setup')),
                TextButton(onPressed:_busy?null:_linkExistingAccount,
                  child:const Text('Resend verification email')),
              ]else Form(key:_key,child:Column(children:[
                if(!AccountDirectory.instance.enabled && !_register)...[
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
                if(AccountDirectory.instance.enabled &&
                   PersonalCloud.instance.signedIn && !_register)
                  TextButton.icon(
                    onPressed:_busy?null:_linkExistingAccount,
                    icon:const Icon(Icons.mark_email_read_outlined),
                    label:const Text('Enable email-only login for this account')),
              ])),
              const SizedBox(height:15),
              Text(AccountDirectory.instance.enabled
                ? 'On a new Android or Windows device, enter only this email '
                  'and password. The directory finds your personal Worker.'
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
  const DesignPanel({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: FileTheme.surface(context).withValues(alpha: .90),
      border: Border.all(color: FileTheme.violet.withValues(alpha: .11)),
      borderRadius: BorderRadius.circular(24),
      boxShadow: [BoxShadow(color: FileTheme.violet.withValues(alpha: .085),
        offset: const Offset(0, 5), blurRadius: 20)],
    ),
    child: child,
  );
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
    final maxWidth = MediaQuery.sizeOf(context).width > 740 ? 570.0 : 440.0;
    return Align(
      alignment: sent ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: FileTheme.dark(context)
              ? (sent ? const Color(0xFF3C315E) : const Color(0xFF4B294B))
              : (sent ? const Color(0xFFF0E7FF) : const Color(0xFFFFDDED)),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(23), topRight: const Radius.circular(23),
            bottomLeft: Radius.circular(sent ? 23 : 6),
            bottomRight: Radius.circular(sent ? 6 : 23),
          ),
          border: Border.all(color: FileTheme.pink.withValues(alpha: .12)),
          boxShadow: [BoxShadow(color: FileTheme.violet.withValues(alpha: .10),
            blurRadius: 18, offset: const Offset(0, 6))],
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


/// Real file preview. Uses a zoomable full-screen image and the same actions
/// as the file card; no duplicate upload is initiated from here.
class FullScreenFilePreview extends StatelessWidget {
  const FullScreenFilePreview({super.key, required this.file,
    required this.onSave, required this.onDelete, required this.onShare});
  final LanFile file;
  final Future<void> Function(LanFile) onSave, onDelete, onShare;

  bool get isPicture {
    final name=file.name.toLowerCase();
    return name.endsWith('.jpg')||name.endsWith('.jpeg')||
      name.endsWith('.png')||name.endsWith('.webp')||name.endsWith('.gif');
  }

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
            tooltip:'Open in another app',
            onPressed:file.state==TransferState.delivered
              ?()=>OpenFilex.open(file.path):null,
            icon:const Icon(Icons.open_in_new_rounded,color:Colors.white)),
          IconButton(
            tooltip:'Share to another app',
            onPressed:file.state==TransferState.delivered
              ?()=>onShare(file):null,
            icon:const Icon(Icons.ios_share_rounded,color:Colors.white)),
          const IconButton(
            tooltip:'Toolbox coming later',
            onPressed:null,
            icon:Icon(Icons.auto_fix_high_rounded,color:Colors.white54)),
        ]),
      ),
    ])),
  );
}

class LiveTransferCard extends StatelessWidget {
  const LiveTransferCard({
    super.key, required this.items, required this.onSave,
    required this.onDelete, required this.onShare,
  });
  final List<LanFile> items;
  final Future<void> Function(LanFile) onSave;
  final Future<void> Function(LanFile) onDelete;
  final Future<void> Function(LanFile) onShare;

  bool get incoming => items.first.incoming;

  bool _photo(String path) {
    final name = path.toLowerCase();
    return name.endsWith('.jpg') || name.endsWith('.jpeg') ||
      name.endsWith('.png') || name.endsWith('.webp') || name.endsWith('.gif');
  }

  Widget _visual(LanFile file) {
    if (_photo(file.name) && File(file.path).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(File(file.path), fit: BoxFit.cover,
          cacheWidth: 250,
          errorBuilder: (_, __, ___) => const Icon(Icons.image_not_supported_outlined,
            color: FileTheme.pink, size: 35)));
    }
    final name = file.name.toLowerCase();
    return Icon(name.endsWith('.mp4') || name.endsWith('.mov')
      ? Icons.play_circle_outline_rounded
      : (name.endsWith('.pdf') ? Icons.picture_as_pdf_outlined
        : Icons.insert_drive_file_outlined), color: FileTheme.pink, size: 34);
  }

  Widget _buttons(BuildContext context, LanFile file) => Wrap(
    spacing: 1,
    runSpacing: 0,
    children: [
      if (incoming)
        IconButton(
          tooltip: 'Save received file',
          onPressed: file.state == TransferState.delivered
            ? () => onSave(file) : null,
          icon: const Icon(Icons.download_rounded, color: FileTheme.pink)),
      IconButton(
        tooltip: 'Delete local card',
        onPressed: () => onDelete(file),
        icon: const Icon(Icons.delete_outline_rounded, color: FileTheme.pink)),
      IconButton(
        tooltip: 'Share to another app',
        onPressed: file.state == TransferState.delivered
            ? () => onShare(file) : null,
        icon: const Icon(Icons.ios_share_rounded, color: FileTheme.pink)),
      IconButton(
        tooltip: 'Open in another app',
        onPressed: file.state == TransferState.delivered
          ? () => OpenFilex.open(file.path) : null,
        icon: const Icon(Icons.open_in_new_rounded, color: FileTheme.pink)),
      const IconButton(
        tooltip: 'Toolbox coming later',
        onPressed: null,
        icon: Icon(Icons.auto_fix_high_rounded, color: FileTheme.pink)),
    ],
  );

  void _preview(BuildContext context,LanFile file){
    if(file.state!=TransferState.delivered &&
       file.state!=TransferState.queued)return;
    Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>
      FullScreenFilePreview(file:file,onSave:onSave,
        onDelete:onDelete,onShare:onShare)));
  }

  Widget _file(BuildContext context, LanFile file) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(children: [
      GestureDetector(
        onTap:()=>_preview(context,file),
        child:SizedBox(width: 78,height:78,child:Center(child:_visual(file))),
      ),
      const SizedBox(width: 9),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w700,
              color: FileTheme.foreground(context), fontSize: 13)),
          Text(_formatBytes(file.size) + ' · ' + file.state.name,
            style: TextStyle(color: FileTheme.muted(context), fontSize: 11)),
          const SizedBox(height: 5),
          if (file.state == TransferState.sending ||
              file.state == TransferState.receiving ||
              file.state == TransferState.preparing)
            LinearProgressIndicator(value: file.progress,
              minHeight: 5, borderRadius: BorderRadius.circular(9)),
          _buttons(context, file),
        ],
      )),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final first = items.first;
    final multiple = items.length > 1;
    final wide = MediaQuery.sizeOf(context).width > 750;
    final bodyWidth = wide ? 580.0 : MediaQuery.sizeOf(context).width * .89;
    return Align(
      alignment: incoming ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(maxWidth: bodyWidth),
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: FileTheme.dark(context)
              ? (incoming ? const Color(0xFF482945) : const Color(0xFF382B57))
              : (incoming ? const Color(0xFFFFDCED) : const Color(0xFFF0E7FF)),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(22),
            topRight: const Radius.circular(22),
            bottomLeft: Radius.circular(incoming ? 6 : 22),
            bottomRight: Radius.circular(incoming ? 22 : 6)),
          border: Border.all(color: FileTheme.violet.withValues(alpha: .15)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(multiple
                ? items.length.toString() + ' Files (Group)' : first.name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: FileTheme.foreground(context),
                fontWeight: FontWeight.w800, fontSize: 14))),
            DesignTag(incoming ? 'Received' : 'Sent', received: incoming),
          ]),
          const SizedBox(height: 5),
          Text((incoming ? 'From ' : 'To ') + first.peer + ' · Offline LAN',
            style: TextStyle(color: FileTheme.muted(context), fontSize: 11)),
          const SizedBox(height: 6),
          ...items.take(multiple ? 4 : 1).map((entry) => _file(context, entry)),
          if (items.length > 4)
            Text('+ ' + (items.length - 4).toString() + ' more files',
              style: TextStyle(color: FileTheme.muted(context), fontSize: 11)),
          if (incoming && multiple)
            TextButton.icon(
              onPressed: items.every((f) => f.state == TransferState.delivered)
                ? () async { for (final item in items) { await onSave(item); } }
                : null,
              icon: const Icon(Icons.download_for_offline_outlined),
              label: const Text('Download All')),
          Align(
            alignment: Alignment.centerRight,
            child: Text(first.created.toLocal().toString().substring(11, 16),
              style: TextStyle(color: FileTheme.muted(context), fontSize: 10))),
        ]),
      ),
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


class CloudInboxCard extends StatelessWidget {
  const CloudInboxCard({super.key, required this.items,
    required this.onSave, required this.onDelete, required this.onShare});
  final List<CloudFile> items;
  final Future<void> Function(CloudFile) onSave, onDelete, onShare;

  @override
  Widget build(BuildContext context) {
    final first=items.first;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width>700
          ? 580 : MediaQuery.sizeOf(context).width*.90),
        margin: const EdgeInsets.symmetric(vertical: 7),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: FileTheme.dark(context)
            ? const Color(0xFF482945) : const Color(0xFFFFDDED),
          border: Border.all(color: FileTheme.pink.withValues(alpha: .17)),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(22), topRight: Radius.circular(22),
            bottomLeft: Radius.circular(5), bottomRight: Radius.circular(22))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,children: [
          Row(children: [
            Expanded(child: Text(items.length>1
              ? items.length.toString()+' Files (QR Group)' : first.name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: FileTheme.foreground(context),
                fontWeight: FontWeight.w800))),
            const DesignTag('Received',received:true),
          ]),
          const SizedBox(height: 7),
          Text('From Guest browser · Guest QR · Online',
            style: TextStyle(color: FileTheme.muted(context),fontSize:11)),
          for(final file in items.take(5))
            Row(children: [
              const Icon(Icons.insert_drive_file_outlined,
                color:FileTheme.pink,size:32),
              const SizedBox(width:9),
              Expanded(child: Column(crossAxisAlignment:CrossAxisAlignment.start,
                children: [
                  Text(file.name,maxLines:1,overflow:TextOverflow.ellipsis,
                    style:TextStyle(color:FileTheme.foreground(context),
                      fontWeight:FontWeight.w700,fontSize:12)),
                  Text(_formatBytes(file.size),
                    style:TextStyle(color:FileTheme.muted(context),fontSize:11)),
                ])),
              IconButton(tooltip:'Download received QR file',
                onPressed:()=>onSave(file),
                icon:const Icon(Icons.download_rounded,color:FileTheme.pink)),
              IconButton(tooltip:'Delete QR file',
                onPressed:()=>onDelete(file),
                icon:const Icon(Icons.delete_outline_rounded,color:FileTheme.pink)),
              IconButton(tooltip:'Share QR file externally',
                onPressed:()=>onShare(file),
                icon:const Icon(Icons.ios_share_rounded,color:FileTheme.pink)),
            ]),
          if(items.length>5)
            Text('+ '+(items.length-5).toString()+' more files',
              style:TextStyle(color:FileTheme.muted(context),fontSize:12)),
          if(items.length>1)
            TextButton.icon(
              onPressed:()async{for(final f in items){await onSave(f);}},
              icon:const Icon(Icons.download_for_offline_outlined),
              label:const Text('Download All')),
          Align(alignment:Alignment.centerRight,
            child:Text('Guest QR · '+first.created.toLocal().toString().substring(11,16),
              style:TextStyle(color:FileTheme.muted(context),fontSize:10))),
        ]),
      ),
    );
  }
}

class TimelineGroup {
  const TimelineGroup({this.lan, this.cloud});
  final List<LanFile>? lan;
  final List<CloudFile>? cloud;
  DateTime get created => lan?.first.created ?? cloud!.first.created;
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
  String _filter = 'All';
  bool _choosing = false;
  bool _showSamples = true;
  bool _refreshing = false;
  bool _desktopSidebarVisible = true;
  final _sidebarVisibleNotifier = ValueNotifier<bool>(true);
  final _desktopNavigator = GlobalKey<NavigatorState>();

  void _toggleSidebar(){
    setState(()=>_desktopSidebarVisible=!_desktopSidebarVisible);
    _sidebarVisibleNotifier.value=_desktopSidebarVisible;
  }
  static const _native = MethodChannel('file_share.native');
  Timer? _midnight;

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
      unawaited(appLan.cleanExpired());
      PersonalCloud.instance.removeExpiredLocalEntries();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _armMidnight();
    appLan.addListener(_changed);
    PersonalCloud.instance.addListener(_changed);
    if (widget.enableBackends) WidgetsBinding.instance.addPostFrameCallback((_) {
      appLan.start().then((_) async {
        if (Platform.isAndroid) {
          _native.setMethodCallHandler((call) async {
            if(call.method=='sharesReceived') await _takeSharedFiles();
          });
          try { await _native.invokeMethod<bool>('startLanService'); }
          catch(e){ _snack('Background LAN limited: '+e.toString()); }
          await _takeSharedFiles();
        }
        if (mounted) setState(() {});
      }).catchError((Object e) { _snack('LAN start failed: ' + e.toString()); });
      PersonalCloud.instance.restore().then((_) =>
        PersonalCloud.instance.cleanupLocalCache()).catchError((Object e) {
          _snack('Personal cloud storage unavailable: ' + e.toString());
        });
    });
  }

  void _changed() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    _midnight?.cancel();
    _sidebarVisibleNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    appLan.removeListener(_changed);
    PersonalCloud.instance.removeListener(_changed);
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)));
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
    } else {
      screen = FeatureDesignPage(title: title, mode: widget.mode, onMode: widget.onMode);
    }
    if (Platform.isWindows && MediaQuery.sizeOf(context).width >= 820) {
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
      _nav('Devices', Icons.devices_rounded, pinned: pinned),
      _nav('My QR', Icons.qr_code_2_rounded, pinned: pinned),
      _nav('Cloud Setup', Icons.cloud_outlined, pinned: pinned),
      _nav('Settings', Icons.settings_outlined, pinned: pinned),
      _nav('Profile', Icons.person_outline_rounded, pinned: pinned),
      AnimatedBuilder(
        animation: PersonalCloud.instance,
        builder: (_, __) => PersonalCloud.instance.signedIn
          ? ListTile(
              leading: const Icon(Icons.logout_rounded, color: FileTheme.violet),
              title: const Text('Logout'),
              onTap: () async {
                if (!pinned) Navigator.pop(context);
                await PersonalCloud.instance.signOutLocal();
                _snack('Cloud signed out. Offline LAN stays available.');
              })
          : _nav('Login', Icons.login_rounded, pinned: pinned),
      ),
    ]),
  );

  Widget _drawer() => Drawer(
    backgroundColor: FileTheme.surface(context),
    child: _navContents(pinned: false),
  );

  Widget _desktopSidebar() => Container(
    width: 248,
    decoration: BoxDecoration(
      color: FileTheme.surface(context).withValues(alpha: .93),
      border: Border(right: BorderSide(
        color: FileTheme.violet.withValues(alpha: .13))),
    ),
    child: _navContents(pinned: true),
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
        _showSamples=false;
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
        _showSamples=false;
        _staged.add(PendingBatch(LanEngine.newId(),sources,names,sizes));
      });
    }catch(e){_snack('File selection failed: '+e.toString());}
    finally{if(mounted)setState(()=>_choosing=false);}
  }

  Future<void> _send() async {
    if(_staged.isEmpty || !appLan.started)return;
    final batches=List<PendingBatch>.from(_staged);
    for(final batch in batches){
      try {
        // This persists a private copy and queues even with ZERO peers.
        await appLan.enqueue(batch.sources,names:batch.labels);
        if(mounted)setState(()=>_staged.remove(batch));
      }catch(e){_snack('Could not queue selected files: '+e.toString());}
    }
    if(appLan.peers.isEmpty){
      _snack('Saved to Pending. Will send when nearby devices appear.');
    }
  }

  Future<void> _saveReceived(LanFile item) async {
    if (!item.incoming || item.state != TransferState.delivered) return;
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads == null) throw StateError('Downloads directory unavailable');
      await downloads.create(recursive: true);
      var target = File(downloads.path + Platform.pathSeparator +
        LanEngine.safeFileName(item.name));
      var index = 1;
      while (await target.exists()) {
        target = File(downloads.path + Platform.pathSeparator +
          index.toString() + '_' + LanEngine.safeFileName(item.name));
        index++;
      }
      await File(item.path).openRead().pipe(target.openWrite());
      _snack('Saved to Downloads: ' + target.path);
    } catch (e) {
      _snack('Could not save to Downloads. Try external Share. ' + e.toString());
    }
  }

  Future<void> _share(LanFile file) async {
    try {
      if (file.state != TransferState.delivered) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)], text: file.name));
    } catch (e) { _snack('Sharing failed: ' + e.toString()); }
  }

  Future<void> _delete(LanFile file) async {
    try { await appLan.remove(file.id); }
    catch (e) { _snack('Delete failed: ' + e.toString()); }
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
    if (_filter != 'Sent') {
      final groupedCloud = <String, List<CloudFile>>{};
      for (final item in PersonalCloud.instance.files) {
        groupedCloud.putIfAbsent(item.session, () => []).add(item);
      }
      timeline.addAll(groupedCloud.values.map((group) =>
        TimelineGroup(cloud: group)));
    }
    timeline.sort((a, b) => b.created.compareTo(a.created));
    return timeline;
  }

  Future<void> _saveCloud(CloudFile entry) async {
    try {
      final downloaded = await PersonalCloud.instance.download(entry);
      final downloads = await getDownloadsDirectory();
      if (downloads == null) throw StateError('Downloads directory not available');
      await downloads.create(recursive: true);
      final name = LanEngine.safeFileName(entry.name);
      var target = File(downloads.path + Platform.pathSeparator + name);
      var suffix = 1;
      while (await target.exists()) {
        target = File(downloads.path + Platform.pathSeparator +
          suffix.toString() + '_' + name);
        suffix++;
      }
      await downloaded.openRead().pipe(target.openWrite());
      _snack('Guest QR file saved to Downloads.');
    } catch (e) { _snack('QR Download failed: ' + e.toString()); }
  }

  Future<void> _deleteCloud(CloudFile entry) async {
    try { await PersonalCloud.instance.deleteRemote(entry); }
    catch (e) { _snack('QR Delete failed: ' + e.toString()); }
  }

  Future<void> _shareCloud(CloudFile entry) async {
    try {
      final downloaded = await PersonalCloud.instance.download(entry);
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
              subtitle:Text(_formatBytes(batch.sizes[i])+' · Not sent',
                style:TextStyle(color:FileTheme.muted(context),fontSize:11)),
              trailing:IconButton(
                tooltip:'Remove selected file',icon:const Icon(Icons.close_rounded),
                onPressed:(){
                  setState((){
                    batch.sources.removeAt(i);
                    batch.labels.removeAt(i);
                    batch.sizes.removeAt(i);
                    if(batch.sources.isEmpty)_staged.remove(batch);
                  });
                }),
            ),
      ],
    ));
  }

  Widget _dashboardColumn(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 730;
    final desktop = Platform.isWindows && MediaQuery.sizeOf(context).width >= 820;
    final groups = _timeline();
    final useDemo = _showSamples && groups.isEmpty && _staged.isEmpty;
    final samples = mockTransfers.where((f) =>
      _filter == 'All' || (_filter == 'Sent' && f.sent) ||
      (_filter == 'Received' && !f.sent)).toList();
    return Column(children: [
            Padding(
              padding: EdgeInsets.fromLTRB(wide ? 24 : 10, 10,
                wide ? 24 : 10, 5),
              child: DesignPanel(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 5),
                child: Row(children: [
                  IconButton(
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
                      Text('File Transfer', style: TextStyle(fontSize: wide ? 21 : 17,
                        fontWeight: FontWeight.w800,
                        color: FileTheme.foreground(context))),
                      Text(appLan.peers.length.toString() + ' nearby LAN devices · ' +
                        (appLan.started ? 'LAN active' : 'Starting LAN') +
                        (PersonalCloud.instance.connected ? ' · QR Cloud connected' : ' · Cloud not connected'),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10,
                          color: FileTheme.muted(context))),
                    ])),
                  IconButton(tooltip: 'QR design preview',
                    onPressed: () => _navigate('My QR'),
                    icon: const Icon(Icons.qr_code_2_rounded,
                      color: FileTheme.violet)),
                  AppearanceButton(mode: widget.mode, onChange: widget.onMode),
                  IconButton(tooltip:'Refresh nearby LAN devices',
                    onPressed:_refreshing?null:_refreshNearby,
                    icon:AnimatedRotation(
                      turns:_refreshing?2:0,
                      duration:const Duration(milliseconds:1100),
                      curve:Curves.linear,
                      child:const Icon(Icons.refresh_rounded,color:FileTheme.violet))),
                ]),
              ),
            ),
            if (appLan.error != null)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 15),
                child: Text(appLan.error!, maxLines: 2,
                  style: const TextStyle(color: Colors.deepOrange, fontSize: 10))),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 10),
              child: Row(children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final choice in const ['All', 'Sent', 'Received'])
                        Padding(padding: const EdgeInsets.only(right: 5),
                          child: ChoiceChip(label: Text(choice),
                            selected: choice == _filter,
                            onSelected: (_) => setState(() => _filter = choice))),
                    ]),
                  ),
                ),
                if (groups.isEmpty)
                  TextButton(onPressed: () => setState(() =>
                    _showSamples = !_showSamples),
                    child: Text(_showSamples ? 'Hide demo' : 'View demo')),
              ]),
            ),
            if (useDemo)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(children: [
                  const DesignTag('SAMPLE DATA'),
                  const SizedBox(width: 7),
                  Expanded(child: Text('Example cards only — no real files',
                    maxLines: 1, style: TextStyle(fontSize: 10,
                      color: FileTheme.muted(context)))),
                ])),
            Expanded(child: groups.isNotEmpty
              ? ListView.builder(
                  padding: EdgeInsets.symmetric(horizontal: wide ? 28 : 12),
                  itemCount: groups.length,
                  itemBuilder: (_, i) => groups[i].lan != null
                    ? LiveTransferCard(items: groups[i].lan!,
                        onSave: _saveReceived, onDelete: _delete, onShare: _share)
                    : CloudInboxCard(items: groups[i].cloud!,
                        onSave: _saveCloud, onDelete: _deleteCloud,
                        onShare: _shareCloud))
              : useDemo
                ? ListView.builder(
                    padding: EdgeInsets.symmetric(horizontal: wide ? 28 : 12),
                    itemCount: samples.length,
                    itemBuilder: (_, i) => DesignFileCard(transfer: samples[i]))
                : Center(child: Text('No transfers yet. Choose files with +',
                    style: TextStyle(color: FileTheme.muted(context))))),
            if (_staged.isNotEmpty)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                child: _drafts(context)),
            Padding(padding: EdgeInsets.fromLTRB(wide ? 24 : 10, 5,
              wide ? 24 : 10, 10),
              child: DesignPanel(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                child: Row(children: [
                  IconButton.filledTonal(
                    tooltip: 'Choose files',
                    onPressed: _choosing ? null : _choose,
                    icon: const Icon(Icons.add_rounded)),
                  const IconButton(
                    tooltip: 'Tools coming later',
                    onPressed: null,
                    icon: Icon(Icons.handyman_outlined)),
                  Expanded(child: Text(_staged.isEmpty
                      ? 'Choose files to send...'
                      : _staged.length.toString() + ' selection(s)',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12,
                      color: FileTheme.muted(context)))),
                  IconButton.filled(
                    tooltip: 'Send selected files',
                    onPressed: _staged.isEmpty ? null : () => unawaited(_send()),
                    icon: const Icon(Icons.send_rounded)),
                ]),
              ),
            ),
          ]);
  }

  @override
  Widget build(BuildContext context) {
    final desktop = Platform.isWindows && MediaQuery.sizeOf(context).width >= 820;
    return RootBackGuard(child: Scaffold(
      key: _scaffold,
      drawer: _drawer(),
      body: Container(
        decoration: BoxDecoration(gradient: FileTheme.background(context)),
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
          '200 MB and up to 4 upload sessions per rolling 24 hours'),
      ]),
    ),
  ]);

  Widget _cloud(BuildContext c) => Column(children: [
    _section(c, 'Connect your personal Cloudflare',
      'A user connects their own account once through Account ID and restricted API token.',
      Column(children: [
        _line(c, Icons.cloud_off_outlined, 'Cloud connection',
          'Not connected · no Cloudflare requests are being made',
          trailing: const DesignTag('Offline')),
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
      'The provisioning engine will run later; no live resources exist.',
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
    if (Platform.isWindows) ...[
      _section(c, 'Windows Background Receiver',
        'Closing the window hides File Share in the tray. The LAN engine keeps receiving while Windows is awake.',
        Column(children: [
          ValueListenableBuilder<bool>(
            valueListenable: WindowsBackground.instance.autoStartEnabled,
            builder: (context, enabled, _) => SwitchListTile(
              title: const Text('Start with Windows'),
              subtitle: const Text('Launch File Share when you sign in to Windows'),
              value: enabled,
              onChanged: (value) async {
                try { await WindowsBackground.instance.setAutoStart(value); }
                catch (e) {
                  if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(
                    SnackBar(content: Text('Windows startup error: $e')));
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
    if (Platform.isAndroid) ...[
      _section(c, 'Android Background Receiver',
        'A visible connected-device foreground notification keeps the LAN engine available after leaving the app.',
        const Column(children: [
          ListTile(
            leading: Icon(Icons.wifi_rounded),
            title: Text('Background LAN receiving'),
            subtitle: Text('Active while the File Share foreground service is running'),
          ),
          ListTile(
            leading: Icon(Icons.notifications_active_outlined),
            title: Text('File received notifications'),
            subtitle: Text('Allow notifications in Android app settings'),
          ),
          Text('Force Stop, OEM battery optimization, Wi-Fi disconnect and reboot can still interrupt receiving.'),
        ]),
      ),
      const SizedBox(height: 14),
    ],
    _section(c, 'Appearance', 'Light, dark and follow-system for Android and Windows.',
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

  Widget _profile(BuildContext c) => _section(c, 'My profile',
    'Use local Wi-Fi sharing as a guest, or login to connect your personal cloud.',
    Column(children: [
      Center(child: CircleAvatar(
        radius: 37, backgroundColor: FileTheme.violet.withValues(alpha: .15),
        child: const Icon(Icons.person_outline, size: 35,
          color: FileTheme.violet))),
      const SizedBox(height: 12),
      const DesignTag('GUEST / OFFLINE'),
      const SizedBox(height: 10),
      _line(c, Icons.email_outlined, 'Account', 'Not signed in'),
      _line(c, Icons.cloud_off_outlined, 'Personal Cloudflare', 'Not connected'),
      const SizedBox(height: 14),
      SizedBox(width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => Navigator.push(c, fadePage(
            LoginPage(mode: mode, onMode: onMode))),
          icon: const Icon(Icons.login_rounded),
          label: const Text('View login UI'),
        )),
    ]),
  );
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
              const Text('1. Create D1 and R2 in your own Cloudflare account.\n'
                '2. Apply cloudflare/schema.sql to D1.\n'
                '3. Deploy worker.js with the guest page assets.\n'
                '4. Set a strong OWNER_TOKEN as a Worker secret.\n'
                '5. Connect above, then open My QR and Generate.'),
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

  Future<void> _revoke() async {
    final yes=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
      title:const Text('Revoke permanent QR?'),
      content:const Text('Guests will no longer be able to use the old QR URL.'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancel')),
        FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Revoke')),
      ],
    ));
    if(yes==true) await _run(() => PersonalCloud.instance.revokeQr());
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
                  ? 'Your QR remains until you revoke or regenerate it.'
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
                      onPressed:_busy?null:()=>_run(()=>cloud.regenerateQr()),
                      icon:const Icon(Icons.refresh_rounded),
                      label:const Text('Regenerate')),
                    OutlinedButton.icon(
                      onPressed:_busy?null:_revoke,
                      icon:const Icon(Icons.delete_outline_rounded),
                      label:const Text('Revoke')),
                  ]),
              ],
              if(_busy)const Padding(padding:EdgeInsets.all(14),
                child:CircularProgressIndicator()),
              if(_error!=null)Padding(padding:const EdgeInsets.all(12),
                child:Text(_error!,style:const TextStyle(
                  color:Colors.deepOrange,fontSize:12))),
            ])),
            const SizedBox(height:14),
            DesignPanel(child:Text(
              'Guest limit: 200 MB total and 4 upload sessions per rolling 24 hours. '
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


/// Real nearby devices: the list is driven by the live UDP discovery engine,
/// not the earlier placeholder names.
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
              if(peers.isEmpty)
                Padding(padding:const EdgeInsets.all(22),
                  child:Text('Keep File Share open on another phone or Windows PC connected to the same Wi-Fi. Discovery does not need internet.',
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
              onTap:()=>Navigator.push(context,MaterialPageRoute<void>(
                builder:(_)=>FullScreenFilePreview(
                  file:item,onSave:_save,onDelete:_delete,onShare:_share))),
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
                  onTap:()=>Navigator.push(context,MaterialPageRoute<void>(
                    builder:(_)=>FullScreenFilePreview(file:item,
                      onSave:_save,onDelete:_delete,onShare:_share)))),
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
