import 'dart:io';
import 'windows_tls_trust.dart';

/// Shared HTTPS transport. Peer and hostname verification are never disabled.
/// Windows gets one retry using public root CAs already trusted by Windows.
class SecureHttp {
  SecureHttp._();
  static Future<T> run<T>(Future<T> Function(HttpClient) action,
      {Duration connectionTimeout=const Duration(seconds:15)}) {
    return WindowsTlsTrust.retryWithSystemRoots((context) async {
      final client=HttpClient(context:context)..connectionTimeout=connectionTimeout;
      try { return await action(client); }
      finally { client.close(force:true); }
    });
  }
}
