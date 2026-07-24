package ua.ikstv.avelren.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPolicyTest {
    @Test fun `notification id is stable and event based`() {
        val first = stableNotificationId("a".repeat(64))
        assertEquals(first, stableNotificationId("a".repeat(64)))
        assertTrue(first != stableNotificationId("b".repeat(64)))
    }

    @Test fun `request code is stable, event based and non-negative`() {
        val requestCode = stableNotificationRequestCode("event-id-1")
        assertEquals(requestCode, stableNotificationRequestCode("event-id-1"))
        assertEquals(0, requestCode and Int.MIN_VALUE)
        assertTrue(requestCode != stableNotificationRequestCode("event-id-2"))
    }

    @Test fun `notification flags include immutable and update current`() {
        val flags = notificationPendingIntentFlags()
        assertEquals(
            android.app.PendingIntent.FLAG_IMMUTABLE,
            flags and android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        assertEquals(
            android.app.PendingIntent.FLAG_UPDATE_CURRENT,
            flags and android.app.PendingIntent.FLAG_UPDATE_CURRENT,
        )
        assertEquals(0, flags and android.app.PendingIntent.FLAG_MUTABLE)
    }

    @Test fun `activity flags include clear top and single top`() {
        val flags = notificationActivityFlags()
        assertEquals(
            android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP,
            flags and android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP,
        )
        assertEquals(
            android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP,
            flags and android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP,
        )
    }

    @Test fun `local deduplicator marks a displayed event once`() {
        val values = mutableSetOf<String>()
        val deduplicator = NotificationDeduplicator(object : SeenEventStore {
            override fun contains(eventId: String): Boolean = eventId in values
            override fun add(eventId: String) { values += eventId }
        })
        assertTrue(deduplicator.isNew("event"))
        deduplicator.markDisplayed("event")
        assertFalse(deduplicator.isNew("event"))
    }

    @Test fun `permission prompt is requested once only on Android 13 or newer`() {
        assertTrue(shouldRequestNotificationPermission(33, false, false))
        assertFalse(shouldRequestNotificationPermission(33, false, true))
        assertFalse(shouldRequestNotificationPermission(33, true, false))
        assertFalse(shouldRequestNotificationPermission(32, false, false))
    }
}
