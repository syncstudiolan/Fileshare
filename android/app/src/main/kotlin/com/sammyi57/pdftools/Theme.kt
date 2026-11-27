package com.sammyi57.pdftools

import com.example.file_share.R

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.io.File

// Three colours: Tangerine is the one sharp accent, Black Cherry is the ink (text, primary buttons, the tab bar), and
// Cool Blue is the quiet second surface (the Recent card, the hero's words). Light is warm paper; dark is a
// cherry-tinted near-black. Loud surfaces are a radial glow with film grain, not a glossy linear gradient.
object Brand {
  val tangerine = Color(0xFF9A80E9)
  val cherry = Color(0xFF342744)
  val cool = Color(0xFFE9DEFF)
}

@Immutable
data class Palette(
  val bg: Color, // screen background
  val surface: Color, // grouped lists, inputs, dialogs
  val sunken: Color, // tiles behind artwork, pressed rows, search, segmented track
  val page: Color, // paper inside illustrations
  val ink: Color, // text and primary buttons
  val sub: Color,
  val faint: Color,
  val line: Color,
  val lineStrong: Color,
  val accent: Color,
  val accentSoft: Color,
  val accentInk: Color,
  val onInk: Color, // text on primary buttons
  val hero: List<Color>, // the loud surface: base, middle, glow
  val panel: Color, // the floating tab bar's glass
  val onPanel: Color,
  val onPanelSub: Color,
  val dark: Boolean,
)

val LightPalette = Palette(
  bg = Color(0xFFF9F5FF), surface = Color(0xFFFFFFFF), sunken = Color(0xFFF0E9FC), page = Color(0xFFFFFFFF),
  ink = Brand.cherry, sub = Color(0xFF756985), faint = Color(0xFFAEA2BE), line = Color(0xFFE8DFF3),
  lineStrong = Color(0xFFD8CBEA), accent = Brand.tangerine, accentSoft = Color(0xFFECE4FF), accentInk = Color(0xFF6443BD),
  onInk = Color(0xFFFFFFFF),
  hero = listOf(Brand.cherry, Color(0xFFBBA6EC), Brand.tangerine),
  panel = Brand.cherry, onPanel = Color(0xFFFFFFFF), onPanelSub = Color(0xFFE5DBF7),
  dark = false,
)

// Dark is a neutral warm near-black (after Poetica), not a cherry tint: Tangerine is the only colour in it.
val DarkPalette = Palette(
  bg = Color(0xFF151321), surface = Color(0xFF221E31), sunken = Color(0xFF2A253B), page = Color(0xFF302940),
  ink = Color(0xFFF5F1FC), sub = Color(0xFFB0A7BE), faint = Color(0xFF847C92), line = Color(0xFF3D354F),
  lineStrong = Color(0xFF4D4261), accent = Color(0xFFB69BFF), accentSoft = Color(0xFF352B50), accentInk = Color(0xFFD4C5FF),
  onInk = Color(0xFF151321),
  hero = listOf(Color(0xFF241E36), Color(0xFF62478E), Brand.tangerine), // near-black, the glow alone carries the colour
  panel = Color(0xFF221E31), onPanel = Color(0xFFF5F1FC), onPanelSub = Color(0xFFB0A7BE),
  dark = true,
)

// The scanner is its own dark, camera-style surface in both themes: the dark palette's near-blacks, with Tangerine for
// detection and actions (and Black Cherry on top of it).
object ScanUi {
  val bg = Color(0xFF13101C)
  val panel = Color(0xFF221E31)
  val raised = Color(0xFF3D354F)
  val text = Color(0xFFFFFFFF)
  val dim = Color(0xFFB0A7BE)
  val line = Color(0xFF3D354F)
  val accent = Brand.tangerine
  val accentSoft = Color(0x389A80E9)
  val onAccent = Brand.cherry
  val scrim = Color(0x99000000)
}

val LocalPalette = staticCompositionLocalOf { LightPalette }

/** The active palette. */
val c: Palette @Composable get() = LocalPalette.current

// Poppins throughout. It runs tall, so line heights are ~1.3x to keep accents and descenders unclipped.
val Poppins = FontFamily(
  Font(R.font.poppins_regular, FontWeight.Normal),
  Font(R.font.poppins_medium, FontWeight.Medium),
  Font(R.font.poppins_semibold, FontWeight.SemiBold),
)

object Type {
  private fun s(size: Float, weight: FontWeight, line: Float? = null, spacing: Float = 0f) = TextStyle(
    fontFamily = Poppins, fontWeight = weight, fontSize = size.sp,
    lineHeight = (line ?: (size * 1.32f)).sp, letterSpacing = spacing.sp,
  )
  val largeTitle = s(32f, FontWeight.SemiBold, 42f, -0.5f)
  val title = s(25f, FontWeight.SemiBold, 33f, -0.3f)
  val hero = s(25f, FontWeight.SemiBold, 33f, -0.4f)
  val body = s(15f, FontWeight.Normal, 22f)
  val small = s(13f, FontWeight.Normal, 19f)
  val item = s(15f, FontWeight.Medium)
  val label = s(13f, FontWeight.SemiBold)
  val button = s(15f, FontWeight.SemiBold)
  val num = s(12.5f, FontWeight.Medium)
  val med = s(13.5f, FontWeight.Medium)
  val bold = s(14f, FontWeight.SemiBold)
  val big = s(26f, FontWeight.SemiBold, 32f, -0.6f) // the reference's big numbers: sizes and counts
  val caption = s(11.5f, FontWeight.Medium, 16f, 1.4f) // uppercase section labels, spaced out
}

// Deliberately not one radius for everything: small things are tighter.
object Radius {
  val tile = 10.dp
  val control = 12.dp
  val group = 16.dp
  val card = 22.dp
  val hero = 30.dp
}

enum class ThemePref { System, Light, Dark }

object ThemeState {
  private val file get() = File(appContext.filesDir, "theme.txt") // same file the Expo app used
  var pref by mutableStateOf(read())
    private set

  private fun read(): ThemePref = try {
    when (file.takeIf { it.exists() }?.readText()?.trim()) {
      "light" -> ThemePref.Light
      "dark" -> ThemePref.Dark
      else -> ThemePref.System
    }
  } catch (_: Exception) {
    ThemePref.System
  }

  fun set(p: ThemePref) {
    pref = p
    try { file.writeText(p.name.lowercase()) } catch (_: Exception) {}
  }
}
