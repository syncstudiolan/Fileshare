package com.sammyi57.pdftools

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

/** Exact current page appearance including multiple ID images, filters,
 * perspective crop and A4/Legal placement. The editable ScanDoc and
 * previously saved PDF remain untouched.
 */
suspend fun snapshotPdfEditorPages(doc: ScanDoc, selected: List<Int>): List<String> =
  withContext(Dispatchers.IO) {
    require(selected.isNotEmpty()) { "Select at least one PDF page" }
    val rendered=doc.pages.map { page ->
      page.copy(shots=page.shots.map { shot ->
        if(shot.rendered)shot else renderShot(doc.id,shot)
      })
    }
    val images=mutableListOf<String>()
    val sheets=rendered.flatMap { page ->
      val start=images.size
      images.addAll(page.shots.map { pathOf(it.out ?: it.src) })
      layoutScanPage(page.kind,page.size,
        page.shots.map { it.shownW to it.shownH },page.placements)
        .map { sheet -> sheet.copy(items=sheet.items.map { it.copy(img=start+it.img) }) }
    }
    val preview=buildScanPdf(sheets,images)
    val output=File(appContext.cacheDir,"pdf-tool-switch").apply { mkdirs() }
    try{
      val pages=mutableListOf<String>()
      ParcelFileDescriptor.open(preview,
        ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
        PdfRenderer(descriptor).use { pdf ->
          for(index in selected.distinct()){
            require(index in 0 until pdf.pageCount) { "PDF page not available" }
            pdf.openPage(index).use { page ->
              val width=1400
              val height=(width.toFloat()*page.height/page.width)
                .toInt().coerceIn(1,3200)
              val bitmap=Bitmap.createBitmap(width,height,
                Bitmap.Config.ARGB_8888)
              try{
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap,null,null,PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val destination=File(output,
                  "page-${System.nanoTime()}-${index+1}.png")
                FileOutputStream(destination).use { stream ->
                  check(bitmap.compress(Bitmap.CompressFormat.PNG,100,stream)){
                    "Could not export PDF page ${index+1}"
                  }
                }
                pages.add(destination.absolutePath)
              }finally{bitmap.recycle()}
            }
          }
        }
      }
      pages
    }finally{preview.delete()}
  }
