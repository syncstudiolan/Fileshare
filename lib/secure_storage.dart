import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Shared secure storage for account credentials and sessions.
/// macOS distribution is ad-hoc and has no provisioning profile, so it must
/// use the legacy login Keychain rather than the Data Protection Keychain.
/// Other platforms keep flutter_secure_storage's normal defaults.
class FileShareSecureStorage {
  FileShareSecureStorage._();

  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage();
  static const FlutterSecureStorage _macOSStorage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  static FlutterSecureStorage get instance =>
      Platform.isMacOS ? _macOSStorage : _defaultStorage;
}
