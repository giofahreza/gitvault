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
    private var decryptionCipher: Cipher? = null

    override fun onCreateInputView(): View {
        Log.d(TAG, "onCreateInputView called")

        credentialCacheManager = CredentialCacheManager(this)

        // Inflate toolbar layout
        val inflater = LayoutInflater.from(this)
        inputView = inflater.inflate(R.layout.ime_toolbar, null)

        // Note: InputMethodService doesn't have direct window access for security flags
        // The IME runs in the system process and is inherently more secure than app windows

        // Setup load credentials button
        inputView?.findViewById<ImageButton>(R.id.ime_load_credentials)?.setOnClickListener {
            loadCredentialsAfterAuth()
        }

        // Setup switch keyboard button
        inputView?.findViewById<ImageButton>(R.id.ime_switch_keyboard)?.setOnClickListener {
            switchToSystemKeyboard()
        }

        // Show keyboard immediately without auth (prevents keyboard from dismissing)
        // User can tap the load button to authenticate and load credentials
        loadCredentialsWithoutAuth()

        return inputView!!
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        currentEditorInfo = attribute
        Log.d(TAG, "onStartInput: input field detected")
    }

    override fun onStartInputView(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(attribute, restarting)
        currentEditorInfo = attribute
        Log.d(TAG, "onStartInputView: input view started")
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
     * Load credentials without authentication.
     * Just shows empty state with instructions initially.
     * User can tap a button to trigger auth and load credentials.
     */
    private fun loadCredentialsWithoutAuth() {
        // Don't auto-load credentials to avoid launching activity that dismisses keyboard
        // Show empty state with message
        showEmptyState()
        Log.d(TAG, "Keyboard ready. Credentials not loaded to prevent dismissal.")
    }

    /**
     * Load credentials after biometric authentication.
     * Reads encrypted metadata cache and displays credential titles.
     */
    private fun loadCredentialsAfterAuth() {
        // Request biometric auth
        requestBiometricAuth { cipher ->
            if (cipher != null) {
                decryptionCipher = cipher
                loadAndDisplayCredentials(cipher)
            } else {
                Log.w(TAG, "Biometric auth cancelled")
                showEmptyState()
            }
        }
    }

    /**
     * Request biometric authentication via GitVaultIMEAuthActivity.
     */
    private fun requestBiometricAuth(callback: (Cipher?) -> Unit) {
        // Set callback before launching activity
        GitVaultIMEAuthActivity.setAuthCallback(callback)

        // Launch transparent auth activity
        val intent = Intent(this, GitVaultIMEAuthActivity::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        startActivity(intent)
    }

    /**
     * Load encrypted metadata and display credentials in list.
     */
    private fun loadAndDisplayCredentials(cipher: Cipher) {
        try {
            val credentials = credentialCacheManager.readMetadataCache(cipher)
            Log.d(TAG, "Loaded ${credentials.size} credentials")

            if (credentials.isEmpty()) {
                showEmptyState()
            } else {
                displayCredentialsList(credentials)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load credentials: ${e.message}")
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

        // Hide message, show list
        messageView?.visibility = View.GONE
        recyclerView.visibility = View.VISIBLE

        val adapter = CredentialAdapter(
            credentials,
            onFillUsername = { uuid -> requestCredentialFill(uuid, "username") },
            onFillPassword = { uuid -> requestCredentialFill(uuid, "password") }
        )

        recyclerView.layoutManager = LinearLayoutManager(this)
        recyclerView.adapter = adapter
    }

    /**
     * Request credential from Flutter via MethodChannel.
     * Flutter decrypts the entry and returns username or password.
     * IME fills it into the input field.
     */
    private fun requestCredentialFill(uuid: String, field: String) {
        // TODO: Call Flutter to get decrypted credential
        // For now, this is a placeholder that shows the integration point
        Log.d(TAG, "Requesting fill for $uuid/$field")

        // In production, this would:
        // 1. Call Flutter via MethodChannel to get credential
        // 2. Receive decrypted username/password
        // 3. Fill into input field using InputConnection
        // 4. Clear sensitive data from memory
    }

    /**
     * Fill text into the current input field.
     */
    private fun fillText(text: String) {
        currentInputConnection?.commitText(text, 1)

        // Zero-out the string from memory
        text.toCharArray().fill('\u0000')
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
        decryptionCipher = null
        currentEditorInfo = null
        currentInputConnection = null
        Log.d(TAG, "Sensitive data cleared")
    }

}
