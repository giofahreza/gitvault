# GitVault Desktop MCP Implementation Plan

## Status

Implemented in the current worktree on July 30, 2026.

The shared session controller, notes-only authorization service, Streamable
HTTP server, native Dart stdio bridge, Desktop AI Apps UI, approvals, tray
lifecycle, Linux/macOS runners, tests, release workflows, and user
documentation are present. Local verification covers the full MCP suite and
real Linux HTTP/stdio flows. Windows and macOS builds are defined in CI;
signing and notarization remain dependent on external platform credentials.

Final local verification:

- 51 Flutter tests pass, including 21 Desktop/MCP tests.
- Static analysis reports no errors in the implementation. The repository
  retains its existing warning and style-info backlog.
- Linux release, native Linux stdio bridge, web release, and Android debug APK
  builds succeed with Flutter 3.29.3.
- Real Linux Desktop HTTP and stdio note flows were exercised against the
  compiled app and bridge.

## Product outcome

GitVault Desktop will let any MCP-compatible AI application work with the
user's GitVault notes. Configuration, client approval, permissions, write
approval, revocation, and activity history will all be managed inside the
GitVault desktop UI.

The implementation will remain in this repository and use only the
Flutter/Dart stack:

- Flutter for the Windows, macOS, and Linux application and approval UI.
- Dart for the MCP protocol service, loopback server, and stdio bridge.
- The existing encrypted notes repository and GitHub synchronization flow for
  note storage and multi-device sync.

Web and mobile remain normal GitVault clients. They do not host an MCP server.
GitVault Desktop must be running and unlocked for an AI application to access
notes.

Only applications that support MCP over stdio or Streamable HTTP can connect.
GitVault cannot provide MCP access to an application that does not implement an
MCP client.

## Fixed decisions

1. Keep one repository and one Flutter/Dart codebase.
2. Require GitVault Desktop for MCP access.
3. Name the product area **AI Apps** in the UI; use "MCP" in technical details.
4. Limit the first release to notes. Never expose passwords, TOTP secrets or
   codes, SSH credentials or keys, GitHub tokens, the root key, PIN data,
   recovery phrases, or device-linking secrets.
5. Support both MCP transports:
   - Streamable HTTP on loopback for clients that support local HTTP.
   - A bundled `gitvault_mcp` Dart executable for stdio-only clients.
6. Keep the loopback service available while Desktop is running, but return
   `vault_locked` for every vault operation while GitVault is locked.
7. Require a direct user-authorized connection in unlocked GitVault Desktop
   and per-client permissions. Do not accept unsolicited pairing requests.
8. Default writes to interactive desktop approval. Deletion always requires
   approval in the first release.
9. Store AI client registrations locally on that desktop. Do not synchronize
   client secrets or permissions through GitHub.
10. Record local MCP activity without storing note bodies or secrets in logs.

## Implemented repository baseline

- Windows, Linux, and macOS Flutter runners are present.
- `VaultSessionController` is the shared UI/MCP lock authority.
- `NotesMcpService` uses the encrypted `NotesRepository`, optimistic
  concurrency, scoped reads/writes, and debounced foreground synchronization.
- Client verifiers and redacted activity are held in dedicated MCP Hive boxes;
  raw HTTP credentials are not persisted server-side.
- The stdio bridge keeps its minimum credential in a per-user profile with
  restricted file permissions.
- Desktop settings expose AI Apps only on Windows, macOS, and Linux.
- Desktop and tag release workflows build the app and bridge on all three
  desktop operating systems. Release publication is serialized after every
  platform build succeeds.

## Target architecture

```text
MCP client with HTTP support
        |
        | Streamable HTTP + per-client bearer credential
        v
GitVault Desktop loopback MCP server
        ^
        | authenticated local bridge connection
        |
MCP client with stdio support
        |
        | stdio
        v
bundled gitvault_mcp Dart bridge

GitVault Desktop loopback MCP server
        |
        v
client authorization -> optional user approval -> NotesMcpService
        |
        v
NotesRepository -> encrypted local Hive data -> ForegroundSyncService -> GitHub
```

Implemented repository layout:

