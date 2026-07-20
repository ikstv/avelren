package ua.ikstv.avelren.repository

import com.google.gson.Gson
import com.google.gson.JsonParseException
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.charset.StandardCharsets
import java.time.DateTimeException
import java.util.Locale
import ua.ikstv.avelren.domain.WorkloadSnapshot
import ua.ikstv.avelren.network.ApiConfiguration
import ua.ikstv.avelren.network.WorkloadResponse

private const val CONNECT_TIMEOUT_MS = 8_000
private const val READ_TIMEOUT_MS = 12_000
private const val MAX_RESPONSE_BYTES = 64 * 1024
private const val WORKLOAD_PATH = "/v1/workload"
private const val JSON_CONTENT_TYPE_PREFIX = "application/json"

class ApiWorkloadRepository(
    private val baseUrl: String = ApiConfiguration.baseUrl,
    private val requestFactory: ApiRequestFactory = AndroidApiRequestFactory(),
    private val gson: Gson = Gson(),
) : WorkloadRepository {

    override suspend fun getLatest(): WorkloadSnapshot = fetchLatestWithRetry(maxAttempts = 1)

    suspend fun getLatestWithRetry(maxAttempts: Int = 2): WorkloadSnapshot = fetchLatestWithRetry(
        maxAttempts = maxAttempts.coerceAtLeast(1),
    )

    private fun fetchLatestWithRetry(maxAttempts: Int): WorkloadSnapshot {
        var lastError: ApiWorkloadException? = null
        repeat(maxAttempts) {
            try {
                return fetchOnce()
            } catch (error: ApiWorkloadException) {
                lastError = error
            }
        }
        throw lastError ?: ApiWorkloadException("Failed to load workload snapshot")
    }

    private fun fetchOnce(): WorkloadSnapshot {
        val endpointUrl = workloadEndpoint(baseUrl)
        val request = requestFactory.create(endpointUrl)

        request.use {
            when (val statusCode = it.responseCode) {
                in 200..299 -> return parseWorkload(it)
                in 300..399 -> throw ApiWorkloadRedirectException(statusCode)
                else -> throw ApiWorkloadHttpStatusException(statusCode)
            }
        }
    }

    private fun parseWorkload(request: ApiRequest): WorkloadSnapshot {
        validateContentType(request.contentType)
        if (request.contentLength >= 0 && request.contentLength > MAX_RESPONSE_BYTES) {
            throw ApiWorkloadResponseTooLargeException()
        }

        val body = readWithLimit(request.body())
        return try {
            gson.fromJson(body, WorkloadResponse::class.java).toDomain()
        } catch (error: IllegalArgumentException) {
            throw ApiWorkloadResponseException("Invalid workload payload", error)
        } catch (error: JsonParseException) {
            throw ApiWorkloadResponseException("Invalid workload payload", error)
        } catch (error: DateTimeException) {
            throw ApiWorkloadResponseException("Invalid workload payload", error)
        } catch (error: Exception) {
            if (error is ApiWorkloadException) throw error
            throw ApiWorkloadResponseException("Invalid workload payload", error)
        }
    }

    private fun readWithLimit(input: InputStream): String {
        BufferedInputStream(input).use { stream ->
            val buffer = ByteArray(4 * 1024)
            var totalBytes = 0
            val output = ByteArrayOutputStream()
            while (true) {
                val read = stream.read(buffer)
                if (read == -1) break

                totalBytes += read
                if (totalBytes > MAX_RESPONSE_BYTES) {
                    throw ApiWorkloadResponseTooLargeException()
                }
                output.write(buffer, 0, read)
            }
            return output.toString(StandardCharsets.UTF_8)
        }
    }

    private fun validateContentType(contentType: String?) {
        val normalized = contentType.orEmpty().lowercase(Locale.US).trim()
        if (!normalized.startsWith(JSON_CONTENT_TYPE_PREFIX)) {
            throw ApiWorkloadContentTypeException(contentType)
        }
    }

    private fun workloadEndpoint(rawBaseUrl: String): String {
        val baseUri = try {
            URI(rawBaseUrl)
        } catch (error: Exception) {
            throw ApiWorkloadException("Invalid API base URL", error)
        }

        require(baseUri.scheme.equals("https", ignoreCase = true)) {
            "API base URL must be HTTPS"
        }
        require(!baseUri.host.isNullOrBlank()) {
            "API base URL must contain a host"
        }

        val normalizedPath = baseUri.path.ifEmpty { "/" }
        val fixedBaseUri = URI(
            baseUri.scheme,
            baseUri.userInfo,
            baseUri.host,
            baseUri.port,
            if (normalizedPath.endsWith("/")) normalizedPath else "$normalizedPath/",
            null,
            null,
        )
        return fixedBaseUri.resolve(WORKLOAD_PATH).toString()
    }
}

interface ApiRequest : AutoCloseable {
    val responseCode: Int
    val contentType: String?
    val contentLength: Long
    fun body(): InputStream
}

interface ApiRequestFactory {
    fun create(url: String): ApiRequest
}

class AndroidApiRequestFactory : ApiRequestFactory {
    override fun create(url: String): ApiRequest {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = CONNECT_TIMEOUT_MS
        connection.readTimeout = READ_TIMEOUT_MS
        connection.instanceFollowRedirects = false
        connection.setRequestProperty("Accept", "application/json")
        return AndroidApiRequest(connection)
    }
}

class AndroidApiRequest(
    private val connection: HttpURLConnection,
) : ApiRequest {
    override val responseCode: Int
        get() = connection.responseCode

    override val contentType: String?
        get() = connection.getHeaderField("Content-Type")

    override val contentLength: Long
        get() = connection.contentLengthLong

    override fun body(): InputStream = connection.inputStream

    override fun close() {
        connection.disconnect()
    }
}

open class ApiWorkloadException(
    message: String,
    cause: Throwable? = null,
) : IOException(message, cause)

class ApiWorkloadHttpStatusException(statusCode: Int) : ApiWorkloadException("Unexpected status: $statusCode")
class ApiWorkloadRedirectException(statusCode: Int) : ApiWorkloadException("Redirect is not allowed: $statusCode")
class ApiWorkloadContentTypeException(contentType: String?) : ApiWorkloadException(
    "Unsupported Content-Type: ${contentType ?: "(missing)"}",
)
class ApiWorkloadResponseTooLargeException : ApiWorkloadException("Response body is too large")
class ApiWorkloadResponseException(message: String, cause: Throwable) : ApiWorkloadException(message, cause)
