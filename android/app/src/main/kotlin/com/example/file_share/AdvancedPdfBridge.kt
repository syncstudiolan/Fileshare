package com.example.file_share

import android.content.Context
import android.graphics.Bitmap
import android.graphics.YuvImage
import android.graphics.ImageFormat
import android.graphics.Rect
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
import com.tom_roush.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState
import com.tom_roush.pdfbox.util.Matrix
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
    private val advanced by lazy { PdfAdvancedOperations(context){ args -> process(args) } }
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
                    "detectFrame" -> detectFrame(args)
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

    private fun detectFrame(a:Map<*,*>):List<Double>? {
        val bytes=a["bytes"] as? ByteArray?:return null
        val width=number(a,"width",0)
        val height=number(a,"height",0)
        require(width>0&&height>0&&width*height*3L/2<=bytes.size){
            "Camera frame does not contain NV21 data"
        }
        val compressed=ByteArrayOutputStream()
        YuvImage(bytes,ImageFormat.NV21,width,height,null).compressToJpeg(
            Rect(0,0,width,height),65,compressed)
        val original=BitmapFactory.decodeByteArray(compressed.toByteArray(),0,
            compressed.size())?:return null
        val rotation=number(a,"rotation",0)%360
        val oriented=if(rotation==0)original else Bitmap.createBitmap(
            original,0,0,original.width,original.height,
            android.graphics.Matrix().apply{postRotate(rotation.toFloat())},true)
        val file=temporary("jpg")
        return try{
            file.outputStream().use{oriented.compress(Bitmap.CompressFormat.JPEG,75,it)}
            scanner.corners(file.absolutePath)
        }finally{
            file.delete()
            if(oriented!==original)oriented.recycle()
            original.recycle()
        }
    }

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
                    val reverse=a["reverse"] as? Boolean?:false
                    val maxPages=sources.maxOf{it.numberOfPages}
                    for(i in 0 until maxPages)for((index,src) in sources.withIndex()){
                        if(i<src.numberOfPages){
                            val p=if(reverse&&index>0)src.numberOfPages-i-1 else i
                            adopt(out,src.getPage(p))
                        }
                    }
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
        val text=select(a,"text","DRAFT").trim().take(100).filter{it.code in 32..126}
        require(text.isNotEmpty()){"Watermark text is required"}
        val opacity=(a["opacity"] as? Number)?.toFloat()?.coerceIn(.05f,1f)?:.2f
        PDDocument.load(File(path)).use{ doc->
            val font=PDType1Font.HELVETICA_BOLD
            for(p in doc.pages){
                val box=p.cropBox
                val scale=(a["scale"] as? Number)?.toFloat()?.coerceIn(.5f,2f)?:1f
                val size=min(box.width,box.height)/10f*scale
                val width=font.getStringWidth(text)/1000f*size
                val rad=Math.toRadians(-32.0)
                val x=box.lowerLeftX+box.width/2-
                    (kotlin.math.cos(rad)*width/2).toFloat()
                val y=box.lowerLeftY+box.height/2-
                    (kotlin.math.sin(rad)*width/2).toFloat()
                PDPageContentStream(doc,p,PDPageContentStream.AppendMode.APPEND,true,true).use{stream->
                    stream.saveGraphicsState()
                    stream.setGraphicsStateParameters(PDExtendedGraphicsState().apply{
                        nonStrokingAlphaConstant=opacity
                        strokingAlphaConstant=opacity
                    })
                    stream.setNonStrokingColor(.82f,.27f,.17f)
                    stream.beginText()
                    stream.setFont(font,size)
                    stream.setTextMatrix(Matrix.getRotateInstance(rad,x,y))
                    stream.showText(text)
                    stream.endText()
                    stream.restoreGraphicsState()
                }
            }
            doc.save(dest)
        }
    }
    private fun pageNumbers(path:String,a:Map<*,*>,dest:File){
        val position=select(a,"position","center")
        val format=select(a,"format","n")
        PDDocument.load(File(path)).use{doc->
            val font=PDType1Font.HELVETICA
            val count=doc.numberOfPages
            for(i in 0 until count){
                val page=doc.getPage(i);val box=page.cropBox
                val rotation=((page.rotation%360)+360)%360
                val (displayW,displayH)=if(rotation%180!=0)
                    box.height to box.width else box.width to box.height
                val label=if(format=="of")"Page ${i+1} of $count" else "${i+1}"
                val textWidth=font.getStringWidth(label)/1000f*10f
                val left=when(position){
                    "left"->28f
                    "right"->displayW-28f-textWidth
                    else->(displayW-textWidth)/2f
                }
                val x=left/displayW
                val y=(displayH-20f-10f*.79f)/displayH
                val h=10f*.79f/displayH
                val fractions=when(rotation){
                    90->listOf(y,x,h,0f)
                    180->listOf(1f-x,y,0f,h)
                    270->listOf(1f-y-h,1f-x,h,0f)
                    else->listOf(x,1f-y-h,0f,h)
                }
                val startX=fractions[0]*box.width
                val startY=fractions[1]*box.height
                val rw=fractions[2]*box.width
                val rh=fractions[3]*box.height
                val originX=when(rotation){90,180->startX+rw;else->startX}
                val originY=when(rotation){180,270->startY+rh;else->startY}
                PDPageContentStream(doc,page,PDPageContentStream.AppendMode.APPEND,true,true).use{stream->
                    stream.beginText()
                    stream.setFont(font,10f)
                    stream.setNonStrokingColor(.2f,.2f,.2f)
                    stream.setTextMatrix(Matrix.getRotateInstance(
                        Math.toRadians(rotation.toDouble()),
                        box.lowerLeftX+originX,box.lowerLeftY+originY))
                    stream.showText(label)
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
        if(select(a,"mode","crop")=="resize"){
            PdfVectorLayout.resize(File(path),dest,select(a,"size","A4"))
            return
        }
        PDDocument.load(File(path)).use{doc->
            val left=(a["left"] as? Number)?.toFloat()?:0f
            val top=(a["top"] as? Number)?.toFloat()?:0f
            val right=(a["right"] as? Number)?.toFloat()?:1f
            val bottom=(a["bottom"] as? Number)?.toFloat()?:1f
            require(left>=0&&top>=0&&right<=1&&bottom<=1&&right>left&&bottom>top)
            for(i in pages(doc,a)){
                val p=doc.getPage(i);val box=p.cropBox
                val x=left;val y=top;val w=right-left;val h=bottom-top
                val rot=((p.rotation%360)+360)%360
                val fractions=when(rot){
                    90->listOf(y,x,h,w)
                    180->listOf(1f-x-w,y,w,h)
                    270->listOf(1f-y-h,1f-x-w,h,w)
                    else->listOf(x,1f-y-h,w,h)
                }
                p.cropBox=PDRectangle(
                    box.lowerLeftX+fractions[0]*box.width,
                    box.lowerLeftY+fractions[1]*box.height,
                    fractions[2]*box.width,fractions[3]*box.height)
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
        val mode=select(a,"mode","quality")
        if(mode!="size"){
            compressQuality(path,dest,number(a,"quality",60).coerceIn(20,95),0)
            return
        }
        val target=((a["targetMB"] as? String)?.toDoubleOrNull()
            ?:((a["targetMB"] as? Number)?.toDouble()?:2.0))*1048576.0
        require(target>0){"Target file size must be positive"}
        val steps=listOf(80 to 0,60 to 2400,45 to 2000,
            35 to 1600,25 to 1200,20 to 900)
        var bestBytes=File(path).readBytes()
        for((quality,side) in steps){
            val candidate=temporary()
            try{
                compressQuality(path,candidate,quality,side)
                val bytes=candidate.readBytes()
                if(bytes.size<bestBytes.size)bestBytes=bytes
                if(bytes.size<=target){dest.writeBytes(bytes);return}
            }finally{candidate.delete()}
        }
        dest.writeBytes(bestBytes)
    }
    private fun compressQuality(path:String,dest:File,quality:Int,maxSide:Int) {
        PDDocument.load(File(path)).use{doc->
            for(obj in doc.document.objects){
                val stream=obj.getObject() as? COSStream?:continue
                if(stream.getCOSName(COSName.SUBTYPE)!=COSName.IMAGE)continue
                val filter=stream.getDictionaryObject(COSName.FILTER)
                val jpeg=filter==COSName.DCT_DECODE||
                    (filter is COSArray&&filter.size()==1&&
                    filter.getObject(0)==COSName.DCT_DECODE)
                if(!jpeg)continue
                try{
                    val raw=stream.createRawInputStream().use{it.readBytes()}
                    val meta=BitmapFactory.Options().apply{inJustDecodeBounds=true}
                    BitmapFactory.decodeByteArray(raw,0,raw.size,meta)
                    if(meta.outWidth<=0||meta.outHeight<=0)continue
                    var sample=1
                    if(maxSide>0){
                        while(max(meta.outWidth,meta.outHeight)/sample>maxSide*2)sample*=2
                    }
                    val bitmap=BitmapFactory.decodeByteArray(raw,0,raw.size,
                        BitmapFactory.Options().apply{inSampleSize=sample})?:continue
                    val resized=if(maxSide>0&&max(bitmap.width,bitmap.height)>maxSide){
                        val factor=maxSide.toFloat()/max(bitmap.width,bitmap.height)
                        Bitmap.createScaledBitmap(bitmap,
                            max(1,(bitmap.width*factor).toInt()),
                            max(1,(bitmap.height*factor).toInt()),true)
                    }else bitmap
                    try{
                        val bytes=ByteArrayOutputStream().use{out->
                            resized.compress(Bitmap.CompressFormat.JPEG,quality,out)
                            out.toByteArray()
                        }
                        if(bytes.size>=raw.size)continue
                        stream.createRawOutputStream().use{it.write(bytes)}
                        stream.setItem(COSName.FILTER,COSName.DCT_DECODE)
                        stream.setItem(COSName.COLORSPACE,COSName.DEVICERGB)
                        stream.setInt(COSName.BITS_PER_COMPONENT,8)
                        stream.setInt(COSName.WIDTH,resized.width)
                        stream.setInt(COSName.HEIGHT,resized.height)
                        stream.removeItem(COSName.DECODE)
                        stream.removeItem(COSName.DECODE_PARMS)
                    }finally{
                        if(resized!==bitmap)resized.recycle()
                        bitmap.recycle()
                    }
                }catch(_:Exception){/* Preserve unusual JPEG streams as-is. */}
            }
            doc.documentCatalog.cosObject.removeItem(COSName.METADATA)
            doc.save(dest)
        }
        if(dest.length()>=File(path).length())
            File(path).copyTo(dest,overwrite=true)
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
        PdfVectorLayout.flip(File(path),dest,select(a,"axis","h"))
    }

}
