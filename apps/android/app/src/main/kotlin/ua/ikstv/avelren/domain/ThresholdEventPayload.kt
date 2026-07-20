package ua.ikstv.avelren.domain

/**
 * A threshold event already calculated and emitted by the Avelren server.
 *
 * The Android client displays this payload; it does not derive threshold events.
 */
data class ThresholdEventPayload(
    val eventId: String,
    val locationId: String,
    val vehicleCount: Int,
    val crossedThresholds: List<Int>,
    val observedAtEpochMillis: Long,
) {
    init {
        require(eventId.isNotBlank()) { "eventId must not be blank" }
        require(locationId.isNotBlank()) { "locationId must not be blank" }
        require(vehicleCount >= 0) { "vehicleCount must not be negative" }
        require(crossedThresholds.isNotEmpty()) { "crossedThresholds must not be empty" }
        require(crossedThresholds.all { it > 0 }) { "crossedThresholds must be positive" }
        require(observedAtEpochMillis >= 0L) { "observedAtEpochMillis must not be negative" }
    }

    fun formattedThresholds(): String = crossedThresholds.joinToString(separator = ", ")
}
