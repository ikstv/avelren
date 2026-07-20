package ua.ikstv.avelren.push

import com.google.gson.Gson
import ua.ikstv.avelren.BuildConfig
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.Locale
import javax.net.ssl.HttpsURLConnection

data class RegistrationResult(val installationCredential: String?)

interface PushRegistrationApi {
    suspend fun register(installationId: String, token: String, locale: String): RegistrationResult
    suspend fun rotate(installationId: String, credential: String, token: String)
    suspend fun heartbeat(installationId: String, credential: String, locale: String)
    suspend fun disable(installationId: String, credential: String)
}

class PushRegistrationClient(
    private val baseUrl: String = BuildConfig.API_BASE_URL,
    private val gson: Gson = Gson(),
) : PushRegistrationApi {
    init {
        val uri = URI(baseUrl)
        require(uri.scheme == "https" && uri.userInfo == null && uri.fragment == null)
    }

    override suspend fun register(installationId: String, token: String, locale: String): RegistrationResult {
        val response = request(
            "POST", "v1/push/installations",
            gson.toJson(mapOf("installationId" to installationId, "token" to token,
                "platform" to "android", "locale" to locale)), null, setOf(200, 201),
        )
        val decoded = gson.fromJson(response, RegistrationResponse::class.java)
        if (decoded.status != "registered") throw PushRegistrationException()
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

    private fun request(method: String, relativePath: String, body: String?, credential: String?,
        accepted: Set<Int>): String {
        val connection = URL(URL(baseUrl), relativePath).openConnection() as? HttpsURLConnection
            ?: throw PushRegistrationException()
        try {
            connection.requestMethod = method
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 5_000
            connection.readTimeout = 8_000
            connection.setRequestProperty("Accept", "application/json")
            if (credential != null) connection.setRequestProperty("Authorization", "Bearer $credential")
            if (body != null) {
                val bytes = body.toByteArray(Charsets.UTF_8)
                if (bytes.size > REQUEST_LIMIT) throw PushRegistrationException()
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(bytes) }
            }
            val status = connection.responseCode
            if (status in 300..399 || status !in accepted) throw PushRegistrationException()
            if (status == HttpURLConnection.HTTP_NO_CONTENT) return ""
            if (connection.contentType?.lowercase(Locale.ROOT)?.startsWith("application/json") != true) {
                throw PushRegistrationException()
            }
            return connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(1_024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (output.size() + read > RESPONSE_LIMIT) throw PushRegistrationException()
                    output.write(buffer, 0, read)
                }
                output.toString(Charsets.UTF_8.name())
            }
        } catch (error: PushRegistrationException) {
            throw error
        } catch (_: Exception) {
            throw PushRegistrationException()
        } finally {
            connection.disconnect()
        }
    }

    private data class RegistrationResponse(
        val status: String? = null, val installationCredential: String? = null,
    )
    private companion object {
        const val REQUEST_LIMIT = 8 * 1_024
        const val RESPONSE_LIMIT = 16 * 1_024
    }
}

class PushRegistrationException : Exception("Push registration failed")
