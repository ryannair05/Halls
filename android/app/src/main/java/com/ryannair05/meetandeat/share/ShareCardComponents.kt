package com.ryannair05.meetandeat.share

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ryannair05.meetandeat.MenuTraitIcon
import com.ryannair05.meetandeat.iconColor
import com.ryannair05.meetandeat.R
import com.ryannair05.meetandeat.dining.DiningMenuItem
import com.ryannair05.meetandeat.dining.MenuTrait
import com.ryannair05.meetandeat.dining.MenuTraitClassifier

@Composable
internal fun ShareDietaryTraits(
    item: DiningMenuItem,
    theme: ShareCardTheme,
    modifier: Modifier = Modifier,
) {
    val traits = remember(item.sourceLabels, item.name) {
        MenuTraitClassifier.classify(item.sourceLabels, item.name)
            .filterNot { it == MenuTrait.UNKNOWN || it == MenuTrait.ALLERGEN_WARNING }
            .take(4)
    }
    if (traits.isEmpty()) return

    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        traits.forEach { trait -> ShareTraitBadge(trait, theme) }
    }
}

@Composable
internal fun ShareWatermark(
    theme: ShareCardTheme,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Image(
            painter = painterResource(R.mipmap.ic_launcher_foreground),
            contentDescription = null,
            modifier = Modifier
                .size(18.dp)
                .alpha(0.55f),
        )
        Text(
            "Shared via Halls",
            color = theme.contentColor.copy(alpha = 0.45f),
            fontSize = 10.sp,
            fontWeight = FontWeight.Light,
        )
    }
}

@Composable
private fun ShareTraitBadge(trait: MenuTrait, theme: ShareCardTheme) {
    val traitColor = trait.iconColor(theme.containerColor)
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = traitColor.copy(alpha = 0.13f),
        contentColor = traitColor,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 5.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            MenuTraitIcon(trait, modifier = Modifier.size(11.dp), tint = traitColor)
            Spacer(Modifier.width(3.dp))
            Text(trait.shareLabel, fontSize = 9.sp, fontWeight = FontWeight.Medium)
        }
    }
}

private val MenuTrait.shareLabel: String
    get() = when (this) {
        MenuTrait.TREE_NUT -> "Tree nut"
        MenuTrait.GLUTEN_FRIENDLY -> "Gluten friendly"
        MenuTrait.GLUTEN_FREE -> "Gluten free"
        MenuTrait.ALLERGEN_WARNING -> "Allergen"
        else -> name.replace('_', ' ').lowercase().replaceFirstChar(Char::uppercase)
    }
