#!/usr/bin/env python3
"""Patch a generated macOS Flutter runner for File Share's silent login launch.

Run after 'flutter create --platforms=macos --project-name file_share .'
and before building a signed macOS .app. Does not run Flutter or release.
"""
from __future__ import annotations
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
WINDOW = ROOT / "macos/Runner/MainFlutterWindow.swift"
DELEGATE = ROOT / "macos/Runner/AppDelegate.swift"
ICONSET = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
SOURCE = ROOT / "assets/branding/file_share_icon.webp"

def patch_window() -> None:
    if not WINDOW.is_file():
        raise SystemExit("Generate the macOS Flutter runner before patching")
    text = WINDOW.read_text(encoding="utf-8")
    marker = "class MainFlutterWindow: NSWindow {"
    if marker not in text:
        raise SystemExit("Unexpected MainFlutterWindow.swift structure")
    if "fileShareSuppressInitialLoginShow" not in text:
        # Intercept only the first native orderFront on --background.
        # Later 'View' from the menu bar must be allowed to show the window.
        code = """
  private var fileShareSuppressInitialLoginShow =
      ProcessInfo.processInfo.arguments.contains("--background")

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    if fileShareSuppressInitialLoginShow && place != .out {
      fileShareSuppressInitialLoginShow = false
      super.order(.out, relativeTo: otherWin)
      return
    }
    super.order(place, relativeTo: otherWin)
  }
"""
        text=text.replace(marker,marker+code,1)
    if 'file_share.desktop' not in text:
        registration="RegisterGeneratedPlugins(registry: flutterViewController)"
        if registration not in text:
            raise SystemExit("macOS Flutter plugin registration anchor missing")
        channel = """
    // Preserve the --background login flag for the Dart entrypoint.
    // FlutterViewController's default project need not forward shell args.
    let startupChannel = FlutterMethodChannel(
      name: "file_share.desktop",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    startupChannel.setMethodCallHandler { call, result in
      if call.method == "isBackgroundLaunch" {
        result(ProcessInfo.processInfo.arguments.contains("--background"))
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
"""
        text=text.replace(registration,registration+channel,1)
    WINDOW.write_text(text,encoding="utf-8")

def patch_delegate() -> None:
    if not DELEGATE.is_file():
        raise SystemExit("Generated macOS AppDelegate.swift is missing")
    text=DELEGATE.read_text(encoding="utf-8")
    if "applicationShouldTerminateAfterLastWindowClosed" in text:
        # Flutter's generated AppDelegate normally contains exactly this
        # return; a macOS tray app must not quit on its final window close.
        if "return true" in text:
            text=text.replace("return true","return false",1)
    else:
        marker="class AppDelegate: FlutterAppDelegate {"
        if marker not in text:
            raise SystemExit("Unexpected generated AppDelegate.swift structure")
        text=text.replace(marker,marker+"""
  override func applicationShouldTerminateAfterLastWindowClosed(
      _ sender: NSApplication) -> Bool {
    return false
  }
""",1)
    if "applicationShouldHandleReopen" not in text:
        marker="class AppDelegate: FlutterAppDelegate {"
        if marker not in text:
            raise SystemExit("macOS AppDelegate open/activate anchor missing")
        text=text.replace(marker,marker+"""
  // Clicking the installed app in Finder or Dock should reopen a hidden
  // menu-bar window instead of doing nothing when the process is running.
  override func applicationShouldHandleReopen(
      _ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      if let window = sender.windows.first(where: { $0 is MainFlutterWindow }) {
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
      }
    }
    return true
  }
""",1)
    DELEGATE.write_text(text,encoding="utf-8")

def brand_icons() -> None:
    contents=ICONSET/"Contents.json"
    if not contents.is_file() or not SOURCE.is_file():
        raise SystemExit("Generated macOS AppIcon or File Share brand asset missing")
    spec=json.loads(contents.read_text(encoding="utf-8"))
    with Image.open(SOURCE) as original:
        base=original.convert("RGBA")
        for entry in spec.get("images",[]):
            filename=entry.get("filename")
            size=entry.get("size","")
            scale=entry.get("scale","1x")
            if not filename or not size:
                continue
            px=int(float(size.split("x")[0])*int(scale[:-1]))
            if px<16 or px>1024:
                raise SystemExit(f"Unexpected macOS icon size {px}")
            base.resize((px,px),Image.Resampling.LANCZOS).save(
                ICONSET/filename,format="PNG")
    print("File Share branded macOS Dock and launcher icons ready")

def main() -> None:
    patch_window()
    patch_delegate()
    brand_icons()
    print("macOS menu-bar login, close-to-tray and native hidden launch patched.")

if __name__=="__main__":
    main()
