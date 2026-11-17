import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'account_directory.dart';

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
  String? _sessionToken;
  String? _accountEmail;
  int _sessionExpiry = 0;
  String? _qrLink;
  final List<CloudFile> files = [];
  final Map<String, Future<File>> _downloadsInFlight = {};
  // A single foreground WebSocket replaces all periodic inbox polling.
  WebSocket? _inboxSocket;
  StreamSubscription<dynamic>? _inboxSubscription;
  Timer? _inboxReconnect;
  bool _inboxLiveEnabled=false;
  bool _inboxConnecting=false;
  bool _inboxRefreshPending=false;
  int _inboxReconnectFailures=0;

  String? error;
  bool loading = false;
  bool _loggedOut = false;
  bool get signedIn => !_loggedOut && _sessionToken != null &&
      _sessionExpiry > DateTime.now().millisecondsSinceEpoch;
  String? get accountEmail => _accountEmail;
  bool get connected => !_loggedOut && _host != null &&
    (signedIn || (_ownerToken != null && _accountEmail == null));
  bool get cloudSetupSaved => _host != null;
  bool get canRegisterAccount => _ownerToken != null && _host != null;
  String? get workerOrigin => _host?.origin;
  String? get endpoint => _host?.origin;
  String? get qrLink => _qrLink;

  // Restore the locally encrypted connection without a network request.
  Future<void> restore() async {
    try {
      final host = await _secrets.read(key: 'personal_worker_url');
      final secret = await _secrets.read(key: 'personal_owner_token');
      _loggedOut = await _secrets.read(key: 'personal_signed_out') == 'yes';
      _sessionToken = await _secrets.read(key: 'personal_auth_session');
      _accountEmail = await _secrets.read(key: 'personal_auth_email');
      _sessionExpiry = int.tryParse(await _secrets.read(
        key: 'personal_auth_expiry') ?? '') ?? 0;
      if(_sessionExpiry <= DateTime.now().millisecondsSinceEpoch){
        _sessionToken=null;
        await _secrets.delete(key:'personal_auth_session');
      }
      if(host != null) {
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
    Uri host, String token, String method, String path,
    [Map<String, dynamic>? payload]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.openUrl(method, host.resolve(path));
      if(token.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ' + token);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if(payload != null){
        request.headers.contentType=ContentType.json;
        request.add(utf8.encode(jsonEncode(payload)));
      }
      final response = await request.close().timeout(const Duration(seconds: 18));
      final body = await utf8.decoder.bind(response).join();
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Unexpected Worker response');
      }
      if (response.statusCode < 200 || response.statusCode > 299 ||
          data['ok'] != true) {
        // Older personal Workers return one generic credential message.
        // Directory already resolved this email, so a login 401 means
        // a wrong password, not an unreachable cloud connection.
        if(path=='/v1/auth/login' && response.statusCode==401){
          throw StateError('Incorrect password');
        }
        if(path=='/v1/auth/login' && response.statusCode==404){
          throw StateError('Email address is not registered');
        }
        throw StateError(data['error']?.toString() ?? 'Cloud request failed');
      }
      return data;
    } finally { client.close(force: true); }
  }

  Future<Map<String, dynamic>> _call(String method, String path) {
    if (!connected) throw StateError('Please login. Your Cloudflare setup is retained.');
    return _request(_host!, signedIn ? _sessionToken! : _ownerToken!, method, path);
  }


  // Real signup and login live in the owner's own Cloudflare Worker/D1.
  // The worker URL is required on a second device without a central directory.
  Future<void> _acceptLogin(Map<String, dynamic> data, Uri host) async {
    final token=data['session'], email=data['email'], expiry=data['expiresAt'];
    if(token is! String || email is! String || expiry is! num ||
       token.isEmpty || expiry.toInt() <= DateTime.now().millisecondsSinceEpoch){
      throw const FormatException('Invalid account session from Worker');
    }
    await _secrets.write(key:'personal_worker_url',value:host.origin);
    await _secrets.write(key:'personal_auth_session',value:token);
    await _secrets.write(key:'personal_auth_email',value:email);
    await _secrets.write(key:'personal_auth_expiry',value:expiry.toInt().toString());
    await _secrets.delete(key:'personal_signed_out');
    _host=host;
    _sessionToken=token;
    _accountEmail=email;
    _sessionExpiry=expiry.toInt();
    _loggedOut=false;
    error=null;
    notifyListeners();
  }

  Future<void> registerAccount(String email,String password) async {
    if(!canRegisterAccount) {
      throw StateError('Connect or provision your personal Worker first');
    }
    final data=await _request(_host!,_ownerToken!,'POST','/v1/auth/register',{
      'email':email.trim().toLowerCase(),'password':password,
    });
    await _acceptLogin(data,_host!);
  }

  Future<void> loginAccount(String workerUrl,String email,String password) async {
    final host=_validWorker(workerUrl);
    final data=await _request(host,'','POST','/v1/auth/login',{
      'email':email.trim().toLowerCase(),'password':password,
    });
    await _acceptLogin(data,host);
    // Authenticate with the session, not a Cloudflare administrative API key.
    await refreshFiles();
  }

  /// Direct personal Worker login: Directory resolves ONLY the Worker URL.
  /// The password never passes through Central Directory or its D1.
  Future<void> loginByEmail(String email,String password) async {
    final normalized=email.trim().toLowerCase();
    final workerUrl=await AccountDirectory.instance.resolveWorker(normalized);
    final host=_validWorker(workerUrl);
    final data=await _request(host,'','POST','/v1/auth/login',{
      'email':normalized,'password':password,
    });
    if(data['email']!=normalized) {
      throw StateError('Personal cloud returned a different account email');
    }
    final token=data['session'];
    if(token is! String || token.isEmpty) {
      throw const FormatException('Missing personal cloud login session');
    }
    final proof=await _request(host,token,'GET','/v1/auth/me');
    if(proof['email']!=normalized) {
      throw StateError('Personal cloud did not verify this account');
    }
    await _acceptLogin(data,host);
    await refreshFiles();
  }

  /// Bind this account to exactly one personal cloud for email/password
  /// sign-in across devices. No email delivery or OTP is involved.
  Future<void> linkAccountDirectory() async {
    if(!signedIn || _accountEmail==null || _host==null || _sessionToken==null) {
      throw StateError('Log in to your personal cloud before linking');
    }
    await AccountDirectory.instance.linkAccount(
      email:_accountEmail!, workerUrl:_host!.origin,
      personalSession:_sessionToken!,
    );
  }

  Future<void> validateAccountSession() async {
    if(!signedIn || _host==null)return;
    try{
      await _request(_host!,_sessionToken!,'GET','/v1/auth/me');
    }catch(_){
      _sessionToken=null;
      await _secrets.delete(key:'personal_auth_session');
      notifyListeners();
    }
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
    _loggedOut = false;
    await _secrets.delete(key: 'personal_signed_out');
    error = null;
    notifyListeners();
  }

  /// Local worker sign-out keeps encrypted setup for the same phone.
  /// Real email/password login and cross-device recovery require the future
  /// account auth service; this is NOT a replacement for authentication.
  Future<void> signOutLocal() async {
    stopLiveInbox();
    _loggedOut = true;
    _sessionToken=null;
    _qrLink = null;
    files.clear();
    await _secrets.write(key: 'personal_signed_out', value: 'yes');
    await _secrets.delete(key:'personal_auth_session');
    notifyListeners();
  }

  Future<void> disconnect() async {
    stopLiveInbox();
    _host = null;
    _ownerToken = null;
    _sessionToken=null;
    _sessionExpiry=0;
    _accountEmail=null;
    _loggedOut = false;
    _qrLink = null;
    files.clear();
    await _secrets.delete(key: 'personal_worker_url');
    await _secrets.delete(key: 'personal_owner_token');
    await _secrets.delete(key: 'personal_signed_out');
    await _secrets.delete(key:'personal_auth_session');
    await _secrets.delete(key:'personal_auth_email');
    await _secrets.delete(key:'personal_auth_expiry');
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

  /// Open one authenticated WebSocket while the dashboard is foregrounded.
  /// Only a 'files-changed' signal crosses the socket; metadata is fetched
  /// once on reconnect and when a real upload/delete event arrives.
  void startLiveInbox() {
    if(_inboxLiveEnabled)return;
    _inboxLiveEnabled=true;
    _inboxReconnectFailures=0;
    unawaited(_connectLiveInbox());
  }

  void stopLiveInbox() {
    _inboxLiveEnabled=false;
    _inboxReconnect?.cancel();
    _inboxReconnect=null;
    final old=_inboxSocket;
    _inboxSocket=null;
    unawaited(_inboxSubscription?.cancel()??Future<void>.value());
    _inboxSubscription=null;
    if(old!=null)unawaited(old.close());
  }

  Future<void> _connectLiveInbox() async {
    if(!_inboxLiveEnabled || _inboxConnecting || _inboxSocket!=null ||
       !signedIn || _host==null)return;
    _inboxConnecting=true;
    try {
      final uri=_host!.replace(scheme:'wss',path:'/v1/owner/events');
      final socket=await WebSocket.connect(uri.toString(),headers:{
        HttpHeaders.authorizationHeader:'Bearer '+_sessionToken!,
      }).timeout(const Duration(seconds:12));
      if(!_inboxLiveEnabled || !signedIn){
        await socket.close();
        return;
      }
      _inboxSocket=socket;
      _inboxReconnectFailures=0;
      // Reconcile missed upload events after any network interruption.
      unawaited(_refreshAfterEvent());
      _inboxSubscription=socket.listen((message){
        if(message=='files-changed')unawaited(_refreshAfterEvent());
      },onError:(Object _){
        _lostLiveInbox(socket);
      },onDone:(){
        _lostLiveInbox(socket);
      },cancelOnError:true);
    }catch(error){
      // Legacy Workers respond 404 to the new endpoint. Do NOT probe them
      // every minute: owner must explicitly upgrade Worker once via Auto
      // Connect. Genuine network drops still use bounded reconnect backoff.
      final message=error.toString();
      if(message.contains('HTTP status code: 404') ||
         message.contains('HTTP status code: 426') ||
         message.contains('HTTP status code: 503')){
        _inboxLiveEnabled=false;
      }else{
        _scheduleInboxReconnect();
      }
    }finally{
      _inboxConnecting=false;
    }
  }

  void _lostLiveInbox(WebSocket socket) {
    if(!identical(_inboxSocket,socket))return;
    _inboxSocket=null;
    unawaited(_inboxSubscription?.cancel()??Future<void>.value());
    _inboxSubscription=null;
    _scheduleInboxReconnect();
  }

  void _scheduleInboxReconnect() {
    if(!_inboxLiveEnabled || !signedIn || _inboxReconnect!=null)return;
    const seconds=[2,4,8,16,30,60];
    final index=_inboxReconnectFailures.clamp(0,seconds.length-1);
    _inboxReconnectFailures++;
    // Backoff only after a broken socket; never poll a healthy connection.
    _inboxReconnect=Timer(Duration(seconds:seconds[index]),(){
      _inboxReconnect=null;
      unawaited(_connectLiveInbox());
    });
  }

  Future<void> _refreshAfterEvent() async {
    if(loading){
      _inboxRefreshPending=true;
      return;
    }
    await refreshFiles();
  }

  /// Metadata fetch is event-triggered or explicit, never timed polling.
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
    finally {
      loading = false;
      notifyListeners();
      // If an upload notification arrived while another refresh was
      // in-flight, coalesce it into ONE follow-up D1 request.
      if(_inboxRefreshPending && _inboxLiveEnabled){
        _inboxRefreshPending=false;
        scheduleMicrotask(() => unawaited(_refreshAfterEvent()));
      }
    }
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
  // The dashboard can hide expired QR cards at midnight with ZERO network calls.
  void removeExpiredLocalEntries() {
    const day = 86400000, istOffset = 19800000;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final before = files.length;
    files.removeWhere((entry) {
      final created = entry.created.toUtc().millisecondsSinceEpoch;
      final expiry = ((created + istOffset) ~/ day + 1) * day - istOffset;
      return expiry <= now;
    });
    if (files.length != before) notifyListeners();
    unawaited(cleanupLocalCache());
  }

  /// Reuse downloads across thumbnail, preview, Share, Tools and Save.
  /// File data stays in private storage and expires with the QR files.
  Future<File> download(CloudFile item) {
    final pending=_downloadsInFlight[item.id];
    if(pending!=null)return pending;
    final task=_downloadFile(item);
    _downloadsInFlight[item.id]=task;
    task.then((_) => _downloadsInFlight.remove(item.id),
      onError:(Object _) => _downloadsInFlight.remove(item.id));
    return task;
  }

  Future<File> _downloadFile(CloudFile item) async {
    if(!connected)throw StateError('Cloud not connected');
    final cache=await _cacheDir();
    final safe=item.name.replaceAll(RegExp(r'[/\\\x00-\x1f]'),'_');
    final target=File(cache.path+Platform.pathSeparator+'cloud_'+
      nextMidnightIst().toString()+'_'+item.id+'_'+safe);
    if(await target.exists()){
      if(await target.length()==item.size)return target;
      await target.delete();
    }
    final temporary=File(target.path+'.part');
    final client=HttpClient()..connectionTimeout=const Duration(seconds:12);
    try{
      final request=await client.getUrl(
        _host!.resolve('/v1/owner/file/'+item.id));
      request.headers.set(HttpHeaders.authorizationHeader,'Bearer '+
        (signedIn?_sessionToken!:_ownerToken!));
      final response=await request.close().timeout(const Duration(seconds:30));
      if(response.statusCode!=200)throw StateError(
        'Cloud download returned HTTP '+response.statusCode.toString());
      await response.pipe(temporary.openWrite());
      if(await temporary.length()!=item.size)throw const FormatException(
        'Cloud file download was incomplete');
      return temporary.rename(target.path);
    }catch(_){
      if(await temporary.exists())await temporary.delete();
      rethrow;
    }finally{client.close(force:true);}
  }

  Future<void> deleteRemote(CloudFile item) async {
    await _call('DELETE', '/v1/owner/file/' + item.id);
    files.removeWhere((f) => f.id == item.id);
    notifyListeners();
  }
}