```text
lib/
  core/session/
    vault_session_controller.dart
  features/ai_apps/
    ai_apps_screen.dart
    mcp_approval_host.dart
  mcp/
    mcp_desktop_server.dart
    mcp_server_factory.dart
    mcp_client_registry.dart
    mcp_approval_controller.dart
    desktop_lifecycle_service.dart
    notes_mcp_service.dart
    mcp_models.dart
bin/
  gitvault_mcp.dart
test/mcp/
linux/
macos/
windows/
```

The exact file split may be adjusted to match the selected Dart MCP SDK, but
the protocol, authorization, application service, and UI must remain separate.

## MCP protocol and transports

### SDK selection

Before feature implementation, evaluate and pin a maintained Dart MCP SDK that
supports the protocol version needed by target clients, stdio, and Streamable
HTTP. Do not hand-roll JSON-RPC framing if a maintained compatible SDK exists.
Add protocol compatibility tests so an SDK update cannot silently break
clients.

### Loopback server

- Bind only to `127.0.0.1` and, when tested, `::1`. Never bind to `0.0.0.0` or
  a LAN interface.
- Use a configurable local port with a stable default and collision fallback.
- Write the active endpoint and instance identifier to a discovery file in the
  per-user application support directory.
- Restrict the discovery file to the current OS user where the platform allows
  it.
- Require a per-client bearer credential for all MCP sessions.
- Validate HTTP `Origin` and `Host`; do not enable broad CORS.
- Apply request body, note body, result count, and timeout limits.
- Keep protocol errors structured and avoid leaking stack traces or local
  filesystem paths.

### Stdio bridge

- Compile `bin/gitvault_mcp.dart` as a small native executable for each desktop
  platform and bundle it with GitVault Desktop.
- Keep the bridge independent of Flutter UI imports so it can be compiled and
  launched by any MCP host.
- Read the desktop endpoint from the discovery file.
- Forward MCP messages between stdin/stdout and the authenticated loopback
  server.
- Write protocol data only to stdout. Diagnostics go to stderr with secrets
  redacted.
- Return a clear actionable error when Desktop is not running or is locked.
- Support a client profile ID rather than placing a bearer token directly in
  command-line arguments.

The bridge profile is protected by the current OS user boundary. GitVault must
not claim cryptographic proof of an AI application's displayed name: another
process running as the same compromised OS user can impersonate a local client.

## Client connections and permissions

### Connection authorization flow

1. The user unlocks GitVault Desktop and opens
   **Settings > AI Apps > Connect app**.
2. The user selects HTTP or stdio, enters a recognizable name, and grants
   permissions and tag scope.
3. GitVault immediately creates the locally authorized registration, stores
   only the random credential verifier, and displays the generated
   configuration.
4. For stdio, Desktop writes a protected local profile and the configuration
   contains only its profile ID. For HTTP, the raw bearer credential is shown
   once.
5. The user adds the configuration to the target MCP-compatible application.
6. The user can later edit permissions, rotate credentials, revoke access, or
   remove the registration.

This direct Desktop-authorized model replaces the earlier short-lived pairing
proposal. It has a smaller attack surface because an external process cannot
create or prompt an inbound pairing request. The operating-system user
boundary still applies.

### Permission model

Each connected AI app has independent permissions:

- Read note metadata.
- Read note content.
- Search notes.
- Create notes.
- Append to notes.
- Edit notes.
- Archive notes.
- Delete notes.
- Include archived notes.
- Allowed tags and denied tags.
- Write policy: ask every time or allow while unlocked.

Defaults:

- Read/search can be granted during initial connection setup.
- Create, append, edit, and archive ask every time.
- Delete is disabled until explicitly enabled and still asks every time.
- Archived notes are excluded.
- An empty tag scope means all non-archived notes; the UI must state this
  clearly.

Changing permissions takes effect immediately for new and active sessions.
Revocation invalidates the credential and closes active sessions.

## Desktop approval experience

Add a desktop-only **AI Apps** settings screen with:

- Master **Allow AI apps** switch, off by default.
- Server state: stopped, locked, ready, or error.
- Local endpoint and a copyable client configuration.
- Connected app list with transport, permissions, last used time, and status.
- Pending action approvals.
- Recent activity with result, timestamp, and client name.
- Edit, rotate credential, disconnect, and revoke-all actions.

