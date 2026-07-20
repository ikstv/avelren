package ua.ikstv.avelren.domain

import java.time.Instant

enum class WorkloadFreshness {
    FRESH,
    STALE,
    UNKNOWN,
}

data class WorkloadSnapshot(
    val locationId: String,
    val vehicleCount: Int,
    val observedAt: Instant,
    val receivedAt: Instant,
    val freshness: WorkloadFreshness,
    val sequence: Long,
    val isDemo: Boolean,
) {
    init {
        require(locationId.isNotBlank()) { "locationId must not be blank" }
        require(vehicleCount >= 0) { "vehicleCount must not be negative" }
        require(sequence >= 0L) { "sequence must not be negative" }
    }
}
