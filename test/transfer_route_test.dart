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
  test('Never interpret a negative or unknown peer count as zero', () {
    expect(() => chooseTransferRoute(nearbyCount: -1, cloudSignedIn: true),
        throwsArgumentError);
  });
}
