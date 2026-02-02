package com.giofahreza.gitvault

import android.app.Activity
import android.app.assist.AssistStructure
import android.content.Intent
import android.content.Context
import android.os.Bundle
import android.provider.Settings
import android.view.autofill.AutofillManager
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
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
    }

    private val AUTOFILL_CHANNEL = "com.giofahreza.gitvault/autofill"
    private val IME_CHANNEL = "com.giofahreza.gitvault/ime"
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
                "provideAutofillData" -> {
                    val username = call.argument<String>("username")
                    val password = call.argument<String>("password")
                    setAutofillResult(username, password)
                    result.success(true)
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
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Check if this is an autofill authentication request
        if (intent?.getBooleanExtra("autofill_request", false) == true) {
            val packageName = intent?.getStringExtra("autofill_package")
            val domain = intent?.getStringExtra("autofill_domain")

            // Extract autofill IDs from intent
            pendingUsernameId = intent?.getParcelableExtra("username_id")
            pendingPasswordId = intent?.getParcelableExtra("password_id")

            // Notify Flutter that autofill is requested
            autofillMethodChannel?.invokeMethod("autofillRequested", mapOf(
                "package" to packageName,
                "domain" to domain
            ))
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

        // Create the response with the dataset
        val fillResponse = FillResponse.Builder()
            .addDataset(datasetBuilder.build())
            .build()

        // Return the filled response
        val replyIntent = Intent().apply {
            putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, fillResponse)
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
                        url = obj.get("url")?.asString
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
