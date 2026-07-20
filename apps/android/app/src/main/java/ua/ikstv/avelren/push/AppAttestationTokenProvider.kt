package ua.ikstv.avelren.push

import com.google.firebase.appcheck.FirebaseAppCheck
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

fun interface AppAttestationTokenProvider {
    suspend fun token(): String
}

class FirebaseAppAttestationTokenProvider : AppAttestationTokenProvider {
    override suspend fun token(): String = suspendCancellableCoroutine { continuation ->
        FirebaseAppCheck.getInstance().getAppCheckToken(false).addOnCompleteListener { task ->
            if (!continuation.isActive) return@addOnCompleteListener
            val token = if (task.isSuccessful) task.result?.token else null
            if (token.isNullOrBlank()) {
                continuation.resumeWithException(PushRegistrationException(retryable = true))
            } else {
                continuation.resume(token)
            }
        }
    }
}
