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

fun shouldRequestNotificationPermission(
    sdkInt: Int,
    permissionGranted: Boolean,
    requestedBefore: Boolean,
): Boolean = sdkInt >= 33 && !permissionGranted && !requestedBefore
