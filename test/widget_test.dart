import 'dart:io';

import 'package:file_share/main.dart';
import 'package:file_share/lan_engine.dart';
import 'package:file_share/account_directory.dart';
import 'package:file_share/personal_cloud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance=InMemorySharedPreferencesAsync.empty();
  });
  test('Real TCP LAN transfer delivers bytes and receives exactly one event',
      () async {
    final root = await Directory.systemTemp.createTemp('file_share_tcp_test_');
    final senderDir = Directory(root.path + Platform.pathSeparator + 'sender');
    final receiverDir = Directory(root.path + Platform.pathSeparator + 'receiver');
    await senderDir.create();
    await receiverDir.create();
    const port = 51248;
    final receiver = LanEngine(
      tcpPort: port, discoveryPort: 51249,
      testSupportDirectory: receiverDir, testDeviceId: 'receiver-1');
    final sender = LanEngine(
      tcpPort: 51250, discoveryPort: 51251,
      testSupportDirectory: senderDir, testDeviceId: 'sender-1');
    var notices = 0;
    receiver.onReceived = (file) async {
      expect(file.incoming, isTrue);
      expect(file.state, TransferState.delivered);
      notices++;
    };
    try {
      await receiver.start();
      await sender.start();
      final source = File(root.path + Platform.pathSeparator + 'hello.txt');
      const message = 'actual socket transfer without UI';
      await source.writeAsString(message);
      // No visible peer -> Send still enters the durable Pending Queue.
      await sender.enqueue([source], names: ['hello.txt']);
      expect(sender.queuedBatches.length, 1);
      expect(receiver.files, isEmpty);
      // Discovery later: the engine auto-delivers the pending batch.
      sender.peers['receiver-1'] =
          LanPeer('receiver-1', 'Android receiver', '127.0.0.1', port, DateTime.now());
      for (var i = 0; i < 40 && receiver.files.where((f) =>
          f.state == TransferState.delivered).isEmpty; i++) {
        sender.refresh();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      final incoming = receiver.files.where((f) =>
          f.state == TransferState.delivered).toList();
      expect(incoming, hasLength(1));
      expect(await File(incoming.single.path).readAsString(), message);
      // Delivery is persisted before the ACK; the UI notification callback
      // is deliberately asynchronous and may follow the persisted file.
      for (var i = 0; i < 40 && notices == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(notices, 1);
    } finally {
      await sender.stop();
      await receiver.stop();
      await root.delete(recursive: true);
    }
  });

  test('Busy LAN listener does not create a second socket and can retry',
      () async {
    final temporary=await Directory.systemTemp.createTemp('fileshare_socket_');
    final occupied=await ServerSocket.bind(InternetAddress.anyIPv4,0);
    final engine=LanEngine(
      tcpPort:occupied.port,discoveryPort:51587,
      testSupportDirectory:temporary,testDeviceId:'retry-test');
    try {
      await engine.start();
      expect(engine.receivingEnabled,isFalse);
      await occupied.close();
      await engine.retryReceiver();
      expect(engine.receivingEnabled,isTrue);
      await engine.retryReceiver(); // Already bound: no duplicate listener.
      expect(engine.receivingEnabled,isTrue);
    }finally{
      await engine.stop();
      await temporary.delete(recursive:true);
    }
  });

  Future<void> noop(LanFile _) async {}

  Future<void> noopCloud(CloudFile _) async {}

  testWidgets('Guest QR card shows filename once and four real actions',
      (tester) async {
    final file=CloudFile(id:'demo-cloud-1',session:'guest-test',
      name:'received-document.pdf',size:210000,
      created:DateTime.utc(2026,11,17,10,15));
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      body:ListView(children:[
        CloudInboxCard(items:[file],onSave:noopCloud,onDelete:noopCloud,
          onShare:noopCloud,onPreview:noopCloud,onTools:noopCloud),
      ]),
    )));
    expect(find.text('received-document.pdf'),findsOneWidget);
    expect(find.byTooltip('Download received QR file'),findsOneWidget);
    expect(find.byTooltip('Delete QR file'),findsOneWidget);
    expect(find.byTooltip('Share QR file externally'),findsOneWidget);
    expect(find.byTooltip('Open in Tools'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });

  testWidgets('Received card has one filename and exactly four actions',
      (tester) async {
    final file=LanFile(id:'in',batch:'test',name:'receipt.pdf',
      path:'/missing/receipt.pdf',peer:'Office PC',incoming:true,size:1024,
      created:DateTime.utc(2026,11,17),state:TransferState.delivered);
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      body:ListView(children:[
        LiveTransferCard(items:[file],onSave:noop,onDelete:noop,
          onShare:noop,onTools:noop),
      ]),
    )));
    expect(find.text('receipt.pdf'),findsOneWidget);
    expect(find.byTooltip('Download'),findsOneWidget);
    expect(find.byTooltip('Delete'),findsOneWidget);
    expect(find.byTooltip('Share'),findsOneWidget);
    expect(find.byTooltip('Open in Tools'),findsOneWidget);
    expect(find.byTooltip('Open in another app'),findsNothing);
    expect(tester.takeException(),isNull);
  });

  testWidgets('Sent card has one filename and no Download action',
      (tester) async {
    final file=LanFile(id:'out',batch:'test',name:'photo.jpg',
      path:'/missing/photo.jpg',peer:'Other Phone',incoming:false,size:170000,
      created:DateTime.utc(2026,11,17),state:TransferState.queued);
    await tester.pumpWidget(MaterialApp(home:Scaffold(
      body:ListView(children:[
        LiveTransferCard(items:[file],onSave:noop,onDelete:noop,
          onShare:noop,onTools:noop),
      ]),
    )));
    expect(find.text('photo.jpg'),findsOneWidget);
    expect(find.byTooltip('Download'),findsNothing);
    expect(find.byTooltip('Delete'),findsOneWidget);
    expect(find.byTooltip('Share'),findsOneWidget);
    expect(find.byTooltip('Open in Tools'),findsOneWidget);
    expect(find.byTooltip('Open in another app'),findsNothing);
    expect(tester.takeException(),isNull);
  });

  testWidgets('Compact LAN sent card only shows double tick after ACK delivery',
      (tester) async {
    Future<void> noOp(LanFile _) async {}
    final file=LanFile(id:'sent1',batch:'batch1',name:'image.jpg',
      path:'/missing/image.jpg',peer:'Office Desktop',
      incoming:false,size:2048,created:DateTime.utc(2026,11,18),
      state:TransferState.queued);
    Widget card()=>MaterialApp(home:Scaffold(body:ListView(children:[
      LiveTransferCard(items:[file],onSave:noOp,onDelete:noOp,
        onShare:noOp,onTools:noOp),
    ])));
    await tester.pumpWidget(card());
    expect(find.text('image.jpg'),findsOneWidget);
    expect(find.text('To Office Desktop · Offline LAN'),findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded),findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded),findsNothing);
    file.state=TransferState.delivered;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(card());
    expect(find.byIcon(Icons.done_all_rounded),findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded),findsNothing);
    expect(tester.takeException(),isNull);
  });

  testWidgets('Compact Guest QR transfer displays source once',
      (tester) async {
    final f=CloudFile(id:'qr1',session:'qr-group',
      name:'passport.pdf',size:20000,
      created:DateTime.utc(2026,11,18,10,0));
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:ListView(children:[
      CloudInboxCard(items:[f],onSave:noopCloud,onDelete:noopCloud,
        onShare:noopCloud,onPreview:noopCloud,onTools:noopCloud),
    ]))));
    expect(find.text('passport.pdf'),findsOneWidget);
    expect(find.text('From Guest browser · Guest QR · Online'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });

  test('Official directory is configured for both Flutter targets', () {
    // Both Android and Windows import the same AccountDirectory singleton.
    expect(AccountDirectory.instance.enabled, isTrue);
    expect(AccountDirectory.validateDirectoryUrl(
      'https://fileshare-directory.modeltech0.workers.dev'),
      'https://fileshare-directory.modeltech0.workers.dev');
    expect(
      () => AccountDirectory.validateDirectoryUrl('http://127.0.0.1:8787'),
      throwsFormatException);
  });

  test('LAN file names cannot contain path separators', () {
    expect(LanEngine.safeFileName('../unsafe\\name.png'),
        '.._unsafe_name.png');
  });

  test('LAN transfer records round-trip without losing progress', () {
    final entry = LanFile(
      id: 'id', batch: 'batch', name: 'test.jpg', path: '/temp/test.jpg',
      peer: 'Laptop', incoming: true, size: 1024, done: 512,
      created: DateTime.utc(2026, 11, 16), state: TransferState.receiving);
    final decoded = LanFile.fromJson(entry.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.progress, 0.5);
    expect(decoded.incoming, isTrue);
    expect(decoded.batch, 'batch');
  });

  test('Queued batch persists the intended files and acknowledged peers', () {
    final batch = QueuedLanBatch('batch-1', DateTime.utc(2026, 11, 16), [
      QueuedLanItem('file-1','picture.jpg','/private/picture.jpg',4096)
    ], {'android-A:file-1'});
    final restored = QueuedLanBatch.fromJson(batch.toJson());
    expect(restored, isNotNull);
    expect(restored!.items.single.name, 'picture.jpg');
    expect(restored.deliveredKeys.contains('android-A:file-1'), isTrue);
    expect(restored.deliveredKeys.contains('android-B:file-1'), isFalse);
  });

  testWidgets('Drawer has the new offline menu and no History or Tools',
      (tester) async {
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.light,
      offlineDefault: true,
      enableBackends: false,
    ));
    await tester.tap(find.byTooltip('Open navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
    expect(find.text('History'), findsNothing);
    expect(find.text('Tools'), findsNothing);
  });

  testWidgets('Account creation and personal Cloudflare setup are reachable',
      (tester) async {
    await tester.pumpWidget(const FileShareApp(initialMode: ThemeMode.light));
    await tester.tap(find.text('Login / Create Account'));
    await tester.pumpAndSettle();
    expect(find.text('File Share Account'), findsOneWidget);
    await tester.tap(find.text('New here? Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Create your account'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    final cloudSetup = find.text('Set up or connect personal Cloudflare');
    await tester.ensureVisible(cloudSetup);
    await tester.pumpAndSettle();
    await tester.tap(cloudSetup);
    await tester.pumpAndSettle();
    expect(find.text('One-time Cloudflare Auto Setup'), findsOneWidget);
    expect(find.text('Verify & Auto Connect'), findsOneWidget);
    // No credentials, network calls, setup operations or deployments from tests.
  });

  testWidgets('Windows wide view has a persistent collapsible sidebar',
      (tester) async {
    if (!Platform.isWindows) return;
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.light, offlineDefault: true,
      enableBackends: false,
    ));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide sidebar'), findsWidgets);
    expect(find.text('Devices'), findsWidgets);
    await tester.tap(find.byTooltip('Hide sidebar').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show sidebar'), findsOneWidget);
    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide sidebar'), findsWidgets);
  });

  testWidgets('First use offers login and no-login offline LAN', (tester) async {
    await tester.pumpWidget(const FileShareApp(initialMode: ThemeMode.light));
    expect(find.text('Login / Create Account'), findsOneWidget);
    expect(find.text('Skip to Offline LAN'), findsOneWidget);
  });

  testWidgets('Theme menu supports light, dark and system', (tester) async {
    await tester.pumpWidget(const FileShareApp(initialMode: ThemeMode.light));
    await tester.tap(find.byTooltip('Choose light or dark appearance'));
    await tester.pumpAndSettle();
    expect(find.text('Light mode'), findsOneWidget);
    expect(find.text('Dark mode'), findsOneWidget);
    expect(find.text('Follow system'), findsOneWidget);
  });

  testWidgets('Unified timeline shows LAN and Guest QR sample cards',
      (tester) async {
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.dark,
      offlineDefault: true,
      enableBackends: false,
    ));
    expect(find.text('File Transfer'), findsOneWidget);
    expect(find.text('4 Photos (Group)'), findsOneWidget);
    expect(find.text('SAMPLE DATA'), findsOneWidget);
    expect(find.text('Example cards only — no real files'), findsOneWidget);
    expect(find.byTooltip('Refresh nearby LAN devices'),
        findsOneWidget);
  });

  testWidgets('Sent cards have no download action', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DesignFileCard(
          transfer: MockTransfer('sample.png', 'To Windows PC · Offline LAN',
              '1 MB', '12:00 PM', sent: true),
        ),
      ),
    ));
    expect(find.byTooltip('Download · not enabled'), findsNothing);
    expect(find.byTooltip('Delete · not enabled'), findsOneWidget);
    expect(find.byTooltip('Share externally · not enabled'), findsOneWidget);
  });

  testWidgets('Received cards have download but still no live actions',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DesignFileCard(
          transfer: MockTransfer('sample.png', 'From Android B · Offline LAN',
              '1 MB', '12:00 PM'),
        ),
      ),
    ));
    expect(find.byTooltip('Download · not enabled'), findsOneWidget);
    expect(find.byTooltip('Delete · not enabled'), findsOneWidget);
  });

  testWidgets('QR screen requires connection and never invents a real QR',
      (tester) async {
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.light,
      offlineDefault: true,
      enableBackends: false,
    ));
    await tester.tap(find.byTooltip('QR design preview'));
    await tester.pumpAndSettle();
    expect(find.text('My Permanent QR'), findsOneWidget);
    expect(find.text('No active QR yet'), findsOneWidget);
    expect(find.text('Connect Personal Cloud'), findsOneWidget);
  });

  testWidgets('Narrow mobile dashboard renders first group card',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const FileShareApp(
      initialMode: ThemeMode.light, offlineDefault: true,
      enableBackends: false,
    ));
    await tester.pumpAndSettle();
    expect(find.text('4 Photos (Group)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

