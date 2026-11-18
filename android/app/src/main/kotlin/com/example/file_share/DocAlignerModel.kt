package com.example.file_share

import android.content.Context
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfByte
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.dnn.Dnn
import org.opencv.dnn.Net
import org.opencv.imgproc.Imgproc

/**
 * DocAligner LC100 (DocsaidLab, Apache-2.0), adapted from the MIT
 * sammyZi/pdf-tools DocModel.kt. The 4.75MB pinned ONNX asset is fetched
 * by Android Gradle on builds, and runs inside OpenCV DNN without a second
 * machine-learning runtime.
 *
 * Returns TL/TR/BR/BL corners normalized to [0,1]. If the model is missing
 * or confidence is insufficient, the scanner uses classical contour detection.
 */
internal class DocAlignerModel(private val context:Context){
    private val modelName="docaligner_lc100.onnx"
    private var net:Net?=null
    private var unavailable=false
    private fun load():Net?{
        if(unavailable)return null
        net?.let{return it}
        return try{
            val bytes=context.assets.open(modelName).use{it.readBytes()}
            val buffer=MatOfByte(*bytes)
            try{Dnn.readNetFromONNX(buffer).also{net=it}}
            finally{buffer.release()}
        }catch(_:Exception){unavailable=true;null}
    }
    private fun ordered(pts:Array<Point>):Array<Point>{
        val tl=pts.minBy{it.x+it.y}
        val br=pts.maxBy{it.x+it.y}
        val rest=pts.filter{it!==tl&&it!==br}
        val tr=rest.minBy{it.y-it.x}
        val bl=rest.first{it!==tr}
        return arrayOf(tl,tr,br,bl)
    }
    @Synchronized fun detect(rgb:Mat):Array<Point>?{
        val engine=load()?:return null
        val tiny=Mat()
        val blob=Mat()
        return try{
            Imgproc.resize(rgb,tiny,Size(256.0,256.0),0.0,0.0,Imgproc.INTER_AREA)
            val input=Dnn.blobFromImage(tiny,1.0/255.0,
                Size(256.0,256.0),Scalar(0.0),false,false)
            try{engine.setInput(input)}finally{input.release()}
            val result=engine.forward()
            try{
                val hw=result.size(2)
                require(hw>0){"Bad detection heatmap"}
                val scores=FloatArray(4*hw*hw)
                result.get(intArrayOf(0,0,0,0),scores)
                val points=Array(4){idx->
                    peak(scores,idx*hw*hw,hw)?:return null
                }
                val coords=ordered(points)
                val quadrilateral=MatOfPoint2f(*coords)
                val area=Imgproc.contourArea(quadrilateral)
                quadrilateral.release()
                val pixel=MatOfPoint(*coords.map{
                    Point(it.x*1000,it.y*1000)}.toTypedArray())
                val convex=Imgproc.isContourConvex(pixel)
                pixel.release()
                if(area<.05||!convex)null else coords
            }finally{result.release()}
        }catch(_:Exception){null}
        finally{tiny.release();blob.release()}
    }
    private fun peak(data:FloatArray,offset:Int,hw:Int):Point?{
        val mask=Mat(hw,hw,CvType.CV_8U)
        val bytes=ByteArray(hw*hw){i->
            if(data[offset+i]>=.3f)1.toByte() else 0.toByte()
        }
        mask.put(0,0,bytes)
        val labels=Mat();val stats=Mat();val centers=Mat()
        try{
            val count=Imgproc.connectedComponentsWithStats(mask,labels,stats,centers)
            var best=-1;var area=0.0
            for(i in 1 until count){
                val next=stats.get(i,Imgproc.CC_STAT_AREA)[0]
                if(next>area){area=next;best=i}
            }
            if(best<0)return null
            val ids=IntArray(hw*hw)
            labels.get(0,0,ids)
            var x=0.0;var y=0.0;var weight=0.0
            for(i in ids.indices)if(ids[i]==best){
                val v=data[offset+i].toDouble()
                x+=(i%hw)*v;y+=(i/hw)*v;weight+=v
            }
            if(weight<=0)return null
            return Point((x/weight+.5)/hw,(y/weight+.5)/hw)
        }finally{listOf(mask,labels,stats,centers).forEach{it.release()}}
    }
}
