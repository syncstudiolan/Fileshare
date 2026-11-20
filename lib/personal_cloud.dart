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
    required this.session, required this.created,
    this.deviceTransfer=false, this.senderId='', this.senderName='',
    this.receivedAt});
  final String id, name, session, senderId, senderName;
  final bool deviceTransfer;
  final int size;
  final DateTime created;
  final DateTime? receivedAt;
}

/// A local outgoing Dashboard card, created immediately after Send.
/// Progress reflects acknowledged R2 chunks, not a simulated timer.
class CloudUploadJob {
  CloudUploadJob(this.localId,this.file,this.name,this.size,this.senderId);
  final String localId,name,senderId;
  final File file;
  final int size;
  String? remoteId,error;
  double progress=0;
  bool uploading=true;
  bool failed=false;
  DateTime created=DateTime.now();
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
  final List<CloudUploadJob> outgoingUploads = [];
  int _uploadSequence=0;
  final Map<String, Future<File>> _downloadsInFlight = {};
  // A single foreground WebSocket replaces all periodic inbox polling.
  WebSocket? _inboxSocket;
  StreamSubscription<dynamic>? _inboxSubscription;
  Timer? _inboxReconnect;
  Timer? _inboxEventDebounce;
  bool _inboxLiveEnabled=false;
  bool get liveInboxEnabled => _inboxLiveEnabled;
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

