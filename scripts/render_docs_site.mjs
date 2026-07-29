import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const DOCS_ROOT = join(ROOT, "docs", "docs");
const VERSION = "20260729c";
const UPDATED = "July 29, 2026";

const primaryGroups = [
  {
    label: "Tutorials",
    pages: ["quick-start", "github-sync"],
  },
  {
    label: "How-to guides",
    pages: ["passwords", "notes", "totp", "totp-import", "ssh", "autofill-keyboard"],
  },
  {
    label: "Reference",
    pages: ["platform-support", "sync-behavior", "security", "settings", "devices"],
  },
  {
    label: "Recovery",
    pages: ["recovery"],
  },
  {
    label: "Operations",
    pages: ["install-update", "release-verification"],
  },
  {
    label: "Troubleshooting",
    pages: ["faq", "troubleshooting"],
  },
];

const topicGroups = [
  {
    slug: "security",
    title: "Security",
    summary: "Encryption, PIN, biometric unlock, duress mode, clipboard handling, and device trust.",
    pages: ["security", "settings", "devices", "recovery"],
  },
  {
    slug: "sync",
    title: "Sync",
    summary: "GitHub repository setup, sync behavior, conflicts, device registry sync, and diagnostics.",
    pages: ["github-sync", "sync-behavior", "devices", "recovery", "troubleshooting"],
  },
  {
    slug: "devices",
    title: "Devices",
    summary: "Trusted devices, Link New Device, recovery requests, alerts, and removal behavior.",
    pages: ["devices", "recovery", "platform-support", "troubleshooting"],
  },
  {
    slug: "android",
    title: "Android",
    summary: "APK install, autofill, GitVault Keyboard, biometric unlock, recent-app privacy, and mobile support.",
    pages: ["platform-support", "autofill-keyboard", "install-update", "release-verification", "troubleshooting"],
  },
  {
    slug: "web",
    title: "Web",
    summary: "Web app setup, keyboard PIN entry, browser biometric support, lock button, and GitHub Pages deployment.",
    pages: ["platform-support", "security", "install-update", "release-verification", "troubleshooting"],
  },
];

