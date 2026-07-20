package ua.ikstv.avelren.push

import kotlinx.coroutines.delay

class PushRegistrationCoordinator(
    private val identity: PushIdentityStore,
    private val api: PushRegistrationApi,
    private val sleeper: suspend (Long) -> Unit = { delay(it) },
) {
    suspend fun registerToken(token: String, locale: String) {
        require(token.length in 20..4_096)
        retry {
            val installationId = identity.installationId()
            val credential = identity.credential()
            if (credential == null) {
                api.register(installationId, token, locale).installationCredential
                    ?.let(identity::saveCredential)
            } else {
                api.rotate(installationId, credential, token)
                api.heartbeat(installationId, credential, locale)
            }
        }
    }

    private suspend fun retry(operation: suspend () -> Unit) {
        var last: Exception? = null
        repeat(3) { attempt ->
            try {
                operation()
                return
            } catch (error: PushRegistrationException) {
                last = error
                if (attempt < 2) sleeper(1_000L shl attempt)
            }
        }
        throw last ?: PushRegistrationException()
    }
}
