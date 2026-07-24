package ua.ikstv.avelren.ui

import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
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

    @Test
    fun `loading maps to loading render state`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Loading)
        assertIs<WorkloadRenderState.Loading>(state)
    }

    @Test
    fun `success maps to snapshot render state`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Success(demoSnapshot))

        assertIs<WorkloadRenderState.Success>(state)
        assertEquals(demoSnapshot, state.snapshot)
    }

    @Test
    fun `error maps to error render state`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Error)
        assertIs<WorkloadRenderState.Error>(state)
    }

    @Test
    fun `loading contains no payload`() {
        val state = mapWorkloadRenderState(WorkloadUiState.Loading)
        assertTrue(state !is WorkloadRenderState.Success)
    }
}
