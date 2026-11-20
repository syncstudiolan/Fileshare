import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/transfer_route.dart';

void main() {
  test('1+ LAN devices ALWAYS wins, even for a logged-in cloud account', () {
    for (final count in [1, 2, 3, 10]) {
      expect(chooseTransferRoute(nearbyCount: count, cloudSignedIn: true),
          TransferRoute.lan);
      expect(chooseTransferRoute(nearbyCount: count, cloudSignedIn: false),
          TransferRoute.lan);
    }
  });
  test('Cloud is permitted only after zero nearby devices and login', () {
    expect(chooseTransferRoute(nearbyCount: 0, cloudSignedIn: true),
        TransferRoute.cloud);
    expect(chooseTransferRoute(nearbyCount: 0, cloudSignedIn: false),
        TransferRoute.pending);
  });
  test('Auto Cloud OFF always uses LAN or LAN Pending, even when logged in',(){
    for(final peers in [1,2,3,10]){
      expect(chooseTransferRoute(nearbyCount:peers,cloudSignedIn:true,
        autoCloudEnabled:false),TransferRoute.lan);
    }
    expect(chooseTransferRoute(nearbyCount:0,cloudSignedIn:true,
      autoCloudEnabled:false),TransferRoute.pending);
    expect(chooseTransferRoute(nearbyCount:0,cloudSignedIn:false,
      autoCloudEnabled:false),TransferRoute.pending);
  });

  test('Default ON permits remote cloud only for signed-in zero-peer case',(){
    expect(chooseTransferRoute(nearbyCount:0,cloudSignedIn:true),
      TransferRoute.cloud);
    expect(chooseTransferRoute(nearbyCount:0,cloudSignedIn:false),
      TransferRoute.pending);
    expect(chooseTransferRoute(nearbyCount:2,cloudSignedIn:true),
      TransferRoute.lan);
  });

  test('Never interpret a negative or unknown peer count as zero', () {
    expect(() => chooseTransferRoute(nearbyCount: -1, cloudSignedIn: true),
        throwsArgumentError);
  });
}
