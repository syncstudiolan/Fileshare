#!/usr/bin/env python3
"""Align Windows taskbar process identity with the installed File Share shortcut.

The Flutter Windows runner is generated during GitHub Actions (not committed).
Apply this AFTER flutter create and before flutter build, so the taskbar groups
the window under the branded, pinned File Share shortcut rather than a default
Flutter/runner taskbar entry.
"""
from pathlib import Path

ROOT=Path(__file__).resolve().parent.parent
MAIN=ROOT/"windows/runner/main.cpp"
RC=ROOT/"windows/runner/Runner.rc"
ICO=ROOT/"windows/runner/resources/app_icon.ico"
APP_ID="FileShare.Desktop"

def main()->None:
    if not MAIN.is_file() or not RC.is_file() or not ICO.is_file():
        raise SystemExit("Windows Flutter runner or branded icon missing")
    source=MAIN.read_text(encoding="utf-8")
    if '#include <shobjidl.h>' not in source:
        source='#include <shobjidl.h>\n#pragma comment(lib, "shell32.lib")\n'+source
    marker="int APIENTRY wWinMain("
    pos=source.find(marker)
    if pos<0:
        raise SystemExit("Unknown Flutter Windows runner: missing wWinMain")
    open_brace=source.find("{",pos)
    if open_brace<0:
        raise SystemExit("Malformed Windows main.cpp")
    directive='::SetCurrentProcessExplicitAppUserModelID(L"'+APP_ID+'");'
    if directive not in source:
        source=source[:open_brace+1]+(
            "\n  // Match the Start-menu / desktop shortcut ID for Windows taskbar.\n"
            "  "+directive+"\n"
        )+source[open_brace+1:]
    # Some Flutter Windows runners also explicitly show the outer window.
    # Only a user-initiated launch may show it; login startup remains hidden.
    manual_show='window.Show();'
    silent_show='if (wcsstr(GetCommandLineW(), L"--background") == nullptr) window.Show();'
    if manual_show in source and silent_show not in source:
        source=source.replace(manual_show,silent_show,1)
    if "#include <cwchar>" not in source:
        source="#include <cwchar>"+chr(10)+source
    MAIN.write_text(source,encoding="utf-8")

    # The Windows taskbar uses the HWND's small/big icons, not the tray icon
    # nor necessarily the EXE's resource icon. Explicitly attach the exact
    # approved ICO resource to the Flutter window as soon as it is created.
    # Flutter regenerates this C++ runner in CI, so patch after flutter create.
    flutter_window=ROOT/"windows/runner/flutter_window.cpp"
    if not flutter_window.is_file():
        raise SystemExit("Generated FlutterWindow C++ source is missing")
    window_code=flutter_window.read_text(encoding="utf-8")
    # Flutter's generated OnCreate normally calls Show() on the first frame.
    # The --background startup shortcut must not flash that window.
    old_show='this->Show();'
    conditional_show='if (wcsstr(GetCommandLineW(), L"--background") == nullptr) this->Show();'
    if conditional_show not in window_code:
        if old_show not in window_code:
            raise SystemExit("Unexpected FlutterWindow::OnCreate Show() implementation")
        window_code=window_code.replace(old_show,conditional_show,1)
    if "#include <cwchar>" not in window_code:
        window_code="#include <cwchar>"+chr(10)+window_code

    if '#include "resource.h"' not in window_code:
        window_code='#include "resource.h"\n'+window_code
    on_create='bool FlutterWindow::OnCreate() {'
    window_icon_code='''  // Explicit HWND and Shell icon identity: Windows taskbar/pinned
  // shortcuts can prefer AppUserModel relaunch resources over WM_GETICON.
  HWND hwnd = GetHandle();
  if (hwnd) {
    HINSTANCE module = GetModuleHandleW(nullptr);
    HICON iconSmall = reinterpret_cast<HICON>(LoadImageW(
        module, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, 16, 16,
        LR_DEFAULTCOLOR | LR_SHARED));
    HICON iconLarge = reinterpret_cast<HICON>(LoadImageW(
        module, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, 32, 32,
        LR_DEFAULTCOLOR | LR_SHARED));
    if (iconSmall) SendMessageW(hwnd, WM_SETICON, ICON_SMALL,
                               reinterpret_cast<LPARAM>(iconSmall));
    if (iconLarge) SendMessageW(hwnd, WM_SETICON, ICON_BIG,
                               reinterpret_cast<LPARAM>(iconLarge));

    IPropertyStore* store = nullptr;
    if (SUCCEEDED(SHGetPropertyStoreForWindow(
        hwnd, IID_PPV_ARGS(&store)))) {
      wchar_t exePath[MAX_PATH] = {};
      if (GetModuleFileNameW(nullptr, exePath, MAX_PATH)) {
        std::wstring resource = std::wstring(exePath) + L",-"
                              + std::to_wstring(IDI_APP_ICON);
        PROPVARIANT value{};
        if (SUCCEEDED(InitPropVariantFromString(resource.c_str(), &value))) {
          store->SetValue(PKEY_AppUserModel_RelaunchIconResource, value);
          PropVariantClear(&value);
        }
        const std::wstring command = L"\\\"" + std::wstring(exePath) + L"\\\"";
        if (SUCCEEDED(InitPropVariantFromString(command.c_str(), &value))) {
          store->SetValue(PKEY_AppUserModel_RelaunchCommand, value);
          PropVariantClear(&value);
        }
      }
      // Set window AppID AFTER relaunch properties, matching installer links.
      PROPVARIANT appID{};
      if (SUCCEEDED(InitPropVariantFromString(L"FileShare.Desktop", &appID))) {
        store->SetValue(PKEY_AppUserModel_ID, appID);
        PropVariantClear(&appID);
      }
      store->Release();
    }
  }
'''
    if on_create not in window_code:
        raise SystemExit("Unknown Flutter Windows runner: OnCreate signature changed")
    # Install after Win32Window::OnCreate has created the HWND, not before.
    # The previous patch injected at function entry, so GetHandle() could
    # be null and WM_SETICON silently had no effect on the taskbar.
    base_created='''  if (!Win32Window::OnCreate()) {
    return false;
  }'''
    if base_created not in window_code:
        raise SystemExit("FlutterWindow::OnCreate base HWND setup has changed")
    if 'Explicit HWND and Shell icon identity' not in window_code:
        window_code=window_code.replace(base_created,
            base_created+'\n'+window_icon_code,1)
    for directive in (
        '#include <string>',
        '#include <shellapi.h>',
        '#include <shobjidl.h>',
        '#include <propkey.h>',
        '#include <propvarutil.h>',
        '#pragma comment(lib, "shell32.lib")',
        '#pragma comment(lib, "propsys.lib")',
        '#pragma comment(lib, "ole32.lib")',
    ):
        if directive not in window_code:
            window_code=directive+'\n'+window_code
    flutter_window.write_text(window_code,encoding="utf-8")
    assert 'WM_SETICON, ICON_SMALL' in window_code
    assert 'WM_SETICON, ICON_BIG' in window_code
    assert 'PKEY_AppUserModel_RelaunchIconResource' in window_code
    assert 'PKEY_AppUserModel_ID' in window_code

    resources=RC.read_text(encoding="utf-8")
    if 'IDI_APP_ICON' not in resources or 'app_icon.ico' not in resources:
        raise SystemExit("Windows Runner.rc does not reference the branded app_icon.ico")
    from PIL import Image
    with Image.open(ICO) as icon:
        icon.seek(0)
        if icon.size[0]<16 or icon.size[1]<16:
            raise SystemExit("Taskbar ICO missing usable resolution")
    if ICO.stat().st_size<1000:
        raise SystemExit("Branded Windows taskbar ICO is unexpectedly small")
    print("Verified branded Windows EXE icon and stable taskbar AppUserModelID.")

if __name__=="__main__":
    main()
