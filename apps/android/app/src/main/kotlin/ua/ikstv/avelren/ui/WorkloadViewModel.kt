package ua.ikstv.avelren.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.CreationExtras
import androidx.lifecycle.viewModelScope
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ua.ikstv.avelren.repository.WorkloadRepository

class WorkloadViewModel(
    private val workloadRepository: WorkloadRepository,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val loadDispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
) : ViewModel() {

    private val _state = MutableStateFlow<WorkloadUiState>(WorkloadUiState.Loading)
    val state: StateFlow<WorkloadUiState> = _state.asStateFlow()
    private val loading = AtomicBoolean(false)

    init {
        load()
    }

    fun retry() {
        load()
    }

    private fun load() {
        if (!loading.compareAndSet(false, true)) {
            return
        }
        viewModelScope.launch(loadDispatcher) {
            _state.value = WorkloadUiState.Loading
            _state.value = try {
                WorkloadUiState.Success(withContext(ioDispatcher) {
                    workloadRepository.getLatest()
                })
            } catch (_: Exception) {
                WorkloadUiState.Error
            } finally {
                loading.set(false)
            }
        }
    }

    class Factory(
        private val workloadRepository: WorkloadRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            return create(modelClass, CreationExtras.Empty)
        }

        override fun <T : ViewModel> create(
            modelClass: Class<T>,
            extras: CreationExtras,
        ): T {
            require(modelClass == WorkloadViewModel::class.java) {
                "Unexpected ViewModel class ${modelClass.name}"
            }
            return WorkloadViewModel(workloadRepository = workloadRepository) as T
        }
    }
}
