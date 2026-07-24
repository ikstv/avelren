package ua.ikstv.avelren.push

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import ua.ikstv.avelren.MainActivity
import ua.ikstv.avelren.R

class AvelrenMessagingService : FirebaseMessagingService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onNewToken(token: String) {
        scope.launch { (application as AvelrenApplication).register(token) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val payload = PushPayloadParser.parse(message.data) ?: return
        val preferences = getSharedPreferences("avelren_push_events", MODE_PRIVATE)
        val deduplicator = NotificationDeduplicator(object : SeenEventStore {
            override fun contains(eventId: String): Boolean = preferences.contains(eventId)
            override fun add(eventId: String) { preferences.edit().putBoolean(eventId, true).apply() }
        })
        if (!deduplicator.isNew(payload.eventId)) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED) return
        val openIntent = Intent(this, MainActivity::class.java).apply {
            action = OPEN_FROM_NOTIFICATION_ACTION
            flags = notificationActivityFlags()
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            stableNotificationRequestCode(payload.eventId),
            openIntent,
            notificationPendingIntentFlags(),
        )
        val notification = NotificationCompat.Builder(this, AvelrenApplication.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(getString(R.string.push_notification_title))
            .setContentText(getString(R.string.push_notification_text, payload.threshold, payload.observedCount))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java)
            .notify(stableNotificationId(payload.eventId), notification)
        deduplicator.markDisplayed(payload.eventId)
    }
}
