package ua.ikstv.avelren.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Button
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import ua.ikstv.avelren.R
import ua.ikstv.avelren.domain.WorkloadFreshness
import ua.ikstv.avelren.domain.WorkloadSnapshot

private val workloadTimestampFormatter: DateTimeFormatter = DateTimeFormatter
    .ofPattern("yyyy-MM-dd HH:mm:ss 'UTC'")
    .withZone(ZoneOffset.UTC)

internal sealed interface WorkloadRenderState {
    data object Loading : WorkloadRenderState
    data class Success(val snapshot: WorkloadSnapshot) : WorkloadRenderState
    data object Error : WorkloadRenderState
}

internal fun mapWorkloadRenderState(state: WorkloadUiState): WorkloadRenderState = when (state) {
    WorkloadUiState.Loading -> WorkloadRenderState.Loading
    is WorkloadUiState.Success -> WorkloadRenderState.Success(state.snapshot)
    WorkloadUiState.Error -> WorkloadRenderState.Error
}

internal fun shouldShowDemoIndicator(state: WorkloadRenderState): Boolean =
    state is WorkloadRenderState.Success && state.snapshot.isDemo

private fun formatWorkloadTimestamp(timestamp: Instant): String = workloadTimestampFormatter.format(timestamp)

internal fun formatReceivedAt(receivedAt: Instant): String = formatWorkloadTimestamp(receivedAt)

internal fun formatObservedAt(observedAt: Instant): String = formatWorkloadTimestamp(observedAt)

internal fun formatDeliveryDelaySeconds(observedAt: Instant, receivedAt: Instant): Long? {
    val delaySeconds = Duration.between(observedAt, receivedAt).seconds
    return if (delaySeconds >= 0L) {
        delaySeconds
    } else {
        null
    }
}

internal fun freshnessLabelResource(freshness: WorkloadFreshness): Int = when (freshness) {
    WorkloadFreshness.FRESH -> R.string.snapshot_freshness_fresh
    WorkloadFreshness.STALE -> R.string.snapshot_freshness_stale
    WorkloadFreshness.UNKNOWN -> R.string.snapshot_freshness_unknown
}

internal fun freshnessWarningResource(freshness: WorkloadFreshness): Int? = when (freshness) {
    WorkloadFreshness.FRESH -> null
    WorkloadFreshness.STALE -> R.string.snapshot_freshness_stale_warning
    WorkloadFreshness.UNKNOWN -> R.string.snapshot_freshness_unknown_warning
}

@Composable
fun AvelrenApp(state: WorkloadUiState, onRetry: () -> Unit) {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = stringResource(R.string.placeholder_title),
                    style = MaterialTheme.typography.headlineMedium,
                    modifier = Modifier.padding(PaddingValues(bottom = 12.dp)),
                )
                when (val renderState = mapWorkloadRenderState(state)) {
                    WorkloadRenderState.Loading -> {
                        Text(
                            text = stringResource(R.string.state_loading),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                    }

                    is WorkloadRenderState.Success -> {
                        Text(
                            text = stringResource(
                                R.string.snapshot_location,
                                renderState.snapshot.locationId,
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = stringResource(
                                R.string.snapshot_vehicle_count,
                                renderState.snapshot.vehicleCount,
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = stringResource(
                                R.string.snapshot_freshness,
                                stringResource(freshnessLabelResource(renderState.snapshot.freshness)),
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        freshnessWarningResource(renderState.snapshot.freshness)?.let { warningRes ->
                            Text(
                                text = stringResource(warningRes),
                                style = MaterialTheme.typography.bodyLarge,
                            )
                            Spacer(modifier = Modifier.height(8.dp))
                        }
                        Text(
                            text = stringResource(
                                R.string.snapshot_sequence,
                                renderState.snapshot.sequence,
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = stringResource(
                                R.string.snapshot_observed,
                                formatObservedAt(renderState.snapshot.observedAt),
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = stringResource(
                                R.string.snapshot_received,
                                formatReceivedAt(renderState.snapshot.receivedAt),
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        val delaySeconds = formatDeliveryDelaySeconds(
                            renderState.snapshot.observedAt,
                            renderState.snapshot.receivedAt,
                        )
                        if (delaySeconds != null) {
                            Text(
                                text = stringResource(R.string.snapshot_delay_seconds, delaySeconds),
                                style = MaterialTheme.typography.bodyLarge,
                            )
                        } else {
                            Text(
                                text = stringResource(R.string.snapshot_delay_unknown),
                                style = MaterialTheme.typography.bodyLarge,
                            )
                        }
                        if (shouldShowDemoIndicator(renderState)) {
                            Spacer(modifier = Modifier.height(8.dp))
                            Text(
                                text = stringResource(R.string.snapshot_demo),
                                style = MaterialTheme.typography.bodyLarge,
                            )
                        }
                        Spacer(modifier = Modifier.height(12.dp))
                        Button(onClick = onRetry, modifier = Modifier.fillMaxWidth(0.5f)) {
                            Text(text = stringResource(R.string.action_refresh))
                        }
                    }

                    WorkloadRenderState.Error -> {
                        Text(
                            text = stringResource(R.string.state_error),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(12.dp))
                        Button(onClick = onRetry, modifier = Modifier.fillMaxWidth(0.5f)) {
                            Text(text = stringResource(R.string.action_retry))
                        }
                    }
                }
            }
        }
    }
}
