#!/usr/bin/env python3
"""iOS-only CI workaround: prevent unused ONNX native plugin registration.

File Share's iOS enhancer uses the pure-Dart mobile implementation.
The flutter_onnxruntime native plugin is required for Windows, not iOS.
Its iOS CocoaPods/SPM download currently fails TLS verification on
Microsoft's binary CDN. Do not disable TLS verification or touch
Android/Windows metadata. The cached package change is CI-local.
"""
import json
import pathlib
import re
from urllib.parse import urlparse, unquote

root = pathlib.Path(__file__).resolve().parents[2]
config = json.loads((root / ".dart_tool/package_config.json").read_text())
packages = [p for p in config["packages"] if p["name"] == "flutter_onnxruntime"]
assert len(packages) == 1, "Expected exactly one ONNX Runtime package"
entry = packages[0]
root_uri = entry["rootUri"]
config_dir = root / ".dart_tool"
if root_uri.startswith("file:"):
    plugin = pathlib.Path(unquote(urlparse(root_uri).path))
else:
    plugin = (config_dir / unquote(root_uri)).resolve()
pubspec = plugin / "pubspec.yaml"
original = pubspec.read_text()
assert re.search(r"^version:\s*1\.9\.0\s*$", original, re.M), "Unexpected ONNX version"
lines = original.splitlines(keepends=True)
# Only remove the ios platform declaration under flutter.plugin.platforms.
platforms = next((i for i, line in enumerate(lines)
                  if re.match(r"^\s{4}platforms:\s*$", line)), None)
if platforms is None:
    raise SystemExit("Missing native plugin platforms section")
start = next((i for i in range(platforms + 1, len(lines))
              if re.match(r"^\s{6}ios:\s*$", lines[i])), None)
if start is None:
    raise SystemExit("Expected flutter_onnxruntime iOS plugin declaration")
end = start + 1
while end < len(lines) and (
    lines[end].strip() == "" or
    (len(lines[end]) - len(lines[end].lstrip())) > 6
):
    end += 1
patched = "".join(lines[:start] + lines[end:])
assert re.search(r"^\s{6}windows:", patched, re.M), "Windows plugin must remain"
assert not re.search(r"^\s{6}ios:", patched, re.M), "iOS plugin still registered"
pubspec.write_text(patched)
print("iOS ONNX native registration disabled; Dart mobile enhancer stays enabled.")
