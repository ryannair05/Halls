package com.ryannair05.meetandeat

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
internal fun DiningTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val dark = isSystemInDarkTheme()
    val colors = remember(context, configuration, dark) {
        val system = if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        if (system.hasColorfulAccents()) system else if (dark) HallsDarkColors else HallsLightColors
    }
    MaterialTheme(
        colorScheme = colors,
        typography = Typography(),
        shapes = Shapes(),
        motionScheme = MotionScheme.expressive(),
        content = content,
    )
}

// Android can supply a monochrome dynamic scheme even when no colorful palette is enabled.
// Inspect only accent roles: neutral surfaces and the always-red error color cannot identify it.
internal fun ColorScheme.hasColorfulAccents(): Boolean =
    listOf(primary, secondary, tertiary, primaryContainer, secondaryContainer, tertiaryContainer).any {
        maxOf(it.red, it.green, it.blue) - minOf(it.red, it.green, it.blue) > 0.06f
    }

// Material tonal palettes: Penn State-inspired blue, teal secondary, and warm gold tertiary.
// Every container, foreground, inverse, and surface role has a matching light/dark value.
internal val HallsLightColors = lightColorScheme(
    primary = Color(0xFF455E91),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFD8E2FF),
    onPrimaryContainer = Color(0xFF2C4678),
    inversePrimary = Color(0xFFAEC6FF),
    secondary = Color(0xFF006A61),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFF9EF2E6),
    onSecondaryContainer = Color(0xFF005049),
    tertiary = Color(0xFF7E570F),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFFFDDB0),
    onTertiaryContainer = Color(0xFF614000),
    background = Color(0xFFF7F9FF),
    onBackground = Color(0xFF1A1B20),
    surface = Color(0xFFF7F9FF),
    onSurface = Color(0xFF1A1B20),
    surfaceVariant = Color(0xFFDFE7F5),
    onSurfaceVariant = Color(0xFF44474F),
    surfaceTint = Color(0xFF455E91),
    inverseSurface = Color(0xFF2F3036),
    inverseOnSurface = Color(0xFFF0F0F7),
    outline = Color(0xFF757780),
    outlineVariant = Color(0xFFC5C6D0),
    scrim = Color(0xFF000000),
    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF93000A),
    surfaceBright = Color(0xFFF7F9FF),
    surfaceDim = Color(0xFFD3DFF2),
    surfaceContainer = Color(0xFFE5EDFC),
    surfaceContainerHigh = Color(0xFFDBE6FA),
    surfaceContainerHighest = Color(0xFFD0DFF6),
    surfaceContainerLow = Color(0xFFEDF3FF),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    primaryFixed = Color(0xFFD8E2FF),
    primaryFixedDim = Color(0xFFAEC6FF),
    onPrimaryFixed = Color(0xFF001A43),
    onPrimaryFixedVariant = Color(0xFF2C4678),
    secondaryFixed = Color(0xFF9EF2E6),
    secondaryFixedDim = Color(0xFF82D5CA),
    onSecondaryFixed = Color(0xFF00201D),
    onSecondaryFixedVariant = Color(0xFF005049),
    tertiaryFixed = Color(0xFFFFDDB0),
    tertiaryFixedDim = Color(0xFFF2BE6E),
    onTertiaryFixed = Color(0xFF281800),
    onTertiaryFixedVariant = Color(0xFF614000),
)

internal val HallsDarkColors = darkColorScheme(
    primary = Color(0xFFAEC6FF),
    onPrimary = Color(0xFF122F60),
    primaryContainer = Color(0xFF2C4678),
    onPrimaryContainer = Color(0xFFD8E2FF),
    inversePrimary = Color(0xFF455E91),
    secondary = Color(0xFF82D5CA),
    onSecondary = Color(0xFF003732),
    secondaryContainer = Color(0xFF005049),
    onSecondaryContainer = Color(0xFF9EF2E6),
    tertiary = Color(0xFFF2BE6E),
    onTertiary = Color(0xFF442C00),
    tertiaryContainer = Color(0xFF614000),
    onTertiaryContainer = Color(0xFFFFDDB0),
    background = Color(0xFF0E1625),
    onBackground = Color(0xFFE2E2E9),
    surface = Color(0xFF0E1625),
    onSurface = Color(0xFFE2E2E9),
    surfaceVariant = Color(0xFF34435D),
    onSurfaceVariant = Color(0xFFC5C6D0),
    surfaceTint = Color(0xFFAEC6FF),
    inverseSurface = Color(0xFFE2E2E9),
    inverseOnSurface = Color(0xFF2F3036),
    outline = Color(0xFF8E9099),
    outlineVariant = Color(0xFF44474F),
    scrim = Color(0xFF000000),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    surfaceBright = Color(0xFF354660),
    surfaceDim = Color(0xFF0E1625),
    surfaceContainer = Color(0xFF1C2A41),
    surfaceContainerHigh = Color(0xFF253651),
    surfaceContainerHighest = Color(0xFF30425F),
    surfaceContainerLow = Color(0xFF152238),
    surfaceContainerLowest = Color(0xFF09101D),
    primaryFixed = Color(0xFFD8E2FF),
    primaryFixedDim = Color(0xFFAEC6FF),
    onPrimaryFixed = Color(0xFF001A43),
    onPrimaryFixedVariant = Color(0xFF2C4678),
    secondaryFixed = Color(0xFF9EF2E6),
    secondaryFixedDim = Color(0xFF82D5CA),
    onSecondaryFixed = Color(0xFF00201D),
    onSecondaryFixedVariant = Color(0xFF005049),
    tertiaryFixed = Color(0xFFFFDDB0),
    tertiaryFixedDim = Color(0xFFF2BE6E),
    onTertiaryFixed = Color(0xFF281800),
    onTertiaryFixedVariant = Color(0xFF614000),
)

