#!/usr/bin/env python3
"""Generate native File Share assets from the user-approved logo in-repo.

Run after `flutter create` so generated platform runners don't overwrite icons.
Requires Pillow. Source asset is intentionally small to keep APK footprint low.
"""
from __future__ import annotations
from pathlib import Path
from PIL import Image, ImageOps, ImageEnhance

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/branding/file_share_icon.webp"
BRAND = ROOT / "assets/branding"


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit("Approved logo source is missing: " + str(SOURCE))
    icon = Image.open(SOURCE).convert("RGBA")
    if icon.size != (96, 96):
        icon = ImageOps.fit(icon, (96, 96), method=Image.Resampling.LANCZOS)

    # Larger PNG sizes are scaled from the same approved image, no new artwork.
    for density, px in [
        ("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
        ("xxhdpi", 144), ("xxxhdpi", 192),
    ]:
        folder = ROOT / f"android/app/src/main/res/mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        image = icon.resize((px, px), Image.Resampling.LANCZOS)
        image.save(folder / "ic_launcher.png", optimize=True)
        image.save(folder / "ic_launcher_round.png", optimize=True)

    # Adaptive icon background stays within the app brand; no non-brand glyph.
    fg_folder = ROOT / "android/app/src/main/res/drawable"
    fg_folder.mkdir(parents=True, exist_ok=True)
    icon.resize((432, 432), Image.Resampling.LANCZOS).save(
        fg_folder / "ic_file_share_launcher_foreground.png", optimize=True
    )
    adaptive = ROOT / "android/app/src/main/res/mipmap-anydpi-v26"
    adaptive.mkdir(parents=True, exist_ok=True)
    xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@android:color/white"/>
    <foreground android:drawable="@drawable/ic_file_share_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_file_share_notification"/>
</adaptive-icon>
'''
    (adaptive / "ic_launcher.xml").write_text(xml, encoding="utf-8")
    (adaptive / "ic_launcher_round.xml").write_text(xml, encoding="utf-8")

    # Windows EXE icon / Start menu / desktop shortcuts / installer / tray.
    # ICO embeds multiple sizes so tiny taskbar/tray use their own pixels.
    windows_icon = ROOT / "windows/runner/resources/app_icon.ico"
    windows_icon.parent.mkdir(parents=True, exist_ok=True)
    icon.resize((256, 256), Image.Resampling.LANCZOS).save(
        windows_icon, format="ICO", sizes=[(16, 16), (24, 24),
            (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    )
    BRAND.mkdir(parents=True, exist_ok=True)
    (BRAND / "file_share_tray.ico").write_bytes(windows_icon.read_bytes())

    print("Generated native Android launcher and Windows ICO from approved artwork.")


if __name__ == "__main__":
    main()
