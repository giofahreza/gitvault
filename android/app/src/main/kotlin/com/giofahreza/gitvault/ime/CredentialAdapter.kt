package com.giofahreza.gitvault.ime

import android.util.Log
import android.view.LayoutInflater
import android.view.ViewGroup
import android.widget.ImageButton
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.giofahreza.gitvault.R

/**
 * RecyclerView adapter for IME credential list.
 * Shows only titles and URLs (no passwords visible in toolbar).
 * Tap username/password icon to fill that field.
 */
class CredentialAdapter(
    private val credentials: List<CredentialMetadata>,
    private val onFillUsername: (uuid: String) -> Unit,
    private val onFillPassword: (uuid: String) -> Unit
) : RecyclerView.Adapter<CredentialAdapter.CredentialViewHolder>() {

    inner class CredentialViewHolder(itemView: android.view.View) :
        RecyclerView.ViewHolder(itemView) {
        private val titleView: TextView = itemView.findViewById(R.id.credential_title)
        private val urlView: TextView = itemView.findViewById(R.id.credential_url)
        private val usernameBtn: ImageButton =
            itemView.findViewById(R.id.credential_username_btn)
        private val passwordBtn: ImageButton =
            itemView.findViewById(R.id.credential_password_btn)

        fun bind(credential: CredentialMetadata) {
            Log.d("CredentialAdapter", "bind() called for: ${credential.title}")
            titleView.text = credential.title
            urlView.text = credential.url ?: "(no URL)"

            Log.d("CredentialAdapter", "Setting click listeners, usernameBtn=$usernameBtn, passwordBtn=$passwordBtn")
            Log.d("CredentialAdapter", "Username button: clickable=${usernameBtn.isClickable}, focusable=${usernameBtn.isFocusable}, enabled=${usernameBtn.isEnabled}")
            Log.d("CredentialAdapter", "Password button: clickable=${passwordBtn.isClickable}, focusable=${passwordBtn.isFocusable}, enabled=${passwordBtn.isEnabled}")

            // Add touch listeners to debug
            usernameBtn.setOnTouchListener { v, event ->
                Log.d("CredentialAdapter", "Username button TOUCH event: ${event.action}")
                false // Don't consume
            }

            passwordBtn.setOnTouchListener { v, event ->
                Log.d("CredentialAdapter", "Password button TOUCH event: ${event.action}")
                false // Don't consume
            }

            usernameBtn.setOnClickListener {
                Log.d("CredentialAdapter", "Username button CLICKED for: ${credential.title}")
                onFillUsername(credential.uuid)
            }

            passwordBtn.setOnClickListener {
                Log.d("CredentialAdapter", "Password button CLICKED for: ${credential.title}")
                onFillPassword(credential.uuid)
            }

            Log.d("CredentialAdapter", "Click listeners set successfully")
        }
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): CredentialViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.ime_credential_item, parent, false)
        Log.d("CredentialAdapter", "onCreateViewHolder called")
        return CredentialViewHolder(view)
    }

    override fun onBindViewHolder(holder: CredentialViewHolder, position: Int) {
        Log.d("CredentialAdapter", "onBindViewHolder called for position $position")
        holder.bind(credentials[position])
    }

    override fun getItemCount(): Int = credentials.size
}
