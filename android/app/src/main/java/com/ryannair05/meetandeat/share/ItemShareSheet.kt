package com.ryannair05.meetandeat.share

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.draw
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ryannair05.meetandeat.dining.DiningMenuItem
import com.ryannair05.meetandeat.dining.MenuItemDetail
import com.ryannair05.meetandeat.dining.PSUDiningHall
import kotlinx.coroutines.launch
import java.time.LocalDate

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ItemShareSheet(
    hall: PSUDiningHall,
    date: LocalDate,
    mealName: String,
    item: DiningMenuItem,
    detail: MenuItemDetail,
    onDismiss: () -> Unit,
) {
    com.ryannair05.meetandeat.TrackScreen("share_item")
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val graphicsLayer = rememberGraphicsLayer()
    val sheetState = rememberBottomSheetState(
        initialValue = SheetValue.Hidden,
        enabledValues = setOf(SheetValue.Hidden, SheetValue.Expanded),
    )
    val hasIngredients = detail.ingredients?.isNotBlank() == true || detail.allergenStatement?.isNotBlank() == true
    val hasNutrition = detail.nutrition.isNotEmpty()
    var options by remember(detail) {
        mutableStateOf(
            ItemShareOptions(
                showIngredients = hasIngredients,
                showNutrition = hasNutrition,
            )
        )
    }
    var exporting by remember { mutableStateOf(false) }
    var exportError by rememberSaveable { mutableStateOf<String?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .imePadding()
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Share dish as image", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                Text(
                    "Customize the card, then send the exact preview.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Text("Preview", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
            Surface(
                shape = MaterialTheme.shapes.extraLarge,
                color = MaterialTheme.colorScheme.surfaceContainerLow,
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp)
                        .drawWithContent {
                            graphicsLayer.record { this@drawWithContent.drawContent() }
                            drawLayer(graphicsLayer)
                        },
                ) {
                    ItemShareCard(hall, date, mealName, item, detail, options)
                }
            }

            Text("Card style", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
            ShareThemePicker(options.theme) { theme ->
                options = options.copy(theme = theme)
                exportError = null
            }

            OutlinedTextField(
                value = options.customCaption,
                onValueChange = { value ->
                    if (value.length <= 60) options = options.copy(customCaption = value)
                    exportError = null
                },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Caption or callout (optional)") },
                placeholder = { Text("This looks good!") },
                supportingText = { Text("${options.customCaption.length}/60") },
                singleLine = true,
            )

            Text("Content", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = MaterialTheme.shapes.large,
                color = MaterialTheme.colorScheme.surfaceContainerLow,
            ) {
                Column(Modifier.padding(horizontal = 14.dp, vertical = 4.dp)) {
                    ShareToggleRow("Header and location", options.showHeader) {
                        options = options.copy(showHeader = it)
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f))
                    ShareToggleRow("Meal and date", options.showTimestamp, enabled = options.showHeader) {
                        options = options.copy(showTimestamp = it)
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f))
                    ShareToggleRow("Dietary icons and tags", options.showDietaryTraits) {
                        options = options.copy(showDietaryTraits = it)
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f))
                    ShareToggleRow("Ingredients and allergens", options.showIngredients, enabled = hasIngredients) {
                        options = options.copy(showIngredients = it)
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f))
                    ShareToggleRow("Nutrition facts", options.showNutrition, enabled = hasNutrition) {
                        options = options.copy(showNutrition = it)
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f))
                    ShareToggleRow("Halls watermark", options.showWatermark) {
                        options = options.copy(showWatermark = it)
                    }
                }
            }

            exportError?.let { message ->
                Text(message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
            }

            Button(
                enabled = !exporting,
                onClick = {
                    exporting = true
                    exportError = null
                    scope.launch {
                        runCatching {
                            ShareImageExporter.export(context, graphicsLayer, fileNamePrefix = "item-share")
                        }.onSuccess { image ->
                            ShareImageExporter.share(
                                context = context,
                                image = image,
                                chooserTitle = "Share item card",
                                clipLabel = item.name,
                            )
                            onDismiss()
                        }.onFailure { error ->
                            exportError = error.message ?: "Couldn't create the item image."
                        }
                        exporting = false
                    }
                },
                modifier = Modifier.fillMaxWidth().height(52.dp),
                shape = MaterialTheme.shapes.large,
            ) {
                if (exporting) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.AutoMirrored.Filled.Send, null)
                    Spacer(Modifier.width(8.dp))
                    Text("Share item card")
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}
