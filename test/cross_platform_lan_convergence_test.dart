import 'dart:async';
import 'dart:io';

import 'package:file_share/lan_engine.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> until(bool Function() done, Duration timeout,
    {required String Function() diagnostics}) async {
  final deadline=DateTime.now().add(timeout);
  while(!done()){
    if(DateTime.now().isAfter(deadline))throw StateError('LAN condition timed out: ${diagnostics()}');
    await Future<void>.delayed(const Duration(milliseconds:100));
  }
}

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();

  test('four asymmetric discovery engines converge and deliver all 12 directions', () async {
    final root=await Directory.systemTemp.createTemp('fileshare-four-peer-');
    final engines=<LanEngine>[];
    const ids=['iphone','mac','android','windows'];
    try{
      for(final id in ids){
        final directory=await Directory('${root.path}/$id').create();
        final engine=LanEngine(tcpPort:0,testSupportDirectory:directory,testDeviceId:id);
        engines.add(engine);
        await engine.start();
      }
      // Reproduce the reported asymmetry: initially only the iPhone knows
      // all three peers. No fake peer map insertion or file relaying.
      for(final other in engines.skip(1)){
        engines.first.seedHelloPeerForTest(LanPeer(other.deviceId!,other.deviceId!,
          '127.0.0.1',other.receiverPortForTest!,DateTime.now()));
      }
      await until(()=>engines.every((e)=>e.peers.length==3),const Duration(seconds:35),
        diagnostics:()=>engines.map((e)=>'${e.deviceId}: ${e.peers.keys.join(',')} error=${e.error}').join('; '));
      for(final engine in engines){
        expect(engine.peers.keys.toSet(),ids.where((id)=>id!=engine.deviceId).toSet());
        expect(engine.files,isEmpty,reason:'control traffic cannot create transfer cards');
      }
      final payloads=<String,File>{};
      for(final id in ids){
        payloads[id]=await File('${root.path}/$id.txt').writeAsString('payload from $id');
      }
      await Future.wait(engines.map((e)=>e.send([payloads[e.deviceId]!],e.peers.values)));
      await until(()=>engines.every((e)=>e.files.where((f)=>f.incoming &&
        f.state==TransferState.delivered).length==3),const Duration(seconds:15),
        diagnostics:()=>engines.map((e)=>'${e.deviceId}: ${e.files.map((f)=>f.state.name).join(',')} error=${e.error}').join('; '));
      for(final e in engines){
        final received=e.files.where((f)=>f.incoming).toList();
        expect(received.length,3);
        expect(received.map((f)=>f.peerId).toSet(),ids.where((id)=>id!=e.deviceId).toSet());
        for(final f in received){
          expect(await File(f.path).readAsString(),'payload from ${f.peerId}');
        }
        expect(e.files.where((f)=>!f.incoming && f.state==TransferState.delivered).length,3);
      }
    }finally{
      for(final engine in engines){await engine.stop();}
      await root.delete(recursive:true);
    }
  }, timeout:const Timeout(Duration(seconds:75)));

  test('native loss preserves independent UDP and verified TCP routes',(){
    final sources=WindowsLanPeerSources();
    final now=DateTime.now();
    final peer=LanPeer('mac','Mac','192.168.1.7',49311,now);
    sources.observeNative(peer);
    sources.observeUdp(peer);
    sources.observeVerified(peer);
    sources.loseNative('mac');
    expect(sources.snapshot(now).keys,['mac']);
    expect(sources.snapshot(now.add(const Duration(seconds:25))).keys,['mac']);
    expect(sources.snapshot(now.add(const Duration(seconds:31))),isEmpty);
  });
}
