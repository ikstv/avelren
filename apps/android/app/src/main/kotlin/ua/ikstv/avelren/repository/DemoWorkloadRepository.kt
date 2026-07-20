package ua.ikstv.avelren.repository

import java.time.Instant
import ua.ikstv.avelren.domain.WorkloadFreshness
import ua.ikstv.avelren.domain.WorkloadSnapshot

class DemoWorkloadRepository : WorkloadRepository {
    override suspend fun getLatest(): WorkloadSnapshot = WorkloadSnapshot(
        locationId = "demo",
        vehicleCount = 120,
        observedAt = Instant.EPOCH,
        receivedAt = Instant.EPOCH,
        freshness = WorkloadFreshness.UNKNOWN,
        sequence = 0L,
        isDemo = true,
    )
}
