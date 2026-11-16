import 'package:file_share/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Welcome offers login or skip-to-LAN', (tester) async {
    await tester.pumpWidget(
      const FileShareApp(initialMode: ThemeMode.light),
    );
    expect(find.text('Login / Create Account'), findsOneWidget);
    expect(find.text('Skip to Offline LAN'), findsOneWidget);
  });

  testWidgets('Header appearance menu includes both modes',
      (tester) async {
    await tester.pumpWidget(
      const FileShareApp(initialMode: ThemeMode.light),
    );
    await tester.tap(find.byTooltip('Choose light or dark appearance'));
    await tester.pumpAndSettle();
    expect(find.text('Light mode'), findsOneWidget);
    expect(find.text('Dark mode'), findsOneWidget);
    expect(find.text('Follow system'), findsOneWidget);
  });

  testWidgets('Offline dashboard remains a single timeline',
      (tester) async {
    await tester.pumpWidget(
      const FileShareApp(
        initialMode: ThemeMode.dark,
        offlineDefault: true,
      ),
    );
    expect(find.text('File Transfer'), findsOneWidget);
    expect(find.text('Your files will appear here'), findsOneWidget);
    expect(find.byTooltip('Choose files'), findsOneWidget);
  });
}
