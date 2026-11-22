package com.sammyi57.pdftools

import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ScanModesAndIdLayoutTest {
  private fun doc() = ScanDoc(
    id="draft",name="Card test",created=1L,modified=1L,
    pages=(0..3).map { index ->
      ScanPage(id="p$index",kind="doc",size="fit",
        shots=listOf(Shot(src="/tmp/p$index.jpg",width=1000,height=630)))
    })

  @Test fun allFourPhotosFitOneEditableIdCardSheet() {
    val converted=convertScanMode(doc(),"id")
    assertEquals(1,converted.pages.size)
    val page=converted.pages.single()
    assertEquals(4,page.shots.size)
    assertEquals(4,page.placements.size)
    assertEquals("A4-portrait",page.size)
    assertEquals("id",page.kind)
    val sheet=layoutScanPage(page.kind,page.size,
      page.shots.map { it.shownW to it.shownH },page.placements).single()
    assertEquals(4,sheet.items.size)
    assertEquals(595.28f,sheet.W,0.02f)
    assertEquals(841.89f,sheet.H,0.02f)
    for(slot in page.placements){
      assertTrue(slot.x>=0f && slot.y>=0f)
      assertTrue(slot.x+slot.w<=1.0001f)
      assertTrue(slot.y+slot.h<=1.0001f)
    }
  }

  @Test fun canMoveResizeChangeLayerAndUseLegalPaper() {
    val page=convertScanMode(doc(),"id").pages.single()
    val moved=editCardPlacement(page,source=1,dx=.04f,dy=.09f)
    assertTrue(moved.placements[1].x>page.placements[1].x)
    val sized=editCardPlacement(moved,source=1,dx=.06f,dy=.04f,resize=true)
    assertTrue(sized.placements[1].w>moved.placements[1].w)
    val front=reorderCardPlacement(sized,source=1,toFront=true)
    assertEquals(1,front.placements.last().sourceIndex)
    val back=reorderCardPlacement(front,source=1,toFront=false)
    assertEquals(1,back.placements.first().sourceIndex)
    val legal=back.copy(size="Legal-portrait")
    val sheet=layoutScanPage("id",legal.size,
      legal.shots.map { it.shownW to it.shownH },legal.placements).single()
    assertEquals(612f,sheet.W,0.01f)
    assertEquals(1008f,sheet.H,0.01f)
  }

  @Test fun switchingBackKeepsEverySourceAndDraftPositionsSerialize() {
    val before=doc()
    val card=convertScanMode(before,"id")
    val encoded=Json.encodeToString(card)
    val saved=Json.decodeFromString<ScanDoc>(encoded)
    assertEquals(card.pages.single().placements,saved.pages.single().placements)
    val restored=convertScanMode(saved,"doc")
    assertEquals(4,restored.pages.size)
    assertEquals(before.pages.map { it.shots.single().src },
      restored.pages.map { it.shots.single().src })
    assertTrue(restored.pages.all { it.kind=="doc" })
  }
}
