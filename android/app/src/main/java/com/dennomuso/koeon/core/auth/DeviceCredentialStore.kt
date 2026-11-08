package com.dennomuso.koeon.core.auth

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

interface DeviceCredentialStore {
    fun read(): String?
    fun write(credential: String)
    fun clear()
}

/** Raw credentials are encrypted by an Android Keystore non-exportable AES key. */
class AndroidKeystoreDeviceCredentialStore(context: Context) : DeviceCredentialStore {
    private val preferences = context.getSharedPreferences("koeon_encrypted_device_identity", Context.MODE_PRIVATE)
    private val alias = "koeon_device_credential_v1"

    override fun read(): String? {
        val encrypted = preferences.getString("ciphertext", null) ?: return null
        val iv = preferences.getString("iv", null) ?: throw java.io.IOException("Credential IV unavailable")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(createIfMissing = false), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
        return String(cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)), Charsets.UTF_8)
    }

    override fun write(credential: String) {
        require(credential.length >= 32)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(credential.toByteArray(Charsets.UTF_8))
        preferences.edit()
            .putString("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .apply()
    }

    override fun clear() {
        preferences.edit().clear().apply()
    }

    private fun key(createIfMissing: Boolean = true): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        if (!createIfMissing) throw java.io.IOException("Credential key unavailable")
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }
}
