import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// An owner-facing client for a user's OWN workers.dev endpoint.
/// It does not receive a Cloudflare admin API token; that token is only for
/// initial provisioning. The OWNER_TOKEN secret belongs to the user's Worker.
class CloudFile {
  const CloudFile({required this.id, required this.name, required this.size,
    required this.session, required this.created});
  final String id, name, session;
  final int size;
  final DateTime created;
}

class PersonalCloud extends ChangeNotifier {
  PersonalCloud._();
  static final PersonalCloud instance = PersonalCloud._();
  static const _secrets = FlutterSecureStorage();

  Uri? _host;
  String? _ownerToken;
  String? _qrLink;
  final List<CloudFile> files = [];
  String? error;
  bool loading = false;
  bool get connected => _host != null && _ownerToken != null;
  String? get endpoint => _host?.origin;
  String? get qrLink => _qrLink;

  // Restore the locally encrypted connection without a network request.
  Future<void> restore() async {
    try {
      final host = await _secrets.read(key: 'personal_worker_url');
      final secret = await _secrets.read(key: 'personal_owner_token');
      if (host != null && secret != null) {
        _host = _validWorker(host);
        _ownerToken = secret;
        notifyListeners();
      }
    } catch (e) { error = 'Secure cloud storage unavailable: ' + e.toString(); }
  }

  static Uri _validWorker(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'https' ||
        !uri.host.endsWith('.workers.dev') ||
        uri.userInfo.isNotEmpty || uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException('Use your HTTPS *.workers.dev Worker URL');
    }
    return Uri(scheme: 'https', host: uri.host);
  }

  Future<Map<String, dynamic>> _request(
    Uri host, String token, String method, String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.openUrl(method, host.resolve(path));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ' + token);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 18));
      final body = await utf8.decoder.bind(response).join();
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Unexpected Worker response');
      }
      if (response.statusCode < 200 || response.statusCode > 299 ||
          data['ok'] != true) {
        throw StateError(data['error'] ?? 'Cloud request failed');
      }
      return data;
    } finally { client.close(force: true); }
  }

  Future<Map<String, dynamic>> _call(String method, String path) {
    if (!connected) throw StateError('Connect your personal cloud first');
    return _request(_host!, _ownerToken!, method, path);
  }

  /// This is an advanced/manual pairing method, not Cloudflare API-token
  /// auto-provisioning. No account/password verification is simulated.
  Future<void> connectWorker(String workersUrl, String ownerToken) async {
    final url = _validWorker(workersUrl);
    if (ownerToken.trim().length < 16) {
      throw const FormatException('Owner token is missing or too short');
    }
    await _request(url, ownerToken.trim(), 'GET', '/v1/owner/qr');
    await _secrets.write(key: 'personal_worker_url', value: url.origin);
    await _secrets.write(key: 'personal_owner_token', value: ownerToken.trim());
    _host = url;
    _ownerToken = ownerToken.trim();
    error = null;
    notifyListeners();
  }

  Future<void> disconnect() async {
    _host = null;
    _ownerToken = null;
    _qrLink = null;
    files.clear();
    await _secrets.delete(key: 'personal_worker_url');
    await _secrets.delete(key: 'personal_owner_token');
    notifyListeners();
  }

  Future<String?> loadQr() async {
    final result = await _call('GET', '/v1/owner/qr');
    final token = result['qr'] is Map ? result['qr']['token'] as String? : null;
    _qrLink = token == null ? null : _host!.resolve('/q/' + token).toString();
    notifyListeners();
    return _qrLink;
  }

  Future<String> createQr() async {
    final result = await _call('POST', '/v1/owner/qr');
    _qrLink = result['url'] as String;
    notifyListeners();
    return _qrLink!;
  }

  Future<String> regenerateQr() async {
    final result = await _call('POST', '/v1/owner/qr/regenerate');
    _qrLink = result['url'] as String;
    notifyListeners();
    return _qrLink!;
  }

  Future<void> revokeQr() async {
    await _call('DELETE', '/v1/owner/qr');
    _qrLink = null;
    notifyListeners();
  }

  /// No idle polling. Called explicitly by user refresh or a future push.
  Future<void> refreshFiles() async {
    if (!connected || loading) return;
    loading = true;
    notifyListeners();
    try {
      final fetched = <CloudFile>[];
      var offset = 0;
      while (offset < 10000) {
        final data = await _call('GET',
          '/v1/owner/files?offset=' + offset.toString());
        final rows = (data['files'] as List?) ?? [];
        for (final raw in rows) {
          if (raw is! Map) continue;
          fetched.add(CloudFile(
            id: raw['id'] as String,
            name: raw['name'] as String,
            size: (raw['size'] as num).toInt(),
            session: raw['session_id'] as String,
            created: DateTime.fromMillisecondsSinceEpoch(
              (raw['created_at'] as num).toInt()),
          ));
        }
        if (rows.length < 100) break;
        offset += rows.length;
      }
      files..clear()..addAll(fetched);
      error = null;
    } catch (e) { error = 'Cloud inbox refresh failed: ' + e.toString(); }
    finally { loading = false; notifyListeners(); }
  }

  static int nextMidnightIst() {
    const day = 86400000, offset = 19800000;
    final ms = DateTime.now().toUtc().millisecondsSinceEpoch;
    return ((ms + offset) ~/ day + 1) * day - offset;
  }

  Future<Directory> _cacheDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(support.path + Platform.pathSeparator + 'file_share_cloud');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> cleanupLocalCache() async {
    final dir = await _cacheDir();
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!name.startsWith('cloud_')) continue;
      final expiry = int.tryParse(name.split('_').elementAtOrNull(1) ?? '');
      if (expiry != null && expiry <= DateTime.now().millisecondsSinceEpoch) {
        try { await entry.delete(); } catch (_) {}
      }
    }
  }

  /// Streams to private app storage; no 200 MB allocation in Dart RAM.
  Future<File> download(CloudFile item) async {
    if (!connected) throw StateError('Cloud not connected');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final cache = await _cacheDir();
    final safe = item.name.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_');
    final target = File(cache.path + Platform.pathSeparator + 'cloud_' +
      nextMidnightIst().toString() + '_' + item.id + '_' + safe);
    try {
      final request = await client.getUrl(
        _host!.resolve('/v1/owner/file/' + item.id));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ' + _ownerToken!);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('Cloud download returned HTTP ' +
          response.statusCode.toString());
      }
      await response.pipe(target.openWrite());
      return target;
    } catch (_) {
      if (await target.exists()) await target.delete();
      rethrow;
    } finally { client.close(force: true); }
  }

  Future<void> deleteRemote(CloudFile item) async {
    await _call('DELETE', '/v1/owner/file/' + item.id);
    files.removeWhere((f) => f.id == item.id);
    notifyListeners();
  }
}