const pages = [
  {
    slug: "quick-start",
    title: "Quick start",
    category: "Tutorials",
    applies: "First setup on web or Android",
    summary: "Create your vault, save recovery, set a PIN, add an item, and connect encrypted sync.",
    keywords: "setup onboarding create vault recovery phrase pin github sync first run link device restore",
    headings: ["Before you start", "Create your first vault", "Set up sync", "Add another device", "Verify the setup"],
    excerpt:
      "Start with a new vault, write down the recovery phrase, set a 4-6 digit PIN, add one vault item, then connect GitHub sync if you need backup or more devices.",
    related: ["github-sync", "devices", "recovery", "install-update"],
    body: `
      <p class="docs-lead">Use this tutorial the first time you open GitVault. It keeps the critical order clear: create the vault, protect recovery, set unlock, then connect sync.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/settings-pin-setup.png" alt="GitVault PIN setup screen" loading="lazy">
        </div>
        <figcaption>Set the unlock method before depending on the vault for daily use.</figcaption>
      </figure>

      <h2>Before you start</h2>
      <ul class="docs-list">
        <li><strong>GitHub account</strong> Required only when you want encrypted sync or multi-device use.</li>
        <li><strong>Private repository</strong> Recommended for every synced vault. Keep it dedicated to GitVault.</li>
        <li><strong>Recovery storage</strong> Prepare a place outside GitVault for the recovery phrase or recovery kit.</li>
      </ul>

      <h2>Create your first vault</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open GitVault.</strong><p>Use <a class="docs-inline-link" href="/app/">the web app</a> on desktop, or install the Android APK from <a class="docs-inline-link" href="https://github.com/giofahreza/gitvault/releases/latest">GitHub Releases</a>.</p></div></li>
        <li><span>2</span><div><strong>Choose the new-vault path.</strong><p>Use fresh setup when this is your first GitVault device.</p></div></li>
        <li><span>3</span><div><strong>Save the recovery phrase.</strong><p>Write it down or store the recovery kit outside GitVault. Do not keep the only copy inside the vault.</p></div></li>
        <li><span>4</span><div><strong>Create a PIN.</strong><p>Use a 4-6 digit PIN you can enter accurately. On web, type the PIN with the physical keyboard.</p></div></li>
        <li><span>5</span><div><strong>Add one item.</strong><p>Add a password, note, 2FA code, or SSH credential, then reopen it to confirm the saved data is correct.</p></div></li>
      </ol>

      <h2>Set up sync</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Create a private GitHub repository.</strong><p>Use a dedicated empty repository for the encrypted vault files.</p></div></li>
        <li><span>2</span><div><strong>Create a fine-grained token.</strong><p>Give the token access only to the vault repository with Metadata read and Contents read/write permissions.</p></div></li>
        <li><span>3</span><div><strong>Open Settings, then GitHub Sync.</strong><p>Enter the GitHub owner, repository name, and token.</p></div></li>
        <li><span>4</span><div><strong>Run the first sync.</strong><p>Wait for a success state before opening the vault on another device.</p></div></li>
      </ol>

      <h2>Add another device</h2>
      <p>Use Link New Device when you still have an unlocked trusted device. Use Restore Device only when you are setting up from recovery.</p>
      <ul class="docs-list">
        <li><strong>Link New Device</strong> Opens a short-lived invite from a trusted device and is the normal path for adding your phone, laptop, or browser.</li>
        <li><strong>Restore Device</strong> Starts from the recovery phrase and GitHub access, then waits for a trusted-device approval or the lost-device new-token path.</li>
      </ul>

      <h2>Verify the setup</h2>
      <ul class="docs-list">
        <li><strong>Unlock</strong> Close and reopen GitVault, then confirm PIN or biometric unlock works.</li>
        <li><strong>Sync</strong> Check Settings for a successful sync timestamp after adding an item.</li>
        <li><strong>Recovery</strong> Confirm the recovery phrase or kit is stored somewhere you can access without GitVault.</li>
      </ul>

      <div class="docs-note danger">
        <strong>Do not skip recovery.</strong>
        <p>If you lose every trusted device and the recovery phrase, GitVault cannot decrypt your vault for you.</p>
      </div>
    `,
  },
  {
    slug: "github-sync",
    title: "GitHub sync setup",
    category: "Tutorials",
    applies: "Web and Android",
    summary: "Prepare a private repository and fine-grained token for encrypted GitVault storage.",
    keywords: "github repository repo token pat fine grained contents metadata private sync storage bearer classic token",
    headings: ["Visual checkpoint", "How GitHub is used", "Create private storage", "Token permissions", "Connect GitVault", "Rotate a token"],
    excerpt:
      "GitHub is only encrypted storage. GitVault encrypts locally, writes ciphertext files to one private repository, and needs a fine-grained token with minimal repository permissions.",
    related: ["sync-behavior", "devices", "recovery", "troubleshooting"],
    body: `
      <p class="docs-lead">GitHub is not the password manager. It is only the storage location for encrypted vault files that GitVault creates after local encryption.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/settings-autofill-devices.png" alt="GitVault settings area with sync, autofill, and connected devices" loading="lazy">
        </div>
        <figcaption>GitHub Sync lives in Settings. After saving token details, confirm sync succeeds before adding another device.</figcaption>
      </figure>

      <h2>Visual checkpoint</h2>
      <p>Before opening GitVault on another device, Settings should show GitHub Sync as connected and a successful sync timestamp or status.</p>

      <h2>How GitHub is used</h2>
      <p>GitVault reads and writes encrypted vault data in your private repository. Passwords, notes, TOTP secrets, recovery records, and device registry data are encrypted before they are uploaded.</p>

      <h2>Create private storage</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Create an empty private repository.</strong><p>Use a normal GitHub account. Keep the repository private and dedicated to GitVault.</p></div></li>
        <li><span>2</span><div><strong>Leave normal branch settings.</strong><p>GitVault only needs repository contents access. You do not need GitHub Pages, Actions, or a public repository for vault sync.</p></div></li>
        <li><span>3</span><div><strong>Copy the owner and repository name.</strong><p>You will enter both values in GitVault Settings.</p></div></li>
      </ol>

      <h2>Token permissions</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Open GitHub fine-grained tokens.</strong><p>Go to Developer settings, then Personal access tokens, then Fine-grained tokens.</p></div></li>
        <li><span>2</span><div><strong>Select only the vault repository.</strong><p>A token scoped to one repository limits damage if the token is exposed.</p></div></li>
        <li><span>3</span><div><strong>Grant Metadata read.</strong><p>GitHub usually selects this automatically.</p></div></li>
        <li><span>4</span><div><strong>Grant Contents read and write.</strong><p>This lets GitVault download encrypted data and upload encrypted updates.</p></div></li>
        <li><span>5</span><div><strong>Copy the token immediately.</strong><p>GitHub shows it once. Paste it into GitVault before closing the page.</p></div></li>
      </ol>

      <div class="docs-note">
        <strong>Use fine-grained tokens.</strong>
        <p>Classic tokens are broader than GitVault needs. Use a fine-grained token scoped to the single private vault repository.</p>
      </div>

      <h2>Connect GitVault</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Unlock GitVault.</strong><p>Open Settings after the vault is unlocked.</p></div></li>
        <li><span>2</span><div><strong>Open GitHub Sync.</strong><p>Enter GitHub owner, repository name, and the fine-grained token.</p></div></li>
        <li><span>3</span><div><strong>Save and run sync.</strong><p>Wait for success before adding another device.</p></div></li>
        <li><span>4</span><div><strong>Check the repository.</strong><p>You should see encrypted vault files, not readable secret values.</p></div></li>
      </ol>

      <h2>Rotate a token</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Create a replacement token first.</strong><p>Use the same repository and permissions.</p></div></li>
        <li><span>2</span><div><strong>Update GitVault Settings.</strong><p>Paste the new token and confirm sync works.</p></div></li>
        <li><span>3</span><div><strong>Revoke the old token in GitHub.</strong><p>Do this after GitVault confirms a successful sync with the new token.</p></div></li>
      </ol>
    `,
  },
  {
    slug: "platform-support",
    title: "Platform support",
    category: "Reference",
    applies: "Web and Android",
    summary: "Feature availability across the web app and Android APK.",
    keywords: "platform support web android browser apk autofill keyboard biometric ssh terminal recent apps",
    headings: ["Support matrix", "Web notes", "Android notes", "Unsupported or conditional behavior"],
    excerpt:
      "Most vault features work on web and Android. Android adds system autofill, GitVault Keyboard, recent-app privacy, and mobile SSH terminal behavior where supported.",
    related: ["install-update", "autofill-keyboard", "security", "troubleshooting"],
    body: `
      <p class="docs-lead">GitVault shares the same encrypted vault across web and Android, but some integrations depend on the platform.</p>

      <h2>Support matrix</h2>
      <div class="docs-table-wrap">
        <table class="docs-table">
          <thead><tr><th>Feature</th><th>Web app</th><th>Android APK</th><th>Notes</th></tr></thead>
          <tbody>
            <tr><td>Passwords</td><td>Supported</td><td>Supported</td><td>Add, group, search, copy, edit, and delete entries.</td></tr>
            <tr><td>Notes</td><td>Supported</td><td>Supported</td><td>Mobile uses a single-column list for readability.</td></tr>
            <tr><td>2FA live codes</td><td>Supported</td><td>Supported</td><td>Live TOTP codes and countdowns are available in the vault.</td></tr>
            <tr><td>TOTP import link</td><td>Supported</td><td>Supported</td><td>Paste otpauth links on either platform.</td></tr>
            <tr><td>TOTP QR scan</td><td>Browser-dependent</td><td>Supported where camera permission works</td><td>Paste the secret when scanning is unavailable.</td></tr>
            <tr><td>SSH credential storage</td><td>Supported</td><td>Supported</td><td>Credentials are encrypted like other vault data.</td></tr>
            <tr><td>SSH terminal</td><td>Not the primary target</td><td>Supported where Android terminal dependencies work</td><td>Test a host before relying on terminal sessions.</td></tr>
            <tr><td>System autofill</td><td>Not available</td><td>Android 8.0+</td><td>Requires selecting GitVault as the Android autofill provider.</td></tr>
            <tr><td>GitVault Keyboard</td><td>Not available</td><td>Android input method</td><td>Useful when an app does not trigger autofill reliably.</td></tr>
            <tr><td>Biometric unlock</td><td>Supported on capable browsers/devices</td><td>Supported on capable devices</td><td>PIN remains the backup unlock method.</td></tr>
            <tr><td>Lock button</td><td>Supported</td><td>Supported</td><td>Use it before leaving an unlocked vault.</td></tr>
            <tr><td>Recent-app privacy</td><td>Browser-managed</td><td>Supported</td><td>Android hides the latest vault view from the app switcher where the OS honors secure window flags.</td></tr>
          </tbody>
        </table>
      </div>

      <h2>Web notes</h2>
      <ul class="docs-list">
        <li><strong>PIN input</strong> Type the PIN with the physical keyboard. Mouse-only keypad entry is not required.</li>
        <li><strong>Biometric unlock</strong> Browser support depends on the device, browser, and secure context.</li>
        <li><strong>Version</strong> The web app version is filled from the current release tag after GitHub Pages deployment.</li>
      </ul>

      <h2>Android notes</h2>
      <ul class="docs-list">
        <li><strong>Autofill</strong> Select GitVault as the Android autofill provider before expecting suggestions.</li>
        <li><strong>Keyboard</strong> Enable GitVault Keyboard when a target app does not expose fields to autofill.</li>
        <li><strong>APK</strong> The universal APK is easiest. ABI-specific APKs are available for smaller downloads.</li>
      </ul>

      <h2>Unsupported or conditional behavior</h2>
      <p>Some Android vendors restrict third-party autofill in their own browsers or system builds. When autofill does not appear, try Chrome and the GitVault Keyboard fallback.</p>
    `,
  },
  {
    slug: "sync-behavior",
    title: "Sync behavior",
    category: "Reference",
    applies: "Web and Android",
    summary: "How encrypted GitHub sync, auto-sync, conflict handling, deletion tombstones, and device checks work.",
    keywords: "sync behavior auto sync last write wins conflict tombstones deleted items interval github device revocation",
    headings: ["What sync moves", "When sync runs", "Conflict handling", "Deletes", "Device trust checks", "Performance habits"],
    excerpt:
      "GitVault syncs encrypted vault data and trust records through GitHub. Auto-sync can run in the background, conflicts resolve by latest change, and deletes are retained as tombstones.",
    related: ["github-sync", "devices", "settings", "troubleshooting"],
    body: `
      <p class="docs-lead">GitVault is local-first. You can use the vault locally, and sync uploads encrypted changes to GitHub when enabled.</p>

      <h2>What sync moves</h2>
      <ul class="docs-list">
        <li><strong>Vault items</strong> Passwords, notes, TOTP entries, and SSH credentials are encrypted before upload.</li>
        <li><strong>Device registry</strong> Trusted devices and device alerts are synced so web and Android see the same trust state.</li>
        <li><strong>Recovery records</strong> Recovery requests and approvals are stored as encrypted coordination data.</li>
      </ul>

      <h2>When sync runs</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Manual sync.</strong><p>Use Settings when you want an immediate check after important edits.</p></div></li>
        <li><span>2</span><div><strong>Auto-sync.</strong><p>When enabled, GitVault periodically checks for local and remote changes at the configured interval.</p></div></li>
        <li><span>3</span><div><strong>App open checks.</strong><p>GitVault can check device trust when the app opens so removed devices clear local sync access quickly.</p></div></li>
      </ol>

      <h2>Conflict handling</h2>
      <p>GitVault uses smart sync with last-write-wins behavior. If the same item is edited on two devices before either device syncs, the newest synced item version wins.</p>
      <div class="docs-note warning">
        <strong>Avoid editing the same item offline on two devices.</strong>
        <p>For high-value entries, sync the first device before editing that same entry from another device.</p>
      </div>

      <h2>Deletes</h2>
      <p>Deleted records are tracked with tombstones so a deletion can propagate to other devices instead of being recreated by an older local copy.</p>

      <h2>Device trust checks</h2>
      <p>If a device is removed from Connected Devices, it is no longer trusted after the change syncs. When that removed device next opens or performs a trust check, GitVault clears local sync access and requires Link New Device or recovery before it can access synced data again.</p>

      <h2>Performance habits</h2>
      <ul class="docs-list">
        <li><strong>Keep tokens narrow</strong> One small private repository is faster to scan and safer to authorize.</li>
        <li><strong>Use reasonable intervals</strong> Very frequent sync checks can cost battery and GitHub API quota on mobile.</li>
        <li><strong>Sync after large edits</strong> Manual sync after bulk changes reduces surprise on other devices.</li>
      </ul>
    `,
  },
  {
    slug: "passwords",
    title: "Passwords",
    category: "How-to guides",
    applies: "Web and Android",
    summary: "Add, group, search, copy, edit, delete, and fill password entries.",
    keywords: "password credentials username url notes group dropdown create group copy edit delete autofill totp",
    headings: ["Add a password", "Choose or create a group", "Use a saved password", "Edit or delete", "Autofill on Android"],
    excerpt:
      "Password entries store login title, username, password, URL, notes, group, and optional TOTP data. Groups can be selected or created from the same dropdown.",
    related: ["autofill-keyboard", "totp", "sync-behavior", "security"],
    body: `
      <p class="docs-lead">Use Passwords for login credentials and related context. Entries can include a URL, notes, group, and optional TOTP secret.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/passwords-list.png" alt="GitVault grouped password list" loading="lazy">
        </div>
        <figcaption>Groups keep the password list scannable on web and mobile.</figcaption>
      </figure>

      <h2>Add a password</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open Passwords.</strong><p>Use the Passwords tab or menu item.</p></div></li>
        <li><span>2</span><div><strong>Select add.</strong><p>Open the password form.</p></div></li>
        <li><span>3</span><div><strong>Fill login details.</strong><p>Add title, username, password, URL, and notes as needed.</p></div></li>
        <li><span>4</span><div><strong>Add 2FA when useful.</strong><p>Paste a TOTP secret if you want the login and live authenticator code in one record.</p></div></li>
        <li><span>5</span><div><strong>Save.</strong><p>Confirm the entry appears in the list, then sync if you use multiple devices.</p></div></li>
      </ol>

      <h2>Choose or create a group</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Open the group dropdown.</strong><p>Existing groups appear in the same field.</p></div></li>
        <li><span>2</span><div><strong>Select an existing group.</strong><p>Use consistent names like Personal, Work, Finance, or Servers.</p></div></li>
        <li><span>3</span><div><strong>Create a new group in place.</strong><p>If the group does not exist, create it from the dropdown without leaving the form.</p></div></li>
      </ol>

      <h2>Use a saved password</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Search or open a group.</strong><p>Find entries by title, username, URL, or group.</p></div></li>
        <li><span>2</span><div><strong>Copy the needed field.</strong><p>Use copy actions for username, password, and TOTP code.</p></div></li>
        <li><span>3</span><div><strong>Wait for clipboard clear.</strong><p>When enabled, GitVault clears copied secrets after the configured delay.</p></div></li>
      </ol>

      <h2>Edit or delete</h2>
      <p>Open the password detail, edit the fields, and save. If deleting, confirm the deletion and let sync run so other devices receive the tombstone.</p>

      <h2>Autofill on Android</h2>
      <p>After setting GitVault as the Android autofill provider, open a login field in another app. If the app does not show autofill, switch to GitVault Keyboard and choose the credential there.</p>
    `,
  },
  {
    slug: "notes",
    title: "Notes",
    category: "How-to guides",
    applies: "Web and Android",
    summary: "Create private notes, checklists, tags, colors, pinned notes, archive, and search.",
    keywords: "notes checklist pinned list grid single column mobile tags archive color search private text",
    headings: ["Create a note", "Create a checklist", "Organize notes", "Find notes", "Archive or delete"],
    excerpt:
      "Notes can be plain private text or checklists. Use pinning, colors, tags, archive, and search to keep private information usable.",
    related: ["sync-behavior", "security", "troubleshooting"],
    body: `
      <p class="docs-lead">Use Notes for private text, recovery codes, secure references, and checklist-style private tasks.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/notes-grid-pinned.png" alt="GitVault pinned notes view" loading="lazy">
        </div>
        <figcaption>Desktop can use denser note views. Mobile keeps the notes list to one column for readability.</figcaption>
      </figure>

      <h2>Create a note</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open Notes.</strong><p>Use the Notes tab or menu item.</p></div></li>
        <li><span>2</span><div><strong>Select add.</strong><p>Open the note editor.</p></div></li>
        <li><span>3</span><div><strong>Add a title and content.</strong><p>Keep titles descriptive enough to search later.</p></div></li>
        <li><span>4</span><div><strong>Save.</strong><p>Confirm the note appears in the list.</p></div></li>
      </ol>

      <h2>Create a checklist</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Open the note editor.</strong><p>Choose checklist mode where available.</p></div></li>
        <li><span>2</span><div><strong>Add checklist rows.</strong><p>Use one row per task or private reminder.</p></div></li>
        <li><span>3</span><div><strong>Tap rows to complete them.</strong><p>Completed rows stay in the note until edited or removed.</p></div></li>
      </ol>

      <h2>Organize notes</h2>
      <ul class="docs-list">
        <li><strong>Pin</strong> Keep important notes at the top.</li>
        <li><strong>Color</strong> Use color as a quick visual category.</li>
        <li><strong>Tags</strong> Add tags such as #work or #finance when search should find a note by context.</li>
        <li><strong>Archive</strong> Hide old notes without deleting them.</li>
      </ul>

      <h2>Find notes</h2>
      <p>Use search for title, visible content, and tags. On mobile, the single-column layout is intended to keep each note readable without side-by-side squeezing.</p>

      <h2>Archive or delete</h2>
      <p>Archive notes you may need later. Delete only when you are sure, then sync so other devices receive the delete tombstone.</p>
    `,
  },
  {
    slug: "totp",
    title: "2FA codes",
    category: "How-to guides",
    applies: "Web and Android",
    summary: "Store TOTP secrets, organize codes by group, copy live codes, and handle countdown timing.",
    keywords: "2fa totp authenticator code timer secret issuer account group dropdown copy countdown",
    headings: ["Add a 2FA code", "Choose or create a group", "Use a code", "Store 2FA inside a password"],
    excerpt:
      "GitVault works as an authenticator for TOTP secrets. Codes regenerate on the normal timer and can be copied from the 2FA page or password details.",
    related: ["totp-import", "passwords", "sync-behavior", "security"],
    body: `
      <p class="docs-lead">Use 2FA Codes for authenticator-style TOTP secrets. GitVault stores the secret in the encrypted vault and shows live codes when unlocked.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/2fa-codes.png" alt="GitVault live TOTP codes list" loading="lazy">
        </div>
        <figcaption>Each code includes a countdown so you can avoid copying a nearly expired code.</figcaption>
      </figure>

      <h2>Add a 2FA code</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open 2FA Codes.</strong><p>Use the authenticator area in GitVault.</p></div></li>
        <li><span>2</span><div><strong>Add issuer and account.</strong><p>Use names you can recognize during login.</p></div></li>
        <li><span>3</span><div><strong>Paste the TOTP secret.</strong><p>Copy the secret or otpauth link from the service you are protecting.</p></div></li>
        <li><span>4</span><div><strong>Save and verify.</strong><p>Confirm GitVault shows a live 6-digit code and countdown.</p></div></li>
      </ol>

      <h2>Choose or create a group</h2>
      <p>Use the group dropdown in the 2FA form. Select an existing group or create a new one from the same control so 2FA organization matches your password organization.</p>

      <h2>Use a code</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Open the 2FA entry.</strong><p>Wait for the next code if the countdown is nearly finished.</p></div></li>
        <li><span>2</span><div><strong>Copy the code.</strong><p>Paste it into the service before the timer resets.</p></div></li>
        <li><span>3</span><div><strong>Let clipboard clear.</strong><p>Use clipboard auto-clear for safer temporary copying.</p></div></li>
      </ol>

      <h2>Store 2FA inside a password</h2>
      <p>If the TOTP secret belongs to a login already saved in Passwords, attach it to the password record. That keeps username, password, URL, notes, and live 2FA code together.</p>
    `,
  },
  {
    slug: "totp-import",
    title: "TOTP import",
    category: "How-to guides",
    applies: "Web and Android",
    summary: "Import authenticator secrets from manual secrets, otpauth links, or QR codes when supported.",
    keywords: "totp import otpauth qr code scanner secret google authenticator issuer account migration",
    headings: ["Accepted inputs", "Import from a copied secret", "Import from an otpauth link", "Import from QR", "Verify imported codes"],
    excerpt:
      "GitVault accepts manual TOTP secrets and otpauth links. QR scanning depends on camera support; paste the link or secret when scanning is unavailable.",
    related: ["totp", "passwords", "platform-support", "troubleshooting"],
    body: `
      <p class="docs-lead">Use TOTP import when moving authenticator entries into GitVault. Always verify a new code against the service before deleting the old authenticator entry.</p>

      <h2>Accepted inputs</h2>
      <ul class="docs-list">
        <li><strong>Manual secret</strong> A base32 TOTP secret copied from the service.</li>
        <li><strong>otpauth link</strong> A link beginning with <code>otpauth://totp/</code>.</li>
        <li><strong>QR code</strong> Supported where the platform and permissions expose camera scanning.</li>
      </ul>

      <h2>Import from a copied secret</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open the service's 2FA setup page.</strong><p>Choose the option that shows the manual setup key.</p></div></li>
        <li><span>2</span><div><strong>Copy the secret.</strong><p>Do not include spaces unless the app specifically accepts them.</p></div></li>
        <li><span>3</span><div><strong>Open GitVault 2FA Codes.</strong><p>Create a new code and paste the secret.</p></div></li>
        <li><span>4</span><div><strong>Fill issuer and account.</strong><p>Use the service name as issuer and your username or email as account.</p></div></li>
      </ol>

      <h2>Import from an otpauth link</h2>
      <p>Paste the full otpauth link into the TOTP field. GitVault reads the issuer, account, and secret when the link contains them.</p>

      <h2>Import from QR</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Open scan from the 2FA flow.</strong><p>Grant camera permission if the platform asks.</p></div></li>
        <li><span>2</span><div><strong>Scan the QR code.</strong><p>Hold the code steady and keep the screen bright.</p></div></li>
        <li><span>3</span><div><strong>Review imported fields.</strong><p>Check issuer and account before saving.</p></div></li>
      </ol>

      <h2>Verify imported codes</h2>
      <p>Before deleting the old authenticator entry, use a GitVault-generated code to complete a real login or a service verification step.</p>
    `,
  },
  {
    slug: "ssh",
    title: "SSH credentials",
    category: "How-to guides",
    applies: "Web and Android",
    summary: "Save SSH hosts, ports, usernames, passwords, keys, and Android terminal entries.",
    keywords: "ssh terminal host username port password private key android credentials ping connect session",
    headings: ["Add an SSH credential", "Password auth", "Key auth", "Test and connect", "Operational habits"],
    excerpt:
      "SSH entries store host credentials in the encrypted vault. Android can open terminal workflows where supported by the build and device.",
    related: ["platform-support", "sync-behavior", "security", "troubleshooting"],
    body: `
      <p class="docs-lead">SSH entries keep server access details inside the same encrypted vault as passwords, notes, and 2FA codes.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/ssh-list.png" alt="GitVault SSH credentials list" loading="lazy">
        </div>
        <figcaption>Use clear host titles so server entries are easy to identify before connecting.</figcaption>
      </figure>

      <h2>Add an SSH credential</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open SSH.</strong><p>Use the SSH area in GitVault.</p></div></li>
        <li><span>2</span><div><strong>Add host details.</strong><p>Enter a title, host, username, and port.</p></div></li>
        <li><span>3</span><div><strong>Choose authentication data.</strong><p>Add a password or private-key details.</p></div></li>
        <li><span>4</span><div><strong>Save.</strong><p>Review the saved entry before connecting.</p></div></li>
      </ol>

      <h2>Password auth</h2>
      <p>Store the SSH password only when the server still requires password authentication. Use clipboard auto-clear if you copy it into another terminal.</p>

      <h2>Key auth</h2>
      <p>Store private-key material only for devices you trust. If a device is lost, remove it from Connected Devices and rotate server credentials where appropriate.</p>

      <h2>Test and connect</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Ping or test first.</strong><p>Confirm the host and port are reachable.</p></div></li>
        <li><span>2</span><div><strong>Open terminal where supported.</strong><p>Android builds can use terminal workflows when the device supports them.</p></div></li>
        <li><span>3</span><div><strong>Lock after use.</strong><p>Server credentials are high-value secrets.</p></div></li>
      </ol>

      <h2>Operational habits</h2>
      <ul class="docs-list">
        <li><strong>Use unique titles</strong> Include environment or region when hosts look similar.</li>
        <li><strong>Rotate after loss</strong> If a trusted device is lost, rotate credentials that were available on that device.</li>
        <li><strong>Sync after edits</strong> Confirm changes reach other trusted devices before relying on them away from the source device.</li>
      </ul>
    `,
  },
  {
    slug: "autofill-keyboard",
    title: "Autofill and GitVault Keyboard",
    category: "How-to guides",
    applies: "Android",
    summary: "Enable Android autofill and GitVault Keyboard for easier password entry in other apps.",
    keywords: "android autofill service keyboard ime inline suggestions samsung chrome pixel gboard swiftkey",
    headings: ["Enable autofill on Samsung", "Enable autofill on Pixel or stock Android", "Verify autofill", "Enable GitVault Keyboard", "When to use keyboard fallback"],
    excerpt:
      "Android autofill works after selecting GitVault as the system autofill service. GitVault Keyboard is the fallback for apps or browsers that do not expose fields correctly.",
    related: ["passwords", "platform-support", "settings", "troubleshooting"],
    body: `
      <p class="docs-lead">Autofill and GitVault Keyboard are Android integrations for getting credentials into other apps. Configure both if you want the most reliable mobile flow.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/settings-ime-keyboard.png" alt="GitVault Keyboard settings" loading="lazy">
        </div>
        <figcaption>GitVault Keyboard helps when an app does not trigger the Android autofill provider.</figcaption>
      </figure>

      <h2>Enable autofill on Samsung</h2>
      <pre><code>Settings
General Management
Passwords, Passkeys, and Autofill
Cog beside Preferred Service
GitVault</code></pre>

      <h2>Enable autofill on Pixel or stock Android</h2>
      <pre><code>Settings
System
Languages and input
Autofill service
GitVault</code></pre>

      <h2>Verify autofill</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Unlock GitVault.</strong><p>The vault must be available before it can fill credentials.</p></div></li>
        <li><span>2</span><div><strong>Open Chrome or another app with a login page.</strong><p>Tap the username field.</p></div></li>
        <li><span>3</span><div><strong>Choose GitVault from suggestions.</strong><p>If no suggestion appears, try Chrome and then the keyboard fallback.</p></div></li>
      </ol>

      <h2>Enable GitVault Keyboard</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Open GitVault Settings.</strong><p>Find GitVault Keyboard.</p></div></li>
        <li><span>2</span><div><strong>Tap Enable.</strong><p>Follow the Android input method prompt.</p></div></li>
        <li><span>3</span><div><strong>Switch keyboard in a text field.</strong><p>Select GitVault Keyboard when you need credential suggestions.</p></div></li>
      </ol>

      <h2>When to use keyboard fallback</h2>
      <ul class="docs-list">
        <li><strong>Autofill missing</strong> Some apps do not expose username and password fields to Android autofill.</li>
        <li><strong>Vendor browser issues</strong> Some Samsung Internet builds prefer Samsung Pass. Chrome is the recommended browser when third-party autofill is blocked.</li>
        <li><strong>Older devices</strong> Dropdown fallback can work on Android 8.0+ even when inline suggestions are not available.</li>
      </ul>
    `,
  },
  {
    slug: "security",
    title: "Security model",
    category: "Reference",
    applies: "Web and Android",
    summary: "How local encryption, unlock, biometric, duress mode, clipboard clearing, storage, and trust work.",
    keywords: "security encryption xchacha20 poly1305 local first pin biometric lock auth interval duress panic clipboard github ciphertext",
    headings: ["Security layers", "Unlock and lock", "Biometric unlock", "Authentication interval", "Duress mode", "Clipboard auto-clear"],
    excerpt:
      "GitVault encrypts data locally with authenticated encryption before GitHub sync. Local unlock is protected by PIN and optional biometric support, with duress and clipboard safety settings.",
    related: ["settings", "devices", "recovery", "sync-behavior"],
    body: `
      <p class="docs-lead">GitVault is built around local encryption and user-owned storage. GitHub stores encrypted files, not readable vault contents.</p>

      <h2>Security layers</h2>
      <div class="docs-table-wrap">
        <table class="docs-table">
          <thead><tr><th>Layer</th><th>How GitVault handles it</th><th>User responsibility</th></tr></thead>
          <tbody>
            <tr><td>Encryption</td><td>XChaCha20-Poly1305 authenticated encryption before sync.</td><td>Protect recovery material and unlocked devices.</td></tr>
            <tr><td>Storage</td><td>GitHub stores ciphertext files in your private repository.</td><td>Keep the repository private and token permissions narrow.</td></tr>
            <tr><td>Unlock</td><td>PIN and optional biometric unlock protect local access.</td><td>Use a PIN you can enter reliably and avoid sharing trusted devices.</td></tr>
            <tr><td>Clipboard</td><td>Copied secrets can auto-clear after a configured delay.</td><td>Use short delays on shared or work devices.</td></tr>
            <tr><td>Device trust</td><td>Linked and recognized devices are tracked in the encrypted registry.</td><td>Review devices and remove devices you no longer control.</td></tr>
          </tbody>
        </table>
      </div>

      <h2 id="unlock-lock">Unlock and lock</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open the app.</strong><p>The lock screen appears when authentication is required.</p></div></li>
        <li><span>2</span><div><strong>Enter the full PIN.</strong><p>Use the keyboard on web or the on-screen keypad on Android.</p></div></li>
        <li><span>3</span><div><strong>Wait for verification.</strong><p>Wrong attempts can trigger throttling before another attempt is accepted.</p></div></li>
        <li><span>4</span><div><strong>Lock manually when needed.</strong><p>Use the lock button before stepping away from an unlocked vault.</p></div></li>
      </ol>

      <h2>Biometric unlock</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Unlock with PIN first.</strong><p>Biometric unlock is enabled from an already-unlocked vault.</p></div></li>
        <li><span>2</span><div><strong>Open Settings.</strong><p>Find biometric unlock in the security area.</p></div></li>
        <li><span>3</span><div><strong>Approve the prompt.</strong><p>Use biometric unlock only on devices and browsers you personally control.</p></div></li>
      </ol>

      <h2>Authentication interval</h2>
      <p>The authentication interval controls how often GitVault asks again after opening or returning to the app. The interval does not reset just because you open the app, so a short interval remains strict across repeated opens.</p>

      <h2>Duress mode</h2>
      <p>Duress mode uses a panic PIN for emergencies. Entering the duress PIN wipes the vault and shows decoy data. Treat this as destructive and test only with disposable data.</p>

      <h2>Clipboard auto-clear</h2>
      <p>Copied usernames, passwords, and codes can be cleared automatically after a configured delay. The OS clipboard is outside the encrypted vault, so use the shortest delay that fits your workflow.</p>
    `,
  },
  {
    slug: "settings",
    title: "Settings",
    category: "Reference",
    applies: "Web and Android",
    summary: "Configuration reference for PIN, biometric, auth interval, sync, clipboard, autofill, keyboard, theme, devices, and recovery.",
    keywords: "settings theme clipboard autofill keyboard github biometric pin interval recovery kit connected devices auto sync lock",
    headings: ["Settings map", "Recommended settings", "After changing settings"],
    excerpt:
      "Settings controls unlock behavior, biometric unlock, authentication interval, clipboard clearing, GitHub sync, auto-sync, autofill, keyboard, devices, and recovery kit access.",
    related: ["security", "sync-behavior", "devices", "autofill-keyboard"],
    body: `
      <p class="docs-lead">Settings is where GitVault connects sync, changes unlock behavior, manages devices, and configures Android integrations.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/settings-top.png" alt="GitVault settings screen" loading="lazy">
        </div>
        <figcaption>Review Settings after onboarding so the vault matches how you use each device.</figcaption>
      </figure>

      <h2>Settings map</h2>
      <div class="docs-table-wrap">
        <table class="docs-table">
          <thead><tr><th>Setting</th><th>Use it for</th><th>Recommended habit</th></tr></thead>
          <tbody>
            <tr><td>PIN</td><td>Backup unlock on web and Android.</td><td>Use 4-6 digits you can type accurately.</td></tr>
            <tr><td>Biometric unlock</td><td>Faster unlock on supported browsers and Android devices.</td><td>Enable only on personal trusted devices.</td></tr>
            <tr><td>Authentication interval</td><td>Control when GitVault asks again after opening or returning to the app.</td><td>Use shorter intervals for shared machines.</td></tr>
            <tr><td>Clipboard auto-clear</td><td>Clear copied passwords and codes automatically.</td><td>Use the shortest delay that fits your workflow.</td></tr>
            <tr><td>GitHub sync</td><td>Encrypted backup and multi-device sync.</td><td>Check sync success after important edits.</td></tr>
            <tr><td>Auto-sync</td><td>Periodic background sync checks.</td><td>Avoid overly aggressive intervals on mobile.</td></tr>
            <tr><td>Connected devices</td><td>Review, link, recognize, and remove trusted devices.</td><td>Remove devices you no longer control.</td></tr>
            <tr><td>Autofill and keyboard</td><td>Android system-wide credential filling.</td><td>Use Chrome if the device browser blocks third-party autofill.</td></tr>
            <tr><td>Theme</td><td>Light, dark, or system appearance.</td><td>Pick the mode that is easiest to scan.</td></tr>
          </tbody>
        </table>
      </div>

      <h2>Recommended settings</h2>
      <ul class="docs-list">
        <li><strong>Personal phone</strong> Biometric on, short clipboard clear, auto-sync enabled, Android recent-app privacy enabled by default.</li>
        <li><strong>Personal laptop browser</strong> Keyboard PIN entry, lock button habit, biometric only if the browser and device are trusted.</li>
        <li><strong>Shared computer</strong> Short authentication interval, short clipboard clear, manual lock after each use.</li>
      </ul>

      <h2>After changing settings</h2>
      <p>Run sync after changes that affect devices, GitHub access, or recovery. Then check another trusted device to confirm the state arrived.</p>
    `,
  },
  {
    slug: "devices",
    title: "Connected devices",
    category: "Reference",
    applies: "Web and Android",
    summary: "Link, approve, recognize, remove, and recover trusted web and Android devices.",
    keywords: "devices linked trusted remove approval recognize recovery token registry alert link new device qr transfer code pin",
    headings: ["Visual checklist", "What the device list means", "Link a new device", "Device added outside Link New Device", "Remove a device", "When a removed device opens"],
    excerpt:
      "Connected Devices shows trusted web and Android devices after they link or restore and sync. Removing a device makes it untrusted, and it must link or restore again.",
    related: ["recovery", "sync-behavior", "security", "troubleshooting"],
    body: `
      <p class="docs-lead">Connected Devices is the trust list for web browsers and Android installs that can access the synced vault.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/settings-autofill-devices.png" alt="GitVault settings area with connected devices" loading="lazy">
        </div>
        <figcaption>The device list is shared through encrypted sync, so each device needs a successful sync before every other device sees it.</figcaption>
      </figure>

      <h2>Visual checklist</h2>
      <ul class="docs-list">
        <li><strong>Current device visible</strong> The device you are using should be clearly marked as this device or current device.</li>
        <li><strong>New device named</strong> After Link New Device completes, give the new phone, browser, or laptop a recognizable name.</li>
        <li><strong>Sync after trust changes</strong> After recognizing or removing a device, run sync so other devices receive the trust update.</li>
      </ul>

      <h2>What the device list means</h2>
      <ul class="docs-list">
        <li><strong>This device</strong> The device or browser currently open.</li>
        <li><strong>Trusted device</strong> A device that linked, restored with approval, or was explicitly recognized by you.</li>
        <li><strong>Unknown device alert</strong> A warning that a device appeared outside the Link New Device flow.</li>
        <li><strong>Removed device</strong> A device that must link again or restore before it can use synced vault access.</li>
      </ul>

      <h2>Link a new device</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open Settings on a trusted device.</strong><p>Select Link New Device and keep the source device open.</p></div></li>
        <li><span>2</span><div><strong>Show the invite.</strong><p>Display the QR code or copy the transfer code.</p></div></li>
        <li><span>3</span><div><strong>Open GitVault on the new device.</strong><p>Choose Link New Device from onboarding or the add-device flow.</p></div></li>
        <li><span>4</span><div><strong>Scan or paste the invite.</strong><p>Enter the short PIN shown by the trusted device.</p></div></li>
        <li><span>5</span><div><strong>Name the device.</strong><p>The new device becomes trusted only after the invite is consumed successfully.</p></div></li>
      </ol>

      <h2>Device added outside Link New Device</h2>
      <p>If a device appears without the Link New Device flow, GitVault warns other trusted devices. Choose "I recognize this device" only when the device, time, and context match your own action. If not, remove the device and rotate the GitHub token.</p>

      <h2>Remove a device</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Open Settings, then Connected Devices.</strong><p>Use a trusted device that can sync.</p></div></li>
        <li><span>2</span><div><strong>Select remove for the device.</strong><p>The device is no longer trusted after this change syncs.</p></div></li>
        <li><span>3</span><div><strong>Rotate credentials when needed.</strong><p>If the removed device may be compromised, create a new GitHub token and revoke the old token.</p></div></li>
      </ol>

      <h2>When a removed device opens</h2>
      <p>When the removed device opens or checks trust, GitVault clears local sync access. The device must use Link New Device or the recovery flow before it can access synced data again.</p>
    `,
  },
  {
    slug: "recovery",
    title: "Recovery flows",
    category: "Recovery",
    applies: "Web and Android",
    summary: "Restore with trusted-device approval or recover after losing every trusted device with old and new GitHub tokens.",
    keywords: "recovery phrase trusted device approval old token new token lost all devices restore onboarding wait approval",
    headings: ["Recovery checklist", "Which recovery path to use", "Restore with another trusted device", "Restore after losing every trusted device", "After recovery succeeds", "What GitVault cannot recover"],
    excerpt:
      "Recovery starts with the normal trusted-device approval path. If no trusted device can answer, use recovery phrase plus old GitHub access and a newly generated GitHub token.",
    related: ["devices", "github-sync", "security", "troubleshooting"],
    body: `
      <p class="docs-lead">Recovery is deliberately stricter than normal device linking. It is for restoring access when setting up a device that was not linked from another trusted device.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/settings-about.png" alt="GitVault About settings and recovery-related information" loading="lazy">
        </div>
        <figcaption>After recovery, verify the app version and encryption details in Settings before trusting the restored setup.</figcaption>
      </figure>

      <h2>Recovery checklist</h2>
      <ul class="docs-list">
        <li><strong>Recovery phrase</strong> Required for restore. Keep it outside GitVault.</li>
        <li><strong>Current repository access</strong> Required to read the existing encrypted vault files.</li>
        <li><strong>Trusted-device approval</strong> Preferred when any trusted device is still available.</li>
        <li><strong>New GitHub token</strong> Required only for the lost-all-devices path.</li>
      </ul>

      <h2>Which recovery path to use</h2>
      <div class="docs-table-wrap">
        <table class="docs-table">
          <thead><tr><th>Situation</th><th>Use this flow</th><th>Why</th></tr></thead>
          <tbody>
            <tr><td>You still have an unlocked trusted device</td><td>Link New Device</td><td>Fastest and strongest confirmation because a trusted device creates the invite.</td></tr>
            <tr><td>You have a trusted device but are restoring from recovery</td><td>Recovery with trusted-device approval</td><td>The trusted device approves the recovery request.</td></tr>
            <tr><td>You lost every trusted device</td><td>Recovery phrase plus old and new GitHub token</td><td>The new token proves current GitHub account control when no device can approve.</td></tr>
          </tbody>
        </table>
      </div>

      <h2>Restore with another trusted device</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open GitVault on the new device.</strong><p>Choose restore from onboarding or the existing-vault path.</p></div></li>
        <li><span>2</span><div><strong>Connect the existing vault repository.</strong><p>Use the current repository and current token first.</p></div></li>
        <li><span>3</span><div><strong>Enter the recovery phrase.</strong><p>GitVault creates a recovery request and waits for another trusted device.</p></div></li>
        <li><span>4</span><div><strong>Approve from a trusted device.</strong><p>Open Settings, review the request, and approve only if the new device is yours.</p></div></li>
        <li><span>5</span><div><strong>Return to the new device.</strong><p>Wait for approval or use Check Approval, then verify vault data.</p></div></li>
      </ol>

      <h2>Restore after losing every trusted device</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Start the normal restore flow first.</strong><p>GitVault first waits for trusted-device approval.</p></div></li>
        <li><span>2</span><div><strong>Choose the new-token path only when no device can answer.</strong><p>This path is for lost-device recovery, not daily linking.</p></div></li>
        <li><span>3</span><div><strong>Create a new GitHub token.</strong><p>Create a new fine-grained token for the same private vault repository.</p></div></li>
        <li><span>4</span><div><strong>Provide the old and new access context.</strong><p>The old token proves access to existing vault storage. The new token proves current control of the GitHub account.</p></div></li>
        <li><span>5</span><div><strong>Complete recovery.</strong><p>Wait for GitVault to confirm that the vault can decrypt and sync.</p></div></li>
      </ol>

      <h2>After recovery succeeds</h2>
      <ul class="docs-list">
        <li><strong>Revoke old token</strong> Remove the old token from GitHub after the new token works.</li>
        <li><strong>Review devices</strong> Remove any old phone, browser, or machine you no longer control.</li>
        <li><strong>Run sync</strong> Confirm the recovered device uploads its current trusted state.</li>
      </ul>

      <h2>What GitVault cannot recover</h2>
      <p>GitVault cannot decrypt a vault without the required recovery material. Keep recovery phrase storage independent from your GitVault vault.</p>
    `,
  },
  {
    slug: "install-update",
    title: "Install and update",
    category: "Operations",
    applies: "Web and Android",
    summary: "Open the web app, install Android APKs, verify release assets, and understand version updates.",
    keywords: "install update apk universal abi sha256 release tag github pages web app version android",
    headings: ["Web app", "Android APK", "Release assets", "Verify the version", "Upgrade habits"],
    excerpt:
      "The web app is served at /app/ and the Android APK is published on GitHub Releases. The visible version is derived from the release tag.",
    related: ["release-verification", "platform-support", "quick-start", "github-sync", "troubleshooting"],
    body: `
      <p class="docs-lead">Use the web app for browser access and GitHub Releases for Android APK downloads.</p>

      <h2>Web app</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Open the app.</strong><p>Go to <a class="docs-inline-link" href="/app/">gitvault.giofahreza.com/app/</a>.</p></div></li>
        <li><span>2</span><div><strong>Unlock or onboard.</strong><p>Existing browsers unlock locally. New browsers must create, link, or restore a vault.</p></div></li>
        <li><span>3</span><div><strong>Check Settings.</strong><p>The web version should match the latest deployed release tag after GitHub Pages updates.</p></div></li>
      </ol>

      <h2>Android APK</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Open GitHub Releases.</strong><p>Use <a class="docs-inline-link" href="https://github.com/giofahreza/gitvault/releases/latest">the latest release</a>.</p></div></li>
        <li><span>2</span><div><strong>Download the universal APK.</strong><p><code>gitvault-vX.Y.Z-universal.apk</code> works on most devices.</p></div></li>
        <li><span>3</span><div><strong>Allow APK installation.</strong><p>Enable install from unknown sources for the browser or file manager you use.</p></div></li>
        <li><span>4</span><div><strong>Open GitVault.</strong><p>Existing installs should keep local data. New installs must link or restore.</p></div></li>
      </ol>

      <h2>Release assets</h2>
      <ul class="docs-list">
        <li><strong>Universal APK</strong> Easiest Android download and recommended for most users.</li>
        <li><strong>ABI APKs</strong> Smaller downloads for specific device CPU architectures.</li>
        <li><strong>SHA256SUMS.txt</strong> Checksums for verifying release downloads.</li>
      </ul>

      <div class="docs-note">
        <strong>Verify downloads before installing on a high-value device.</strong>
        <p>Use the <a class="docs-inline-link" href="/docs/release-verification/">release verification guide</a> when you download an APK outside a trusted browser session.</p>
      </div>

      <h2>Verify the version</h2>
      <p>Open Settings, then About. The app version should match the release tag after the web or APK build has been deployed.</p>

      <h2>Upgrade habits</h2>
      <ul class="docs-list">
        <li><strong>Sync first</strong> Run sync before upgrading a device with important unsynced edits.</li>
        <li><strong>Keep recovery available</strong> Confirm the recovery phrase is available before replacing phones or browsers.</li>
        <li><strong>Wait for Pages</strong> Web deployment can lag a release while GitHub Pages finishes deploying.</li>
      </ul>
    `,
  },
  {
    slug: "release-verification",
    title: "Release verification",
    category: "Operations",
    applies: "Android and web release checks",
    summary: "Verify APK checksums, release assets, and deployed web version before trusting an update.",
    keywords: "release verification apk sha256 checksum sha256sums version tag github releases web pages verify download",
    headings: ["What to verify", "Verify an APK checksum", "Windows checksum", "macOS or Linux checksum", "Verify the web app", "When verification fails"],
    excerpt:
      "Use SHA256SUMS.txt from the same GitHub release to verify an APK download, then check the in-app version against the release tag after installing or opening the web app.",
    related: ["install-update", "platform-support", "security", "faq", "troubleshooting"],
    body: `
      <p class="docs-lead">Verification is optional for casual testing, but it is a good habit before installing an APK that will hold real secrets.</p>

      <figure class="docs-figure">
        <div class="docs-figure-frame">
          <img src="/screenshots/settings-about.png" alt="GitVault About settings showing app and encryption details" loading="lazy">
        </div>
        <figcaption>After installing or opening the app, confirm the visible version in Settings matches the release you expected.</figcaption>
      </figure>

      <h2>What to verify</h2>
      <ul class="docs-list">
        <li><strong>Same release</strong> Download the APK and <code>SHA256SUMS.txt</code> from the same GitHub release page.</li>
        <li><strong>Correct filename</strong> Compare the checksum line for the exact APK file you installed.</li>
        <li><strong>Visible version</strong> Check Settings, then About, after install or web deployment.</li>
        <li><strong>Recovery available</strong> Confirm recovery material is available before replacing a phone or browser profile.</li>
      </ul>

      <h2>Verify an APK checksum</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Download release assets.</strong><p>Download <code>gitvault-vX.Y.Z-universal.apk</code> and <code>SHA256SUMS.txt</code> from the same release.</p></div></li>
        <li><span>2</span><div><strong>Calculate the APK hash.</strong><p>Use the command for your desktop OS, or an Android terminal app if you verify directly on the phone.</p></div></li>
        <li><span>3</span><div><strong>Compare exactly.</strong><p>The calculated SHA-256 value must match the checksum line for that APK filename.</p></div></li>
        <li><span>4</span><div><strong>Install only after a match.</strong><p>If the values differ, delete the file and download again from GitHub Releases.</p></div></li>
      </ol>

      <h2>Windows checksum</h2>
      <pre><code>certutil -hashfile gitvault-vX.Y.Z-universal.apk SHA256</code></pre>

      <h2>macOS or Linux checksum</h2>
      <pre><code>sha256sum gitvault-vX.Y.Z-universal.apk
cat SHA256SUMS.txt</code></pre>

      <h2>Verify the web app</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Open <a class="docs-inline-link" href="/app/">/app/</a>.</strong><p>Use the deployed web app URL, not a stale local build.</p></div></li>
        <li><span>2</span><div><strong>Open Settings, then About.</strong><p>The version should match the latest release tag after GitHub Pages finishes deploying.</p></div></li>
        <li><span>3</span><div><strong>Reload if needed.</strong><p>If the old version remains, wait for Pages deployment and reload the browser tab.</p></div></li>
      </ol>

      <h2>When verification fails</h2>
      <ul class="docs-list">
        <li><strong>Checksum mismatch</strong> Delete the APK and download it again from the release page.</li>
        <li><strong>Missing APK</strong> Wait for the release workflow to finish, then refresh the release page.</li>
        <li><strong>Old web version</strong> Check GitHub Pages deployment status and reload after the deploy completes.</li>
      </ul>
    `,
  },
  {
    slug: "faq",
    title: "FAQ and common mistakes",
    category: "Troubleshooting",
    applies: "Web and Android",
    summary: "Answers for common setup, sync, device trust, recovery, autofill, and release questions.",
    keywords: "faq common mistakes github token device alert recognize link device restore recovery autofill checksum web version pin throttling",
    headings: ["Setup", "Sync", "Devices", "Recovery", "Autofill", "Updates", "Security"],
    excerpt:
      "Common GitVault mistakes include using the wrong token permission, skipping the recovery phrase, recognizing an unknown device too quickly, and expecting Android autofill before selecting GitVault as provider.",
    related: ["quick-start", "github-sync", "devices", "recovery", "release-verification", "troubleshooting"],
    body: `
      <p class="docs-lead">Use this page when something feels confusing but not fully broken. It collects the mistakes users are most likely to hit during first setup and multi-device use.</p>

      <section class="docs-faq" aria-labelledby="setup-faq">
        <h2 id="setup-faq">Setup</h2>
        <details open>
          <summary>Do I need a business account or verification?</summary>
          <p>No. GitVault sync needs a normal GitHub account, a private repository, and a fine-grained token scoped to that repository.</p>
        </details>
        <details>
          <summary>Can I use GitVault without GitHub sync?</summary>
          <p>Yes, but the vault stays local to that device. Use GitHub sync when you want encrypted backup, device linking, or restore from another device.</p>
        </details>
        <details>
          <summary>Can GitVault recover my vault if I lose the phrase?</summary>
          <p>No. GitVault cannot decrypt the vault without the recovery material and valid access flow.</p>
        </details>
      </section>

      <section class="docs-faq" aria-labelledby="sync-faq">
        <h2 id="sync-faq">Sync</h2>
        <details open>
          <summary>Why does sync fail right after I paste a GitHub token?</summary>
          <p>The most common cause is token scope. Use a fine-grained token for the exact private repository with Metadata read and Contents read/write permissions.</p>
        </details>
        <details>
          <summary>Does GitHub see my passwords or notes?</summary>
          <p>No. GitVault encrypts vault data before upload. GitHub stores encrypted files, not readable secrets.</p>
        </details>
        <details>
          <summary>Why does a change show on one device but not another?</summary>
          <p>Sync the source device first, then sync the target device. If both devices edited the same item offline, the newest synced item version wins.</p>
        </details>
      </section>

      <section class="docs-faq" aria-labelledby="devices-faq">
        <h2 id="devices-faq">Devices</h2>
        <details open>
          <summary>Why did I get an alert even though the device is mine?</summary>
          <p>The device may have appeared outside the Link New Device invite flow, or the trusted state may not have synced yet. Recognize it only if the timing and device match your own action, then sync.</p>
        </details>
        <details>
          <summary>Why is another device missing from the list?</summary>
          <p>That device must link, restore, and sync before other devices can see it. Open GitVault on that device and run sync after setup.</p>
        </details>
        <details>
          <summary>Does removing a device erase its local storage immediately?</summary>
          <p>It is marked untrusted after the removal syncs. When that device opens or checks trust with network access, GitVault clears local sync access and requires linking or recovery again.</p>
        </details>
      </section>

      <section class="docs-faq" aria-labelledby="recovery-faq">
        <h2 id="recovery-faq">Recovery</h2>
        <details open>
          <summary>Should I link or restore a new phone?</summary>
          <p>Use Link New Device when a trusted device is still available. Use Restore Device when you are setting up from recovery instead of a trusted invite.</p>
        </details>
        <details>
          <summary>Why do lost-device recovery steps ask for a new GitHub token?</summary>
          <p>If no trusted device can approve the request, a newly generated token for the same repository proves current GitHub account control.</p>
        </details>
        <details>
          <summary>When should I revoke the old token?</summary>
          <p>After recovery succeeds and GitVault confirms sync works with the new token.</p>
        </details>
      </section>

      <section class="docs-faq" aria-labelledby="autofill-faq">
        <h2 id="autofill-faq">Autofill</h2>
        <details open>
          <summary>Why does Android autofill not appear?</summary>
          <p>GitVault must be selected as the Android autofill provider. If a browser or app still does not show it, try Chrome or use GitVault Keyboard.</p>
        </details>
        <details>
          <summary>Does web support system autofill?</summary>
          <p>No. System-wide autofill is an Android integration. The web app supports vault use in the browser.</p>
        </details>
      </section>

      <section class="docs-faq" aria-labelledby="updates-faq">
        <h2 id="updates-faq">Updates</h2>
        <details open>
          <summary>Why is the web version still old?</summary>
          <p>GitHub Pages deployment can lag the release tag. Wait for Pages to finish, then reload the web app.</p>
        </details>
        <details>
          <summary>Why is there no APK on a new release?</summary>
          <p>The release workflow may still be running. Refresh after the APK build job finishes, then verify the asset with <code>SHA256SUMS.txt</code>.</p>
        </details>
      </section>

      <section class="docs-faq" aria-labelledby="security-faq">
        <h2 id="security-faq">Security</h2>
        <details open>
          <summary>What should I do after an unexpected device alert?</summary>
          <p>Do not recognize it. Remove the device if it appears in Connected Devices, create a new GitHub token, update trusted devices, and revoke the old token.</p>
        </details>
        <details>
          <summary>Why is PIN input delayed?</summary>
          <p>Wrong attempts can trigger throttling. Wait for the timer, then enter the full PIN. On web, use the physical keyboard.</p>
        </details>
      </section>
    `,
  },
  {
    slug: "troubleshooting",
    title: "Troubleshooting",
    category: "Troubleshooting",
    applies: "Web and Android",
    summary: "Diagnose sync, token, unlock, device, autofill, biometric, web version, and Android issues in order.",
    keywords: "troubleshooting sync token device pin biometric autofill alert web android version github pages diagnostics",
    headings: ["Diagnostic order", "Common problems", "Autofill checks", "Device trust checks", "When to rotate a token"],
    excerpt:
      "Start with unlock and internet, then check repository and token permissions, source-device sync, target-device sync, device trust, and platform-specific settings.",
    related: ["sync-behavior", "github-sync", "devices", "autofill-keyboard"],
    body: `
      <p class="docs-lead">Work from the simplest local cause to the broader sync cause. This order prevents chasing device trust when the problem is just unlock, network, or token access.</p>

      <h2>Diagnostic order</h2>
      <ol class="docs-steps">
        <li><span>1</span><div><strong>Unlock first.</strong><p>Confirm the vault unlocks with PIN or biometric. Wait out throttling after wrong PIN attempts.</p></div></li>
        <li><span>2</span><div><strong>Check internet.</strong><p>GitHub sync and device approvals need network access.</p></div></li>
        <li><span>3</span><div><strong>Check GitHub repository and token.</strong><p>Verify owner, repository name, token expiry, and Contents read/write permission.</p></div></li>
        <li><span>4</span><div><strong>Sync the source device.</strong><p>The device that made the change must upload it first.</p></div></li>
        <li><span>5</span><div><strong>Sync the target device.</strong><p>The other device must download the change after the source upload succeeds.</p></div></li>
        <li><span>6</span><div><strong>Check device trust.</strong><p>Open Connected Devices if a device cannot access data or alerts keep appearing.</p></div></li>
        <li><span>7</span><div><strong>Check platform-specific settings.</strong><p>Autofill, keyboard, biometric, and recent-app privacy depend on OS or browser support.</p></div></li>
      </ol>

      <h2>Common problems</h2>
      <div class="docs-table-wrap">
        <table class="docs-table">
          <thead><tr><th>Problem</th><th>Likely cause</th><th>What to do</th></tr></thead>
          <tbody>
            <tr><td>Sync fails</td><td>Network, repository, token, or permission problem.</td><td>Check internet access, repository name, token expiry, and Contents read/write permission.</td></tr>
            <tr><td>PIN input is delayed</td><td>Wrong attempts triggered throttling.</td><td>Wait for the timer, then type the full PIN with the keyboard on web.</td></tr>
            <tr><td>Device is not listed</td><td>The device has not linked, restored, or synced yet.</td><td>Open GitVault on that device and run sync after setup.</td></tr>
            <tr><td>Device alert keeps returning</td><td>The trusted state has not synced everywhere yet.</td><td>Sync the device where you recognized it, then sync the other devices.</td></tr>
            <tr><td>New device cannot access data</td><td>It was removed or is not trusted.</td><td>Use Link New Device from a trusted device, or restore with recovery and valid GitHub token flow.</td></tr>
            <tr><td>Biometric unlock unavailable</td><td>The browser or device does not expose biometric support.</td><td>Use PIN unlock, or try a supported browser/device.</td></tr>
            <tr><td>Web version looks old</td><td>GitHub Pages or browser cache has not refreshed.</td><td>Wait for Pages deployment, then reload the app. The app also clears old service-worker caches.</td></tr>
          </tbody>
        </table>
      </div>

      <h2>Autofill checks</h2>
      <ol class="docs-steps compact">
        <li><span>1</span><div><strong>Confirm GitVault is selected.</strong><p>Set GitVault as the Android autofill service.</p></div></li>
        <li><span>2</span><div><strong>Try Chrome.</strong><p>Some vendor browsers restrict third-party autofill providers.</p></div></li>
        <li><span>3</span><div><strong>Use GitVault Keyboard.</strong><p>Switch keyboards when the target app does not trigger autofill.</p></div></li>
      </ol>

      <h2>Device trust checks</h2>
      <ul class="docs-list">
        <li><strong>Linked but missing</strong> Run sync on the linked device, then sync the device you are checking from.</li>
        <li><strong>Recognized but still alerting</strong> Sync the recognizing device first. If alerts continue after sync, remove the device and link it again.</li>
        <li><strong>Removed device still opens</strong> Open it with network access so revocation can be detected and local sync access can be cleared.</li>
      </ul>

      <h2>When to rotate a token</h2>
      <p>Rotate the GitHub token when a device is lost, a token may be exposed, or an unknown device alert does not match your own activity.</p>
    `,
  },
];

