/// The route is chosen once per explicit Send action, after discovery.
/// A single nearby device forbids cloud upload for the entire batch.
enum TransferRoute { lan, cloud, pending }

TransferRoute chooseTransferRoute({
  required int nearbyCount,
  required bool cloudSignedIn,
}) {
  if (nearbyCount < 0) throw ArgumentError.value(nearbyCount, 'nearbyCount');
  if (nearbyCount > 0) return TransferRoute.lan;
  return cloudSignedIn ? TransferRoute.cloud : TransferRoute.pending;
}
