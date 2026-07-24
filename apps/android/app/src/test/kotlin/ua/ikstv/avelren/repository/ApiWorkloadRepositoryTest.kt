package ua.ikstv.avelren.repository

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import kotlinx.coroutines.runBlocking
import org.junit.Test

class ApiWorkloadRepositoryTest {
    @Test
    fun `maps valid workload payload`() {
        val payload = jsonPayload("demo", 123, "fresh", 42L)
        val repository = repositoryOf(payload, "application/json")

        val result = runBlocking { repository.getLatest() }

        assertEquals("demo", result.locationId)
        assertEquals(123, result.vehicleCount)
        assertEquals(42L, result.sequence)
    }

    @Test
    fun `rejects malformed workload json`() {
        val repository = repositoryOf("{ invalid json }", "application/json")

        val error = runBlocking {
            runCatching { repository.getLatest() }.exceptionOrNull()
        }

        assertTrue(error is ApiWorkloadResponseException)
    }

    @Test
    fun `rejects non-json content type`() {
        val repository = repositoryOf(
            body = "{\"locationId\":\"demo\",\"vehicleCount\":123,\"observedAt\":\"2026-07-20T08:00:00.000Z\",\"receivedAt\":\"2026-07-20T08:00:01.000Z\",\"freshness\":\"fresh\",\"sequence\":1}",
            contentType = "text/plain",
        )

        val error = runBlocking {
            runCatching { repository.getLatest() }.exceptionOrNull()
        }

        assertTrue(error is ApiWorkloadContentTypeException)
    }

    @Test
    fun `rejects payload missing required fields`() {
        val payload = """
            {
              "vehicleCount": 123,
              "observedAt": "2026-07-20T08:00:00.000Z",
              "receivedAt": "2026-07-20T08:00:01.000Z",
              "freshness": "fresh",
              "sequence": 42
            }
        """.trimIndent()
        val repository = repositoryOf(payload, "application/json")

        val error = runBlocking {
            runCatching { repository.getLatest() }.exceptionOrNull()
        }

        assertTrue(error is ApiWorkloadResponseException)
    }

    @Test
    fun `rejects payload with wrong field type`() {
        val payload = """
            {
              "locationId": "demo",
              "vehicleCount": "not-a-number",
              "observedAt": "2026-07-20T08:00:00.000Z",
              "receivedAt": "2026-07-20T08:00:01.000Z",
              "freshness": "fresh",
              "sequence": 42
            }
        """.trimIndent()
        val repository = repositoryOf(payload, "application/json")

        val error = runBlocking {
            runCatching { repository.getLatest() }.exceptionOrNull()
        }

        assertTrue(error is ApiWorkloadResponseException)
    }

    @Test
    fun `returns error for http errors`() {
        val repository = repositoryOf(
            body = "{}",
            contentType = "application/json",
            responseCode = 503,
        )

        val error = runBlocking {
            runCatching { repository.getLatest() }.exceptionOrNull()
        }

        assertTrue(error is ApiWorkloadHttpStatusException)
    }

    @Test
    fun `returns error for oversized responses`() {
        val oversizedPayload = createOversizedPayload("A".repeat(70_000))
        val repository = repositoryOf(oversizedPayload, "application/json")

        val error = runBlocking {
            runCatching { repository.getLatest() }.exceptionOrNull()
        }

        assertTrue(error is ApiWorkloadResponseTooLargeException)
    }

    @Test
    fun `returns error for redirect responses`() {
        val repository = repositoryOf("{}", "application/json", responseCode = 302)

        val error = runBlocking {
            runCatching { repository.getLatest() }.exceptionOrNull()
        }

        assertTrue(error is ApiWorkloadRedirectException)
    }

    @Test
    fun `retries after an error`() {
        val firstResponse = FakeRequest(
            responseCode = 503,
            contentType = "application/json",
            body = "{}",
        )
        val secondResponse = FakeRequest(
            responseCode = 200,
            contentType = "application/json",
            body = jsonPayload("retry-loc", 9, "stale", 8L),
        )
        val factory = FakeRequestFactory(firstResponse, secondResponse)
        val repository = ApiWorkloadRepository(
            baseUrl = "https://api.avelren.invalid/",
            requestFactory = factory,
        )

        val result = runBlocking { repository.getLatestWithRetry(2) }

        assertEquals("retry-loc", result.locationId)
        assertEquals(2, factory.requestsMade)
    }

    private fun repositoryOf(
        body: String,
        contentType: String,
        responseCode: Int = 200,
    ): ApiWorkloadRepository = ApiWorkloadRepository(
        baseUrl = "https://api.avelren.invalid/",
        requestFactory = FakeRequestFactory(FakeRequest(responseCode, contentType, body)),
    )

    private fun jsonPayload(
        locationId: String,
        vehicleCount: Int,
        freshness: String,
        sequence: Long,
    ): String = """
        {
          "locationId": "$locationId",
          "vehicleCount": $vehicleCount,
          "observedAt": "2026-07-20T08:00:00.000Z",
          "receivedAt": "2026-07-20T08:00:01.000Z",
          "freshness": "$freshness",
          "sequence": $sequence
        }
    """.trimIndent()

    private fun createOversizedPayload(note: String): String = """
        {
          "locationId": "oversized",
          "vehicleCount": 1,
          "observedAt": "2026-07-20T08:00:00.000Z",
          "receivedAt": "2026-07-20T08:00:01.000Z",
          "freshness": "fresh",
          "sequence": 1,
          "note": "$note"
        }
    """.trimIndent()
}

private class FakeRequest(
    override val responseCode: Int,
    override val contentType: String,
    private val body: String,
    override val contentLength: Long = body.toByteArray(StandardCharsets.UTF_8).size.toLong(),
) : ApiRequest {
    override fun body(): InputStream = ByteArrayInputStream(body.toByteArray(StandardCharsets.UTF_8))
    override fun close() {}
}

private class FakeRequestFactory(private vararg val requests: FakeRequest) : ApiRequestFactory {
    private var index = 0
    var requestsMade = 0
        private set

    override fun create(url: String): ApiRequest {
        requestsMade++
        return requests[index++]
    }
}
