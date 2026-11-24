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

  test('Windows updater launches native elevated setup before closing tray',
      () async {
    final src=await File('lib/file_share_updates.dart').readAsString();
    final start=src.indexOf('Future<void> _installWindows(');
    final end=src.indexOf('Future<void> revealWindowsInstaller()',start);
    expect(start,greaterThan(0));
    expect(end,greaterThan(start));
    final windows=src.substring(start,end);
    final launch=windows.indexOf('await Isolate.run(');
    final reject=windows.indexOf('if(code<=32)');
    final shutdown=windows.indexOf(
      'await WindowsBackground.instance.exitCompletely();');
    expect(launch,greaterThan(0));
    expect(reject,greaterThan(launch));
    expect(shutdown,greaterThan(reject));
    expect(windows, isNot(contains('powershell.exe')));
    expect(src,contains("'ShellExecuteW'"));
    expect(src,contains("wide('runas')"));
    expect(src,contains('stage=Platform.isWindows&&verified?UpdateStage.ready'));
    expect(src,contains('Show downloaded installer'));
    expect(src,contains('await sha256.bind(file.openRead()).first'));
  });
}