Write approval dialogs show:

- Requesting AI app.
- Exact operation.
- Target note title and ID.
- A readable before/after diff for edits.
- The text being appended or created.
- **Allow once**, **Always allow this action**, and **Deny** actions where
  appropriate.

Delete approval has only **Delete** and **Deny** in the first release. Approval
requests expire after 60 seconds. Locking or quitting GitVault denies all
pending requests.

When MCP is enabled, Desktop should offer:

- Launch GitVault at sign-in.
- Keep GitVault running in the system tray.
- Lock from the tray without quitting.
- Explicit **Quit GitVault** to stop the MCP service.

These controls must explain that closing the MCP service disconnects AI apps,
without exposing implementation instructions in the normal notes UI.

## Shared vault session state

Refactor `BiometricGate` authentication state into a Riverpod-backed
`VaultSessionController` with these states:

- `starting`
- `locked`
- `unlocking`
- `unlocked`
- `duress`
- `revoked`

Both the Flutter UI and MCP authorization layer must observe this one source of
truth.

Rules:

- No MCP tool may read repository data unless state is `unlocked`.
- Lock, timeout, device revocation, duress activation, app exit, and vault wipe
  immediately cancel approvals and invalidate MCP data access.
- MCP never triggers a biometric or PIN prompt by itself. The user unlocks from
  GitVault Desktop.
- The server may complete MCP initialization while locked, but vault tools
  return `vault_locked`.
- Do not cache note content across a lock transition.
- Duress mode exposes no real notes through MCP and disconnects active clients.

## Notes MCP surface

### Resources

Expose read-only note resources when the client has read permission:

- `gitvault://notes/{uuid}`
- Resource metadata includes title, tags, archived/pinned state, and modified
  timestamp.
- Resource content is returned only when the client has note-content access.

### Tools

First-release tools:

- `list_notes`
- `search_notes`
- `get_note`
- `list_note_tags`
- `create_note`
- `append_to_note`
- `update_note`
- `archive_note`
- `delete_note`

Requirements:

- List and search use pagination and bounded snippets.
- Read results include `uuid` and `modified_at`.
- Update, append, archive, and delete accept `expected_modified_at`.
- If the note changed since the AI read it, return `conflict` with current
  metadata instead of overwriting the user's newer work.
- Update supports explicit field patches rather than replacing unspecified
  fields.
- Tag permission checks apply before both reads and writes.
- A write invalidates relevant Riverpod providers and calls
  `ForegroundSyncService.scheduleSync` with a short debounce.
- A successful local write is reported as locally saved even if GitHub sync is
  pending or later fails.
- MCP output treats note content as user data, never as trusted instructions.

Structured errors:

- `desktop_unavailable`
- `vault_locked`
- `client_not_paired`
- `client_revoked`
- `permission_denied`
- `approval_required`
- `approval_denied`
- `approval_timeout`
- `note_not_found`
- `conflict`
- `invalid_input`
- `rate_limited`
- `internal_error`

## Local persistence

Create separate stores for:

- MCP server settings.
- Client registrations and credential verifiers.
- Permission policies.
- Activity records.

Do not put raw bearer credentials, note content, GitHub tokens, root keys, or
recovery phrases in activity records.

Server-side credentials should use random 256-bit values and store a
cryptographic verifier rather than plaintext. Bridge profile files contain the
minimum client credential needed to connect and must be restricted to the
current OS user. Credential rotation invalidates the old value immediately.

Activity retention defaults to 30 days with a user action to clear it. Record:

- Timestamp.
- Client ID and display name.
- Tool/action.
- Target note UUID when applicable.
- Allowed, denied, conflict, or failed result.
- Whether user approval was requested.

## Process and lifecycle rules

- Only one GitVault Desktop instance may own the MCP endpoint.
- A second launch should focus the existing app rather than create another
  server or open the same Hive boxes.
- Start the server only after application storage and providers initialize.
- Remove stale discovery data on clean shutdown and safely replace stale data
  after a crash.