const pageBySlug = Object.fromEntries(pages.map((page) => [page.slug, page]));

function pageHref(slug) {
  return slug ? `/docs/${slug}/` : "/docs/";
}

function categoryHref(slug) {
  return `/docs/category/${slug}/`;
}

function navLink(page, currentPath) {
  const href = pageHref(page.slug);
  const active = currentPath === href ? ' aria-current="page" class="is-active"' : "";
  return `<a href="${href}" data-title="${escapeAttr(page.title)}" data-category="${escapeAttr(page.category)}" data-summary="${escapeAttr(page.summary)}" data-keywords="${escapeAttr(page.keywords)}"${active}>
                <span>${page.title}</span>
                <small>${page.summary}</small>
              </a>`;
}

function topicLink(topic, currentPath) {
  const href = categoryHref(topic.slug);
  const active = currentPath === href ? ' aria-current="page" class="is-active"' : "";
  return `<a href="${href}" data-title="${escapeAttr(topic.title)}" data-category="Topic" data-summary="${escapeAttr(topic.summary)}" data-keywords="${escapeAttr(topic.slug)}"${active}><span>${topic.title}</span><small>${topic.summary}</small></a>`;
}

function docsNav(currentPath) {
  const homeActive = currentPath === "/docs/" ? ' is-active" aria-current="page"' : '"';
  const groups = primaryGroups
    .map((group) => {
      const links = group.pages.map((slug) => navLink(pageBySlug[slug], currentPath)).join("\n\n              ");
      return `<div class="docs-nav-group">
              <p class="docs-toc-label">${group.label}</p>

              ${links}
            </div>`;
    })
    .join("\n\n            ");

  const topics = topicGroups.map((topic) => topicLink(topic, currentPath)).join("\n");

  return `<aside class="docs-toc" aria-label="Docs pages">
          <label class="docs-search" for="docs-search">
            <span>Search docs</span>
            <input id="docs-search" type="search" autocomplete="off" placeholder="Search docs">
          </label>
          <div id="docs-search-results" class="docs-search-results" aria-live="polite"></div>
          <a class="docs-home-link${homeActive} href="/docs/">Docs home</a>

            ${groups}

          <div class="docs-nav-group docs-nav-group-compact">
            <p class="docs-toc-label">Browse topics</p>
            ${topics}
          </div>
        </aside>`;
}

