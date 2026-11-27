import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Text messages reuse the exact durable LAN/cloud file transport.
/// No word/character limit is imposed by this codec or the composer.
/// Network, filesystem and device memory limits still apply.
class FileShareText {
  static const suffix = '.fstext';
  static bool isText(String name) => name.startsWith('FileshareText-') && name.endsWith(suffix);

  static Future<File> create(String message, String uniqueId) async {
    if (message.trim().isEmpty) throw ArgumentError('Message is empty');
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}${Platform.pathSeparator}text_messages');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}FileshareText-$uniqueId$suffix');
    await file.writeAsString(message, encoding: utf8, flush: true);
    return file;
  }

  /// Read only a bounded *preview* to keep very large messages scrollable.
  /// The original UTF-8 file remains intact; Copy loads complete content.
  static Future<String> preview(File file) async {
    final bytes = <int>[];
    await for(final chunk in file.openRead(0, 8192)) { bytes.addAll(chunk); }
    final content = utf8.decode(bytes, allowMalformed: true);
    return await file.length() > 8192 ? '$content\n… Tap to view full text' : content;
  }
}
