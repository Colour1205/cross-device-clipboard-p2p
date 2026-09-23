package io.uaena.cliplink.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.expressiveLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/**
 * ClipLink's own palette, used when the wallpaper-derived scheme is turned
 * off. Deliberately high-chroma: M3 Expressive leans on vivid container roles
 * to carry hierarchy rather than on borders and dividers, and a muted palette
 * flattens the whole thing back into the old Material 3 look.
 */
private val BrandDark = darkColorScheme(
    primary = Color(0xFFB9C3FF),
    onPrimary = Color(0xFF1B2D7A),
    primaryContainer = Color(0xFF334494),
    onPrimaryContainer = Color(0xFFDEE1FF),
    secondary = Color(0xFFF4B8D0),
    onSecondary = Color(0xFF522340),
    secondaryContainer = Color(0xFF6D3A58),
    onSecondaryContainer = Color(0xFFFFD8E7),
    tertiary = Color(0xFF8FD8C4),
    onTertiary = Color(0xFF003730),
    tertiaryContainer = Color(0xFF005046),
    onTertiaryContainer = Color(0xFFAAF5E0),
    background = Color(0xFF111318),
    surface = Color(0xFF111318),
    surfaceContainerLowest = Color(0xFF0C0E13),
    surfaceContainerLow = Color(0xFF191C20),
    surfaceContainer = Color(0xFF1D2024),
    surfaceContainerHigh = Color(0xFF282A2F),
    surfaceContainerHighest = Color(0xFF33353A),
)

/**
 * The Material 3 Expressive theme wrapper.
 *
 * [MaterialExpressiveTheme] is NOT the same component as MaterialTheme - it
 * is what installs the expressive shape scale and, crucially, the
 * [MotionScheme] that every expressive component animates with. Swapping it
 * back to MaterialTheme silently drops the springy motion this whole UI is
 * tuned around, without a single compile error.
 */
@Composable
fun ClipLinkTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colorScheme: ColorScheme = when {
        // minSdk is 31, so dynamic color is always actually available - no
        // version guard needed, unlike the usual boilerplate.
        dynamicColor && darkTheme -> dynamicDarkColorScheme(context)
        dynamicColor -> dynamicLightColorScheme(context)
        darkTheme -> BrandDark
        // expressiveLightColorScheme() has no dark counterpart in the library,
        // which is why the dark side above is hand-rolled rather than derived.
        else -> expressiveLightColorScheme()
    }

    MaterialExpressiveTheme(
        colorScheme = colorScheme,
        motionScheme = MotionScheme.expressive(),
        content = content,
    )
}
