package ua.ikstv.avelren.ui

import ua.ikstv.avelren.domain.WorkloadSnapshot

sealed interface WorkloadUiState {
    object Loading : WorkloadUiState
    data class Success(val snapshot: WorkloadSnapshot) : WorkloadUiState
    object Error : WorkloadUiState
}
