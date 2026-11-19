# File Share — Profile, Cloud Status and Background Receiving

Branch: `draft/live-scanner-smooth-editor-tools`, existing Draft PR #6.

## Implemented code changes

### Profile: correct account and connection
- The Profile screen no longer has hardcoded `Not signed in` or `Not connected` strings.
- It observes `PersonalCloud.instance` and shows the authenticated email when the cached session is valid.
- Worker connection is represented by `PersonalCloud.connected`. A saved Worker configuration without a valid login displays **Cloud setup saved · Sign in to connect**, not a false positive.
- The Settings and earlier Cloud Setup status indicators also now read the actual connection state.
- The encrypted personal-cloud session is restored before Flutter renders the initial route. An existing valid session opens the dashboard rather than showing the new-user onboarding screen.
- Optional local-only avatar picker/change/remove; uses installed `image_picker`, secure app support directory and preferences, with no photo uploaded to any cloud.

### Windows: launch receiver in the system tray on sign-in
- Existing tray manager and single-instance LAN receiver are retained.
- One-time `HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run` registration installs an entry for the installed executable with `--background`. No admin privileges or separate startup service are required.
- The startup path is ignored for Flutter tester, temporary or Debug binaries, and later manual opt-out via the existing **Start with Windows** switch is preserved in preferences.
- `--background` does not maximize the window; the tray is initialized before the background launch; a second startup invocation does not open the existing process's dashboard.
- The LAN receive engine is now started automatically on Windows even when Offline Mode was not the last selected UI mode.
- The already implemented file-received toast still triggers through `WindowsBackground.notifyReceived`.
- The personal cloud's existing event-triggered WebSocket inbox remains active while the Windows UI is minimized to the tray.
- **Windows startup occurs after the user signs in to Windows**, because desktop system-tray icons require a signed-in desktop session, not before login.

### Android: persistent foreground LAN receiver and reboot recovery
- Existing `LanKeepAliveService` has `START_STICKY`, a connectedDevice foreground notification and an application-level retained Flutter engine. Its Android notification method is kept.
- Added `FileShareBootReceiver` with `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED` intent filters plus `RECEIVE_BOOT_COMPLETED` permission.
- The background service's restart preference is saved in native app SharedPreferences. **Settings → Android Background Receiver** has a working opt-out/on switch synchronized to Dart startup preferences.
- The foreground notification is posted before expensive FlutterEngine startup, and FlutterEngine initialization is lazy (MainActivity/foreground service only) to avoid starting the engine for disabled boot receivers.
- The Dart LAN listener starts when background receiving is enabled, even if the app uses the normal login/onboarding screen.
- Foreground LAN transfers can still run while the app is open, independently of the boot opt-out.
- **Limitations:** Android's force-stop, reboot permissions, OEM battery management, Wi-Fi availability and foreground-service launch restrictions take priority. There is no technically valid promise that a consumer Android app can run 100% of the time after force-stop or every OEM reboot.

## Verification pending (not executed)

- Flutter toolchain `flutter pub get`, `flutter analyze`, `flutter test`.
- Android Kotlin compilation and boot-receiver integration on API levels 26–36.
- Windows installed EXE sign-in/startup test, registry opt-out, duplicate process behavior and tray hidden-window test.
- Confirm profile-email and Worker status after first login, restart, expiry, logout and internet disconnection.
- Change/remove local avatar on Android and Windows.
- Receive a LAN file while the app is closed on Android and the window is hidden on Windows.
- Verify boot behavior with Android battery restrictions, disabled receiver preference, package replacement and restored connectivity.

**No APK/EXE build, workflow dispatch, merge, deployment or release was performed.**
