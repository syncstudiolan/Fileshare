import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart' as xml;

/// An offline non-destructive editor of existing OOXML text containers.
/// It never writes over the original and leaves non-text package entries intact.
class FileShareDocEngine {
  FileShareDocEngine._(this.source,this.kind,this.blocks,this.archive,this.parts);
  final File source;
  final String kind;
  final List<DocBlock> blocks;
  final Archive? archive;
  final Map<String,xml.XmlDocument> parts;
  static const textFormats={'txt','md','markdown','html','htm','css','js','ts',
    'json','xml','yaml','yml','csv','log','sql','py','dart','java','kt','ini',
    'sh','bat','ps1','svg'};
  static const officeFormats={'docx','docm','dotx','xlsx','xlsm','xltx',
    'pptx','pptm','ppsx','potx','odt','ods','odp'};
  static const viewOnly={'pdf','doc','rtf','xls','xlsb','ppt','epub',
    'zip','jpg','jpeg','png','webp','gif','bmp','heic','mp3','wav',
    'mp4','mkv','mov','flac','ogg'};
  static String ext(String path)=>path.toLowerCase().split('.').last;
  static bool canEdit(String path)=>textFormats.contains(ext(path))||
    officeFormats.contains(ext(path));
  static bool canView(String path)=>canEdit(path)||viewOnly.contains(ext(path));
  static Iterable<xml.XmlElement> named(xml.XmlNode node,String name)=>
    node.descendants.whereType<xml.XmlElement>().where((n)=>n.name.local==name);
  static List<xml.XmlElement> slots(xml.XmlDocument doc,String kind)=>
    doc.descendants.whereType<xml.XmlElement>().where((node){
      if({'docx','docm','dotx'}.contains(kind)){
        return node.name.local=='p'&&node.name.prefix=='w' &&
          !node.ancestors.whereType<xml.XmlElement>()
            .any((parent)=>parent.name.local=='p'&&parent.name.prefix=='w');
      }
      if({'pptx','pptm','ppsx','potx'}.contains(kind))
        return node.name.local=='p'&&node.name.prefix=='a';
      if({'xlsx','xlsm','xltx'}.contains(kind))return node.name.local=='c';
      return node.name.local=='p'||node.name.local=='h';
    }).toList();

  static Future<FileShareDocEngine> open(File file) async {
    if(!await file.exists())throw StateError('File unavailable');
    if(await file.length()>32*1024*1024)
      throw StateError('File is larger than 32 MB safety limit');
    final type=ext(file.path);
    if(textFormats.contains(type)){
      return FileShareDocEngine._(file,type,[
        DocBlock('text','Document',await file.readAsString(),'text',0)
      ],null,{});
    }
    if(!officeFormats.contains(type)){
      throw UnsupportedError('No document editing engine for .'+type);
    }
    final zip=ZipDecoder().decodeBytes(await file.readAsBytes());
    if(zip.length>10000||zip.fold<int>(0,(a,f)=>a+f.size)>256*1024*1024){
      throw StateError('Unsafe Office archive size');
    }
    final paths=<String>[];
    if({'docx','docm','dotx'}.contains(type)){
      paths.add('word/document.xml');
      paths.addAll(zip.where((f)=>RegExp(
        r'^word/(header[0-9]+|footer[0-9]+|footnotes|endnotes)\.xml$')
        .hasMatch(f.name)).map((f)=>f.name).toList()..sort());
    }else if({'xlsx','xlsm','xltx'}.contains(type)){
      paths.addAll(zip.where((f)=>
        RegExp(r'^xl/worksheets/sheet[0-9]+\.xml$').hasMatch(f.name))
        .map((f)=>f.name).toList()..sort());
    }else if({'pptx','pptm','ppsx','potx'}.contains(type)){
      paths.addAll(zip.where((f)=>
        RegExp(r'^ppt/slides/slide[0-9]+\.xml$').hasMatch(f.name))
        .map((f)=>f.name).toList()..sort());
    }else{
      paths.add('content.xml');
    }
    final shared=<String>[];
    if({'xlsx','xlsm','xltx'}.contains(type)){
      final file=zip.findFile('xl/sharedStrings.xml');
      if(file!=null){
        final tree=xml.XmlDocument.parse(utf8.decode(file.content));
        for(final row in named(tree,'si')){
          shared.add(named(row,'t').map((e)=>e.innerText).join());
        }
      }
    }
    final blocks=<DocBlock>[];
    final parts=<String,xml.XmlDocument>{};
    for(final path in paths){
      final file=zip.findFile(path);
      if(file==null)continue;
      if(file.size>24*1024*1024)throw StateError('Oversized XML part');
      final tree=xml.XmlDocument.parse(utf8.decode(file.content));
      parts[path]=tree;
      final nodes=slots(tree,type);
      for(var i=0;i<nodes.length;i++){
        final node=nodes[i];
        var label=path.split('/').last;
        String value;
        if({'xlsx','xlsm','xltx'}.contains(type)){
          if(node.children.whereType<xml.XmlElement>()
            .any((e)=>e.name.local=='f'))continue;
          label=node.attributes.where((a)=>a.name.local=='r')
            .map((a)=>a.value).firstOrNull??label;
          final cellType=node.attributes.where((a)=>a.name.local=='t')
            .map((a)=>a.value).firstOrNull??'n';
          final raw=node.children.whereType<xml.XmlElement>()
            .where((e)=>e.name.local=='v').map((e)=>e.innerText)
            .firstOrNull??'';
          final id=int.tryParse(raw)??-1;
          value=cellType=='s'?(id>=0&&id<shared.length?shared[id]:''):
            cellType=='inlineStr'
            ?named(node,'t').map((e)=>e.innerText).join():raw;
        }else{
          value={'odt','ods','odp'}.contains(type)
            ?node.innerText:named(node,'t').map((e)=>e.innerText).join();
        }
        if(value.isNotEmpty){
          blocks.add(DocBlock(path+'#'+i.toString(),label,value,path,i));
        }
      }
    }
    return FileShareDocEngine._(file,type,blocks,zip,parts);
  }

