package ua.ikstv.avelren.ui

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import ua.ikstv.avelren.domain.WorkloadFreshness
import ua.ikstv.avelren.domain.WorkloadSnapshot

class AvelrenAppTest {
    private val demoSnapshot = WorkloadSnapshot(
        locationId = "demo",
        vehicleCount = 42,
        observedAt = Instant.parse("2026-07-20T08:00:00Z"),
        receivedAt = Instant.parse("2026-07-20T08:00:01Z"),
        freshness = WorkloadFreshness.FRESH,
        sequence = 1L,
        isDemo = true,
    )
    private val liveSnapshot = demoSnapshot.copy(isDemo = false)

    @Test
    fun `loading maps to loading render state`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Loading)
        assertTrue(state is WorkloadRenderState.Loading)
    }

    @Test
    fun `success maps to snapshot render state`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Success(demoSnapshot))

        assertTrue(state is WorkloadRenderState.Success)
        state as WorkloadRenderState.Success
        assertEquals(demoSnapshot, state.snapshot)
    }

    @Test
    fun `error maps to error render state`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Error)
        assertTrue(state is WorkloadRenderState.Error)
    }

    @Test
    fun `loading contains no payload`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Loading)
        assertTrue(state !is WorkloadRenderState.Success)
    }

    @Test
    fun `demo snapshot shows indicator`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Success(demoSnapshot))
        assertTrue(shouldShowDemoIndicator(state))
    }

    @Test
    fun `live snapshot hides demo indicator`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Success(liveSnapshot))
        assertTrue(!shouldShowDemoIndicator(state))
    }

    @Test
    fun `format received time is UTC deterministic`() {
        assertEquals("2026-07-20 08:00:01 UTC", formatReceivedAt(demoSnapshot.receivedAt))
    }

    @Test
    fun `format observed time is UTC deterministic`() {
        assertEquals("2026-07-20 08:00:00 UTC", formatObservedAt(demoSnapshot.observedAt))
    }

    @Test
    fun `format delivery delay returns seconds`() {
        val delay = formatDeliveryDelaySeconds(
            Instant.parse("2026-07-20T08:00:00Z"),
            Instant.parse("2026-07-20T08:00:05Z"),
        )
        assertEquals(5L, delay)
    }

    @Test
    fun `format delivery delay is unknown when received before observed`() {
        val delay = formatDeliveryDelaySeconds(
            Instant.parse("2026-07-20T08:00:05Z"),
            Instant.parse("2026-07-20T08:00:00Z"),
        )
        assertEquals(null, delay)
    }

    @Test
    fun `freshness label uses localized resource for fresh`() {
        assertEquals(R.string.snapshot_freshness_fresh, freshnessLabelResource(WorkloadFreshness.FRESH))
    }

    @Test
    fun `freshness label uses localized resource for stale`() {
        assertEquals(R.string.snapshot_freshness_stale, freshnessLabelResource(WorkloadFreshness.STALE))
    }

    @Test
    fun `freshness label uses localized resource for unknown`() {
        assertEquals(R.string.snapshot_freshness_unknown, freshnessLabelResource(WorkloadFreshness.UNKNOWN))
    }
}
