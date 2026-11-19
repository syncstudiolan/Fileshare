import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:file_share/file_share_doc_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart' as xml;

void main(){
  late Directory temporary;
  setUp(()async{
    temporary=await Directory.systemTemp.createTemp('file_share_doc_test_');
  });
  tearDown(()async{
    if(await temporary.exists())await temporary.delete(recursive:true);
  });

  Future<File> office(String extension,Map<String,String> entries)async{
    final archive=Archive();
    archive.add(ArchiveFile.string('[Content_Types].xml',
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'));
    for(final entry in entries.entries){
      archive.add(ArchiveFile.bytes(entry.key,utf8.encode(entry.value)));
    }
    archive.add(ArchiveFile.bytes('word/media/image.png',[1,2,3,4]));
    final file=File(temporary.path+'/sample.'+extension);
    await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
    return file;
  }

  test('DOCX edits paragraph, keeps embedded binary and source intact',()async{
    final file=await office('docx',{
      'word/document.xml':'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>World</w:t></w:r></w:p></w:body></w:document>'
    });
    final original=await file.readAsBytes();
    final engine=await FileShareDocEngine.open(file);
    expect(engine.blocks.map((b)=>b.original),containsAll(['Hello','World']));
    final out=await engine.saveCopy({engine.blocks.first.id:'Updated'},
      Directory(temporary.path+'/saved'));
    expect(out.path,isNot(file.path));
    expect(await file.readAsBytes(),original);
    final archive=ZipDecoder().decodeBytes(await out.readAsBytes());
    expect(archive.findFile('word/media/image.png')!.content,[1,2,3,4]);
    final document=xml.XmlDocument.parse(utf8.decode(
      archive.findFile('word/document.xml')!.content));
    expect(document.innerText,contains('Updated'));
    expect(document.innerText,contains('World'));
  });

  test('Word bold italic and underline persist as OOXML run properties',()async{
    final file=await office('docx',{
      'word/document.xml':'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p><w:r><w:t>Format me</w:t></w:r></w:p>'
        '</w:body></w:document>'
    });
    final engine=await FileShareDocEngine.open(file);
    final id=engine.blocks.single.id;
    final out=await engine.saveCopy({},Directory(temporary.path+'/styles'),
      formatChanges:{id:{'bold','italic','underline'}});
    final zip=ZipDecoder().decodeBytes(await out.readAsBytes());
    final document=xml.XmlDocument.parse(utf8.decode(
      zip.findFile('word/document.xml')!.content));
    expect(document.findAllElements('b').length,1);
    expect(document.findAllElements('i').length,1);
    expect(document.findAllElements('u').length,1);
  });

  test('XLSX shared string cell becomes independent inline text',()async{
    final file=await office('xlsx',{
      'xl/sharedStrings.xml':'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<si><t>Shared</t></si></sst>',
      'xl/worksheets/sheet1.xml':'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c>'
        '<c r="B1" t="s"><v>0</v></c>'
        '<c r="C1"><f>SUM(1,2)</f><v>3</v></c></row></sheetData></worksheet>'
    });
    final engine=await FileShareDocEngine.open(file);
    expect(engine.blocks.length,2);
    final out=await engine.saveCopy({engine.blocks.first.id:'Changed'},
      Directory(temporary.path+'/saved'));
    final archive=ZipDecoder().decodeBytes(await out.readAsBytes());
    final doc=xml.XmlDocument.parse(utf8.decode(
      archive.findFile('xl/worksheets/sheet1.xml')!.content));
    final cells=doc.findAllElements('c').toList();
    expect(cells.first.getAttribute('t'),'inlineStr');
    expect(cells.first.innerText,'Changed');
    expect(cells[1].getAttribute('t'),'s');
    expect(cells[1].innerText,'0');
    expect(cells[2].findElements('f').first.innerText,'SUM(1,2)');
  });

  test('PPTX edits one slide text without modifying the other',()async{
    final file=await office('pptx',{
      'ppt/slides/slide1.xml':'<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Title</a:t></a:r>'
        '</a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
    });
    final engine=await FileShareDocEngine.open(file);
    expect(engine.blocks.single.original,'Title');
    final out=await engine.saveCopy({engine.blocks.single.id:'New slide'},
      Directory(temporary.path+'/saved'));
    final archive=ZipDecoder().decodeBytes(await out.readAsBytes());
    expect(utf8.decode(archive.findFile('ppt/slides/slide1.xml')!.content),
      contains('New slide'));
  });

  test('HTML file saves copy and preserves source',()async{
    final original=File(temporary.path+'/example.html');
    await original.writeAsString('<h1>Original</h1>');
    final engine=await FileShareDocEngine.open(original);
    final result=await engine.saveCopy({'text':'<h1>Edited</h1>'},
      Directory(temporary.path+'/saved'));
    expect(await result.readAsString(),'<h1>Edited</h1>');
    expect(await original.readAsString(),'<h1>Original</h1>');
  });

  test('creates standard minimal DOCX and opens it offline',()async{
    final file=await FileShareDocEngine.createBlankDocx(temporary);
    final engine=await FileShareDocEngine.open(file);
    expect(engine.blocks.single.original,'New document');
    final archive=ZipDecoder().decodeBytes(await file.readAsBytes());
    expect(archive.findFile('_rels/.rels'),isNotNull);
    expect(archive.findFile('[Content_Types].xml'),isNotNull);
    expect(archive.findFile('word/document.xml'),isNotNull);
  });

  test('ODT paragraph text is editable without stripping package media',()async{
    final file=await office('odt',{
      'content.xml':'<office:document-content '
        'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
        'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">'
        '<office:body><office:text>'
        '<text:p>Before <text:span>Text</text:span></text:p>'
        '</office:text></office:body></office:document-content>'
    });
    final engine=await FileShareDocEngine.open(file);
    expect(engine.blocks.single.original,'Before Text');
    final out=await engine.saveCopy({engine.blocks.single.id:'After'},
      Directory(temporary.path+'/edited'));
    final archive=ZipDecoder().decodeBytes(await out.readAsBytes());
    expect(utf8.decode(archive.findFile('content.xml')!.content),contains('After'));
    expect(archive.findFile('word/media/image.png')!.content,[1,2,3,4]);
  });

  test('unknown format correctly rejects editing',(){
    expect(FileShareDocEngine.canEdit('scan.pdf'),false);
    expect(FileShareDocEngine.canView('scan.pdf'),true);
    expect(FileShareDocEngine.canEdit('legacy.doc'),false);
  });
}
