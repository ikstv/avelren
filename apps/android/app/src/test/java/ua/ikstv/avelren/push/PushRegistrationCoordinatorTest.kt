package ua.ikstv.avelren.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushRegistrationCoordinatorTest {
    @Test fun `initial registration stores only returned credential`() = runBlocking {
        val identity = FakeIdentity()
        PushRegistrationCoordinator(identity, FakeApi()).registerToken("t".repeat(20), "uk-UA")
        assertEquals("c".repeat(43), identity.saved)
        assertFalse(identity.values.any { it.contains("t".repeat(20)) })
    }

    @Test fun `token rotation uses existing authenticated installation`() = runBlocking {
        val api = FakeApi()
        PushRegistrationCoordinator(FakeIdentity("c".repeat(43)), api)
            .registerToken("n".repeat(20), "en-US")
        assertTrue(api.rotated)
        assertTrue(api.didHeartbeat)
    }

    @Test fun `transient registration failure retries with backoff`() = runBlocking {
        val api = FakeApi(failures = 2)
        val delays = mutableListOf<Long>()
        PushRegistrationCoordinator(FakeIdentity(), api, delays::add)
            .registerToken("t".repeat(20), "uk-UA")
        assertEquals(listOf(1_000L, 2_000L), delays)
        assertEquals(3, api.calls)
    }

    @Test fun `ambiguous existing registration does not retry or expect a credential`() = runBlocking {
        val identity = FakeIdentity()
        val api = FakeApi(registrationCredential = null)
        PushRegistrationCoordinator(identity, api).registerToken("t".repeat(20), "uk-UA")
        assertEquals(1, api.calls)
        assertEquals(null, identity.saved)
    }

    private class FakeIdentity(var saved: String? = null) : PushIdentityStore {
        val values = mutableListOf<String>()
        override fun installationId(): String = "i".repeat(32)
        override fun credential(): String? = saved
        override fun saveCredential(credential: String) { saved = credential; values += credential }
    }

    private class FakeApi(
        var failures: Int = 0,
        private val registrationCredential: String? = "c".repeat(43),
    ) : PushRegistrationApi {
        var calls = 0
        var rotated = false
        var didHeartbeat = false
        override suspend fun register(installationId: String, token: String, locale: String): RegistrationResult {
            calls += 1
            if (failures-- > 0) throw PushRegistrationException()
            return RegistrationResult(registrationCredential)
        }
        override suspend fun rotate(installationId: String, credential: String, token: String) { rotated = true }
        override suspend fun heartbeat(installationId: String, credential: String, locale: String) {
            didHeartbeat = true
        }
        override suspend fun disable(installationId: String, credential: String) = Unit
    }
}
