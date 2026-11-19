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

    # Leave an extra safe zone for OEM adaptive icon masks and legacy circles.
    def framed(size, ratio, bg=(0, 0, 0, 0)):
        canvas = Image.new("RGBA", (size, size), bg)
        side = max(1, round(size * ratio))
        mark = ImageOps.contain(icon, (side, side),
                                method=Image.Resampling.LANCZOS)
        canvas.alpha_composite(mark,
          ((size-mark.width)//2, (size-mark.height)//2))
        return canvas

    # Larger PNG sizes are scaled from the same approved image, no new artwork.
    for density, px in [
        ("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
        ("xxhdpi", 144), ("xxxhdpi", 192),
    ]:
        folder = ROOT / f"android/app/src/main/res/mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        image = framed(px, 0.62, (244, 238, 255, 255))
        image.save(folder / "ic_launcher.png", optimize=True)
        image.save(folder / "ic_launcher_round.png", optimize=True)

    # Adaptive icon background stays within the app brand; no non-brand glyph.
    fg_folder = ROOT / "android/app/src/main/res/drawable"
    fg_folder.mkdir(parents=True, exist_ok=True)
    framed(432, 0.48).save(
        fg_folder / "ic_file_share_launcher_foreground.png", optimize=True
    )
    adaptive = ROOT / "android/app/src/main/res/mipmap-anydpi-v26"
    adaptive.mkdir(parents=True, exist_ok=True)
    xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/file_share_icon_bg"/>
    <foreground android:drawable="@drawable/ic_file_share_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_file_share_notification"/>
</adaptive-icon>
'''
    (adaptive / "ic_launcher.xml").write_text(xml, encoding="utf-8")
    (adaptive / "ic_launcher_round.xml").write_text(xml, encoding="utf-8")

    colors = ROOT / "android/app/src/main/res/values"
    colors.mkdir(parents=True, exist_ok=True)
    (colors / "file_share_icon_background.xml").write_text(
        '<resources><color name="file_share_icon_bg">'
        '#F4EEFF</color></resources>', encoding="utf-8")

    # When called from the iOS runner, create every required branded app icon.
    ios_runner = ROOT / "ios/Runner"
    if ios_runner.is_dir():
        import json
        appicons = ios_runner / "Assets.xcassets/AppIcon.appiconset"
        appicons.mkdir(parents=True, exist_ok=True)
        specs = [
            ("iphone", 20, [2, 3]), ("iphone", 29, [2, 3]),
            ("iphone", 40, [2, 3]), ("iphone", 60, [2, 3]),
            ("ipad", 20, [1, 2]), ("ipad", 29, [1, 2]),
            ("ipad", 40, [1, 2]), ("ipad", 76, [1, 2]),
            ("ipad", 83.5, [2]),
        ]
        entries = []
        for idiom, points, scales in specs:
            for scale in scales:
                pixels = round(points * scale)
                filename = "fs-{}-{}-{}.png".format(
                    idiom, str(points).replace(".", "_"), scale)
                framed(pixels, .72, (244, 238, 255, 255)).convert(
                    "RGB").save(appicons / filename, optimize=True)
                entries.append(dict(idiom=idiom,
                    size="{}x{}".format(points, points),
                    scale="{}x".format(scale), filename=filename))
        framed(1024, .72, (244, 238, 255, 255)).convert(
            "RGB").save(appicons / "fs-store.png", optimize=True)
        entries.append(dict(idiom="ios-marketing", size="1024x1024",
            scale="1x", filename="fs-store.png"))
        (appicons / "Contents.json").write_text(
            json.dumps(dict(images=entries,
                info=dict(version=1, author="xcode")), indent=2),
            encoding="utf-8")

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

    print("Generated padded Android, iOS and Windows brand icons.")


if __name__ == "__main__":
    main()
