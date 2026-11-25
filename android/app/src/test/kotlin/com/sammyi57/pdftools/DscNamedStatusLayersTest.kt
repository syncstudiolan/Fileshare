package com.sammyi57.pdftools

import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceDictionary
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceStream
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DscNamedStatusLayersTest {
  @Test fun statusLayerRewritePreservesRealBackgroundAndSignerStream() {
    PDDocument().use { document ->
      fun xobject(width: Float, height: Float) = PDAppearanceStream(document).apply {
        bBox = PDRectangle(width,height)
        resources = PDResources()
      }
      val n = xobject(50f,30f)
      val frm = xobject(50f,30f)
      val resources = frm.resources
      val layers = listOf("n0","n1","n2","n3","n4")
      layers.forEach { key ->
        resources.put(COSName.getPDFName(key), xobject(
          if(key=="n4" || key=="n2")50f else 100f,
          if(key=="n4" || key=="n2")30f else 100f))
      }
      n.resources.put(COSName.getPDFName("FRM"),frm)
      val widget = PDAnnotationWidget().apply {
        appearance = PDAppearanceDictionary().apply {
          setNormalAppearance(n)
        }
      }
      val beforeN0=resources.getXObject(COSName.getPDFName("n0")).cosObject
      val beforeN2=resources.getXObject(COSName.getPDFName("n2")).cosObject
      val beforeN1=resources.getXObject(COSName.getPDFName("n1")).cosObject
      assertFalse(replaceDscNamedStatusLayers(document,widget,DscAppearanceVerdict.UNKNOWN))
      assertSame(beforeN1,resources.getXObject(COSName.getPDFName("n1")).cosObject)
      assertTrue(replaceDscNamedStatusLayers(document,widget,DscAppearanceVerdict.VALID))
      assertSame(beforeN0,resources.getXObject(COSName.getPDFName("n0")).cosObject)
      assertSame(beforeN2,resources.getXObject(COSName.getPDFName("n2")).cosObject)
      assertNotSame(beforeN1,resources.getXObject(COSName.getPDFName("n1")).cosObject)
    }
  }
}
