import 'package:file_share/main.dart';
import 'package:file_share/personal_cloud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main(){
  Future<void> noop(CloudFile _) async {}

  Widget card(CloudFile file)=>MaterialApp(home:Scaffold(
    body:ListView(children:[CloudInboxCard(
      items:[file],onSave:noop,onDelete:noop,onShare:noop,
      onPreview:noop,onTools:noop)])));

  testWidgets('Online cloud card starts single tick and becomes double after receipt',
      (tester)async{
    appLan.deviceId='senderDevice12345';
    final first=CloudFile(id:'cloud-one',session:'device_cloud-one',
      name:'report.pdf',size:4567,deviceTransfer:true,
      senderId:'senderDevice12345',senderName:'Windows PC',
      created:DateTime.now());
    await tester.pumpWidget(card(first));
    expect(find.text('Sent · Online / Cloud'),findsOneWidget);
    expect(find.byIcon(Icons.done_rounded),findsOneWidget);
    expect(find.byTooltip('Download received cloud file'),findsNothing);
    final received=CloudFile(id:'cloud-one',session:'device_cloud-one',
      name:'report.pdf',size:4567,deviceTransfer:true,
      senderId:'senderDevice12345',senderName:'Windows PC',
      created:first.created,receivedAt:DateTime.now());
    await tester.pumpWidget(card(received));
    await tester.pump();
    expect(find.byIcon(Icons.done_all_rounded),findsOneWidget);
  });
}
