package com.giofahreza.gitvault.ime

import android.content.Intent
import android.hardware.biometrics.BiometricPrompt
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.CancellationSignal
import android.util.Log
import android.util.TypedValue
import android.view.LayoutInflater
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.giofahreza.gitvault.MainActivity
import com.giofahreza.gitvault.R

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

    // Credential waiting to be filled on next IME rebind to target field
    @Volatile
    private var pendingCredentialToFill: String? = null

    // Package name of the app that requested the fill (e.g. "com.android.chrome").
    // The pending credential is only committed when the IME rebinds to this package,
    // preventing accidental fill into GitVault's own UI when the Flutter engine
    // is cold-started via MainActivity to decrypt the credential.
    @Volatile
    private var pendingFillTargetPackage: String? = null

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
        // Force show the keyboard even when hardware keyboard is connected
        requestShowSelf(0)
    }

    override fun onStartInputView(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(attribute, restarting)
        currentEditorInfo = attribute
        currentInputConnection = getCurrentInputConnection()
        val pkg = attribute?.packageName ?: ""
        Log.d(TAG, "onStartInputView: input view started, pkg=$pkg")

        // Fill any pending credential now that the IME has rebound to the target field.
        // Post with a short delay to allow the target app's InputConnection to fully
        // settle after regaining focus from SecureCredentialRequestActivity.
        val pending = pendingCredentialToFill
        val targetPkg = pendingFillTargetPackage
        if (pending != null) {
            // Only fill when the IME is bound to the app that originally requested the fill.
            // If targetPkg is null (legacy/unknown), fill regardless of current package.
            if (targetPkg != null && pkg != targetPkg) {
                Log.d(TAG, "Deferring fill: current pkg=$pkg, waiting for pkg=$targetPkg")
                // Leave pendingCredentialToFill set — it will be consumed when the
                // correct app regains focus (e.g. after moveTaskToBack in MainActivity).
            } else {
                pendingCredentialToFill = null
                pendingFillTargetPackage = null
                Log.d(TAG, "Filling pending credential after IME rebind (pkg=$pkg)")

                // Detect Chrome/WebView-based browsers that use a DOM sync loop.
                // commitText and setComposingText both return true but the text gets
                // erased by Chrome's sync loop (which resets the field to match JS state
                // after the auth overlay caused JS focus loss). Clipboard paste bypasses
                // this sync loop entirely, so it is used for browsers.
                val isWebBrowser = pkg.contains("chrome") ||
                    pkg.contains("chromium") ||
                    pkg.contains("firefox") ||
                    pkg.contains("browser") ||
                    pkg.contains("opera") ||
                    pkg.contains("vivaldi") ||
                    pkg.contains("brave")
                // For browsers: clipboard paste strategy (no delay needed before the
                // strategy call — the 300ms clipboard-settle delay is inside fillTextViaCompose).
                // For native apps: commitText with 300ms for InputConnection to settle.
                val fillDelay = if (isWebBrowser) 0L else 300L
                Log.d(TAG, "Fill strategy: ${if (isWebBrowser) "clipboard-paste" else "commitText"} (delay=${fillDelay}ms) for pkg=$pkg")

                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    if (isWebBrowser) {
                        fillTextViaCompose(pending)
                    } else {
                        fillText(pending)
                    }
                }, fillDelay)
            }
        }
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
        val scrollView = inputView?.findViewById<ScrollView>(R.id.ime_credentials_scroll)
        val listContainer = inputView?.findViewById<LinearLayout>(R.id.ime_credentials_list)
        val messageView = inputView?.findViewById<TextView>(R.id.ime_message)

        if (listContainer == null || scrollView == null) {
            Log.e(TAG, "Credential list container not found")
            return
        }

        Log.d(TAG, "Displaying ${credentials.size} credentials")

        // Hide message, show list
        messageView?.visibility = View.GONE
        scrollView.visibility = View.VISIBLE

        // Clear existing views
        listContainer.removeAllViews()

        val density = resources.displayMetrics.density

        for (credential in credentials) {
            // Row container
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
                val pad = (12 * density).toInt()
                setPadding((16 * density).toInt(), pad, (16 * density).toInt(), pad)
                gravity = android.view.Gravity.CENTER_VERTICAL
            }

            // Title + URL column
            val textCol = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                val marginEnd = (8 * density).toInt()
                (layoutParams as LinearLayout.LayoutParams).marginEnd = marginEnd
            }
            val titleView = TextView(this).apply {
                text = credential.title
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(null, android.graphics.Typeface.BOLD)
                setTextColor(android.graphics.Color.BLACK)
            }
            val urlView = TextView(this).apply {
                text = credential.url ?: "(no URL)"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setTextColor(android.graphics.Color.DKGRAY)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
                val topMargin = (2 * density).toInt()
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).also { it.topMargin = topMargin }
            }
            textCol.addView(titleView)
            textCol.addView(urlView)

            // Username (info) button
            val usernameBtn = ImageButton(this).apply {
                val size = (48 * density).toInt()
                layoutParams = LinearLayout.LayoutParams(size, size).also {
                    it.marginEnd = (4 * density).toInt()
                }
                val pad = (8 * density).toInt()
                setPadding(pad, pad, pad, pad)
                setImageResource(android.R.drawable.ic_dialog_info)
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                isClickable = true
                isFocusable = false
                contentDescription = "Fill username"
                Log.d(TAG, "Creating username button for ${credential.title}")
                setOnClickListener {
                    Log.d(TAG, "USERNAME button clicked for ${credential.title}")
                    requestCredentialFill(credential.uuid, "username")
                }
            }

            // Password (lock) button
            val passwordBtn = ImageButton(this).apply {
                val size = (48 * density).toInt()
                layoutParams = LinearLayout.LayoutParams(size, size)
                val pad = (8 * density).toInt()
                setPadding(pad, pad, pad, pad)
                setImageResource(android.R.drawable.ic_lock_lock)
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                isClickable = true
                isFocusable = false
                contentDescription = "Fill password"
                Log.d(TAG, "Creating password button for ${credential.title}")
                setOnClickListener {
                    Log.d(TAG, "PASSWORD button clicked for ${credential.title}")
                    requestCredentialFill(credential.uuid, "password")
                }
            }

            row.addView(textCol)
            row.addView(usernameBtn)
            row.addView(passwordBtn)
            listContainer.addView(row)

            Log.d(TAG, "Added credential row for: ${credential.title}")
        }
    }

    /**
     * Request credential fill with biometric authentication.
     *
     * Preferred path (API 28+, Flutter engine running):
     *   Use android.hardware.biometrics.BiometricPrompt directly from the IME service.
     *   This shows a system-level dialog that does NOT launch a new Activity/task,
     *   so Chrome's window retains focus throughout. After successful auth, the
     *   credential is filled via commitText while Chrome's HTML element still has
     *   JS focus — no clipboard needed, no DOM-sync issues.
     *
     * Fallback path:
     *   Launch SecureCredentialRequestActivity (existing Activity-based flow) which
     *   stores the credential as pendingCredentialToFill and fills via clipboard paste
     *   in onStartInputView after Chrome's IME rebinds.
     */
    private fun requestCredentialFill(uuid: String, field: String) {
        val targetPackage = currentEditorInfo?.packageName
        Log.d(TAG, "Requesting secure fill for $uuid/$field, targetPkg=$targetPackage")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && MainActivity.isEngineAvailable()) {
            requestCredentialFillWithSystemBiometric(uuid, field, targetPackage)
        } else {
            requestCredentialFillViaActivity(uuid, field, targetPackage)
        }
    }

    /**
     * Auth via android.hardware.biometrics.BiometricPrompt (API 28+).
     * Shows a system dialog without launching an Activity, so Chrome keeps window
     * focus. On success the credential is decrypted and committed directly.
     */
    @android.annotation.TargetApi(Build.VERSION_CODES.P)
    private fun requestCredentialFillWithSystemBiometric(
        uuid: String,
        field: String,
        targetPackage: String?
    ) {
        try {
            val executor = mainExecutor

            val promptBuilder = BiometricPrompt.Builder(this)
                .setTitle("Unlock Credential")
                .setSubtitle("Authenticate to fill ${if (field == "username") "username" else "password"}")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // API 30+: allow both biometric and device credential (PIN/pattern)
                promptBuilder.setAllowedAuthenticators(
                    android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_WEAK or
                    android.hardware.biometrics.BiometricManager.Authenticators.DEVICE_CREDENTIAL
                )
            } else {
                // API 28-29: biometric only, with a negative button for cancel
                promptBuilder.setNegativeButton("Cancel", executor) { _, _ ->
                    Log.d(TAG, "System biometric prompt cancelled")
                }
            }

            val cancellationSignal = CancellationSignal()

            promptBuilder.build().authenticate(
                cancellationSignal,
                executor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        result: BiometricPrompt.AuthenticationResult
                    ) {
                        Log.d(TAG, "System biometric auth succeeded, decrypting credential")
                        MainActivity.decryptCredentialForIME(uuid, field) { credential: String? ->
                            if (credential != null) {
                                // A brief delay lets Chrome restore JS focus after the
                                // system biometric dialog dismisses before we commitText.
                                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                    val currentPkg = currentEditorInfo?.packageName ?: ""
                                    if (targetPackage == null || currentPkg == targetPackage) {
                                        Log.d(TAG, "Direct commitText fill after system biometric (pkg=$currentPkg)")
                                        fillText(credential)
                                    } else {
                                        // IME has moved to a different app; queue the fill.
                                        pendingCredentialToFill = credential
                                        pendingFillTargetPackage = targetPackage
                                        Log.d(TAG, "System biometric fill queued for pkg=$targetPackage (current=$currentPkg)")
                                    }
                                }, 300L)
                            } else {
                                Log.w(TAG, "Credential decryption failed after system biometric auth")
                            }
                        }
                    }

                    override fun onAuthenticationFailed() {
                        Log.w(TAG, "System biometric: finger not recognized")
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        Log.w(TAG, "System biometric error $errorCode: $errString")
                        // BIOMETRIC_ERROR_USER_CANCELED (10) and negative button (13) mean the
                        // user explicitly dismissed. For hardware errors, fall back to activity flow.
                        if (errorCode != BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED &&
                            errorCode != 13 /* BIOMETRIC_ERROR_NEGATIVE_BUTTON */) {
                            Log.d(TAG, "Falling back to activity-based fill flow")
                            requestCredentialFillViaActivity(uuid, field, targetPackage)
                        }
                    }
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "System biometric setup failed, using activity flow: ${e.message}", e)
            requestCredentialFillViaActivity(uuid, field, targetPackage)
        }
    }

    /**
     * Fallback auth via SecureCredentialRequestActivity (transparent Activity, new task).
     * Used when the Flutter engine is not running or on API < 28.
     * After auth, fills via clipboard paste on Chrome or commitText on native apps.
     */
    private fun requestCredentialFillViaActivity(
        uuid: String,
        field: String,
        targetPackage: String?
    ) {
        try {
            val requestToken = SecureCredentialBridge.requestCredential(uuid, field) { credential ->
                if (credential != null) {
                    pendingCredentialToFill = credential
                    pendingFillTargetPackage = targetPackage
                    Log.d(TAG, "Credential ready, queued for fill on pkg=$targetPackage")
                } else {
                    Log.w(TAG, "Credential request cancelled or failed")
                }
            }

            val intent = Intent(this, SecureCredentialRequestActivity::class.java)
            intent.putExtra(SecureCredentialRequestActivity.EXTRA_REQUEST_TOKEN, requestToken)
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION
            startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Error launching credential request activity: ${e.message}", e)
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
            val success = inputConnection.commitText(text, 1)
            Log.d(TAG, "commitText result: $success, connection: ${inputConnection.javaClass.simpleName}")

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
     * Fill text into a Chrome/WebView target via clipboard paste.
     *
     * Chrome's ThreadedInputConnection accepts commitText and setComposingText but
     * its DOM sync loop immediately resets the field to match the JS state (empty,
     * since JS focus was lost when the auth overlay appeared). Clipboard paste goes
     * through a higher-level OS path that bypasses the InputConnection sync loop
     * and directly triggers Chrome's paste handler, which works regardless of
     * whether the HTML element has been unfocused at the JS level.
     *
     * All clipboard IPC calls run on a background thread to avoid blocking the
     * IME's main thread and causing an ANR (the clipboard service can be slow on
     * some emulator configurations).
     *
     * SECURITY: Clipboard is cleared 5 seconds after paste.
     */
    private fun fillTextViaCompose(text: String) {
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
        executor.execute {
            try {
                val cm = getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                    as android.content.ClipboardManager
                cm.setPrimaryClip(android.content.ClipData.newPlainText("", text))
                Log.d(TAG, "Credential placed in clipboard")

                // Brief pause for clipboard broadcast to settle before paste
                Thread.sleep(300)

                val ic = getCurrentInputConnection()
                val pasted = ic?.performContextMenuAction(android.R.id.paste) ?: false
                Log.d(TAG, "paste result: $pasted")

                // SECURITY: zero-out credential
                val chars = text.toCharArray()
                chars.fill('\u0000')
                try {
                    val f = String::class.java.getDeclaredField("value")
                    f.isAccessible = true
                    (f.get(text) as? CharArray)?.fill('\u0000')
                } catch (_: Exception) {}

                // Clear clipboard after a generous delay
                Thread.sleep(5000)
                try {
                    cm.setPrimaryClip(android.content.ClipData.newPlainText("", ""))
                    Log.d(TAG, "Clipboard cleared after paste")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to clear clipboard: ${e.message}")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error filling via clipboard: ${e.message}", e)
            } finally {
                executor.shutdown()
            }
        }
    }

    /**
     * Fill text via clipboard paste — more reliable for Chrome/WebView targets.
     * Chrome's WebView loses JS focus when the transparent auth overlay is shown;
     * commitText returns true but the text never reaches the HTML input element.
     * Paste goes through a higher-level path that doesn't require JS focus.
     *
     * SECURITY: Clipboard is cleared 1.5 seconds after paste.
     */
    private fun fillTextViaClipboard(text: String) {
        try {
            val cm = getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                as android.content.ClipboardManager

            // Put credential in clipboard
            cm.setPrimaryClip(android.content.ClipData.newPlainText("", text))
            Log.d(TAG, "Credential placed in clipboard, attempting paste")

            // Trigger paste via InputConnection context-menu action
            val ic = getCurrentInputConnection()
            val pasted = ic?.performContextMenuAction(android.R.id.paste) ?: false
            Log.d(TAG, "performContextMenuAction(paste) result: $pasted")

            // Schedule clipboard clear regardless of paste result.
            // Use empty string replacement instead of clearPrimaryClip() to avoid
            // triggering the "beginBroadcast() called while already in a broadcast"
            // IllegalStateException in some Android system versions.
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                try {
                    cm.setPrimaryClip(android.content.ClipData.newPlainText("", ""))
                    Log.d(TAG, "Clipboard cleared after paste")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to clear clipboard: ${e.message}")
                }
            }, 1500)

        } catch (e: Exception) {
            Log.e(TAG, "Error filling via clipboard: ${e.message}", e)
        }
    }

    /**
     * Show empty state when no credentials available.
     */
    private fun showEmptyState() {
        val scrollView = inputView?.findViewById<ScrollView>(R.id.ime_credentials_scroll)
        val messageView = inputView?.findViewById<TextView>(R.id.ime_message)

        // Show message, hide list
        messageView?.visibility = View.VISIBLE
        scrollView?.visibility = View.GONE
    }

    override fun onDestroy() {
        super.onDestroy()
        pendingCredentialToFill = null
        pendingFillTargetPackage = null
        Log.d(TAG, "IME service destroyed, pending credential cleared")
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
        // Note: pendingCredentialToFill is intentionally NOT cleared here.
        // It must survive the onUnbindInput → onStartInputView cycle that
        // occurs when SecureCredentialRequestActivity finishes. It is cleared
        // in onStartInputView after being used (or if the session ends via
        // onFinishInput when there is no subsequent onStartInputView).
        Log.d(TAG, "Sensitive data cleared")
    }

}