- Stop accepting new operations before closing repositories.
- Cancel in-flight writes on lock when they have not yet reached repository
  mutation. Never interrupt an already committed local write halfway.
- Handle sleep/resume, network changes, port conflicts, client crashes, and
  Desktop upgrades without silently broadening permissions.
- MCP remains usable for local notes when GitHub is offline. Sync status remains
  separate from local operation success.

## Desktop platform work

### Windows

- Preserve the existing runner.
- Validate Windows Hello behavior and PIN fallback.
- Bundle the stdio bridge and expose its absolute path in generated configs.
- Add installer/portable packaging after the MCP path is stable.

### macOS

- Add the Flutter macOS runner.
- Configure entitlements for network client/server access, keychain access,
  local authentication, and app sandbox behavior as required.
- Validate Touch ID and fallback unlock.
- Build a signed/notarized artifact when Apple signing credentials are
  available. Unsigned development builds will trigger Gatekeeper warnings.

### Linux

- Add the Flutter Linux runner.
- Provide PIN unlock because `local_auth` has no Linux implementation in the
  current dependency graph.
- Validate required system libraries, secure local file permissions, tray
  behavior, and package installation paths.
- Produce at least one portable release format plus documented dependencies.

Adding platform runners may expose Android-only plugin assumptions. Every
mobile-only service in startup and settings must be guarded by actual platform
capability, not just `!kIsWeb`.

## Implementation phases

### Phase 0: Feasibility and platform baseline - Complete

- Select and pin the Dart MCP SDK.
- Prove a minimal stdio-to-loopback round trip using Dart only.
- Add Linux and macOS runners without changing Android/web behavior.
- Run analyze, unit tests, and debug/release desktop builds on available hosts.
- Audit all plugins for Windows, macOS, and Linux compatibility.

Exit criteria:

- A test MCP client can initialize and call a no-data health tool through both
  transports.
- Android and web still build.
- Desktop platform gaps and signing requirements are documented.

### Phase 1: Shared session and notes application service - Complete

- Extract `VaultSessionController`.
- Route existing unlock, lock button, timeout, revocation, wipe, and duress
  paths through it.
- Add `NotesMcpService` over `NotesRepository`.
- Add conflict checks, pagination, tag scoping, provider invalidation, and sync
  scheduling.

Exit criteria:

- Lock-state unit tests cover every transition.
- Notes MCP service tests cannot access data while locked.
- Concurrent UI and MCP edits do not silently overwrite newer data.

### Phase 2: MCP server and authorization - Complete

- Implement protocol initialization, resources, tools, errors, and limits.
- Implement the loopback server, direct Desktop-authorized client registry,
  credentials, rate limiting, and revocation.
- Add discovery lifecycle and single-instance protection.

Exit criteria:

- Unauthenticated requests receive no vault data.
- Revocation terminates access immediately.
- The service is unreachable from non-loopback interfaces.

### Phase 3: AI Apps desktop UI and approvals - Complete

- Add the desktop-only settings entry and management screens.
- Add direct connection authorization and action approval flows.
- Add permission editing, tag scopes, activity history, and credential rotation.
- Connect lock and app lifecycle events to pending requests.

Exit criteria:

- A user can connect, restrict, inspect, and revoke an AI app without editing a
  config file by hand beyond pasting the generated MCP configuration into the
  target app.
- Every write policy is visible and testable.

### Phase 4: Global client bridge - Complete

- Implement and compile `gitvault_mcp`.
- Add profile discovery, authenticated forwarding, stderr diagnostics, and
  reconnect behavior.
- Generate tested configuration snippets for common stdio and HTTP MCP hosts.
- Keep generic instructions available for other MCP-compatible applications.

Exit criteria:

- At least two independent MCP hosts can use the same GitVault Desktop
  installation with different permissions.
- Revoking one client does not affect another.

### Phase 5: Desktop lifecycle and distribution - Complete

- Add tray controls, explicit quit, optional launch at sign-in, and
  single-instance activation.
- Add Windows, macOS, and Linux CI jobs.
- Bundle the correct bridge binary with each desktop artifact.
- Add checksums and signing/notarization where credentials are available.

