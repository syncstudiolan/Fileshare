package com.sammyi57.pdftools


import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// Vector icons are bundled with the Android app. The previous mdi.ttf file was
// a zero-byte Git blob, so codepoint-based glyphs rendered tofu boxes.
@Composable
fun Icon(glyph: Int, size: Dp = 22.dp, color: Color = c.ink, modifier: Modifier = Modifier, label: String? = null) {
  val vector = when (glyph) {
    I.accountOffOutline -> Icons.Filled.PersonOff
    I.accountSwitchOutline -> Icons.Filled.ManageAccounts
    I.airplane -> Icons.Filled.Flight
    I.alertCircleOutline -> Icons.Filled.ErrorOutline
    I.arrowLeft -> Icons.Filled.ArrowBack
    I.arrowRight -> Icons.Filled.ArrowForward
    I.arrowUpRight -> Icons.Filled.NorthEast
    I.autoFix -> Icons.Filled.AutoFixHigh
    I.brush -> Icons.Filled.Brush
    I.cameraIris -> Icons.Filled.Camera
    I.cameraOffOutline -> Icons.Filled.NoPhotography
    I.cameraOutline -> Icons.Filled.CameraAlt
    I.cameraFlipOutline -> Icons.Filled.FlipCameraAndroid
    I.cameraPlusOutline -> Icons.Filled.AddAPhoto
    I.cameraRetakeOutline -> Icons.Filled.FlipCameraAndroid
    I.cellphone -> Icons.Filled.Smartphone
    I.cellphoneArrowDown -> Icons.Filled.InstallMobile
    I.cellphoneLock -> Icons.Filled.PhonelinkLock
    I.cellphoneRemove -> Icons.Filled.PhonelinkErase
    I.check -> Icons.Filled.Check
    I.checkboxBlankOutline -> Icons.Filled.CheckBoxOutlineBlank
    I.checkboxMarked -> Icons.Filled.CheckBox
    I.chevronDown -> Icons.Filled.KeyboardArrowDown
    I.chevronLeft -> Icons.Filled.ChevronLeft
    I.chevronRight -> Icons.Filled.ChevronRight
    I.chevronUp -> Icons.Filled.KeyboardArrowUp
    I.close -> Icons.Filled.Close
    I.closeCircle -> Icons.Filled.Cancel
    I.cloudSyncOutline -> Icons.Filled.CloudSync
    I.cloudUploadOutline -> Icons.Filled.CloudUpload
    I.codeTags -> Icons.Filled.Code
    I.cogOutline -> Icons.Filled.Settings
    I.contentSaveOutline -> Icons.Filled.Save
    I.crop -> Icons.Filled.Crop
    I.deleteOutline -> Icons.Filled.DeleteOutline
    I.deleteSweepOutline -> Icons.Filled.DeleteSweep
    I.dotsVertical -> Icons.Filled.MoreVert
    I.downloadOutline -> Icons.Filled.Download
    I.drag -> Icons.Filled.DragIndicator
    I.draw -> Icons.Filled.Draw
    I.drawPen -> Icons.Filled.Create
    I.ellipseOutline -> Icons.Filled.Circle
    I.eraser -> Icons.Filled.AutoFixOff
    I.eyedropper -> Icons.Filled.Colorize
    I.imageOutline -> Icons.Filled.Image
    I.eyeOffOutline -> Icons.Filled.VisibilityOff
    I.eyeOutline -> Icons.Filled.Visibility
    I.fileDocumentEditOutline -> Icons.Filled.EditDocument
    I.fileDocumentOutline -> Icons.Filled.Description
    I.fileImageOutline -> Icons.Filled.InsertPhoto
    I.filePdfBox -> Icons.Filled.PictureAsPdf
    I.fileWordOutline -> Icons.Filled.Description
    I.flash -> Icons.Filled.FlashOn
    I.flashAuto -> Icons.Filled.FlashAuto
    I.flashOff -> Icons.Filled.FlashOff
    I.folderMoveOutline -> Icons.Filled.DriveFileMove
    I.folderOutline -> Icons.Filled.FolderOpen
    I.folderPlusOutline -> Icons.Filled.CreateNewFolder
    I.folderZipOutline -> Icons.Filled.FolderZip
    I.formatFontSizeDecrease -> Icons.Filled.TextDecrease
    I.formatFontSizeIncrease -> Icons.Filled.TextIncrease
    I.formatText -> Icons.Filled.TextFields
    I.textRecognition -> Icons.Filled.DocumentScanner
    I.fullscreen -> Icons.Filled.Fullscreen
    I.gestureTap -> Icons.Filled.TouchApp
    I.googleDrive -> Icons.Filled.Cloud
    I.harddisk -> Icons.Filled.Storage
    I.history -> Icons.Filled.History
    I.homeOutline -> Icons.Filled.Home
    I.imageFilterBlackWhite -> Icons.Filled.FilterBAndW
    I.imageMultipleOutline -> Icons.Filled.Collections
    I.informationOutline -> Icons.Filled.Info
    I.lineScan -> Icons.Filled.DocumentScanner
    I.magnify -> Icons.Filled.Search
    I.menuDown -> Icons.Filled.ArrowDropDown
    I.messageTextOutline -> Icons.Filled.Message
    I.openInNew -> Icons.Filled.OpenInNew
    I.pin -> Icons.Filled.PushPin
    I.heart -> Icons.Filled.Favorite
    I.heartOutline -> Icons.Filled.FavoriteBorder
    I.star -> Icons.Filled.Star
    I.paperclip -> Icons.Filled.AttachFile
    I.pinOffOutline -> Icons.Filled.PushPin
    I.pinOutline -> Icons.Filled.PushPin
    I.pencilOutline -> Icons.Filled.Edit
    I.play -> Icons.Filled.PlayArrow
    I.plus -> Icons.Filled.Add
    I.plusBoxMultipleOutline -> Icons.Filled.LibraryAdd
    I.qrcode -> Icons.Filled.QrCode
    I.rectangle -> Icons.Filled.Rectangle
    I.rectangleOutline -> Icons.Filled.CropSquare
    I.resize -> Icons.Filled.AspectRatio
    I.restore -> Icons.Filled.Restore
    I.rotateLeft -> Icons.Filled.RotateLeft
    I.rotateRight -> Icons.Filled.RotateRight
    I.shareVariantOutline -> Icons.Filled.Share
    I.shieldCheckOutline -> Icons.Filled.VerifiedUser
    I.swapHorizontal -> Icons.Filled.SwapHoriz
    I.sync -> Icons.Filled.Sync
    I.trashCanOutline -> Icons.Filled.DeleteOutline
    I.tuneVariant -> Icons.Filled.Tune
    I.undo -> Icons.Filled.Undo
    I.viewGridOutline -> Icons.Filled.GridView
    I.wifiOff -> Icons.Filled.WifiOff
    else -> Icons.Filled.Description
  }
  androidx.compose.material3.Icon(
    imageVector = vector,
    contentDescription = label,
    tint = color,
    modifier = modifier.size(size),
  )
}

