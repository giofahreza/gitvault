package com.giofahreza.gitvault.ime

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
            titleView.text = credential.title
            urlView.text = credential.url ?: "(no URL)"

            usernameBtn.setOnClickListener {
                onFillUsername(credential.uuid)
            }

            passwordBtn.setOnClickListener {
                onFillPassword(credential.uuid)
            }
        }
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): CredentialViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.ime_credential_item, parent, false)
        return CredentialViewHolder(view)
    }

    override fun onBindViewHolder(holder: CredentialViewHolder, position: Int) {
        holder.bind(credentials[position])
    }

    override fun getItemCount(): Int = credentials.size
}
