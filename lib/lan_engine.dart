import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local-only file sharing. UDP broadcast discovers peers; direct TCP streams
/// bytes without loading entire files into memory. No cloud calls or login.
class LanPeer {
  const LanPeer(this.id, this.name, this.address, this.port, this.lastSeen);
  final String id, name, address;
  final int port;
  final DateTime lastSeen;
}

enum TransferState { queued, preparing, sending, receiving, delivered, failed }

class LanFile {
  LanFile({
    required this.id, required this.batch, required this.name,
    required this.path, required this.peer, required this.incoming,
    required this.size, required this.created, required this.state,
    this.done = 0, this.error, this.peerId = '',
  });
  final String id, batch, name, path, peer, peerId;
  final bool incoming;
  final int size;
  final DateTime created;
  TransferState state;
  int done;
  String? error;

  double get progress => size == 0
      ? (state == TransferState.delivered ? 1 : 0)
      : (done / size).clamp(0.0, 1.0).toDouble();

  Map<String, dynamic> toJson() => {
    'id': id, 'batch': batch, 'name': name, 'path': path,
    'peer': peer, 'peerId': peerId, 'incoming': incoming, 'size': size,
    'created': created.toUtc().toIso8601String(),
    'state': state.name, 'done': done,
  };

  static LanFile? fromJson(Object? obj) {
    try {
      if (obj is! Map<String, dynamic>) return null;
      final status = obj['state'] as String? ?? 'failed';
      return LanFile(
        id: obj['id'] as String, batch: obj['batch'] as String,
        name: obj['name'] as String, path: obj['path'] as String,
        peer: obj['peer'] as String, peerId: (obj['peerId'] as String?) ?? '',
        incoming: obj['incoming'] == true,
        size: (obj['size'] as num).toInt(),
        created: DateTime.parse(obj['created'] as String),
        state: TransferState.values.firstWhere((x) => x.name == status,
          orElse: () => TransferState.failed),
        done: (obj['done'] as num?)?.toInt() ?? 0,
      );
    } catch (_) { return null; }
  }
}


/// A batch is committed only after the user presses Send. Its source files
/// are private snapshots so delivery survives closing the app.
class QueuedLanItem {
  QueuedLanItem(this.id, this.name, this.path, this.size);
  final String id, name, path;
  final int size;
  Map<String,dynamic> toJson() => {'id':id,'name':name,'path':path,'size':size};
  static QueuedLanItem? fromJson(Object? raw) {
    if(raw is! Map<String,dynamic>) return null;
    try {return QueuedLanItem(raw['id'] as String,raw['name'] as String,
      raw['path'] as String,(raw['size'] as num).toInt());}
    catch(_){return null;}
  }
}
class QueuedLanBatch {
  QueuedLanBatch(this.id,this.created,this.items,[Set<String>? delivered])
    : deliveredKeys=delivered??<String>{};
  final String id;
  final DateTime created;
  final List<QueuedLanItem> items;
  final Set<String> deliveredKeys;
  Map<String,dynamic> toJson()=>{'id':id,'created':created.toUtc().toIso8601String(),
    'items':items.map((e)=>e.toJson()).toList(),'delivered':deliveredKeys.toList()};
  static QueuedLanBatch? fromJson(Object? raw){
    if(raw is! Map<String,dynamic>)return null;
    try {
      final items=(raw['items'] as List).map(QueuedLanItem.fromJson)
        .whereType<QueuedLanItem>().toList();
      if(items.isEmpty)return null;
      return QueuedLanBatch(raw['id'] as String,DateTime.parse(raw['created'] as String),
        items,(raw['delivered'] as List? ?? []).whereType<String>().toSet());
    }catch(_){return null;}
  }
}

