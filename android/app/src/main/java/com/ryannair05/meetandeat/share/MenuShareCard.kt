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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ryannair05.meetandeat.dining.DiningMealPeriod
import com.ryannair05.meetandeat.dining.PSUDiningHall
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

@Composable
fun MenuShareCard(
    hall: PSUDiningHall,
    date: LocalDate,
    meal: DiningMealPeriod,
    options: MenuShareOptions,
    modifier: Modifier = Modifier,
) {
    val palette = options.theme
    val sections = remember(meal) { meal.sections.take(3) }

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        color = palette.containerColor,
        contentColor = palette.contentColor,
        border = BorderStroke(1.dp, palette.borderColor),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
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
                                "${meal.name} • ${date.format(shareDateFormatter)}",
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
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }

            sections.forEach { section ->
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        section.name.uppercase(Locale.US),
                        color = palette.accentColor,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        letterSpacing = 0.8.sp,
                    )
                    section.items.forEach { item ->
                        Column(Modifier.fillMaxWidth()) {
                            Text(
                                "• ${item.name}",
                                color = palette.contentColor,
                                fontSize = 13.sp,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (options.showDietaryTraits) {
                                ShareDietaryTraits(
                                    item = item,
                                    theme = palette,
                                    modifier = Modifier.padding(start = 12.dp, top = 3.dp),
                                )
                            }
                        }
                    }
                }
            }

            val hiddenSections = meal.sections.size - sections.size
            if (hiddenSections > 0) {
                Text(
                    "+$hiddenSections more ${if (hiddenSections == 1) "section" else "sections"}",
                    color = palette.contentColor.copy(alpha = 0.55f),
                    fontSize = 10.sp,
                )
            }

            if (options.showWatermark) {
                HorizontalDivider(color = palette.borderColor)
                ShareWatermark(palette, Modifier.align(Alignment.End))
            }
        }
    }
}

private val shareDateFormatter = DateTimeFormatter.ofPattern("EEE, MMM d", Locale.US)
