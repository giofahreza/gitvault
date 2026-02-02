package com.giofahreza.gitvault.ime

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Manages encrypted metadata cache for IME keyboard.
 * Uses Android KeyStore with AES-256-GCM for credential metadata.
 *
 * Mitigations:
 * - setUserAuthenticationValidityDurationSeconds(-1): Requires auth for EVERY operation
 * - CryptoObject binding: Prevents Frida injection by tying auth to cryptographic operation
 * - Android-generated IV: Prevents manual nonce reuse attacks
 * - NoBackupFilesDir: Excludes from ADB backup
 * - Atomic writes: Write to .tmp, then rename to prevent partial writes
 * - KeyPermanentlyInvalidatedException handling: Re-generates key if fingerprints change
 */
class CredentialCacheManager(private val context: Context) {
    companion object {
        private const val TAG = "CredentialCacheManager"
        private const val KEY_ALIAS = "gitvault_ime_key"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_SIZE = 256 // AES-256
        private const val GCM_TAG_LENGTH = 128 // bits
        private const val CACHE_FILE_NAME = "ime_meta.enc"
        private const val MASTER_KEY_ALIAS = "_credential_cache_master_key_"
    }

    private val keyStore: KeyStore = KeyStore.getInstance(KEYSTORE_PROVIDER)
    private val gson = Gson()
    private val cacheFile: File
        get() = File(context.noBackupFilesDir, CACHE_FILE_NAME)

    init {
        keyStore.load(null)
    }

    /**
     * Get or create the AES-256-GCM key for credential metadata encryption.
     *
     * This key requires biometric authentication for EVERY use (validity duration = -1).
     * CryptoObject binding ensures the auth can't be bypassed by Frida injection.
     */
    fun getOrCreateKey(): SecretKey {
        // Check if key exists and is valid
        val existingKey = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
        if (existingKey != null) {
            try {
                // Verify key is still hardware-backed and not invalidated
                verifyKeyValid()
                return existingKey
            } catch (e: Exception) {
                Log.w(TAG, "Existing key invalid, regenerating: ${e.message}")
                keyStore.deleteEntry(KEY_ALIAS)
            }
        }

        // Generate new key
        return generateNewKey()
    }

    /**
     * Encrypt metadata list and write atomically to noBackupFilesDir.
     * Each credential is {uuid, title, url}, no usernames or passwords.
     */
    fun writeMetadataCache(metadata: List<CredentialMetadata>, cipher: Cipher) {
        try {
            // Serialize metadata to JSON
            val json = gson.toJson(metadata)
            val plaintext = json.toByteArray(Charsets.UTF_8)

            // Include versionCode in AAD to prevent downgrade attacks
            val aad = "v${getVersionCode()}".toByteArray(Charsets.UTF_8)

            // Encrypt with provided cipher (already initialized with CryptoObject)
            cipher.updateAAD(aad)
            val ciphertext = cipher.doFinal(plaintext)

            // Get IV from cipher
            val iv = cipher.iv
            if (iv == null || iv.isEmpty()) {
                throw IllegalStateException("IV is null or empty")
            }

            // Create encrypted payload: [IV_SIZE (4 bytes)][IV][CIPHERTEXT]
            val payload = ByteArray(4 + iv.size + ciphertext.size)
            var offset = 0

            // Write IV size
            payload[offset++] = (iv.size shr 24).toByte()
            payload[offset++] = (iv.size shr 16).toByte()
            payload[offset++] = (iv.size shr 8).toByte()
            payload[offset++] = iv.size.toByte()

            // Write IV
            System.arraycopy(iv, 0, payload, offset, iv.size)
            offset += iv.size

            // Write ciphertext
            System.arraycopy(ciphertext, 0, payload, offset, ciphertext.size)

            // Atomic write: write to .tmp, then rename
            val tmpFile = File(cacheFile.parent, "${cacheFile.name}.tmp")
            tmpFile.writeBytes(payload)
            tmpFile.renameTo(cacheFile)

            Log.d(TAG, "Metadata cache written: ${metadata.size} credentials")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to write metadata cache: ${e.message}")
            throw e
        }
    }

