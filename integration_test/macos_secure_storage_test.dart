import 'dart:io';

import 'package:file_share/secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS login Keychain write/read/delete works without Keychain Sharing',
      (tester) async {
    if (!Platform.isMacOS) return;
    final storage = FileShareSecureStorage.instance;
    final key = 'fileshare-keychain-smoke-' + DateTime.now().microsecondsSinceEpoch.toString();
    const value = 'fileshare-macos-keychain-roundtrip';
    await storage.write(key: key, value: value);
    expect(await storage.read(key: key), value);
    await storage.delete(key: key);
    expect(await storage.read(key: key), isNull);
  });
}
