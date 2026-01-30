# GitVault

A sovereign, device-centric password manager and 2FA authenticator using GitHub as storage backend.

## Features

- **Zero-Knowledge Architecture**: All encryption happens on-device
- **Hardware-Backed Security**: Keys stored in Secure Enclave/KeyStore
- **Biometric Authentication**: Fingerprint/Face ID instead of master passwords
- **GitHub Storage**: Your private repo as encrypted backup
- **Cross-Device Sync**: Secure device linking via blind handshake
- **Integrated 2FA**: Built-in TOTP authenticator
- **System Autofill**: Native credential provider integration

## Security Model

- XChaCha20-Poly1305 authenticated encryption
- 256-bit keys in hardware security modules
- Deterministic filename obfuscation via HMAC-SHA256
- Traffic analysis protection through padding
- Anti-rollback protection

## Development Phases

1. ✅ Crypto Engine - Core encryption/decryption
2. 🔄 Local Vault - Biometric-protected local storage
3. ⏳ GitHub Sync - Remote backup and sync
4. ⏳ Device Linking - Multi-device support
5. ⏳ Hardening - Autofill, duress mode, audit logs

## Getting Started

```bash
# Install dependencies
flutter pub get

# Run tests
flutter test

# Run app
flutter run
```

## Project Structure

```
lib/
├── core/           # Core security and crypto
├── data/           # Models and repositories
├── features/       # UI screens
└── utils/          # Constants and helpers
```
