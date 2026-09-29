package com.ryannair05.meetandeat.share

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.RestaurantMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ryannair05.meetandeat.dining.DiningMenuItem
import com.ryannair05.meetandeat.dining.MenuItemDetail
import com.ryannair05.meetandeat.dining.PSUDiningHall
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

@Composable
fun ItemShareCard(
    hall: PSUDiningHall,
    date: LocalDate,
    mealName: String,
    item: DiningMenuItem,
    detail: MenuItemDetail,
    options: ItemShareOptions,
    modifier: Modifier = Modifier,
) {
    val palette = options.theme
    val ingredientText = detail.ingredients?.trim().orEmpty()
    val allergenText = detail.allergenStatement?.trim().orEmpty()

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        color = palette.containerColor,
        contentColor = palette.contentColor,
        border = BorderStroke(1.dp, palette.borderColor),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (options.showHeader) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.Restaurant,
                        contentDescription = null,
                        tint = palette.accentColor,
                        modifier = Modifier.size(22.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            "${hall.displayName} Dining",
                            color = palette.contentColor,
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Bold,
                        )
                        if (options.showTimestamp) {
                            Text(
                                listOf(mealName, date.format(itemShareDateFormatter))
                                    .filter(String::isNotBlank)
                                    .joinToString(" • "),
                                color = palette.contentColor.copy(alpha = 0.68f),
                                fontSize = 12.sp,
                            )
                        }
                    }
                }
                HorizontalDivider(color = palette.borderColor)
            }

            if (options.customCaption.isNotBlank()) {
                Surface(
                    color = palette.accentColor.copy(alpha = 0.13f),
                    contentColor = palette.accentColor,
                    shape = RoundedCornerShape(10.dp),
                ) {
                    Text(
                        options.customCaption.trim(),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }

            Surface(
                color = palette.accentColor.copy(alpha = 0.11f),
                contentColor = palette.contentColor,
                shape = RoundedCornerShape(14.dp),
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.RestaurantMenu,
                            contentDescription = null,
                            tint = palette.accentColor,
                            modifier = Modifier.size(24.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            item.name,
                            modifier = Modifier.weight(1f),
                            color = palette.contentColor,
                            fontSize = 21.sp,
                            fontWeight = FontWeight.Bold,
                            lineHeight = 25.sp,
                        )
                    }
                    if (options.showDietaryTraits) {
                        ShareDietaryTraits(item, palette)
                    }
                }
            }

            if (options.showIngredients && (ingredientText.isNotEmpty() || allergenText.isNotEmpty())) {
                ShareSectionLabel("Ingredients & allergens", palette)
                if (allergenText.isNotEmpty()) {
                    Surface(
                        color = palette.accentColor.copy(alpha = 0.1f),
                        contentColor = palette.contentColor,
                        shape = RoundedCornerShape(10.dp),
                    ) {
                        Text(
                            allergenText,
                            modifier = Modifier.fillMaxWidth().padding(10.dp),
                            color = palette.contentColor.copy(alpha = 0.82f),
                            fontSize = 11.sp,
                            lineHeight = 15.sp,
                        )
                    }
                }
                if (ingredientText.isNotEmpty()) {
                    Text(
                        ingredientText,
                        color = palette.contentColor.copy(alpha = 0.78f),
                        fontSize = 11.sp,
                        lineHeight = 15.sp,
                    )
                }
            }

            if (options.showNutrition && detail.nutrition.isNotEmpty()) {
                ShareSectionLabel("Nutrition", palette)
                Column {
                    detail.nutrition.forEachIndexed { index, fact ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                fact.name,
                                modifier = Modifier.weight(1f),
                                color = palette.contentColor.copy(alpha = 0.76f),
                                fontSize = 11.sp,
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                fact.value,
                                color = palette.contentColor,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                        if (index != detail.nutrition.lastIndex) {
                            HorizontalDivider(color = palette.borderColor.copy(alpha = 0.65f))
                        }
                    }
                }
            }

            if (options.showWatermark) {
                HorizontalDivider(color = palette.borderColor)
                ShareWatermark(palette, Modifier.align(Alignment.End))
            }
        }
    }
}

@Composable
private fun ShareSectionLabel(label: String, theme: ShareCardTheme) {
    Text(
        label.uppercase(Locale.US),
        color = theme.accentColor,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.8.sp,
    )
}

private val itemShareDateFormatter = DateTimeFormatter.ofPattern("EEE, MMM d", Locale.US)
