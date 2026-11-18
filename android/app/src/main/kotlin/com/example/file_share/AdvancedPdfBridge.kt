package com.example.file_share

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
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
    init { PDFBoxResourceLoader.init(context) }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
        executor.execute {
            try {
                val output: Any? = when(call.method) {
                    "countPages" -> PDDocument.load(File(required(args,"path"))).use { it.numberOfPages }
                    "renderPage" -> render(required(args,"path"), number(args,"page",0), number(args,"width",900))
                    "process" -> process(args)
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
                else -> error("This tool's Android processing engine is not available yet: $mode")
            }
            require(output.exists() && output.length()>0){"PDF engine produced an empty output"}
            return output.path
        } catch(e:Exception){ output.delete();throw e }
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
                        if(i<src.numberOfPages)out.importPage(src.getPage(i))
                }else for(src in sources)for(p in src.pages)out.importPage(p)
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
                selected.forEach{ require(it in 0 until doc.numberOfPages){"Invalid page"};out.importPage(doc.getPage(it)) }
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
                selection.filterNot{it in deleted}.forEach{out.importPage(doc.getPage(it))}
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
                    stream.setNonStrokingColor(Color.BLACK)
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
                for(i in first until doc.numberOfPages)out.importPage(doc.getPage(i))
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
    private fun compress(path:String,a:Map<*,*>,dest:File){
        // Conservative lossless re-save. Deliberately not advertised as
        // JPEG recompression until image-stream tests are in place.
        PDDocument.load(File(path)).use{doc->doc.save(dest)}
    }
}