class LanEngine extends ChangeNotifier {
  LanEngine({this.discoveryPort = 49310, this.tcpPort = 49311,
    this.expiry = const Duration(hours: 24),
    this.testSupportDirectory, this.testDeviceId});
  // Injected only for isolated socket tests; production uses app private paths.
  final Directory? testSupportDirectory;
  final String? testDeviceId;
  final int discoveryPort, tcpPort;
  final Duration expiry;
  final List<LanFile> files = [];
  final List<QueuedLanBatch> queuedBatches = [];
  final Map<String, LanPeer> peers = {};
  final Set<String> _activePeers = {};
  final Map<String, DateTime> _attempts = {};
  ServerSocket? _server;
  RawDatagramSocket? _discovery;
  static const MethodChannel _bonjour = MethodChannel('file_share.lan_discovery');
  final Set<String> _bonjourPeerIds = <String>{};
  bool _bonjourStarted = false;
  Timer? _heartbeat, _cleanup, _listenerRetry;
  bool _bindingReceiver = false;
  int _listenerGeneration = 0;
  bool get receivingEnabled => _server != null;
  Directory? _inbox, _outbox;
  File? _db, _queueDb;
  String? deviceId, error;
  bool started = false, _disposed = false;
  Future<void>? _starting;
  Future<void> Function(LanFile)? onReceived;
  Future<void> _writes = Future<void>.value();

  static String newId() => base64Url.encode(
    List<int>.generate(16, (_) => Random.secure().nextInt(256))).replaceAll('=', '');

  static String safeFileName(String input) {
    final clean = input.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_').trim();
    if (clean.isEmpty || clean == '.' || clean == '..') return 'file';
    return clean.length > 180 ? clean.substring(clean.length - 180) : clean;
  }

  void _notify() { if (!_disposed) notifyListeners(); }

  // The UI and the cached background FlutterEngine can request start together.
  // Use one server/UDP listener rather than racing for the same ports.
  Future<void> start() {
    if (started) return Future<void>.value();
    return _starting ??= _startOnce().whenComplete(() => _starting = null);
  }

