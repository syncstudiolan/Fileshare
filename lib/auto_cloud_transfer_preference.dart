import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Controls only outgoing cross-network device uploads.
///
/// Guest QR creation, public QR upload and the owner inbox are intentionally
/// independent of this preference and remain available while it is OFF.
class AutoCloudTransferPreference extends ChangeNotifier {
  AutoCloudTransferPreference._();
  static final instance=AutoCloudTransferPreference._();
  static const storageKey='auto_cloud_transfer_enabled';
  bool _enabled=true; // Safe documented default: automatic cloud fallback ON.
  bool get enabled=>_enabled;

  Future<void> load() async {
    final saved=await SharedPreferencesAsync().getBool(storageKey);
    final value=saved??true;
    if(_enabled!=value){
      _enabled=value;
      notifyListeners();
    }
  }

  Future<void> setEnabled(bool value) async {
    if(_enabled==value)return;
    // Persist first. If storage fails, report the error and keep the previous
    // selection rather than showing a misleading temporary setting.
    await SharedPreferencesAsync().setBool(storageKey,value);
    _enabled=value;
    notifyListeners();
  }
}
