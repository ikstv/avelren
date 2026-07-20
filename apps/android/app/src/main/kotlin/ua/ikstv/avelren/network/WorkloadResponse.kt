package ua.ikstv.avelren.network

import java.time.Instant
import ua.ikstv.avelren.domain.WorkloadFreshness
import ua.ikstv.avelren.domain.WorkloadSnapshot

/** Wire model for `GET /v1/workload`. JSON decoding is added with the API client. */
data class WorkloadResponse(
    val locationId: String? = null,
    val vehicleCount: Int? = null,
    val observedAt: String? = null,
    val receivedAt: String? = null,
    val freshness: String? = null,
    val sequence: Long? = null,
) {
    fun toDomain(isDemo: Boolean = false): WorkloadSnapshot = WorkloadSnapshot(
        locationId = locationId?.takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("locationId is required"),
        vehicleCount = vehicleCount?.takeIf { it >= 0 } ?: throw IllegalArgumentException("vehicleCount is required"),
        observedAt = Instant.parse(observedAt ?: throw IllegalArgumentException("observedAt is required")),
        receivedAt = Instant.parse(receivedAt ?: throw IllegalArgumentException("receivedAt is required")),
        freshness = when ((freshness ?: "").lowercase()) {
            "fresh" -> WorkloadFreshness.FRESH
            "stale" -> WorkloadFreshness.STALE
            "unknown" -> WorkloadFreshness.UNKNOWN
            else -> throw IllegalArgumentException("Unsupported freshness value")
        },
        sequence = sequence?.takeIf { it >= 0 } ?: throw IllegalArgumentException("sequence is required"),
        isDemo = isDemo,
    )
}
