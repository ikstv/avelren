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
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
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
        val (mainDispatcher, ioDispatcher) = testDispatchers(testScheduler)
        Dispatchers.setMain(mainDispatcher)
        try {
            val viewModel = WorkloadViewModel(
                workloadRepository = repository,
                ioDispatcher = ioDispatcher,
            )

            assertTrue(viewModel.state.value is WorkloadUiState.Loading)
        } finally {
            Dispatchers.resetMain()
        }

    }

    private fun testDispatchers(testScheduler: TestCoroutineScheduler): Pair<TestDispatcher, TestDispatcher> {
        return StandardTestDispatcher(testScheduler) to StandardTestDispatcher(testScheduler)
    }

    @Test
    fun `successful load updates state to success`() = runTest {
        val repository = SequencedWorkloadRepository(listOf(Result.success(defaultSnapshot)))
        val (mainDispatcher, ioDispatcher) = testDispatchers(testScheduler)
        Dispatchers.setMain(mainDispatcher)
        try {
            val viewModel = WorkloadViewModel(
                workloadRepository = repository,
                ioDispatcher = ioDispatcher,
            )

            advanceUntilIdle()

            assertEquals(1, repository.calls)
            assertEquals(
                WorkloadUiState.Success(defaultSnapshot),
                viewModel.state.value,
            )
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `error load updates state to error`() = runTest {
        val repository = SequencedWorkloadRepository(
            listOf(Result.failure(IllegalStateException("boom"))),
        )
        val (mainDispatcher, ioDispatcher) = testDispatchers(testScheduler)
        Dispatchers.setMain(mainDispatcher)
        try {
            val viewModel = WorkloadViewModel(
                workloadRepository = repository,
                ioDispatcher = ioDispatcher,
            )

            advanceUntilIdle()

            assertEquals(1, repository.calls)
            assertTrue(viewModel.state.value is WorkloadUiState.Error)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `retry after error performs another repository call`() = runTest {
        val repository = SequencedWorkloadRepository(
            listOf(
                Result.failure(IllegalStateException("boom")),
                Result.success(defaultSnapshot),
            ),
        )
        val (mainDispatcher, ioDispatcher) = testDispatchers(testScheduler)
        Dispatchers.setMain(mainDispatcher)
        try {
            val viewModel = WorkloadViewModel(repository, ioDispatcher)

            advanceUntilIdle()
            runCurrent()
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
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `retries while loading are ignored`() = runTest {
        val (mainDispatcher, ioDispatcher) = testDispatchers(testScheduler)
        val repository = DelayedWorkloadRepository(defaultSnapshot, 1_000)
        Dispatchers.setMain(mainDispatcher)
        try {
            val viewModel = WorkloadViewModel(repository, ioDispatcher)

            runCurrent()
            assertEquals(1, repository.calls)

            viewModel.retry()
            viewModel.retry()
            assertEquals(1, repository.calls)

            advanceUntilIdle()
            assertEquals(1, repository.calls)
            assertEquals(WorkloadUiState.Success(defaultSnapshot), viewModel.state.value)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `repository is never called on main dispatcher`() = runTest {
        val (mainDispatcher, ioDispatcher) = testDispatchers(testScheduler)
        val repository = DispatchInspectingWorkloadRepository(
            workload = defaultSnapshot,
            expectedMainDispatcher = mainDispatcher,
            expectedWorkloadDispatcher = ioDispatcher,
        )
        Dispatchers.setMain(mainDispatcher)
        try {
            val viewModel = WorkloadViewModel(repository, ioDispatcher)
            advanceUntilIdle()

            assertFalse(repository.calledOnMainDispatcher)
            assertTrue(repository.calledOnExpectedDispatcher)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `recomposition does not start additional load`() = runTest {
        val repository = SequencedWorkloadRepository(listOf(Result.success(defaultSnapshot)))
        val (mainDispatcher, ioDispatcher) = testDispatchers(testScheduler)
        Dispatchers.setMain(mainDispatcher)
        try {
            val viewModel = WorkloadViewModel(
                workloadRepository = repository,
                ioDispatcher = ioDispatcher,
            )

            advanceUntilIdle()
            assertEquals(1, repository.calls)

            repeat(3) {
                val state: StateFlow<WorkloadUiState> = viewModel.state
                assertEquals(1, repository.calls)
                assertEquals(WorkloadUiState.Success(defaultSnapshot), state.value)
            }
        } finally {
            Dispatchers.resetMain()
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
