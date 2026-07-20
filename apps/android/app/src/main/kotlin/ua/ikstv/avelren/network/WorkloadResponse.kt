package ua.ikstv.avelren.network

import java.time.Instant
import ua.ikstv.avelren.domain.WorkloadFreshness
import ua.ikstv.avelren.domain.WorkloadSnapshot

/** Wire model for `GET /v1/workload`. JSON decoding is added with the API client. */
data class WorkloadResponse(
    val locationId: String,
    val vehicleCount: Int,
    val observedAt: String,
    val receivedAt: String,
    val freshness: String,
    val sequence: Long,
) {
    fun toDomain(isDemo: Boolean = false): WorkloadSnapshot = WorkloadSnapshot(
        locationId = locationId,
        vehicleCount = vehicleCount,
        observedAt = Instant.parse(observedAt),
        receivedAt = Instant.parse(receivedAt),
        freshness = when (freshness) {
            "fresh" -> WorkloadFreshness.FRESH
            "stale" -> WorkloadFreshness.STALE
            "unknown" -> WorkloadFreshness.UNKNOWN
            else -> throw IllegalArgumentException("Unsupported freshness value")
        },
        sequence = sequence,
        isDemo = isDemo,
    )
}
