package com.example.file_share

import android.content.Context
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.util.zip.ZipFile
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hssf.usermodel.HSSFWorkbook

/**
 * Lightweight offline Office -> PDF bridge. Does not embed an office renderer,
 * remote conversion service, or any Windows-specific binary in the Android APK.
 * Plain text / worksheet values are preserved for editing in Advanced PDF.
 * Original Office file is never modified. Complex styles, macros, embedded
 * charts, equations and tracked revisions require a dedicated Office renderer.
 */
internal class OfficePdfConverter(private val context:Context){
    private fun fromZip(path:String,entry:String):ByteArray?=
        ZipFile(path).use{zip->
            zip.getEntry(entry)?.let {part->
                require(part.size<16L*1024*1024 || part.size<0){
                    "Office document XML is too large"
                }
                zip.getInputStream(part).use{input->
                    val out=java.io.ByteArrayOutputStream()
                    val buffer=ByteArray(32768)
                    while(true){
                        val n=input.read(buffer)
                        if(n<0)break
                        require(out.size()+n<=16*1024*1024){
                            "Office document XML exceeded the size limit"
                        }
                        out.write(buffer,0,n)
                    }
                    out.toByteArray()
                }
            }
        }
    private fun xmlText(bytes:ByteArray, elements:Set<String>):String{
        val parser=Xml.newPullParser()
        parser.setInput(bytes.inputStream(),"UTF-8")
        val output=StringBuilder()
        var last=""
        var inside=false
        var event=parser.eventType
        while(event!=XmlPullParser.END_DOCUMENT){
            when(event){
                XmlPullParser.START_TAG->{
                    val tag=parser.name.substringAfter(':')
                    inside=tag in elements
                    if(tag=="p"||tag=="row"||tag=="tr"){
                        if(output.isNotEmpty())output.append('\n')
                    }else if(tag=="c"||tag=="tc"||tag=="table-cell"){
                        if(last!="p"&&output.isNotEmpty())output.append("    ")
                    }
                    last=tag
                }
                XmlPullParser.TEXT->{
                    if(inside)output.append(parser.text)
                }
                XmlPullParser.END_TAG->{
                    val tag=parser.name.substringAfter(':')
                    if(tag in elements)inside=false
                }
            }
            event=parser.next()
        }
        return output.toString()
    }
    private fun docx(path:String):String{
        val data=fromZip(path,"word/document.xml")
            ?:error("Word document.xml was not found")
        return xmlText(data,setOf("t"))
    }
    private fun xlsx(path:String):String{
        val shared=fromZip(path,"xl/sharedStrings.xml")
            ?.let{extractSharedStrings(it)} ?: emptyList()
        val output=StringBuilder()
        ZipFile(path).use{zip->
            val sheets=zip.entries().asSequence()
                .filter{it.name.matches(Regex("xl/worksheets/sheet[0-9]+\\.xml"))}
                .sortedBy{it.name}.toList()
            for((idx,entry) in sheets.withIndex()){
                if(idx>0)output.append("\n\n")
                output.append("Worksheet ${idx+1}\n")
                val parser=Xml.newPullParser()
                parser.setInput(zip.getInputStream(entry),"UTF-8")
                var type="";var value=false;var row=StringBuilder()
                var event=parser.eventType
                while(event!=XmlPullParser.END_DOCUMENT){
                    when(event){
                        XmlPullParser.START_TAG->when(parser.name.substringAfter(':')){
                            "c"->{type=parser.getAttributeValue(null,"t")?:""}
                            "v","t"->value=true
                            "row"->row=StringBuilder()
                        }
                        XmlPullParser.TEXT->if(value){
                            val cell=parser.text
                            val display=if(type=="s")shared.getOrNull(cell.toIntOrNull()?:-1)?:cell
                                else cell
                            if(row.isNotEmpty())row.append(" | ")
                            row.append(display)
                        }
                        XmlPullParser.END_TAG->when(parser.name.substringAfter(':')){
                            "v","t"->value=false
                            "row"->{output.append(row).append('\n')}
                        }
                    }
                    event=parser.next()
                }
            }
        }
        return output.toString()
    }
    private fun extractSharedStrings(bytes:ByteArray):List<String>{
        val parser=Xml.newPullParser()
        parser.setInput(bytes.inputStream(),"UTF-8")
        val result=mutableListOf<String>();var text=StringBuilder();var active=false
        var event=parser.eventType
        while(event!=XmlPullParser.END_DOCUMENT){
            when(event){
                XmlPullParser.START_TAG->when(parser.name.substringAfter(':')){
                    "si"->text=StringBuilder()
                    "t"->active=true
                }
                XmlPullParser.TEXT->if(active)text.append(parser.text)
                XmlPullParser.END_TAG->when(parser.name.substringAfter(':')){
                    "t"->active=false
                    "si"->result.add(text.toString())
                }
            }
            event=parser.next()
        }
        return result
    }
    private fun legacyDoc(file:File):String=
        file.inputStream().use{stream->
            HWPFDocument(stream).use{it.range.text()}
        }
    private fun legacyXls(file:File):String{
        val out=StringBuilder()
        file.inputStream().use{stream->
            HSSFWorkbook(stream).use{book->
                for(sheet in book){
                    out.append(sheet.sheetName).append('\n')
                    for(row in sheet){
                        for(cell in row)out.append(cell.toString()).append(" | ")
                        out.append('\n')
                    }
                    out.append('\n')
                }
            }
        }
        return out.toString()
    }
    fun convert(path:String,name:String):String{
        val input=File(path)
        require(input.isFile){"Office file is missing"}
        require(input.length()<=30L*1024*1024){"Office document exceeds 30 MB safety limit"}
        val extension=name.substringAfterLast('.',"").lowercase()
        val text=when(extension){
            "docx"->docx(path)
            "xlsx"->xlsx(path)
            "doc"->legacyDoc(input)
            "xls"->legacyXls(input)
            "odt","ods"->xmlText(fromZip(path,"content.xml")
                ?:error("OpenDocument XML missing"),setOf("p","span","text","v"))
            else->error("Unsupported Office format: $extension")
        }
        require(text.isNotBlank()){"No readable document content"}
        val document=PdfDocument()
        val paint=Paint(Paint.ANTI_ALIAS_FLAG).apply{
            color=Color.BLACK;textSize=11f;typeface=Typeface.DEFAULT
        }
        val margin=35f;val paperW=595;val paperH=842
        val usable=paperW-margin*2
        var page:PdfDocument.Page?=null;var y=margin+12f;var pageNo=0
        fun nextPage(){
            page?.let{document.finishPage(it)}
            pageNo++
            page=document.startPage(PdfDocument.PageInfo.Builder(paperW,paperH,pageNo).create())
            y=margin+12
        }
        try{
            nextPage()
            for(line in text.replace("\r","").split('\n')){
                if(line.isEmpty()){y+=17;continue}
                val chars=line.toCharArray()
                val pending=StringBuilder()
                fun write(){
                    if(pending.isEmpty())return
                    if(y>paperH-margin){nextPage()}
                    page!!.canvas.drawText(pending.toString(),margin,y,paint)
                    y+=17
                    pending.clear()
                }
                for(char in chars){
                    if(paint.measureText(pending.toString()+char)>usable)write()
                    pending.append(char)
                }
                write()
                if(pageNo>2000)error("Document exceeds page limit")
            }
            page?.let{document.finishPage(it)}
            val out=File.createTempFile("fileshare_office_",".pdf",context.cacheDir)
            out.outputStream().use{document.writeTo(it)}
            return out.absolutePath
        }finally{document.close()}
    }
}
