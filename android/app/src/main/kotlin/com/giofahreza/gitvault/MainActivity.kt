package com.giofahreza.gitvault

import android.app.Activity
import android.app.assist.AssistStructure
import android.content.Intent
import android.os.Bundle
import android.view.autofill.AutofillManager
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val AUTOFILL_CHANNEL = "com.giofahreza.gitvault/autofill"
    private var autofillMethodChannel: MethodChannel? = null

    // Store autofill IDs when authentication is requested
    private var pendingUsernameId: AutofillId? = null
    private var pendingPasswordId: AutofillId? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
}
