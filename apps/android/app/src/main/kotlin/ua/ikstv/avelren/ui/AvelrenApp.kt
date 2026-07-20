package ua.ikstv.avelren.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import ua.ikstv.avelren.R
import ua.ikstv.avelren.domain.WorkloadSnapshot
import ua.ikstv.avelren.repository.WorkloadRepository

@Composable
fun AvelrenApp(workloadRepository: WorkloadRepository) {
    val snapshot by produceState<WorkloadSnapshot?>(
        initialValue = null,
        key1 = workloadRepository,
    ) {
        value = workloadRepository.getLatest()
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
                )
                Text(
                    text = snapshot?.let {
                        stringResource(R.string.placeholder_count, it.vehicleCount)
                    } ?: stringResource(R.string.placeholder_loading),
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
        }
    }
}