function pageMeta(page) {
  return `<dl class="docs-meta">
              <div><dt>Type</dt><dd>${page.category}</dd></div>
              <div><dt>Applies to</dt><dd>${page.applies}</dd></div>
              <div><dt>Updated</dt><dd>${UPDATED}</dd></div>
            </dl>`;
}

function relatedSection(page) {
  if (!page.related?.length) {
    return "";
  }

  const links = page.related
    .map((slug) => {
      const related = pageBySlug[slug];
      return `<li><a href="${pageHref(slug)}">${related.title}</a> - ${related.summary}</li>`;
    })
    .join("\n              ");

  return `<section class="docs-related" aria-labelledby="see-also">
            <h2 id="see-also">See also</h2>
            <ul class="docs-link-list">
              ${links}
            </ul>
          </section>`;
}

function layout({ title, description, canonical, currentPath, articleClass = "", slug = "", headingCategory, meta, body }) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="dark">
    <meta name="description" content="${escapeAttr(description)}">
    <title>${title} - GitVault Docs</title>
    <link rel="icon" type="image/jpeg" href="/assets/icon/gitvault_new.jpeg">
    <link rel="canonical" href="${canonical}">
    <link rel="stylesheet" href="/docs.css?v=${VERSION}">
  </head>
  <body>
    <a class="skip-link" href="#docs-content">Skip to docs content</a>

    <header class="site-header">
      <div class="site-header-inner">
        <a class="brand" href="/" aria-label="GitVault home">
          <img src="/assets/icon/gitvault_new.jpeg" alt="" width="30" height="30">
          <span>GitVault</span>
        </a>
        <nav aria-label="Site navigation">
          <a href="/">Home</a>
          <a href="/#vault">Vault</a>
          <a href="/#sync">Sync</a>
          <a href="/docs/" aria-current="page">Docs</a>
          <a href="https://github.com/giofahreza/gitvault">GitHub</a>
          <a class="nav-action" href="/app/">Open App</a>
        </nav>
      </div>
    </header>

    <main class="docs-page-shell">
      <div class="docs-layout">
        ${docsNav(currentPath)}

        <article id="docs-content" class="docs-content docs-article${articleClass ? ` ${articleClass}` : ""}" data-page-slug="${slug}">
          <div class="docs-heading">
            <p class="eyebrow">${headingCategory}</p>
            <h1>${title}</h1>
            ${meta}
          </div>

          ${body}
        </article>

        <aside class="docs-on-page" aria-label="On this page">
          <p class="docs-toc-label">On this page</p>
          <nav id="on-this-page"></nav>
        </aside>
      </div>
    </main>

    <footer class="site-footer">
      <span>GitVault Docs</span>
      <span><a href="https://github.com/giofahreza/gitvault">github.com/giofahreza/gitvault</a></span>
    </footer>
    <script src="/docs.js?v=${VERSION}" defer></script>
  </body>
