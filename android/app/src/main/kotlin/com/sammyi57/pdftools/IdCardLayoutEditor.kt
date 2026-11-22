package com.sammyi57.pdftools

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.min

/** All positions and sizes are normalized relative to the printable page.
 * Keep the original shots untouched. Rendering and PDF export use the exact
 * same layoutScanPage() placements in doc.json.
 */
fun editCardPlacement(page: ScanPage, source: Int,
  dx: Float = 0f, dy: Float = 0f, resize: Boolean = false): ScanPage {
  val slots=page.placements.ifEmpty {
    defaultIdPlacements(page.shots.size,
      if(page.size.startsWith("Legal"))612f else 595.28f,
      if(page.size.startsWith("Legal"))1008f else 841.89f)
  }
  return page.copy(placements=slots.map { slot ->
    if(slot.sourceIndex!=source)slot else {
      if(resize){
        slot.copy(w=(slot.w+dx).coerceIn(.08f,1f-slot.x),
          h=(slot.h+dy).coerceIn(.045f,1f-slot.y))
      }else{
        slot.copy(x=(slot.x+dx).coerceIn(0f,1f-slot.w),
          y=(slot.y+dy).coerceIn(0f,1f-slot.h))
      }
    }
  })
}

fun reorderCardPlacement(page: ScanPage, source: Int, toFront: Boolean): ScanPage {
  val slots=page.placements.ifEmpty { defaultIdPlacements(page.shots.size) }
  val element=slots.firstOrNull { it.sourceIndex==source } ?: return page
  val other=slots.filterNot { it.sourceIndex==source }
  return page.copy(placements=if(toFront)other+element else listOf(element)+other)
}

@Composable
fun IdCardLayoutEditor(
  page: ScanPage,
  onChange: (ScanPage) -> Unit,
  onCrop: () -> Unit,
  onClose: () -> Unit,
) {
  val currentPage by rememberUpdatedState(page)
  val latestChange by rememberUpdatedState(onChange)
  val density=LocalDensity.current
  var selected by remember(page.id) { mutableIntStateOf(0) }
  val legal=page.size.startsWith("Legal")
  val pageW=if(legal)612f else 595.28f
  val pageH=if(legal)1008f else 841.89f
  val placements=page.placements.ifEmpty {
    defaultIdPlacements(page.shots.size,pageW,pageH)
  }
  FullSheet(onClose,ScanUi.bg){
    Column(Modifier.fillMaxSize().padding(12.dp),
      verticalArrangement=Arrangement.spacedBy(10.dp)) {
      Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
        Tap(I.arrowLeft,"Back to PDF editor",onClick=onClose)
        T("ID Card Layout",Type.bold.copy(fontSize=17.sp),
          ScanUi.text,Modifier.weight(1f))
        T("Done",Type.bold,ScanUi.accent,
          Modifier.tap { onClose() }.padding(12.dp))
      }
      Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement=Arrangement.spacedBy(12.dp)) {
        listOf("A4-portrait" to "A4","Legal-portrait" to "Legal").forEach { (format,label) ->
          val active=page.size==format
          T(label,Type.bold,
            if(active)ScanUi.accent else ScanUi.dim,
            Modifier.tap { onChange(page.copy(size=format,
              placements=placements)) }.padding(10.dp))
        }
        T("Auto arrange",Type.bold,ScanUi.accent,
          Modifier.tap {
            latestChange(currentPage.copy(placements=
              defaultIdPlacements(currentPage.shots.size,
                if(currentPage.size.startsWith("Legal"))612f else 595.28f,
                if(currentPage.size.startsWith("Legal"))1008f else 841.89f)))
          }.padding(10.dp))
      }
      T("Drag a card to move. Drag its lower-right corner to resize. "
        +"Select any card to crop or change its layer.",
        Type.small,ScanUi.dim)
      BoxWithConstraints(Modifier.fillMaxWidth().weight(1f),
        contentAlignment=Alignment.Center) {
        val ratio=pageW/pageH
        val width=min((maxWidth-12.dp).value,
          (maxHeight-12.dp).value*ratio).coerceAtLeast(50f).dp
        val height=width/ratio
        val widthPx=with(density){width.toPx()}
        val heightPx=with(density){height.toPx()}
        Box(Modifier.size(width,height).background(Color.White)
          .border(1.dp,ScanUi.line)) {
          placements.forEach { slot ->
            if(slot.sourceIndex in page.shots.indices){
              val index=slot.sourceIndex
              val shot=page.shots[index]
              val bitmap=rememberBitmap(shot.out ?: shot.src,800)
              Box(Modifier
                .offset((slot.x*width.value).dp,(slot.y*height.value).dp)
                .size((slot.w*width.value).dp,(slot.h*height.value).dp)
                .background(Color(0xFFE7F1F5))
                .border(if(selected==index)2.dp else 1.dp,
                  if(selected==index)ScanUi.accent else ScanUi.dim)
                .pointerInput(index,widthPx,heightPx) {
                  detectDragGestures(onDragStart={selected=index}) { change,drag ->
                    change.consume()
                    latestChange(editCardPlacement(currentPage,index,
                      drag.x/widthPx,drag.y/heightPx))
                  }
                }
                .tap { selected=index }) {
                if(bitmap!=null)Image(bitmap,null,Modifier.fillMaxSize(),
                  contentScale=ContentScale.FillBounds)
                if(selected==index){
                  Box(Modifier.align(Alignment.BottomEnd).size(27.dp)
                    .background(ScanUi.accent,RoundedCornerShape(4.dp))
                    .pointerInput(index,widthPx,heightPx) {
                      detectDragGestures { change,drag ->
                        change.consume()
                        latestChange(editCardPlacement(currentPage,index,
                          drag.x/widthPx,drag.y/heightPx,resize=true))
                      }
                    },contentAlignment=Alignment.Center) {
                    Icon(I.resize,18.dp,ScanUi.onAccent)
                  }
                }
              }
            }
          }
        }
      }
      Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement=Arrangement.spacedBy(8.dp)) {
        Btn("Crop selected",Modifier.width(132.dp),I.crop,BtnKind.Secondary,
          height=45.dp,onClick=onCrop)
        Btn("Bring front",Modifier.width(128.dp),I.plus,BtnKind.Secondary,
          height=45.dp) {
          latestChange(reorderCardPlacement(currentPage,selected,true))
        }
        Btn("Send back",Modifier.width(128.dp),I.swapHorizontal,BtnKind.Secondary,
          height=45.dp) {
          latestChange(reorderCardPlacement(currentPage,selected,false))
        }
      }
    }
  }
}
