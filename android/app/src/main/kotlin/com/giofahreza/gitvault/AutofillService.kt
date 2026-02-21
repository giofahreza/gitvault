package com.giofahreza.gitvault

import android.app.assist.AssistStructure
import android.os.CancellationSignal
import android.service.autofill.*
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.view.inputmethod.InlineSuggestionsRequest
import android.widget.RemoteViews
import android.content.IntentSender
import android.app.PendingIntent
import android.content.Intent
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.v1.InlineSuggestionUi
import io.flutter.plugin.common.MethodChannel
import android.os.Bundle
import android.text.TextUtils
import android.graphics.drawable.Icon
import android.graphics.BlendMode
import android.annotation.SuppressLint
import android.util.Log

class GitVaultAutofillService : AutofillService() {

    companion object {
        private const val TAG = "GitVaultAutofill"
        var methodChannel: MethodChannel? = null
    }

    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback
    ) {
        Log.d(TAG, "onFillRequest called")
        // Get the structure from the fill contexts
        val context = request.fillContexts
        val structure = context[context.size - 1].structure

        // Parse the structure to find autofillable fields
        val parsedStructure = parseStructure(structure)

        if (parsedStructure == null) {
            // No autofillable fields found
            Log.d(TAG, "No autofillable fields found")
            callback.onSuccess(null)
            return
        }

        Log.d(TAG, "Found autofillable fields - username: ${parsedStructure.usernameId != null}, password: ${parsedStructure.passwordId != null}")

        // Check if inline suggestions are requested (Android 11+)
        val inlineSuggestionsRequest = request.inlineSuggestionsRequest
        val supportsInline = inlineSuggestionsRequest != null
        Log.d(TAG, "Inline suggestions supported: $supportsInline")

        // Get package name and domain
        val packageName = structure.activityComponent?.packageName
        val webDomain = parsedStructure.webDomain
        Log.d(TAG, "Package: $packageName, Domain: $webDomain")

        // Create authentication intent to unlock vault if needed
        val authIntent = Intent(this, MainActivity::class.java).apply {
            putExtra("autofill_package", packageName)
            putExtra("autofill_domain", webDomain)
            putExtra("autofill_request", true)
            // Pass the autofill IDs so MainActivity can fill them after authentication
            putExtra("username_id", parsedStructure.usernameId)
            putExtra("password_id", parsedStructure.passwordId)
        }

        val authIntentSender: IntentSender = PendingIntent.getActivity(
            this,
            1001,
            authIntent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
        ).intentSender

        // Build the dataset requiring authentication (real credentials come from auth result)
        val datasetBuilder = Dataset.Builder()

        // Label: show domain or app name so user knows what they're filling
        val label = webDomain ?: packageName?.substringAfterLast('.') ?: "App"
        val presentation = RemoteViews(this.packageName, android.R.layout.simple_list_item_1).apply {
            setTextViewText(android.R.id.text1, "GitVault — $label")
        }

        if (supportsInline) {
            val inlinePresentation = createInlinePresentation("GitVault — $label", inlineSuggestionsRequest!!)
            if (inlinePresentation != null) {
                Log.d(TAG, "Using inline presentation with auth")
                if (parsedStructure.usernameId != null) {
                    datasetBuilder.setValue(
                        parsedStructure.usernameId, null, presentation, inlinePresentation
                    )
                }
                if (parsedStructure.passwordId != null) {
                    datasetBuilder.setValue(
                        parsedStructure.passwordId, null, presentation, inlinePresentation
                    )
                }
            } else {
                if (parsedStructure.usernameId != null) {
                    datasetBuilder.setValue(parsedStructure.usernameId, null, presentation)
                }
                if (parsedStructure.passwordId != null) {
                    datasetBuilder.setValue(parsedStructure.passwordId, null, presentation)
                }
            }
        } else {
            if (parsedStructure.usernameId != null) {
                datasetBuilder.setValue(parsedStructure.usernameId, null, presentation)
            }
            if (parsedStructure.passwordId != null) {
                datasetBuilder.setValue(parsedStructure.passwordId, null, presentation)
            }
        }

        // Require authentication — MainActivity will show AutofillSelectScreen
        datasetBuilder.setAuthentication(authIntentSender)

        // Build response with the dataset
        val responseBuilder = FillResponse.Builder()
            .addDataset(datasetBuilder.build())

        // Add save info if both username and password fields exist
        if (parsedStructure.usernameId != null && parsedStructure.passwordId != null) {
            val saveInfo = SaveInfo.Builder(
                SaveInfo.SAVE_DATA_TYPE_USERNAME or SaveInfo.SAVE_DATA_TYPE_PASSWORD,
                arrayOf(parsedStructure.usernameId, parsedStructure.passwordId)
            ).build()
            responseBuilder.setSaveInfo(saveInfo)
            Log.d(TAG, "SaveInfo added to response")
        }

        Log.d(TAG, "Returning fill response to system")
        callback.onSuccess(responseBuilder.build())
    }


    @SuppressLint("RestrictedApi")
    private fun createInlinePresentation(
        text: String,
        inlineSuggestionsRequest: InlineSuggestionsRequest
    ): InlinePresentation? {
        Log.d(TAG, "createInlinePresentation called")
        // Get the first presentation spec
        val spec = inlineSuggestionsRequest.inlinePresentationSpecs[0]

        // Check if the IME spec claims support for v1 UI template
        val imeStyle: Bundle = spec.style
        if (!UiVersions.getVersions(imeStyle).contains(UiVersions.INLINE_UI_VERSION_1)) {
            // IME doesn't support v1 inline UI, return null
            Log.d(TAG, "IME doesn't support v1 inline UI")
            return null
        }
        Log.d(TAG, "IME supports v1 inline UI")

        // Build the attribution PendingIntent (required by InlinePresentation API)
        // Use FLAG_MUTABLE on Android 12+ as recommended by working implementations
        val attributionIntent = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            val explicitIntent = Intent().apply {
                setPackage(packageName)
            }
            PendingIntent.getService(
                this,
                0,
                explicitIntent,
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )
        } else {
            PendingIntent.getService(
                this,
                0,
                Intent(),
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        // Build the inline suggestion UI using androidx.autofill library
        val builder = InlineSuggestionUi.newContentBuilder(attributionIntent)

        // Set title if not empty
        if (text.isNotEmpty()) {
            builder.setTitle(text)
        }

        // Set subtitle
        builder.setSubtitle("GitVault — Tap to fill")

        // Set content description for accessibility
        builder.setContentDescription("GitVault - Password Manager")

        // Set icon (use Android's built-in lock icon)
        val icon = Icon.createWithResource(this, android.R.drawable.ic_lock_lock)
        builder.setStartIcon(icon)

        // Build the slice
        val slice = builder.build().slice

        Log.d(TAG, "InlinePresentation created successfully")
        return InlinePresentation(slice, spec, /* pinned= */ false)
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        // Get the structure from the fill contexts
        val context = request.fillContexts
        val structure = context[context.size - 1].structure

        // Parse the structure to extract username/password
        val parsedStructure = parseStructure(structure)

        if (parsedStructure != null) {
            val username = parsedStructure.username
            val password = parsedStructure.password
            val domain = parsedStructure.webDomain ?: structure.activityComponent.packageName

            // Send to Flutter to save
            methodChannel?.invokeMethod("saveCredentials", mapOf(
                "domain" to domain,
                "username" to username,
                "password" to password
            ))
        }

        callback.onSuccess()
    }

    private fun parseStructure(structure: AssistStructure): ParsedStructure? {
        var usernameId: AutofillId? = null
        var passwordId: AutofillId? = null
        var username: String? = null
        var password: String? = null
        var webDomain: String? = null

        // Traverse the view hierarchy
        for (i in 0 until structure.windowNodeCount) {
            val windowNode = structure.getWindowNodeAt(i)
            webDomain = windowNode.rootViewNode.webDomain ?: webDomain

            traverseNode(windowNode.rootViewNode) { viewNode ->
                val autofillHints = viewNode.autofillHints
                val autofillType = viewNode.autofillType

                if (autofillHints != null && autofillType == View.AUTOFILL_TYPE_TEXT) {
                    for (hint in autofillHints) {
                        if (hint == null) continue
                        when {
                            hint.contains("username", ignoreCase = true) ||
                            hint.contains("email", ignoreCase = true) -> {
                                usernameId = viewNode.autofillId
                                username = viewNode.autofillValue?.textValue?.toString()
                            }
                            hint.contains("password", ignoreCase = true) -> {
                                passwordId = viewNode.autofillId
                                password = viewNode.autofillValue?.textValue?.toString()
                            }
                        }
                    }
                }

                // Fallback: use heuristics if no hints
                if (autofillHints == null || autofillHints.isEmpty()) {
                    val hint = viewNode.hint?.lowercase() ?: ""
                    val text = viewNode.text?.toString()?.lowercase() ?: ""
                    val idEntry = viewNode.idEntry?.lowercase() ?: ""

                    // inputType-based detection as additional signal
                    val inputType = viewNode.inputType
                    val typeClass = inputType and android.text.InputType.TYPE_MASK_CLASS
                    val typeVariation = inputType and android.text.InputType.TYPE_MASK_VARIATION
                    val isTextClass = typeClass == android.text.InputType.TYPE_CLASS_TEXT
                    val isPasswordInputType = isTextClass && (
                        typeVariation == android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                        typeVariation == android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                        typeVariation == android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                    )
                    val isEmailInputType = isTextClass && (
                        typeVariation == android.text.InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
                        typeVariation == android.text.InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS
                    )

                    when {
                        (hint.contains("user") || hint.contains("email") ||
                         text.contains("user") || text.contains("email") ||
                         idEntry.contains("user") || idEntry.contains("email") ||
                         isEmailInputType) &&
                        autofillType == View.AUTOFILL_TYPE_TEXT -> {
                            if (usernameId == null) {
                                usernameId = viewNode.autofillId
                                username = viewNode.autofillValue?.textValue?.toString()
                            }
                        }
                        (hint.contains("pass") || text.contains("pass") || idEntry.contains("pass") ||
                         isPasswordInputType) &&
                        autofillType == View.AUTOFILL_TYPE_TEXT -> {
                            if (passwordId == null) {
                                passwordId = viewNode.autofillId
                                password = viewNode.autofillValue?.textValue?.toString()
                            }
                        }
                    }
                }
            }
        }

        return if (usernameId != null || passwordId != null) {
            ParsedStructure(usernameId, passwordId, username, password, webDomain)
        } else {
            null
        }
    }

    private fun traverseNode(node: AssistStructure.ViewNode?, action: (AssistStructure.ViewNode) -> Unit) {
        if (node == null) return
        action(node)
        for (i in 0 until node.childCount) {
            traverseNode(node.getChildAt(i), action)
        }
    }

    data class ParsedStructure(
        val usernameId: AutofillId?,
        val passwordId: AutofillId?,
        val username: String?,
        val password: String?,
        val webDomain: String?
    ) {
        fun allAutofillIds(): Array<AutofillId> {
            return listOfNotNull(usernameId, passwordId).toTypedArray()
        }
    }
}
