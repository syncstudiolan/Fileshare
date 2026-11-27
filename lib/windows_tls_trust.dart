import 'dart:convert';
import 'dart:io';

/// Windows fallback for Dart TLS's lazily populated root CA store.
/// Only public CAs already trusted by Windows are imported. Peer and hostname
/// verification are never disabled and failed validation remains fail-closed.
class WindowsTlsTrust {
  WindowsTlsTrust._();

  static Future<SecurityContext?>? _cachedContext;

  /// Kept separate so both dart:io TLS exception families are testable.
  static bool isTlsFailure(Object error) =>
      error is HandshakeException || error is TlsException;

  static Future<T> retryWithSystemRoots<T>(
    Future<T> Function(SecurityContext? context) request,
  ) async {
    try {
      return await request(null);
    } on IOException catch (error, stackTrace) {
      // HandshakeException and TlsException must both be considered.
      // Other IOExceptions (DNS, refused sockets, timeouts) are not retried.
      if (!Platform.isWindows || !isTlsFailure(error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      final context = await (_cachedContext ??= _readWindowsRoots());
      if (context == null) {
        _cachedContext = null;
        Error.throwWithStackTrace(error, stackTrace);
      }
      // Exactly one retry; certificate and hostname checks remain enabled.
      return await request(context);
    }
  }

  static Future<SecurityContext?> _readWindowsRoots() async {
    try {
      const script = r'''
$ErrorActionPreference = 'Stop'
$loaded = 0
foreach ($location in @('CurrentUser', 'LocalMachine')) {
  $store = $null
  try {
    $storeLocation = [System.Security.Cryptography.X509Certificates.StoreLocation]$location
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
      [System.Security.Cryptography.X509Certificates.StoreName]::Root,
      $storeLocation
    )
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    foreach ($cert in $store.Certificates) {
      if ($null -ne $cert.RawData) {
        [Console]::Out.WriteLine([Convert]::ToBase64String($cert.RawData))
        $loaded++
      }
    }
  } catch {
    [Console]::Error.WriteLine("Root store unavailable: $location - $($_.Exception.Message)")
  } finally {
    if ($null -ne $store) { $store.Close() }
  }
}
if ($loaded -eq 0) { exit 3 }
''';
      final windowsRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final powershell =
          '$windowsRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      final result = await Process.run(
        powershell,
        const ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
        runInShell: false,
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) return null;

      final raw = result.stdout;
      if (raw is! String || raw.length > 4000000) return null;
      final entries = raw
          .split(RegExp(r'\r?\n'))
          .map((entry) => entry.trim())
          .where((entry) =>
              entry.isNotEmpty && RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(entry))
          .toSet();
      if (entries.isEmpty) return null;

      final context = SecurityContext(withTrustedRoots: true);
      var imported = 0;
      for (final entry in entries) {
        try {
          final bytes = base64.decode(entry);
          if (bytes.length < 100 || bytes.length > 25000) continue;
          final pem = StringBuffer()..writeln('-----BEGIN CERTIFICATE-----');
          for (var i = 0; i < entry.length; i += 64) {
            final end = (i + 64 < entry.length) ? i + 64 : entry.length;
            pem.writeln(entry.substring(i, end));
          }
          pem.writeln('-----END CERTIFICATE-----');
          context.setTrustedCertificatesBytes(utf8.encode(pem.toString()));
          imported++;
        } on TlsException {
          continue;
        } on FormatException {
          continue;
        }
      }
      if (imported == 0) return null;
      return context;
    } catch (_) {
      return null;
    }
  }
}
