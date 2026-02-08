# GitVault

A secure password manager with GitHub-backed encrypted storage and Android autofill support.

## Features

- 🔐 **End-to-end encryption** - Your passwords are encrypted locally before syncing
- 🔄 **GitHub sync** - Store encrypted vault in private GitHub repository
- 🔋 **Background sync** - Battery-optimized automatic sync in background
- ⚡ **Adaptive intervals** - Smart sync frequency based on battery and connectivity
- 📱 **Android autofill** - System-wide password autofill (Android 8.0+)
- ⌨️ **Inline keyboard suggestions** - Autofill suggestions appear in your keyboard (Android 11+)
- 👆 **Biometric authentication** - Unlock with fingerprint
- 🔗 **Device linking** - Link multiple devices via QR code
- 🚨 **Duress mode** - Emergency wipe with duress PIN
- 🖥️ **Termux-like SSH** - Persistent background SSH sessions with notifications
- ⌨️ **Advanced terminal** - Gestures, volume keys, enhanced keyboard toolbar
- 📡 **Multiple SSH sessions** - Concurrent sessions with session manager

## Installation

1. Download `gitvault.apk` from releases
2. Install on your Android device
3. Follow setup instructions below

## Setup Instructions

### 1. Initial Setup

1. Open GitVault app
2. Create a master password (this encrypts your vault)
3. Set up biometric authentication (optional but recommended)

### 2. GitHub Sync Setup

GitVault stores your encrypted vault in a private GitHub repository.

#### Create GitHub Personal Access Token (PAT):

