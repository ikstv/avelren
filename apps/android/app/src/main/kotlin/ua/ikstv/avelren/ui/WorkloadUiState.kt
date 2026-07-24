package ua.ikstv.avelren.ui

import ua.ikstv.avelren.domain.WorkloadSnapshot

sealed interface WorkloadUiState {
    object Loading : WorkloadUiState
    data class Success(
        val snapshot: WorkloadSnapshot,
        val isRefreshing: Boolean = false,
        val refreshFailed: Boolean = false,
    ) : WorkloadUiState
    object Error : WorkloadUiState
}
