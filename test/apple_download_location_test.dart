import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:file_share/transfer_downloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance=InMemorySharedPreferencesAsync.empty();
  });
  const channel=MethodChannel('file_share.downloads');
  final messenger=TestDefaultBinaryMessengerBinding.instance
      .defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel,null));

  test('iOS/macOS directory setting uses persistent native folder channel',
      () async {
    final calls=<String>[];
    messenger.setMockMethodCallHandler(channel,(call) async {
      calls.add(call.method);
      if(call.method=='getDirectory')return 'Files/Selected';
      if(call.method=='chooseDirectory')return 'Files/Changed';
      return null;
    });
    expect(await TransferDownloads.instance.appleDownloadFolder(),
      'Files/Selected');
    expect(await TransferDownloads.instance.chooseAppleDownloadFolder(),
      'Files/Changed');
    expect(calls,['getDirectory','chooseDirectory']);
  });

  test('cancelled native picker preserves existing folder selection',
      () async {
    messenger.setMockMethodCallHandler(channel,(call) async {
      if(call.method=='getDirectory')return 'Files/Selected';
      if(call.method=='chooseDirectory')return null;
      return null;
    });
    expect(await TransferDownloads.instance.chooseAppleDownloadFolder(),isNull);
    expect(await TransferDownloads.instance.appleDownloadFolder(),
      'Files/Selected');
  });

  test('Windows updater requests native elevation before closing tray',
      () async {
    final src=await File('lib/file_share_updates.dart').readAsString();
    final windowsStart=src.indexOf('Future<void> _installWindows(');
    expect(windowsStart,greaterThan(0));
    final windows=src.substring(windowsStart);
    final launch=windows.indexOf('await _requestWindowsSetup(installerPath);');
    final shutdown=windows.indexOf(
      'await WindowsBackground.instance.exitCompletely();');
    expect(launch,greaterThan(0));
    expect(shutdown,greaterThan(launch));
    expect(windows,contains('ShellExecuteExW'));
    expect(windows,contains("wide('runas')"));
    expect(windows,contains("wide('/NORESTART /CLOSEAPPLICATIONS /LOG')"));
    expect(windows,contains('..nShow=1'));
    expect(windows,contains('if(started==0)'));
    expect(windows,contains('if(error==1223)'));
    expect(windows,contains('Isolate.run'));
    expect(windows, isNot(contains('powershell.exe')));
    expect(windows, isNot(contains('installer-started')));
  });

  test('Windows updater locks install, verifies SHA and allows retry', () async {
    final src=await File('lib/file_share_updates.dart').readAsString();
    final install=src.substring(src.indexOf('Future<void> install()'),
      src.indexOf('Future<void> _installMacOS('));
    final lock=install.indexOf('stage=UpdateStage.installing');
    final hash=install.indexOf('sha256.bind(file.openRead())');
    final launch=install.indexOf('await _installWindows(file)');
    expect(lock,greaterThan(0));
    expect(hash,greaterThan(lock));
    expect(launch,greaterThan(hash));
    expect(install,contains('await file.length()!=selected.size'));
    expect(install,contains('stage=Platform.isWindows?UpdateStage.ready:UpdateStage.failed'));
    expect(src,contains('_downloading||stage==UpdateStage.installing'));
    final installer=await File('tool/FileShareInstaller.iss').readAsString();
    expect(installer,contains('UsePreviousAppDir=yes'));
    expect(installer,contains('PrivilegesRequired=admin'));
    expect(installer,contains('Flags: nowait postinstall skipifsilent'));
  });
}
