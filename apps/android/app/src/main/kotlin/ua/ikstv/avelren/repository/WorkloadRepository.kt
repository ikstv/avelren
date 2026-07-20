package ua.ikstv.avelren.repository

import ua.ikstv.avelren.domain.WorkloadSnapshot

interface WorkloadRepository {
    suspend fun getLatest(): WorkloadSnapshot
}
