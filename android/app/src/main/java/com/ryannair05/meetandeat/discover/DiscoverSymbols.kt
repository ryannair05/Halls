package com.ryannair05.meetandeat.discover

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.vectorResource
import com.ryannair05.meetandeat.R

internal object DiscoverSymbols {
    val Explore: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_explore)
    val Groups: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_groups)
    val Bookmark: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_bookmark)
    val BookmarkFilled: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_bookmark_fill1)
    val Location: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_location_on)
    val Online: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_videocam)
}

// Keep event metadata and filters colorful using the active palette.
@Composable
internal fun discoverIconColor(icon: ImageVector): androidx.compose.ui.graphics.Color {
    val colors = androidx.compose.material3.MaterialTheme.colorScheme
    return when (icon) {
        DiscoverSymbols.Groups, DiscoverSymbols.Online, DiscoverSymbols.Explore -> colors.secondary
        DiscoverSymbols.Location, DiscoverSymbols.Bookmark,
        DiscoverSymbols.BookmarkFilled, com.ryannair05.meetandeat.DiningSymbols.Restaurant -> colors.tertiary
        else -> colors.primary
    }
}