  Future<Map<String, dynamic>> _call(String method, String path,
      [Map<String, dynamic>? payload]) {
    if (!connected) throw StateError('Please login. Your Cloudflare setup is retained.');
    return _request(_host!, signedIn ? _sessionToken! : _ownerToken!, method, path, payload);
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
    _inboxEventDebounce?.cancel();
    _inboxEventDebounce=null;
    _inboxRefreshPending=false;
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
      // Subscribe before the initial reconciliation, so there is no gap
      // where a newly completed QR upload could be missed.
      _inboxSubscription=socket.listen((message){
        if(message=='files-changed')_queueInboxRefresh();
      },onError:(Object _){
        _lostLiveInbox(socket);
      },onDone:(){
        _lostLiveInbox(socket);
      },cancelOnError:true);
      _queueInboxRefresh();
    }catch(error){
      // Legacy Workers respond 404 to the new endpoint. Do NOT probe them
      // every minute: owner must explicitly upgrade Worker once via Auto
      // Connect. Genuine network drops still use bounded reconnect backoff.
      final message=error.toString();
      if(message.contains('HTTP status code: 404') ||
         message.contains('HTTP status code: 426') ||
         message.contains('HTTP status code: 503')){
        _inboxLiveEnabled=false;
        // Older Workers have no push endpoint; reconcile just once, not via polling.
        unawaited(refreshFiles());
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

  /// Coalesce burst QR and device-transfer notifications into one D1 fetch.
  /// The timer is event-triggered, not a periodic polling timer.
  void _queueInboxRefresh(){
    if(!_inboxLiveEnabled || _inboxEventDebounce!=null)return;
    _inboxEventDebounce=Timer(const Duration(milliseconds:180),(){
      _inboxEventDebounce=null;
      unawaited(_refreshAfterEvent());
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
      // Current Worker serves QR and device transfers in ONE HTTP response.
      // Older Workers fall back to their original endpoints unchanged.
      Map<String,dynamic>? combined;
      if(signedIn){
        try{
          combined=await _call('GET','/v1/owner/inbox');
        }catch(e){
          if(!e.toString().contains('Not found'))rethrow;
        }
      }
      var offset = 0;
      while (offset < 10000) {
        final data = combined!=null && offset==0 ? combined :
          await _call('GET','/v1/owner/files?offset=' + offset.toString());
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
      // The owner inbox also lists transfers from other logged-in devices.
      // Older Workers without this endpoint retain the existing QR inbox.
      if(signedIn){
        try{
          final remote=combined ?? await _call('GET','/v1/owner/transfers');
          final transferRows=combined!=null ? remote['transfers'] : remote['files'];
          for(final entry in (transferRows as List? ?? [])){
            if(entry is! Map)continue;
            final id=entry['id'] as String;
            fetched.add(CloudFile(
              id:id,name:entry['name'] as String,
              size:(entry['size'] as num).toInt(),
              session:'device_'+id,
              senderId:(entry['sender_id'] as String?)??'',
              senderName:(entry['sender_name'] as String?)??'Device',
              receivedAt:entry['received_at'] is num
                ?DateTime.fromMillisecondsSinceEpoch(
                    (entry['received_at'] as num).toInt()):null,
              deviceTransfer:true,
              created:DateTime.fromMillisecondsSinceEpoch(
                (entry['created_at'] as num).toInt())));
          }
        }catch(e){debugPrint('Device inbox unavailable: '+e.toString());}
      }
      files..clear()..addAll(fetched);
      // A completed outgoing progress card is replaced by the durable
      // cloud card once it appears in the unified inbox.
      final uploadedIds=fetched.map((f)=>f.id).toSet();
      outgoingUploads.removeWhere((job)=>
        !job.uploading && !job.failed && job.remoteId!=null &&
        uploadedIds.contains(job.remoteId));
      error = null;
    } catch (e) { error = 'Cloud inbox refresh failed: ' + e.toString(); }
    finally {
      loading = false;
      notifyListeners();
      // If an upload notification arrived while another refresh was
      // in-flight, coalesce it into ONE follow-up D1 request.
      if(_inboxRefreshPending && _inboxLiveEnabled){
        _inboxRefreshPending=false;
        scheduleMicrotask(_queueInboxRefresh);
      }
    }
  }

  /// Move a file out of Cart immediately; upload continues from this
  /// existing process while the user navigates to another dashboard page.
  /// On platforms that suspend background work (especially iOS), completion
  /// still requires OS runtime and is not guaranteed after force-quit.
  void queueDeviceUpload(File file,String name,String senderId) {
    final job=CloudUploadJob(
      '${DateTime.now().microsecondsSinceEpoch}_${_uploadSequence++}',
      file,name,file.lengthSync(),senderId);
    outgoingUploads.add(job);
    notifyListeners();
    unawaited(_runOutgoingJob(job));
  }

  Future<void> retryDeviceUpload(CloudUploadJob job) async {
    if(job.uploading)return;
    job.uploading=true;
    job.failed=false;
    job.error=null;
    job.progress=0;
    notifyListeners();
    await _runOutgoingJob(job);
  }

  Future<void> _runOutgoingJob(CloudUploadJob job) async {
    try {
      await uploadDeviceFile(job.file,job.name,job.senderId,
        senderName:Platform.localHostname,
        onCreated:(id){job.remoteId=id;notifyListeners();},
        onProgress:(fraction){
          job.progress=fraction;
          notifyListeners();
        });
      // Server confirmed R2 upload. The local Cart snapshot is disposable;
      // the original edited project/source remains untouched.
      job.progress=1;
      job.uploading=false;
      job.failed=false;
      notifyListeners();
      try{
        await _deleteUploadedEditorSnapshot(job.file);
      }catch(e){debugPrint('Cloud editor snapshot cleanup skipped: $e');}
      // Inbox refresh failure must NOT mislabel a committed R2 upload as
      // failed and let Retry create a duplicate transfer.
      try{await refreshFiles();}catch(e){
        debugPrint('Post-upload inbox reconciliation deferred: $e');
      }
    }catch(e){
      job.uploading=false;
      job.failed=true;
      job.error=e.toString();
      // A transfer from a previous IST day is no longer retryable on the
      // server: midnight cleanup discards both incomplete R2 parts and D1.
      if(DateTime.now().toUtc().millisecondsSinceEpoch>=midnightAfterIst(
          job.created.toUtc().millisecondsSinceEpoch)){
        outgoingUploads.remove(job);
        try{await _deleteUploadedEditorSnapshot(job.file);}
        catch(error){debugPrint('Expired Cloud snapshot cleanup: $error');}
      }
      notifyListeners();
    }
  }

  Future<void> _deleteUploadedEditorSnapshot(File file) async {
    final root=await getApplicationSupportDirectory();
    final folders=['editor_cart_versions','image_editing_cart','signature_cart'];
    final path=file.absolute.path;
    if(!folders.any((folder)=>path.startsWith(
        root.path+Platform.pathSeparator+folder+Platform.pathSeparator)))return;
    if(await file.exists())await file.delete();
  }

  /// A double tick requires the receiver to have explicitly saved the
  /// complete downloaded file. Merely seeing inbox metadata is not delivery.
  Future<void> acknowledgeDeviceReceipt(CloudFile item,String? receiverId) async {
    if(!item.deviceTransfer || receiverId==null ||
       receiverId.isEmpty || receiverId==item.senderId || !signedIn)return;
    await _call('POST','/v1/owner/transfer/${item.id}/received',{
      'deviceId':receiverId,
    });
  }

  /// 200MB cross-network sends are only invoked after the LAN-first gate.
  /// Reuse the user's existing Cloudflare login and Worker; no second API key.
  Future<void> uploadDeviceFile(File source,String name,String senderId,
      {String senderName='File Share',
       void Function(double fraction)? onProgress,
       void Function(String id)? onCreated})async{
    if(!signedIn||_host==null)throw StateError('Log in to enable cloud transfer');
    if(senderId.isEmpty)throw StateError('Device identity is not ready');
    if(!await source.exists())throw StateError('Selected file is missing');
    final size=await source.length();
    if(size<1||size>200*1024*1024)throw StateError('Cloud limit is 200 MB per file');
    final init=await _call('POST','/v1/owner/transfer',{
      'name':name,'size':size,'senderId':senderId,'senderName':senderName,
    });
    final id=init['id'] as String;
    onCreated?.call(id);
    const chunk=6*1024*1024;
    if(size<=chunk){
      await _uploadDevicePart(source,id,0,size,false,
        onBytes:(count)=>onProgress?.call(count/size*0.98));
      onProgress?.call(1);
    }else{
      var offset=0,part=1;
      while(offset<size){
        final end=offset+chunk>size?size:offset+chunk;
        await _uploadDevicePart(source,id,offset,end,true,part:part,
          onBytes:(count)=>onProgress?.call((count/size).clamp(0.0,0.98).toDouble()));
        offset=end;
        onProgress?.call((offset/size).clamp(0.0,0.98).toDouble());
        part++;
      }
      await _call('POST','/v1/owner/transfer/'+id+'/complete');
      onProgress?.call(1);
    }
  }

  Future<void> _uploadDevicePart(File file,String id,int offset,int end,
      bool multipart,{int part=1,void Function(int count)? onBytes})async{
    final uri=_host!.resolve('/v1/owner/transfer/'+id+
      (multipart?'/part/'+part.toString():''));
    for(var attempt=0;attempt<3;attempt++){
      final client=HttpClient()..connectionTimeout=const Duration(seconds:15);
      try{
        final request=await client.putUrl(uri);
        request.headers.set(HttpHeaders.authorizationHeader,'Bearer '+_sessionToken!);
        request.headers.contentType=ContentType.binary;
        request.contentLength=end-offset;
        var read=0;
        await request.addStream(file.openRead(offset,end).map((bytes){
          read+=bytes.length;
          onBytes?.call(offset+read);
          return bytes;
        }));
        final response=await request.close().timeout(const Duration(seconds:90));
        final body=await utf8.decoder.bind(response).join();
        if(response.statusCode<200||response.statusCode>=300){
          throw StateError('Cloud upload HTTP '+response.statusCode.toString()+': '+body);
        }
        return;
      }catch(_){
        if(attempt==2)rethrow;
        await Future<void>.delayed(Duration(seconds:attempt+1));
      }finally{client.close(force:true);}
    }
  }

  /// Midnight IST immediately following a file's creation timestamp.
  /// Never recompute a cache entry's expiry from the current date.
  static int midnightAfterIst(int epochMillis) {
    const day=86400000, offset=19800000;
    return ((epochMillis+offset)~/day+1)*day-offset;
  }

  static int nextMidnightIst() =>
    midnightAfterIst(DateTime.now().toUtc().millisecondsSinceEpoch);

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
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final before = files.length;
    files.removeWhere((entry) {
      final created = entry.created.toUtc().millisecondsSinceEpoch;
      // LAN is rolling-24h (inside LanEngine). ALL Cloud entries, both QR
      // and logged-in transfers, expire at the next midnight in India.
      final expiry = midnightAfterIst(created);
      return expiry <= now;
    });
    // Clear stale outgoing Cloud progress/failed-retry cards at midnight too.
    // Do not remove LAN Pending files; their separate 24h timer remains.
    final oldJobs=outgoingUploads.where((job)=>
      midnightAfterIst(job.created.toUtc().millisecondsSinceEpoch)<=now
    ).toList();
    outgoingUploads.removeWhere(oldJobs.contains);
    for(final job in oldJobs){
      if(!job.uploading){
        unawaited(_deleteUploadedEditorSnapshot(job.file).catchError(
          (Object e)=>debugPrint('Expired Cloud cart cleanup: $e')));
      }
    }
    if (files.length != before || oldJobs.isNotEmpty) notifyListeners();
    unawaited(cleanupLocalCache());
  }

  /// Reuse downloads across thumbnail, preview, Share, Tools and Save.
  /// File data stays in private storage and expires with the QR files.
  Future<File> download(CloudFile item) {
    final pending=_downloadsInFlight[item.id];
    if(pending!=null)return pending;
    final task=_downloadFile(item);
    _downloadsInFlight[item.id]=task;
    task.then<void>((_) {
      _downloadsInFlight.remove(item.id);
    }, onError:(Object _, StackTrace __) {
      _downloadsInFlight.remove(item.id);
    });
    return task;
  }

  Future<File> _downloadFile(CloudFile item) async {
    if(!connected)throw StateError('Cloud not connected');
    final cache=await _cacheDir();
    final safe=item.name.replaceAll(RegExp(r'[/\\\x00-\x1f]'),'_');
    final target=File(cache.path+Platform.pathSeparator+'cloud_'+
      midnightAfterIst(item.created.toUtc().millisecondsSinceEpoch)
        .toString()+'_'+item.id+'_'+safe);
    if(await target.exists()){
      if(await target.length()==item.size)return target;
      await target.delete();
    }
    final temporary=File(target.path+'.part');
    final client=HttpClient()..connectionTimeout=const Duration(seconds:12);
    try{
      final request=await client.getUrl(
        _host!.resolve(item.deviceTransfer
          ? '/v1/owner/transfer/'+item.id
          : '/v1/owner/file/'+item.id));
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
    await _call('DELETE',
      (item.deviceTransfer?'/v1/owner/transfer/':'/v1/owner/file/')+item.id);
    files.removeWhere((f) => f.id == item.id);
    notifyListeners();
  }
}
