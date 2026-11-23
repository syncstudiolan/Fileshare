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
  // iOS/macOS must export through native document-provider APIs. A Unix-style
  // path under the app container is NOT the user's Files/Downloads folder.
  static const _appleDownloads = MethodChannel('file_share.downloads');

  Future<String?> appleDownloadFolder() =>
      _appleDownloads.invokeMethod<String>('getDirectory');

  /// The OS picker grants sandbox access to the chosen folder; the native
  /// bridge stores a security-scoped bookmark for subsequent downloads.
  /// Cancel leaves the existing folder unchanged.
  Future<String?> chooseAppleDownloadFolder() =>
      _appleDownloads.invokeMethod<String>('chooseDirectory');

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
    if (Platform.isIOS || Platform.isMacOS) {
      // Native picker opens on first save if no folder is saved. Copying via
      // NSFileCoordinator handles iCloud Drive and other document providers.
      // A cancelled picker returns null so NEW remains on the card.
      return _appleDownloads.invokeMethod<String>('exportFile', {
        'path': source.path,
        'name': safe,
      });
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


/// iOS Files and macOS Finder destination settings, without changing Android
/// DCIM/Downloads or the Windows folder picker.
class AppleDownloadLocationSetting extends StatefulWidget {
  const AppleDownloadLocationSetting({super.key});
  @override State<AppleDownloadLocationSetting> createState() =>
      _AppleDownloadLocationSettingState();
}

class _AppleDownloadLocationSettingState
    extends State<AppleDownloadLocationSetting> {
  String? _folder;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final folder=await TransferDownloads.instance.appleDownloadFolder();
      if(mounted)setState(() { _folder=folder; _error=null; });
    } catch(e) {
      if(mounted)setState(() { _error='Cannot read selected folder: $e'; });
    }
  }

  Future<void> _choose() async {
    if(_busy)return;
    setState(() => _busy=true);
    try {
      final folder=await TransferDownloads.instance.chooseAppleDownloadFolder();
      if(!mounted)return;
      if(folder!=null)setState(() { _folder=folder; _error=null; });
      // Cancel does not erase the previously chosen folder.
    } catch(e) {
      if(mounted)setState(() => _error='Cannot select download folder: $e');
    } finally {
      if(mounted)setState(() => _busy=false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment:CrossAxisAlignment.stretch,
    children:[
      ListTile(
        leading:const Icon(Icons.folder_open_rounded),
        title:Text(_folder??'No download folder selected'),
        subtitle:Text(_folder==null
            ?'First download will ask you to choose a folder.'
            :'Files will be saved here until you change it.'),
      ),
      if(_error!=null)Padding(
        padding:const EdgeInsets.only(bottom:8),
        child:Text(_error!,style:TextStyle(
          color:Theme.of(context).colorScheme.error))),
      OutlinedButton.icon(
        onPressed:_busy?null:_choose,
        icon:const Icon(Icons.folder_copy_outlined),
        label:Text(_busy?'Opening folder picker…'
          :_folder==null?'Choose download folder':'Change download folder')),
    ],
  );
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
