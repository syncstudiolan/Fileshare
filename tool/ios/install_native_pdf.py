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
bonjour_source = source.with_name("FileShareLANBonjour.swift")
if not bonjour_source.is_file():
    raise SystemExit("Native Bonjour source missing")
shutil.copyfile(bonjour_source, runner / "FileShareLANBonjour.swift")
download_source = source.with_name("FileShareDownloadFolder.swift")
if not download_source.is_file():
    raise SystemExit("Native iOS Files-folder bridge missing")
shutil.copyfile(download_source, runner / "FileShareDownloadFolder.swift")

text = app_delegate.read_text(encoding="utf8")
# Flutter 3.41+ uses a UIScene lifecycle, so the implicit engine
# registers plugins in didInitializeImplicitFlutterEngine rather than launch.
old = "GeneratedPluginRegistrant.register(with: self)"
modern = "GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)"
if "FileShareIOSPDF.register" not in text:
    if modern in text:
        registration = modern + """
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FileShareIOSPDF") {
      FileShareIOSPDF.register(messenger: registrar.messenger())
      FileShareLANBonjour.register(messenger: registrar.messenger())
      FileShareDownloadFolder.register(messenger: registrar.messenger())
    }"""
        text = text.replace(modern, registration, 1)
    elif old in text:
        registration = old + """
    FileShareIOSPDF.register(messenger: (window?.rootViewController as! FlutterViewController).binaryMessenger)
    FileShareLANBonjour.register(messenger: (window?.rootViewController as! FlutterViewController).binaryMessenger)
    FileShareDownloadFolder.register(messenger: (window?.rootViewController as! FlutterViewController).binaryMessenger)"""
        text = text.replace(old, registration, 1)
    else:
        raise SystemExit("Cannot identify Flutter plugin registration in AppDelegate")
    app_delegate.write_text(text, encoding="utf8")

ruby = r"""
require 'xcodeproj'
project = Xcodeproj::Project.open('ios/Runner.xcodeproj')
target = project.targets.find { |t| t.name == 'Runner' }
raise 'Missing iOS Runner target' unless target
group = project.main_group.find_subpath('Runner', true)
['FileShareIOSPDF.swift', 'FileShareLANBonjour.swift', 'FileShareDownloadFolder.swift'].each do |filename|
  item = group.files.find { |f| f.path == filename }
  item ||= group.new_file(filename)
  unless target.source_build_phase.files_references.include?(item)
    target.source_build_phase.add_file_reference(item)
  end
end
project.save
"""
subprocess.run(["ruby", "-e", ruby], cwd=root, check=True)
print("Registered iOS native PDFKit, LAN Bonjour, and Files download folder bridge")
