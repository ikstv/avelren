package ua.ikstv.avelren.push

import com.google.gson.Gson
import ua.ikstv.avelren.BuildConfig
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.Locale
import javax.net.ssl.HttpsURLConnection

data class RegistrationResult(val installationCredential: String?)

interface PushRegistrationApi {
    suspend fun register(installationId: String, token: String, locale: String): RegistrationResult
    suspend fun rotate(installationId: String, credential: String, token: String)
    suspend fun heartbeat(installationId: String, credential: String, locale: String)
    suspend fun disable(installationId: String, credential: String)
}

interface PushRegistrationTransport {
    fun execute(method: String, relativePath: String, body: String?, credential: String?,
        appCheckToken: String, accepted: Set<Int>): String
}

class PushRegistrationClient(
    private val attestation: AppAttestationTokenProvider = FirebaseAppAttestationTokenProvider(),
    private val transport: PushRegistrationTransport = HttpsPushRegistrationTransport(BuildConfig.API_BASE_URL),
    private val gson: Gson = Gson(),
) : PushRegistrationApi {
    override suspend fun register(installationId: String, token: String, locale: String): RegistrationResult {
        val response = request(
            "POST", "v1/push/installations",
            gson.toJson(mapOf("installationId" to installationId, "token" to token,
                "platform" to "android", "locale" to locale)), null, setOf(200, 201),
        )
        val decoded = gson.fromJson(response, RegistrationResponse::class.java)
        if (decoded.status != "registered") throw PushRegistrationException(retryable = false)
        return RegistrationResult(decoded.installationCredential)
    }

    override suspend fun rotate(installationId: String, credential: String, token: String) {
        request("PUT", path(installationId, "token"), gson.toJson(mapOf("token" to token)),
            credential, setOf(204))
    }

    override suspend fun heartbeat(installationId: String, credential: String, locale: String) {
        request("PATCH", path(installationId), gson.toJson(mapOf("locale" to locale)),
            credential, setOf(204))
    }

    override suspend fun disable(installationId: String, credential: String) {
        request("DELETE", path(installationId), null, credential, setOf(204))
    }

    private fun path(id: String, suffix: String? = null): String =
        "v1/push/installations/$id" + (suffix?.let { "/$it" } ?: "")

    private suspend fun request(method: String, relativePath: String, body: String?, credential: String?,
        accepted: Set<Int>): String {
        val appCheckToken = try {
            attestation.token()
        } catch (error: PushRegistrationException) {
            throw error
        } catch (_: Exception) {
            throw PushRegistrationException(retryable = true)
        }
        if (!APP_CHECK_TOKEN.matches(appCheckToken)) throw PushRegistrationException(retryable = false)
        return transport.execute(method, relativePath, body, credential, appCheckToken, accepted)
    }

    private data class RegistrationResponse(
        val status: String? = null, val installationCredential: String? = null,
    )

    private companion object {
        val APP_CHECK_TOKEN = Regex("^[A-Za-z0-9._-]{20,8192}$")
    }
}

internal class HttpsPushRegistrationTransport(baseUrl: String) : PushRegistrationTransport {
    private val approvedBase = URI(baseUrl)

    init {
        require(approvedBase.scheme == "https" && !approvedBase.host.isNullOrBlank() &&
            approvedBase.userInfo == null && approvedBase.query == null && approvedBase.fragment == null &&
            approvedBase.path.endsWith("/"))
    }

    override fun execute(method: String, relativePath: String, body: String?, credential: String?,
        appCheckToken: String, accepted: Set<Int>): String {
        val target = approvedBase.resolve(relativePath)
        if (target.scheme != approvedBase.scheme || target.host != approvedBase.host ||
            target.port != approvedBase.port || target.userInfo != null) {
            throw PushRegistrationException(retryable = false)
        }
        val connection = target.toURL().openConnection() as? HttpsURLConnection
            ?: throw PushRegistrationException(retryable = false)
        try {
            connection.requestMethod = method
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 5_000
            connection.readTimeout = 8_000
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("X-Firebase-AppCheck", appCheckToken)
            if (credential != null) connection.setRequestProperty("Authorization", "Bearer $credential")
            if (body != null) {
                val bytes = body.toByteArray(Charsets.UTF_8)
                if (bytes.size > REQUEST_LIMIT) throw PushRegistrationException(retryable = false)
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(bytes) }
            }
            val status = connection.responseCode
            if (status in 300..399) throw PushRegistrationException(retryable = false)
            if (status !in accepted) {
                throw PushRegistrationException(retryable = status == 408 || status == 429 || status >= 500)
            }
            if (status == HttpURLConnection.HTTP_NO_CONTENT) return ""
            if (connection.contentType?.lowercase(Locale.ROOT)?.startsWith("application/json") != true) {
                throw PushRegistrationException(retryable = false)
            }
            return connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(1_024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (output.size() + read > RESPONSE_LIMIT) {
                        throw PushRegistrationException(retryable = false)
                    }
                    output.write(buffer, 0, read)
                }
                output.toString(Charsets.UTF_8.name())
            }
        } catch (error: PushRegistrationException) {
            throw error
        } catch (_: Exception) {
            throw PushRegistrationException(retryable = true)
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        const val REQUEST_LIMIT = 8 * 1_024
        const val RESPONSE_LIMIT = 16 * 1_024
    }
}

class PushRegistrationException(val retryable: Boolean = true) : Exception("Push registration failed")
