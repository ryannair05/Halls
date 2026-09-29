package com.ryannair05.meetandeat.share

import androidx.compose.ui.graphics.Color

enum class ShareCardTheme(
    val label: String,
    val containerColor: Color,
    val contentColor: Color,
    val accentColor: Color,
    val borderColor: Color,
) {
    DARK("Dark", Color(0xFF1E1E1E), Color(0xFFEDEDED), Color(0xFF90CAF9), Color(0xFF3A3A3A)),
    LIGHT("Light", Color(0xFFF7F7F9), Color(0xFF1A1A1A), Color(0xFF0056B3), Color(0xFFD8DAE0)),
    AMOLED("OLED", Color.Black, Color(0xFFF5F5F5), Color(0xFF64B5F6), Color(0xFF282828)),
}

data class MenuShareOptions(
    val showHeader: Boolean = true,
    val showTimestamp: Boolean = true,
    val showDietaryTraits: Boolean = true,
    val showWatermark: Boolean = true,
    val customCaption: String = "",
    val theme: ShareCardTheme = ShareCardTheme.DARK,
)

data class ItemShareOptions(
    val showHeader: Boolean = true,
    val showTimestamp: Boolean = true,
    val showDietaryTraits: Boolean = true,
    val showIngredients: Boolean = true,
    val showNutrition: Boolean = true,
    val showWatermark: Boolean = true,
    val customCaption: String = "",
    val theme: ShareCardTheme = ShareCardTheme.DARK,
)
