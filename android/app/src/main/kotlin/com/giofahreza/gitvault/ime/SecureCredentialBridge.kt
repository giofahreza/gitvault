package com.giofahreza.gitvault.ime

import android.util.Log
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Secure bridge between IME and MainActivity for credential requests.
 *
 * Security features:
 * - Request tokens expire after 30 seconds
 * - Callbacks are single-use only
 * - No credential data stored in this class
 * - All sensitive data cleared immediately after use
 */
object SecureCredentialBridge {
    private const val TAG = "SecureCredentialBridge"
    private const val REQUEST_TIMEOUT_MS = 30000L // 30 seconds

    // Pending credential requests with expiration
    private val pendingRequests = ConcurrentHashMap<String, PendingRequest>()

    /**
     * Request a credential field from the main app.
     * Returns a request token that can be used to receive the result.
     */
    fun requestCredential(
        uuid: String,
        field: String, // "username" or "password"
        callback: (String?) -> Unit
    ): String {
        // Generate unique request token
        val requestToken = UUID.randomUUID().toString()

        // Store request with expiration
        val request = PendingRequest(
            uuid = uuid,
            field = field,
            callback = callback,
            expiresAt = System.currentTimeMillis() + REQUEST_TIMEOUT_MS
        )

        pendingRequests[requestToken] = request

        // Clean up expired requests
        cleanupExpiredRequests()

        Log.d(TAG, "Credential request created: token=$requestToken, uuid=$uuid, field=$field")
        return requestToken
    }

    /**
     * Deliver the credential result to the waiting callback.
     * Single-use only - request is removed after delivery.
     */
    fun deliverResult(requestToken: String, result: String?) {
        val request = pendingRequests.remove(requestToken)

        if (request == null) {
            Log.w(TAG, "No pending request found for token: $requestToken")
            return
        }

        // Check if expired
        if (System.currentTimeMillis() > request.expiresAt) {
            Log.w(TAG, "Request expired: $requestToken")
            request.callback(null)
            return
        }

        // Deliver result (will be cleared by IME immediately after use)
        request.callback(result)
        Log.d(TAG, "Credential delivered for token: $requestToken")
    }

    /**
     * Cancel a pending request.
     */
    fun cancelRequest(requestToken: String) {
        pendingRequests.remove(requestToken)
        Log.d(TAG, "Request cancelled: $requestToken")
    }

    /**
     * Get request details for biometric prompt.
     */
    fun getRequestDetails(requestToken: String): PendingRequest? {
        return pendingRequests[requestToken]?.takeIf {
            System.currentTimeMillis() <= it.expiresAt
        }
    }

    /**
     * Remove expired requests to prevent memory leaks.
     */
    private fun cleanupExpiredRequests() {
        val now = System.currentTimeMillis()
        pendingRequests.entries.removeIf { (token, request) ->
            if (now > request.expiresAt) {
                Log.d(TAG, "Removing expired request: $token")
                true
            } else {
                false
            }
        }
    }

    /**
     * Clear all pending requests (e.g., on app termination).
     */
    fun clearAll() {
        pendingRequests.clear()
        Log.d(TAG, "All pending requests cleared")
    }

    data class PendingRequest(
        val uuid: String,
        val field: String,
        val callback: (String?) -> Unit,
        val expiresAt: Long
    )
}
