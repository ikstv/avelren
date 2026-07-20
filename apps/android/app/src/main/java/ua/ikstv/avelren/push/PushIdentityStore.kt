package ua.ikstv.avelren.push

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

interface PushIdentityStore {
    fun installationId(): String
    fun credential(): String?
    fun saveCredential(credential: String)
}

class AndroidPushIdentityStore(context: Context) : PushIdentityStore {
    private val preferences = context.getSharedPreferences("avelren_push_identity", Context.MODE_PRIVATE)
    private val cipherStore = KeystoreCredentialCipher()

    override fun installationId(): String {
        preferences.getString(INSTALLATION_ID, null)?.let { return it }
        val generated = UUID.randomUUID().toString().replace("-", "")
        check(preferences.edit().putString(INSTALLATION_ID, generated).commit())
        return generated
    }

    override fun credential(): String? {
        val encrypted = preferences.getString(CREDENTIAL, null) ?: return null
        return cipherStore.decrypt(encrypted)
    }

    override fun saveCredential(credential: String) {
        require(credential.matches(Regex("^[A-Za-z0-9_-]{43}$")))
        check(preferences.edit().putString(CREDENTIAL, cipherStore.encrypt(credential)).commit())
    }

    private companion object {
        const val INSTALLATION_ID = "installation_id"
        const val CREDENTIAL = "credential_ciphertext"
    }
}

private class KeystoreCredentialCipher {
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return Base64.encodeToString(
            cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP,
        )
    }

    fun decrypt(value: String): String? = try {
        val bytes = Base64.decode(value, Base64.NO_WRAP)
        if (bytes.size <= IV_BYTES) return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, IV_BYTES)))
        cipher.doFinal(bytes.copyOfRange(IV_BYTES, bytes.size)).toString(Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }

    private fun key(): SecretKey {
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            generateKey()
        }
    }

    private companion object {
        const val KEY_ALIAS = "avelren_push_installation_credential_v1"
        const val IV_BYTES = 12
    }
}
