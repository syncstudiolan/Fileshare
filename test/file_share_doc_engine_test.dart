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
    expect(document.descendants.whereType<xml.XmlElement>().where((e)=>e.name.local=='b').length,1);
    expect(document.descendants.whereType<xml.XmlElement>().where((e)=>e.name.local=='i').length,1);
    expect(document.descendants.whereType<xml.XmlElement>().where((e)=>e.name.local=='u').length,1);
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
    final cells=doc.descendants.whereType<xml.XmlElement>().where((e)=>e.name.local=='c').toList();
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

  test('LAN cache path without suffix can be edited by original filename',()async{
    final original=await office('docx',{
      'word/document.xml':'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p><w:r><w:t>LAN document</w:t></w:r></w:p>'
        '</w:body></w:document>'
    });
    final cache=File(temporary.path+'/opaque_transfer_cache');
    await original.copy(cache.path);
    final opened=await FileShareDocEngine.open(cache,
      filename:'customer_letter.docx');
    expect(opened.kind,'docx');
    expect(opened.blocks.single.original,'LAN document');
    final saved=await opened.saveCopy({opened.blocks.single.id:'Changed'},
      Directory(temporary.path+'/saved'));
    expect(saved.uri.pathSegments.last,'customer_letter_edited.docx');
  });

  test('Word insert, delete and align are kept in a valid DOCX copy',()async{
    final original=await office('docx',{
      'word/document.xml':
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p><w:r><w:t>First</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>Second</w:t></w:r></w:p>'
        '</w:body></w:document>'
    });
    final editor=await FileShareDocEngine.open(original);
    final first=editor.blocks[0].id,second=editor.blocks[1].id;
    final out=await editor.saveCopy({},Directory(temporary.path+'/word-edit'),
      alignmentChanges:{first:'center'},
      insertedAfter:{first:['New paragraph']},
      deletedParagraphs:{second});
    final zip=ZipDecoder().decodeBytes(await out.readAsBytes());
    final doc=xml.XmlDocument.parse(
      utf8.decode(zip.findFile('word/document.xml')!.content));
    final paragraphs=doc.descendants.whereType<xml.XmlElement>()
      .where((node)=>node.name.local=='p').toList();
    expect(paragraphs.length,2);
    expect(doc.innerText,contains('New paragraph'));
    expect(doc.innerText,isNot(contains('Second')));
    expect(paragraphs.first.toXmlString(),contains('center'));
    expect(await original.readAsBytes(),isNot(await out.readAsBytes()));
  });

  test('Excel numeric edits remain numeric cells and formula stays intact',()async{
    final file=await office('xlsx',{
      'xl/worksheets/sheet1.xml':
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetData><row r="1"><c r="A1"><v>3</v></c>'
        '<c r="B1"><f>A1*2</f><v>6</v></c></row></sheetData></worksheet>'
    });
    final model=await FileShareDocEngine.open(file);
    expect(model.blocks.length,1);
    final output=await model.saveCopy({model.blocks.first.id:'42.5'},
      Directory(temporary.path+'/numeric'));
    final zip=ZipDecoder().decodeBytes(await output.readAsBytes());
    final tree=xml.XmlDocument.parse(
      utf8.decode(zip.findFile('xl/worksheets/sheet1.xml')!.content));
    final cells=tree.descendants.whereType<xml.XmlElement>()
      .where((e)=>e.name.local=='c').toList();
    expect(cells[0].getAttribute('t'),isNull);
    expect(cells[0].innerText,'42.5');
    expect(cells[1].toXmlString(),contains('A1*2'));
  });

  test('Word paper layout and inserted table survive save-copy',()async{
    final file=await office('docx',{
      'word/document.xml':
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:p><w:r><w:t>Before table</w:t></w:r></w:p>'
        '<w:sectPr/></w:body></w:document>'
    });
    final model=await FileShareDocEngine.open(file);
    final result=await model.saveCopy({},
      Directory(temporary.path+'/table'),
      tablesAfter:{model.blocks.single.id:[
        const WordTableSpec(2,3,
          ['One','Two','Three','Four','Five','Six'])]},
      pagePaper:'Legal',pageLandscape:true,pageMarginTwips:720);
    final zip=ZipDecoder().decodeBytes(await result.readAsBytes());
    final tree=xml.XmlDocument.parse(utf8.decode(
      zip.findFile('word/document.xml')!.content));
    final tables=tree.descendants.whereType<xml.XmlElement>()
      .where((n)=>n.name.local=='tbl').toList();
    expect(tables.length,1);
    final cells=tree.descendants.whereType<xml.XmlElement>()
      .where((n)=>n.name.local=='tc').toList();
    expect(cells.length,6);
    expect(cells.first.innerText,'One');
    final page=tree.descendants.whereType<xml.XmlElement>()
      .firstWhere((n)=>n.name.local=='pgSz');
    expect(page.getAttribute('w:orient'),'landscape');
    expect(page.getAttribute('w:w'),'20160');
    final margin=tree.descendants.whereType<xml.XmlElement>()
      .firstWhere((n)=>n.name.local=='pgMar');
    expect(margin.getAttribute('w:top'),'720');
  });

  test('unknown format correctly rejects editing',(){
    expect(FileShareDocEngine.canEdit('scan.pdf'),false);
    expect(FileShareDocEngine.canView('scan.pdf'),true);
    expect(FileShareDocEngine.canEdit('legacy.doc'),false);
  });
}
