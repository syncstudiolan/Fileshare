#!/usr/bin/env python3
"""Reproducibly patch flutter_inappwebview_android 1.1.3 for AGP 9.

The upstream 1.1.3 Android build.gradle requests an unsupported non-optimizing
ProGuard file. Only replace that obsolete name, leaving Dart/plugin APIs and
all other dependencies unchanged. Never patch app source or disable R8.
"""
from pathlib import Path
import os

cache=Path(os.environ.get("PUB_CACHE",str(Path.home()/".pub-cache")))
plugins=list(cache.glob("hosted/pub.dev/flutter_inappwebview_android-*/android/build.gradle"))
if not plugins:
    raise SystemExit("flutter_inappwebview_android Android Gradle dependency not found after flutter pub get")
for path in plugins:
    original=path.read_text(encoding="utf-8")
    revised=original.replace("getDefaultProguardFile('proguard-android.txt')",
        "getDefaultProguardFile('proguard-android-optimize.txt')")
    revised=revised.replace('getDefaultProguardFile("proguard-android.txt")',
        'getDefaultProguardFile("proguard-android-optimize.txt")')
    if revised==original:
        if "proguard-android-optimize.txt" in original:
            print("Plugin AGP9 ProGuard already compatible:",path)
            continue
        raise SystemExit("Unexpected plugin Gradle layout; upstream review required: "+str(path))
    path.write_text(revised,encoding="utf-8")
    print("AGP9-compatible ProGuard optimization enabled:",path)
