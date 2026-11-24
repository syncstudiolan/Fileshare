import 'dart:io';

import 'package:file_share/lan_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now=DateTime.utc(2026,11,24);
  LanPeer peer(String id,String ip,[DateTime? seen]) =>
      LanPeer(id,id,ip,49311,seen??now);

  test('Windows combines Android UDP, Apple Bonjour and other Windows peers', (){
    final sources=WindowsLanPeerSources();
    sources.observeUdp(peer('android','192.168.1.2'));
    sources.observeUdp(peer('windows','192.168.1.3'));
    sources.replaceBonjour([
      peer('mac','192.168.1.4'),peer('iphone','192.168.1.5'),
      peer('android','192.168.1.2'),
    ]);
    expect(sources.snapshot(now).keys.toSet(),
        {'android','windows','mac','iphone'});
  });

  test('Bonjour loss never deletes a device still advertising over UDP', (){
    final sources=WindowsLanPeerSources();
    sources.observeUdp(peer('android','192.168.1.2'));
    sources.replaceBonjour([peer('android','192.168.1.2')]);
    sources.replaceBonjour([]);
    expect(sources.snapshot(now).keys,['android']);
    expect(sources.hasBonjourPeers,isFalse);
  });

  test('UDP expiry keeps a live Bonjour route; both lost removes device', (){
    final sources=WindowsLanPeerSources();
    sources.observeUdp(peer('mac','192.168.1.4'));
    sources.replaceBonjour([peer('mac','192.168.1.7')]);
    expect(sources.snapshot(now)['mac']!.address,'192.168.1.4');
    final later=now.add(const Duration(seconds:23));
    expect(sources.snapshot(later)['mac']!.address,'192.168.1.7');
    sources.replaceBonjour([]);
    expect(sources.snapshot(later),isEmpty);
  });

  test('UDP-only devices expire, fresh announcements reconnect, stop clears', (){
    final sources=WindowsLanPeerSources();
    sources.observeUdp(peer('windows','192.168.1.3'));
    final later=now.add(const Duration(seconds:23));
    expect(sources.snapshot(later),isEmpty);
    sources.observeUdp(peer('windows','192.168.1.8',later));
    expect(sources.snapshot(later)['windows']!.address,'192.168.1.8');
    sources.clear();
    expect(sources.snapshot(later),isEmpty);
  });

  test('Windows retries both transports without changing native Apple channel', (){
    final source=File('lib/lan_engine.dart').readAsStringSync();
    expect(source,contains('Future.wait([_ensureWindowsRegistration(),_ensureWindowsBrowser()])'));
    expect(source,contains('nsd.IpLookupType.v4'));
    expect(source,contains('discovery.addListener(update);'));
    expect(source,contains('update(); // Include results'));
    expect(source,contains('_windowsSources.hasBonjourPeers'));
    expect(source,contains('unawaited(_ensureWindowsUdp());'));
    expect(source,contains('unawaited(_startWindowsBonjour());'));
    expect(source,contains('_sendAnnouncement(destination:packet.address)'));
    expect(source,contains("MethodChannel('file_share.lan_discovery')"));
    expect(source,contains('(Platform.isIOS || Platform.isMacOS)'));
  });
}
