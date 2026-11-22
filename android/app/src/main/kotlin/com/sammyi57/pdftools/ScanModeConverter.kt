package com.sammyi57.pdftools

/** Change the editing mode without altering a single original source image.
 * Conversion to ID Card collects all pages on one printable sheet; switching
 * back fans the images out into ordinary editable pages again.
 */
fun convertScanMode(doc: ScanDoc, target: String): ScanDoc {
  require(target in setOf("doc","whiteboard","id","card"))
  if(doc.pages.isEmpty())return doc
  if(target=="id"){
    val shots=doc.pages.flatMap { it.shots }
    if(shots.isEmpty())return doc
    if(doc.pages.size==1 && doc.pages[0].kind=="id")return doc
    return doc.copy(pages=listOf(ScanPage(
      id=doc.pages.first().id,kind="id",size="A4-portrait",
      shots=shots,placements=defaultIdPlacements(shots.size))))
  }
  // Grouped ID pages must be expanded, or a standard Document layout would
  // silently discard all but the first card photo.
  val expanded=doc.pages.flatMap { page ->
    if(page.shots.size>1){
      page.shots.mapIndexed { index,shot -> ScanPage(
        id=if(index==0)page.id else uid(),
        kind=target,size="fit",shots=listOf(shot))}
    }else{
      listOf(page.copy(kind=target,placements=emptyList(),
        size=if(page.kind=="id")"fit" else page.size))
    }
  }
  return doc.copy(pages=expanded)
}
