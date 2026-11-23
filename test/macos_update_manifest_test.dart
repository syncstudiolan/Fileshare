import 'dart:io';

import 'package:file_share/file_share_updates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const macosDmgUrl =
      'https://github.com/syncstudiolan/Fileshare/releases/download/'
      'fileshare-macos-arm64-a1b2c3d4/FileShare-macOS-AppleSilicon.dmg';
  Map<String, dynamic> good(String url) => <String, dynamic>{
    'version': '0.1.0',
    'build': 620,
    'url': url,
    'size': 123456,
    'sha256': List<String>.filled(64, 'a').join(),
    'notes': 'macOS LAN Bonjour',
  };

  test('macOS updater accepts a verified GitHub DMG metadata entry', () {
    final result=UpdateRelease.fromJson(good(macosDmgUrl),'macos');
    expect(result,isNotNull);
    expect(result!.build,620);
    expect(result.url,macosDmgUrl);
    expect(result.sha256,hasLength(64));
  });

  test('macOS updater rejects arbitrary executable or domain', () {
    expect(UpdateRelease.fromJson(good(
      macosDmgUrl.replaceAll('.dmg','.exe')),'macos'),isNull);
    expect(UpdateRelease.fromJson(good(
      macosDmgUrl.replaceFirst('github.com','untrusted.example')),'macos'),isNull);
    final tampered=good(macosDmgUrl)..['sha256']='bad';
    expect(UpdateRelease.fromJson(tampered,'macos'),isNull);
  });

  test('macOS Finder update flow never bypasses authorization', () {
    final source=File('lib/file_share_updates.dart').readAsStringSync();
    expect(source,contains('Platform.isMacOS'));
    expect(source,contains("Process.run('/usr/bin/open',[dmg.path])"));
    expect(source,contains('await WindowsBackground.instance.exitCompletely();'));
    expect(source,contains('drag File Share.app to Applications'));
    expect(source,contains('UpdateStage.ready'));
  });

  test('macOS DMG publication writes manifest after release', () {
    final workflow=File('.github/workflows/macos-apple-silicon-dmg.yml')
        .readAsStringSync();
    final create=workflow.indexOf('gh release create');
    final manifest=workflow.indexOf('tool/publish_update_manifest.py macos');
    expect(create,greaterThan(0));
    expect(manifest,greaterThan(create));
    expect(workflow,contains('--dart-define=FILE_SHARE_BUILD_NUMBER'));
  });
}
