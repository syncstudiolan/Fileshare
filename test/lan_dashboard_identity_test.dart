import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/lan_engine.dart';
LanFile row(String id,String batch,String path,TransferState state,{bool incoming=false,String peer='peer'}) =>
  LanFile(id:id,batch:batch,name:'hi.txt',path:path,peer:peer,peerId:peer,
    incoming:incoming,size:2,created:DateTime(2026),state:state,
    done:state==TransferState.delivered?2:0);
void main(){
  test('one sent snapshot, multiple peer receipts, one dashboard row',(){
    final rows=[row('item','batch','snapshot',TransferState.queued),
      row('item_A','batch','snapshot',TransferState.delivered),
      row('item_B','batch','snapshot',TransferState.delivered)];
    final cards=LanEngine.collapseDashboardFiles(rows);
    expect(cards.length,1);
    expect(cards.single.id,'item');
    expect(cards.single.state,TransferState.delivered);
    expect(rows.length,3);
  });
  test('partial failure does not claim full delivery',(){
    final cards=LanEngine.collapseDashboardFiles([
      row('a','batch','snapshot',TransferState.delivered),
      row('b','batch','snapshot',TransferState.failed)]);
    expect(cards.single.state,TransferState.failed);
  });
  test('intentional repeat and different group files remain distinct',(){
    final cards=LanEngine.collapseDashboardFiles([
      row('a','first','snapshot',TransferState.delivered),
      row('b','second','snapshot',TransferState.delivered),
      row('c','second','another',TransferState.delivered),
      row('d','second','incoming',TransferState.delivered,incoming:true)]);
    expect(cards.length,4);
  });
}
