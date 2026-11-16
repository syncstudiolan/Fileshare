import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Phase 1: native-feeling UI shell only. Authentication and transfer engines are
// intentionally NOT simulated. No network polling or cloud API calls occur.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = SharedPreferencesAsync();
  final mode = await prefs.getString('appearance');
  final offline = await prefs.getBool('offline_start') ?? false;
  runApp(FileShareApp(
    initialMode: switch (mode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    },
    offlineDefault: offline,
  ));
}

class FileShareApp extends StatefulWidget {
  const FileShareApp({
    super.key,
    this.initialMode = ThemeMode.system,
    this.offlineDefault = false,
  });
  final ThemeMode initialMode;
  final bool offlineDefault;

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
            ? DashboardPage(mode: _mode, onMode: _setMode)
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
              mode == ThemeMode.dark ||
                      (mode == ThemeMode.system && FileTheme.dark(context))
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
  final _key = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _hidden = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Container(
          decoration: BoxDecoration(gradient: FileTheme.background(context)),
          child: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: Text('Account',
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                  AppearanceButton(mode: widget.mode, onChange: widget.onMode),
                ]),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(24),
                      children: [
                        const Center(child: AppLogo(size: 68)),
                        const SizedBox(height: 22),
                        Text(
                          _register ? 'Create your account' : 'Welcome back',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: FileTheme.foreground(context),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Login to connect your personal Cloudflare and QR.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: FileTheme.muted(context)),
                        ),
                        const SizedBox(height: 28),
                        Form(
                          key: _key,
                          child: Column(children: [
                            TextFormField(
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              decoration: const InputDecoration(
                                labelText: 'Email address',
                                prefixIcon: Icon(Icons.mail_outline_rounded),
                              ),
                              validator: (value) =>
                                  (value == null ||
                                          !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                                              .hasMatch(value.trim()))
                                      ? 'Enter a valid email'
                                      : null,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _password,
                              obscureText: _hidden,
                              autofillHints: [
                                _register
                                    ? AutofillHints.newPassword
                                    : AutofillHints.password
                              ],
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon:
                                    const Icon(Icons.lock_outline_rounded),
                                suffixIcon: IconButton(
                                  tooltip:
                                      _hidden ? 'Show password' : 'Hide password',
                                  onPressed: () =>
                                      setState(() => _hidden = !_hidden),
                                  icon: Icon(_hidden
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined),
                                ),
                              ),
                              validator: (value) =>
                                  (value == null || value.length < 8)
                                      ? 'Use at least 8 characters'
                                      : null,
                            ),
                            const SizedBox(height: 18),
                            SizedBox(
                              height: 54,
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: () {
                                  if (!_key.currentState!.validate()) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Authentication backend is not connected. No credentials were sent.',
                                      ),
                                    ),
                                  );
                                },
                                child: Text(_register
                                    ? 'Create account'
                                    : 'Login'),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _register = !_register),
                              child: Text(_register
                                  ? 'Already have an account? Login'
                                  : 'New here? Create account'),
                            ),
                            const SizedBox(height: 18),
                            Text('Phase 1 UI only · Authentication is not active',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: FileTheme.muted(context),
                                )),
                          ]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.mode,
    required this.onMode,
  });
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final List<PlatformFile> _staged = [];
  bool _picking = false;

  Future<void> _choose() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      // Native OS picker; avoid reading large files into RAM.
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: false,
      );
      if (picked != null && mounted) {
        setState(() => _staged.addAll(picked.files));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the file manager.')),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _menu() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: ListTile(
            leading: const Icon(Icons.login_rounded),
            title: const Text('Login / Connect personal cloud'),
            subtitle: const Text('LAN stays available without login'),
            onTap: () {
              Navigator.pop(sheet);
              Navigator.push(
                context,
                fadePage(LoginPage(mode: widget.mode, onMode: widget.onMode)),
              );
            },
          ),
        ),
      );

  static String _size(int bytes) {
    var number = bytes.toDouble();
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var index = 0;
    while (number >= 1024 && index < units.length - 1) {
      number /= 1024;
      index++;
    }
    return number.toStringAsFixed(index == 0 ? 0 : 1) + ' ' + units[index];
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 720;
    return RootBackGuard(
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(gradient: FileTheme.background(context)),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1050),
                child: Column(children: [
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: wide ? 24 : 12,
                      vertical: 12,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: FileTheme.surface(context).withValues(alpha: .9),
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Row(children: [
                        IconButton(
                          tooltip: 'Menu',
                          icon: const Icon(Icons.menu_rounded),
                          onPressed: _menu,
                        ),
                        const AppLogo(size: 42),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('File Transfer',
                                  style: TextStyle(
                                    fontSize: wide ? 21 : 17,
                                    fontWeight: FontWeight.w800,
                                    color: FileTheme.foreground(context),
                                  )),
                              Text('Offline LAN · discovery not active yet',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: FileTheme.muted(context),
                                  )),
                            ],
                          ),
                        ),
                        AppearanceButton(
                          mode: widget.mode,
                          onChange: widget.onMode,
                        ),
                      ]),
                    ),
                  ),
                  Expanded(
                    child: _staged.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.forum_outlined,
                                    size: 64,
                                    color: FileTheme.violet
                                        .withValues(alpha: .65)),
                                const SizedBox(height: 15),
                                Text('Your files will appear here',
                                    style: TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.w700,
                                      color: FileTheme.foreground(context),
                                    )),
                                const SizedBox(height: 8),
                                Text('One timeline for LAN and Guest QR files.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: FileTheme.muted(context),
                                    )),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 14),
                            itemCount: _staged.length,
                            itemBuilder: (context, index) {
                              final file = _staged[index];
                              return Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  constraints:
                                      const BoxConstraints(maxWidth: 550),
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.all(13),
                                  decoration: BoxDecoration(
                                    color: FileTheme.surface(context),
                                    borderRadius: BorderRadius.circular(21),
                                  ),
                                  child: Row(children: [
                                    const Icon(Icons.insert_drive_file_outlined,
                                        color: FileTheme.pink),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(file.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w700)),
                                          Text(
                                            _size(file.size) +
                                                ' · Staged · Not sent',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: FileTheme.muted(context),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Remove from selection',
                                      onPressed: () =>
                                          setState(() => _staged.removeAt(index)),
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                                  ]),
                                ),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        wide ? 24 : 12, 8, wide ? 24 : 12, 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: FileTheme.surface(context),
                        borderRadius: BorderRadius.circular(27),
                      ),
                      child: Row(children: [
                        IconButton.filledTonal(
                          tooltip: 'Choose files',
                          onPressed: _picking ? null : _choose,
                          icon: const Icon(Icons.add_rounded),
                        ),
                        const SizedBox(width: 4),
                        const IconButton(
                          tooltip: 'Tools coming later',
                          onPressed: null,
                          icon: Icon(Icons.handyman_outlined),
                        ),
                        Expanded(
                          child: Text(
                            _staged.isEmpty
                                ? 'Choose files to send...'
                                : _staged.length.toString() +
                                    ' file(s) ready for transfer engine',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: FileTheme.muted(context),
                            ),
                          ),
                        ),
                        const IconButton.filled(
                          tooltip: 'Send (available after LAN engine)',
                          onPressed: null,
                          icon: Icon(Icons.send_rounded),
                        ),
                      ]),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'UI preview · no upload/download is running yet',
                      style: TextStyle(
                        fontSize: 10,
                        color: FileTheme.muted(context),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
