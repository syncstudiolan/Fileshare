package com.example.file_share

import com.tom_roush.harmony.awt.geom.AffineTransform
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.common.PDStream
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.util.Matrix
import java.io.File
import kotlin.math.min

/**
 * Vector-preserving page composition adapted from the MIT-licensed Pdf.kt in
 * sammyZi/pdf-tools, retaining crop boxes and inherited resources.
 */
internal object PdfVectorLayout {
    private val PDPage.rot get()=((rotation%360)+360)%360
    private class Shown(val form:PDFormXObject,val w:Float,val h:Float,val rot:Int) {
        val shownW get()=if(rot%180!=0)h else w
        val shownH get()=if(rot%180!=0)w else h
    }
    private fun PDDocument.embed(page:PDPage):Shown{
        val box=page.cropBox
        val form=PDFormXObject(PDStream(this,page.contents,COSName.FLATE_DECODE))
        form.resources=page.resources?:PDResources()
        form.bBox=PDRectangle(box.lowerLeftX,box.lowerLeftY,box.width,box.height)
        form.setMatrix(AffineTransform.getTranslateInstance(
            -box.lowerLeftX.toDouble(),-box.lowerLeftY.toDouble()))
        return Shown(form,box.width,box.height,page.rot)
    }
    private fun PDPageContentStream.place(form:PDFormXObject,
        x:Float,y:Float,sx:Float,sy:Float=sx,deg:Float=0f){
        saveGraphicsState()
        transform(Matrix.getTranslateInstance(x,y))
        if(deg!=0f)transform(Matrix.getRotateInstance(Math.toRadians(deg.toDouble()),0f,0f))
        transform(Matrix.getScaleInstance(sx,sy))
        drawForm(form)
        restoreGraphicsState()
    }
    private fun PDPageContentStream.drawShown(e:Shown,x:Float,y:Float,s:Float){
        val w=e.w*s;val h=e.h*s
        val ox=when(e.rot){180->x+w;270->x+h;else->x}
        val oy=when(e.rot){90->y+w;180->y+h;else->y}
        place(e.form,ox,oy,s,s,-e.rot.toFloat())
    }
    private fun PDDocument.newPage(w:Float,h:Float)=
        PDPage(PDRectangle(w,h)).also{addPage(it)}
    fun flip(input:File,dest:File,axis:String){
        require(axis in setOf("h","v","both")){"Choose flip axis"}
        PDDocument.load(input).use{source->
            PDDocument().use{output->
                for(p in source.pages){
                    val e=output.embed(p)
                    val fx=if(e.rot%180!=0)axis!="h" else axis!="v"
                    val fy=if(e.rot%180!=0)axis!="v" else axis!="h"
                    val newPage=output.newPage(e.w,e.h)
                    PDPageContentStream(output,newPage).use{stream->
                        stream.place(e.form,if(fx)e.w else 0f,
                            if(fy)e.h else 0f,if(fx)-1f else 1f,
                            if(fy)-1f else 1f)
                    }
                    newPage.rotation=e.rot
                }
                output.save(dest)
            }
        }
    }
    fun resize(input:File,dest:File,format:String){
        val dims=when(format){
            "A4"->595.28f to 841.89f
            "A5"->419.53f to 595.28f
            "Letter"->612f to 792f
            "Legal"->612f to 1008f
            else->error("Unknown page size")
        }
        PDDocument.load(input).use{source->
            PDDocument().use{out->
                for(p in source.pages){
                    val e=out.embed(p)
                    val w=if(e.shownW>e.shownH)dims.second else dims.first
                    val h=if(e.shownW>e.shownH)dims.first else dims.second
                    val scale=min(w/e.shownW,h/e.shownH)
                    val page=out.newPage(w,h)
                    PDPageContentStream(out,page).use{
                        it.drawShown(e,(w-e.shownW*scale)/2,
                            (h-e.shownH*scale)/2,scale)
                    }
                }
                out.save(dest)
            }
        }
    }
    fun nup(input:File,dest:File,perSheet:Int,lines:Boolean){
        val grid=mapOf(2 to (2 to 1),4 to (2 to 2),6 to (2 to 3),
            9 to (3 to 3),16 to (4 to 4))
        val (col,row)=grid[perSheet]?:error("Choose 2, 4, 6, 9 or 16")
        PDDocument.load(input).use{source->
            PDDocument().use{out->
                val shown=source.pages.map{out.embed(it)}
                require(shown.isNotEmpty()){"Empty PDF"}
                val landscape=col>row
                val width=if(landscape)841.89f else 595.28f
                val height=if(landscape)595.28f else 841.89f
                val margin=18f
                val cellWidth=(width-2*margin)/col
                val cellHeight=(height-2*margin)/row
                var stream:PDPageContentStream?=null
                try{
                    for((index,e) in shown.withIndex()){
                        val k=index%(col*row)
                        if(k==0){
                            stream?.close()
                            val page=out.newPage(width,height)
                            stream=PDPageContentStream(out,page)
                            if(lines){
                                stream.setStrokingColor(.6f,.6f,.6f)
                                stream.setLineWidth(.5f)
                                for(c in 1 until col){
                                    stream.moveTo(margin+c*cellWidth,margin)
                                    stream.lineTo(margin+c*cellWidth,height-margin)
                                }
                                for(r in 1 until row){
                                    stream.moveTo(margin,height-margin-r*cellHeight)
                                    stream.lineTo(width-margin,height-margin-r*cellHeight)
                                }
                                stream.stroke()
                            }
                        }
                        val scale=min((cellWidth-8)/e.shownW,(cellHeight-8)/e.shownH)
                        val x=margin+(k%col)*cellWidth+(cellWidth-e.shownW*scale)/2
                        val y=height-margin-(k/col+1)*cellHeight+
                            (cellHeight-e.shownH*scale)/2
                        stream!!.drawShown(e,x,y,scale)
                    }
                }finally{stream?.close()}
                out.save(dest)
            }
        }
    }
}
