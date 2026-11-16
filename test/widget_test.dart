import 'package:file_share/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    ));
    expect(find.text('File Transfer'), findsOneWidget);
    expect(find.text('4 Photos (Group)'), findsOneWidget);
    expect(find.text('SAMPLE DATA'), findsOneWidget);
    expect(find.text('No real transfer, devices or login.'), findsOneWidget);
    expect(find.byTooltip('Refresh is disabled during UI preview'),
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

  testWidgets('QR page clearly marks dummy QR as not scannable',
      (tester) async {
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.light, offlineDefault: true,
    ));
    await tester.tap(find.byTooltip('QR design preview'));
    await tester.pumpAndSettle();
    expect(find.text('Your permanent guest QR'), findsOneWidget);
    expect(find.text('DEMO · NOT SCANNABLE'), findsOneWidget);
    expect(find.text('QR LOCKED UNTIL LOGIN'), findsOneWidget);
  });

  testWidgets('Narrow mobile dashboard renders first group card',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.light, offlineDefault: true,
    ));
    await tester.pumpAndSettle();
    expect(find.text('4 Photos (Group)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
