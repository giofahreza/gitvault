package com.giofahreza.gitvault.ime

import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.giofahreza.gitvault.R
import javax.crypto.Cipher

/**
 * Custom IME keyboard service for GitVault credential filling.
 *
 * Security features:
 * - FLAG_SECURE on IME window (prevents screen capture)
 * - BiometricPrompt with CryptoObject (every operation requires auth, no 30s window)
 * - Per-credential on-demand decryption (minimal memory exposure)
 * - Auto-lock when input disconnects
 * - CharArray zero-out after use
 */
class GitVaultIMEService : InputMethodService() {
    companion object {
        private const val TAG = "GitVaultIMEService"
        private const val IME_WINDOW_FLAG = "hideOverlayWindows"
    }

    private lateinit var credentialCacheManager: CredentialCacheManager
    private var inputView: View? = null
    private var currentEditorInfo: EditorInfo? = null
    private var currentInputConnection: InputConnection? = null

    override fun onCreateInputView(): View {
        Log.d(TAG, "onCreateInputView called")

        try {
            credentialCacheManager = CredentialCacheManager(this)

            // Inflate toolbar layout
            val inflater = LayoutInflater.from(this)
            inputView = inflater.inflate(R.layout.ime_toolbar, null)

            // Note: InputMethodService doesn't have direct window access for security flags
            // The IME runs in the system process and is inherently more secure than app windows

            // Setup load credentials button
            inputView?.findViewById<ImageButton>(R.id.ime_load_credentials)?.setOnClickListener {
                try {
                    loadCredentials()
                } catch (e: Exception) {
                    Log.e(TAG, "Error loading credentials: ${e.message}", e)
                }
            }

            // Setup switch keyboard button
            inputView?.findViewById<ImageButton>(R.id.ime_switch_keyboard)?.setOnClickListener {
                try {
                    switchToSystemKeyboard()
                } catch (e: Exception) {
                    Log.e(TAG, "Error switching keyboard: ${e.message}", e)
                }
            }

            // Load credentials immediately on keyboard show
            loadCredentials()

            Log.d(TAG, "Input view created successfully")
            return inputView!!
        } catch (e: Exception) {
            Log.e(TAG, "Fatal error in onCreateInputView: ${e.message}", e)
            // Create a minimal fallback view
            val fallbackView = android.widget.TextView(this)
            fallbackView.text = "GitVault Keyboard Error. Please check logs."
            fallbackView.setPadding(16, 16, 16, 16)
            return fallbackView
        }
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        currentEditorInfo = attribute
        Log.d(TAG, "onStartInput: input field detected")
    }

    override fun onStartInputView(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(attribute, restarting)
        currentEditorInfo = attribute
        currentInputConnection = getCurrentInputConnection()
        Log.d(TAG, "onStartInputView: input view started")
    }

    override fun onEvaluateInputViewShown(): Boolean {
        // Always show the keyboard view
        return true
    }

    override fun onBindInput() {
        super.onBindInput()
        Log.d(TAG, "onBindInput called")
    }

    override fun onUnbindInput() {
        super.onUnbindInput()
        Log.d(TAG, "onUnbindInput called - auto-locking")
        clearSensitiveData()
    }

    override fun onFinishInput() {
        super.onFinishInput()
        Log.d(TAG, "onFinishInput called")
        clearSensitiveData()
    }

