# GitVault User Guide

This is the detailed user guide for GitVault. The root [README](../README.md) is the showcase overview; this guide keeps the setup, sync, device, recovery, and troubleshooting reference in one place.

GitVault is an open source password manager that encrypts passwords, private notes, TOTP secrets, and SSH credentials on device before syncing ciphertext to your own private GitHub repository.

## Platform Support

Core vault features work on the web app, Android APK, and Desktop:

| Feature | Web | Android | Desktop | Notes |
|---|---|---|---|---|
| Passwords, notes, 2FA codes, SSH credential storage | Yes | Yes | Yes | Synced as encrypted vault data |
| Keyboard PIN entry | Yes | On-screen keypad | Yes | PIN remains the backup unlock method |
| Biometric unlock | Browser-dependent | Device-dependent | OS-dependent | Availability depends on platform support |
| System autofill | No | Yes | No | Requires selecting GitVault as Android autofill provider |
| GitVault Keyboard | No | Yes | No | Fallback when Android autofill does not appear |
| AI Apps / MCP | No | No | Yes | Local, notes-only access while Desktop is running |
| Recent-app privacy | Browser-managed | Yes | OS-managed | Android uses secure window flags |

## Quick Start

1. Open the web app at `https://gitvault.giofahreza.com/app/` or install the latest Android APK from GitHub Releases.
2. Create a new vault.
3. Save the recovery phrase outside GitVault.
4. Create a 4-6 digit PIN. On web, the PIN can be entered with the keyboard.
5. Add your first password, note, 2FA code, or SSH credential.
6. Connect GitHub Sync if you want encrypted backup or multi-device use.

Do not skip recovery phrase storage. GitVault cannot decrypt the vault for you if every trusted device and the recovery phrase are lost.

## GitHub Sync

GitHub is used only as encrypted storage. GitVault encrypts the vault locally, then writes ciphertext files to your private repository.

1. Create an empty private repository in your GitHub account.
2. Create a fine-grained personal access token for only that repository.
3. Grant Metadata read and Contents read/write permissions.
4. Paste the GitHub username, repository name, and token into GitVault Settings.
5. Run the first sync and wait for success.

Use fine-grained tokens scoped to one repository. Classic tokens are broader than GitVault needs.

## Sync Behavior

GitVault is local-first. It can sync encrypted vault data, trusted-device records, and recovery coordination data through GitHub when sync is enabled.

- Manual sync runs when you trigger it from Settings.
- Auto-sync periodically checks for local and remote changes at the configured interval.
- Device trust checks can run when the app opens so removed devices clear local sync access quickly.
- Conflicts use smart sync with last-write-wins behavior. Avoid editing the same item offline on two devices before either device syncs.
- Deletes use tombstones so deleted items do not reappear from older local copies.

## Unlock And Lock

### PIN

Use the PIN when GitVault asks for authentication. Wrong attempts can trigger throttling, so wait for the timer before retrying.

### Biometric Unlock

Enable biometric unlock from an already-unlocked vault. Use it only on devices or browsers you personally control.

### Authentication Interval

The authentication interval setting controls when GitVault asks again after opening or returning to the app. Use a shorter interval on shared machines.

### Manual Lock

Use the lock button before stepping away from an unlocked vault.

## Passwords

1. Open Passwords.
2. Select add.
3. Fill title, username, password, URL, and notes.
4. Choose an existing group from the dropdown, or create a new group in the same control.
5. Add a TOTP secret when the login has 2FA and you want the code inside the password record.
6. Save and wait for sync if you use multiple devices.

Use copy actions for username, password, and TOTP codes. Enable clipboard auto-clear for shared or work devices.

## Notes

Notes can store private text, checklists, recovery codes, secure references, and short private documents.

Use pinning for high-priority notes, colors and tags for organization, archive for old notes, and search for quick lookup. Mobile uses a single-column notes list for readability.

## Desktop AI Apps And MCP

