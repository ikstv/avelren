package ua.ikstv.avelren

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.getValue
import ua.ikstv.avelren.repository.ApiWorkloadRepository
import ua.ikstv.avelren.repository.WorkloadRepository
import ua.ikstv.avelren.ui.WorkloadUiState
import ua.ikstv.avelren.ui.AvelrenApp
import ua.ikstv.avelren.ui.WorkloadViewModel
import ua.ikstv.avelren.push.shouldRequestNotificationPermission
import ua.ikstv.avelren.push.shouldRefreshFromNotificationAction

class MainActivity : ComponentActivity() {
    private val workloadRepository: WorkloadRepository = ApiWorkloadRepository()
    private val workloadViewModel: WorkloadViewModel by viewModels {
        WorkloadViewModel.Factory(workloadRepository)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionOnce()
        setContent {
            val state: WorkloadUiState by workloadViewModel.state.collectAsStateWithLifecycle()
            AvelrenApp(state = state, onRetry = workloadViewModel::retry)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent)
    }

    private fun handleNotificationIntent(intent: Intent) {
        if (shouldRefreshFromNotificationAction(intent.action)) {
            workloadViewModel.retry()
        }
    }

    private fun requestNotificationPermissionOnce() {
        val preferences = getSharedPreferences("avelren_permission_state", MODE_PRIVATE)
        if (!shouldRequestNotificationPermission(
                Build.VERSION.SDK_INT,
                ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED,
                preferences.getBoolean("notification_permission_requested", false),
            )) return
        preferences.edit().putBoolean("notification_permission_requested", true).apply()
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    private companion object {
        const val NOTIFICATION_PERMISSION_REQUEST = 301
    }
}
