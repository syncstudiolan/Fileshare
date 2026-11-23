import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/transfer_downloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('Windows updater starts elevated wizard before closing tray',
      () async {
    // Static regression for the handoff ordering even in Linux Flutter CI.
    final src=await File('lib/file_share_updates.dart').readAsString();
    final launch=src.indexOf(r'Start-Process -FilePath \\$installer -Verb RunAs');
    final acknowledge=src.indexOf(
      r"Set-Content -LiteralPath \\$ready -Value 'installer-started'");
    final shutdown=src.indexOf(
      'await WindowsBackground.instance.exitCompletely();');
    expect(launch,greaterThan(0));
    expect(acknowledge,greaterThan(launch),
      reason:'The old updater closed File Share before Inno Setup launched.');
    expect(shutdown,greaterThan(acknowledge));
    expect(src.contains(r'Set-Content -LiteralPath \\$failed'),isTrue);
  });
}
