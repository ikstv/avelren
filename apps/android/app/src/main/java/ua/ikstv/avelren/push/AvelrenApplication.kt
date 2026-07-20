package ua.ikstv.avelren.push

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import ua.ikstv.avelren.BuildConfig
import java.util.Locale

class AvelrenApplication : Application() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        createChannel()
        if (initializeFirebase()) FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
            scope.launch { register(token) }
        }
    }

    internal suspend fun register(token: String) {
        try {
            PushRegistrationCoordinator(AndroidPushIdentityStore(this), PushRegistrationClient())
                .registerToken(token, Locale.getDefault().toLanguageTag())
        } catch (_: Exception) {
            // Deliberately no token, credential, URL, or payload logging.
        }
    }

    private fun initializeFirebase(): Boolean {
        if (FirebaseApp.getApps(this).isNotEmpty()) return true
        val values = listOf(BuildConfig.FCM_APPLICATION_ID, BuildConfig.FCM_PROJECT_ID,
            BuildConfig.FCM_API_KEY, BuildConfig.FCM_SENDER_ID)
        if (values.any(String::isBlank)) return false
        FirebaseApp.initializeApp(
            this,
            FirebaseOptions.Builder().setApplicationId(BuildConfig.FCM_APPLICATION_ID)
                .setProjectId(BuildConfig.FCM_PROJECT_ID).setApiKey(BuildConfig.FCM_API_KEY)
                .setGcmSenderId(BuildConfig.FCM_SENDER_ID).build(),
        )
        return true
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Avelren updates", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
    }

    companion object { const val CHANNEL_ID = "threshold_updates_v1" }
}
