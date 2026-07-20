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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import kotlinx.coroutines.launch
import ua.ikstv.avelren.R
import ua.ikstv.avelren.domain.WorkloadSnapshot
import ua.ikstv.avelren.repository.WorkloadRepository

@Composable
fun AvelrenApp(workloadRepository: WorkloadRepository) {
    var state by remember { mutableStateOf<LoadState>(LoadState.Loading) }
    val coroutineScope = rememberCoroutineScope()
    val load: () -> Unit = {
        coroutineScope.launch {
            state = LoadState.Loading
            state = try {
                LoadState.Success(workloadRepository.getLatest())
            } catch (_: Exception) {
                LoadState.Error
            }
        }
    }

    LaunchedEffect(workloadRepository) {
        load()
    }

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
                when (val currentState = state) {
                    LoadState.Loading -> {
                        Text(
                            text = stringResource(R.string.state_loading),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                    }
                    is LoadState.Success -> {
                        Text(
                            text = stringResource(
                                R.string.snapshot_location,
                                currentState.snapshot.locationId,
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = stringResource(
                                R.string.snapshot_vehicle_count,
                                currentState.snapshot.vehicleCount,
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = stringResource(
                                R.string.snapshot_freshness,
                                currentState.snapshot.freshness.name.lowercase(),
                            ),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = stringResource(R.string.snapshot_sequence, currentState.snapshot.sequence),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                    }
                    LoadState.Error -> {
                        Text(
                            text = stringResource(R.string.state_error),
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Spacer(modifier = Modifier.height(12.dp))
                        Button(onClick = load, modifier = Modifier.fillMaxWidth(0.5f)) {
                            Text(text = stringResource(R.string.action_retry))
                        }
                    }
                }
            }
        }
    }
}

private sealed interface LoadState {
    object Loading : LoadState
    data class Success(val snapshot: WorkloadSnapshot) : LoadState
    object Error : LoadState
}
