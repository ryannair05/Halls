package com.ryannair05.meetandeat

import androidx.annotation.DrawableRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.res.painterResource
import com.ryannair05.meetandeat.dining.MenuTrait
import com.ryannair05.meetandeat.dining.DietaryRequirement

internal val MenuTrait.displayName: String
    get() = name.replace('_', ' ').lowercase().replaceFirstChar(Char::uppercase)

internal val MenuTrait.isAllergen: Boolean
    get() = this in setOf(
        MenuTrait.ALLERGEN_WARNING,
        MenuTrait.MILK,
        MenuTrait.EGG,
        MenuTrait.FISH,
        MenuTrait.SHELLFISH,
        MenuTrait.PEANUT,
        MenuTrait.TREE_NUT,
        MenuTrait.WHEAT,
        MenuTrait.SOY,
        MenuTrait.SESAME,
    )

internal fun Set<MenuTrait>.withoutGenericAllergenWarning(): List<MenuTrait> =
    filterNot { it == MenuTrait.ALLERGEN_WARNING }

@Composable
internal fun MenuTraitIcon(
    trait: MenuTrait,
    modifier: Modifier = Modifier,
    contentDescription: String? = null,
    tint: Color = trait.iconColor(MaterialTheme.colorScheme.surface),
) {
    val allergenIcon = trait.drawableIcon()
    if (allergenIcon != null) {
        Icon(painterResource(allergenIcon), contentDescription, modifier, tint)
    } else {
        Icon(Icons.Default.Info, contentDescription, modifier, tint)
    }
}

@DrawableRes
private fun MenuTrait.drawableIcon(): Int? = when (this) {
    MenuTrait.VEGAN -> R.drawable.ic_dietary_vegan
    MenuTrait.VEGETARIAN -> R.drawable.ic_dietary_vegetarian
    MenuTrait.HALAL -> R.drawable.ic_dietary_halal
    MenuTrait.HALAL_FRIENDLY -> R.drawable.ic_dietary_halal_friendly
    MenuTrait.GLUTEN_FRIENDLY -> R.drawable.ic_dietary_gluten_friendly
    MenuTrait.GLUTEN_FREE -> R.drawable.ic_dietary_gluten_free
    MenuTrait.ALLERGEN_WARNING -> R.drawable.ic_allergen_warning
    MenuTrait.MILK -> R.drawable.ic_allergen_milk
    MenuTrait.EGG -> R.drawable.ic_allergen_egg
    MenuTrait.FISH -> R.drawable.ic_allergen_fish
    MenuTrait.SHELLFISH -> R.drawable.ic_allergen_shellfish
    MenuTrait.PEANUT -> R.drawable.ic_allergen_peanut
    MenuTrait.TREE_NUT -> R.drawable.ic_allergen_tree_nut
    MenuTrait.WHEAT -> R.drawable.ic_allergen_wheat
    MenuTrait.SOY -> R.drawable.ic_allergen_soy
    MenuTrait.SESAME -> R.drawable.ic_allergen_sesame
    else -> null
}

internal val DietaryRequirement.trait: MenuTrait
    get() = when (this) {
        DietaryRequirement.VEGAN -> MenuTrait.VEGAN
        DietaryRequirement.HALAL -> MenuTrait.HALAL
        DietaryRequirement.GLUTEN_FRIENDLY -> MenuTrait.GLUTEN_FRIENDLY
    }

// Match the iOS trait meanings, with shades chosen for the surface actually being rendered.
internal fun MenuTrait.iconColor(background: Color): Color {
    val dark = background.luminance() < 0.5f
    return when (this) {
        MenuTrait.VEGAN -> if (dark) Color(0xFF55C58A) else Color(0xFF08733C)
        MenuTrait.VEGETARIAN -> if (dark) Color(0xFF8AC995) else Color(0xFF466F4F)
        MenuTrait.HALAL, MenuTrait.HALAL_FRIENDLY -> if (dark) Color(0xFF5DD8E5) else Color(0xFF006B78)
        MenuTrait.GLUTEN_FRIENDLY -> if (dark) Color(0xFFB6B3FF) else Color(0xFF5046B5)
        MenuTrait.GLUTEN_FREE -> if (dark) Color(0xFFDBADFF) else Color(0xFF803DB2)
        else -> if (isAllergen) {
            if (dark) Color(0xFFFFB86C) else Color(0xFF9C5000)
        } else {
            if (dark) Color(0xFFCAC4D0) else Color(0xFF49454F)
        }
    }
}
