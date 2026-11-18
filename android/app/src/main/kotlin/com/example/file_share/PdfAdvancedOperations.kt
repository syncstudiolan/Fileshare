package com.example.file_share

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.PDDocumentInformation
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory
import com.tom_roush.pdfbox.pdmodel.graphics.state.RenderingMode
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.File
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.math.min
import kotlin.math.max

/**
 * Advanced processing operations isolated from the Flutter UI.
 * Outputs are written to distinct files; callers own lifecycle of outputs.
 * No PDF is silently uploaded.
 *
 * Processing mechanisms informed by MIT-licensed sammyZi/pdf-tools.
 */
internal class PdfAdvancedOperations(private val context: Context,
    private val simple: (Map<*,*>)->String) {
    private fun file(ext:String="pdf")=File.createTempFile("pdf_adv_",".$ext",context.cacheDir)
    private fun text(a:Map<*,*>,key:String,default:String="")=a[key] as? String ?: default
    private fun num(a:Map<*,*>,key:String,default:Int=0)=(a[key] as? Number)?.toInt()?:default
    private fun source(a:Map<*,*>)=File(text(a,"path").takeIf{it.isNotBlank()}?:error("PDF not selected"))
    private fun adopt(out:PDDocument,p:PDPage) {
        val next=out.importPage(p)
        if(!next.cosObject.containsKey(COSName.RESOURCES))
            next.resources=p.resources?:PDResources()
    }
    private fun indices(input:String,n:Int):List<Int>{
        if(input.isBlank())return (0 until n).toList()
        val all=mutableListOf<Int>()
        for(term in input.split(",")){
            val halves=term.trim().split("-")
            val first=halves[0].trim().toIntOrNull()?:error("Invalid page number")
            val last=if(halves.size==1)first else halves.getOrNull(1)
                ?.trim()?.takeIf{it.isNotEmpty()}?.toIntOrNull()?:n
            require(first in 1..n && last in first..n){"Invalid page range"}
            for(i in first..last)all.add(i-1)
        }
        return all
    }
    private fun savePages(doc:PDDocument,selection:List<Int>,dest:File){
        require(selection.isNotEmpty()){"No PDF pages to export"}
        PDDocument().use{out->
            selection.forEach{ i->
                require(i in 0 until doc.numberOfPages){"Invalid page index"}
                adopt(out,doc.getPage(i))
            }
            out.save(dest)
        }
    }
    private fun namedOutput(suffix:String):Pair<String,File> {
        val out=file()
        return suffix to out
    }
    private fun renderPage(p:PdfRenderer.Page,limit:Int=2200):Bitmap{
        val w=min(p.width*3,limit).coerceAtLeast(1)
        val h=(p.height.toDouble()*w/p.width).toInt().coerceAtLeast(1)
        val bmp=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888)
        bmp.eraseColor(Color.WHITE)
        p.render(bmp,null,null,PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
        return bmp
    }
    private fun rasterize(src:File,index:Int,transform:(Bitmap)->Bitmap):File{
        val out=file()
        ParcelFileDescriptor.open(src,ParcelFileDescriptor.MODE_READ_ONLY).use{fd->
            PdfRenderer(fd).use{renderer->
                PDDocument().use{pdf->
                    for(i in 0 until renderer.pageCount){
                        renderer.openPage(i).use{page->
                            var b=renderPage(page)
                            val changed=if(i==index)transform(b) else b
                            val newPage=PDPage(PDRectangle(page.width.toFloat(),page.height.toFloat()))
                            pdf.addPage(newPage)
                            try{
                                val img=JPEGFactory.createFromImage(pdf,changed,.92f)
                                PDPageContentStream(pdf,newPage).use{
                                    it.drawImage(img,0f,0f,newPage.mediaBox.width,newPage.mediaBox.height)
                                }
                            }finally{
                                if(changed!==b)changed.recycle()
                                b.recycle()
                            }
                        }
                    }
                    pdf.save(out)
                }
            }
        }
        return out
    }

    /** Multi-output actions return one result per produced document. */
    fun run(a:Map<*,*>):List<Map<String,String>> {
        val operation=text(a,"tool")
        val input=source(a)
        require(input.exists()){"Input PDF not found"}
        val output:List<Pair<String,File>> = when(operation){
            "split"->split(input,a)
            "splitText"->splitByText(input,a)
            "splitBookmarks"->splitByBookmarks(input)
            "splitHalf"->splitHalf(input,a)
            "splitSize"->splitBySize(input,a)
            "zip"->zip(input,a)
            "nup"->listOf("n-up" to nup(input,a))
            "ocr"->listOf("searchable" to ocr(input))
            "redact"->listOf("redacted" to redact(input,a))
            "fillSign"->listOf("signed" to fillSign(input,a))
            "workflow"->workflow(input,a)
            else->error("Unsupported advanced PDF operation: $operation")
        }
        return output.map{(name,file)->
            require(file.exists()&&file.length()>0){"PDF operation returned empty output"}
            mapOf("name" to name,"path" to file.absolutePath)
        }
    }
    private fun split(input:File,a:Map<*,*>):List<Pair<String,File>> =
        PDDocument.load(input).use{doc->
            val mode=text(a,"mode","ranges")
            val groups=if(mode=="every") (0 until doc.numberOfPages).map{listOf(it)}
                else text(a,"ranges").split(",").filter{it.isNotBlank()}
                    .map{indices(it,doc.numberOfPages)}
            groups.mapIndexed{index,pages->
                val dest=file();savePages(doc,pages,dest);"part-${index+1}" to dest
            }
        }

    private fun splitByText(input:File,a:Map<*,*>):List<Pair<String,File>> =
        PDDocument.load(input).use{doc->
            val phrase=text(a,"phrase").trim().lowercase()
            require(phrase.isNotEmpty()){"Enter a phrase to split at"}
            val stripper=PDFTextStripper()
            val groups=mutableListOf<MutableList<Int>>()
            var hits=0
            for(i in 0 until doc.numberOfPages){
                stripper.startPage=i+1;stripper.endPage=i+1
                val found=stripper.getText(doc).lowercase().contains(phrase)
                if(found)hits++
                if(groups.isEmpty()||(found&&groups.last().isNotEmpty()))
                    groups.add(mutableListOf())
                groups.last().add(i)
            }
            require(hits>0){"Phrase not found. Try OCR first"}
            groups.mapIndexed{index,pages->
                val out=file();savePages(doc,pages,out);"text-part-${index+1}" to out
            }
        }

    private fun splitByBookmarks(input:File):List<Pair<String,File>> =
        PDDocument.load(input).use{doc->
            val marks=mutableListOf<Pair<String,Int>>()
            var item=doc.documentCatalog.documentOutline?.firstChild
            var visited=0
            while(item!=null && visited++<10000){
                val node=item
                val p=runCatching{node.findDestinationPage(doc)}.getOrNull()
                if(p!=null){
                    val position=doc.pages.indexOf(p)
                    if(position>=0)marks.add((item.title?:"Chapter") to position)
                }
                item=item.nextSibling
            }
            require(marks.isNotEmpty()){"PDF has no top-level bookmarks"}
            val sorted=marks.distinctBy{it.second}.sortedBy{it.second}.toMutableList()
            if(sorted.first().second>0)sorted.add(0,"Front matter" to 0)
            sorted.mapIndexed{index,(title,start)->
                val end=sorted.getOrNull(index+1)?.second?:doc.numberOfPages
                val out=file();savePages(doc,(start until end).toList(),out)
                title to out
            }
        }

    private fun splitHalf(input:File,a:Map<*,*>):List<Pair<String,File>> =
        PDDocument.load(input).use{doc->
            val mode=text(a,"mode","file")
            if(mode=="file"){
                require(doc.numberOfPages>=2){"Need two or more pages"}
                val middle=(doc.numberOfPages+1)/2
                listOf("first-half" to (0 until middle).toList(),
                    "second-half" to (middle until doc.numberOfPages).toList())
                    .map{(name,pages)->
                        val out=file();savePages(doc,pages,out);name to out
                    }
            }else{
                require(mode=="vertical"||mode=="horizontal"){"Invalid split direction"}
                val out=file()
                PDDocument().use{dest->
                    for(p in doc.pages){
                        val original=p.cropBox
                        for(side in 0..1){
                            adopt(dest,p)
                            val copy=dest.getPage(dest.numberOfPages-1)
                            val box=if(mode=="vertical")
                                PDRectangle(original.lowerLeftX+original.width*side/2,
                                    original.lowerLeftY,original.width/2,original.height)
                                else PDRectangle(original.lowerLeftX,
                                    original.lowerLeftY+original.height*(1-side)/2,
                                    original.width,original.height/2)
                            copy.mediaBox=box;copy.cropBox=box
                        }
                    }
                    dest.save(out)
                }
                listOf("sliced" to out)
            }
        }

    private fun splitBySize(input:File,a:Map<*,*>):List<Pair<String,File>> =
        PDDocument.load(input).use{doc->
            val target=(text(a,"maxMB","5").toDoubleOrNull()?:5.0)*1048576.0
            require(target>0){"Specify a positive maximum size"}
            val result=mutableListOf<Pair<String,File>>()
            var group=mutableListOf<Int>()
            var previous:ByteArray?=null
            fun bytesFor(pages:List<Int>):ByteArray {
                PDDocument().use{out->
                    pages.forEach{adopt(out,doc.getPage(it))}
                    return ByteArrayOutputStream().use{stream->out.save(stream);stream.toByteArray()}
                }
            }
            for(i in 0 until doc.numberOfPages){
                val tentative=bytesFor(group+i)
                if(tentative.size>target && group.isNotEmpty()){
                    val out=file();out.writeBytes(requireNotNull(previous))
                    result.add("part-${result.size+1}" to out)
                    group=mutableListOf(i)
                    previous=bytesFor(group)
                } else {
                    group.add(i);previous=tentative
                }
            }
            if(previous!=null){
                val out=file();out.writeBytes(previous!!)
                result.add("part-${result.size+1}" to out)
            }
            result
        }

    private fun zip(input:File,a:Map<*,*>):List<Pair<String,File>> {
        val paths=(a["paths"] as? List<*>)?.filterIsInstance<String>()
            ?.takeIf{it.isNotEmpty()}?:listOf(input.absolutePath)
        val out=file("zip")
        ZipOutputStream(out.outputStream().buffered()).use{zip->
            paths.forEachIndexed{i,p->
                val f=File(p);require(f.exists()){"Cannot find ${f.name}"}
                zip.putNextEntry(ZipEntry("${i+1}_${f.name}"))
                f.inputStream().use{it.copyTo(zip)}
                zip.closeEntry()
            }
        }
        return listOf("pdf-bundle.zip" to out)
    }

    private fun nup(input:File,a:Map<*,*>):File{
        val out=file()
        PdfVectorLayout.nup(input,out,num(a,"perSheet",4),
            a["lines"] as? Boolean?:false)
        return out
    }

    private fun fillSign(input:File,a:Map<*,*>):File {
        val items=(a["items"] as? List<*>)?.filterIsInstance<Map<*,*>>() ?: emptyList()
        require(items.isNotEmpty()){"Add text or a signature"}
        val out=file()
        PDDocument.load(input).use{doc->
            for(item in items){
                val page=(item["page"] as? Number)?.toInt()?:0
                if(page !in 0 until doc.numberOfPages)continue
                val p=doc.getPage(page)
                val box=p.cropBox
                val x=(item["x"] as? Number)?.toFloat()?.coerceIn(0f,1f)?:.1f
                val y=(item["y"] as? Number)?.toFloat()?.coerceIn(0f,1f)?:.1f
                val w=(item["w"] as? Number)?.toFloat()?.coerceIn(.01f,1f)?:.3f
                val h=(item["h"] as? Number)?.toFloat()?.coerceIn(.01f,1f)?:.1f
                val imagePath=item["image"] as? String
                PDPageContentStream(doc,p,PDPageContentStream.AppendMode.APPEND,true,true).use{stream->
                    if(imagePath!=null){
                        val bitmap=BitmapFactory.decodeFile(imagePath)?:error("Signature image missing")
                        try {
                            val embedded=if(imagePath.endsWith(".png",ignoreCase=true))
                                LosslessFactory.createFromImage(doc,bitmap)
                            else JPEGFactory.createFromImage(doc,bitmap,.95f)
                            stream.drawImage(embedded,box.lowerLeftX+x*box.width,
                                box.lowerLeftY+(1-y-h)*box.height,w*box.width,h*box.height)
                        }finally{bitmap.recycle()}
                    }else{
                        val value=(item["text"] as? String).orEmpty()
                            .filter{it.code in 32..126}
                        if(value.isNotBlank()){
                            stream.beginText()
                            stream.setFont(PDType1Font.HELVETICA,14f)
                            stream.setNonStrokingColor(0,0,0)
                            stream.newLineAtOffset(box.lowerLeftX+x*box.width,
                                box.lowerLeftY+(1-y)*box.height)
                            stream.showText(value)
                            stream.endText()
                        }
                    }
                }
            }
            doc.save(out)
        }
        return out
    }

    private fun redact(input:File,a:Map<*,*>):File {
        val marks=(a["boxes"] as? List<*>)?.filterIsInstance<Map<*,*>>()
            ?:error("Select redaction areas")
        require(marks.isNotEmpty()){"Select at least one redaction area"}
        val out=file()
        ParcelFileDescriptor.open(input,ParcelFileDescriptor.MODE_READ_ONLY).use{fd->
            PdfRenderer(fd).use{renderer->
                PDDocument().use{doc->
                    val black=Paint().apply{color=Color.BLACK;style=Paint.Style.FILL}
                    for(i in 0 until renderer.pageCount){
                        renderer.openPage(i).use{p->
                            val bitmap=renderPage(p,3000)
                            try{
                                val canvas=android.graphics.Canvas(bitmap)
                                for(mark in marks){
                                    val target=(mark["page"] as? Number)?.toInt()?:0
                                    if(target!=i)continue
                                    val x=(mark["x"] as? Number)?.toFloat()?:0f
                                    val y=(mark["y"] as? Number)?.toFloat()?:0f
                                    val w=(mark["w"] as? Number)?.toFloat()?:0f
                                    val h=(mark["h"] as? Number)?.toFloat()?:0f
                                    canvas.drawRect(x*bitmap.width,y*bitmap.height,
                                        (x+w)*bitmap.width,(y+h)*bitmap.height,black)
                                }
                                val newPage=PDPage(PDRectangle(p.width.toFloat(),p.height.toFloat()))
                                doc.addPage(newPage)
                                val img=JPEGFactory.createFromImage(doc,bitmap,.95f)
                                PDPageContentStream(doc,newPage).use{
                                    it.drawImage(img,0f,0f,newPage.mediaBox.width,newPage.mediaBox.height)
                                }
                            }finally{bitmap.recycle()}
                        }
                    }
                    doc.documentInformation=PDDocumentInformation()
                    doc.documentCatalog.cosObject.removeItem(COSName.METADATA)
                    doc.save(out)
                }
            }
        }
        return out
    }

    private fun ocr(input:File):File{
        val out=file()
        val recognizer=TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        try {
            ParcelFileDescriptor.open(input,ParcelFileDescriptor.MODE_READ_ONLY).use{fd->
                PdfRenderer(fd).use{renderer->
                    PDDocument.load(input).use{doc->
                        val stripper=PDFTextStripper()
                        for(i in 0 until min(doc.numberOfPages,renderer.pageCount)){
                            stripper.startPage=i+1;stripper.endPage=i+1
                            if(stripper.getText(doc).count{it.isLetterOrDigit()}>100)continue
                            renderer.openPage(i).use{p->
                                val bitmap=renderPage(p,2400)
                                try{
                                    val text=Tasks.await(
                                        recognizer.process(InputImage.fromBitmap(bitmap,0)),
                                        120,TimeUnit.SECONDS)
                                    val page=doc.getPage(i)
                                    val box=page.cropBox
                                    PDPageContentStream(doc,page,PDPageContentStream.AppendMode.APPEND,true,true).use{stream->
                                        stream.setRenderingMode(RenderingMode.NEITHER)
                                        stream.setFont(PDType1Font.HELVETICA,10f)
                                        for(block in text.textBlocks)for(line in block.lines){
                                            val rect=line.boundingBox?:continue
                                            val clean=line.text.filter{it.code in 32..126}
                                            if(clean.isEmpty())continue
                                            val x=box.lowerLeftX+rect.left.toFloat()/bitmap.width*box.width
                                            val y=box.lowerLeftY+(1f-rect.bottom.toFloat()/bitmap.height)*box.height
                                            stream.beginText()
                                            stream.newLineAtOffset(x,y)
                                            stream.showText(clean)
                                            stream.endText()
                                        }
                                    }
                                }finally{bitmap.recycle()}
                            }
                        }
                        doc.save(out)
                    }
                }
            }
            return out
        } finally{recognizer.close()}
    }

    private fun workflow(input:File,a:Map<*,*>):List<Pair<String,File>>{
        val steps=(a["steps"] as? List<*>)?.filterIsInstance<Map<*,*>>()?:emptyList()
        require(steps.isNotEmpty()){"Choose workflow steps"}
        // Each step consumes its predecessors' outputs, including multi-results.
        var results=listOf("input" to input)
        for(step in steps){
            val id=step["tool"] as? String?:error("Workflow step has no tool")
            require(id!="workflow" && id!="scan" && id!="password" && id!="unlock")
            val next=mutableListOf<Pair<String,File>>()
            for((_,f) in results){
                val options=HashMap<Any?,Any?>(step)
                options["path"]=f.absolutePath
                options["tool"]=id
                val advanced=setOf("split","splitText","splitBookmarks",
                    "splitHalf","splitSize","zip","nup","ocr","redact","fillSign")
                if(id in advanced){
                    next.addAll(run(options).map{
                        it.getValue("name") to File(it.getValue("path"))
                    })
                }else{
                    next.add(id to File(simple(options)))
                }
            }
            for((_,f) in results)if(f!=input)f.delete()
            results=next
        }
        return results
    }
}