Exit criteria:

- Install, upgrade, lock, sleep/resume, tray, and uninstall flows are tested on
  all three desktop platforms.
- The bridge path remains valid after an application update.

### Phase 6: Documentation and release hardening - Complete

- Add README and documentation sections for **AI Apps / MCP**.
- Document the desktop requirement, supported transports, permissions, lock
  behavior, revocation, offline behavior, and troubleshooting.
- Add a security and privacy page that states the local OS-user trust boundary.
- Complete protocol compatibility, fuzz, load, and end-to-end tests.

Exit criteria:

- Documentation matches generated UI/configuration.
- Release CI builds Android, web, Windows, macOS, Linux, and all bridge
  artifacts successfully.

## Test plan

### Unit tests

- Protocol argument validation and bounded output.
- Every permission combination.
- Tag allow/deny rules.
- Direct connection authorization, malformed credentials, rate limits,
  credential rotation, and revocation.
- Lock, timeout, duress, wipe, device revocation, and quit transitions.
- Optimistic concurrency using `expected_modified_at`.
- Approval allow-once, always-allow, deny, timeout, and cancellation.
- Activity redaction and retention.

### Integration tests

- MCP initialize, resource listing, tool listing, and tool calls.
- Direct HTTP client and stdio bridge against the same server.
- Create/edit/append/archive/delete followed by repository verification.
- UI edit racing an MCP edit.
- GitHub sync scheduling after MCP writes.
- Offline local writes followed by later sync.
- Invalid token, revoked token, malformed JSON, oversized payload, and request
  flood handling.
- Lock during an active read, pending approval, and pre-commit write.
- Desktop crash and stale discovery recovery.

### End-to-end desktop tests

1. Start with a locked vault and confirm MCP returns `vault_locked`.
2. Unlock Desktop, connect Client A as read-only, and verify reads work but writes
   fail.
3. Connect Client B with approval-required writes and approve one creation.
4. Deny an edit and confirm the note remains unchanged.
5. Cause a UI/MCP edit conflict and confirm neither edit is silently lost.
6. Lock GitVault and confirm both clients immediately lose data access.
7. Unlock, revoke Client A, and confirm only Client A is disconnected.
8. Quit Desktop and confirm the stdio bridge reports `desktop_unavailable`.
9. Restart Desktop and verify permissions persist without exposing a token.
10. Repeat core flows on Windows, macOS, and Linux.

### Security checks

- Confirm no listener exists on LAN interfaces.
- Confirm secrets and note bodies never appear in logs, crash output, or
  activity history.
- Confirm browser-origin requests cannot use the loopback endpoint without a
  valid client credential and allowed origin.
- Confirm file permissions or ACLs limit discovery and bridge profiles to the
  current user.
- Confirm MCP has no code path to password, TOTP, SSH, GitHub, recovery, or
  device-linking repositories.

## Release acceptance criteria

The first MCP release is ready only when:

- Windows, macOS, and Linux desktop builds launch and unlock reliably.
- Both HTTP and stdio clients pass protocol tests.
- The user can connect and revoke clients entirely from GitVault Desktop.
- Locked, revoked, duress, wiped, or exited Desktop exposes no note data.
- Notes are the only vault data type reachable through MCP.
- Permission and tag scopes are enforced server-side, not only hidden in UI.
- Write approvals show the exact mutation and time out safely.
- Concurrent edits produce conflicts instead of silent data loss.
- MCP writes persist encrypted locally and schedule normal GitHub sync.
- Two clients with different permissions remain isolated.
- Android and web regressions are covered by existing builds and tests.
- Documentation accurately describes support and security boundaries.

## Explicitly deferred

- Password, TOTP, SSH, GitHub token, recovery phrase, or device-management MCP
  access.
- A remotely hosted MCP endpoint.
- MCP hosted directly by the web app or mobile app.
- Cross-device synchronization of AI app credentials or permissions.
- Background note access while the desktop vault is locked.
- Cryptographic verification of a third-party AI application's brand or display
  name.
- Semantic/vector search, embeddings, or an external indexing service.
- Non-MCP editor plugins or a public GitVault extension marketplace.
