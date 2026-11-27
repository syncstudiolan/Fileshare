import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_share/file_share_text.dart';

void main(){
  test('recognizes only dedicated text message envelope',(){
    expect(FileShareText.isText('FileshareText-abc.fstext'),isTrue);
    expect(FileShareText.isText('normal.txt'),isFalse);
    expect(FileShareText.isText('other.fstext'),isFalse);
  });
  test('UTF-8 preview preserves short multilingual messages',()async{
    final dir=await Directory.systemTemp.createTemp('fileshare_message_test');
    try{
      final f=File('${dir.path}/short.fstext');
      const message='नमस्ते\nHello 🌍 — paste text';
      await f.writeAsString(message);
      expect(await FileShareText.preview(f),message);
    }finally{await dir.delete(recursive:true);}
  });
  test('10,000+ words have no text codec word cap',()async{
    final dir=await Directory.systemTemp.createTemp('fileshare_long_message');
    try{
      final f=File('${dir.path}/long.fstext');
      final message=List.filled(12000,'hello नमस्ते').join(' ');
      await f.writeAsString(message);
      expect(await f.readAsString(),message);
      expect(await FileShareText.preview(f),contains('Tap to view full text'));
    }finally{await dir.delete(recursive:true);}
  });
}