GitVault Desktop for Windows, macOS, and Linux can host a local MCP service for
applications that support MCP over stdio or Streamable HTTP. The web and
Android apps do not host this service.

1. Open and unlock GitVault Desktop.
2. Open Settings, then **AI Apps**.
3. Enable **Allow AI apps**.
4. Select **Connect AI App** and enter a recognizable name.
5. Choose stdio when the target app launches MCP commands, or Streamable HTTP
   when it accepts a local URL and request headers.
6. Grant only the note permissions and tag scope that app needs.
7. Copy the generated configuration into the target app.

GitVault creates connections only after this direct action in the unlocked
Desktop UI. The local service does not accept unsolicited pairing requests
from other applications.

Each app has a separate credential. HTTP credentials are displayed only once;
stdio profiles are stored in the current user's protected configuration
directory.

Available permissions cover note metadata, content, search, create, append,
edit, archive, delete, and archived-note visibility. An allowed-tag list limits
access to notes containing at least one listed tag. Denied tags always take
priority. An empty allowed-tag list means all notes except denied or archived
notes.

Search checks note bodies only when the app also has **Read note content**.
Without that permission, search is limited to titles and tags and returns no
content snippets.

Writes ask for approval by default. The Desktop dialog shows the application,
operation, note, and before/after content. Approvals expire after 60 seconds.
Delete always requires approval. If a note changes while approval is pending,
GitVault returns a conflict instead of overwriting the newer edit.

Locking GitVault immediately blocks note operations. Rotating a credential,
changing permissions, revoking an app, or removing it invalidates active
sessions. Quit GitVault to stop the MCP service; closing to the tray keeps it
running when that option is enabled.

MCP is notes-only. It has no path to passwords, TOTP secrets or codes, SSH
credentials, GitHub tokens, root keys, PIN data, recovery phrases, or
device-linking secrets. The operating-system user is the local trust boundary:
another process already running as the same compromised OS user may be able to
impersonate a local AI app.

## 2FA Codes

1. Open 2FA Codes.
2. Add issuer and account name.
3. Paste the TOTP secret.
4. Choose or create a group.
5. Save and verify the live code and countdown.

If a code is nearly expired, wait for the next code before copying it into a login form.

### TOTP Import

GitVault can accept manual TOTP secrets and `otpauth://totp/` links. QR scanning depends on camera and platform support.

1. Copy the manual secret or otpauth link from the service you are protecting.
2. Open GitVault 2FA Codes.
3. Paste the secret or link into the TOTP field.
4. Review issuer and account.
5. Save and verify the GitVault code with the service before deleting the old authenticator entry.

## SSH Credentials

SSH entries store host credentials in the encrypted vault. Android builds can also open terminal workflows where supported.

1. Open SSH.
2. Add title, host, username, and port.
3. Add password or private-key information.
4. Test the entry before relying on it.
5. Lock GitVault when finished.

## Connected Devices

### Link A New Device

Use this when you still have a trusted device.

1. Open Settings on the trusted device.
2. Select Link New Device.
3. Show the QR code or copy the transfer code.
4. Open GitVault on the new device from onboarding or Link New Device.
5. Scan or paste the invite.
6. Enter the short PIN shown by the trusted device.
7. Name the new device.

The new device is trusted only after it consumes the invite successfully.

### Device Alerts

If a device appears without the Link New Device flow, GitVault warns trusted devices. Choose "I recognize this device" only when the device and timing match your own action. If the alert is unexpected, remove the device and rotate the GitHub token.

### Remove A Device

1. Open Settings, then Connected Devices.
2. Remove the device you no longer trust.
3. Let the change sync.

When the removed device opens or checks device trust, it clears local sync access and must link again or restore with valid recovery credentials.

## Recovery

### Restore With Another Trusted Device

1. Open GitVault on the new device.
2. Choose restore from onboarding or the existing-vault flow.
3. Connect the existing GitHub repository and current token.
4. Enter the recovery phrase.
5. Approve the recovery request from another trusted device.
6. Return to the new device and verify vault data.