</html>
`;
}

function docsHomeBody() {
  const categorySections = primaryGroups
    .map((group) => {
      const categorySlug = slugify(group.label);
      const links = group.pages
        .map((slug) => {
          const page = pageBySlug[slug];
          return `<li><a href="${pageHref(slug)}">${page.title}</a> - ${page.summary}</li>`;
        })
        .join("\n                ");

      return `<section class="docs-category" aria-labelledby="category-${categorySlug}">
              <h3 id="category-${categorySlug}"><a href="${categoryHref(categorySlug)}">${group.label}</a></h3>
              <p>${categoryIntro(group.label)}</p>
              <ul class="docs-link-list">
                ${links}
              </ul>
            </section>`;
    })
    .join("\n\n            ");

  const topicLinks = topicGroups
    .map((topic) => `<li><a href="${categoryHref(topic.slug)}"><span>${topic.title}</span><small>${topic.summary}</small></a></li>`)
    .join("\n              ");

  return `
          <p class="docs-lead">
            GitVault is an open source password manager for end users who want encrypted storage without a hosted backend. Your vault is encrypted on the device, then synced as ciphertext to your own private GitHub repository.
          </p>

          <section aria-labelledby="what-is-gitvault">
            <h2 id="what-is-gitvault">What is GitVault</h2>
            <p>GitVault stores passwords, private notes, TOTP authenticator secrets, and SSH credentials. It runs on the web and Android, and uses connected-device flows to keep trusted devices aligned.</p>
            <div class="docs-grid">
              <article>
                <h3>End-user setup</h3>
                <p>No business verification or hosted service account is required. A normal GitHub account and private repository are enough for sync.</p>
              </article>
              <article>
                <h3>Local-first vault</h3>
                <p>Secrets are encrypted before sync. GitHub stores vault files, not readable passwords, notes, or recovery data.</p>
              </article>
              <article>
                <h3>Web and Android</h3>
                <p>Use the web app on desktop, Android APK on mobile, and device linking to keep trusted devices aligned.</p>
              </article>
              <article>
                <h3>Recovery owned by you</h3>
                <p>The recovery phrase and GitHub token access are what let you restore a vault. GitVault cannot recover secrets without them.</p>
              </article>
            </div>
          </section>

          <section class="docs-overview" aria-labelledby="common-tasks">
            <h2 id="common-tasks">Common tasks</h2>
            <ul class="docs-page-list compact">
              <li><a href="/docs/quick-start/"><span>Quick start</span><small>Create your vault, save recovery, set a PIN, add an item, and connect sync.</small></a></li>
              <li><a href="/docs/github-sync/"><span>GitHub sync setup</span><small>Create private encrypted storage with a fine-grained token.</small></a></li>
              <li><a href="/docs/devices/"><span>Add or remove devices</span><small>Use Link New Device, recognize trusted devices, and remove devices you no longer trust.</small></a></li>
              <li><a href="/docs/recovery/"><span>Restore access</span><small>Recover with another trusted device or the lost-device new-token path.</small></a></li>
              <li><a href="/docs/autofill-keyboard/"><span>Set up Android autofill</span><small>Enable the system autofill provider and GitVault Keyboard fallback.</small></a></li>
              <li><a href="/docs/troubleshooting/"><span>Fix common issues</span><small>Resolve sync, token, unlock, device, autofill, and biometric problems.</small></a></li>
            </ul>
          </section>

          <section aria-labelledby="documentation-map">
            <h2 id="documentation-map">Documentation map</h2>
            ${categorySections}
          </section>

          <section aria-labelledby="browse-topics">
            <h2 id="browse-topics">Browse topics</h2>
            <ul class="docs-page-list compact">
              ${topicLinks}
            </ul>
          </section>

          <section aria-labelledby="release-status">
            <h2 id="release-status">Release and status</h2>
            <p>Use <a class="docs-inline-link" href="https://github.com/giofahreza/gitvault/releases/latest">GitHub Releases</a> for Android APKs and <a class="docs-inline-link" href="/app/">/app/</a> for the web app. Static docs deploy from the same repository through GitHub Pages.</p>
          </section>
  `;
}

function categoryIntro(label) {
  return {
    Tutorials: "First-run paths from empty vault to synced vault.",
    "How-to guides": "Task-oriented procedures for daily vault use.",
    Reference: "Stable behavior, support, security, settings, and sync details.",
    Recovery: "Ways to restore access and regain trusted-device status.",
    Operations: "Install, update, release, and verification procedures.",
    Troubleshooting: "Symptom-led diagnosis and recovery checks.",
  }[label] || "Related GitVault documentation pages.";
}

function categoryPage(category) {
  const links = category.pages
    .map((slug) => {
      const page = pageBySlug[slug];
      return `<li><a href="${pageHref(slug)}"><span>${page.title}</span><small>${page.summary}</small></a></li>`;
    })
    .join("\n              ");

  const body = `
          <p class="docs-lead">${category.summary || categoryIntro(category.title)}</p>
          <section aria-labelledby="pages-in-${category.slug}">
            <h2 id="pages-in-${category.slug}">Pages in this category</h2>
            <ul class="docs-page-list compact">
              ${links}
            </ul>
          </section>
  `;

  return layout({
    title: category.title,
    description: category.summary || categoryIntro(category.title),
    canonical: `https://gitvault.giofahreza.com${categoryHref(category.slug)}`,
    currentPath: categoryHref(category.slug),
    slug: `category-${category.slug}`,
    headingCategory: "Docs category",
    meta: `<dl class="docs-meta"><div><dt>Category</dt><dd>${category.title}</dd></div><div><dt>Pages</dt><dd>${category.pages.length}</dd></div><div><dt>Updated</dt><dd>${UPDATED}</dd></div></dl>`,
    body,
  });
}

