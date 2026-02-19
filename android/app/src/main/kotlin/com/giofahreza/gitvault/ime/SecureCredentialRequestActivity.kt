package com.giofahreza.gitvault.ime

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.giofahreza.gitvault.MainActivity

/**
 * Transparent activity for secure credential decryption.
 *
 * Security flow:
 * 1. Receives request token from IME
 * 2. Shows biometric prompt
 * 3. After auth, calls Flutter to decrypt credential
 * 4. Returns result to IME via SecureCredentialBridge
 * 5. Finishes immediately (no UI visible)
 *
 * Security features:
 * - Transparent theme (invisible to user)
 * - Single-use request tokens
 * - Biometric auth required
 * - No credential logging
 * - Immediate memory clearing
 */
class SecureCredentialRequestActivity : FragmentActivity() {
    companion object {
        private const val TAG = "SecureCredentialReq"
        const val EXTRA_REQUEST_TOKEN = "request_token"
    }

    private var requestToken: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "onCreate called")

        // Get request token from intent
        requestToken = intent.getStringExtra(EXTRA_REQUEST_TOKEN)
        if (requestToken == null) {
            Log.e(TAG, "No request token provided")
            cancelAndFinish()
            return
        }

        // Verify request is valid
        val request = SecureCredentialBridge.getRequestDetails(requestToken!!)
        if (request == null) {
            Log.e(TAG, "Invalid or expired request token")
            cancelAndFinish()
            return
        }

        // Show biometric prompt
        showBiometricPrompt(request)
    }

    private fun showBiometricPrompt(request: SecureCredentialBridge.PendingRequest) {
        val executor = ContextCompat.getMainExecutor(this)

        val biometricPrompt = BiometricPrompt(this, executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    super.onAuthenticationSucceeded(result)
                    Log.d(TAG, "Biometric authentication succeeded")
                    // Decrypt and return credential
                    decryptAndReturnCredential(request)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    super.onAuthenticationError(errorCode, errString)
                    Log.w(TAG, "Biometric authentication error: $errorCode - $errString")
                    cancelAndFinish()
                }

                override fun onAuthenticationFailed() {
                    super.onAuthenticationFailed()
                    Log.w(TAG, "Biometric authentication failed")
                    // Don't finish - let user retry
                }
            })

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock Credential")
            .setSubtitle("Authenticate to fill ${request.field}")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.BIOMETRIC_WEAK or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            .build()

        biometricPrompt.authenticate(promptInfo)
    }

    private fun decryptAndReturnCredential(request: SecureCredentialBridge.PendingRequest) {
        try {
            // Call MainActivity to decrypt credential via Flutter
            MainActivity.decryptCredentialForIME(
                uuid = request.uuid,
                field = request.field,
                callback = { credential ->
                    // DO NOT LOG THE ACTUAL CREDENTIAL
                    Log.d(TAG, "Credential received from Flutter: ${if (credential != null) "success" else "null"}")

                    deliverResult(credential)
                }
            )

        } catch (e: Exception) {
            Log.e(TAG, "Error processing credential: ${e.message}", e)
            deliverResult(null)
        }
    }

    private fun deliverResult(result: String?) {
        if (requestToken != null) {
            SecureCredentialBridge.deliverResult(requestToken!!, result)
        }
        finish()
    }

    private fun cancelAndFinish() {
        if (requestToken != null) {
            SecureCredentialBridge.cancelRequest(requestToken!!)
        }
        finish()
    }

}
