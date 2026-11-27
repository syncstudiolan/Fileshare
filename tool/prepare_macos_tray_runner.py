#!/usr/bin/env python3
"""Patch a generated macOS Flutter runner for File Share's silent login launch.

Run after 'flutter create --platforms=macos --project-name file_share .'
and before building a signed macOS .app. Does not run Flutter or release.
"""
from __future__ import annotations
import json
import plistlib
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

  func allowFileShareShow() {
    fileShareSuppressInitialLoginShow = false
  }

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
      } else if call.method == "allowShow" {
        self.allowFileShareShow()
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
"""
        text=text.replace(registration,registration+channel,1)
    if "FileShareDownloadFolder.register" not in text:
        registration = "RegisterGeneratedPlugins(registry: flutterViewController)"
        if registration not in text:
            raise SystemExit("Cannot register macOS Finder destination channel")
        text = text.replace(registration, registration + """
    FileShareDownloadFolder.register(
      messenger: flutterViewController.engine.binaryMessenger)""", 1)
    # The macOS project is Flutter-generated in CI. Embedding the source in
    # an existing compiled Swift file avoids fragile Xcode project rewrites.
    bridge = ROOT / "tool/macos/FileShareDownloadFolder.swift"
    if not bridge.is_file():
        raise SystemExit("Native macOS Finder download bridge is missing")
    if "final class FileShareDownloadFolder" not in text:
        source = bridge.read_text(encoding="utf-8")
        source = source.replace("import Cocoa\n", "", 1)
        source = source.replace("import FlutterMacOS\n", "", 1)
        text += "\n\n" + source
    # Generated macOS Runner must register the same Flutter discovery channel
    # as the iOS and Android native bridges; Dart cannot receive Bonjour peers
    # without this step even when Info.plist permissions are present.
    bonjour = ROOT / "tool/macos/FileShareMacLANBonjour.swift"
    if not bonjour.is_file():
        raise SystemExit("Native macOS LAN Bonjour bridge missing")
    if "FileShareMacLANBonjour.register" not in text:
        registration = "RegisterGeneratedPlugins(registry: flutterViewController)"
        if registration not in text:
            raise SystemExit("Cannot register macOS Bonjour channel")
        text = text.replace(registration, registration + """
    FileShareMacLANBonjour.register(
      messenger: flutterViewController.engine.binaryMessenger)""", 1)
    if "final class FileShareMacLANBonjour" not in text:
        source = bonjour.read_text(encoding="utf-8")
        for imported in ("import Cocoa\n", "import FlutterMacOS\n",
                         "import Foundation\n", "import Darwin\n"):
            source = source.replace(imported, "", 1)
        if "import Darwin" not in text:
            text = text.replace("import Cocoa\n",
                                "import Cocoa\nimport Darwin\n", 1)
        text += "\n\n" + source
    # Guard against brittle generated-runner patching. These contracts must
    # appear in the compiled MainFlutterWindow.swift, not just external files.
    if "FileShareMacLANBonjour.register" not in text or (
         "final class FileShareMacLANBonjour" not in text):
        raise SystemExit("macOS LAN channel was not embedded in Flutter runner")
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
      if let window = sender.windows.first(where: { $0 is MainFlutterWindow }) as? MainFlutterWindow {
        window.allowFileShareShow()
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

def patch_local_network_permissions() -> None:
    """Give unsigned Apple Silicon builds the same LAN discovery rights as iOS."""
    info = ROOT / "macos/Runner/Info.plist"
    if not info.is_file():
        raise SystemExit("Generated macOS Info.plist missing")
    with info.open("rb") as handle:
        data = plistlib.load(handle)
    data["NSLocalNetworkUsageDescription"] = (
        "Discover nearby File Share devices and transfer files over local Wi-Fi."
    )
    data["NSBonjourServices"] = ["_fileshare._tcp"]
    data["NSCameraUsageDescription"] = "Capture photos to share."
    data["NSMicrophoneUsageDescription"] = "Capture video to share."
    with info.open("wb") as handle:
        plistlib.dump(data, handle)
    for name in ("Release.entitlements", "DebugProfile.entitlements"):
        path = ROOT / "macos/Runner" / name
        if not path.is_file():
            raise SystemExit(f"Generated macOS entitlement missing: {name}")
        with path.open("rb") as handle:
            entitlements = plistlib.load(handle)
        entitlements["com.apple.security.network.client"] = True
        entitlements["com.apple.security.network.server"] = True
        entitlements["com.apple.security.files.user-selected.read-write"] = True
        # Ad-hoc distribution has no provisioning profile. Dart uses the
        # legacy login Keychain, so do not enable Keychain Sharing here.
        entitlements.pop("keychain-access-groups", None)
        with path.open("wb") as handle:
            plistlib.dump(entitlements, handle)
    print("macOS Bonjour privacy and sandbox client/server permissions ready")


def main() -> None:
    patch_window()
    patch_delegate()
    brand_icons()
    patch_local_network_permissions()
    print("macOS menu-bar login, close-to-tray and native hidden launch patched.")

if __name__=="__main__":
    main()
