import 'package:file_share/main.dart';
import 'package:file_share/lan_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LAN file names cannot contain path separators', () {
    expect(LanEngine.safeFileName('../unsafe\\name.png'),
        '.._unsafe_name.png');
  });

  test('LAN transfer records round-trip without losing progress', () {
    final entry = LanFile(
      id: 'id', batch: 'batch', name: 'test.jpg', path: '/temp/test.jpg',
      peer: 'Laptop', incoming: true, size: 1024, done: 512,
      created: DateTime.utc(2026, 11, 16), state: TransferState.receiving);
    final decoded = LanFile.fromJson(entry.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.progress, 0.5);
    expect(decoded.incoming, isTrue);
    expect(decoded.batch, 'batch');
  });

  testWidgets('First use offers login and no-login offline LAN', (tester) async {
    await tester.pumpWidget(const FileShareApp(initialMode: ThemeMode.light));
    expect(find.text('Login / Create Account'), findsOneWidget);
    expect(find.text('Skip to Offline LAN'), findsOneWidget);
  });

  testWidgets('Theme menu supports light, dark and system', (tester) async {
    await tester.pumpWidget(const FileShareApp(initialMode: ThemeMode.light));
    await tester.tap(find.byTooltip('Choose light or dark appearance'));
    await tester.pumpAndSettle();
    expect(find.text('Light mode'), findsOneWidget);
    expect(find.text('Dark mode'), findsOneWidget);
    expect(find.text('Follow system'), findsOneWidget);
  });

  testWidgets('Unified timeline shows LAN and Guest QR sample cards',
      (tester) async {
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.dark,
      offlineDefault: true,
      enableBackends: false,
    ));
    expect(find.text('File Transfer'), findsOneWidget);
    expect(find.text('4 Photos (Group)'), findsOneWidget);
    expect(find.text('SAMPLE DATA'), findsOneWidget);
    expect(find.text('Example cards only — no real files'), findsOneWidget);
    expect(find.byTooltip('Refresh nearby LAN devices'),
        findsOneWidget);
  });

  testWidgets('Sent cards have no download action', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DesignFileCard(
          transfer: MockTransfer('sample.png', 'To Windows PC · Offline LAN',
              '1 MB', '12:00 PM', sent: true),
        ),
      ),
    ));
    expect(find.byTooltip('Download · not enabled'), findsNothing);
    expect(find.byTooltip('Delete · not enabled'), findsOneWidget);
    expect(find.byTooltip('Share externally · not enabled'), findsOneWidget);
  });

  testWidgets('Received cards have download but still no live actions',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DesignFileCard(
          transfer: MockTransfer('sample.png', 'From Android B · Offline LAN',
              '1 MB', '12:00 PM'),
        ),
      ),
    ));
    expect(find.byTooltip('Download · not enabled'), findsOneWidget);
    expect(find.byTooltip('Delete · not enabled'), findsOneWidget);
  });

  testWidgets('QR screen requires connection and never invents a real QR',
      (tester) async {
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.light,
      offlineDefault: true,
      enableBackends: false,
    ));
    await tester.tap(find.byTooltip('QR design preview'));
    await tester.pumpAndSettle();
    expect(find.text('My Permanent QR'), findsOneWidget);
    expect(find.text('No active QR yet'), findsOneWidget);
    expect(find.text('Connect Personal Cloud'), findsOneWidget);
  });

  testWidgets('Narrow mobile dashboard renders first group card',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.light, offlineDefault: true,
      enableBackends: false,
    ));
    await tester.pumpAndSettle();
    expect(find.text('4 Photos (Group)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

