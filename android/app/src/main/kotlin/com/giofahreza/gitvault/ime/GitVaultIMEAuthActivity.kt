package com.giofahreza.gitvault.ime

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import android.util.Log
import javax.crypto.Cipher

/**
 * Transparent activity for IME biometric authentication.
 * Shows BiometricPrompt with CryptoObject binding.
 * Returns decryption cipher to IME via static callback.
 */
class GitVaultIMEAuthActivity : FragmentActivity() {
    companion object {
        private const val TAG = "GitVaultIMEAuthActivity"
        private var authCallback: ((Cipher?) -> Unit)? = null

        /**
         * Register callback for auth result.
         * Called with decryption cipher on success, null on failure/cancel.
         */
        fun setAuthCallback(callback: (Cipher?) -> Unit) {
            authCallback = callback
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Transparent theme (no UI)
        // Activity will be invisible, only BiometricPrompt shows

        // Show biometric prompt
        showBiometricPrompt()
    }

    private fun showBiometricPrompt() {
        val credentialCacheManager = CredentialCacheManager(this)

        // Get cipher for decryption
        val cipher = try {
            credentialCacheManager.getCipherForDecryption()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get cipher: ${e.message}")
            authCallback?.invoke(null)
            finish()
            return
        }

        // Create CryptoObject with cipher
        val cryptoObject = BiometricPrompt.CryptoObject(cipher)

        // Create executor
        val executor = ContextCompat.getMainExecutor(this)

        // Create callback
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                super.onAuthenticationSucceeded(result)
                Log.d(TAG, "Biometric authentication succeeded")
                // Return the cipher from CryptoObject
                val decryptionCipher = result.cryptoObject?.cipher
                authCallback?.invoke(decryptionCipher)
                finish()
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                super.onAuthenticationError(errorCode, errString)
                Log.w(TAG, "Biometric authentication error: $errorCode - $errString")
                authCallback?.invoke(null)
                finish()
            }

            override fun onAuthenticationFailed() {
                super.onAuthenticationFailed()
                Log.w(TAG, "Biometric authentication failed")
                // Don't finish, let user retry
            }
        }

        // Build and show prompt
        val prompt = BiometricPrompt(this, executor, callback)
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock Credentials")
            .setSubtitle("Biometric authentication required to fill credentials")
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(
                0x00000001 or 0x00000002 // BIOMETRIC_STRONG | BIOMETRIC_WEAK
            )
            .build()

        prompt.authenticate(promptInfo, cryptoObject)
    }
}
