package com.example.file_share

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.encryption.AccessPermission
import com.tom_roush.pdfbox.pdmodel.encryption.StandardProtectionPolicy
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.pdmodel.PDDocumentInformation
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSStream
import com.tom_roush.pdfbox.cos.COSArray
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.math.min
import kotlin.math.max

/** Android-only bridge. No dependency is referenced from desktop targets.
 * MIT reference: sammyZi/pdf-tools (LICENSE retained in third_party).
 * All file edits write fresh files, never overwrite user originals.
 */
class AdvancedPdfBridge(private val context: Context) {
    private val executor = Executors.newSingleThreadExecutor()
    private val advanced by lazy { PdfAdvancedOperations(context) }
    private val scanner by lazy { AndroidDocumentScanner(context) }
    init { PDFBoxResourceLoader.init(context) }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
        executor.execute {
            try {
                val output: Any? = when(call.method) {
                    "countPages" -> PDDocument.load(File(required(args,"path"))).use { it.numberOfPages }
                    "renderPage" -> render(required(args,"path"), number(args,"page",0), number(args,"width",900))
                    "process" -> process(args)
                    "fromImages" -> fromImages(args)
                    "processMany" -> advanced.run(args)
                    "detectDocument" -> scanner.corners(required(args,"path"))
                    "processScan" -> scanner.process(required(args,"path"),args)
                    else -> throw IllegalArgumentException("Unsupported PDF method: ${call.method}")
                }
                android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(output) }
            } catch(e: Exception) {
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    result.error("PDF_PROCESSING", e.message ?: "PDF processing failed", null)
                }
            }
        }
    }
    private fun required(a:Map<*,*>, k:String):String =
        (a[k] as? String)?.takeIf{it.isNotBlank()} ?: error("Missing $k")
    private fun number(a:Map<*,*>, k:String, default:Int)= (a[k] as? Number)?.toInt()?:default
    private fun select(a:Map<*,*>,k:String,default:String="")=a[k] as? String ?: default
    private fun temporary(ext:String="pdf"):File =
        File.createTempFile("fileshare_pdf_",".$ext",context.cacheDir)

    private fun render(path:String,page:Int,width:Int):ByteArray {
        val file=File(path)
        ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
            PdfRenderer(pfd).use { pdf ->
                require(page in 0 until pdf.pageCount) { "Invalid page" }
                pdf.openPage(page).use { p ->
                    val w=width.coerceIn(300,1800)
                    val h=max(1,(p.height.toDouble()*w/p.width).toInt())
                    val bitmap=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        p.render(bitmap,null,null,PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        return ByteArrayOutputStream().use { out ->
                            bitmap.compress(Bitmap.CompressFormat.PNG,85,out)
                            out.toByteArray()
                        }
                    } finally { bitmap.recycle() }
                }
            }
        }
    }
    private fun process(a:Map<*,*>):String {
        val mode=required(a,"tool")
        val path=required(a,"path")
        val output=temporary(if(mode=="zip")"zip" else "pdf")
        try{
            when(mode){
                "merge","alternate" -> combine(a,output,mode=="alternate")
                "split","currentPage","extract" -> extract(path,a,output)
                "rotate" -> rotate(path,a,output)
                "organize" -> organize(path,a,output)
                "watermark" -> watermark(path,a,output)
                "pageNumbers" -> pageNumbers(path,a,output)
                "metadata" -> metadata(path,a,output)
                "password" -> password(path,a,output)
                "unlock" -> unlock(path,a,output)
                "splitText" -> splitText(path,a,output)
                "crop" -> crop(path,a,output)
                "zip" -> zipPdf(path,output)
                "compress" -> compress(path,a,output)
                "flip" -> flip(path,a,output)
                "splitHalf" -> splitHalf(path,a,output)
                "splitBookmarks" -> splitBookmarks(path,a,output)
                "splitSize" -> splitSize(path,a,output)
                "fillSign" -> fillSign(path,a,output)
                else -> error("This tool's Android processing engine is not available yet: $mode")
            }
            require(output.exists() && output.length()>0){"PDF engine produced an empty output"}
            return output.path
        } catch(e:Exception){ output.delete();throw e }
    }
    // Adapted from upstream Pdf.kt adopt(): inherited Resources can otherwise
    // disappear when a page is copied to a different PDF page tree.
    private fun adopt(out:PDDocument, source:PDPage){
        val next=out.importPage(source)
        if(!next.cosObject.containsKey(COSName.RESOURCES))
            next.resources=source.resources?:PDResources()
    }

    private fun combine(a:Map<*,*>,dest:File,alternate:Boolean){
        val paths=(a["paths"] as? List<*>)?.filterIsInstance<String>()
            ?.takeIf{it.isNotEmpty()} ?: listOf(required(a,"path"))
        val sources=paths.map { PDDocument.load(File(it)) }
        try{
            PDDocument().use { out ->
                if(alternate){
                    val maxPages=sources.maxOf{it.numberOfPages}
                    for(i in 0 until maxPages)for(src in sources)
                        if(i<src.numberOfPages)adopt(out,src.getPage(i))
                }else for(src in sources)for(p in src.pages)adopt(out,p)
                require(out.numberOfPages>0){"No pages"}
                out.save(dest)
            }
        }finally{sources.forEach{it.close()}}
    }
    private fun pages(doc:PDDocument, a:Map<*,*>):List<Int>{
        val raw=select(a,"pages")
        if(raw.isBlank())return (0 until doc.numberOfPages).toList()
        val indices=linkedSetOf<Int>()
        raw.split(',').forEach { token ->
            val parts=token.trim().split('-')
            val first=parts.firstOrNull()?.trim()?.toIntOrNull()
                ?: error("Invalid page range")
            val last=if(parts.size==1)first
                else parts.getOrNull(1)?.trim()?.takeIf{it.isNotEmpty()}?.toIntOrNull()?:doc.numberOfPages
            require(first>=1 && last in first..doc.numberOfPages){"Page range outside PDF"}
            for(i in first..last)indices.add(i-1)
        }
        return indices.toList()
    }
    private fun extract(path:String,a:Map<*,*>,dest:File){
        PDDocument.load(File(path)).use { doc ->
            val selected=if(select(a,"tool")=="currentPage")
                listOf(number(a,"page",0)) else pages(doc,a)
            require(selected.isNotEmpty()){"Select at least one page"}
            PDDocument().use { out ->
                selected.forEach{ require(it in 0 until doc.numberOfPages){"Invalid page"};adopt(out,doc.getPage(it)) }
                out.save(dest)
            }
        }
    }
    private fun rotate(path:String,a:Map<*,*>,dest:File){
        PDDocument.load(File(path)).use{ doc->
            val n=number(a,"degrees",90)
            require(n%90==0){"Rotation must be multiple of 90"}
            for(i in pages(doc,a)){val p=doc.getPage(i);p.rotation=(p.rotation+n+360)%360}
            doc.save(dest)
        }
    }
    private fun organize(path:String,a:Map<*,*>,dest:File){
        PDDocument.load(File(path)).use { doc ->
            val selection=pages(doc,a)
            val deleted=(a["deletePages"] as? List<*>)?.mapNotNull{(it as? Number)?.toInt()}?.toSet()?:emptySet()
            PDDocument().use { out ->
                selection.filterNot{it in deleted}.forEach{adopt(out,doc.getPage(it))}
                require(out.numberOfPages>0){"Cannot delete every page"}
                out.save(dest)
            }
        }
    }
    private fun watermark(path:String,a:Map<*,*>,dest:File){
        val text=select(a,"text","DRAFT").take(100).filter{it.code in 32..126}
        require(text.isNotEmpty()){"Watermark text is required"}
        PDDocument.load(File(path)).use { doc ->
            for(p in doc.pages){
                val box=p.cropBox;val size=min(box.width,box.height)/12
                PDPageContentStream(doc,p,PDPageContentStream.AppendMode.APPEND,true,true).use{ stream ->
                    stream.beginText()
                    stream.setFont(PDType1Font.HELVETICA_BOLD,size)
                    stream.setNonStrokingColor(180,170,190)
                    stream.newLineAtOffset(box.lowerLeftX+box.width*.18f,box.lowerLeftY+box.height*.5f)
                    stream.showText(text)
                    stream.endText()
                }
            }
            doc.save(dest)
        }
    }
    private fun pageNumbers(path:String,a:Map<*,*>,dest:File){
        PDDocument.load(File(path)).use { doc ->
            for(i in 0 until doc.numberOfPages){
                val p=doc.getPage(i);val box=p.cropBox
                PDPageContentStream(doc,p,PDPageContentStream.AppendMode.APPEND,true,true).use{stream->
                    stream.beginText()
                    stream.setFont(PDType1Font.HELVETICA,11f)
                    stream.setNonStrokingColor(0,0,0)
                    stream.newLineAtOffset(box.lowerLeftX+box.width/2,box.lowerLeftY+18f)
                    stream.showText("${i+1}")
                    stream.endText()
                }
            }
            doc.save(dest)
        }
    }
    private fun metadata(path:String,a:Map<*,*>,dest:File){
        PDDocument.load(File(path)).use { doc ->
            val i=doc.documentInformation
            i.title=select(a,"title");i.author=select(a,"author")
            i.subject=select(a,"subject");i.keywords=select(a,"keywords")
            doc.documentInformation=i
            doc.save(dest)
        }
    }
    private fun password(path:String,a:Map<*,*>,dest:File){
        val value=required(a,"password")
        PDDocument.load(File(path)).use { doc ->
            require(!doc.isEncrypted){"This PDF is already protected"}
            doc.protect(StandardProtectionPolicy(value,value,AccessPermission()).apply{
                encryptionKeyLength=256
            })
            doc.save(dest)
        }
    }
    private fun unlock(path:String,a:Map<*,*>,dest:File){
        PDDocument.load(File(path),required(a,"password")).use { doc ->
            doc.isAllSecurityToBeRemoved=true
            doc.save(dest)
        }
    }
    private fun splitText(path:String,a:Map<*,*>,dest:File){
        val phrase=required(a,"text").lowercase()
        PDDocument.load(File(path)).use { doc ->
            val stripper=PDFTextStripper()
            val first=(0 until doc.numberOfPages).firstOrNull{
                stripper.startPage=it+1;stripper.endPage=it+1
                stripper.getText(doc).lowercase().contains(phrase)
            }?:error("Phrase not found. OCR this document first.")
            PDDocument().use{ out ->
                for(i in first until doc.numberOfPages)adopt(out,doc.getPage(i))
                out.save(dest)
            }
        }
    }
    private fun crop(path:String,a:Map<*,*>,dest:File){
        PDDocument.load(File(path)).use{doc->
            val left=(a["left"] as? Number)?.toFloat()?:0f
            val top=(a["top"] as? Number)?.toFloat()?:0f
            val right=(a["right"] as? Number)?.toFloat()?:1f
            val bottom=(a["bottom"] as? Number)?.toFloat()?:1f
            require(left>=0&&top>=0&&right<=1&&bottom<=1&&right>left&&bottom>top)
            for(i in pages(doc,a)){
                val p=doc.getPage(i);val box=p.cropBox
                p.cropBox=PDRectangle(box.lowerLeftX+left*box.width,
                    box.lowerLeftY+(1-bottom)*box.height,
                    (right-left)*box.width,(bottom-top)*box.height)
            }
            doc.save(dest)
        }
    }
    private fun zipPdf(path:String,dest:File){
        ZipOutputStream(dest.outputStream().buffered()).use { zip ->
            zip.putNextEntry(ZipEntry(File(path).name))
            File(path).inputStream().use{it.copyTo(zip)}
            zip.closeEntry()
        }
    }

    private fun compress(path:String,a:Map<*,*>,dest:File) {
        val quality=number(a,"quality",60).coerceIn(20,95)
        PDDocument.load(File(path)).use { doc ->
            for(obj in doc.document.objects) {
                val stream=obj.getObject() as? COSStream ?: continue
                if(stream.getCOSName(COSName.SUBTYPE)!=COSName.IMAGE)continue
                val filter=stream.getDictionaryObject(COSName.FILTER)
                val jpeg=filter==COSName.DCT_DECODE ||
                    (filter is COSArray && filter.size()==1 &&
                    filter.getObject(0)==COSName.DCT_DECODE)
                if(!jpeg)continue
                try {
                    val raw=stream.createRawInputStream().use{it.readBytes()}
                    val bitmap=BitmapFactory.decodeByteArray(raw,0,raw.size)?:continue
                    val output=ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.JPEG,quality,output)
                    bitmap.recycle()
                    val next=output.toByteArray()
                    if(next.size>=raw.size)continue
                    stream.createRawOutputStream().use{it.write(next)}
                    stream.setItem(COSName.FILTER,COSName.DCT_DECODE)
                    stream.setItem(COSName.COLORSPACE,COSName.DEVICERGB)
                    stream.setInt(COSName.BITS_PER_COMPONENT,8)
                    stream.removeItem(COSName.DECODE_PARMS)
                }catch(_:Exception){ /* retain unsupported image encodings */ }
            }
            doc.save(dest)
        }
        // Never return a needlessly larger file.
        if(dest.length()>=File(path).length())File(path).copyTo(dest,overwrite=true)
    }

    private fun fromImages(a:Map<*,*>):String {
        val paths=(a["paths"] as? List<*>)?.filterIsInstance<String>()
            ?.takeIf{it.isNotEmpty()}?:error("Choose document photos")
        val mode=select(a,"mode","Document")
        val dest=temporary()
        try {
            PDDocument().use{doc->
                val photos=paths.map{p->
                    BitmapFactory.decodeFile(p)?:error("Cannot read photo: $p")
                }
                try {
                    val frames=if(mode=="Book")photos.flatMap{image->
                        val mid=image.width/2
                        listOf(Bitmap.createBitmap(image,0,0,mid,image.height),
                            Bitmap.createBitmap(image,mid,0,image.width-mid,image.height))
                    }else photos
                    try{
                        if(mode=="ID Card"){
                            for(group in frames.chunked(2)){
                                val page=PDPage(PDRectangle.A4)
                                doc.addPage(page)
                                PDPageContentStream(doc,page).use{stream->
                                    group.forEachIndexed{slot,img->
                                        val maxW=page.mediaBox.width-80
                                        val maxH=page.mediaBox.height/2-70
                                        val factor=min(maxW/img.width,maxH/img.height)
                                        val w=img.width*factor;val h=img.height*factor
                                        val x=(page.mediaBox.width-w)/2
                                        val y=page.mediaBox.height-(slot+1)*page.mediaBox.height/2+(
                                            page.mediaBox.height/2-h)/2
                                        val image=JPEGFactory.createFromImage(doc,img,.92f)
                                        stream.drawImage(image,x,y,w,h)
                                    }
                                }
                            }
                        }else {
                            for(bmp in frames){
                                val paper=if(mode=="Business Card")
                                    PDRectangle(252f,144f) else PDRectangle.A4
                                val page=PDPage(paper)
                                doc.addPage(page)
                                val image=JPEGFactory.createFromImage(doc,bmp,.93f)
                                val width=paper.width;val height=paper.height
                                val margin=if(mode=="Business Card")5f else 12f
                                val factor=min((width-margin*2)/bmp.width,
                                    (height-margin*2)/bmp.height)
                                val dw=bmp.width*factor;val dh=bmp.height*factor
                                PDPageContentStream(doc,page).use{
                                    it.drawImage(image,(width-dw)/2,(height-dh)/2,dw,dh)
                                }
                            }
                        }
                    }finally{
                        if(mode=="Book")frames.forEach{it.recycle()}
                    }
                }finally{photos.forEach{it.recycle()}}
                doc.save(dest)
            }
            return dest.path
        }catch(e:Exception){dest.delete();throw e}
    }

    private fun splitHalf(path:String,a:Map<*,*>,dest:File) {
        PDDocument.load(File(path)).use{doc->
            require(doc.numberOfPages>=2){"Need at least two pages"}
            val start=number(a,"half",0).coerceIn(0,1)
            val half=(doc.numberOfPages+1)/2
            val range=if(start==0)0 until half else half until doc.numberOfPages
            PDDocument().use{out->
                for(i in range)adopt(out,doc.getPage(i))
                out.save(dest)
            }
        }
    }

    private fun splitBookmarks(path:String,a:Map<*,*>,dest:File) {
        PDDocument.load(File(path)).use{doc->
            var bookmark=doc.documentCatalog.documentOutline?.firstChild
            val marks=mutableListOf<Int>()
            while(bookmark!=null){
                bookmark.findDestinationPage(doc)?.let{p->
                    val index=doc.pages.indexOf(p)
                    if(index>=0)marks.add(index)
                }
                bookmark=bookmark.nextSibling
            }
            require(marks.isNotEmpty()){"PDF has no top-level bookmarks"}
            val start=marks.distinct().sorted().first()
            PDDocument().use{out->
                for(i in start until doc.numberOfPages)adopt(out,doc.getPage(i))
                out.save(dest)
            }
        }
    }

    private fun splitSize(path:String,a:Map<*,*>,dest:File) {
        // Single result is the largest leading segment that fits. The
        // multi-part mode will require a list-output API in a later stage.
        val limit=number(a,"maxMB",5).coerceAtLeast(1)*1024L*1024L
        PDDocument.load(File(path)).use{doc->
            PDDocument().use{out->
                var last:ByteArray?=null
                for(page in doc.pages){
                    adopt(out,page)
                    val bytes=ByteArrayOutputStream().use{stream->
                        out.save(stream);stream.toByteArray()
                    }
                    if(bytes.size>limit && last!=null)break
                    last=bytes
                }
                require(last!=null){"Cannot split PDF by that size"}
                dest.writeBytes(last)
            }
        }
    }

    private fun fillSign(path:String,a:Map<*,*>,dest:File) {
        val text=required(a,"text").filter{it.code in 32..126}
        require(text.isNotEmpty()){"Enter supported text to place"}
        PDDocument.load(File(path)).use{doc->
            val index=number(a,"page",0)
            require(index in 0 until doc.numberOfPages)
            val p=doc.getPage(index)
            val b=p.cropBox
            PDPageContentStream(doc,p,PDPageContentStream.AppendMode.APPEND,true,true).use{stream->
                stream.beginText()
                stream.setFont(PDType1Font.HELVETICA,14f)
                stream.setNonStrokingColor(0,0,0)
                stream.newLineAtOffset(b.lowerLeftX+30f,b.lowerLeftY+b.height*.55f)
                stream.showText(text)
                stream.endText()
            }
            doc.save(dest)
        }
    }

    private fun flip(path:String,a:Map<*,*>,dest:File) {
        // Re-render each page into a new image-backed PDF to ensure the page
        // is visually mirrored. Users should know selectable text is lost.
        val vertical=select(a,"axis","h")=="v"
        val input=File(path)
        ParcelFileDescriptor.open(input,ParcelFileDescriptor.MODE_READ_ONLY).use{fd->
            PdfRenderer(fd).use{renderer->
                PDDocument().use{doc->
                    for(i in 0 until renderer.pageCount){
                        renderer.openPage(i).use{page->
                            val bitmap=Bitmap.createBitmap(page.width*2,page.height*2,Bitmap.Config.ARGB_8888)
                            try {
                                bitmap.eraseColor(Color.WHITE)
                                page.render(bitmap,null,null,PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                                val matrix=android.graphics.Matrix().apply{
                                    if(vertical)postScale(1f,-1f)else postScale(-1f,1f)
                                }
                                val mirror=Bitmap.createBitmap(bitmap,0,0,bitmap.width,bitmap.height,matrix,true)
                                try{
                                    val p=PDPage(PDRectangle(page.width.toFloat(),page.height.toFloat()))
                                    doc.addPage(p)
                                    val img=JPEGFactory.createFromImage(doc,mirror,0.9f)
                                    PDPageContentStream(doc,p).use{it.drawImage(img,0f,0f,p.mediaBox.width,p.mediaBox.height)}
                                }finally{mirror.recycle()}
                            }finally{bitmap.recycle()}
                        }
                    }
                    doc.save(dest)
                }
            }
        }
    }
}
