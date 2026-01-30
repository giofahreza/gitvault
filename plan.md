GitVault: Master Design Document

1. Executive Summary

GitVault is a sovereign, high-security note taking app, password manager and 2FA authenticator built on a "Bring Your Own Storage" (BYOS) model. It utilizes a private GitHub repository as a "dumb" file server, ensuring the user retains absolute control over their data.

The system operates on a Device-Centric Security Model, eliminating the traditional "Master Password" in favor of 256-bit cryptographic keys stored in the device's hardware (Secure Enclave/Keystore), protected by biometric authentication.

2. Core Functional Requirements

A. System-Integrated Autofill

The app serves as a native Credential Provider for the operating system, allowing it to inject passwords directly into other apps and websites.

Android: Implements the AutofillService API. Appears as a keyboard suggestion or dropdown in login fields (e.g., Chrome, Instagram).

iOS: Implements AuthenticationServices for native iOS AutoFill.

Desktop: Implements global hotkeys and clipboard integration.

B. Integrated 2FA Authenticator (TOTP)

Replaces Google Authenticator by generating Time-based One-Time Passwords directly within the app.

Unified Storage: TOTP "Secret Keys" are stored alongside passwords in the encrypted vault.

Cross-Device Sync: 2FA codes are available on all linked devices (Phone + PC).

Auto-Copy: When autofilling a password, the valid 2FA code is automatically copied to the clipboard.

3. Security Architecture

A. The "Oblivious Storage" Model

To an outside observer (including GitHub), the repository appears as a flat list of random, equal-sized binary files.

Component

What User Sees

What GitHub Sees

Filename

Google Login

data/8f3a29bc10...3d.bin (HMAC-SHA256 Hash)

Content

Username: me@gmail.com

[Random Noise - 4096 bytes]

Structure

Organized Folders

Flat list of unrelated files

B. Level 2 "Paranoid" Defenses

Traffic Obfuscation (Padding): Every encrypted file is padded with random noise to the nearest 4KB block. This prevents traffic analysis (guessing content based on file size).

Metadata Obfuscation: Filenames are deterministic hashes (HMAC(RootKey, UUID)). No semantic data leaks.

Anti-Rollback: The index.bin file contains a monotonic counter. The app rejects server states with lower counters than the local device.

Duress Mode: A specific "Panic PIN" that, when entered, either wipes the encryption keys or unlocks a decoy vault.

App Hardening: Clipboard auto-clearing (30s timer) and FLAG_SECURE implementation to prevent OS screenshots.

Audit Logging: An encrypted, append-only log of all access events is maintained to detect unauthorized usage if a device is compromised.

C. Device Linking: The "Blind Handshake"

New devices are authorized via a "Split-Channel" mechanism to prevent shoulder surfing and interception.

Channel 1 (QR Code): Contains the Encrypted Root Key + GitHub Credentials.

Channel 2 (Visual): A 6-digit Ephemeral PIN displayed on the source screen.

Process: The new device scans the QR but cannot decrypt it without the user manually typing the PIN.

Validation (Proof of Possession): The new device immediately generates a TOTP code using the shared secret and sends it back to the original device. The original device adds the new device's Public Identity Key to trusted_devices.bin only upon validation.

D. Recovery Protocol (The "Paper Key")

Since there is no Master Password, losing all devices results in permanent data loss.

Requirement: During setup, the user must print or write down a Recovery Kit.

Content: A PDF containing the raw Root Key (in Hex or QR format) and the GitHub Personal Access Token.

Usage: Used to restore access on a fresh device if biometric hardware is lost or broken.

4. Data Structure & Cryptography

A. Algorithms

Encryption: XChaCha20-Poly1305 (Authenticated Encryption).

Key Derivation: Argon2id.

Hashing: HMAC-SHA256 (for filename obfuscation).

B. The Encrypted File Format (.bin)

Every file on GitHub follows this exact byte-structure:

Layer

Component

Size

Description

1. Envelope

Nonce (IV)

24 Bytes

Random initialization vector.



MAC (Tag)

16 Bytes

Poly1305 signature to detect tampering.



Ciphertext

~4056 Bytes

The encrypted payload.

2. Payload

Data Length

4 Bytes

Integer indicating real data size.

(Inside Ciphertext)

Real Data

Variable

The UTF-8 JSON string.



Padding

Variable

Random garbage bytes to fill block.

C. Repository Files

data/{hash}.bin: Individual encrypted password entries.

index.bin: Encrypted index containing UUID-to-Hash mappings and monotonic counters.

trusted_devices.bin: Encrypted JSON list of authorized device Public Keys (for signature verification).

D. Conflict Resolution Strategy

Primary: "Smart Sync" via index.bin timestamps.

Resolution: Last Write Wins (LWW).

Since entry files are isolated (UUID-based), conflicts only occur if the exact same password is edited on two devices simultaneously.

The app compares the modified_at timestamp in the decrypted JSON. The later timestamp overwrites the earlier one.

5. Project Structure (Flutter)

