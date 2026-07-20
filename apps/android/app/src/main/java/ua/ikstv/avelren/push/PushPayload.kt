package ua.ikstv.avelren.push

import java.time.Instant

data class PushPayload(
    val schemaVersion: String,
    val eventId: String,
    val locationId: String,
    val threshold: Int,
    val observedCount: Int,
    val observedAt: Instant,
)

object PushPayloadParser {
    private val fields = setOf(
        "schemaVersion", "eventId", "locationId", "threshold", "observedCount", "observedAt",
    )
    private val eventPattern = Regex("^[a-f0-9]{64}$")
    private val locationPattern = Regex("^[A-Za-z0-9._-]{1,128}$")

    fun parse(data: Map<String, String>): PushPayload? {
        if (data.keys != fields || data["schemaVersion"] != "1") return null
        val eventId = data["eventId"]?.takeIf(eventPattern::matches) ?: return null
        val locationId = data["locationId"]?.takeIf(locationPattern::matches) ?: return null
        val threshold = data["threshold"]?.toIntOrNull()?.takeIf { it in 1..1_000_000 } ?: return null
        val observedCount = data["observedCount"]?.toIntOrNull()
            ?.takeIf { it in threshold..1_000_000 } ?: return null
        val observedAt = try {
            Instant.parse(data["observedAt"])
        } catch (_: RuntimeException) {
            return null
        }
        return PushPayload("1", eventId, locationId, threshold, observedCount, observedAt)
    }
}
