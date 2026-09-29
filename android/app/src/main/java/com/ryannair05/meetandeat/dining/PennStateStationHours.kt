package com.ryannair05.meetandeat.dining

/** Exact provider names and reviewed aliases only. Never infer a venue from an item name. */
object PennStateStationHours {
    private val aliases = mapOf(
        PSUDiningHall.NORTH to mapOf("greens grains" to "Greens + Grains @ Market North",
            "halal cart bowls" to "Halal Cart @ Market North",
            "halal cart chips dips" to "Halal Cart @ Market North",
            "halal cart flats wraps" to "Halal Cart @ Market North",
            "halal cart special features" to "Halal Cart @ Market North",
            "halal cart sweets" to "Halal Cart @ Market North"),
        PSUDiningHall.EAST to mapOf("aloha fresh" to "Aloha Fresh Poke Bowls",
            "bowls" to "Bowls @ East",
            "east philly" to "East Philly Cheesesteaks",
            "edge" to "Edge @ East",
            "fresco" to "Fresco @ East",
            "pizza" to "Pizza @ East"),
        PSUDiningHall.SOUTH to mapOf("amici" to "Amici Italian Market",
            "bowls" to "Bowls @ South",
            "choolaah" to "Choolaah Indian BBQ",
            "choolah" to "Choolaah Indian BBQ",
            "edge" to "Edge @ South",
            "on a roll" to "On a Roll @ South"),
        PSUDiningHall.WEST to mapOf("edge" to "Edge @ West",
            "state chik n" to "State Chik'n in Waring"),
        PSUDiningHall.POLLOCK to mapOf("edge" to "Edge @ Pollock",
            "edge online menu" to "Edge @ Pollock",
            "fresco" to "Fresco @ Pollock",
            "mpk asia" to "Market Pollock Asia Kitchen")
    )
    fun key(hall: PSUDiningHall, section: String): String {
        val normalized = normalizeDiningText(section)
        return aliases[hall]?.get(normalized)?.let(::normalizeDiningText) ?: normalized
    }
}
