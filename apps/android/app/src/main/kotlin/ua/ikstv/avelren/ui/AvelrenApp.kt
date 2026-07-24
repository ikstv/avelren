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
import ua.ikstv.avelren.R
import ua.ikstv.avelren.domain.WorkloadSnapshot

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
                                renderState.snapshot.freshness.name.lowercase(),
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = stringResource(
                                R.string.snapshot_sequence,
                                renderState.snapshot.sequence,
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
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
