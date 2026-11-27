import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Windows fallback for Dart TLS's lazily populated root CA store.
///
/// Only invoked after a *real* certificate handshake failure. Import public
/// CA certificates that Windows itself already trusts; never turn off peer
/// verification, suppress hostname checks, or accept an arbitrary certificate.
/// On an untrusted machine, the retry must fail closed as before.
class WindowsTlsTrust {
  WindowsTlsTrust._();

  static Future<SecurityContext?>? _cachedContext;

  static Future<T> retryWithSystemRoots<T>(
      Future<T> Function(SecurityContext? context) request) async {
    try {
      return await request(null);
    } on TlsException {
      if (!Platform.isWindows) rethrow;
      final context = await (_cachedContext ??= _readWindowsRoots());
      if (context == null) { _cachedContext = null; rethrow; }
      // Deliberately only one retry; invalid chains must still fail.
      return await request(context);
    }
  }

  static Future<SecurityContext?> _readWindowsRoots() async {
    try {
      // Read ONLY Windows Trusted Root Certification Authorities (not
      // Intermediate/Personal/Untrusted stores). The script emits base64 DER
      // certificate bytes, never passwords, private keys or key material.
      const script = r'''
$ErrorActionPreference = 'Stop'
foreach ($location in @('CurrentUser', 'LocalMachine')) {
  try {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', $location)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
      foreach ($cert in $store.Certificates) {
        if ($null -ne $cert.RawData) { [Convert]::ToBase64String($cert.RawData) }
      }
    } finally { $store.Close() }
  } catch { [Console]::Error.WriteLine("Root store unavailable: $location") }
}
''';
      final result = await Process.run(
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        const ['-NoProfile', '-NonInteractive', '-Command', script],
        runInShell: false,
      ).timeout(const Duration(seconds: 12));
      if (result.exitCode != 0) return null;
      final raw = result.stdout;
      if (raw is! String || raw.length > 2000000) return null;
      final entries = raw.split(RegExp(r'\r?\n'))
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty &&
              RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(entry))
          .toSet();
      if (entries.isEmpty) return null;
      final context = SecurityContext(withTrustedRoots: true);
      var imported = 0;
      for (final entry in entries) {
        // Public certificate DER from the OS trust store only.
        try {
          final bytes = base64.decode(entry);
          if (bytes.length < 100 || bytes.length > 25000) continue;
          final pem = StringBuffer();
          pem.writeln('-----BEGIN CERTIFICATE-----');
          for (var i = 0; i < entry.length; i += 64) {
            final end = (i + 64 < entry.length) ? i + 64 : entry.length;
            pem.writeln(entry.substring(i, end));
          }
          pem.writeln('-----END CERTIFICATE-----');
          context.setTrustedCertificatesBytes(utf8.encode(pem.toString()));
          imported++;
        } catch (_) {
          continue;
        }
      }
      if (imported == 0) return null;
      return context;
    } catch (_) {
      // Do not relax TLS if Windows root enumeration is disabled by policy.
      return null;
    }
  }
}
