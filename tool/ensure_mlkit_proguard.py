#!/usr/bin/env python3
"""Apply checked-in R8 ML Kit keep rules to Flutter-generated Android runner.

The repository intentionally does not check in the whole platform runner.
GitHub Actions generates Android files with 'flutter create' on each build,
then this script makes the release shrinker retain reflective registrars.
Fail closed on unexpected Gradle structure; never silently build an unfixed
release APK.
"""
from pathlib import Path
import re

root = Path("android/app")
rules = root / "proguard-rules.pro"
if not rules.is_file():
    raise SystemExit("Missing Android ML Kit R8 keep rules")

for filename, injection in (
    ("build.gradle.kts", '            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")'),
    ("build.gradle", "            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'"),
):
    gradle = root / filename
    if not gradle.exists():
        continue
    source = gradle.read_text(encoding="utf-8")
    if '"proguard-rules.pro"' in source or "'proguard-rules.pro'" in source:
        print("ML Kit R8 rules already configured")
        break
    # Modify only the buildTypes.release block, never debug or signing.
    match = re.search(r"(?m)^\s*buildTypes\s*\{[\s\S]*?^\s*release\s*\{", source)
    if match is None:
        raise SystemExit("Cannot locate Android release buildType to add ML Kit keep rules")
    pos = match.end()
    source = source[:pos] + "\n" + injection + source[pos:]
    gradle.write_text(source, encoding="utf-8")
    print("Applied ML Kit R8 rules to", gradle)
    break
else:
    raise SystemExit("Android app Gradle config was not generated")
