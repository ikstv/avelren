package ua.ikstv.avelren

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import ua.ikstv.avelren.repository.DemoWorkloadRepository
import ua.ikstv.avelren.repository.WorkloadRepository
import ua.ikstv.avelren.ui.AvelrenApp

class MainActivity : ComponentActivity() {
    private val workloadRepository: WorkloadRepository = DemoWorkloadRepository()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            AvelrenApp(workloadRepository = workloadRepository)
        }
    }
}
