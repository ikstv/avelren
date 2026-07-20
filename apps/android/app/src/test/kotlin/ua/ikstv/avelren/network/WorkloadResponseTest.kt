package ua.ikstv.avelren.network

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import ua.ikstv.avelren.domain.WorkloadFreshness

class WorkloadResponseTest {
    @Test
    fun `maps the server contract to the domain model`() {
        val result = WorkloadResponse(
            locationId = "demo",
            vehicleCount = 125,
            observedAt = "2026-07-20T08:00:00.000Z",
            receivedAt = "2026-07-20T08:00:01.000Z",
            freshness = "fresh",
            sequence = 3L,
        ).toDomain()

        assertEquals("demo", result.locationId)
        assertEquals(125, result.vehicleCount)
        assertEquals(Instant.parse("2026-07-20T08:00:00.000Z"), result.observedAt)
        assertEquals(WorkloadFreshness.FRESH, result.freshness)
        assertEquals(3L, result.sequence)
        assertFalse(result.isDemo)
    }

    @Test
    fun `rejects an unknown freshness value`() {
        val response = WorkloadResponse(
            locationId = "demo",
            vehicleCount = 125,
            observedAt = "2026-07-20T08:00:00.000Z",
            receivedAt = "2026-07-20T08:00:01.000Z",
            freshness = "invalid",
            sequence = 3L,
        )

        assertThrows(IllegalArgumentException::class.java) {
            response.toDomain()
        }
    }
}
