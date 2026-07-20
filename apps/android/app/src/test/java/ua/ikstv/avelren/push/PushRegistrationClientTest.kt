package ua.ikstv.avelren.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushRegistrationClientTest {
    @Test fun `fresh attestation token is attached to every protected request`() = runBlocking {
        val transport = RecordingTransport()
        var sequence = 0
        val client = PushRegistrationClient(
            attestation = AppAttestationTokenProvider { "token-${++sequence}".padEnd(20, 'x') },
            transport = transport,
        )
        client.register("i".repeat(32), "t".repeat(20), "uk-UA")
        client.rotate("i".repeat(32), "c".repeat(43), "n".repeat(20))
        client.heartbeat("i".repeat(32), "c".repeat(43), "en-US")
        client.disable("i".repeat(32), "c".repeat(43))
        assertEquals(4, transport.tokens.distinct().size)
        assertTrue(transport.tokens.all { it.length >= 20 })
        assertEquals(listOf("POST", "PUT", "PATCH", "DELETE"), transport.methods)
    }

    @Test fun `attestation acquisition fails closed before transport`() = runBlocking {
        val transport = RecordingTransport()
        val client = PushRegistrationClient(
            attestation = AppAttestationTokenProvider { throw IllegalStateException("sensitive-token") },
            transport = transport,
        )
        try {
            client.register("i".repeat(32), "t".repeat(20), "uk-UA")
        } catch (error: PushRegistrationException) {
            assertTrue(error.retryable)
            assertFalse(error.message.orEmpty().contains("sensitive-token"))
        }
        assertTrue(transport.tokens.isEmpty())
    }

    @Test fun `malformed attestation token is permanent and never sent`() = runBlocking {
        val transport = RecordingTransport()
        val client = PushRegistrationClient(
            attestation = AppAttestationTokenProvider { "not valid" },
            transport = transport,
        )
        try {
            client.register("i".repeat(32), "t".repeat(20), "uk-UA")
        } catch (error: PushRegistrationException) {
            assertFalse(error.retryable)
        }
        assertTrue(transport.tokens.isEmpty())
    }

    @Test fun `production transport accepts only a fixed HTTPS origin`() {
        HttpsPushRegistrationTransport("https://api.avelren.invalid/")
        listOf("http://api.avelren.invalid/", "https://user@api.avelren.invalid/",
            "https://api.avelren.invalid/?query=1", "https://api.avelren.invalid/#fragment")
            .forEach { value ->
                try {
                    HttpsPushRegistrationTransport(value)
                    throw AssertionError("Unsafe URL accepted")
                } catch (_: IllegalArgumentException) {
                    // Expected before any token can be attached.
                }
            }
    }

    private class RecordingTransport : PushRegistrationTransport {
        val tokens = mutableListOf<String>()
        val methods = mutableListOf<String>()
        override fun execute(method: String, relativePath: String, body: String?, credential: String?,
            appCheckToken: String, accepted: Set<Int>): String {
            methods += method
            tokens += appCheckToken
            return if (method == "POST") "{\"status\":\"registered\"}" else ""
        }
    }
}