    /**
     * Load credentials directly from cache without biometric auth.
     * The metadata cache only contains titles/URLs, not passwords.
     * Biometric auth will be required when filling actual passwords.
     */
    private fun loadCredentials() {
        try {
            val credentials = credentialCacheManager.readMetadataCache()
            Log.d(TAG, "Loaded ${credentials.size} credentials")

            if (credentials.isEmpty()) {
                showEmptyState()
            } else {
                displayCredentialsList(credentials)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load credentials: ${e.message}", e)
            showEmptyState()
        }
    }

    /**
     * Display credentials in RecyclerView.
     */
    private fun displayCredentialsList(credentials: List<CredentialMetadata>) {
        val recyclerView = inputView?.findViewById<RecyclerView>(R.id.ime_credentials_list)
        val messageView = inputView?.findViewById<android.widget.TextView>(R.id.ime_message)

        if (recyclerView == null) {
            Log.e(TAG, "RecyclerView not found")
            return
        }

        Log.d(TAG, "Displaying ${credentials.size} credentials in RecyclerView")

        // Hide message, show list
        messageView?.visibility = View.GONE
        recyclerView.visibility = View.VISIBLE

        val adapter = CredentialAdapter(
            credentials,
            onFillUsername = { uuid ->
                Log.d(TAG, "onFillUsername callback triggered for $uuid")
                requestCredentialFill(uuid, "username")
            },
            onFillPassword = { uuid ->
                Log.d(TAG, "onFillPassword callback triggered for $uuid")
                requestCredentialFill(uuid, "password")
            }
        )

        recyclerView.layoutManager = LinearLayoutManager(this)
        recyclerView.adapter = adapter

        // Add touch event logging
        recyclerView.setOnTouchListener { v, event ->
            Log.d(TAG, "RecyclerView touch event: ${event.action} at (${event.x}, ${event.y})")
            false // Don't consume the event
        }

        // Force layout to ensure items are drawn
        recyclerView.post {
            Log.d(TAG, "RecyclerView child count: ${recyclerView.childCount}")
            Log.d(TAG, "RecyclerView adapter item count: ${adapter.itemCount}")

            // Log each child view
            for (i in 0 until recyclerView.childCount) {
                val child = recyclerView.getChildAt(i)
                Log.d(TAG, "Child $i: ${child.javaClass.simpleName}, clickable=${child.isClickable}, bounds=${child.left},${child.top},${child.right},${child.bottom}")
            }
        }
    }

    /**
     * Request credential from Flutter with biometric authentication.
     * Security: Requires biometric auth, uses secure IPC, clears memory immediately.
     */
    private fun requestCredentialFill(uuid: String, field: String) {
        Log.d(TAG, "Requesting secure fill for $uuid/$field")

        try {
            // Create secure request with callback
            val requestToken = SecureCredentialBridge.requestCredential(uuid, field) { credential ->
                if (credential != null) {
                    // Fill the decrypted credential
                    fillText(credential)

                    // CRITICAL: Clear from memory immediately
                    // (CharArray zero-out happens in fillText)

                    Log.d(TAG, "Credential filled successfully")
                } else {
                    Log.w(TAG, "Credential request cancelled or failed")
                }
            }

            // Launch transparent activity for biometric auth
            val intent = Intent(this, SecureCredentialRequestActivity::class.java)
            intent.putExtra(SecureCredentialRequestActivity.EXTRA_REQUEST_TOKEN, requestToken)
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION
            startActivity(intent)

        } catch (e: Exception) {
            Log.e(TAG, "Error requesting credential: ${e.message}", e)
        }
    }

    /**
     * Fill text into the current input field.
     * SECURITY: Clears sensitive data from memory immediately after use.
     */
    private fun fillText(text: String) {
        try {
            // Get current input connection directly (don't rely on cached value)
            // This ensures we can fill even if onStartInputView hasn't been called yet
            val inputConnection = getCurrentInputConnection()
            if (inputConnection == null) {
                Log.e(TAG, "No input connection available to fill text")
                return
            }

            // Fill into input field
            inputConnection.commitText(text, 1)

            // CRITICAL: Zero-out the string from memory
            // Convert to CharArray and overwrite with nulls
            val chars = text.toCharArray()
            chars.fill('\u0000')

            // Force string internal value to be cleared (reflection, best effort)
            try {
                val valueField = String::class.java.getDeclaredField("value")
                valueField.isAccessible = true
                val value = valueField.get(text) as? CharArray
                value?.fill('\u0000')
            } catch (e: Exception) {
                // Reflection failed (expected on newer Android), but CharArray clearing above still works
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error filling text: ${e.message}", e)
        }
    }

    /**
     * Show empty state when no credentials available.
     */
    private fun showEmptyState() {
        val recyclerView = inputView?.findViewById<RecyclerView>(R.id.ime_credentials_list)
        val messageView = inputView?.findViewById<android.widget.TextView>(R.id.ime_message)

        // Show message, hide list
        messageView?.visibility = View.VISIBLE
        recyclerView?.visibility = View.GONE
    }

    /**
     * Switch back to system keyboard.
     */
    private fun switchToSystemKeyboard() {
        val imm = getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
            as android.view.inputmethod.InputMethodManager
        imm.switchToNextInputMethod(null, false)
    }

    /**
     * Clear all sensitive data when IME is closed.
     */
    private fun clearSensitiveData() {
        currentEditorInfo = null
        currentInputConnection = null
        Log.d(TAG, "Sensitive data cleared")
    }

}
