import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nsd/nsd.dart' as nsd;
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

/// All platforms share one peer registry, independently tracking discovery
/// sources. A loss on one transport must not erase another live route.
@visibleForTesting
class WindowsLanPeerSources {
  final _udp=<String,LanPeer>{};
  final _bonjour=<String,LanPeer>{};
  final _native=<String,LanPeer>{};
  final _verified=<String,LanPeer>{};

  bool get hasBonjourPeers=>_bonjour.isNotEmpty;
  void observeUdp(LanPeer peer)=>_udp[peer.id]=peer;
  void observeNative(LanPeer peer)=>_native[peer.id]=peer;
  void loseNative(String id)=>_native.remove(id);
  void clearNative()=>_native.clear();
  void observeVerified(LanPeer peer)=>_verified[peer.id]=peer;
  Iterable<LanPeer> verified(DateTime now)=>_verified.values.where((p)=>
      now.difference(p.lastSeen)<const Duration(seconds:30));
  void replaceBonjour(Iterable<LanPeer> snapshot) {
    _bonjour
      ..clear()
      ..addEntries(snapshot.map((p)=>MapEntry(p.id,p)));
  }
  Map<String,LanPeer> snapshot(DateTime now) {
    final cutoff=now.subtract(const Duration(seconds:22));
    _udp.removeWhere((_,p)=>p.lastSeen.isBefore(cutoff));
    // Prefer the fresh directly observed UDP address if available. DNS-SD
    // remains the route for iPhone and other Bonjour-only devices.
    _verified.removeWhere((_,p)=>now.difference(p.lastSeen)>=const Duration(seconds:30));
    return {..._bonjour,..._native,..._udp,..._verified};
  }
  void clear(){_udp.clear();_bonjour.clear();_native.clear();_verified.clear();}
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
  nsd.Registration? _windowsRegistration;
  nsd.Discovery? _windowsDiscovery;
  final _windowsSources=WindowsLanPeerSources();
  bool _windowsRegistering=false, _windowsBrowsing=false, _windowsUdpBinding=false;
  DateTime? _windowsBrowseStartedAt, _lastNativeRefresh;
  bool _nativeStarting=false, _nativeRestartNeeded=false;
  final _helloCandidates=<String,LanPeer>{};
  final _helloAttempts=<String,DateTime>{};
  final _helloActive=<String>{};
  static const _helloProtocol='fileshare-peer-hello-v2';
  static const _helloCap=32;
  Timer? _heartbeat, _cleanup, _listenerRetry;
  bool _bindingReceiver = false;
  int _listenerGeneration = 0;
  bool get receivingEnabled => _server != null;
  Directory? _inbox, _outbox;
  File? _db, _queueDb;
  String? deviceId, error;
  bool started = false, _disposed = false;
  Future<void>? _starting, _stopping;
  final _incomingConnections=<Socket,Future<void>>{};
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
    if(_disposed)return Future<void>.value();
    final stopping=_stopping;
    if(stopping!=null)return stopping.then((_)=>start());
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
      if (_server != null) return;
      unawaited(_bindReceiver().then((_) async {
        // If a background copy of File Share temporarily held the TCP port,
        // discovery must start when the receiver finally becomes available.
        // Previously the retry re-bound TCP but never advertised that socket.
        if (_server == null || _disposed) return;
        if (testSupportDirectory == null &&
            (Platform.isIOS || Platform.isAndroid || Platform.isMacOS) &&
            !_bonjourStarted) {
          await _startBonjour();
        }
        if (testSupportDirectory == null && Platform.isWindows) {
          unawaited(_startWindowsBonjour());
        }
      }));
    });
    // iOS rejects raw UDP broadcast without Apple's restricted multicast
    // entitlement. macOS can also lose IPv4 broadcasts due to network and
    // firewall policies. Bonjour DNS-SD is shared by iOS, Android and macOS;
    // keep UDP v1 on desktops/Android only for older LAN clients.
    // Isolated unit tests need only the TCP queue/receiver.
    if(testSupportDirectory==null && !Platform.isIOS) {
      unawaited(_ensureWindowsUdp());
    }
    if (testSupportDirectory == null &&
        (Platform.isIOS || Platform.isAndroid || Platform.isMacOS)) {
      unawaited(_startBonjour());
    }
    if (testSupportDirectory == null && Platform.isWindows) {
      unawaited(_startWindowsBonjour());
    }
    // Identical cadence for every platform; native discovery remains running.
    _heartbeat=Timer.periodic(const Duration(seconds:5), (_) {
      if(testSupportDirectory==null)refresh(refreshBonjour: false);
      _expirePeers();
      _pumpHello();
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
      socket.listen((connection) {
        if(generation!=_listenerGeneration||_disposed||_stopping!=null){
          connection.destroy();
          return;
        }
        final task=_accept(connection).catchError((Object e){
          debugPrint('LAN receive cleanup: $e');
        }).whenComplete((){_incomingConnections.remove(connection);});
        _incomingConnections[connection]=task;
        unawaited(task);
      },
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

  // Windows UDP stays independent from native DNS-SD, including recovery
  // after a transient bind error or network/socket shutdown.
  Future<void> _ensureWindowsUdp() async {
    if(Platform.isIOS || _disposed || _windowsUdpBinding ||
        _discovery!=null || testSupportDirectory!=null)return;
    _windowsUdpBinding=true;
    final generation=_listenerGeneration;
    RawDatagramSocket? socket;
    try {
      final bound=await RawDatagramSocket.bind(InternetAddress.anyIPv4,
          discoveryPort,reuseAddress:true);
      socket=bound;
      if(_disposed||generation!=_listenerGeneration){bound.close();return;}
      bound.broadcastEnabled=true;
      _discovery=bound;
      void lost() {
        if(identical(_discovery,bound)){
          _discovery=null;
          bound.close();
        }
      }
      bound.listen((event) {
        if(event!=RawSocketEvent.read)return;
        Datagram? packet;
        while((packet=bound.receive())!=null){_receiveAnnouncement(packet!);}
      },onError:(Object e){
        debugPrint('Windows LAN UDP listener: $e');
        lost();
      },onDone:lost);
      _sendAnnouncement();
    }catch(e){
      if(identical(_discovery,socket))_discovery=null;
      socket?.close();
      if(!_disposed&&generation==_listenerGeneration){
        debugPrint('Windows LAN UDP bind failed; retrying: $e');
      }
    }finally{_windowsUdpBinding=false;}
  }

  // Windows 10 1903+ native DNS-SD. Registering this device and browsing
  // others are independent operations; a failure in one cannot stop the
  // other or permanently disable discovery while TCP is already healthy.
  Future<void> _startWindowsBonjour() async {
    if(!Platform.isWindows||deviceId==null||_server==null||_disposed||
        testSupportDirectory!=null)return;
    await Future.wait([_ensureWindowsRegistration(),_ensureWindowsBrowser()]);
  }

  Future<void> _ensureWindowsRegistration() async {
    if(_windowsRegistration!=null||_windowsRegistering)return;
    _windowsRegistering=true;
    final generation=_listenerGeneration;
    try{
      final id=deviceId!;
      final instance='FileShare-${id.substring(0,min(8,id.length))}';
      final registration=await nsd.register(nsd.Service(
        name:instance,type:'_fileshare._tcp',port:_server!.port,
        txt:<String,Uint8List>{
          'id':Uint8List.fromList(utf8.encode(id)),
          'n':Uint8List.fromList(utf8.encode(Platform.localHostname)),
          'v':Uint8List.fromList(utf8.encode('2')),
        },
      ));
      if(_disposed||generation!=_listenerGeneration){
        await nsd.unregister(registration);
        return;
      }
      _windowsRegistration=registration;
    }catch(e){debugPrint('Windows LAN DNS-SD registration failed; retrying: $e');}
    finally{_windowsRegistering=false;}
  }

  Future<void> _ensureWindowsBrowser() async {
    if(_windowsBrowsing)return;
    final existing=_windowsDiscovery;
    // Recover a silent empty browser, without restarting healthy sessions.
    if(existing!=null &&
        (_windowsSources.hasBonjourPeers || _windowsBrowseStartedAt==null ||
         DateTime.now().difference(_windowsBrowseStartedAt!)<
             const Duration(seconds:30)))return;
    _windowsBrowsing=true;
    final generation=_listenerGeneration;
    try{
      if(existing!=null){
        // Keep the old reference if stopping fails; avoid duplicate native
        // browser handles. Its callbacks are ignored only after successful stop.
        await nsd.stopDiscovery(existing);
        if(identical(_windowsDiscovery,existing)){
          _windowsDiscovery=null;
          _windowsSources.replaceBonjour(const []);
          _publishWindowsPeers();
        }
      }
      if(_disposed||generation!=_listenerGeneration)return;
      final discovery=await nsd.startDiscovery('_fileshare._tcp',
          ipLookupType:nsd.IpLookupType.v4);
      if(_disposed||generation!=_listenerGeneration){
        await nsd.stopDiscovery(discovery);
        return;
      }
      _windowsDiscovery=discovery;
      _windowsBrowseStartedAt=DateTime.now();
      void update(){
        if(_disposed||generation!=_listenerGeneration||
            !identical(_windowsDiscovery,discovery))return;
        _readWindowsBonjour(discovery);
      }
      discovery.addListener(update);
      update(); // Include results that arrived before the listener was added.
    }catch(e){debugPrint('Windows LAN DNS-SD browser failed; retrying: $e');}
    finally{_windowsBrowsing=false;}
  }

  void _readWindowsBonjour(nsd.Discovery discovery) {
    final fresh=<LanPeer>[];
    for(final service in discovery.services){
      final idBytes=service.txt?['id'];
      final id=idBytes==null?null:utf8.decode(idBytes,allowMalformed:true);
      final port=service.port;
      if(id==null||id.isEmpty||id==deviceId||id.length>100||
          port==null||port<1||port>65535)continue;
      final addresses=service.addresses??const <InternetAddress>[];
      final ipv4=addresses.where((a)=>a.type==InternetAddressType.IPv4 &&
          !a.isLoopback && a.address!='0.0.0.0' && a.address!='255.255.255.255');
      if(ipv4.isEmpty)continue;
      final nameBytes=service.txt?['n'];
      final name=nameBytes==null?(service.name??'Device'):
          utf8.decode(nameBytes,allowMalformed:true);
      final peer=LanPeer(id,safeFileName(name),ipv4.first.address,port,DateTime.now());
      fresh.add(peer);
      final version=service.txt?['v'];
      if(version!=null && utf8.decode(version,allowMalformed:true)=='2')_offerHello(peer);
    }
    _windowsSources.replaceBonjour(fresh);
    _publishWindowsPeers();
  }

  void _publishWindowsPeers(){
    if(_disposed)return;
    final next=_windowsSources.snapshot(DateTime.now());
    peers..clear()..addAll(next);
    _notify();
    _dispatchQueued();
  }

  /// iOS and macOS NetService, and Android NsdManager, advertise the same
  /// TCP receiver using stable device IDs in TXT records and IPv4 peers.
  Future<void> _startBonjour() async {
    if (_bonjourStarted || _nativeStarting || _disposed || _server == null || deviceId == null) return;
    _nativeStarting=true;
    final generation=_listenerGeneration;
    _bonjour.setMethodCallHandler((call) async {
      if (_disposed || generation!=_listenerGeneration || !started && _starting == null) return;
      final data = call.arguments;
      if (data is! Map) return;
      if (call.method == 'lost') {
        final id = data['id'];
        if (id is String && _bonjourPeerIds.remove(id)) {
          _windowsSources.loseNative(id);
          _publishWindowsPeers();
        }
        return;
      }
      if (call.method == 'error') {
        final message=data['message']?.toString()??'unavailable';
        if(message.toLowerCase().contains('browse') || message.toLowerCase().contains('discovery failed') || message.toLowerCase().contains('advertis')) {
          _nativeRestartNeeded=true;
        }
        error = 'Nearby discovery: $message';
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
      if (error?.startsWith('Nearby discovery:') == true ||
          error?.startsWith('Bonjour discovery unavailable:') == true ||
          (Platform.isMacOS &&
           error?.startsWith('LAN broadcast unavailable:') == true)) {
        error = null;
      }
      final peer=LanPeer(id,safeFileName(name is String?name:'Device'),address,port,DateTime.now());
      _windowsSources.observeNative(peer);
      if(data['v']=='2')_offerHello(peer);
      _publishWindowsPeers();
      if(first)_pumpHello();
    });
    try {
      await _bonjour.invokeMethod<void>('start', {
        'id': deviceId!, 'name': Platform.localHostname, 'port': _server!.port,
      });
      if(generation!=_listenerGeneration||_disposed){
        await _bonjour.invokeMethod<void>('stop');
        return;
      }
      _bonjourStarted = true;
      _lastNativeRefresh=DateTime.now();
    } on PlatformException catch (e) {
      error = 'Bonjour discovery unavailable: ${e.message ?? e.code}';
      _notify();
    } on MissingPluginException {
      error = 'Nearby discovery module missing. Install the updated build.';
      _notify();
    } finally {_nativeStarting=false;}
  }

  Future<void> _restartNativeBonjour() async {
    if(_nativeStarting)return;
    _nativeStarting=true;
    try{await _bonjour.invokeMethod<void>('stop');}catch(_){}
    finally{_nativeStarting=false;}
    _bonjourPeerIds.clear();
    _windowsSources.clearNative();
    _publishWindowsPeers();
    if(!_disposed&&(started||_starting!=null))await _startBonjour();
  }

  Future<void> retryReceiver() => _bindReceiver();

  void refresh({bool refreshBonjour = true}) {
    if(testSupportDirectory!=null || _disposed)return;
    if(!Platform.isIOS)unawaited(_ensureWindowsUdp());
    if(Platform.isWindows){
      unawaited(_startWindowsBonjour());
      if(refreshBonjour && _windowsDiscovery!=null){
        _readWindowsBonjour(_windowsDiscovery!);
      }
    }else if(Platform.isIOS||Platform.isAndroid||Platform.isMacOS){
      final now=DateTime.now();
      final canRefresh=_lastNativeRefresh==null ||
        now.difference(_lastNativeRefresh!)>=const Duration(seconds:30);
      if(_nativeRestartNeeded && canRefresh && !_nativeStarting){
        _nativeRestartNeeded=false;
        _bonjourStarted=false;
        _lastNativeRefresh=now;
        unawaited(_restartNativeBonjour());
        return;
      }
      if(!_bonjourStarted){
        unawaited(_startBonjour());
      }else if(canRefresh && (refreshBonjour||peers.isEmpty)){
        _lastNativeRefresh=now;
        unawaited(_bonjour.invokeMethod<void>('refresh').catchError((Object e){
          debugPrint('Nearby refresh failed: $e');
          _nativeRestartNeeded=true;
        }));
      }
    }
    _sendAnnouncement();
    _pumpHello();
  }

  void _sendAnnouncement({InternetAddress? destination}) {
    final socket=_discovery;
    final receiver=_server;
    if(socket==null || receiver==null || deviceId==null)return;
    final bytes=utf8.encode(jsonEncode({
      'app':'fileshare-lan-v1','id':deviceId,
      'name':Platform.localHostname,'port':receiver.port,'v':'2',
    }));
    try{
      socket.send(bytes,destination??InternetAddress('255.255.255.255'),discoveryPort);
    }catch(e){debugPrint('LAN announcement failed: $e');}
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
      if(id.isEmpty || (obj['port'] as int)>65535 || packet.address.isLoopback ||
          packet.address.address=='0.0.0.0')return;
      final peer=LanPeer(id,safeFileName((obj['name'] as String?)??'Device'),
          packet.address.address,obj['port'] as int,DateTime.now());
      _windowsSources.observeUdp(peer);
      if(obj['v']=='2')_offerHello(peer);
      _publishWindowsPeers();
      if(firstSeen)_sendAnnouncement(destination:packet.address);
    } catch (_) {}
  }

  void _expirePeers() {
    if(testSupportDirectory!=null && _helloCandidates.isEmpty && _windowsSources.verified(DateTime.now()).isEmpty){
      final cutoff=DateTime.now().subtract(const Duration(seconds:22));
      peers.removeWhere((_,p)=>p.lastSeen.isBefore(cutoff));
      _notify();
      return;
    }
    _publishWindowsPeers();
  }

  // Only known v2 File Share advertisements and verified same-subnet hints
  // can seed this control exchange. No scanning or relaying file payloads.
  bool _validHelloPeer(LanPeer p) {
    final ip=InternetAddress.tryParse(p.address);
    return p.id.isNotEmpty && p.id!=deviceId && p.id.length<=100 &&
      ip!=null && ip.type==InternetAddressType.IPv4 &&
      (!ip.isLoopback || testSupportDirectory!=null) &&
      !ip.isMulticast && ip.address!='0.0.0.0' &&
      p.port>0 && p.port<=65535 &&
      (testSupportDirectory!=null||p.port==tcpPort);
  }

  bool _sameLocalSubnet(String address,String local) {
    final ip=InternetAddress.tryParse(address);
    final own=InternetAddress.tryParse(local);
    if(ip==null||own==null||ip.type!=InternetAddressType.IPv4||
        own.type!=InternetAddressType.IPv4)return false;
    if(testSupportDirectory!=null)return ip.isLoopback&&own.isLoopback;
    if(ip.isLoopback||own.isLoopback)return false;
    // Conservative /24 hint boundary: direct UDP/Bonjour still supports
    // larger networks. Do not follow arbitrary addresses advertised by peers.
    final x=ip.rawAddress,y=own.rawAddress;
    return x[0]==y[0]&&x[1]==y[1]&&x[2]==y[2]&&
      x[3]!=0&&x[3]!=255&&address!=local;
  }

  // Dart's accepted Socket.address can be the listener's wildcard address
  // (0.0.0.0); an outbound Socket.address may be the destination address.
  // Neither is a reliable interface address. Use the OS interface list
  // and the actual TCP remote address for the same-subnet security boundary.
  Future<String?> _localHelloInterfaceFor(String remote) async {
    try {
      final interfaces=await NetworkInterface.list(
        type:InternetAddressType.IPv4,includeLoopback:testSupportDirectory!=null);
      for(final interface in interfaces){
        for(final address in interface.addresses){
          if(_sameLocalSubnet(remote,address.address))return address.address;
        }
      }
    }catch(e){
      debugPrint('LAN interface lookup failed: $e');
    }
    return null;
  }

  void _offerHello(LanPeer peer) {
    if(_disposed||!_validHelloPeer(peer))return;
    final now=DateTime.now();
    _helloCandidates.removeWhere((_,p)=>now.difference(p.lastSeen)>const Duration(seconds:45));
    if(!_helloCandidates.containsKey(peer.id)&&_helloCandidates.length>=_helloCap)return;
    _helloCandidates[peer.id]=peer;
    _pumpHello();
  }

  @visibleForTesting
  void seedHelloPeerForTest(LanPeer peer) {
    if(testSupportDirectory==null)throw StateError('Test discovery only');
    _offerHello(peer);
  }

  @visibleForTesting
  int? get receiverPortForTest=>testSupportDirectory==null?null:_server?.port;

  void _pumpHello(){
    if(_disposed||_server==null||deviceId==null)return;
    final now=DateTime.now();
    _helloCandidates.removeWhere((_,p)=>now.difference(p.lastSeen)>const Duration(seconds:45));
    _helloAttempts.removeWhere((id,time)=>!_helloCandidates.containsKey(id)&&
        now.difference(time)>const Duration(seconds:45));
    for(final peer in _helloCandidates.values.toList()){
      if(_helloActive.length>=4)break;
      final last=_helloAttempts[peer.id];
      if(last!=null&&now.difference(last)<const Duration(seconds:10))continue;
      if(!_helloActive.add(peer.id))continue;
      _helloAttempts[peer.id]=now;
      unawaited(_probeHello(peer).whenComplete(()=>_helloActive.remove(peer.id)));
    }
  }

  Map<String,Object?> _helloIdentity()=>{'id':deviceId,'name':Platform.localHostname,
      'port':_server!.port};
  LanPeer? _parseHelloPeer(Object? value,String address){
    if(value is! Map)return null;
    final id=value['id'],name=value['name'],port=value['port'];
    if(id is! String||name is! String||port is! int)return null;
    final p=LanPeer(id,safeFileName(name),address,port,DateTime.now());
    return _validHelloPeer(p)?p:null;
  }

  Future<Map?> _readHelloLine(Socket socket) async{
    final bytes=<int>[];
    await for(final chunk in socket.timeout(const Duration(seconds:3))){
      final end=chunk.indexOf(10);
      bytes.addAll(end<0?chunk:chunk.sublist(0,end));
      if(bytes.length>8192)return null;
      if(end>=0){
        final value=jsonDecode(utf8.decode(bytes));
        return value is Map?value:null;
      }
    }
    return null;
  }

  Future<void> _probeHello(LanPeer candidate) async{
    final generation=_listenerGeneration;
    Socket? socket;
    try{
      socket=await Socket.connect(candidate.address,candidate.port,
          timeout:const Duration(seconds:2));
      if(generation!=_listenerGeneration||_disposed||_server==null)return;
      socket.add(utf8.encode(jsonEncode({'protocol':_helloProtocol,..._helloIdentity()})+'\n'));
      await socket.flush().timeout(const Duration(seconds:2));
      final remote=socket.remoteAddress.address;
      final response=await _readHelloLine(socket);
      if(generation!=_listenerGeneration||_disposed||response==null||
          response['protocol']!=_helloProtocol)return;
      final confirmed=_parseHelloPeer(response,remote);
      if(confirmed==null||confirmed.id!=candidate.id||confirmed.port!=candidate.port)return;
      _windowsSources.observeVerified(confirmed);
      _helloCandidates[confirmed.id]=confirmed;
      _publishWindowsPeers();
      final local=await _localHelloInterfaceFor(remote);
      if(generation!=_listenerGeneration||_disposed||local==null)return;
      final hints=response['peers'];
      if(hints is List){
        for(final hint in hints.take(_helloCap)){
          if(hint is! Map||hint['address'] is! String)continue;
          final address=hint['address'] as String;
          if(!_sameLocalSubnet(address,local))continue;
          final p=_parseHelloPeer(hint,address);
          if(p!=null&&!_helloCandidates.containsKey(p.id))_offerHello(p);
        }
      }
    }catch(e){
      // Keep routine production retries quiet, but expose real socket failure
      // details in CI instead of leaving a bare convergence timeout.
      if(testSupportDirectory!=null)debugPrint('LAN hello $deviceId -> ${candidate.id}: $e');
    }
    finally{socket?.destroy();}
  }

  Future<void> _answerHello(Socket socket,Map meta) async{
    if(_server==null||deviceId==null)return;
    final sender=_parseHelloPeer(meta,socket.remoteAddress.address);
    if(sender==null)return;
    final generation=_listenerGeneration;
    final local=await _localHelloInterfaceFor(sender.address);
    if(local==null||generation!=_listenerGeneration||_disposed||_server==null){
      if(testSupportDirectory!=null)debugPrint('LAN hello rejected: no local interface for ${sender.address}');
      return;
    }
    // Only directly checked peers are shared; each recipient must verify the
    // advertised identity itself before adding the hinted device to its list.
    final hints=_windowsSources.verified(DateTime.now()).where((p)=>
      p.id!=sender.id&&_sameLocalSubnet(p.address,local)).take(12)
      .map((p)=>{'id':p.id,'name':p.name,'address':p.address,'port':p.port}).toList();
    socket.add(utf8.encode(jsonEncode({'protocol':_helloProtocol,
      ..._helloIdentity(),'peers':hints})+'\n'));
    await socket.flush().timeout(const Duration(seconds:2));
    if(generation==_listenerGeneration&&!_disposed)_offerHello(sender);
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
    if(!started||_stopping!=null||queuedBatches.isEmpty||peers.isEmpty)return;
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
    var control=false;
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
          if(meta is Map && meta['protocol']==_helloProtocol){
            control=true;
            await _answerHello(socket,meta);
            await Future<void>.delayed(const Duration(milliseconds:100));
            return;
          }
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
      if(!control)error = 'Receive failed: $e';
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
      try{await reader.cancel();}catch(_){}
      socket.destroy();
      if(!control)_update(save: true);
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

  Future<void> stop() => _stopping ??= _stopOnce().whenComplete(()=>_stopping=null);

  Future<void> _stopOnce() async {
    final starting=_starting;
    if(starting!=null){try{await starting;}catch(_){}}
    started=false;
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
    final discovery = _windowsDiscovery;
    _windowsDiscovery = null;
    if (discovery != null) {
      try { await nsd.stopDiscovery(discovery); } catch (_) {}
    }
    final registration = _windowsRegistration;
    _windowsRegistration = null;
    if (registration != null) {
      try { await nsd.unregister(registration); } catch (_) {}
    }
    _windowsBrowseStartedAt=null;
    _windowsSources.clear();
    _helloCandidates.clear();
    _helloAttempts.clear();
    _helloActive.clear();
    _lastNativeRefresh=null;
    _nativeRestartNeeded=false;
    peers.clear();
    final server=_server;
    _server=null;
    await server?.close();
    _discovery=null;
    // The receiver persists its final history after the ACK grace period.
    // Closing ServerSocket alone does not close accepted sockets or join
    // those tasks. Wait for their cleanup before the final history flush,
    // especially on Windows where an open file prevents directory removal.
    final active=Map<Socket,Future<void>>.of(_incomingConnections);
    for(final connection in active.keys){connection.destroy();}
    await Future.wait(active.values);
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
