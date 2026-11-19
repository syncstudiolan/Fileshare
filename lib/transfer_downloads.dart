import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent, local-to-this-device download acknowledgement. A received
/// file is NEW until it has been successfully exported at least once.
class TransferDownloads {
  TransferDownloads._();
  static final instance = TransferDownloads._();
  final ValueNotifier<Set<String>> saved = ValueNotifier(<String>{});
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  static const _key = 'downloaded_transfer_ids_v1';
  static const _channel = MethodChannel('file_share.native');

  Future<void> init() async {
    saved.value = (await _prefs.getStringList(_key) ?? <String>[]).toSet();
  }

  bool isNew(String id) => !saved.value.contains(id);

  Future<void> markSaved(String id) async {
    if (saved.value.contains(id)) return;
    final next = <String>{...saved.value, id};
    await _prefs.setStringList(_key, next.toList());
    saved.value = next;
  }

  static bool _isImage(String name) {
    final s = name.toLowerCase();
    return ['.jpg','.jpeg','.png','.webp','.gif','.bmp','.heic','.heif']
      .any(s.endsWith);
  }

  /// Save once; caller marks NEW as acknowledged only AFTER successful copy.
  /// Android MediaStore makes images available to Gallery (DCIM/FileShare),
  /// and other files visible in the public Downloads collection.
  Future<String?> export(File source, String name) async {
    if (!await source.exists()) throw StateError('Source no longer available');
    final safe = name.replaceAll(RegExp(r'[/\\]'), '_');
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>('saveReceivedFile', {
        'path': source.path, 'name': safe, 'image': _isImage(safe),
      });
    }
    if (Platform.isWindows) {
      final downloads = await getDownloadsDirectory();
      final prefs = _prefs;
      final defaultFolder = downloads?.path;
      final alwaysDefault = await prefs.getBool('windows_always_downloads') ?? false;
      String? folder;
      if (alwaysDefault && defaultFolder != null) {
        folder = defaultFolder;
      } else {
        // Native Windows folder picker opens for each download by default.
        // Initial location remembers the most recent successful export.
        final previous = await prefs.getString('windows_last_download_folder');
        folder = await FilePicker.getDirectoryPath(
          dialogTitle: 'Choose a folder for this download',
          initialDirectory: previous ?? defaultFolder);
      }
      if (folder == null) return null; // Cancel is not a download.
      final directory = Directory(folder);
      if (!await directory.exists()) throw StateError('Selected folder unavailable');
      final target = await _unique(directory, safe);
      await source.openRead().pipe(target.openWrite());
      await prefs.setString('windows_last_download_folder', folder);
      return target.path;
    }
    final directory = await getDownloadsDirectory();
    if (directory == null) throw StateError('Downloads directory unavailable');
    await directory.create(recursive: true);
    final target = await _unique(directory, safe);
    await source.openRead().pipe(target.openWrite());
    return target.path;
  }

  Future<bool> windowsAlwaysDownloads() async =>
    await _prefs.getBool('windows_always_downloads') ?? false;

  Future<void> setWindowsAlwaysDownloads(bool value) async =>
    _prefs.setBool('windows_always_downloads', value);

  Future<String?> lastWindowsFolder() async =>
    _prefs.getString('windows_last_download_folder');

  Future<File> _unique(Directory dir, String name) async {
    var target = File('${dir.path}${Platform.pathSeparator}$name');
    var n = 1;
    while (await target.exists()) {
      target = File('${dir.path}${Platform.pathSeparator}${n}_$name');
      n++;
    }
    return target;
  }
}

/// A tiny, bright badge anchored above the receiver's download icon.
/// Listens to successful exports, not transfer completion or preview taps.
class NewDownloadBadge extends StatelessWidget {
  const NewDownloadBadge({super.key,required this.id});
  final String id;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Set<String>>(
    valueListenable: TransferDownloads.instance.saved,
    builder: (context, saved, _) {
      if (saved.contains(id)) return const SizedBox.shrink();
      return IgnorePointer(child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5,vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFFFD941),
          borderRadius: BorderRadius.circular(7),
          boxShadow: const [BoxShadow(
            color: Color(0x669C5F00),blurRadius: 6)]),
        child: const Text('NEW',
          style: TextStyle(fontSize: 8,fontWeight: FontWeight.w900,
            color: Color(0xFF432300),letterSpacing: .4)),
      ));
    },
  );
}