  Future<void> _startOnce() async {
    final dir = testSupportDirectory ?? await getApplicationSupportDirectory();
    _inbox = Directory(dir.path + Platform.pathSeparator + 'fileshare_inbox');
    await _inbox!.create(recursive: true);
    _db = File(_inbox!.path + Platform.pathSeparator + 'history.json');
    _outbox = Directory(_inbox!.path + Platform.pathSeparator + 'outbox');
    await _outbox!.create(recursive: true);
    _queueDb = File(_inbox!.path + Platform.pathSeparator + 'pending_batches.json');
    if (testDeviceId != null) {
      deviceId = testDeviceId;
    } else {
      final preferences = SharedPreferencesAsync();
      deviceId = await preferences.getString('lan_device_id') ?? newId();
      await preferences.setString('lan_device_id', deviceId!);
    }
    await _restore();
    await _loadQueue();
    await cleanExpired();
    await _bindReceiver();
    // Recover automatically if an older app process temporarily owns the port.
    _listenerRetry = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_server == null) unawaited(_bindReceiver());
    });
    // iOS rejects raw UDP broadcast without Apple's restricted multicast
    // entitlement. Bonjour is the system-supported discovery mechanism.
    // Android keeps the UDP v1 discovery for existing older clients.
    if (!Platform.isIOS) try {
      _discovery = await RawDatagramSocket.bind(InternetAddress.anyIPv4,
        discoveryPort, reuseAddress: true);
      _discovery!.broadcastEnabled = true;
      _discovery!.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = _discovery?.receive()) != null) {
          _receiveAnnouncement(packet!);
        }
      });
      refresh();
      _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        refresh();
        _expirePeers();
        _dispatchQueued();
      });
    } catch (e) { error = 'LAN broadcast unavailable: ' + e.toString(); }
    if (testSupportDirectory == null && (Platform.isIOS || Platform.isAndroid)) {
      await _startBonjour();
    }
    // Keep peer cleanup and queued delivery alive even on iOS without UDP.
    _heartbeat ??= Timer.periodic(const Duration(seconds: 5), (_) {
      _expirePeers();
      _dispatchQueued();
    });
    _cleanup = Timer.periodic(const Duration(minutes: 1),
      (_) { unawaited(cleanExpired()); });
    started = true;
    _notify();
  }

  /// One TCP receiver per LAN engine. No shared ServerSocket binding: shared
  /// ports can randomly deliver a file to the wrong process on Windows.
  /// Failed binds are retried without resetting the saved transfer queue.
  Future<void> _bindReceiver() async {
    if (_bindingReceiver || _server != null || _disposed) return;
    _bindingReceiver = true;
    final generation = _listenerGeneration;
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.anyIPv4, tcpPort);
      if (generation != _listenerGeneration) {
        await socket.close();
        return;
      }
      _server = socket;
      socket.listen((connection) => unawaited(_accept(connection)),
        onError: (Object e) {
          error = 'LAN receive connection error: $e';
          _notify();
        });
      if (error?.startsWith('LAN receiver port') == true ||
          error?.startsWith('Unable to listen for LAN files') == true) {
        error = null;
      }
    } on SocketException catch (e) {
      // Windows 10048, Linux 98 and macOS 48 indicate an occupied port.
      final code = e.osError?.errorCode;
      final isBusy = code == 10048 || code == 98 || code == 48;
      error = isBusy
        ? 'LAN receiver port $tcpPort is already in use. '
          'Close the other File Share process. Automatically retrying.'
        : 'LAN receiver could not start; retrying: $e';
      debugPrint('LAN listener bind failed: $e');
    } catch (e) {
      error = 'LAN receiver unavailable; retrying: $e';
    } finally {
      _bindingReceiver = false;
      _notify();
    }
  }

  /// iOS Bonjour and Android NsdManager advertise the same TCP receiver.
  /// Both platforms announce stable IDs via TXT records and resolve to IPv4.
  Future<void> _startBonjour() async {
    if (_bonjourStarted || _server == null || deviceId == null) return;
    _bonjour.setMethodCallHandler((call) async {
      if (_disposed || !started && _starting == null) return;
      final data = call.arguments;
      if (data is! Map) return;
      if (call.method == 'lost') {
        final id = data['id'];
        if (id is String && _bonjourPeerIds.remove(id)) {
          peers.remove(id);
          _notify();
        }
        return;
      }
      if (call.method == 'error') {
        error = 'Nearby discovery: ${data['message'] ?? 'unavailable'}';
        _notify();
        return;
      }
      if (call.method != 'peer') return;
      final id = data['id'], address = data['address'];
      final name = data['name'], port = data['port'];
      if (id is! String || id.isEmpty || id == deviceId ||
          id.length > 100 || address is! String ||
          InternetAddress.tryParse(address)?.type != InternetAddressType.IPv4 ||
          port is! int || port < 1 || port > 65535) return;
      final first = !peers.containsKey(id);
      _bonjourPeerIds.add(id);
      peers[id] = LanPeer(id, safeFileName(name is String ? name : 'Device'),
          address, port, DateTime.now());
      _notify();
      if (first) _dispatchQueued();
    });
    try {
      await _bonjour.invokeMethod<void>('start', {
        'id': deviceId!, 'name': Platform.localHostname, 'port': _server!.port,
      });
      _bonjourStarted = true;
    } on PlatformException catch (e) {
      error = 'Bonjour discovery unavailable: ${e.message ?? e.code}';
      _notify();
    } on MissingPluginException {
      error = 'Nearby discovery module missing. Install the updated build.';
      _notify();
    }
  }

  Future<void> retryReceiver() => _bindReceiver();

  void refresh() {
    if (_discovery == null) return;
    final bytes = utf8.encode(jsonEncode({
      'app': 'fileshare-lan-v1', 'id': deviceId,
      'name': Platform.localHostname, 'port': tcpPort,
    }));
    try {
      _discovery!.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (e) { error = 'Discovery broadcast failed: ' + e.toString(); }
  }

  void _receiveAnnouncement(Datagram packet) {
    try {
      final obj = jsonDecode(utf8.decode(packet.data));
      if (obj is! Map || obj['app'] != 'fileshare-lan-v1' ||
          obj['id'] == deviceId || obj['id'] is! String ||
          obj['port'] is! int || (obj['port'] as int) <= 0) return;
      final id = obj['id'] as String;
      if (id.length > 100) return;
      final firstSeen = !peers.containsKey(id);
      peers[id] = LanPeer(id, safeFileName((obj['name'] as String?) ?? 'Device'),
        packet.address.address, obj['port'] as int, DateTime.now());
      _notify();
      if(firstSeen)refresh();
      _dispatchQueued();
    } catch (_) {}
  }

  void _expirePeers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 22));
    peers.removeWhere((key, peer) =>
      !_bonjourPeerIds.contains(key) && peer.lastSeen.isBefore(cutoff));
    _notify();
  }

  Future<void> _restore() async {
    if (_db == null || !await _db!.exists()) return;
    try {
      final obj = jsonDecode(await _db!.readAsString());
      if (obj is List) {
        final seen = files.map((item) => item.id).toSet();
        for (final raw in obj) {
          final file = LanFile.fromJson(raw);
          if (file == null || !seen.add(file.id)) continue;
          if (file.state != TransferState.delivered &&
              file.state != TransferState.queued) {
            file.state = TransferState.failed;
          }
          files.add(file);
        }
      }
    } catch (e) { error = 'Local history read failed: ' + e.toString(); }
  }


  Future<void> _loadQueue() async {
    if(_queueDb==null||!await _queueDb!.exists())return;
    try {
      final raw=jsonDecode(await _queueDb!.readAsString());
      if(raw is List){
        final seen = queuedBatches.map((batch) => batch.id).toSet();
        queuedBatches.addAll(raw.map(QueuedLanBatch.fromJson)
          .whereType<QueuedLanBatch>().where((batch) => seen.add(batch.id)));
      }
    }catch(e){error='Pending queue read failed: '+e.toString();}
  }
  void _saveQueue(){
    final contents=jsonEncode(queuedBatches.map((e)=>e.toJson()).toList());
    _writes=_writes.then((_)async{
      if(_queueDb==null)return;
      final tmp=File(_queueDb!.path+'.tmp');
      await tmp.writeAsString(contents,flush:true);
      if(await _queueDb!.exists())await _queueDb!.delete();
      await tmp.rename(_queueDb!.path);
    }).catchError((Object e){error='Pending queue save failed: '+e.toString();});
  }

  /// Starts only when Send is pressed; no nearby device is required.
  Future<String> enqueue(List<File> sources,{List<String>? names})async{
    if(!started||_outbox==null)throw StateError('LAN engine not ready');
    if(sources.isEmpty)throw StateError('No selected files');
    final batchId=newId();
    final items=<QueuedLanItem>[];
    try{
      for(var i=0;i<sources.length;i++){
        final source=sources[i];
        if(!await source.exists())throw StateError('Selected file unavailable');
        final fileId=newId();
        final name=safeFileName(names!=null&&names.length>i
          ?names[i]:source.uri.pathSegments.last);
        final copy=File(_outbox!.path+Platform.pathSeparator+fileId+'_'+name);
        await source.openRead().pipe(copy.openWrite());
        items.add(QueuedLanItem(fileId,name,copy.path,await copy.length()));
      }
      final batch=QueuedLanBatch(batchId,DateTime.now(),items);
      queuedBatches.add(batch);
      for(final item in items){
        files.insert(0,LanFile(id:item.id,batch:batchId,name:item.name,
          path:item.path,peer:'Waiting for nearby devices',incoming:false,
          size:item.size,created:batch.created,state:TransferState.queued));
      }
      _update(save:true);
      _saveQueue();
      await _writes;
      _dispatchQueued();
      return batchId;
    }catch(_){
      for(final item in items){final f=File(item.path);
        if(await f.exists())await f.delete();}
      rethrow;
    }
  }
  void _dispatchQueued(){
    if(!started||queuedBatches.isEmpty||peers.isEmpty)return;
    for(final peer in peers.values.toList()){
      if(_activePeers.add(peer.id)){
        unawaited(_deliverToPeer(peer).whenComplete(()=>_activePeers.remove(peer.id)));
      }
    }
  }
  Future<void> _deliverToPeer(LanPeer peer)async{
    try{
      for(final batch in queuedBatches.toList()){
        if(DateTime.now().difference(batch.created)>=expiry)continue;
        for(final item in batch.items.toList()){
          final key=peer.id+':'+item.id;
          if(batch.deliveredKeys.contains(key))continue;
          final last=_attempts[key];
          if(last!=null&&DateTime.now().difference(last)<const Duration(seconds:30))continue;
          _attempts[key]=DateTime.now();
          final source=File(item.path);
          if(!await source.exists())continue;
          final matches=files.where((f)=>!f.incoming && f.batch==batch.id &&
            f.peerId==peer.id && f.id=='${item.id}_${peer.id}');
          final entry=matches.isNotEmpty ? matches.first : LanFile(
            id:'${item.id}_${peer.id}',batch:batch.id,name:item.name,
            path:item.path,peer:peer.name,peerId:peer.id,incoming:false,
            size:item.size,created:batch.created,state:TransferState.preparing);
          if(matches.isEmpty)files.insert(0,entry);
          entry.state=TransferState.preparing;
          entry.error=null;
          entry.done=0;
          _update(save:true);
          await _sendOne(source,peer,entry);
          if(entry.state==TransferState.delivered){
            batch.deliveredKeys.add(key);_saveQueue();
          }else{return;}
        }
      }
    }catch(e){error='Queued LAN delivery: '+e.toString();_notify();}
  }
  Future<void> cancelQueuedBatch(String id)async{
    final batches=queuedBatches.where((b)=>b.id==id).toList();
    if(batches.isEmpty)return;
    final batch=batches.first;queuedBatches.remove(batch);
    files.removeWhere((e)=>e.batch==id&&!e.incoming&&e.state==TransferState.queued);
    for(final item in batch.items){
      final f=File(item.path);if(await f.exists())await f.delete();
    }
    _saveQueue();_update(save:true);
  }

  void _save() {
    final snapshot = jsonEncode(files.map((x) => x.toJson()).toList());
    _writes = _writes.then((_) async {
      if (_db == null) return;
      final temp = File(_db!.path + '.tmp');
      await temp.writeAsString(snapshot, flush: true);
      if (await _db!.exists()) await _db!.delete();
      await temp.rename(_db!.path);
    }).catchError((Object e) { error = 'History save failed: ' + e.toString(); });
  }

  void _update({bool save = false}) {
    _notify();
    if (save) _save();
  }

  /// Send each selected original file to each nearby peer. No originals are
  /// deleted during cleanup, only temporary received copies in the app inbox.
  Future<void> send(List<File> selected, Iterable<LanPeer> destinations,
      {String? batchId}) async {
    final targets = destinations.toList();
    if (targets.isEmpty) throw StateError('No LAN receiver is available.');
    final batch = batchId ?? newId();
    final tasks = <Future<void>>[];
    for (final file in selected) {
      if (!await file.exists()) continue;
      final size = await file.length();
      for (final peer in targets) {
        final record = LanFile(
          id: newId(), batch: batch,
          name: safeFileName(file.uri.pathSegments.last),
          path: file.path, peer: peer.name, peerId: peer.id, incoming: false,
          size: size, created: DateTime.now(), state: TransferState.preparing);
        files.insert(0, record);
        tasks.add(_sendOne(file, peer, record));
      }
    }
    _update(save: true);
    await Future.wait(tasks);
  }

  Future<void> _sendOne(File source, LanPeer peer, LanFile record) async {
    Socket? socket;
    try {
      socket = await Socket.connect(peer.address, peer.port,
        timeout: const Duration(seconds: 8));
      socket.setOption(SocketOption.tcpNoDelay, true);
      final accepted = Completer<bool>();
      final ack = <int>[];
      socket.listen((chunk) {
        if (accepted.isCompleted) return;
        ack.addAll(chunk);
        if (ack.length > 128) {
          accepted.complete(false);
        } else if (ack.contains(10)) {
          accepted.complete(utf8.decode(ack).startsWith('OK'));
        }
      }, onDone: () {
        if (!accepted.isCompleted) accepted.complete(false);
      }, onError: (Object _) {
        if (!accepted.isCompleted) accepted.complete(false);
      });
      socket.add(utf8.encode(jsonEncode({
        'protocol': 'fileshare-file-v1', 'id': record.id,
        'batch': record.batch, 'name': record.name,
        'size': record.size, 'sender': Platform.localHostname,
        'senderId': deviceId,
      }) + '\n'));
      record.state = TransferState.sending;
      _notify();
      var written = 0;
      var checkpoint = 0;
      await for (final chunk in source.openRead()) {
        socket.add(chunk);
        written += chunk.length;
        record.done = written;
        if (written - checkpoint > 1024 * 1024 || written == record.size) {
          checkpoint = written;
          await socket.flush(); // bounded buffering
          _notify();
        }
      }
      await socket.flush();
      // The receiver acknowledges at the declared byte count. Keep the
      // channel writable/readable until we have the ACK; close() can swallow it.
      final ok = await accepted.future.timeout(const Duration(seconds: 45));
      if (!ok) throw const SocketException('Receiver did not acknowledge file');
      record.state = TransferState.delivered;
      record.done = record.size;
      record.error = null;
      if (error?.startsWith('Send failed:') == true) error = null;
    } catch (e) {
      record.state = TransferState.failed;
      record.error = e.toString();
      error = 'Send failed: ' + e.toString();
    } finally {
      socket?.destroy();
      _update(save: true);
    }
  }

  Future<void> _accept(Socket socket) async {
    IOSink? out;
    File? part;
    LanFile? record;
    // A socket's end-of-stream is NOT required to finish a file. Android
    // clients may keep TCP open for an ACK, so read exactly the framed size.
    final reader = StreamIterator<List<int>>(socket);
    try {
      final header = <int>[];
      var ready = false, got = 0, expected = -1;
      var alreadyDelivered = false;
      Future<void> store(List<int> bytes) async {
        if (bytes.isEmpty) return;
        if (got + bytes.length > expected) {
          throw const FormatException('More bytes than declared');
        }
        if (!alreadyDelivered) out!.add(bytes);
        got += bytes.length;
        if (!alreadyDelivered) {
          record!.done = got;
          if (got == expected || got % (1024 * 1024) < bytes.length) {
            await out!.flush();
            _notify();
          }
        }
      }

      // Prevent abandoned connections from tying up the receiver indefinitely.
      while (await reader.moveNext().timeout(const Duration(seconds: 60))) {
        final chunk = reader.current;
        if (ready) {
          await store(chunk);
        } else {
          final newline = chunk.indexOf(10);
          if (newline == -1) {
            header.addAll(chunk);
            if (header.length > 8192) {
              throw const FormatException('Header too long');
            }
            continue;
          }
          header.addAll(chunk.sublist(0, newline));
          if (header.length > 8192) {
            throw const FormatException('Header too long');
          }
          final meta = jsonDecode(utf8.decode(header));
          if (meta is! Map || meta['protocol'] != 'fileshare-file-v1' ||
              meta['size'] is! int || (meta['size'] as int) < 0 ||
              meta['name'] is! String) {
            throw const FormatException('Invalid transfer');
          }
          expected = meta['size'] as int;
          final senderId = (meta['senderId'] as String?) ?? socket.remoteAddress.address;
          final transferId = (meta['id'] as String?) ?? '';
          // Stable, scoped IDs survive ACK loss and sender retries.
          final id = transferId.isEmpty ? newId() : '${senderId}_$transferId';
          final name = safeFileName(meta['name'] as String);
          final destination = _inbox!.path + Platform.pathSeparator + id + '_' + name;
          final existing = files.where((f) => f.incoming && f.id == id &&
            f.state == TransferState.delivered && f.size == expected &&
            f.name == name && File(f.path).existsSync());
          alreadyDelivered = existing.isNotEmpty;
          if (alreadyDelivered) {
            record = existing.first;
          } else {
            // A previous partial attempt must not produce another card.
            files.removeWhere((f) => f.incoming && f.id == id &&
              f.state != TransferState.delivered);
            part = File(destination + '.part');
            out = part.openWrite();
            record = LanFile(
              id: id, batch: safeFileName((meta['batch'] as String?) ?? id),
              name: name, path: destination,
              peer: safeFileName((meta['sender'] as String?) ?? socket.remoteAddress.address),
              peerId: senderId,
              incoming: true, size: expected, created: DateTime.now(),
              state: TransferState.receiving);
            files.insert(0, record);
            _update(save: true);
          }
          ready = true;
          await store(chunk.sublist(newline + 1));
        }
        // The protocol explicitly declares file length. Don't wait for FIN.
        if (ready && got == expected) break;
      }

      if (!ready || got != expected) {
        throw const SocketException('Incoming file incomplete');
      }
      if (!alreadyDelivered) {
        await out!.flush();
        await out.close();
        out = null;
        await part!.rename(record!.path);
        record.state = TransferState.delivered;
        record.done = expected;
        // Persist completion before acknowledging so a retry is idempotent.
        _update(save: true);
        await _writes;
      }
      socket.add(utf8.encode('OK\n'));
      await socket.flush();
      // Let the ACK leave the TCP stack before cancelling the stream/socket.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final callback = onReceived;
      if (!alreadyDelivered && callback != null) {
        unawaited(Future.sync(() => callback(record!)).catchError((Object e) {
          error = 'System notification unavailable: $e';
          _notify();
        }));
      }
    } catch (e) {
      if (record != null) {
        record.state = TransferState.failed;
        record.error = e.toString();
      }
      error = 'Receive failed: $e';
      try {
        socket.add(utf8.encode('ERR\n'));
        await socket.flush();
      } catch (_) {}
    } finally {
      try { await out?.close(); } catch (_) {}
      if (record?.state != TransferState.delivered) {
        try {
          if (part != null && await part.exists()) await part.delete();
        } catch (_) {}
      }
      await reader.cancel();
      socket.destroy();
      _update(save: true);
    }
  }

  Future<void> remove(String id) async {
    final hits = files.where((entry) => entry.id == id).toList();
    if (hits.isEmpty) return;
    final item = hits.first;
    if(item.state==TransferState.queued){await cancelQueuedBatch(item.batch);return;}
    // Never delete sender originals.
    if (item.incoming) {
      final f = File(item.path);
      if (await f.exists()) await f.delete();
    }
    files.remove(item);
    _update(save: true);
  }

  Future<void> cleanExpired() async {
    final now = DateTime.now();
    for (final entry in files.where((item) =>
      now.difference(item.created) >= expiry &&
      item.state != TransferState.sending &&
      item.state != TransferState.receiving &&
      item.state != TransferState.preparing).toList()) {
      try { await remove(entry.id); } catch (e) {
        error = 'Cleanup retry needed: ' + e.toString();
      }
    }
    for(final batch in queuedBatches.where((b)=>
      now.difference(b.created)>=expiry).toList()){
      try{await cancelQueuedBatch(batch.id);}
      catch(e){error='Queued cleanup will retry: '+e.toString();}
    }
    if (_inbox == null) return;
    try {
      await for (final entity in _inbox!.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.part') && !name.startsWith('stage_')) continue;
        final inUse = files.any((f) => f.path == entity.path &&
          (f.state == TransferState.sending || f.state == TransferState.preparing));
        if (inUse) continue;
        if (now.difference((await entity.stat()).modified) > expiry) {
          await entity.delete();
        }
      }
    } catch (e) { error = 'Orphan cleanup: ' + e.toString(); }
  }

  Future<void> stop() async {
    _listenerGeneration++;
    _listenerRetry?.cancel();
    _listenerRetry = null;
    _heartbeat?.cancel();
    _cleanup?.cancel();
    _discovery?.close();
    if (_bonjourStarted) {
      _bonjourStarted = false;
      try { await _bonjour.invokeMethod<void>('stop'); } catch (_) {}
    }
    _bonjourPeerIds.clear();
    peers.clear();
    await _server?.close();
    _server = null;
    _discovery = null;
    started = false;
    _notify();
    await _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
