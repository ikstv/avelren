package ua.ikstv.avelren.push

import java.nio.ByteBuffer
import java.security.MessageDigest

interface SeenEventStore {
    fun contains(eventId: String): Boolean
    fun add(eventId: String)
}

class NotificationDeduplicator(private val store: SeenEventStore) {
    fun isNew(eventId: String): Boolean = !store.contains(eventId)
    fun markDisplayed(eventId: String) = store.add(eventId)
}

fun stableNotificationId(eventId: String): Int = ByteBuffer.wrap(
    MessageDigest.getInstance("SHA-256").digest(eventId.toByteArray(Charsets.UTF_8)),
).int

fun stableNotificationRequestCode(eventId: String): Int = ByteBuffer.wrap(
    MessageDigest.getInstance("SHA-256").digest(eventId.toByteArray(Charsets.UTF_8)),
).int and Int.MAX_VALUE

fun notificationActivityFlags(): Int =
    android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP or
        android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP

fun notificationPendingIntentFlags(): Int =
    android.app.PendingIntent.FLAG_UPDATE_CURRENT or
        android.app.PendingIntent.FLAG_IMMUTABLE

fun shouldRequestNotificationPermission(
    sdkInt: Int,
    permissionGranted: Boolean,
    requestedBefore: Boolean,
): Boolean = sdkInt >= 33 && !permissionGranted && !requestedBefore

const val OPEN_FROM_NOTIFICATION_ACTION =
    "ua.ikstv.avelren.action.OPEN_FROM_NOTIFICATION"

fun shouldRefreshFromNotificationAction(action: String?): Boolean = action == OPEN_FROM_NOTIFICATION_ACTION