lib/
├── main.dart                  # App Entry Point
├── core/
│   ├── crypto/
│   │   ├── crypto_manager.dart    # CORE: XChaCha20, Padding, HMAC logic
│   │   ├── key_storage.dart       # Secure Storage (Hardware) wrapper
│   │   └── blind_handshake.dart   # Logic for PIN-protected QR generation
│   ├── auth/
│   │   ├── biometric_auth.dart    # Local Auth (Fingerprint/Face)
│   │   └── duress_manager.dart    # Logic to handle Panic PINs
│   └── services/
│       ├── github_service.dart    # GitHub API (GET/PUT/DELETE)
│       └── autofill_service.dart  # Native OS Autofill integration
├── data/
│   ├── models/
│   │   ├── vault_entry.dart       # Model: {uuid, user, pass, totp_secret}
│   │   ├── sync_index.dart        # Model: {last_updated, monotonic_counter}
│   │   └── device_registry.dart   # Model: List of trusted public keys
│   └── repositories/
│       ├── vault_repository.dart  # Orchestrates Encryption <-> Storage
│       └── sync_engine.dart       # "Smart Sync" (Diffing logic)
├── features/
│   ├── onboarding/              # Setup & Recovery Kit generation
│   ├── vault/                   # Main UI (Decrypted in-memory only)
│   ├── device_linking/          # QR Scanner & TOTP Validation UI
│   └── settings/                # Security controls
└── utils/
    └── constants.dart           # Constants (e.g., BlockSize = 4096)


6. Dependencies (pubspec.yaml)

name: gitvault
description: A sovereign, device-centric password manager using GitHub.
version: 1.0.0+1
publish_to: 'none'

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter

  # --- CORE SECURITY ---
  # The heavy lifter for XChaCha20-Poly1305 and Argon2id
  cryptography: ^2.5.0

  # To store the Root Key securely in hardware (KeyStore/Keychain)
  flutter_secure_storage: ^9.0.0
  # OR biometric_storage for stricter hardware enforcement
  biometric_storage: ^5.0.0

  # To auth user before releasing keys
  local_auth: ^2.1.6

  # --- BACKEND & DATA ---
  # To talk to GitHub API
  github: ^9.24.0
  http: ^1.1.0

  # Local Database (Fast, encrypted NoSQL)
  hive: ^2.2.3
  hive_flutter: ^1.1.0

  # --- DEVICE FEATURES ---
  # For the "Blind Handshake" (Scanning QRs)
  mobile_scanner: ^3.5.0
  # For displaying the QR code
  qr_flutter: ^4.1.0
  # For 2FA/TOTP generation
  otp: ^3.1.0
  # For Native Autofill Support
  flutter_autofill_service: ^1.0.0 
  # For Unique ID generation
  uuid: ^4.0.0

  # --- STATE MANAGEMENT ---
  flutter_riverpod: ^2.4.9
  freezed_annotation: ^2.4.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  build_runner: ^2.4.6
  freezed: ^2.4.5
  hive_generator: ^2.0.1


7. Implementation Roadmap

Phase 1: The "Crypto Engine"

Implement CryptoManager.

Deliverable: Unit tests proving data can be Encrypted -> Padded -> Decrypted -> Unpadded correctly.

Phase 2: Local Vault & Biometrics

Implement KeyStorage and BiometricAuth.

Build the VaultRepository connected to Hive.

Deliverable: A local-only app that saves passwords securely.

Phase 3: GitHub Sync

Implement GitHubService and SyncEngine.

Deliverable: App syncs data to a private repo. User sees .bin files appear on GitHub.

Phase 4: Device Linking

Implement the "Blind Handshake" (QR + PIN).

Implement TOTP validation loop.

Deliverable: Ability to scan a QR on Device A and see data appear on Device B.

Phase 5: Hardening

Add flutter_autofill_service for OS integration.

Implement Duress PIN, Clipboard Timer, and FLAG_SECURE.

8. The "Splitting" & Saving Logic (Code Snippet)

This is the logic you will implement in vault_repository.dart to ensure data is split and obfuscated.

// Pseudo-code for saving an entry
Future<void> saveEntry(VaultEntry entry) async {
  // 1. Get Root Key (Unlock Secure Storage)
  final rootKey = await _keyStorage.getRootKey();

  // 2. Generate Obfuscated Filename
  // We use HMAC so it is deterministic (we can find it again) but random-looking
  final filenameHash = await _crypto.hmacSha256(
    key: rootKey,
    data: entry.uuid
  );
  final filename = "data/$filenameHash.bin";

  // 3. Serialize & Pad
  final jsonString = entry.toJsonString();
  final paddedBytes = _paddingUtils.addRandomPadding(
    utf8.encode(jsonString),
    blockSize: 4096 // Pad to nearest 4KB
  );

  // 4. Encrypt
  final encryptedBox = await _crypto.encryptXChaCha20(
    data: paddedBytes,
    key: rootKey
  );

  // 5. Upload to GitHub
  await _githubService.uploadFile(
    path: filename,
    content: encryptedBox.toBytes(),
    commitMessage: "Update entry" // Generic message
  );
}

