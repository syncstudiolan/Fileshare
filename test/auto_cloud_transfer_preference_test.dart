import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:file_share/auto_cloud_transfer_preference.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Auto Cloud defaults ON and persists manual OFF separately from QR',()async{
    SharedPreferencesAsyncPlatform.instance=InMemorySharedPreferencesAsync.empty();
    final setting=AutoCloudTransferPreference.instance;
    await setting.load();
    expect(setting.enabled,isTrue);

    await setting.setEnabled(false);
    expect(setting.enabled,isFalse);
    expect(await SharedPreferencesAsync().getBool(
      AutoCloudTransferPreference.storageKey),isFalse);

    // Re-load as the app does after a restart.
    await setting.load();
    expect(setting.enabled,isFalse);
    await setting.setEnabled(true);
    expect(setting.enabled,isTrue);
  });
}
