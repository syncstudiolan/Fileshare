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
  test('accepts windows installer only on the windows channel',(){
    final w=candidate(url:'${base}tag/FileShare-Windows-Setup.exe');
    expect(UpdateRelease.fromJson(w,'windows'),isNotNull);
    expect(UpdateRelease.fromJson(w,'android'),isNull);
  });
}
