package ua.ikstv.avelren.ui

import java.time.Instant
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import ua.ikstv.avelren.domain.WorkloadFreshness
import ua.ikstv.avelren.domain.WorkloadSnapshot
import ua.ikstv.avelren.repository.WorkloadRepository

@OptIn(ExperimentalCoroutinesApi::class)
class WorkloadViewModelTest {
    private val defaultSnapshot = WorkloadSnapshot(
        locationId = "demo",
        vehicleCount = 42,
        observedAt = Instant.parse("2026-07-20T08:00:00.000Z"),
        receivedAt = Instant.parse("2026-07-20T08:00:01.000Z"),
        freshness = WorkloadFreshness.FRESH,
        sequence = 1L,
        isDemo = true,
    )

    @Test
    fun `initial state is loading`() = runTest {
        val repository = SequencedWorkloadRepository(listOf(Result.success(defaultSnapshot)))
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = WorkloadViewModel(
            workloadRepository = repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        assertTrue(viewModel.state.value is WorkloadUiState.Loading)
    }

    @Test
    fun `successful load updates state to success`() = runTest {
        val repository = SequencedWorkloadRepository(listOf(Result.success(defaultSnapshot)))
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = WorkloadViewModel(
            workloadRepository = repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        advanceUntilIdle()

        assertEquals(1, repository.calls)
        assertEquals(
            WorkloadUiState.Success(defaultSnapshot),
            viewModel.state.value,
        )
    }

    @Test
    fun `error load updates state to error`() = runTest {
        val repository = SequencedWorkloadRepository(
            listOf(Result.failure(IllegalStateException("boom"))),
        )
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = WorkloadViewModel(
            workloadRepository = repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        advanceUntilIdle()

        assertEquals(1, repository.calls)
        assertTrue(viewModel.state.value is WorkloadUiState.Error)
    }

    @Test
    fun `retry after error performs another repository call`() = runTest {
        val repository = SequencedWorkloadRepository(
            listOf(
                Result.failure(IllegalStateException("boom")),
                Result.success(defaultSnapshot),
            ),
        )
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = WorkloadViewModel(
            repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        advanceUntilIdle()
        assertTrue(viewModel.state.value is WorkloadUiState.Error)
        assertEquals(1, repository.calls)

        viewModel.retry()
        runCurrent()
        advanceUntilIdle()

        assertEquals(2, repository.calls)
        assertEquals(
            WorkloadUiState.Success(defaultSnapshot),
            viewModel.state.value,
        )
    }

    @Test
    fun `retries while loading are ignored`() = runTest {
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val repository = DelayedWorkloadRepository(defaultSnapshot, 1_000)
        val viewModel = WorkloadViewModel(
            repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        runCurrent()
        assertEquals(1, repository.calls)

        viewModel.retry()
        viewModel.retry()
        assertEquals(1, repository.calls)

        advanceUntilIdle()
        assertEquals(1, repository.calls)
        assertEquals(WorkloadUiState.Success(defaultSnapshot), viewModel.state.value)
    }

    @Test
    fun `manual refresh after success performs another repository call`() = runTest {
        val secondSnapshot = defaultSnapshot.copy(sequence = 2L)
        val repository = SequencedWorkloadRepository(
            listOf(Result.success(defaultSnapshot), Result.success(secondSnapshot)),
        )
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = WorkloadViewModel(
            repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        advanceUntilIdle()
        assertEquals(1, repository.calls)
        assertEquals(
            WorkloadUiState.Success(defaultSnapshot),
            viewModel.state.value,
        )

        viewModel.retry()
        advanceUntilIdle()

        assertEquals(2, repository.calls)
        assertEquals(
            WorkloadUiState.Success(secondSnapshot),
            viewModel.state.value,
        )
    }

    @Test
    fun `retry from success keeps previous snapshot while refreshing`() = runTest {
        val secondSnapshot = defaultSnapshot.copy(sequence = 2L)
        val repository = TimedWorkloadRepository(
            listOf(Result.success(defaultSnapshot), Result.success(secondSnapshot)),
            delaysMs = listOf(0L, 500L),
        )
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = WorkloadViewModel(
            repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        advanceUntilIdle()
        assertEquals(
            WorkloadUiState.Success(defaultSnapshot),
            viewModel.state.value,
        )

        viewModel.retry()
        runCurrent()
        val refreshingState = viewModel.state.value
        assertEquals(
            WorkloadUiState.Success(defaultSnapshot, isRefreshing = true, refreshFailed = false),
            refreshingState,
        )

        advanceUntilIdle()
        assertEquals(
            WorkloadUiState.Success(secondSnapshot, isRefreshing = false, refreshFailed = false),
            viewModel.state.value,
        )
    }

    @Test
    fun `retry from success preserves snapshot and marks refresh failure`() = runTest {
        val repository = TimedWorkloadRepository(
            listOf(
                Result.success(defaultSnapshot),
                Result.failure(IllegalStateException("boom")),
            ),
            delaysMs = listOf(0L, 500L),
        )
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = WorkloadViewModel(
            repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        advanceUntilIdle()
        assertEquals(
            WorkloadUiState.Success(defaultSnapshot),
            viewModel.state.value,
        )

        viewModel.retry()
        runCurrent()
        val refreshingState = viewModel.state.value
        assertEquals(
            WorkloadUiState.Success(defaultSnapshot, isRefreshing = true, refreshFailed = false),
            refreshingState,
        )

        advanceUntilIdle()
        assertEquals(
            WorkloadUiState.Success(defaultSnapshot, isRefreshing = false, refreshFailed = true),
            viewModel.state.value,
        )
    }

    @Test
    fun `refresh failure can be retried and clears refresh failure`() = runTest {
        val secondSnapshot = defaultSnapshot.copy(sequence = 3L)
        val repository = TimedWorkloadRepository(
            listOf(
                Result.success(defaultSnapshot),
                Result.failure(IllegalStateException("boom")),
                Result.success(secondSnapshot),
            ),
            delaysMs = listOf(0L, 500L, 0L),
        )
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = WorkloadViewModel(
            repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        advanceUntilIdle()
        viewModel.retry()
        advanceUntilIdle()
        assertEquals(
            WorkloadUiState.Success(defaultSnapshot, isRefreshing = false, refreshFailed = true),
            viewModel.state.value,
        )

        viewModel.retry()
        advanceUntilIdle()
        assertEquals(
            WorkloadUiState.Success(secondSnapshot, isRefreshing = false, refreshFailed = false),
            viewModel.state.value,
        )
    }

    @Test
    fun `duplicate retries during refresh are ignored`() = runTest {
        val repository = TimedWorkloadRepository(
            listOf(
                Result.success(defaultSnapshot),
                Result.success(defaultSnapshot.copy(sequence = 2L)),
            ),
            delaysMs = listOf(0L, 500L),
        )
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = WorkloadViewModel(
            repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        advanceUntilIdle()
        viewModel.retry()
        viewModel.retry()
        viewModel.retry()
        advanceUntilIdle()

        assertEquals(2, repository.calls)
        assertEquals(
            WorkloadUiState.Success(
                defaultSnapshot.copy(sequence = 2L),
                isRefreshing = false,
                refreshFailed = false,
            ),
            viewModel.state.value,
        )
    }

    @Test
    fun `repository is never called on main dispatcher`() = runTest {
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val repository = DispatchInspectingWorkloadRepository(
            workload = defaultSnapshot,
            expectedMainDispatcher = Dispatchers.Main,
            expectedWorkloadDispatcher = ioDispatcher,
        )
        val viewModel = WorkloadViewModel(
            workloadRepository = repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )
        advanceUntilIdle()

        assertFalse(repository.calledOnMainDispatcher)
        assertTrue(repository.calledOnExpectedDispatcher)
    }

    @Test
    fun `recomposition does not start additional load`() = runTest {
        val loadDispatcher = StandardTestDispatcher(testScheduler)
        val ioDispatcher = StandardTestDispatcher(testScheduler)
        val repository = SequencedWorkloadRepository(listOf(Result.success(defaultSnapshot)))
        val viewModel = WorkloadViewModel(
            workloadRepository = repository,
            ioDispatcher = ioDispatcher,
            loadDispatcher = loadDispatcher,
        )

        advanceUntilIdle()
        assertEquals(1, repository.calls)

        repeat(3) {
            val state: StateFlow<WorkloadUiState> = viewModel.state
            assertEquals(1, repository.calls)
            assertEquals(WorkloadUiState.Success(defaultSnapshot), state.value)
        }
    }
}

private class SequencedWorkloadRepository(private val responses: List<Result<WorkloadSnapshot>>) :
    WorkloadRepository {
    var calls = 0
        private set

    private var responseIndex = 0

    override suspend fun getLatest(): WorkloadSnapshot {
        calls++
        val response = responses[responseIndex]
        responseIndex = (responseIndex + 1).coerceAtMost(responses.lastIndex)
        return response.getOrThrow()
    }
}

private class TimedWorkloadRepository(
    private val responses: List<Result<WorkloadSnapshot>>,
    private val delaysMs: List<Long> = emptyList(),
) : WorkloadRepository {
    var calls = 0
        private set

    private var responseIndex = 0

    override suspend fun getLatest(): WorkloadSnapshot {
        calls++
        val response = responses[responseIndex]
        val delayMs = delaysMs.getOrElse(responseIndex) { 0L }
        responseIndex = (responseIndex + 1).coerceAtMost(responses.lastIndex)
        if (delayMs > 0) {
            delay(delayMs)
        }
        return response.getOrThrow()
    }
}

private class DelayedWorkloadRepository(
    private val workload: WorkloadSnapshot,
    private val delayMs: Long,
) : WorkloadRepository {
    var calls = 0
        private set

    override suspend fun getLatest(): WorkloadSnapshot {
        calls++
        delay(delayMs)
        return workload
    }
}

private class DispatchInspectingWorkloadRepository(
    private val workload: WorkloadSnapshot,
    private val expectedMainDispatcher: CoroutineDispatcher,
    private val expectedWorkloadDispatcher: CoroutineDispatcher,
) : WorkloadRepository {
    var calledOnMainDispatcher = false
        private set

    var calledOnExpectedDispatcher = false
        private set

    override suspend fun getLatest(): WorkloadSnapshot {
        val currentDispatcher = coroutineContext[ContinuationInterceptor] as? CoroutineDispatcher
        if (currentDispatcher == expectedMainDispatcher) {
            calledOnMainDispatcher = true
        }
        if (currentDispatcher == expectedWorkloadDispatcher) {
            calledOnExpectedDispatcher = true
        }
        return workload
    }
}
