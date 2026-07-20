package ua.ikstv.avelren.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PushPayloadParserTest {
    private val valid = mapOf(
        "schemaVersion" to "1", "eventId" to "a".repeat(64),
        "locationId" to "location-1", "threshold" to "50", "observedCount" to "62",
        "observedAt" to "2026-07-20T10:15:30Z",
    )

    @Test fun `accepts exact supported payload`() {
        assertEquals(50, PushPayloadParser.parse(valid)?.threshold)
    }
    @Test fun `rejects unsupported schema`() {
        assertNull(PushPayloadParser.parse(valid + ("schemaVersion" to "2")))
    }
    @Test fun `rejects arbitrary url field`() {
        assertNull(PushPayloadParser.parse(valid + ("url" to "https://example.invalid")))
    }
    @Test fun `rejects malformed event and timestamp`() {
        assertNull(PushPayloadParser.parse(valid + ("eventId" to "bad")))
        assertNull(PushPayloadParser.parse(valid + ("observedAt" to "bad")))
    }
}