### Restore After Losing Every Trusted Device

1. Start the normal restore flow first.
2. When no trusted device can approve, choose the new-token path.
3. Create a new fine-grained GitHub token for the same private vault repository.
4. Provide the old access context and the new token in GitVault.
5. Revoke the old token in GitHub after recovery succeeds.

The old token proves access to existing vault storage. The new token proves current control of the GitHub account.

## Install And Update

### Web

Open `https://gitvault.giofahreza.com/app/`. The web app version is derived from the current release tag after GitHub Pages deployment.

### Android

Download the latest APK from GitHub Releases. The universal APK works on most devices; ABI-specific APKs are available for smaller downloads.

### Desktop

Download the Windows, macOS, or Linux archive and its matching platform
checksum file from GitHub Releases. Extract the entire archive so GitVault,
its runtime files, and the bundled `gitvault_mcp` executable remain together.

### Verify A Release

Before running a release that will hold real secrets:

1. Download the APK or Desktop archive and its checksum file from the same GitHub release.
2. Calculate the SHA-256 hash for the downloaded application.
3. Compare the value with the exact filename line in the matching checksum file.
4. Install or extract only when the values match.
5. Open Settings, then About, and confirm the app version matches the release tag.

On Windows:

```powershell
certutil -hashfile gitvault-vX.Y.Z-universal.apk SHA256
Get-FileHash -Algorithm SHA256 gitvault-vX.Y.Z-windows-x64.zip
Get-Content SHA256SUMS-windows.txt
```

On macOS or Linux:

```bash
sha256sum gitvault-vX.Y.Z-universal.apk
cat SHA256SUMS.txt
sha256sum -c SHA256SUMS-linux.txt
shasum -a 256 -c SHA256SUMS-macos.txt
```

## FAQ And Common Mistakes

| Question | Answer |
|---|---|
| Do I need business verification? | No. A normal GitHub account, private repository, and fine-grained token are enough for sync. |
| Does GitHub see my secrets? | No. GitVault uploads encrypted vault files, not readable passwords, notes, or TOTP secrets. |
| Should I link or restore a new device? | Use Link New Device when a trusted device is available. Use Restore Device when setting up from recovery. |
| Why does an alert appear for my own device? | The device may have appeared outside Link New Device, or trusted state has not synced yet. Recognize it only if the timing and device match your action. |
| Why is the web version still old? | GitHub Pages deployment can lag the release tag. Wait for deployment, then reload the web app. |

## Troubleshooting

| Problem | Likely cause | What to do |
|---|---|---|
| Sync fails | Network, repository, token, or permission problem | Check internet access, repository name, token expiry, and contents read/write permission |
| PIN input is delayed | Wrong attempts triggered throttling | Wait for the timer, then type the full PIN with the keyboard on web |
| Device is not listed | The device has not linked, restored, or synced yet | Open GitVault on that device and run sync after setup |
| Device alert keeps returning | The device registry did not sync the trusted state everywhere yet | Sync the device where you recognized it, then sync the other devices |
| New device cannot access data | It was removed or is not trusted | Use Link New Device from a trusted device, or restore with recovery and valid GitHub token flow |
| Autofill not showing | Android autofill provider is not selected or browser support is limited | Select GitVault in Android Autofill settings and try Chrome when Samsung Internet does not show third-party providers |
| Autofill still missing in one app | The target app does not expose fields to Android autofill | Enable GitVault Keyboard and switch keyboards in that app |
| Biometric unlock unavailable | The browser or device does not expose biometric support | Use PIN unlock, or try a supported browser/device |
| AI app reports Desktop unavailable | GitVault Desktop is closed or AI Apps is disabled | Open Desktop and enable Allow AI apps |
| AI app reports vault locked | GitVault is running but locked | Unlock in Desktop; MCP never opens the unlock prompt itself |
| AI app reports conflict | The note changed after the app read it | Read the note again and retry with the newest modified timestamp |
