import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
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

enum TransferState { preparing, sending, receiving, delivered, failed }

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

class LanEngine extends ChangeNotifier {
  LanEngine({this.discoveryPort = 49310, this.tcpPort = 49311,
    this.expiry = const Duration(hours: 24)});
  final int discoveryPort, tcpPort;
  final Duration expiry;
  final List<LanFile> files = [];
  final Map<String, LanPeer> peers = {};
  ServerSocket? _server;
  RawDatagramSocket? _discovery;
  Timer? _heartbeat, _cleanup;
  Directory? _inbox;
  File? _db;
  String? deviceId, error;
  bool started = false, _disposed = false;
  Future<void> _writes = Future<void>.value();

  static String newId() => base64Url.encode(
    List<int>.generate(16, (_) => Random.secure().nextInt(256))).replaceAll('=', '');

  static String safeFileName(String input) {
    final clean = input.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_').trim();
    if (clean.isEmpty || clean == '.' || clean == '..') return 'file';
    return clean.length > 180 ? clean.substring(clean.length - 180) : clean;
  }

  void _notify() { if (!_disposed) notifyListeners(); }

  Future<void> start() async {
    if (started) return;
    final dir = await getApplicationSupportDirectory();
    _inbox = Directory(dir.path + Platform.pathSeparator + 'fileshare_inbox');
    await _inbox!.create(recursive: true);
    _db = File(_inbox!.path + Platform.pathSeparator + 'history.json');
    final preferences = SharedPreferencesAsync();
    deviceId = await preferences.getString('lan_device_id') ?? newId();
    await preferences.setString('lan_device_id', deviceId!);
    await _restore();
    await cleanExpired();
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, tcpPort);
      _server!.listen((connection) { unawaited(_accept(connection)); });
    } catch (e) { error = 'Unable to listen for LAN files: ' + e.toString(); }
    try {
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
      });
    } catch (e) { error = 'LAN broadcast unavailable: ' + e.toString(); }
    _cleanup = Timer.periodic(const Duration(minutes: 1),
      (_) { unawaited(cleanExpired()); });
    started = true;
    _notify();
  }

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
      peers[id] = LanPeer(id, safeFileName((obj['name'] as String?) ?? 'Device'),
        packet.address.address, obj['port'] as int, DateTime.now());
      _notify();
    } catch (_) {}
  }

  void _expirePeers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 22));
    peers.removeWhere((key, peer) => peer.lastSeen.isBefore(cutoff));
    _notify();
  }

  Future<void> _restore() async {
    if (_db == null || !await _db!.exists()) return;
    try {
      final obj = jsonDecode(await _db!.readAsString());
      if (obj is List) {
        for (final raw in obj) {
          final file = LanFile.fromJson(raw);
          if (file == null) continue;
          if (file.state != TransferState.delivered) {
            file.state = TransferState.failed; // interrupted, not delivered
          }
          files.add(file);
        }
      }
    } catch (e) { error = 'Local history read failed: ' + e.toString(); }
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
      await socket.close(); // half-close write side; continue reading ACK
      final ok = await accepted.future.timeout(const Duration(seconds: 45));
      if (!ok) throw const SocketException('Receiver did not acknowledge file');
      record.state = TransferState.delivered;
      record.done = record.size;
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
    try {
      final header = <int>[];
      var ready = false, got = 0, expected = -1;
      Future<void> store(List<int> bytes) async {
        if (bytes.isEmpty) return;
        if (got + bytes.length > expected) {
          throw const FormatException('More bytes than declared');
        }
        out!.add(bytes);
        got += bytes.length;
        record!.done = got;
        if (got == expected || got % (1024 * 1024) < bytes.length) {
          await out!.flush();
          _notify();
        }
      }

      await for (final chunk in socket) {
        if (ready) {
          await store(chunk);
          continue;
        }
        final newline = chunk.indexOf(10);
        if (newline == -1) {
          header.addAll(chunk);
          if (header.length > 8192) throw const FormatException('Long header');
          continue;
        }
        header.addAll(chunk.sublist(0, newline));
        if (header.length > 8192) throw const FormatException('Long header');
        final meta = jsonDecode(utf8.decode(header));
        if (meta is! Map || meta['protocol'] != 'fileshare-file-v1' ||
            meta['size'] is! int || (meta['size'] as int) < 0 ||
            meta['name'] is! String) {
          throw const FormatException('Invalid transfer');
        }
        expected = meta['size'] as int;
        final id = newId();
        final name = safeFileName(meta['name'] as String);
        final destination = _inbox!.path + Platform.pathSeparator + id + '_' + name;
        part = File(destination + '.part');
        out = part.openWrite();
        record = LanFile(
          id: id, batch: safeFileName((meta['batch'] as String?) ?? id),
          name: name, path: destination,
          peer: safeFileName((meta['sender'] as String?) ?? socket.remoteAddress.address),
          peerId: (meta['senderId'] as String?) ?? '',
          incoming: true, size: expected, created: DateTime.now(),
          state: TransferState.receiving);
        files.insert(0, record!);
        _update(save: true);
        ready = true;
        await store(chunk.sublist(newline + 1));
      }

      if (!ready || got != expected) {
        throw const SocketException('Incoming file incomplete');
      }
      await out!.flush();
      await out.close();
      out = null;
      await part!.rename(record!.path);
      record.state = TransferState.delivered;
      socket.write('OK\n');
      await socket.flush();
    } catch (e) {
      if (record != null) {
        record.state = TransferState.failed;
        record.error = e.toString();
      }
      error = 'Receive failed: ' + e.toString();
      try { socket.write('ERR\n'); await socket.flush(); } catch (_) {}
    } finally {
      try { await out?.close(); } catch (_) {}
      if (record?.state != TransferState.delivered) {
        try { if (part != null && await part.exists()) await part.delete(); }
        catch (_) {}
      }
      socket.destroy();
      _update(save: true);
    }
  }

  Future<void> remove(String id) async {
    final hits = files.where((entry) => entry.id == id).toList();
    if (hits.isEmpty) return;
    final item = hits.first;
    // Received data is managed by the app. An outgoing original is USER DATA.
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
    _heartbeat?.cancel();
    _cleanup?.cancel();
    _discovery?.close();
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
