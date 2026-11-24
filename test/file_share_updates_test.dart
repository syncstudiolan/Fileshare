import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/file_share_updates.dart';

void main(){
  const hash='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const base='https://github.com/syncstudiolan/Fileshare/releases/download/';
  Map<String,Object> candidate({String? url,int build=100,int size=1024,
      String sha256=hash})=> <String,Object>{
    'version':'0.2.0','build':build,'size':size,
    'url':url??'${base}fileshare-android-v0.2.0-build-100/FileShare-Android-ARM64-Release.apk',
    'sha256':sha256,'notes':'Test changelog',
  };

  test('accepts release manifest from the trusted GitHub repo',(){
    final a=UpdateRelease.fromJson(candidate(),'android');
    expect(a,isNotNull);
    expect(a!.build,100);
    expect(a.size,1024);
    expect(a.version,'0.2.0');
  });
  test('rejects external download hosts and wrong package type',(){
    expect(UpdateRelease.fromJson(candidate(
      url:'https://example.com/release.apk'),'android'),isNull);
    expect(UpdateRelease.fromJson(candidate(
      url:'${base}tag/fake.exe'),'android'),isNull);
  });
  test('rejects missing hash, size or invalid build',(){
    expect(UpdateRelease.fromJson(candidate(sha256:'oops'),'android'),isNull);
    expect(UpdateRelease.fromJson(candidate(size:0),'android'),isNull);
    expect(UpdateRelease.fromJson(candidate(build:0),'android'),isNull);
  });
  test('iOS channel accepts only trusted unsigned IPA release URLs',(){
    final ipa=candidate(url:'${base}fileshare-ios-unsigned-build-45/FileShare-iOS-UNSIGNED.ipa');
    expect(UpdateRelease.fromJson(ipa,'ios'),isNotNull);
    expect(UpdateRelease.fromJson(ipa,'android'),isNull);
    expect(UpdateRelease.fromJson(ipa,'windows'),isNull);
    expect(UpdateRelease.fromJson(candidate(url:'https://other.example/evil.ipa'),'ios'),isNull);
  });

  test('accepts windows installer only on the windows channel',(){
    final w=candidate(url:'${base}tag/FileShare-Windows-Setup.exe');
    expect(UpdateRelease.fromJson(w,'windows'),isNotNull);
    expect(UpdateRelease.fromJson(w,'android'),isNull);
  });
  test('iOS downloads and verifies IPA before opening a signing share sheet',(){
    final source=File('lib/file_share_updates.dart').readAsStringSync();
    expect(source,contains("Platform.isIOS?'ipa'"));
    expect(source,contains('SharePlus.instance.share(ShareParams(files:[XFile(file.path)]'));
    expect(source.indexOf('sha256.bind(file.openRead())'),
        lessThan(source.indexOf('SharePlus.instance.share(ShareParams(files:[XFile(file.path)]')));
    expect(source,contains('Share IPA to signing app'));
  });

  test('one release workflow selects platforms and fails fast before group publication',(){
    final pipeline=File('.github/workflows/offline-validation.yml').readAsStringSync();
    for(final platform in ['android','windows','ios','macos']){
      expect(pipeline,contains('inputs.$platform'));
    }
    expect(pipeline,contains('[release-now]'));
    expect(pipeline,contains('  macos:'));
    expect(pipeline,contains("'runner':'macos-15-intel'"));
    expect(pipeline,contains('fail-fast: true'));
    expect(pipeline,contains('Restore clean source for macOS after iOS packaging'));
    expect(pipeline,contains("needs: [release_preflight, build]"));
    expect(pipeline,contains("needs.build.result == 'success'"));
    expect(pipeline,contains('tool/publish_update_manifest.py --set'));
    expect(pipeline, isNot(contains('publish_windows_release:')));
    expect(pipeline, isNot(contains('publish_ipa:')));
    expect(pipeline,contains('hdiutil verify'));
    expect(pipeline,contains(r'--build-number="${{ github.run_number }}"'));
    final mac=File('.github/workflows/macos-apple-silicon-dmg.yml').readAsStringSync();
    expect(mac,contains('workflow_call:'));
    expect(mac,contains('hdiutil verify'));
  });

}
