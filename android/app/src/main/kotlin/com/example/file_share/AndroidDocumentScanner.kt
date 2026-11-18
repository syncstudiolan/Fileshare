package com.example.file_share

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.io.File
import java.util.UUID
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * On-device scanner: OpenCV quadrilateral detection and perspective correction,
 * plus low-latency preview and full-quality final JPEG.
 * Camera capture itself stays in the Flutter application (image_picker).
 */
internal class AndroidDocumentScanner(private val context:Context) {
    private val ready by lazy { OpenCVLoader.initLocal() }
    private fun ensure(){require(ready){"OpenCV initialization failed"}}
    private fun load(path:String,maxSize:Int):Bitmap {
        val opt=BitmapFactory.Options().apply{inJustDecodeBounds=true}
        BitmapFactory.decodeFile(path,opt)
        val longest=max(opt.outWidth,opt.outHeight)
        require(longest>0){"Document photo cannot be decoded"}
        var sample=1
        while(longest/sample>maxSize*2)sample*=2
        val decoded=BitmapFactory.decodeFile(path,BitmapFactory.Options().apply{
            inSampleSize=sample
            inPreferredConfig=Bitmap.Config.ARGB_8888
        })?:error("Invalid document image")
        if(max(decoded.width,decoded.height)<=maxSize)return decoded
        val scale=maxSize.toDouble()/max(decoded.width,decoded.height)
        return Bitmap.createScaledBitmap(decoded,
            max(1,(decoded.width*scale).roundToInt()),
            max(1,(decoded.height*scale).roundToInt()),true).also{decoded.recycle()}
    }
    private fun order(pts:Array<Point>):Array<Point> {
        val sorted=pts.sortedWith(compareBy<Point>{it.x+it.y})
        val tl=sorted.first();val br=sorted.last()
        val rest=pts.filter{it!==tl&&it!==br}
        val tr=rest.minByOrNull{it.y-it.x}?:rest.first()
        val bl=rest.first{it!==tr}
        return arrayOf(tl,tr,br,bl)
    }
    fun corners(path:String):List<Double>?{
        ensure()
        val bitmap=load(path,1000)
        val rgba=Mat();Utils.bitmapToMat(bitmap,rgba);bitmap.recycle()
        val gray=Mat();val blur=Mat();val edges=Mat();val hierarchy=Mat()
        val contours=ArrayList<MatOfPoint>()
        try{
            Imgproc.cvtColor(rgba,gray,Imgproc.COLOR_RGBA2GRAY)
            Imgproc.GaussianBlur(gray,blur,Size(5.0,5.0),0.0)
            Imgproc.Canny(blur,edges,40.0,130.0)
            Imgproc.dilate(edges,edges,Imgproc.getStructuringElement(
                Imgproc.MORPH_RECT,Size(3.0,3.0)))
            Imgproc.findContours(edges,contours,hierarchy,
                Imgproc.RETR_LIST,Imgproc.CHAIN_APPROX_SIMPLE)
            val limit=rgba.width()*rgba.height()*.15
            val candidates=contours.sortedByDescending{Imgproc.contourArea(it)}
            for(contour in candidates.take(35)){
                if(Imgproc.contourArea(contour)<limit)break
                val curve=MatOfPoint2f(*contour.toArray())
                val approx=MatOfPoint2f()
                try{
                    Imgproc.approxPolyDP(curve,approx,
                        .025*Imgproc.arcLength(curve,true),true)
                    if(approx.total()!=4L)continue
                    val poly=MatOfPoint(*approx.toArray())
                    val convex=Imgproc.isContourConvex(poly)
                    poly.release()
                    if(!convex)continue
                    val p=order(approx.toArray())
                    return p.flatMap{listOf(
                        (it.x/rgba.width()).coerceIn(0.0,1.0),
                        (it.y/rgba.height()).coerceIn(0.0,1.0))}
                }finally{curve.release();approx.release()}
            }
            return null
        }finally{
            rgba.release();gray.release();blur.release();edges.release()
            hierarchy.release();contours.forEach{it.release()}
        }
    }
    fun process(path:String,a:Map<*,*>):String{
        ensure()
        val bmp=load(path,3400)
        val rgba=Mat();Utils.bitmapToMat(bmp,rgba);bmp.recycle()
        var rgb=Mat()
        Imgproc.cvtColor(rgba,rgb,Imgproc.COLOR_RGBA2RGB)
        rgba.release()
        val raw=a["corners"] as? List<*>
        if(raw!=null && raw.size==8){
            val p=Array(4){i->
                Point(((raw[i*2] as? Number)?.toDouble()?:0.0).coerceIn(0.0,1.0)*rgb.cols(),
                    ((raw[i*2+1] as? Number)?.toDouble()?:0.0).coerceIn(0.0,1.0)*rgb.rows())
            }
            val ordered=order(p)
            fun dist(x:Point,y:Point)=hypot(x.x-y.x,x.y-y.y)
            val w=max(dist(ordered[0],ordered[1]),dist(ordered[2],ordered[3])).roundToInt().coerceAtLeast(20)
            val h=max(dist(ordered[0],ordered[3]),dist(ordered[1],ordered[2])).roundToInt().coerceAtLeast(20)
            val src=MatOfPoint2f(*ordered)
            val dst=MatOfPoint2f(Point(0.0,0.0),Point(w.toDouble(),0.0),
                Point(w.toDouble(),h.toDouble()),Point(0.0,h.toDouble()))
            val matrix=Imgproc.getPerspectiveTransform(src,dst)
            val warped=Mat()
            Imgproc.warpPerspective(rgb,warped,matrix,Size(w.toDouble(),h.toDouble()),
                Imgproc.INTER_LINEAR,Core.BORDER_REPLICATE)
            matrix.release();src.release();dst.release();rgb.release();rgb=warped
        }
        when(((a["rotate"] as? Number)?.toInt()?:0)%360){
            90->Core.rotate(rgb,rgb,Core.ROTATE_90_CLOCKWISE)
            180->Core.rotate(rgb,rgb,Core.ROTATE_180)
            270->Core.rotate(rgb,rgb,Core.ROTATE_90_COUNTERCLOCKWISE)
        }
        when(a["filter"] as? String?:"Color"){
            "B&W"->{
                val gray=Mat()
                Imgproc.cvtColor(rgb,gray,Imgproc.COLOR_RGB2GRAY)
                Imgproc.adaptiveThreshold(gray,gray,255.0,
                    Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C,
                    Imgproc.THRESH_BINARY,31,12.0)
                Imgproc.cvtColor(gray,rgb,Imgproc.COLOR_GRAY2RGB)
                gray.release()
            }
            "Gray"->{
                Imgproc.cvtColor(rgb,rgb,Imgproc.COLOR_RGB2GRAY)
                Imgproc.cvtColor(rgb,rgb,Imgproc.COLOR_GRAY2RGB)
            }
            "Enhance"->{
                val lab=Mat()
                Imgproc.cvtColor(rgb,lab,Imgproc.COLOR_RGB2Lab)
                val channels=ArrayList<Mat>()
                Core.split(lab,channels)
                val clahe=Imgproc.createCLAHE(2.0,Size(8.0,8.0))
                clahe.apply(channels[0],channels[0])
                Core.merge(channels,lab)
                Imgproc.cvtColor(lab,rgb,Imgproc.COLOR_Lab2RGB)
                channels.forEach{it.release()};lab.release()
            }
        }
        val output=Bitmap.createBitmap(rgb.cols(),rgb.rows(),Bitmap.Config.ARGB_8888)
        val rgbaOut=Mat()
        Imgproc.cvtColor(rgb,rgbaOut,Imgproc.COLOR_RGB2RGBA)
        Utils.matToBitmap(rgbaOut,output)
        rgbaOut.release();rgb.release()
        val file=File.createTempFile("scan_page_",".jpg",context.cacheDir)
        try{
            file.outputStream().buffered().use{out->
                require(output.compress(Bitmap.CompressFormat.JPEG,94,out))
            }
            return file.absolutePath
        }finally{output.recycle()}
    }
}