function escapeAttr(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function slugify(value) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

function write(relativePath, content) {
  const target = join(DOCS_ROOT, relativePath);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content.replace(/[ \t]+$/gm, ""));
}

write(
  "index.html",
  layout({
    title: "Documentation",
    description:
      "GitVault documentation for setup, GitHub sync, passwords, notes, 2FA codes, SSH credentials, connected devices, recovery, and troubleshooting.",
    canonical: "https://gitvault.giofahreza.com/docs/",
    currentPath: "/docs/",
    articleClass: "docs-index-page",
    slug: "",
    headingCategory: "Product documentation",
    meta: `<dl class="docs-meta"><div><dt>Product</dt><dd>GitVault</dd></div><div><dt>Applies to</dt><dd>Web and Android</dd></div><div><dt>Updated</dt><dd>${UPDATED}</dd></div></dl>`,
    body: docsHomeBody(),
  }),
);

for (const page of pages) {
  write(
    `${page.slug}/index.html`,
    layout({
      title: page.title,
      description: page.summary,
      canonical: `https://gitvault.giofahreza.com${pageHref(page.slug)}`,
      currentPath: pageHref(page.slug),
      slug: page.slug,
      headingCategory: page.category,
      meta: pageMeta(page),
      body: `${page.body}\n\n          ${relatedSection(page)}`,
    }),
  );
}