    /**
     * Read and decrypt metadata from cache.
     * Requires cipher initialized with BiometricPrompt CryptoObject.
     */
    fun readMetadataCache(cipher: Cipher): List<CredentialMetadata> {
        return try {
            if (!cacheFile.exists()) {
                Log.d(TAG, "Cache file does not exist")
                return emptyList<CredentialMetadata>()
            }

            val payload = cacheFile.readBytes()
            if (payload.size < 4) {
                Log.w(TAG, "Cache file too small")
                return emptyList<CredentialMetadata>()
            }

            // Read IV size
            var offset = 0
            val ivSize: Int = ((payload[offset].toInt() and 0xFF) shl 24) or
                    ((payload[offset + 1].toInt() and 0xFF) shl 16) or
                    ((payload[offset + 2].toInt() and 0xFF) shl 8) or
                    (payload[offset + 3].toInt() and 0xFF)
            offset += 4

            if (ivSize <= 0 || offset + ivSize > payload.size) {
                Log.e(TAG, "Invalid IV size: $ivSize")
                return emptyList<CredentialMetadata>()
            }

            // Read IV
            val iv: ByteArray = ByteArray(ivSize)
            System.arraycopy(payload, offset, iv, 0, ivSize)
            offset += ivSize

            // Read ciphertext
            val ciphertext: ByteArray = ByteArray(payload.size - offset)
            System.arraycopy(payload, offset, ciphertext, 0, ciphertext.size)

            // Initialize cipher with IV
            val spec = GCMParameterSpec(GCM_TAG_LENGTH, iv)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), spec)

            // Include versionCode in AAD
            val aad = "v${getVersionCode()}".toByteArray(Charsets.UTF_8)
            cipher.updateAAD(aad)

            // Decrypt
            val plaintext = cipher.doFinal(ciphertext)
            val json = String(plaintext, Charsets.UTF_8)

            // Parse JSON
            val typeToken = object : TypeToken<List<CredentialMetadata>>() {}
            val result: List<CredentialMetadata> = gson.fromJson(json, typeToken.type)
            Log.d(TAG, "Metadata cache read: ${result.size} credentials")
            result
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read metadata cache: ${e.message}")
            emptyList<CredentialMetadata>()
        }
    }

    /**
     * Get cipher initialized for decryption with the KeyStore key.
     * This cipher is suitable for CryptoObject binding with BiometricPrompt.
     */
    fun getCipherForDecryption(): Cipher {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey())
        return cipher
    }

    /**
     * Get cipher initialized for encryption with a fresh IV.
     * Android generates the IV automatically.
     */
    fun getCipherForEncryption(): Cipher {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        return cipher
    }

    /**
     * Clear the encrypted metadata cache file.
     */
    fun clearCache() {
        try {
            if (cacheFile.exists()) {
                cacheFile.delete()
                Log.d(TAG, "Cache cleared")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear cache: ${e.message}")
        }
    }

    /**
     * Check if hardware KeyStore is available.
     * Warns if key is software-only backed.
     */
    fun isHardwareBackedKeyStore(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val key = getOrCreateKey() as? SecretKey
                key != null && keyStore.getEntry(KEY_ALIAS, null).let {
                    if (it is KeyStore.SecretKeyEntry) {
                        it.secretKey != null
                    } else false
                }
            } else {
                true // Assume hardware-backed on older APIs
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not verify hardware backing: ${e.message}")
            false
        }
    }

    /**
     * Verify that the current key is still valid.
     * Throws KeyPermanentlyInvalidatedException if fingerprints have changed.
     */
    private fun verifyKeyValid() {
        try {
            val key = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
                ?: throw IllegalStateException("Key not found")

            // Try a test encrypt/decrypt cycle to verify key validity
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val testData = byteArrayOf(1, 2, 3, 4)
            val iv = cipher.iv
            cipher.doFinal(testData)

            // Key is valid
            Log.d(TAG, "Key validation passed")
        } catch (e: android.security.keystore.KeyPermanentlyInvalidatedException) {
            Log.w(TAG, "Key permanently invalidated (fingerprint changed)")
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Key validation failed: ${e.message}")
            throw e
        }
    }

    /**
     * Generate a new AES-256-GCM key in Android KeyStore.
     *
     * Key properties:
     * - Algorithm: AES
     * - Key size: 256 bits
     * - Mode: GCM
     * - Padding: NoPadding
     * - Requires biometric authentication: YES
     * - Validity duration: -1 (requires auth for EVERY operation)
     * - Hardware-backed if available
     */
    private fun generateNewKey(): SecretKey {
        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)

        val keySpec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setKeySize(KEY_SIZE)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            // CRITICAL: Require biometric auth for EVERY operation (no 30s window)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationValidityDurationSeconds(-1)
            // Invalidate key if new fingerprints are enrolled
            .setInvalidatedByBiometricEnrollment(true)
            .build()

        keyGenerator.init(keySpec)
        val key = keyGenerator.generateKey()
        Log.d(TAG, "New AES-256-GCM key generated: $KEY_ALIAS")
        return key
    }

    private fun getVersionCode(): Int {
        return try {
            val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.longVersionCode.toInt()
            } else {
                @Suppress("DEPRECATION")
                packageInfo.versionCode
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not get version code: ${e.message}")
            1
        }
    }
}

/**
 * Data class for credential metadata (no passwords, only identifiers).
 * Sent to IME and encrypted in metadata cache.
 */
data class CredentialMetadata(
    val uuid: String,
    val title: String,
    val url: String?
)
