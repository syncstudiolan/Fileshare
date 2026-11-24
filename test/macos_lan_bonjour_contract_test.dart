import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS and mobile advertise the same Bonjour LAN TCP service', () {
    final dart = File('lib/lan_engine.dart').readAsStringSync();
    final native = File('tool/macos/FileShareMacLANBonjour.swift')
        .readAsStringSync();

    // The Mac no longer depends exclusively on UDP broadcast.
    expect(dart, contains(
        '(Platform.isIOS || Platform.isAndroid || Platform.isMacOS)'));
    expect(dart, contains('await _startBonjour();'));
    expect(dart, contains("MethodChannel('file_share.lan_discovery')"));

    // This exact DNS-SD name and TXT schema must match Android/iOS.
    expect(native, contains('"_fileshare._tcp."'));
    expect(native, contains('"id": Data(id.utf8)'));
    expect(native, contains('"n": Data(name.utf8)'));
    expect(native, contains('channel?.invokeMethod("peer"'));
    expect(native, contains('"address": ip'));
    expect(native, contains('"port": sender.port'));
  });

  test('generated macOS Runner registers Bonjour and has LAN permissions', () {
    final builder = File('tool/prepare_macos_tray_runner.py')
        .readAsStringSync();
    expect(builder, contains('FileShareMacLANBonjour.register'));
    expect(builder, contains(
        'tool/macos/FileShareMacLANBonjour.swift'));
    expect(builder, contains('final class FileShareMacLANBonjour'));
    expect(builder, contains('NSLocalNetworkUsageDescription'));
    expect(builder, contains('NSBonjourServices'));
    expect(builder, contains('com.apple.security.network.client'));
    expect(builder, contains('com.apple.security.network.server'));
  });

  test('manual refresh does not restart Bonjour every UDP heartbeat', () {
    final engine = File('lib/lan_engine.dart').readAsStringSync();
    expect(engine, contains('refresh(refreshBonjour: false)'));
    expect(engine, contains(
        'void refresh({bool refreshBonjour = true})'));
    expect(engine, contains(
        'Platform.isIOS||Platform.isAndroid||Platform.isMacOS'));
    // TCP listener retry has to restore advertisement after a blocked port.
    expect(engine, contains('if (_server == null || _disposed) return;'));
    expect(engine, contains('!_bonjourStarted'));
  });
}