  void apply(Map<String,String> changed){
    for(final block in blocks){
      final value=changed[block.id];
      if(value==null||value==block.original||block.part=='text')continue;
      final tree=parts[block.part];
      if(tree==null)continue;
      final nodes=slots(tree,kind);
      if(block.index>=nodes.length)continue;
      final node=nodes[block.index];
      if({'xlsx','xlsm','xltx'}.contains(kind)){
        if(node.children.whereType<xml.XmlElement>()
          .any((e)=>e.name.local=='f'))continue;
        final oldType=node.attributes.where((a)=>a.name.local=='t')
          .map((a)=>a.value).firstOrNull??'n';
        final numeric=RegExp(
          r'^[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?$')
          .hasMatch(value.trim());
        if(oldType=='n' && numeric){
          node.children.removeWhere((n)=>n is xml.XmlElement &&
            (n.name.local=='v'||n.name.local=='is'));
          node.children.add(xml.XmlElement(xml.XmlName('v'),[],
            [xml.XmlText(value.trim())]));
          continue;
        }
        node.attributes.removeWhere((a)=>a.name.local=='t');
        node.attributes.add(xml.XmlAttribute(xml.XmlName('t'),'inlineStr'));
        node.children.removeWhere((n)=>n is xml.XmlElement &&
          (n.name.local=='v'||n.name.local=='is'));
        node.children.add(xml.XmlElement(xml.XmlName('is'),[],[
          xml.XmlElement(xml.XmlName('t'),[],[xml.XmlText(value)])
        ]));
      }else if({'odt','ods','odp'}.contains(kind)){
        final leafText=node.descendants.whereType<xml.XmlText>().toList();
        if(leafText.isEmpty){node.children.add(xml.XmlText(value));}
        else{
          leafText.first.value=value;
          for(final text in leafText.skip(1))text.value='';
        }
      }else{
        final runs=named(node,'t').toList();
        if(runs.isEmpty)continue;
        runs.first.children..clear()..add(xml.XmlText(value));
        for(final run in runs.skip(1))run.children.clear();
        if({'docx','docm','dotx'}.contains(kind)){
          runs.first.attributes.removeWhere((a)=>a.name.local=='space');
          runs.first.attributes.add(
            xml.XmlAttribute(xml.XmlName('space','xml'),'preserve'));
        }
      }
    }
  }

  Future<File> saveCopy(Map<String,String> changed,Directory dir) async {
    await dir.create(recursive:true);
    final filename=source.uri.pathSegments.last;
    final dot=filename.lastIndexOf('.');
    final basename=(dot<0?filename:filename.substring(0,dot))
      .replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'),'_');
    var counter=0;
    late File target;
    do{
      final suffix=counter==0?'_edited':'_edited_'+counter.toString();
      counter++;
      target=File(dir.path+Platform.pathSeparator+basename+suffix+'.'+kind);
    }while(await target.exists());
    if(archive==null){
      await target.writeAsString(changed['text']??blocks.first.original,flush:true);
      return target;
    }
    apply(changed);
    final rebuilt=Archive();
    for(final part in archive!){
      if(!part.isFile){
        rebuilt.add(ArchiveFile.directory(part.name));
      }else{
        final xmlPart=parts[part.name];
        rebuilt.add(ArchiveFile.bytes(part.name,
          xmlPart==null?part.content:utf8.encode(xmlPart.toXmlString())));
      }
    }
    await target.writeAsBytes(ZipEncoder().encodeBytes(rebuilt),flush:true);
    final verify=ZipDecoder().decodeBytes(await target.readAsBytes());
    if(verify.length!=archive!.length){
      await target.delete();
      throw StateError('Office package validation failed');
    }
    return target;
  }
}
class DocBlock {
  const DocBlock(this.id,this.title,this.original,this.part,this.index);
  final String id,title,original,part;
  final int index;
}