1. Go to [GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens](https://github.com/settings/personal-access-tokens/new)
2. Click **Generate new token**
3. Configure token:
   - **Token name**: `GitVault`
   - **Expiration**: Custom (or your preference)
   - **Repository access**: Only select repositories → Choose your vault repo
   - **Permissions**:
     - Contents: **Read and write**
     - Metadata: **Read** (required, auto-selected)
4. Click **Generate token**
5. **Copy the token immediately** (you won't see it again!)

#### Configure in GitVault:

1. Open GitVault → Settings → GitHub Sync
2. Enter your GitHub username (e.g., `giofahreza`)
3. Enter repository name (e.g., `qweasdzcx`)
4. Paste your Personal Access Token
5. Tap **Save**

**Important**: GitVault uses fine-grained PATs with Bearer authentication, not classic tokens.

### 3. Enable Autofill on Android

To use GitVault for autofill in apps and browsers:

#### Samsung Devices (Galaxy S25, etc.):

```
Settings → General Management → Passwords, Passkeys, and Autofill
→ Tap cog wheel beside "Preferred Service"
→ Look for "GitVault" in the list
→ Select GitVault
```

#### Other Android Devices:

```
Settings → System → Languages & input → Autofill service
→ Select "GitVault"
```

Or:

```
Settings → Security and Privacy → More Security Settings
→ Autofill service from Google
→ Select "GitVault"
```

#### Verify Autofill is Enabled:

1. Open Chrome browser
2. Go to any login page (e.g., accounts.google.com)
3. Tap the username/email field
4. You should see "GitVault" in the autofill dropdown or keyboard suggestions

### 4. Using Autofill

#### How it Works:

1. **Tap a login field** in any app or browser
2. **See GitVault suggestion**:
   - **Android 11+**: Suggestion appears in keyboard (inline)
   - **Android 8-10**: Dropdown above the field
3. **Tap GitVault** → App opens
4. **Authenticate** with biometric/PIN
5. **Select account** from your vault
6. **Auto-fills** username and password

#### Saving New Passwords:

When you enter credentials in an app/website, GitVault will prompt to save them automatically.

## Important Notes

### Samsung Devices Known Issues

**Samsung S25 / One UI 7 / Android 15:**

Samsung has a known bug affecting third-party autofill services:
- Samsung Internet browser may ONLY support Samsung Pass
- Third-party autofill services may not appear in settings
- Settings may not save properly

**Workaround**:
- Use **Google Chrome** instead of Samsung Internet browser
- Check Samsung Community for updates: [One UI 7 autofill issue](https://eu.community.samsung.com/t5/galaxy-s25-series/one-ui-7-android-autofill-password-managers-not-recognising-they/td-p/11632374)

### Inline Keyboard Suggestions

For autofill to appear **inside your keyboard** (not just dropdown):

**Requirements:**
- ✅ Android 11 or higher
- ✅ Compatible keyboard (Gboard, Samsung Keyboard, SwiftKey)
- ✅ Keyboard must support inline suggestions

**Recommended Keyboard:**
Install **Gboard** from Play Store for best inline autofill experience.

If inline suggestions don't appear, GitVault will fall back to dropdown autofill (still works perfectly).

## Security Features

### Encryption

- **Master password**: Encrypts your entire vault locally
- **AES-256 encryption**: Industry-standard encryption
- **Key derivation**: PBKDF2 with high iteration count
- All encryption happens on-device before syncing to GitHub

### Duress Mode

Create a duress PIN that wipes your vault in emergency situations:

```
Settings → Security → Duress PIN
```

When you enter the duress PIN instead of your master password, GitVault will:
1. Immediately wipe all local data
2. Lock the app
3. Appear as if the PIN was incorrect

### Device Linking

Link multiple devices securely:

1. **Primary device**: Settings → Link Device → Show QR Code
2. **New device**: Scan QR code during setup
3. Vault is securely transferred with end-to-end encryption

## Troubleshooting

### Autofill Not Showing

1. **Check if GitVault is enabled** in Settings → Autofill service
2. **Try different browser**: Use Chrome instead of Samsung Internet
3. **Check Android version**: Autofill requires Android 8.0+
4. **Reinstall app**: Uninstall and reinstall GitVault
5. **Check keyboard**: For inline suggestions, use Gboard

### Sync Issues

**"Repository not found" error:**
- Verify repository name is correct (no typos)
- Check PAT has **Contents: Read and write** permission
- Make sure repository exists and is private
- Token must be a **fine-grained** token, not classic

**"Repository empty" error:**
- This is normal for new repositories
- GitVault will create initial sync on first save

**"Can't access repository" error:**
- Check internet connection
- Verify PAT hasn't expired
- Regenerate token if needed

### Biometric Authentication Issues

If fingerprint doesn't work:
1. Go to Settings → Security → Biometric Authentication
2. Toggle off and on
3. Re-test fingerprint
4. Check Android Settings → Biometrics → Fingerprint is registered

### Background Sync

GitVault now supports automatic background sync with intelligent battery optimization:

**Features:**
- Automatic periodic sync with GitHub
- Battery-aware sync intervals (adapts to battery level)
- WiFi-only sync option (save cellular data)
- Sync only when charging option (maximum battery conservation)
- Real-time sync statistics and monitoring

**Configuration:**
1. Go to Settings → Background Sync
2. Enable background sync
3. Choose sync interval (15-360 minutes)
4. Optional: Enable "WiFi Only" or "Charging Only"

**How it works:**
- Syncs automatically in background even when app is closed
- Adjusts frequency based on battery (e.g., less frequent on low battery)
- Uses exponential backoff on failures to save battery
- Shows last sync time and status in settings

For detailed information, see [Background Sync Guide](BACKGROUND_SYNC_GUIDE.md).

### SSH Terminal (Termux-Like Features)

GitVault includes a professional SSH terminal with Termux-inspired features:

**Features:**
- Persistent background sessions (survive app closure)
- Notification-based session access
- Multiple concurrent SSH sessions
- Wake locks to keep connections alive
- Gestures (double tap, long press, pinch zoom)
- Volume key bindings (Ctrl+C, Ctrl+D)
- Enhanced keyboard toolbar
- Session manager
- Copy/paste support

**Usage:**
1. Go to SSH → Add credential
2. Connect → Choose "Persistent Session"
3. Session runs in background with notification
4. Tap notification to return to session
5. Manage sessions from Sessions screen

**Termux-Like Gestures:**
- **Double Tap**: Toggle keyboard toolbar
- **Long Press**: Context menu
- **Pinch Zoom**: Adjust font size
- **Volume Down**: Ctrl+C (interrupt)
- **Volume Up**: Ctrl+D (end input)

**Session Management:**
- Multiple sessions supported
- Sessions persist across app restarts
- Tap notification to switch sessions
- Close individual or all sessions

For detailed information, see [SSH Termux Features](SSH_TERMUX_FEATURES.md).

## File Structure

```
.
├── android/                    # Android native code
│   └── app/src/main/kotlin/
│       └── com/example/gitvault/
│           ├── MainActivity.kt          # Flutter activity + autofill handling
│           └── AutofillService.kt       # Android autofill service
├── lib/                        # Flutter/Dart code
│   ├── core/
│   │   ├── auth/              # Authentication & biometric
│   │   ├── crypto/            # Encryption & key management
│   │   └── services/          # GitHub API service
│   ├── data/
│   │   └── repositories/      # Sync engine & vault storage
│   └── features/
│       ├── vault/             # Main vault screen
│       ├── settings/          # Settings screen
│       ├── onboarding/        # Initial setup
│       └── device_linking/    # QR code device linking
└── README.md                   # This file
```

## Technical Details

### Autofill Implementation

- **Service**: `GitVaultAutofillService` extends Android `AutofillService`
- **Inline suggestions**: Uses `androidx.autofill:autofill:1.3.0` library
- **UI Version support**: Checks `UiVersions.INLINE_UI_VERSION_1`
- **Fallback**: Automatic fallback to dropdown if keyboard doesn't support inline

### GitHub Sync

- **Authentication**: Bearer token (fine-grained PAT)
- **API**: GitHub REST API v3
- **Storage**: Encrypted JSON blob in repository
- **Conflict resolution**: Last-write-wins strategy

## Building from Source

### Prerequisites

- Flutter SDK (latest stable)
- Android SDK (API 23+)
- Kotlin 1.9+
- Gradle 8.14+

### Build Steps

```bash
# Clone repository
git clone https://github.com/giofahreza/gitvault
cd gitvault

# Get dependencies
flutter pub get

# Build release APK
cd android
./gradlew assembleRelease

# APK location:
# build/app/outputs/flutter-apk/app-release.apk
```

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly (especially autofill functionality)
5. Submit a pull request

## License

[Add your license here]

## Support

For issues, questions, or feature requests:
- Create an issue on GitHub
- Check troubleshooting section above
- Review Samsung-specific known issues

## Credits

GitVault uses the following open-source projects:
- Flutter
- github package for Dart
- local_auth for biometric authentication
- flutter_secure_storage for secure key storage
- mobile_scanner for QR code scanning
- androidx.autofill for inline keyboard suggestions

Autofill implementation inspired by:
- [KeeVault flutter_autofill_service](https://github.com/kee-org/flutter_autofill_service)
- [Bitwarden mobile](https://github.com/bitwarden/mobile)
- [Android AutofillFramework samples](https://github.com/android/input-samples)