/** Codepoints in the MaterialCommunityIcons font, named as in the Expo app. */
object I {
  const val accountOffOutline = 0xF0BE7
  const val accountSwitchOutline = 0xF04CB
  const val airplane = 0xF001D
  const val alertCircleOutline = 0xF05D6
  const val arrowLeft = 0xF004D
  const val arrowRight = 0xF0054
  const val arrowUpRight = 0xF17BF
  const val autoFix = 0xF0068
  const val brush = 0xF00E3
  const val cameraIris = 0xF0104
  const val cameraOffOutline = 0xF19BF
  const val cameraOutline = 0xF0D5D
  const val cameraFlipOutline = 0xF15DA
  const val cameraPlusOutline = 0xF0EDC
  const val cameraRetakeOutline = 0xF0E1A
  const val cellphone = 0xF011C
  const val cellphoneArrowDown = 0xF09D5
  const val cellphoneLock = 0xF094F
  const val cellphoneRemove = 0xF094D
  const val check = 0xF012C
  const val checkboxBlankOutline = 0xF0131
  const val checkboxMarked = 0xF0132
  const val chevronDown = 0xF0140
  const val chevronLeft = 0xF0141
  const val chevronRight = 0xF0142
  const val chevronUp = 0xF0143
  const val close = 0xF0156
  const val closeCircle = 0xF0159
  const val cloudSyncOutline = 0xF12D6
  const val cloudUploadOutline = 0xF0B7E
  const val codeTags = 0xF0174
  const val cogOutline = 0xF08BB
  const val contentSaveOutline = 0xF0818
  const val crop = 0xF019E
  const val deleteOutline = 0xF09E7
  const val deleteSweepOutline = 0xF0C62
  const val dotsVertical = 0xF01D9
  const val downloadOutline = 0xF0B8F
  const val drag = 0xF01DB
  const val draw = 0xF0F49
  const val drawPen = 0xF19B9
  const val ellipseOutline = 0xF0EA1
  const val eraser = 0xF01FE
  const val eyedropper = 0xF020A
  const val imageOutline = 0xF0976
  const val eyeOffOutline = 0xF06D1
  const val eyeOutline = 0xF06D0
  const val fileDocumentEditOutline = 0xF0DC9
  const val fileDocumentOutline = 0xF09EE
  const val fileImageOutline = 0xF0EB0
  const val filePdfBox = 0xF0226
  const val fileWordOutline = 0xF103E
  const val flash = 0xF0241
  const val flashAuto = 0xF0242
  const val flashOff = 0xF0243
  const val folderMoveOutline = 0xF1246
  const val folderOutline = 0xF0256
  const val folderPlusOutline = 0xF0B9D
  const val folderZipOutline = 0xF07B9
  const val formatFontSizeDecrease = 0xF09F3
  const val formatFontSizeIncrease = 0xF09F4
  const val formatText = 0xF0284
  const val textRecognition = 0xF113A
  const val fullscreen = 0xF0293
  const val gestureTap = 0xF0741
  const val googleDrive = 0xF02B6
  const val harddisk = 0xF02CA
  const val history = 0xF02DA
  const val homeOutline = 0xF06A1
  const val imageFilterBlackWhite = 0xF02F0
  const val imageMultipleOutline = 0xF02EF
  const val informationOutline = 0xF02FD
  const val lineScan = 0xF0624
  const val magnify = 0xF0349
  const val menuDown = 0xF035D
  const val messageTextOutline = 0xF036A
  const val openInNew = 0xF03CC
  const val pin = 0xF0403
  const val heart = 0xF08D0
  const val heartOutline = 0xF18A0
  const val star = 0xF04CE
  const val paperclip = 0xF03E2
  const val pinOffOutline = 0xF0930
  const val pinOutline = 0xF0931
  const val pencilOutline = 0xF0CB6
  const val play = 0xF040A
  const val plus = 0xF0415
  const val plusBoxMultipleOutline = 0xF1143
  const val qrcode = 0xF0432
  const val rectangle = 0xF0E5E
  const val rectangleOutline = 0xF0E5F
  const val resize = 0xF0A68
  const val restore = 0xF099B
  const val rotateLeft = 0xF0465
  const val rotateRight = 0xF0467
  const val shareVariantOutline = 0xF1514
  const val shieldCheckOutline = 0xF0CC8
  const val swapHorizontal = 0xF04E1
  const val sync = 0xF04E6
  const val trashCanOutline = 0xF0A7A
  const val tuneVariant = 0xF1542
  const val undo = 0xF054C
  const val viewGridOutline = 0xF11D9
  const val wifiOff = 0xF05AA
}
