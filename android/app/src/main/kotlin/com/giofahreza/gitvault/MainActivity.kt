package com.giofahreza.gitvault

import android.app.Activity
import android.app.assist.AssistStructure
import android.content.Intent
import android.content.Context
import android.os.Bundle
import android.provider.Settings
import android.view.autofill.AutofillManager
import android.service.autofill.Dataset
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import android.view.inputmethod.InputMethodManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.giofahreza.gitvault.ime.CredentialCacheManager
import com.giofahreza.gitvault.ime.CredentialMetadata
import com.google.gson.Gson
import android.util.Log

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val IME_CHANNEL = "com.giofahreza.gitvault/ime"
        const val ACTION_DECRYPT_FOR_IME = "com.giofahreza.gitvault.DECRYPT_FOR_IME"
        const val EXTRA_REQUEST_TOKEN = "ime_request_token"
        const val EXTRA_UUID = "ime_uuid"
        const val EXTRA_FIELD = "ime_field"

        // Static reference to Flutter engine for IME credential requests
        @Volatile
        private var flutterEngineInstance: FlutterEngine? = null

        // Application context for starting activities when engine is null
        @Volatile
        var appContext: android.content.Context? = null

        // Pending IME decrypt when engine was null at request time
        @Volatile
        var pendingIMEToken: String? = null
        @Volatile
        var pendingIMEUuid: String? = null
        @Volatile
        var pendingIMEField: String? = null

        fun isEngineAvailable(): Boolean = flutterEngineInstance != null

        // Pending autofill request stored on cold start for Flutter to poll
        @Volatile var pendingAutofillPackage: String? = null
        @Volatile var pendingAutofillDomain: String? = null
        @Volatile var hasPendingAutofill: Boolean = false

        /**
         * Decrypt credential for IME after biometric authentication.
         * Called from SecureCredentialRequestActivity after successful auth.
         *
         * SECURITY: Only called after biometric auth passes in SecureCredentialRequestActivity.
         */
        fun decryptCredentialForIME(
            uuid: String,
            field: String,
            callback: (String?) -> Unit
        ) {
            val engine = flutterEngineInstance
            if (engine == null) {
                Log.e(TAG, "Flutter engine not initialized - cannot decrypt credential")
                callback(null)
                return
            }

            try {
                val channel = MethodChannel(engine.dartExecutor.binaryMessenger, IME_CHANNEL)

                channel.invokeMethod(
                    "getCredentialFieldForIME",
                    mapOf("uuid" to uuid, "field" to field),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            // Result is the decrypted credential string
                            val credential = result as? String

                            // DO NOT LOG THE ACTUAL CREDENTIAL
                            Log.d(TAG, "Credential decrypted: ${if (credential != null) "success" else "null"}")

                            callback(credential)
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                            Log.e(TAG, "Flutter returned error: $errorCode - $errorMessage")
                            callback(null)
                        }

                        override fun notImplemented() {
                            Log.e(TAG, "Method not implemented in Flutter")
                            callback(null)
                        }
                    }
                )
            } catch (e: Exception) {
                Log.e(TAG, "Error decrypting credential: ${e.message}", e)
                callback(null)
            }
        }
    }

    private val AUTOFILL_CHANNEL = "com.giofahreza.gitvault/autofill"
    private var autofillMethodChannel: MethodChannel? = null
    private var imeMethodChannel: MethodChannel? = null

    // Store autofill IDs when authentication is requested
    private var pendingUsernameId: AutofillId? = null
    private var pendingPasswordId: AutofillId? = null

    // IME credential cache manager
    private lateinit var credentialCacheManager: CredentialCacheManager
    private val gson = Gson()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Store static reference for IME credential decryption
        flutterEngineInstance = flutterEngine
        appContext = applicationContext

        credentialCacheManager = CredentialCacheManager(this)

        // Setup autofill channel
        autofillMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUTOFILL_CHANNEL
        )

        // Set the channel for AutofillService to use
        GitVaultAutofillService.methodChannel = autofillMethodChannel

        autofillMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "enableAutofillService" -> {
                    enableAutofillService()
                    result.success(null)
                }
                "isAutofillServiceEnabled" -> {
                    val enabled = isAutofillServiceEnabled()
                    result.success(enabled)
                }
                "getPendingAutofillRequest" -> {
                    if (hasPendingAutofill) {
                        val data = mapOf(
                            "package" to pendingAutofillPackage,
                            "domain" to pendingAutofillDomain
                        )
                        hasPendingAutofill = false
                        pendingAutofillPackage = null
                        pendingAutofillDomain = null
                        Log.d(TAG, "Delivering pending autofill request to Flutter")
                        result.success(data)
                    } else {
                        result.success(null)
                    }
                }
                "provideAutofillData" -> {
                    val username = call.argument<String>("username")
                    val password = call.argument<String>("password")
                    setAutofillResult(username, password)
                    result.success(true)
                }
                "cancelAutofill" -> {
                    setResult(Activity.RESULT_CANCELED)
                    finish()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Setup IME channel
        imeMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            IME_CHANNEL
        )

        imeMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateCredentialCache" -> {
                    val metadataJson = call.argument<String>("metadata")
                    if (metadataJson != null) {
                        try {
                            updateCredentialCache(metadataJson)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to update credential cache: ${e.message}")
                            result.error("CACHE_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARG", "metadata is null", null)
                    }
                }
                "getCredentialForIME" -> {
                    val uuid = call.argument<String>("uuid")
                    if (uuid != null) {
                        // This will be called by Flutter to provide a single credential
                        // The IME will receive the result and fill it
                        result.success(null)
                    } else {
                        result.error("INVALID_ARG", "uuid is null", null)
                    }
                }
                "isIMEEnabled" -> {
                    val enabled = isIMEEnabled()
                    result.success(enabled)
                }
                "openIMESettings" -> {
                    openIMESettings()
                    result.success(null)
                }
                "showKeyboardPicker" -> {
                    showKeyboardPicker()
                    result.success(null)
                }
                "setThemeMode" -> {
                    val mode = call.argument<String>("mode") ?: "system"
                    saveThemeMode(mode)
                    result.success(null)
                }
                "getCredentialFieldForIME" -> {
                    // This is called from SecureCredentialRequestActivity
                    // Flutter will handle the actual decryption
                    // Just forward the call to Flutter
                    result.success(null) // Will be handled by Flutter method channel
                }
                else -> result.notImplemented()
            }
        }

        // After engine and channels are set up, process any pending IME decrypt
        // Delay to allow Flutter/Dart side to initialize its method handlers
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            processPendingIMEDecrypt()
        }, 1000)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Check if this is an autofill authentication request
        if (intent?.getBooleanExtra("autofill_request", false) == true) {
            val packageName = intent?.getStringExtra("autofill_package")
            val domain = intent?.getStringExtra("autofill_domain")

            // Extract autofill IDs from intent (needed for setAutofillResult later)
            @Suppress("DEPRECATION")
            pendingUsernameId = intent?.getParcelableExtra("username_id")
            @Suppress("DEPRECATION")
            pendingPasswordId = intent?.getParcelableExtra("password_id")

            // Store for Flutter to poll — avoids cold-start timing race where
            // the Dart isolate hasn't registered its method handler yet.
            pendingAutofillPackage = packageName
            pendingAutofillDomain = domain
            hasPendingAutofill = true
            Log.d(TAG, "Autofill request stored for Flutter poll: pkg=$packageName, domain=$domain")
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == ACTION_DECRYPT_FOR_IME) {
            Log.d(TAG, "onNewIntent: decrypt for IME request")
            processPendingIMEDecrypt()
        }
    }

    private fun processPendingIMEDecrypt() {
        val token = pendingIMEToken ?: return
        val uuid = pendingIMEUuid ?: return
        val field = pendingIMEField ?: return

        pendingIMEToken = null
        pendingIMEUuid = null
        pendingIMEField = null

        Log.d(TAG, "Processing pending IME decrypt for token $token")

        val request = com.giofahreza.gitvault.ime.SecureCredentialBridge.getRequestDetails(token)
        if (request == null) {
            Log.w(TAG, "Pending IME decrypt: request expired or not found")
            return
        }

        decryptCredentialForIME(uuid, field) { credential ->
            Log.d(TAG, "Pending IME decrypt result: ${if (credential != null) "success" else "null"}")
            com.giofahreza.gitvault.ime.SecureCredentialBridge.deliverResult(token, credential)

            // The credential has been delivered to the IME. Move GitVault to the
            // background so the target app (e.g. Chrome) regains focus and the IME
            // can fill the credential into the correct input field.
            if (!isFinishing) {
                Log.d(TAG, "IME credential delivered; moving task to back")
                moveTaskToBack(true)
            }
        }
    }

    private fun enableAutofillService() {
        val autofillManager = getSystemService(AutofillManager::class.java)
        if (autofillManager != null && !autofillManager.hasEnabledAutofillServices()) {
            val intent = Intent(android.provider.Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE)
            intent.data = android.net.Uri.parse("package:$packageName")
            startActivity(intent)
        }
    }

    private fun isAutofillServiceEnabled(): Boolean {
        val autofillManager = getSystemService(AutofillManager::class.java)
        return autofillManager?.hasEnabledAutofillServices() == true
    }

    private fun setAutofillResult(username: String?, password: String?) {
        // Create a presentation for the dataset
        val presentation = RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
            setTextViewText(android.R.id.text1, "GitVault")
        }

        // Build the dataset with actual credentials
        val datasetBuilder = Dataset.Builder()

        if (pendingUsernameId != null && username != null) {
            datasetBuilder.setValue(
                pendingUsernameId!!,
                AutofillValue.forText(username),
                presentation
            )
        }

        if (pendingPasswordId != null && password != null) {
            datasetBuilder.setValue(
                pendingPasswordId!!,
                AutofillValue.forText(password),
                presentation
            )
        }

        // For dataset-level authentication (Dataset.setAuthentication), the reply must be
        // the Dataset directly — NOT wrapped in FillResponse.
        // Wrapping in FillResponse causes the framework to show the fill UI again instead
        // of filling the fields directly.
        val replyIntent = Intent().apply {
            putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, datasetBuilder.build())
        }

        setResult(Activity.RESULT_OK, replyIntent)
        finish()
    }

    /**
     * Update the encrypted credential metadata cache.
     * Receives JSON array of {uuid, title, url} and encrypts it with KeyStore.
     */
    private fun updateCredentialCache(metadataJson: String) {
        try {
            // Parse the JSON array
            val metadataList = mutableListOf<CredentialMetadata>()
            val jsonArray = com.google.gson.JsonParser.parseString(metadataJson).asJsonArray

            for (element in jsonArray) {
                val obj = element.asJsonObject
                metadataList.add(
                    CredentialMetadata(
                        uuid = obj.get("uuid")?.asString ?: "",
                        title = obj.get("title")?.asString ?: "",
                        url = if (obj.has("url") && !obj.get("url").isJsonNull) obj.get("url").asString else null,
                        group = if (obj.has("group") && !obj.get("group").isJsonNull) obj.get("group").asString else null,
                        hasTotpSecret = obj.get("hasTotpSecret")?.asBoolean ?: false,
                        totpSecret = if (obj.has("totpSecret") && !obj.get("totpSecret").isJsonNull) obj.get("totpSecret").asString else null
                    )
                )
            }

            // Get encryption cipher (with fresh IV, no auth needed for write)
            val cipher = credentialCacheManager.getCipherForEncryption()

            // Write encrypted cache
            credentialCacheManager.writeMetadataCache(metadataList, cipher)
            Log.d(TAG, "Credential cache updated: ${metadataList.size} entries")
        } catch (e: Exception) {
            Log.e(TAG, "Error updating credential cache: ${e.message}")
            throw e
        }
    }

    /** Save theme mode to SharedPreferences so the IME can read it without Flutter. */
    private fun saveThemeMode(mode: String) {
        getSharedPreferences("gitvault_ime_prefs", android.content.Context.MODE_PRIVATE)
            .edit().putString("theme_mode", mode).apply()
        Log.d(TAG, "Theme mode saved: $mode")
    }

    /**
     * Check if GitVault IME keyboard is enabled as the current input method.
     */
    private fun isIMEEnabled(): Boolean {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val currentImeId = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.DEFAULT_INPUT_METHOD
        )
        return currentImeId?.contains("com.giofahreza.gitvault") ?: false
    }

    /**
     * Open the system IME settings page.
     */
    private fun openIMESettings() {
        startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
    }

    /**
     * Show the keyboard picker to let user switch to GitVault IME.
     */
    private fun showKeyboardPicker() {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showInputMethodPicker()
    }
}
