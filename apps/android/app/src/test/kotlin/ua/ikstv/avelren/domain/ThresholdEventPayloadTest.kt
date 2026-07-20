package ua.ikstv.avelren.domain

import org.junit.Assert.assertEquals
import org.junit.Test

class ThresholdEventPayloadTest {
    @Test
    fun `formats one threshold supplied by the server`() {
        val payload = payload(crossedThresholds = listOf(50))

        assertEquals("50", payload.formattedThresholds())
    }

    @Test
    fun `formats multiple thresholds in the order supplied by the server`() {
        val payload = payload(crossedThresholds = listOf(50, 100, 150))

        assertEquals("50, 100, 150", payload.formattedThresholds())
    }

    private fun payload(crossedThresholds: List<Int>) = ThresholdEventPayload(
        eventId = "demo-event",
        locationId = "demo",
        vehicleCount = 160,
        crossedThresholds = crossedThresholds,
        observedAtEpochMillis = 0L,
    )
}
