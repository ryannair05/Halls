package com.ryannair05.meetandeat

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.vectorResource

/** Bundled Material Symbols Outlined (24px, weight 400); filled variants identify selected tabs. */
internal object DiningSymbols {
    val ChevronRight: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_chevron_right)
    val MoreVert: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_more_vert)
    val ArrowBack: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_arrow_back)
    val AccessTime: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_schedule)
    val CalendarMonth: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_calendar_month)
    val Close: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_close)
    val FilterList: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_filter_list)
    val Restaurant: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_restaurant)
    val Search: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_search)
    val WifiOff: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_wifi_off)
    val OpenInBrowser: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_open_in_browser)
    val Share: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_share)
    val Warning: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_warning)
    val DirectionsRun: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_directions_run)
    val MenuBook: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_menu_book)
    val DirectionsBus: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_directions_bus)
    val MenuBookFilled: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_menu_book_fill1)
    val DirectionsBusFilled: ImageVector @Composable get() = ImageVector.vectorResource(R.drawable.symbol_directions_bus_fill1)
}
