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
