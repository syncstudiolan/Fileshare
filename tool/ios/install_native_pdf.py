#!/usr/bin/env python3
"""Wire File Share's PDFKit source into the Flutter-generated iOS runner.

The iOS runner is generated in CI; this keeps native integration reproducible
without copying stale Xcode project files into the Android/Windows source tree.
"""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
runner = root / "ios/Runner"
source = Path(__file__).with_name("FileShareIOSPDF.swift")
app_delegate = runner / "AppDelegate.swift"

if not app_delegate.exists() or not source.exists():
    raise SystemExit("Flutter-generated iOS Runner or native PDFKit source missing")
shutil.copyfile(source, runner / "FileShareIOSPDF.swift")

text = app_delegate.read_text(encoding="utf8")
needle = "GeneratedPluginRegistrant.register(with: self)"
replacement = needle + """
    if let flutterController = window?.rootViewController as? FlutterViewController {
      FileShareIOSPDF.register(on: flutterController)
    }"""
if needle not in text:
    raise SystemExit("Cannot identify Flutter plugin registration in AppDelegate")
if "FileShareIOSPDF.register" not in text:
    app_delegate.write_text(text.replace(needle, replacement), encoding="utf8")

ruby = r"""
require 'xcodeproj'
project = Xcodeproj::Project.open('ios/Runner.xcodeproj')
target = project.targets.find { |t| t.name == 'Runner' }
raise 'Missing iOS Runner target' unless target
group = project.main_group.find_subpath('Runner', true)
item = group.files.find { |f| f.path == 'FileShareIOSPDF.swift' }
item ||= group.new_file('FileShareIOSPDF.swift')
unless target.source_build_phase.files_references.include?(item)
  target.source_build_phase.add_file_reference(item)
end
project.save
"""
subprocess.run(["ruby", "-e", ruby], cwd=root, check=True)
print("Registered native PDFKit and document-scanner features in iOS Runner")