const categoryRecords = [
  ...primaryGroups.map((group) => ({
    slug: slugify(group.label),
    title: group.label,
    summary: categoryIntro(group.label),
    pages: group.pages,
  })),
  ...topicGroups,
];

for (const category of categoryRecords) {
  write(`category/${category.slug}/index.html`, categoryPage(category));
}

write(
  "search-index.json",
  JSON.stringify(
    {
      pages: [
        {
          title: "Docs home",
          category: "Overview",
          summary: "GitVault documentation home and common tasks.",
          keywords: "documentation overview home common tasks",
          headings: ["What is GitVault", "Common tasks", "Documentation map", "Browse topics", "Release and status"],
          excerpt: "Start from GitVault documentation home to find setup, sync, devices, recovery, and troubleshooting pages.",
          href: "/docs/",
        },
        ...pages.map((page) => ({
          title: page.title,
          category: page.category,
          summary: page.summary,
          keywords: page.keywords,
          headings: page.headings,
          excerpt: page.excerpt,
          href: pageHref(page.slug),
        })),
        ...categoryRecords.map((category) => ({
          title: category.title,
          category: "Topic",
          summary: category.summary || categoryIntro(category.title),
          keywords: `${category.slug} ${category.title}`,
          headings: ["Pages in this category"],
          excerpt: (category.pages || []).map((slug) => pageBySlug[slug]?.title).filter(Boolean).join(", "),
          href: categoryHref(category.slug),
        })),
      ],
    },
    null,
    2,
  ) + "\n",
);
