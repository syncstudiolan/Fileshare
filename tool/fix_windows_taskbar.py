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
    MAIN.write_text(source,encoding="utf-8")

    # The Windows taskbar uses the HWND's small/big icons, not the tray icon
    # nor necessarily the EXE's resource icon. Explicitly attach the exact
    # approved ICO resource to the Flutter window as soon as it is created.
    # Flutter regenerates this C++ runner in CI, so patch after flutter create.
    flutter_window=ROOT/"windows/runner/flutter_window.cpp"
    if not flutter_window.is_file():
        raise SystemExit("Generated FlutterWindow C++ source is missing")
    window_code=flutter_window.read_text(encoding="utf-8")
    if '#include "resource.h"' not in window_code:
        window_code='#include "resource.h"\\n'+window_code
    on_create='bool FlutterWindow::OnCreate() {'
    window_icon_code='''  // File Share branded taskbar and Alt-Tab icons.
  HWND hwnd = GetHandle();
  HINSTANCE module = GetModuleHandle(nullptr);
  HICON small = static_cast<HICON>(LoadImage(
      module, MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON, 16, 16, LR_DEFAULTCOLOR));
  HICON large = static_cast<HICON>(LoadImage(
      module, MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON, 32, 32, LR_DEFAULTCOLOR));
  if (hwnd && small) SendMessage(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small));
  if (hwnd && large) SendMessage(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(large));
'''
    if on_create not in window_code:
        raise SystemExit("Unknown Flutter Windows runner: OnCreate signature changed")
    if 'File Share branded taskbar and Alt-Tab icons.' not in window_code:
        window_code=window_code.replace(on_create,on_create+'\\n'+window_icon_code,1)
    flutter_window.write_text(window_code,encoding="utf-8")
    assert 'WM_SETICON, ICON_SMALL' in window_code
    assert 'WM_SETICON, ICON_BIG' in window_code

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
