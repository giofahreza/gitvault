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

---

# Trusted-Device Approval and Registry Synchronization Fix Plan

## Status

Application changes are implemented. The Desktop MCP phases above were already
complete; this implementation addresses the trusted device registry and approval
flow below. The final local run passed 190 tests with one live integration test
skipped, and the web release build passed. Live GitHub and physical device acceptance checks remain release
gates, as described in the verification record. Do not interpret local automated
test results as completion of those external gates.

The original lost-update race was reproduced before changing production logic:
a concurrent approval became `pending` again after recognition uploaded its
older registry. The same regression now passes with compare-and-rebase writes.

## Implementation record

| Phase | Implementation |
|---|---|
| 0 | SHA-aware fake with deterministic competing writes, conflict limits, read/write failures, and response loss after commit. |
| 1 | Explicit file snapshots and expected-SHA PUT; typed sanitized errors; distinguish absent branch from absent file; no registry access through generic upload. |
| 2 | `DeviceRegistryStore` serializes by owner/repository/branch within an isolate, retries a fresh read/decrypt/apply/encrypt after conflicts, and caps attempts at four. All registry writers use it. |
| 3 | Terminal responses cannot be reversed, completion is bound to the requester, repeated operations avoid extra commits, revocation is rechecked after conflicts, and new QR links require a valid single-use invite. |
| 4 | One cache envelope records scope, SHA, observation time, clock source, and stale status. Read-only refresh returns remote state without consuming invites or creating local registration. Settings hides approval actions when unavailable and labels cached devices as unconfirmed. |
| 5 | An independently testable modal handles checking, waiting, completing, denied, expired, and unavailable states; stops terminal polling; supports new requests and resume checks; closes after registration commits. Vault restoration follows outside the modal with separate error guidance. |
| 6 | Structured diagnostics contain operation, hashed identifiers, blob SHAs, conflict count, status/error category, clock source, outcome, and elapsed time. No raw exceptions or registry contents are logged. |
| Verification | Protocol, encrypted registry, modal, and Settings widget tests; opt-in disposable-repository integration test; desktop CI now runs the full test suite. See the verification record below for actual results and unrun gates. |

### Explicit policies and limitations

- Device IDs are opaque and case-sensitive. Display names never select records.
- A repeated matching answer is a successful no-op; an opposite terminal answer
  is rejected. Expiry equality is expired. A response must be at or after the
  request time and strictly before expiry to authorize recovery.
- A completed request succeeds idempotently only while its matching trusted
  registration still exists. Revocation prevents replaying it.
- Existing trusted and legacy records remain readable. A new `link` registration
  requires a live invite; missing or expired invites also cannot upgrade an
  existing unverified record. Read-only refresh never consumes the local invite,
  and failed remote writes retain it for retry.
- Ambiguous write responses trigger a fresh logical retry with stable operation
  IDs. A confirmed remote commit remains successful if the following cache write
  fails; diagnostics mark the cache stale. Authorization always rereads GitHub.
- Native clients use the GitHub response `Date` plus monotonic elapsed time when
  available. GitHub's CORS exposed headers omit `Date`, so browsers use UTC system
  time; `clockSource` records this fallback. Keep browser clocks synchronized.
  Strict server-enforced expiry across arbitrarily skewed browser clocks requires
  a coordination backend or relay and is not guaranteed by the Contents API.
- The lock covers one isolate only. Remote SHA preconditions provide protection
  against concurrent updated clients in other devices, isolates, or processes.
- Older clients can still fetch a newer SHA and blindly overwrite state. Upgrade
  all active writers before claiming this guarantee across a vault. This client
  patch cannot prevent a client holding both repository write access and the root
  key from deliberately rewriting trust state.
- Fresh-token fallback retains the existing product policy and rejects the
  active and immediately previous token fingerprints. A different token proves
  repository access, not its issuance date; revoke old tokens in GitHub. Registry
  removal alone does not revoke a copied GitHub token or root key.

## Objective

Make trusted-device and recovery approval state correct under concurrent device
activity, transient GitHub failures, and delayed polling.

The system must never:

- overwrite a newer approval with an older pending snapshot;
- treat a temporary GitHub error as an empty trusted-device registry;
- display cached pending approval as current and actionable;
- silently lose an approval, recognition, revocation, invite, or completion;
- close the recovery flow before the device registration state is durable.

## Confirmed architecture at investigation

- `trusted_devices.bin` is one encrypted registry document stored through the
  GitHub Contents API.
- Registry changes use read/decrypt/modify/encrypt/upload of the whole file.
- The GitHub Contents API requires the current blob SHA for updates and returns
  `409 Conflict` for concurrent updates.
- The current retry refreshes the SHA but reuses the stale encrypted payload.
- Normal sync has an in-memory lock, but direct registry actions do not share a
  global registry-write lock.
- The recovery modal polls approximately every three seconds while active.
- Background and normal sync are polling-based; there is no webhook, WebSocket,
  SSE, or push-notification path in the application.
- The device-list UI can fall back to a locally cached registry without a
  remote SHA or freshness marker.
- Existing registry tests use an in-memory service that overwrites files and
  does not simulate SHA conflicts.

Relevant implementation locations:

- `lib/core/services/github_service.dart`
- `lib/data/repositories/sync_engine.dart`
- `lib/features/settings/settings_screen.dart`
- `lib/core/services/foreground_sync_service.dart`
- `test/device_recovery_approval_test.dart`

## Design decisions

1. Keep GitHub as the encrypted vault and registry backend for the first fix.
2. Treat the registry as a compare-and-swap document, not as last-write-wins
   data.
3. Reapply a logical operation to the newest registry after every conflict;
   never retry an old encrypted snapshot with only a new SHA.
4. Serialize registry writes within one app process, while relying on remote
   compare-and-swap for cross-device safety.
5. Make security-state transitions monotonic and operation-specific.
6. Treat unknown or transient reads as errors, never as an empty registry.
7. Keep cached registry data visibly stale and non-actionable when the remote
   state cannot be confirmed.
8. Keep polling for now. Realtime delivery is an optional architecture change,
   not the correctness fix.

## Why this is the preferred first fix

Moving immediately to a realtime database would add authentication, migration,
privacy, availability, and operational complexity. It would also not fix the
current client-side state machine automatically.

Correct compare-and-rebase behavior should be enough for this low-volume,
short-lived approval flow. The existing three-second modal polling can provide
near-realtime user experience once the registry writes are safe.

Switching from the Contents API to Git references alone is not sufficient. A
Git reference can prevent a branch from being force-overwritten, but the client
still has to rebuild its logical change against the newest document. A webhook
would only provide server-side notification; it would not solve concurrent
registry writes.

## Implementation phases

### Phase 0: Add a conflict-capable test model before changing production logic

Extend the test GitHub service so it models the real file protocol:

- maintain a blob SHA for each file;
- require the expected SHA on update;
- return `409` when the expected SHA is stale;
- allow a test to inject 404, 409, 429, 500, timeout, and malformed-content
  responses;
- record uploaded payloads and commit messages.

Create deterministic concurrency tests where two writers read the same pending
registry, one approves a request, and the other updates a device heartbeat.
The final registry must contain both changes.

Do not change production code until this test can reproduce the current lost
update behavior.

### Phase 1: Make GitHub file access explicit and status-safe

Introduce a remote-file snapshot abstraction containing at least:

- file bytes;
- blob SHA;
- whether the file exists;
- the relevant HTTP status/error classification.

Separate these operations:

- read a file snapshot;
- create a file when it is genuinely absent;
- update a file using an explicit expected SHA;
- classify conflicts as retryable compare-and-swap failures.

Change error handling so:

- 404 can mean “missing file” only where initialization explicitly allows it;
- 401/403 remain authentication/permission failures;
- 409 remains a write conflict or retryable read conflict;
- 429 is rate limiting;
- 5xx and network failures are transient errors;
- malformed or empty existing content is an invalid-data error.

Do not silently convert non-404 failures into `null` or an empty registry.
Do not treat 422 as a generic branch-missing condition without checking its
actual response meaning.

### Phase 2: Build one transactional registry mutation path

Create a single internal registry mutation function used by every registry
writer:

```text
acquire local registry-write lock
repeat up to a bounded retry count:
    read latest registry snapshot and SHA
    decrypt and validate the registry
    apply the logical operation to this latest state
    if operation is a no-op:
        cache the validated state and return
    encrypt the resulting registry
    update using the exact snapshot SHA
    if update succeeds:
        cache only the successfully committed state
        return
    if conflict:
        retry from a fresh read and reapply the operation
    otherwise:
        fail without uploading a fallback state
throw a typed registry-conflict error
release local lock
```

The retry must repeat the entire read/decrypt/apply/encrypt sequence. It must
not reuse the old encrypted bytes.

Route all of these through the same path:

- create and consume device invites;
- recognize a device;
- revoke a device;
- create a recovery approval request;
- approve or deny a recovery request;
- complete approved recovery;
- complete token-rotated recovery;
- registry refresh and local heartbeat updates.

The mutation callback should be keyed by stable identifiers such as
`approvalId`, `deviceId`, and `inviteId`, so it can safely be reapplied after a
conflict.

### Phase 3: Enforce monotonic registry semantics

Define explicit transition rules:

- `pending` approval may become `approved`, `denied`, or `expired` only once;
- an approval answered before expiry remains valid when it is observed later;
- `approved` may become completed, but never return to `pending`;
- repeated completion for the same approval/device is idempotent;
- a recognized/trusted registration cannot be downgraded by a stale local
  registration method;
- revocation is preserved unless an explicit, valid relink operation removes
  it;
- unrelated approvals, invites, devices, and revocations must survive every
  operation.

Do not use generic last-write-wins for trust or recovery state.

### Phase 4: Fix local cache and UI freshness behavior

Store cache metadata with the registry:

- last successfully observed remote blob SHA;
- last successful remote-read time;
- whether the cached state is confirmed or stale.

Update the device-list behavior:

- only replace current UI state after a successful, authenticated,
  decryptable remote read;
- if remote state is unavailable, show the last-known state as stale or show an
  error state;
- never expose stale pending approvals as current approval actions;
- do not upload a registry after an unknown or failed remote read;
- keep the local device display available without pretending the remote list is
  authoritative.

The cache is for continuity of display, not for authorization decisions.

### Phase 5: Make the recovery modal state machine explicit

Keep the three-second polling interval initially, but separate these states:

- checking;
- waiting for approval;
- approval received;
- completing recovery;
- completed;
- denied;
- expired;
- temporarily unable to check.

When approval is observed:

1. call the transactional completion operation;
2. let that operation re-read and retry against the latest registry;
3. close the modal only after device registration is durably committed;
4. if vault restoration fails after registration commits, close the approval
   modal and show a separate restore error with retry guidance.

When the request expires, show a clear terminal state and provide an explicit
retry/cancel path. Do not leave the user unable to distinguish expiration from
an active approval wait.

### Phase 6: Add observability without logging secrets

Record diagnostic metadata only:

- operation type;
- device ID hash or redacted identifier;
- approval/invite ID hash or redacted identifier;
- read SHA and committed SHA;
- conflict count;
- HTTP status class;
- final state;
- elapsed time.

Never log GitHub tokens, recovery phrases, root keys, decrypted registry
contents, or vault data.

This will distinguish:

- approval never committed;
- approval committed and then overwritten;
- approval committed but completion failed;
- remote state correct but local UI stale.

## Required test coverage

### Registry concurrency

- approval versus heartbeat update;
- approval versus recognition;
- approval versus invite consumption;
- approval versus another approval;
- completion versus refresh;
- revoke versus refresh;
- multiple simultaneous writers with repeated conflicts;
- bounded retry exhaustion without data loss.

### State invariants

- pending cannot return after approval;
- completed approval remains completed;
- recognized device is not downgraded;
- expired approval cannot be newly approved;
- timely approval remains valid when read after its expiry timestamp;
- unrelated registry entries survive all mutations;
- repeated operations are idempotent.

### Error handling

- 404 during allowed initialization;
- 404 for an existing expected registry path;
- 401/403 authentication failure;
- 409 read/write conflict;
- 429 rate limiting;
- 5xx failure;
- timeout and offline failure;
- malformed encrypted registry;
- valid remote registry with an empty device list.

No error case may cause an existing registry to be replaced by a local-only
registry.

### UI and modal

- approval appears after polling;
- approval completion closes the modal;
- completion conflict retries successfully;
- completion failure leaves a clear recoverable error;
- expiry is visibly terminal;
- stale cached approval is not actionable;
- Settings refresh does not retain a falsely current pending card after a
  confirmed remote approval.

### End-to-end scenarios

1. Create a recovery request on Device A.
2. Approve it on Device B while Device C performs a registry refresh.
3. Confirm the final registry contains the approval and Device C's unrelated
   update.
4. Let Device A poll and complete recovery.
5. Repeat with injected conflicts, offline periods, and rate limits.
6. Repeat the QR Link New Device flow separately; it must not be confused with
   recovery approval.

## Verification commands

Run focused registry tests first, then the full test suite and static analysis.
During investigation Flutter/Dart were unavailable. Implementation verification
uses a temporary Flutter 3.29.3 SDK matching CI; see the results below.

Also inspect the GitHub commit history for `trusted_devices.bin` during a
controlled test. A committed approval followed by a later committed pending
snapshot would confirm the stale-writer race.

## Realtime architecture decision

Do not add a realtime service as part of the first correctness patch.

If future product requirements demand push-based updates, keep GitHub for
encrypted vault files and move only device coordination to a transactional
backend with:

- server-side compare-and-set approval transitions;
- authenticated device identities;
- transactional completion/revocation;
- realtime subscriptions or push notifications.

GitHub webhooks are server-to-server notifications. They would require an
external relay plus WebSocket or mobile push delivery and would not replace the
transactional write design.

## Verification record — 2026-11-22

Flutter 3.29.3 was installed temporarily outside the repository to match desktop
CI. Generated model files remain ignored; no dependency upgrade was required.

| Check | Result |
|---|---|
| Original regression before production changes | Failed with expected `approved`, actual `pending`, reproducing lost approval. |
| Model generation | Passed with `dart run build_runner build --delete-conflicting-outputs`. |
| Final full test run | `flutter test`: 190 passed; one opt-in live GitHub integration test skipped. |
| Final web release build | `flutter build web --release`: passed, including browser clock fallback. |
| Final changed-file static analysis | Zero errors and zero warnings. Informational formatting/const/context lint notices remain; these are not claimed to be a clean lint baseline. |
| Final full-project static analysis | `flutter analyze --no-fatal-infos` exits 1: zero errors, 11 warnings in untouched autofill/IME/SSH/vault files, and informational lint notices (266 total findings). These existing warnings were not changed by this registry fix. |
| Whitespace validation | `git diff --check`: passed. |
| Live GitHub write/conflict/history inspection | Not run: no disposable test repository credentials were supplied. |
| Native macOS build | Not run: full Xcode is absent; only Command Line Tools are installed. |
| Camera QR, multi-device, background isolate, process termination, and physical platform acceptance | Pending manual/device runs; simulated concurrency and widget lifecycle tests do not substitute for these. |

Automated coverage is organized as follows. The original test-case tables remain
the acceptance checklist; this mapping reports what was actually exercised and
does not mark every end-to-end row as passed.

| Test file | Exercised behavior |
|---|---|
| `test/github_registry_protocol_test.dart` | Exact SHA PUT without a second GET; bytes/SHA/time from one response; missing file versus branch; 401/403/409/429/5xx; rate-limit classification; malformed/empty content; timeout/offline normalization; concurrent create versus validation failure; generic registry-upload prohibition. |
| `test/device_recovery_approval_test.dart` | Encrypted concurrent approval/heartbeat/recognition/invite/completion; opposite and different answers; repeated conflicts and retry exhaustion; local serialization; revoked actor/target races; idempotent and ambiguous completion/creation; requester binding; remote and browser clock policies; invalid schema and wrong key; scoped stale cache; successful commit with failed cache write; QR single-use and missing-invite policy; trusted metadata preservation; hashed diagnostic output. |
| `test/recovery_approval_dialog_test.dart` | Polling discovery; durability before dismissal; completion retry; terminal expiry/denial; request retry with a new ID; connection errors; remaining lifetime; overlapping checks; resume; disposal; new-token fallback; request-creation failure. |
| `test/device_registry_ui_test.dart` | Fresh pending cards; stale cached approvals hidden after failure; explicit retry; valid empty remote state; inactive/reactivated Settings; rejection of another repository's cached device list. |
| `test/github_registry_integration_test.dart` | Opt-in harness for an actual GitHub 409 and encrypted logical rebase. Compiles in the full suite; live execution remains unverified. |
| Existing MCP, onboarding, vault, notes, crypto, and widget suites | Included in the full test run to catch regressions outside the registry. |

The live harness requires an existing `data` branch in a disposable repository:

```sh
# Supply these through your shell/CI secret store; do not put tokens in this file:
# GITVAULT_TEST_GITHUB_TOKEN, GITVAULT_TEST_REPO_OWNER, GITVAULT_TEST_REPO_NAME
GITVAULT_RUN_GITHUB_INTEGRATION=1 flutter test test/github_registry_integration_test.dart
```

It creates a unique `integration-tests/<uuid>/trusted_devices.bin`, uses fresh
test encryption keys, forces a competing heartbeat commit, verifies the approval
survives the real conflict, and removes its fixture. It never targets the live
root `trusted_devices.bin`. Repeat the actual approval/restore and QR flows on
supported platforms before release, including a failed vault restore after
registration has already committed. Browser clock-skew enforcement remains
limited by the documented local-clock fallback.

## Acceptance criteria

The fix is complete only when:

- no stale registry payload can overwrite a newer approval;
- every registry write uses a fresh snapshot and expected SHA;
- conflict retries reapply the logical operation;
- transient GitHub failures cannot create or upload an empty fallback registry;
- cached state is never used as authoritative approval state;
- trusted-device and recovery transitions are monotonic;
- the recovery modal closes after durable completion;
- expired or failed approvals have clear terminal UI states;
- concurrency, conflict, cache, error, and modal tests pass;
- no secrets or decrypted registry contents appear in diagnostics.

## Sources

- GitHub Contents API: concurrent updates, required blob SHA, and `409`
  behavior: <https://docs.github.com/en/rest/repos/contents?apiversion=2022-11-28>
- GitHub Git references API: non-force updates and conflict behavior:
  <https://docs.github.com/en/rest/git/refs>
- GitHub webhooks: server-side event delivery versus polling:
  <https://docs.github.com/en/webhooks/about-webhooks>

---

## Test cases

These test cases are the required verification matrix for the trusted-device
approval and registry synchronization plan. Every case should run against a
deterministic fake GitHub service first, then the highest-risk cases should be
repeated against a controlled real repository.

### Test data and conventions

| Fixture | Definition |
|---|---|
| Device A | Recovery device requesting approval. |
| Device B | Trusted device approving, denying, recognizing, or revoking. |
| Device C | Concurrent trusted device performing refresh or another mutation. |
| Approval R1 | Pending recovery approval with a known `approvalId`, request time, and expiry. |
| Invite I1 | Pending device-link invite with a known `inviteId` and expiry. |
| Registry V1 | Valid encrypted registry containing Devices A, B, C, R1, and I1. |
| SHA-1 | Remote blob SHA read with Registry V1. |
| SHA-2 | New remote blob SHA committed by a competing writer. |
| Conflict | GitHub update using SHA-1 after SHA-2 is already current. |
| Retry limit | The configured maximum number of compare-and-rebase attempts. |
| Fresh read | A successful remote read that returns bytes, a SHA, and decryptable authenticated content. |
| Stale cache | A locally stored registry whose remote read time or SHA cannot be confirmed. |

### Registry read and GitHub status cases

| ID | Scenario and setup | Steps | Expected result | Corner case or regression caught |
|---|---|---|---|---|
| TC-READ-001 | Existing valid Registry V1 is available. | Read the registry snapshot. | Bytes, blob SHA, and success status are returned. | The cache must not be updated before authentication and decryption succeed. |
| TC-READ-002 | The trusted-device file is genuinely absent during first initialization. | Request the registry with initialization explicitly allowed. | An empty initial registry may be created once. | Missing-file behavior must not be used for normal refreshes. |
| TC-READ-003 | The trusted-device file is absent during an existing-device refresh. | Refresh with `uploadIfNeeded` enabled. | The operation fails safely or follows an explicit initialization path; it must not erase the known registry. | Prevents a temporary branch or path problem from becoming a local-only registry upload. |
| TC-READ-004 | GitHub returns HTTP 401. | Read the registry. | Authentication error is surfaced; no cache replacement or upload occurs. | A revoked or invalid token must not be interpreted as an empty registry. |
| TC-READ-005 | GitHub returns HTTP 403. | Read the registry. | Permission error is surfaced; no cache replacement or upload occurs. | Fine-grained token permission failures must remain distinguishable from missing files. |
| TC-READ-006 | GitHub returns HTTP 404 for the data branch. | Read the registry. | Branch-not-found is reported separately from file-not-found. | The client must not initialize or overwrite a repository based only on a generic 404. |
| TC-READ-007 | GitHub returns HTTP 409 during a read. | Read the registry. | Read conflict is classified as retryable; no empty registry is produced. | A read conflict must not silently become a valid empty state. |
| TC-READ-008 | GitHub returns HTTP 429. | Read and then attempt a refresh. | Rate-limit error is surfaced or retried with bounded backoff; no write occurs. | Prevents rate limiting from causing registry loss. |
| TC-READ-009 | GitHub returns HTTP 500, 502, or 503. | Read and then attempt a refresh. | Transient server error is surfaced or retried; no empty registry is returned and no upload occurs. | Covers GitHub outages and proxy failures. |
| TC-READ-010 | Network timeout or offline device occurs during read. | Start a refresh and interrupt connectivity. | Operation fails as stale/unavailable; previous cache is not presented as authoritative. | The UI may retain display data only with a stale indicator. |
| TC-READ-011 | Existing file has zero bytes or invalid Base64. | Read and decrypt the registry. | Invalid-data error is returned; existing cache remains unchanged and no upload occurs. | Empty content is not equivalent to a missing registry. |
| TC-READ-012 | Existing encrypted bytes fail authentication or use the wrong root key. | Read and decrypt the registry. | Decryption/authentication failure is returned; trusted state is never replaced. | Protects against corruption, wrong account, and tampering. |
| TC-READ-013 | Existing registry decrypts successfully to `{devices: []}`. | Refresh the registry. | Empty-but-valid registry is accepted as authoritative and handled according to product rules. | Distinguishes a valid empty list from a failed read. |
| TC-READ-014 | Registry JSON is valid but missing optional legacy fields. | Refresh and mutate the registry. | Missing optional fields are defaulted safely; unrelated state is preserved. | Covers registries written by older app versions. |
| TC-READ-015 | Registry contains unknown fields and future-compatible fields. | Read, mutate one known field, and write. | Unknown fields survive the mutation unchanged. | Prevents older clients from deleting newer metadata. |
| TC-READ-016 | Registry contains malformed types, such as a string instead of a device list. | Read and validate the registry. | Validation fails safely; no destructive repair upload occurs. | Prevents type errors from producing a reduced registry. |

### Compare-and-rebase and concurrency cases

| ID | Scenario and setup | Steps | Expected result | Corner case or regression caught |
|---|---|---|---|---|
| TC-CON-001 | Device B and Device C both read Registry V1 with SHA-1. B approves R1; C updates its heartbeat. | Let B commit SHA-2, then let C write with SHA-1. | C receives conflict, rereads SHA-2, reapplies only the heartbeat operation, and commits a registry containing both approval and heartbeat. | Directly reproduces the current lost-approval bug. |
| TC-CON-002 | Device B recognizes Device A while Device C refreshes from an older snapshot. | Force the recognition write to conflict. | Final registration remains recognized and C's unrelated refresh survives. | Stale refresh must not restore an unverified registration method. |
| TC-CON-003 | Two trusted devices approve different pending approvals concurrently. | Run both mutations from the same base SHA. | Both approvals are present in the final registry. | Whole-file list replacement must not drop one approval. |
| TC-CON-004 | Two devices attempt to answer the same pending approval concurrently. | One approves and one denies from the same base SHA. | Exactly one valid terminal answer wins according to the defined policy; the other receives an already-answered result and cannot reverse it. | Prevents ambiguous approval/denial races. |
| TC-CON-005 | Device A completes R1 while Device C refreshes or updates another device. | Force completion to conflict. | Completion is retried against the latest registry and preserves C's update. | Completion must not fail merely because another device updated the document. |
| TC-CON-006 | Device B revokes Device A while Device C tries to refresh Device A. | Run revoke and refresh concurrently. | Revocation is preserved; Device A cannot write an older trusted state over it. | Protects the security boundary during a race. |
| TC-CON-007 | Device B creates invite I1 while Device C consumes another invite. | Run both operations against the same base SHA. | Both invite/device changes survive, or explicit single-use semantics reject only the invalid invite. | Pending invite list must not lose entries. |
| TC-CON-008 | A writer receives repeated conflicts from competing devices. | Inject conflicts until just below the retry limit. | Each retry rereads and reapplies the operation; eventual success contains all applicable changes. | Confirms retries are logical-operation retries, not SHA-only retries. |
| TC-CON-009 | Every attempt conflicts until the retry limit is exceeded. | Execute a mutation. | A typed conflict error is returned; no stale payload is uploaded after exhaustion and local cache is not marked fresh. | Prevents infinite loops and false success. |
| TC-CON-010 | Two registry writes originate from the same app process. | Start them without awaiting the first operation. | The local registry mutex serializes them; both operations commit without avoidable local conflict. | Covers simultaneous UI action and background sync. |
| TC-CON-011 | Background sync runs in a separate isolate or process from the foreground action. | Force both writers to operate concurrently. | The local mutex is not assumed to protect them; remote SHA conflict handling preserves both operations. | Verifies cross-isolate safety. |
| TC-CON-012 | A conflict occurs after encryption, and encryption uses a new nonce/padding each time. | Retry the mutation. | New ciphertext is generated from the latest logical registry on each retry; no stale ciphertext is reused. | Covers randomized encryption and blob-SHA changes. |
| TC-CON-013 | A no-op mutation reads the latest registry. | Re-recognize an already recognized device or complete an already completed approval. | No unnecessary upload occurs; current state is returned as success. | Prevents repeated polling or taps from creating needless commits. |
| TC-CON-014 | A writer applies an operation to a registry where its target was deleted or revoked by a competing writer. | Force a conflict, then retry. | Operation follows explicit policy: safe no-op or typed rejection; it must not recreate the deleted trust state. | Prevents stale operations from resurrecting devices. |
| TC-CON-015 | The upload `PUT` succeeds but the client loses the response before receiving the commit SHA. | Repeat the same idempotent mutation. | The second attempt recognizes the already-applied state or safely reapplies it; no contradictory state is written. | Covers ambiguous network completion. |

### Approval, recovery, invite, and trust-state cases

| ID | Scenario and setup | Steps | Expected result | Corner case or regression caught |
|---|---|---|---|---|
| TC-STATE-001 | R1 is pending and unexpired. | Approve R1. | R1 becomes approved with responder identity and response time. | Baseline approval path. |
| TC-STATE-002 | R1 is pending and unexpired. | Deny R1. | R1 becomes denied and cannot later become approved. | Denial must be terminal. |
| TC-STATE-003 | R1 is pending and expired. | Attempt approval. | R1 becomes expired or returns an expired result; no approval is committed. | Prevents late approval. |
| TC-STATE-004 | R1 was approved before expiry but is read after its expiry timestamp. | Poll status and complete recovery. | R1 remains valid because the response time was before expiry. | Existing timely-after-expiry behavior must remain intact. |
| TC-STATE-005 | R1 is already approved. | Attempt a second approval or denial. | The operation returns already-answered without changing the original response. | Prevents a second device from reversing the answer. |
| TC-STATE-006 | R1 is approved but not completed. | Complete recovery twice. | First completion registers the device; second completion is idempotent and does not duplicate the device. | Handles retries and ambiguous network responses. |
| TC-STATE-007 | R1 is approved, but a competing stale writer contains R1 as pending. | Force the stale writer to conflict. | Rebase preserves approved or completed state; pending never returns. | Core monotonicity guarantee. |
| TC-STATE-008 | R1 is approved but the target device is already registered. | Complete recovery. | Existing device record is merged without duplicating the device or deleting trusted metadata. | Covers interrupted completion and retry. |
| TC-STATE-009 | R1 references a different device than the device attempting completion. | Attempt completion. | Completion is rejected safely; no other device is registered. | Prevents approval ID misuse. |
| TC-STATE-010 | R1 is missing from the latest registry after a conflict. | Attempt completion. | Completion returns a clear not-found or superseded result; it does not create a new approval implicitly. | Prevents stale approval resurrection. |
| TC-STATE-011 | A device is recognized while its local registration method is `link` or another trusted method. | Recognize the device. | Operation is idempotent or preserves the stronger existing trusted state. | Recognition must not damage valid link metadata. |
| TC-STATE-012 | A recognized device is later refreshed by a device whose local method is unverified or legacy. | Force refresh and possible upload. | Remote `recognized` state remains recognized. | Covers the existing downgrade regression. |
| TC-STATE-013 | Device clocks differ by a large positive and negative offset. | Request, approve, poll, and complete with skewed clocks. | Behavior follows the documented expiry policy; no device can approve after the request is expired according to the authoritative policy. | Exposes client-clock dependence and requires an explicit tolerance decision. |
| TC-STATE-014 | R1 has a missing, malformed, or unparseable expiry timestamp. | Poll and answer R1. | The request is rejected safely as invalid or expired; it is never treated as indefinitely valid. | Prevents malformed data from bypassing expiry. |
| TC-STATE-015 | I1 is valid and unexpired. | Consume I1 through QR linking. | Device is registered as `link`; I1 is consumed exactly once. | Baseline QR link flow. |
| TC-STATE-016 | I1 is expired. | Attempt to consume I1. | Link is rejected or marked expired; no trusted device is added. | Prevents late invite use. |
| TC-STATE-017 | I1 is consumed twice by the same or different devices. | Submit the same invite twice. | First valid consumption wins; later attempts are rejected or idempotently recognized without adding another device. | Covers QR replay. |
| TC-STATE-018 | I1 is missing from the latest registry after the new device scanned it. | Refresh the linked device. | Device is not silently downgraded to unverified; result follows explicit missing-invite policy and is visible to the user. | Covers invite propagation delay and stale registry reads. |
| TC-STATE-019 | Device A is revoked while it has a pending approval or invite. | Revoke Device A, then process the pending record. | Related approval/invite is invalidated according to policy and cannot restore the revoked device through a stale write. | Covers revocation cleanup races. |
| TC-STATE-020 | Revoked device uses the old token. | Run trust refresh. | Access is rejected and local sync credentials are cleared as designed; registry is not modified by that device. | Security regression check. |
| TC-STATE-021 | Revoked device uses a valid fresh token or valid new invite. | Run relink flow. | Explicit relink policy is applied; revoked record is removed only as part of a valid relink operation. | Prevents arbitrary unrevocation. |
| TC-STATE-022 | Registry contains unknown approval status or registration method. | Refresh and display devices. | Unknown state is preserved and shown as requiring review; it is not silently treated as trusted or pending. | Forward compatibility and safe default behavior. |

### Cache, freshness, and device-list UI cases

| ID | Scenario and setup | Steps | Expected result | Corner case or regression caught |
|---|---|---|---|---|
| TC-CACHE-001 | Fresh remote Registry V1 is read successfully. | Refresh the device list. | UI and local cache reflect V1 and record its remote SHA and freshness time. | Baseline cache update. |
| TC-CACHE-002 | Remote read fails after the UI previously showed pending R1. | Trigger a refresh. | UI shows stale/unavailable state or preserves display data with a stale marker; it does not claim R1 is currently pending. | Prevents stale approval from appearing authoritative. |
| TC-CACHE-003 | Remote read fails while the cached registry contains a pending approval. | Attempt to approve from the device list. | Approval action is disabled or requires a successful fresh read. | Prevents approving an old or deleted request. |
| TC-CACHE-004 | Remote read returns valid empty devices with a successful SHA. | Refresh the device list. | Empty remote state is accepted as current; it is not confused with a failed read. | Separates valid emptiness from failure. |
| TC-CACHE-005 | Registry refresh fails with HTTP 500, 429, timeout, or decryption error. | Run normal sync with upload enabled. | No registry upload occurs and the existing cache remains marked stale. | Prevents destructive fallback writes. |
| TC-CACHE-006 | A successful remote approval exists, but an old local cache still says pending. | Refresh the device list. | Fresh remote state replaces the old cache and removes the pending card. | Directly tests the reported symptom. |
| TC-CACHE-007 | Device list refreshes every three seconds while Settings is active. | Keep Settings open and mutate the registry remotely. | UI eventually reflects the remote state without overlapping loads or duplicate writes. | Covers timer overlap and `_loadingDevices`. |
| TC-CACHE-008 | Settings becomes inactive during a refresh. | Navigate away while a read is in flight. | No unsafe `setState`, cache corruption, or upload occurs after disposal. | Lifecycle safety. |
| TC-CACHE-009 | Settings becomes active again after a failed refresh. | Return to Settings. | A fresh remote read is attempted; old stale state is not silently marked fresh. | Covers tab lifecycle. |
| TC-CACHE-010 | A new unverified device warning is dismissed locally. | Dismiss, refresh, then change its remote registration method. | Local dismissal behavior follows policy and a newly changed device state is not hidden permanently. | Prevents dismissal from masking future security changes. |
| TC-CACHE-011 | Recognized device write succeeds remotely but the following UI refresh fails. | Recognize, then inject a read failure. | UI may remain stale temporarily but never writes the old state back to GitHub. | Separates display lag from data corruption. |

### Recovery modal and approval-flow UI cases

| ID | Scenario and setup | Steps | Expected result | Corner case or regression caught |
|---|---|---|---|---|
| TC-MODAL-001 | Device A creates R1; Device B approves it promptly. | Let A poll. | A changes to approval-received, completes recovery transactionally, restores the vault, and closes the approval modal. | Happy path for the reported issue. |
| TC-MODAL-002 | Approval is committed just after a polling request starts. | Poll while the approval is being written. | Current poll may return pending, but the next bounded poll detects approval without losing it. | Normal read/write timing race. |
| TC-MODAL-003 | Approval is committed within the 30-second window but is read after expiry. | Delay polling after the response. | Approval remains valid because response time was before expiry; completion is allowed. | Protects timely approvals under polling delay. |
| TC-MODAL-004 | Device A sees approved, then completion encounters a 409. | Inject conflict during completion. | Completion rereads, reapplies, succeeds, and closes the modal. | Confirms the second completion race is fixed. |
| TC-MODAL-005 | Device A sees approved, then a stale writer overwrites the registry before completion. | Complete recovery. | After the stale-writer fix this cannot occur; if it occurs in a negative test, modal shows a clear recoverable failure and no false success. | Verifies both data invariant and safe UI failure. |
| TC-MODAL-006 | Approval response arrives after expiry. | Poll the modal. | Modal enters an explicit expired terminal state; no device registration occurs. | Late approval must not look like a network hang. |
| TC-MODAL-007 | Device B denies R1. | Poll Device A. | Modal shows denied state and does not attempt completion. | Denial path. |
| TC-MODAL-008 | GitHub is offline during polling. | Keep the modal open through multiple failed polls. | Modal shows temporary check errors, does not reset valid state to pending, and remains retryable. | Distinguishes unavailable from not approved. |
| TC-MODAL-009 | GitHub is offline after approval but before completion. | Poll and retry completion after reconnecting. | Completion succeeds after reconnect without creating duplicate device records. | Recovery after transient outage. |
| TC-MODAL-010 | Vault restore fails after `completeApprovedRecovery` commits. | Inject failure in restore sync. | Approval modal closes after durable registration; a separate restore error and retry action is shown. | Prevents the modal from falsely implying approval was not received. |
| TC-MODAL-011 | User presses manual Check Approval while an automatic check is running. | Start both actions. | Only one check runs; no duplicate completion or conflicting UI state occurs. | Covers `_busy` and reentrancy. |
| TC-MODAL-012 | User backgrounds the app during polling and resumes after approval. | Pause and resume the app. | On resume, a fresh check runs and the modal reaches the correct current state. | Mobile lifecycle and timer suspension. |
| TC-MODAL-013 | User cancels an expired or denied modal. | Press Cancel. | Modal closes without changing the registry or local trust state. | Cancellation must be non-mutating. |
| TC-MODAL-014 | User chooses Use New Token after approval flow expires. | Complete token-rotated recovery. | New-token flow uses its own transactional completion and does not reuse an expired approval incorrectly. | Separates fallback recovery from normal approval. |
| TC-MODAL-015 | QR Link New Device is completed successfully. | Scan/enter transfer code, verify PIN, and finish linking. | Link screen closes and device is registered as `link`; no recovery approval modal is shown. | Prevents confusion between QR linking and recovery approval. |
| TC-MODAL-016 | QR link registration refresh fails after successful key transfer. | Inject registry failure. | User receives a clear registration warning; the app does not claim remote trust was confirmed. | Separates local key transfer from registry durability. |

### Security and data-integrity cases

| ID | Scenario and setup | Steps | Expected result | Corner case or regression caught |
|---|---|---|---|---|
| TC-SEC-001 | An attacker or stale client uploads a registry based on an old SHA. | Attempt the update after a newer commit exists. | GitHub conflict is handled; stale state cannot replace newer trust state. | Core anti-lost-update security case. |
| TC-SEC-002 | A device has the GitHub token but not the correct root key. | Download and attempt registry mutation. | Decryption fails; no upload or cache replacement occurs. | Prevents ciphertext replacement with an unauthenticated registry. |
| TC-SEC-003 | A device has the root key but GitHub permission is removed. | Read and mutate the registry. | Operation fails safely; no local success is reported. | Permission revocation. |
| TC-SEC-004 | Registry ciphertext is modified outside the app. | Attempt read, refresh, and sync. | Authentication failure is surfaced; trusted state is preserved locally as stale and no overwrite occurs. | Tamper detection. |
| TC-SEC-005 | Logs are collected during successful and failed operations. | Inspect logs and diagnostics. | No token, root key, recovery phrase, decrypted registry, vault data, or raw approval details appear. | Prevents sensitive observability regression. |
| TC-SEC-006 | A stale operation tries to recreate a revoked device. | Rebase the operation after revocation. | Revocation remains authoritative and recreation is rejected unless explicit relink conditions are met. | Prevents trust resurrection. |
| TC-SEC-007 | An approval ID is replayed from another device. | Attempt completion with the wrong device identity. | Operation is rejected and no device is registered. | Approval binding and replay resistance. |
| TC-SEC-008 | Two device names or IDs are identical except for case or whitespace. | Register, recognize, and revoke devices. | Identity matching follows the documented device-ID policy, not display-name equality. | Prevents accidental cross-device mutation. |

### Observability and operational cases

| ID | Scenario and setup | Steps | Expected result | Corner case or regression caught |
|---|---|---|---|---|
| TC-OBS-001 | Successful mutation with no conflict. | Run approval and completion. | Operation type, redacted IDs, SHA metadata, final state, and duration are recorded without secrets. | Baseline diagnostics. |
| TC-OBS-002 | Mutation conflicts twice before succeeding. | Inject two conflicts. | Conflict count and final committed SHA are recorded; intermediate payloads are not logged. | Makes retry behavior diagnosable. |
| TC-OBS-003 | Mutation fails after retry exhaustion. | Force continuous conflicts. | Typed error, attempt count, and status class are recorded; no false success is recorded. | Operational alerting correctness. |
| TC-OBS-004 | Read fails with each supported HTTP/network error. | Execute reads under injected failures. | Error classification is retained in diagnostics and UI without exposing response tokens or decrypted content. | Distinguishes outage types. |
| TC-OBS-005 | App restarts after a successful remote commit but before local cache write. | Simulate process termination. | Next read obtains the remote committed state and reconstructs cache safely. | Crash consistency. |
| TC-OBS-006 | App restarts after local cache write but before remote commit. | Simulate process termination. | Next read does not trust the uncommitted cache as authoritative. | Prevents local false success. |
| TC-OBS-007 | Multiple devices commit in rapid succession. | Inspect controlled repository history. | Each commit can be correlated to a logical operation without exposing registry contents. | Supports production diagnosis of stale overwrites. |

### Migration and compatibility cases

| ID | Scenario and setup | Steps | Expected result | Corner case or regression caught |
|---|---|---|---|---|
| TC-MIG-001 | Registry was written by the current production version without cache SHA metadata. | Upgrade and refresh. | Registry remains readable; metadata is added only after a confirmed successful read. | Safe rollout from old cache format. |
| TC-MIG-002 | Registry contains old registration methods such as `sync` or `recovery`. | Refresh and display. | Old entries are preserved and classified according to safe legacy policy. | Prevents accidental mass warnings or trust upgrades. |
| TC-MIG-003 | Registry contains old approval records without `respondedAt`. | Poll and attempt completion. | Record is treated as invalid or expired according to explicit migration policy; no unsafe approval occurs. | Prevents missing timestamps from bypassing expiry. |
| TC-MIG-004 | Registry contains future fields and a newer status unknown to this client. | Mutate an unrelated device. | Future fields and unknown status remain intact; client does not downgrade them. | Forward-compatible document mutation. |
| TC-MIG-005 | Cache JSON is corrupt while remote registry is valid. | Open Settings and refresh. | Corrupt cache is ignored or replaced by the validated remote state. | Local cache recovery. |
| TC-MIG-006 | Remote registry is valid but local Hive storage is unavailable or closed. | Read and mutate. | Operation fails without remote destructive fallback; UI reports local storage failure. | Protects against partial local initialization. |

### End-to-end acceptance cases

| ID | Scenario and setup | Steps | Expected result | Corner case or regression caught |
|---|---|---|---|---|
| TC-E2E-001 | Device A has a recovery phrase and old GitHub credentials; Device B is trusted. | Create R1, approve on B, poll on A, complete recovery, restore vault. | A becomes trusted, vault restores, modal closes, and registry contains approval completion plus all unrelated devices. | Primary user-reported flow. |
| TC-E2E-002 | Device C runs normal sync during every stage of TC-E2E-001. | Repeat the full flow with forced overlap. | Approval and completion remain durable despite concurrent refreshes and heartbeat writes. | Production-like concurrency. |
| TC-E2E-003 | Device B is offline when R1 is created, then reconnects before expiry. | Reconnect, approve, and poll. | Approval succeeds if still within expiry; polling delay does not invalidate a timely response. | Offline trusted device. |
| TC-E2E-004 | Device B comes online after R1 expires. | Attempt approval. | Approval is rejected as expired and A receives a clear retry path. | Expiry boundary. |
| TC-E2E-005 | Device A has no trusted device available. | Use new-token recovery. | Token-rotated recovery succeeds independently and does not reuse stale approval state. | Fallback recovery path. |
| TC-E2E-006 | QR Link New Device is used while normal sync is active on the source device. | Create invite, scan, consume, and sync. | Device links once, invite is consumed once, and existing vault/registry state is preserved. | QR and sync concurrency. |
| TC-E2E-007 | GitHub returns intermittent 429 and 500 responses during the flow. | Retry through the full approval window. | No destructive fallback occurs; the user sees temporary errors and can retry safely. | Realistic service instability. |
| TC-E2E-008 | The app is killed at each boundary: before upload, after upload, before cache write, and during restore. | Restart and resume. | Remote committed state is recovered; uncommitted state is retried or reported without duplication. | Crash and ambiguous-completion safety. |
| TC-E2E-009 | Three devices perform different registry operations at once: approval, recognition, and revoke. | Run all operations from the same initial registry. | Final state follows the documented conflict and security policy; no unrelated operation disappears. | Multi-writer stress case. |
| TC-E2E-010 | A controlled repository is inspected after a successful approval followed by a competing refresh. | Compare commit order and decrypt each registry version with test keys. | No committed pending snapshot follows the approval unless a documented newer request was created. | Confirms the original stale-writer defect is eliminated. |

### Test completion gate

Implementation must not be considered complete until:

- all `READ`, `CON`, and `STATE` cases pass;
- all security cases pass with no destructive fallback;
- all modal cases pass on supported platforms;
- at least one real GitHub conflict is reproduced and resolved correctly;
- the focused Flutter tests and full test suite pass;
- static analysis passes without new errors;
- no test requires exposing a real GitHub token, recovery phrase, root key, or
  production registry contents.

## Untested and partially tested cases — initial audit 2026-11-22

Historical snapshot: the local execution follow-up below supersedes these
statuses and counts. Original requirements and expected results are retained.

This audit compares the actual test fixtures and assertions with every original
trusted-device checklist row and the earlier Desktop/MCP verification requirements.
A passing test name does not establish that every requirement in its corresponding
checklist row was exercised. This is an evidence audit, not a measured code-coverage
report.

Of the **111 original trusted-device cases**, **27 have not been run** and **48
are partially tested**. The remaining **36 have no identified gap in local test
coverage**; they still require the applicable live-service and platform acceptance
checks below. The recorded **190 passing tests and one skipped opt-in GitHub test**
do not establish completion of the checklist. No tests were run as part of this
documentation-only audit.

- **Not run:** no executed test of the exact scenario was found, or the relevant
  harness exists but has not been executed.
- **Partial:** related assertions have passed, but part of the original scenario,
  its expected results, or its required environment remains unverified.
- The missing checks below supplement the original expected results; they do not
  replace or reduce those results. Original IDs are preserved for traceability.
- Earlier recorded Linux Desktop/MCP smoke-test results are credited separately
  from the current local suite. A platform-gated test that returns early on this
  macOS host does not prove that its body ran.

| Trusted-device area | Not run | Partial |
| --- | --- | --- |
| Registry reads | 0 | 3 |
| Concurrency | 2 | 7 |
| Trust, approval, recovery, and invites | 3 | 13 |
| Cache and Settings UI | 3 | 5 |
| Recovery modal and link UI | 4 | 9 |
| Security and diagnostics | 3 | 7 |
| Migration and compatibility | 2 | 4 |
| End-to-end acceptance | 10 | 0 |
| **Total** | **27** | **48** |

### Acceptance checks that remain open across locally covered cases

These checks apply in addition to the individual gaps below. No physical-device
or full supported-platform acceptance run is recorded for the trusted-device
changes.

| Required environment / check | Scope | Evidence still needed |
| --- | --- | --- |
| Controlled real GitHub repository | Conflict/retry cases, including locally covered cases, and TC-E2E-010 | Execute the skipped live conflict harness, repeat high-risk interleavings, and inspect/decrypt test-file revision history with redacted diagnostics. |
| Supported platforms | All TC-MODAL-001 through TC-MODAL-016 and applicable Settings/link flows | Record actual rendering, lifecycle, cancellation, retry, QR/manual transfer and PIN behavior on each supported platform. |
| Independent writers | TC-CON-011 and multi-device E2E cases | Use separate processes/isolates and independent local storage; in-process remote hooks do not exercise process isolation. |
| Process termination and persistent restart | TC-OBS-005, TC-OBS-006, TC-E2E-008 | Kill/restart at each persistence boundary and recover from persisted local/remote state. |
| Browser clock behavior | TC-STATE-013 | Exercise positive/negative clock skew in the browser. GitHub CORS hides Date in browsers, so local UTC fallback cannot establish strict server-time expiry under arbitrary client clock skew. |
| Desktop distribution and lifecycle | Earlier Desktop/MCP Phases 0, 4, 5 and 6 | Record Windows/macOS/Linux release launch, lifecycle, host integration and applicable signing/notarization checks; earlier Linux smoke tests and the web build cover only their recorded environments. |

GitHub-backed storage still relies on polling and optimistic concurrency. These
checks must distinguish ordinary polling delay from stale writes and premature
local success. Older clients can still overwrite registry state, so mixed-version
behavior also remains an acceptance concern.

### Trusted-device checklist gaps

#### Registry reads

| ID | Status | Scenario / requirement | Existing evidence | Missing verification |
| --- | --- | --- | --- | --- |
| TC-READ-010 | Partial | Timeout/offline during registry read | Protocol normalizes timeout/network exceptions; Settings failure uses HTTP 500. | Inject timeout and offline errors into a refresh with a populated cache; assert stale UI, cache preservation, and zero PUTs. |
| TC-READ-011 | Partial | Empty or malformed existing content | Protocol rejects empty/invalid Base64; registry tests reject junk bytes. | Seed a known cache first, then inject each invalid-content variant and assert the cached data survives unchanged. |
| TC-READ-012 | Partial | Authenticated ciphertext corruption or wrong key | Wrong-key and short-junk rejection are exercised. | Flip bytes in a valid encrypted registry with an existing cache; assert authentication failure, stale metadata, preserved data, and no upload. |

#### Concurrency

| ID | Status | Scenario / requirement | Existing evidence | Missing verification |
| --- | --- | --- | --- | --- |
| TC-CON-001 | Partial | Approval versus heartbeat | Heartbeat test preserves an injected approved status. | Use a valid competing approval with response metadata, then assert it is still valid through getDeviceApprovalStatus/completion; run the skipped live conflict harness. |
| TC-CON-002 | Partial | Recognition versus stale refresh | Recognition races an approval; recognized refresh is tested sequentially. | Force recognition and a heartbeat/refresh from the same SHA in both commit orders; assert both changes survive. |
| TC-CON-003 | Partial | Two different concurrent approvals | Both status fields survive a hook-injected update. | The competing approval lacks respondedAt/responder metadata. Exercise two valid approval responses and verify both remain usable. |
| TC-CON-007 | Not run | Create one invite while consuming another | Approval-versus-consumption and ambiguous invite creation cover different combinations. | Run invite creation and consumption against the same SHA and verify both invites/devices plus unrelated data. |
| TC-CON-011 | Not run | Separate-isolate/process writers | A hook emulates a remote writer in one test isolate. | Run actual independent isolates/processes with independent device storage against the same registry. |
| TC-CON-012 | Partial | Re-encryption on every conflict | Encrypted rebasing and conflict retries pass. | Capture each attempted ciphertext and expected SHA; verify fresh ciphertext is generated from each new snapshot rather than reused. |
| TC-CON-013 | Partial | Idempotent no-op mutations | Repeated completion and approval avoid extra uploads. | Re-recognize an already recognized/trusted device and assert no extra commit or metadata rewrite. |
| TC-CON-014 | Partial | Target disappears or is revoked during retry | Refresh and approver-revocation races are covered. | Delete/revoke the recognition or completion target between GET and PUT; verify each operation rejects or safely does nothing. |
| TC-CON-015 | Partial | PUT commits but response is lost | Approval response, invite creation, and request creation have response-loss tests. | Exercise ambiguous recovery completion, invite consumption, recognition, revocation, and token rotation; assert durable idempotent state. |

#### Trust, approval, recovery, and invites

| ID | Status | Scenario / requirement | Existing evidence | Missing verification |
| --- | --- | --- | --- | --- |
| TC-STATE-001 | Partial | Baseline successful approval metadata | Status becomes approved and a repeated response is a no-op. | Assert responder ID/name and response timestamp, and preserve that exact response through retries. |
| TC-STATE-002 | Not run | Deny a pending request through the mutation API | Tests inject denied state or return a mocked denied status. | Call respondToDeviceApproval with approved: false; verify metadata, persistence, and rejection of later approval. |
| TC-STATE-004 | Partial | Complete a timely approval after expiry | Status polling accepts a timely response observed late. | Complete that same request after expiry and assert durable registration and completion metadata. |
| TC-STATE-005 | Partial | Already-approved request cannot be reversed | A matching repeated approval avoids another write; denial-winning race is tested. | Attempt denial after an approved response has committed; assert the original response fields remain unchanged. |
| TC-STATE-010 | Not run | Request removed before a completion retry | A completed request without a device is tested, which is a different case. | Remove the approval after completion reads it, force conflict, and assert no implicit request/device resurrection. |
| TC-STATE-011 | Not run | Recognize an already linked/trusted registration | Linked refresh and trusted metadata during completion are tested. | Recognize existing link/setup/recognized records and verify their trust method and link metadata are preserved without uploads. |
| TC-STATE-012 | Partial | Concurrent refresh must not downgrade recognition | Sequential refresh of a recognized record passes. | Force a conflict and a real refresh mutation using stale unverified/legacy local registration. |
| TC-STATE-013 | Partial | Positive and negative clock skew across the flow | One future server-time/equality case and a no-Date fallback case pass. | Exercise both skew directions through request/response/poll/completion and browser runtime. Strict server expiry with hidden Date remains an acknowledged capability limit, not a passed guarantee. |
| TC-STATE-014 | Partial | Malformed/missing expiry on an otherwise pending request | The combined malformed-state loop returns expired. | Each iteration mutates the previous fixture; status remains null before expiry variants run. Isolate each expiry variant with status: pending and assert the expiry-specific result. |
| TC-STATE-015 | Partial | Valid invite consumed through QR linking | Direct registry refresh consumes an invite and registers link state. | Exercise transfer-code/QR decoding and PIN verification through the real link screen, then confirm durable registration. |
| TC-STATE-016 | Partial | Expired invite cannot establish trust | A test named expired invite actually supplies no matching invite. | Provide an existing invite whose expiresAt is in the past, including the equality boundary, and verify no trust upgrade or consumption. |
| TC-STATE-017 | Partial | Invite replay by the same or another device | Different-device replay is rejected; ordinary later refresh is a no-op. | Explicitly replay the consumed invite ID on the original device and race two consumers; assert one trusted registration and no duplicates. |
| TC-STATE-018 | Partial | Missing scanned invite is visibly rejected | New registration with a missing invite is rejected without writing. | Verify the link screen displays the warning after real key transfer and does not falsely report confirmed trust. |
| TC-STATE-019 | Partial | Revoke invalidates related pending work | Revocation removes the target's approvals and created invites. | Attempt to process those stale records after revocation, including concurrent consumption/completion, and verify they cannot restore trust. |
| TC-STATE-021 | Partial | Explicit relink of a revoked device | Fresh-token relink and token-rotated recovery pass. | Relink a revoked identity with a valid new invite and prove only that successful transaction removes its tombstone. |
| TC-STATE-022 | Partial | Unknown statuses/methods stay safe and intact | Unknown approval status is read as unusable. | Display an unknown registration method as requiring review and mutate an unrelated record without deleting/changing the unknown state. |

#### Cache and Settings UI

| ID | Status | Scenario / requirement | Existing evidence | Missing verification |
| --- | --- | --- | --- | --- |
| TC-CACHE-001 | Partial | Cache observation metadata | Successful reads populate the cache; SHA presence and stale flag have assertions. | Assert the exact observed remote SHA, observation timestamp/clock source, and scope after a successful Settings read. |
| TC-CACHE-005 | Partial | All refresh failures preserve stale cache | HTTP failures are tested with existing cache; invalid ciphertext/wrong key reject writes separately. | Seed a cache and exercise timeout, offline, and authentication/decryption failure with upload enabled; assert stale metadata and unchanged data. |
| TC-CACHE-006 | Partial | Pending card disappears after confirmed approval | The test named fresh approval replaces the remote document with devices: [] and removes the approval list. | Keep the request and devices, transition that request to approved/completed remotely, and verify the pending card/cache update. |
| TC-CACHE-007 | Partial | Three-second polling without overlapping loads | Settings polling observes changed data and is read-only. | Hold a read open across several timer ticks, assert one in-flight load, then verify latest state and zero writes. |
| TC-CACHE-008 | Not run | Settings disposed/inactivated during an in-flight refresh | Modal disposal is tested; Settings inactivity is tested after reads finish. | Delay a Settings response, navigate away/dispose, then complete or fail it; assert no unsafe setState or remote write. |
| TC-CACHE-009 | Partial | Reactivation after a failed refresh | Tab reactivation and explicit recovery from failure are tested separately. | Fail a read, deactivate/reactivate Settings, and verify stale data stays non-actionable until a new read succeeds. |
| TC-CACHE-010 | Not run | Dismissal cannot mask later trust changes | Dismissal reconciliation exists in application code. | Dismiss an unverified warning, change its remote trust state and change it back, then assert the intended renewed warning. |
| TC-CACHE-011 | Not run | Recognition commits but following UI refresh fails | Recognition and unrelated Settings read failures pass independently. | Combine a successful recognition action with a failing follow-up read; verify stale display and no write-back of old state. |

#### Recovery modal and link UI

| ID | Status | Scenario / requirement | Existing evidence | Missing verification |
| --- | --- | --- | --- | --- |
| TC-MODAL-001 | Partial | Complete request-to-restore happy path | Widget callbacks prove polling and commit-before-close; registry operations are tested separately. | Wire request creation, another device's response, real completion, local credential setup, and vault restore through the Settings flow. |
| TC-MODAL-003 | Partial | Timely response observed after expiry in the modal | Late status acceptance and ordinary widget dismissal pass separately. | Drive the modal with the real status/completion path after expiry and assert successful registration/dismissal. |
| TC-MODAL-004 | Partial | 409 during completion closes the modal after retry | Registry completion rebases; widget completion is a supplied callback. | Run the modal with a conflict-capable registry service and assert retry plus durable registration before dismissal. |
| TC-MODAL-005 | Not run | Old/stale writer overwrites approval before completion | Generic completion errors are recoverable in a widget test. | Overwrite approved state using an old-client-style write between polling and completion; verify clear failure and no false success. Old clients can still cause this. |
| TC-MODAL-006 | Partial | Late approval produces terminal expiry | Registry rejects late approval and the widget handles a mocked expired status. | Feed a late approved record through the real modal polling path and assert zero registration/completion attempts. |
| TC-MODAL-008 | Partial | Repeated offline polling failures | One failed check followed by a successful manual retry is tested. | Keep the modal offline across several automatic polls and through expiry; verify bounded polling, correct messaging, and safe recovery. |
| TC-MODAL-009 | Partial | Offline after approval, before completion | A callback throws once and succeeds on manual retry. | Inject the failure in real registry I/O and assert reconnection completes once without duplicate device records. |
| TC-MODAL-010 | Not run | Vault restoration fails after registration commits | The modal durability test never runs a restore. | Fail the actual restore service after commit; assert modal dismissal, separate error guidance, and a usable retry path. |
| TC-MODAL-012 | Partial | Mobile suspend/resume | Synthetic lifecycle notifications trigger a new check. | Run on supported physical platforms with actual timer suspension/backgrounding and approval while suspended. |
| TC-MODAL-013 | Partial | Cancel a denied or expired request | The terminal-state widget tests retry first, then cancel the new pending request. | Cancel directly from denied and expired states; assert dismissal and zero mutations/local trust changes. |
| TC-MODAL-014 | Partial | New-token recovery after expiry | Widget callback returns true; token-rotation core test uses a separate fixture. | Exercise the actual new-token dialog with an expired approval, real transactional rotation, credential persistence, and restore. |
| TC-MODAL-015 | Not run | QR/manual transfer and PIN happy path | Registry invite state is exercised directly. | Run both scan and entered transfer code through PIN verification and screen dismissal; verify no recovery modal. |
| TC-MODAL-016 | Not run | Link warning after key transfer succeeds but registration fails | Registry rejects failed/missing invites. | Inject failure through the link screen and verify web/native warnings, including the subsequent initial-sync outcome. |

#### Security and diagnostics

| ID | Status | Scenario / requirement | Existing evidence | Missing verification |
| --- | --- | --- | --- | --- |
| TC-SEC-004 | Partial | Tampered authenticated registry with existing cache | Wrong keys and short invalid bytes fail safely. | Modify valid ciphertext, then run read, refresh, and normal sync with a prior cache; verify stale preservation and no upload. |
| TC-SEC-005 | Partial | No secrets in success and failure logs | Captured logs cover one successful approval after two conflicts; protocol errors are sanitized separately. | Capture no-conflict, failure, retry-exhaustion, and completion logs with token/key/mnemonic/vault canaries; assert none leak. |
| TC-SEC-008 | Partial | Opaque identity matching for case and whitespace | Recognition distinguishes phone from Phone despite equal display names. | Exercise whitespace-distinct IDs and registration/revocation as well as recognition; assert no other record changes. |
| TC-OBS-001 | Partial | Successful no-conflict diagnostics | Diagnostics are captured only for an approval with two conflicts. | Capture no-conflict approval and completion; assert operation, hashes, read/committed SHA, outcome, and elapsed time. |
| TC-OBS-002 | Partial | Conflict diagnostic contract | The captured event asserts conflicts == 2, ID hashes, and clock source. | Assert the final committed SHA and outcome and exclude payload/ciphertext logging throughout all retry events. |
| TC-OBS-003 | Partial | Exhaustion logs do not claim success | Typed conflict exhaustion and stale cache are asserted. | Capture diagnostics and assert failed outcome, attempt/conflict count, HTTP status, and absence of any success event. |
| TC-OBS-004 | Partial | Read error classification in diagnostics/UI | Protocol exceptions and generic unavailable UI are tested separately. | Capture each read-error category through the real UI/service path and verify its diagnostic classification and safe user-visible treatment. |
| TC-OBS-005 | Not run | Restart after commit, before cache write | Response loss and cache-write exceptions simulate adjacent failures. | Terminate/restart at the commit/cache boundary with persisted independent state, then verify reconstruction from remote. |
| TC-OBS-006 | Not run | Restart with an uncommitted optimistic cache | Current implementation writes cache after commit. | Seed an old-client/negative pre-commit cache and restart; prove it cannot authorize pending work. Do not manufacture this ordering in the new writer. |
| TC-OBS-007 | Not run | Rapid real commits and repository-history correlation | Live integration harness is skipped. | Inspect/decrypt controlled test-file revisions and correlate commit sequence with redacted operation diagnostics. |

#### Migration and compatibility

| ID | Status | Scenario / requirement | Existing evidence | Missing verification |
| --- | --- | --- | --- | --- |
| TC-MIG-001 | Partial | Upgrade from an existing legacy cache | Fixtures omit optional remote fields; cache normally starts empty. | Preseed the old JSON-only cache without SHA metadata and verify safe upgrade only after confirmed remote observation. |
| TC-MIG-002 | Partial | Legacy sync/recovery records in Settings | Legacy methods occur in registry fixtures. | Display both legacy methods, refresh/mutate unrelated entries, and assert classification and metadata preservation. |
| TC-MIG-003 | Not run | Old approved record lacks respondedAt | Pending records without respondedAt are not this scenario. | Poll and attempt completion for an approved legacy record with the response timestamp absent; assert no registration. |
| TC-MIG-004 | Partial | Future fields and unknown status survive unrelated mutation | Unknown fields survive a heartbeat; unknown statuses are read independently. | Combine both in one registry, mutate an unrelated device, and assert the future status/fields survive exactly. |
| TC-MIG-005 | Not run | Corrupt cache with valid remote data | Another repository's valid JSON cache is rejected. | Supply malformed JSON for the cache and open Settings with valid remote state; verify recovery and fresh replacement. |
| TC-MIG-006 | Partial | Unavailable/closed Hive storage | A cache-write override throws after a successful remote commit. | Exercise closed/unavailable initialization, cache reads and pre-commit storage, plus UI reporting. Preserve the documented successful-commit policy for failures after PUT. |

#### End-to-end acceptance

| ID | Status | Scenario / requirement | Existing evidence | Missing verification |
| --- | --- | --- | --- | --- |
| TC-E2E-001 | Not run | Recovery phrase to restored trusted device | Core and widget stages pass independently. | Execute the full flow on independent devices with real credentials and verify durable registry plus restored vault. |
| TC-E2E-002 | Not run | Recovery while a third device syncs | Pairwise interleavings are simulated. | Overlap a real third device's normal sync with request, response, completion, and restoration. |
| TC-E2E-003 | Not run | Trusted device reconnects before expiry | Timely status logic is tested without a disconnect/reconnect journey. | Run the full offline-then-online-before-expiry approval flow and verify requester completion. |
| TC-E2E-004 | Not run | Trusted device reconnects after expiry | Core expiry and widget terminal states pass independently. | Run late reconnection, rejected approval, and visible new-request retry end to end. |
| TC-E2E-005 | Not run | No trusted device; recover with a new token | Core rotation and a mocked fallback callback pass independently. | Complete real new-token validation, registry mutation, local setup, and restoration. |
| TC-E2E-006 | Not run | QR linking while the source syncs | Invite consumption and approval-versus-consumption are modeled. | Create/scan/verify/consume a real invite while source sync runs; assert one registration and preserved vault. |
| TC-E2E-007 | Not run | Intermittent rate limits and server failures across the flow | Individual HTTP errors and retryable UI are tested. | Alternate 429/500 and success over the whole approval window through recovery/restore. |
| TC-E2E-008 | Not run | Kill/restart at every persistence boundary | In-process response loss/cache exceptions are covered. | Terminate before/after PUT, before cache persistence, and during restore; restart and verify no duplicated or falsely confirmed trust. |
| TC-E2E-009 | Not run | Approval, recognition, and revoke from three writers | Pairwise and repeated generic competing writes pass. | Run all three logical operations from one initial SHA on independent devices and verify the complete final state. |
| TC-E2E-010 | Not run | Inspect actual encrypted revision history | The real-conflict harness exists but was skipped and does not audit history. | Run a controlled live scenario and decrypt successive test revisions to verify no stale pending state follows approval. |

### Earlier Desktop/MCP plan: remaining verification gaps

The original Desktop/MCP plan expresses many requirements as prose rather than
numbered test cases. The following **22 audit rows** use new `MCP-GAP-*` IDs to
identify those requirements; they are separate from the 111 trusted-device
checklist cases and their totals. **4 are not run and 18 are partial.**
Implementation status and existing CI configuration alone are not evidence that
the acceptance checks ran.

| ID | Status | Scenario / requirement | Existing evidence | Missing verification |
| --- | --- | --- | --- | --- |
| MCP-GAP-001 | Partial | Unit: protocol arguments, pagination, bounded output | HTTP request-size/rate boundaries are tested; service tests cover selected tools. | Add invalid-argument, pagination/cursor, output-boundary, and protocol-version cases for every exposed tool/resource. |
| MCP-GAP-002 | Partial | Unit: every permission combination and tag rule | Selected permission/tag combinations, archive access, content restrictions, and backlink scope pass. | Exercise the full permission/write-policy/tag allow/deny matrix, including updates and multiple clients. |
| MCP-GAP-003 | Partial | Unit/integration: malformed credentials | Missing authorization, hashing, rotation, disabling, and revocation are covered. | Exercise malformed bearer/profile/discovery values and credential persistence/reload failures across both transports. |
| MCP-GAP-004 | Partial | Unit: all vault terminal states and actual application hooks | Starting/unlocking/unlocked/lock/duress/revoked state checks and a desktop lock-action widget pass. | Exercise wipe, timeout, quit and device-revocation application hooks; assert active MCP reads/writes stop in every transition. |
| MCP-GAP-005 | Partial | Unit/UI: every write approval policy and cancellation path | Allow-always, denial, timeout, lock cancellation, and selected pending-write races are covered. | Test allow-once versus persistent exemption through the actual approval UI, permission changes while pending, and each user-cancel path. |
| MCP-GAP-006 | Partial | Unit: activity redaction and retention | The denied HTTP write checks one activity result. | Seed secret/body canaries, exceed retention bounds, reload history, and verify redaction and expiry. |
| MCP-GAP-007 | Not run | Integration: resource listing | HTTP initialization, tool listing, and selected calls pass. | List and read MCP resources with permitted, locked, revoked, and restricted clients; assert the resource contract. |
| MCP-GAP-008 | Partial | Integration: complete CRUD persisted in the real encrypted repository | HTTP/service tests use MemoryNotesRepository; ordinary repository tests run separately. | Drive create/edit/append/archive/delete through MCP into real storage, reopen it, and verify encryption and final contents. |
| MCP-GAP-009 | Partial | Integration: actual UI edit racing an MCP edit | A service test simulates a repository edit during approval. | Race the real notes UI and MCP against the same persisted note; verify conflict behavior and no lost updates. |
| MCP-GAP-010 | Not run | Integration: GitHub scheduling and offline MCP writes | Registry/vault sync tests and MCP mutation tests run separately. | Verify MCP writes schedule sync, persist offline, and later reach a controlled repository without loss or duplication. |
| MCP-GAP-011 | Partial | Hardening: malformed JSON, fuzzing, and sustained load | Origin/host rejection, one oversized body, and a rate-limit burst are exercised. | Run malformed/truncated JSON and protocol fuzz corpora, long-running/concurrent load, bounded-output and stdio framing/size cases. |
| MCP-GAP-012 | Partial | Integration: lock at every active read/approval/pre-commit boundary | Selected service read and approval lock/revocation races pass. | Block actual repository persistence immediately before commit and exercise lock/duress/wipe/quit without mutation or data leakage. |
| MCP-GAP-013 | Partial | Integration: desktop crash and stale-discovery recovery | A Linux-only test uses a stale endpoint and expects desktop_unavailable; earlier real Linux flows are recorded. | Crash and restart Desktop with stale discovery/profiles, then verify reconnection and credential safety. The Linux-only test returns early on this macOS host, so its passing count is not execution evidence here. |
| MCP-GAP-014 | Partial | Phase 4: two independent MCP hosts and per-client isolation | Real Linux HTTP/stdio smoke flows are recorded; HTTP tests exercise individual credentials. | Use two independent host applications with different permissions simultaneously; revoke one and verify the other's session survives. |
| MCP-GAP-015 | Partial | End-to-end desktop checklist steps 1–10 | Earlier Linux note flows plus component HTTP/session/approval tests are credited. | Record the complete locked-to-unlock/connect/approve/deny/conflict/revoke/quit/restart journey, with persisted permissions, on Windows, macOS, and Linux. |
| MCP-GAP-016 | Partial | Security: LAN exposure and IPv6 loopback behavior | HTTP tests exercise loopback plus rejected Host/Origin headers. | Probe from another network host and test IPv6 binding/loopback behavior where enabled; verify no LAN listener. |
| MCP-GAP-017 | Partial | Security: logs, crash output, and activity contain no secrets | Credential hashing/storage assertions and one denied activity entry pass. | Capture success/failure/crash/bridge logs and activity using note-body and credential canaries on all desktop platforms. |
| MCP-GAP-018 | Not run | Security: discovery/profile file permissions and ACLs | No automated permission/ACL assertions were found in the MCP suite. | Validate owner-only access on Linux/macOS and Windows ACLs, including after creation, rotation, update, and restart. |
| MCP-GAP-019 | Partial | Security: notes-only reachable surface | Tool listing checks required note tools and their annotations. | Assert the entire exposed tools/resources surface excludes passwords, TOTP, SSH, GitHub, recovery and device linking, and probe forbidden access paths. |
| MCP-GAP-020 | Not run | Phase 5: desktop lifecycle/distribution matrix | Implementation and CI definitions are present. | Record install/upgrade/uninstall, tray versus explicit quit, sign-in launch, single-instance activation, lock and sleep/resume on all three desktop systems. |
| MCP-GAP-021 | Partial | Phase 4/5: host configuration and bridge path survives update | Historical Linux bridge execution is recorded. | Use generated configuration in the supported hosts and upgrade/move the installed app; verify profile discovery, bridge path, and reconnect behavior. |
| MCP-GAP-022 | Partial | Phase 0/6: release compatibility and artifact acceptance | Historical Linux release/bridge, Android debug, and web builds are recorded; current web release passes. | Run and launch Windows/macOS/Linux artifacts and current mobile builds; verify packaging, signing/notarization/checksums and the plugin compatibility matrix where credentials/platforms are available. |

## Local test execution follow-up — 2026-11-22

Historical execution snapshot. The 2026-11-23 continuation below supersedes
this section’s counts, statuses, and remaining-check list.

The preceding audit is a **historical snapshot before this test expansion**.
This follow-up supersedes its execution statuses. The user limited execution to
**local environments only**. No production repository, token, or physical device
was used. Local HTTP adapters implement the GitHub API/CAS contract; they are
not evidence of GitHub's live behavior.

**Acceptance is still open.** The original completion gate requires a real
GitHub conflict and supported-platform modal acceptance, which cannot be
established by this local run. There are also remaining integration checks
listed explicitly below; a larger passing-test count does not close them.

Of the previous **75 trusted-device gaps**, **59 now pass locally**, **14 remain
partial**, and **2 require external execution and were not run**. The original
36 locally covered cases remain covered by the full suite. These counts describe
scenario evidence, not measured line/branch coverage.

For the **22 MCP audit rows**, **5 now pass locally**, **16 remain partial**,
and **1 is unexecuted external platform acceptance**.

### Reproduction and regression fixes

Tests uncovered the following production defects, and the corresponding fixes
are included in the working tree.

| Finding | Fix | Executed regression |
| --- | --- | --- |
| Fast approvals could have respondedAt before requestedAt because HTTP Date is rounded to whole seconds. | Validate requestedAt, tolerate only subsecond rounding by clamping the response to requestedAt, and retain strict response-before-expiry validation. Requests substantially ahead of observed time remain rejected. | `device_registry_gaps_test.dart`: fast flow, both clock-offset directions, subsecond rounding and invalid future timestamp. |
| Link screen disposed the device-name field's controller/focus during the route's closing animation. | A stateful name dialog owns and disposes those resources when unmounted. The existing GitHub factory is used for linking operations. | `device_link_integration_test.dart`: actual manual/QR callback, real PIN derivation, Save and dismissal. |
| MCP authorization could expire while encrypting a note, but persistence still occurred. | Recheck the live session/client authorization immediately before the repository commits, including all nine MCP mutation call sites. | `mcp_gap_test.dart`: hold actual encryption, then lock/duress/revoke; no note reaches Hive. |
| Actual MCP write approvals with before/after previews crashed during AlertDialog intrinsic layout. | Use the available screen width without an unsupported intrinsic LayoutBuilder. | `mcp_approval_ui_test.dart`: allow once/always, denial, cancellation and delete. |
| Settings hid the storage-unavailable error when closed Hive prevented reading credentials. | Show the recorded registry error even when credential loading failed. | `device_registry_storage_test.dart`: actual closed Hive, no PUT, visible safe error, reopen and confirmed refresh. |
| Editor autosave could overwrite a newer MCP edit. | Save against the editor's last persisted version; preserve the draft and show failed-save state on conflict. | `mcp_notes_editor_integration_test.dart`: actual editor/MCP writes in both orders, real encryption and reopened storage. |
| GitHub setup, phrase and replacement-token dialogs disposed focus/controllers before closing routes unmounted. | Wait for DialogRoute.completed before disposing resources. | `settings_recovery_integration_test.dart`: real Settings dialog chain, including invalid token and no-vault retry. |
| Phrase recovery passed the closing phrase dialog's context into approval/restoration. | Keep the caller's mounted context through the recovery chain. | `settings_recovery_integration_test.dart`: actual phrase entry, approval, durable registration, saved credentials and restored encrypted note; restore-outage guidance and retry. |

Some earlier tests also had misleading fixtures: the expiry variants reused a
previously invalid status, an “expired invite” was absent instead of expired,
and the pending-card “approval” test removed the whole request list. Those
fixtures now exercise their named states directly. The Linux-only stdio check
uses an explicit platform skip instead of silently returning on this host.

### Executed evidence and reproducible commands

Run from the repository root with Flutter 3.29.3 / its bundled Dart SDK:

```sh
flutter test --concurrency=4 --reporter expanded
flutter build web --release
dart analyze --format machine
git diff --check
```

| Final verification | Result | Local execution log |
| --- | --- | --- |
| Full native suite | **424 passed, 2 explicitly skipped, 0 failed** | `/tmp/gitvault-final-passing-suite.log` |
| Settings recovery after reusing the existing route-cleanup helper | **3 passed** | `/tmp/gitvault-final-settings-check.log` |
| Web release build | **Passed** (`build/web` generated). | `/tmp/gitvault-final-web-build.log` |
| Full static analysis | **0 errors, 11 distinct existing warnings; no new warnings/errors** compared with the preceding analysis. There are 559 distinct informational diagnostics, including style lints; analysis is not warning/lint clean. | `/tmp/gitvault-final-analysis-machine.log` |
| Working-tree whitespace check | `git diff --check` passed. | Command output |

Temporary execution logs are on this workstation. The repository test sources
provide the reproducible evidence; no changes were staged or committed.

The full suite has two intentional skips on this macOS host: the opt-in live
GitHub conflict test and the Linux-only stdio test. Neither is counted as
executed coverage. Native widget tests run in Flutter's test renderer, not an
installed macOS application.

A separate Chromium run executed the original 12 approval-modal widget tests.
Broader browser suites did not execute successfully: startup/external asset
loading stalled, and a local-asset rerun hit a browser module-loading error.
The web release build is compilation evidence, not a browser acceptance run.

### Updated trusted-device gap table

“Local passed” means the added local assertions for the audited gap passed.
All applicable external acceptance gates below still apply. “Partial” records
both the evidence obtained and the exact remaining boundary.

#### Registry reads

| ID | Current status | Scenario | Executed evidence | Remaining verification |
| --- | --- | --- | --- | --- |
| TC-READ-010 | Local passed | Timeout/offline during registry read | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-READ-011 | Local passed | Empty or malformed existing content | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-READ-012 | Local passed | Authenticated ciphertext corruption or wrong key | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |

#### Concurrency

| ID | Current status | Scenario | Executed evidence | Remaining verification |
| --- | --- | --- | --- | --- |
| TC-CON-001 | Local passed | Approval versus heartbeat | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CON-002 | Local passed | Recognition versus stale refresh | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CON-003 | Local passed | Two different concurrent approvals | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CON-007 | Local passed | Create one invite while consuming another | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CON-011 | Local passed | Separate-isolate/process writers | `test/registry_isolate_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CON-012 | Local passed | Re-encryption on every conflict | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CON-013 | Local passed | Idempotent no-op mutations | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CON-014 | Local passed | Target disappears or is revoked during retry | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CON-015 | Local passed | PUT commits but response is lost | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |

#### Trust, approval, recovery, and invites

| ID | Current status | Scenario | Executed evidence | Remaining verification |
| --- | --- | --- | --- | --- |
| TC-STATE-001 | Local passed | Baseline successful approval metadata | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-002 | Local passed | Deny a pending request through the mutation API | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-004 | Local passed | Complete a timely approval after expiry | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-005 | Local passed | Already-approved request cannot be reversed | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-010 | Local passed | Request removed before a completion retry | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-011 | Local passed | Recognize an already linked/trusted registration | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-012 | Local passed | Concurrent refresh must not downgrade recognition | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-013 | Partial | Positive and negative clock skew across the flow | `test/device_registry_gaps_test.dart` | Positive/negative native server-clock offsets pass. Browser skew remains unexecuted; hidden GitHub Date means UTC fallback cannot guarantee strict expiry under arbitrary skew. |
| TC-STATE-014 | Local passed | Malformed/missing expiry on an otherwise pending request | `test/device_recovery_approval_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-015 | Local passed | Valid invite consumed through QR linking | `test/device_link_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-016 | Local passed | Expired invite cannot establish trust | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-017 | Local passed | Invite replay by the same or another device | `test/registry_isolate_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-018 | Local passed | Missing scanned invite is visibly rejected | `test/device_link_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-019 | Local passed | Revoke invalidates related pending work | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-021 | Local passed | Explicit relink of a revoked device | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-STATE-022 | Local passed | Unknown statuses/methods stay safe and intact | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |

#### Cache and Settings UI

| ID | Current status | Scenario | Executed evidence | Remaining verification |
| --- | --- | --- | --- | --- |
| TC-CACHE-001 | Local passed | Cache observation metadata | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CACHE-005 | Local passed | All refresh failures preserve stale cache | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CACHE-006 | Local passed | Pending card disappears after confirmed approval | `test/device_registry_ui_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CACHE-007 | Local passed | Three-second polling without overlapping loads | `test/device_registry_ui_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CACHE-008 | Local passed | Settings disposed/inactivated during an in-flight refresh | `test/device_registry_ui_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CACHE-009 | Local passed | Reactivation after a failed refresh | `test/device_registry_ui_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CACHE-010 | Local passed | Dismissal cannot mask later trust changes | `test/device_registry_ui_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-CACHE-011 | Local passed | Recognition commits but following UI refresh fails | `test/device_registry_ui_test.dart` | Applicable live-service/platform gates below remain open. |

#### Recovery modal and link UI

| ID | Current status | Scenario | Executed evidence | Remaining verification |
| --- | --- | --- | --- | --- |
| TC-MODAL-001 | Local passed | Complete request-to-restore happy path | `test/settings_recovery_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-003 | Local passed | Timely response observed after expiry in the modal | `test/recovery_registry_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-004 | Local passed | 409 during completion closes the modal after retry | `test/recovery_registry_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-005 | Local passed | Old/stale writer overwrites approval before completion | `test/recovery_registry_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-006 | Local passed | Late approval produces terminal expiry | `test/recovery_registry_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-008 | Local passed | Repeated offline polling failures | `test/recovery_registry_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-009 | Local passed | Offline after approval, before completion | `test/recovery_registry_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-010 | Local passed | Vault restoration fails after registration commits | `test/settings_recovery_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-012 | Partial | Mobile suspend/resume | `test/recovery_approval_dialog_test.dart` | Synthetic lifecycle coverage remains; actual mobile suspension/background timers and approval while suspended require physical devices. |
| TC-MODAL-013 | Local passed | Cancel a denied or expired request | `test/recovery_registry_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-014 | Local passed | New-token recovery after expiry | `test/settings_recovery_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-015 | Local passed | QR/manual transfer and PIN happy path | `test/device_link_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MODAL-016 | Partial | Link warning after key transfer succeeds but registration fails | `test/device_link_integration_test.dart` | Native key-transfer/registration failure and initial-sync warnings pass. Browser-specific warning path has not executed. |

#### Security and diagnostics

| ID | Current status | Scenario | Executed evidence | Remaining verification |
| --- | --- | --- | --- | --- |
| TC-SEC-004 | Local passed | Tampered authenticated registry with existing cache | `test/recovery_restore_integration_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-SEC-005 | Local passed | No secrets in success and failure logs | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-SEC-008 | Local passed | Opaque identity matching for case and whitespace | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-OBS-001 | Local passed | Successful no-conflict diagnostics | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-OBS-002 | Local passed | Conflict diagnostic contract | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-OBS-003 | Local passed | Exhaustion logs do not claim success | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-OBS-004 | Partial | Read error classification in diagnostics/UI | `test/device_registry_gaps_test.dart`; `test/device_registry_ui_test.dart` | All service diagnostic classifications pass; UI covers timeout/network/tamper/HTTP failure. Each HTTP classification has not been driven through the actual Settings UI. |
| TC-OBS-005 | Partial | Restart after commit, before cache write | `test/registry_isolate_test.dart` | An isolate is killed after PUT before cache persistence and replacement reconstructs remote state. Disk-backed application/process restart at this boundary remains open. |
| TC-OBS-006 | Partial | Restart with an uncommitted optimistic cache | `test/registry_isolate_test.dart`; `test/device_registry_gaps_test.dart` | A replacement isolate with seeded optimistic cache cannot authorize completion. Full application restart with an actual persisted legacy optimistic cache remains open. |
| TC-OBS-007 | Not run (external) | Rapid real commits and repository-history correlation | `test/github_registry_integration_test.dart` | Requires a disposable live GitHub repository and encrypted revision-history inspection; unavailable under local-only scope. |

#### Migration and compatibility

| ID | Current status | Scenario | Executed evidence | Remaining verification |
| --- | --- | --- | --- | --- |
| TC-MIG-001 | Local passed | Upgrade from an existing legacy cache | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MIG-002 | Local passed | Legacy sync/recovery records in Settings | `test/device_registry_ui_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MIG-003 | Local passed | Old approved record lacks respondedAt | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MIG-004 | Local passed | Future fields and unknown status survive unrelated mutation | `test/device_registry_gaps_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MIG-005 | Local passed | Corrupt cache with valid remote data | `test/device_registry_ui_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-MIG-006 | Local passed | Unavailable/closed Hive storage | `test/device_registry_storage_test.dart` | Applicable live-service/platform gates below remain open. |

#### End-to-end acceptance

| ID | Current status | Scenario | Executed evidence | Remaining verification |
| --- | --- | --- | --- | --- |
| TC-E2E-001 | Partial | Recovery phrase to restored trusted device | `test/settings_recovery_integration_test.dart`; `test/recovery_restore_integration_test.dart` | Actual phrase/setup/approval/credential/restore UI and encrypted reopen pass locally. Independent physical devices and live GitHub remain open. |
| TC-E2E-002 | Partial | Recovery while a third device syncs | `test/recovery_restore_integration_test.dart` | Real third-device normal sync rebases against an injected valid response and target restores all three items. The competing response is a simulated remote writer; physical/live-service overlap remains open. |
| TC-E2E-003 | Partial | Trusted device reconnects before expiry | `test/recovery_restore_integration_test.dart` | Source offline/reconnect before expiry completes locally; full requester UI/restore in that exact journey and physical-device run remain open. |
| TC-E2E-004 | Partial | Trusted device reconnects after expiry | `test/recovery_restore_integration_test.dart`; `test/recovery_registry_integration_test.dart` | Late reconnect is rejected and a new request is usable; terminal modal logic passes separately. Full combined UI journey and physical-device run remain open. |
| TC-E2E-005 | Partial | No trusted device; recover with a new token | `test/settings_recovery_integration_test.dart` | Actual expired-request token UI rejects old/invalid/no-data tokens, commits rotation, persists credentials and restores locally. Live token access/revocation and independent physical devices remain open. |
| TC-E2E-006 | Partial | QR linking while the source syncs | `test/device_link_integration_test.dart`; `test/recovery_restore_integration_test.dart` | Actual local QR callback/manual-code/PIN flow and encrypted restoration pass. Exact source normal-sync overlap with camera/PIN linking has not been executed. |
| TC-E2E-007 | Partial | Intermittent rate limits and server failures across the flow | `test/recovery_restore_integration_test.dart` | 429/500 alternation through approval and real restoration passes at service level. The complete UI journey with errors across all stages and live throttling remains open. |
| TC-E2E-008 | Partial | Kill/restart at every persistence boundary | `test/registry_isolate_test.dart`; `test/recovery_restore_integration_test.dart` | Commit-before-cache isolate termination and encrypted-storage reopen pass. Full process kills before/after PUT and during restore remain open. |
| TC-E2E-009 | Local passed | Approval, recognition, and revoke from three writers | `test/registry_isolate_test.dart` | Applicable live-service/platform gates below remain open. |
| TC-E2E-010 | Not run (external) | Inspect actual encrypted revision history | `test/github_registry_integration_test.dart` | Requires a disposable live GitHub repository and encrypted revision-history inspection; unavailable under local-only scope. |

### Updated MCP gap table

| ID | Current status | Executed evidence | Remaining verification / limits |
| --- | --- | --- | --- |
| MCP-GAP-001 | Partial | `test/mcp/mcp_gap_test.dart`; `test/mcp/mcp_protocol_gap_test.dart` | Invalid arguments for all 16 tools, pagination and complete 103-note traversal pass. Full per-tool output-boundary and protocol-version combinations remain open. |
| MCP-GAP-002 | Partial | `test/mcp/mcp_gap_test.dart` | 80 single-grant/operation checks plus six tag combinations pass. All 512 permission subsets, all write-policy/tag/update combinations are not exhausted. |
| MCP-GAP-003 | Partial | `test/mcp/mcp_http_integration_test.dart`; `test/mcp/mcp_security_test.dart` | Malformed HTTP bearer variants reject safely. Profile/discovery corruption, persistence failures and both-transport negative matrix remain open. |
| MCP-GAP-004 | Partial | `test/mcp/mcp_gap_test.dart`; `test/mcp/vault_lock_action_test.dart` | Lock, duress and revoked states reject, including lock during real encryption. Actual wipe/timeout/quit/device-revocation hooks remain open. |
| MCP-GAP-005 | Partial | `test/mcp/mcp_approval_ui_test.dart`; `test/mcp/mcp_gap_test.dart` | Actual UI allow-once/always/deny/cancel, delete restrictions, repeat prompting and pending permission loss pass. Complete every-tool/policy/cancellation matrix remains open. |
| MCP-GAP-006 | Local passed | `test/mcp/mcp_gap_test.dart` | Persisted 31-day expiry, 1,000-record retention and note-body/title/verifier redaction pass. Platform crash/log acceptance is separate. |
| MCP-GAP-007 | Local passed | `test/mcp/mcp_protocol_gap_test.dart` | Real client/server protocol lists/reads scoped resources; lock/revoke and metadata-only rejection pass. |
| MCP-GAP-008 | Local passed | `test/mcp/mcp_gap_test.dart` | Actual encrypted create/edit/append/archive/delete, raw-storage secrecy and reopen durability pass. |
| MCP-GAP-009 | Local passed | `test/mcp/mcp_notes_editor_integration_test.dart` | Actual editor autosave versus MCP passes both orders in encrypted storage; conflicts preserve the winning edit and the editor draft. Archive/delete actions racing MCP are not covered by these text-edit tests. |
| MCP-GAP-010 | Partial | `test/mcp/mcp_gap_test.dart` | Offline CRUD and mutation callbacks pass. Actual foreground scheduling/debounce and subsequent remote synchronization have not been exercised together. |
| MCP-GAP-011 | Partial | `test/mcp/mcp_http_integration_test.dart`; `test/mcp/mcp_protocol_gap_test.dart` | Malformed/truncated JSON and all-tool invalid arguments pass. Sustained fuzz/load, stdio framing/size and exhaustive bounded-output checks remain open. |
| MCP-GAP-012 | Partial | `test/mcp/mcp_gap_test.dart` | Actual encryption is held before persistence and lock/duress/revocation prevent creation. Every read/write boundary plus wipe/quit hooks remain open. |
| MCP-GAP-013 | Partial | `test/mcp/mcp_http_integration_test.dart` | Linux-only stdio stale-endpoint case now explicitly skips on macOS; desktop crash/restart/discovery/profile matrix remains open. |
| MCP-GAP-014 | Partial | `test/mcp/mcp_protocol_gap_test.dart` | Two independent protocol sessions isolate tags and revocation. Two actual external host applications are not exercised. |
| MCP-GAP-015 | Partial | `test/mcp/mcp_approval_ui_test.dart`; `test/mcp/mcp_http_integration_test.dart` | Local components/protocol/approval integration pass. Complete installed Windows/macOS/Linux user journey remains open. |
| MCP-GAP-016 | Partial | `test/mcp/mcp_http_integration_test.dart` | IPv4 loopback plus Host/Origin defenses pass. Another network host and enabled IPv6/LAN probing remain open. |
| MCP-GAP-017 | Partial | `test/mcp/mcp_gap_test.dart`; `test/mcp/mcp_http_integration_test.dart` | Activity and malformed-protocol redaction pass. Complete success/failure/crash/bridge logs with canaries across desktop platforms remain open. |
| MCP-GAP-018 | Partial | `test/mcp/mcp_security_test.dart` | Actual macOS POSIX file permissions remain 0600 after write and rotation. Directories, Linux execution, Windows ACLs, update/restart matrix remain open. |
| MCP-GAP-019 | Local passed | `test/mcp/mcp_protocol_gap_test.dart` | Exact 16-tool surface, resource/template scope and forbidden-tool probes pass; no vault/password/SSH/recovery tools are reachable. |
| MCP-GAP-020 | Not run (external) | Platform acceptance | Installed-app lifecycle, tray/quit, login launch, single instance, upgrades/uninstall and sleep/resume need supported platform installations. |
| MCP-GAP-021 | Partial | Earlier Linux smoke evidence; configuration implementation | Actual host configuration after installed-app update/move/restart is not executed locally. |
| MCP-GAP-022 | Partial | Current web release build; earlier recorded platform builds | Current web build and native test suite are verified locally. Windows/macOS/Linux artifact launch/signing/notarization and current mobile/compatibility matrix remain open. |

### Remaining local integration checks

These have not been turned into passing claims:

- Drive every HTTP diagnostic classification through the actual Settings UI;
  current category assertions and safe UI failure assertions partly run separately.
- Combine late trusted-source reconnection/new-request retry with the complete
  requester UI and restoration in that exact journey.
- Overlap source normal sync with the actual QR/manual/PIN link screen.
- Exercise intermittent 429/500 failures at every UI stage, including final
  restore, instead of relying on the service journey plus separate UI retries.
- Persist legacy optimistic cache to disk and restart a full app/process; kill
  at every before/after-PUT, cache and restore boundary. The isolate tests kill
  a real worker but keep the remote authority in the parent and copy independent
  memory cache into the replacement worker.
- Complete the MCP permission/policy/tag combination matrix, active
  read/write/approval transitions for wipe/quit/timeout, actual foreground sync
  scheduling after MCP writes, sustained fuzz/load, and the full stdio
  negative/profile/discovery/restart matrix.
- Probe archive/delete actions racing MCP separately from the verified editor
  text-autosave race. Complete process-log redaction, directory modes and
  discovery/profile persistence-failure checks.

### External acceptance gates under the local-only constraint

| Gate | Still needed |
| --- | --- |
| Live GitHub | Run the opt-in harness against a disposable repository; observe actual 409/422 conflicts, branch behavior, response loss and throttling, and decrypt revision history to correlate commits with diagnostics. |
| Physical devices | Actual camera scan and PIN entry, mobile background suspension/resume and timer behavior, independent-device journeys and slow/offline transitions. |
| Browser | Complete Settings/link UI execution, web-specific warnings and positive/negative skew. Hidden GitHub Date remains a capability limit for strict expiry under arbitrary client-clock skew. |
| Full process restart | Application termination at all persistence boundaries with independently persisted local state and durable remote authority. |
| Desktop lifecycle/security | Windows/macOS/Linux installed-app host integration, external MCP hosts, IPv6/LAN checks, filesystem/ACL matrix, login/tray/quit/sleep/restart/update/uninstall. |
| Release artifacts | Supported desktop/mobile builds and launches, plugin compatibility, signing/notarization/checksums. A native macOS release cannot be validated on this host without full Xcode. |

GitHub remains a polling transport. Transactional CAS/rebase prevents covered
stale writes among updated clients; it does not provide realtime notifications.
An old client can still overwrite newer registry state. Both limits are
represented by tests/remaining acceptance requirements rather than claims of
realtime synchronization or complete mixed-version protection.


## Local test continuation — 2026-11-23 through 2026-11-24

This historical execution record superseded the two earlier audits. The
round-four continuation below is now authoritative for current results and gaps.
Execution remains **local only**: no live GitHub repository, physical devices,
external AI host installations, or other OS runners were used. Native widget
tests, headless Flutter subprocesses and **107 passing Chromium tests** now run
locally. These do not establish installed-app or cross-browser acceptance.
A passing matrix describes its defined inputs, not every
possible tag, document, protocol payload, or operating-system event.

**The feature is not certified fully tested.** Substantial local gaps are now
closed, but the remaining local and external checks below are still open.
The current trusted-device audit has **63 locally passed, 10 partial, and
2 external/unexecuted rows** among the original 75 gaps. The other 36 original
cases retain their earlier coverage. The MCP audit has **8 locally passed,
13 partial, and 1 external/unexecuted row**.

### Additional defects reproduced and fixed

| Defect | Confirmed failure | Fix and regression evidence |
| --- | --- | --- |
| Editor archive overwrote a newer MCP edit. | Archiving changed persisted `MCP content` back to the editor's old `Body`. | Archive uses `updateNoteIfUnchanged`; six real editor/MCP races cover autosave, archive and delete in both orders, draft preservation, successful actions and encrypted reopen. |
| Editor delete removed a newer MCP edit. | The stored note disappeared after MCP saved a newer version. | Delete uses `deleteNoteIfUnchanged` after its own save queue settles, so a completed local autosave advances the expected version. Conflicts preserve the newer note and keep the editor open. |
| Bridge errors exposed profile/discovery source text. | Malformed JSON printed the token canary to stderr through `FormatException`. | Bridge emits fixed configuration, connection and resource-failure messages; real subprocess failures verify no token canary in logs and no protocol output on startup failure. |
| Inactivity lock left the MCP preview visible. | The vault locked and pending write was cancelled, but `AI app request` remained visible over the locked screen. | Approval-host disposal removes its own root-navigator dialog after the frame; the actual authentication-gate timeout test asserts the preview disappears. |
| Failed desktop discovery persistence left an HTTP listener running. | Obstructing `discovery.json` made startup report an error, but the assigned port still accepted connections. | Startup failure now closes its listener and sessions before reporting failure. An isolated real process verifies the failed port refuses connections and retry reuses that port. |
| Explicit desktop quit left the vault session unlocked. | The actual quit hook completed without revoking session access. Already approved operations could remain authorized during asynchronous shutdown. | Quit locks the session synchronously before stopping transports. Stop cancels pending approvals even without an active listener. Twelve actual application-hook cases cover approval, encryption and decryption boundaries across quit, wipe, inactivity lock and device revocation. |

The new tests also corrected test-harness problems: restore callbacks finish
after modal dismissal; changing `debugPrint` must be undone before widget-test
invariants run; and real Hive/crypto work needs real I/O time plus widget frames,
including during shutdown. These are harness corrections, not product fixes.
The linking overlap test now saves the device name before releasing source sync:
it asserts visible registration progress, an unconsumed invite, no target trust
and no completed navigation while registration is queued. Its earlier assumption
that naming had not appeared yet depended on native frame timing and did not
prove the intended registration overlap.

### Additional executed local cases

| Area / IDs | Test cases and corner cases now executed | Evidence |
| --- | --- | --- |
| TC-OBS-004 / TC-CACHE-005 | Actual Settings UI receives timeout, network, corrupted authenticated ciphertext, 401, 403, 404, 429, 500 and invalid-data failures. Every case verifies stale-cache retention, unchanged SHA/data, matching diagnostic classification, hidden Approve controls, no writes and token redaction. | `test/device_registry_ui_test.dart` |
| TC-E2E-003/004 | Trusted source cannot approve while offline; reconnect before expiry restores through actual phrase/setup/approval UI. Reconnect after expiry is rejected; terminal UI creates a distinct new request, which completes and restores. | `test/settings_recovery_integration_test.dart` |
| TC-E2E-007 | Actual requester UI retries alternating 429/500 registry reads and completion PUTs without persisting recovery keys early. Final restoration separately fails with 429, 500 or 503, displays guidance, preserves trust/credentials, and succeeds on retry. | `test/settings_recovery_integration_test.dart` |
| TC-E2E-007 setup/request/source response | Two additional complete journeys inject 429 and 500 failures during repository validation, index inspection, request GET/PUT and source approval GET/PUT. The source and requester run separate actual Settings interfaces and storage. Exhaust all four ambiguous-500 PUT attempts, check no premature keys/credentials/trust or duplicate request, retry source refresh/approval, then restore the encrypted note. | `test/settings_recovery_integration_test.dart` |
| TC-E2E-006 | Hold an actual source normal-sync registry read while the real QR callback/manual-code/PIN screen transfers keys and queues registration. Release sync, verify both devices and invite consumption, then discard local notes and restore the source's encrypted edit. Both QR-event and manual-code variants pass. | `test/device_link_integration_test.dart` |
| TC-OBS-005/006 / TC-E2E-008 | Ten real SIGKILL boundaries: before PUT, after durable PUT, before confirmed-cache write, after flushed cache, after registration, before key storage, after flushed key storage, before restore, after a flushed partial note restore, and after restore. Replacement Flutter processes reopen disk-backed Hive against a durable encrypted remote-file authority; repeated retry is idempotent. A separate process persists a legacy optimistic cache; a fresh process refuses trust when authority is pending. | `test/registry_process_restart_test.dart`; `test/support/registry_process_probe.dart` |
| MCP-GAP-002 | **129,024 operation checks**: all 512 permission subsets × 2 write policies × 6 tag scopes × 21 operations, covering all 16 tool categories plus archived visibility, tag-removal/private/mixed-tag updates, daily-note creation and append to new/existing daily notes. Check error codes, unchanged storage on rejection, content visibility, prompt counts and the extra create permission needed for a new daily note. | `test/mcp/mcp_permission_matrix_test.dart` |
| MCP-GAP-005 | **90 approval cases**: 9 write paths × 2 policies × 5 decisions. Allow once/always, deny, timeout and client cancellation; delete always prompts and never gains an exemption. Rejections preserve notes; successes mutate. Actual approval UI tests remain part of the suite. | `test/mcp/mcp_gap_test.dart`; `test/mcp/mcp_approval_ui_test.dart` |
| MCP-GAP-004/012 | **119 additional authorization-boundary cases**: hold actual encryption for 8 write paths, actual decryption for 8 read paths, and queue actual deletion behind a held local write; change lock, duress, device revocation, client revocation, permissions, tags or policy. No unauthorized persistence or read result; no lingering approvals. | `test/mcp/mcp_gap_test.dart` |
| MCP-GAP-004/012 application hooks | **12 actual application-hook cases**: Settings Wipe Everything, foreground trust revocation, BiometricGate inactivity timeout and desktop quit each run against pending approval, actual encryption held before persistence, and actual note decryption held before returning data. Check rejection, unchanged existing notes/no new note, cancelled approvals, cleared root key or GitHub credentials where applicable, and hidden previews after timeout/quit. Native plugin calls are mocked. Wipe erases keys; this test does not claim it physically deletes pre-existing encrypted notes. | `test/mcp/mcp_app_hooks_test.dart` |
| MCP-GAP-009 | Six actual editor/MCP races in both orders cover successful/conflicting autosave, archive and delete, pending local changes, visible conflict state, preserved winning content, and durable archived/deleted state. | `test/mcp/mcp_notes_editor_integration_test.dart` |
| MCP-GAP-010 | Three offline MCP creates debounce into one automatic foreground sync attempt. A later create after reconnect schedules a successful upload of all four notes; remote bytes hide plaintext and a fresh local notes box restores every body through real decryption. | `test/mcp/mcp_foreground_sync_integration_test.dart` |
| MCP-GAP-001/011 | Invalid arguments for every exposed tool under stable, legacy and require2026 SDK profiles; a deterministic 48-payload malformed corpus sent eight requests concurrently produces small redacted parse errors. Existing oversized-body and 120-request rate-limit checks also run. | `test/mcp/mcp_protocol_gap_test.dart`; `test/mcp/mcp_http_integration_test.dart` |
| MCP-GAP-003/013/014/017 | Real isolated-home bridge subprocesses reject missing/invalid profile arguments, path traversal, missing discovery/profile, malformed JSON, non-object profiles, mismatched client IDs, empty tokens, non-loopback endpoints and stale endpoints. Two simultaneous OS bridge processes exchange Unicode/newline content; closing one and starting a replacement leaves the other usable. | `test/mcp/mcp_stdio_process_test.dart` |
| MCP-GAP-011 raw stdio | Send an initialize frame one byte at a time, splitting UTF-8 Unicode; combine notification and two calls in one OS-pipe write. Malformed JSON, invalid UTF-8, array and null frames return small redacted errors without poisoning the next valid call. EOF halfway through another frame exits successfully. | `test/mcp/mcp_stdio_process_test.dart` |
| MCP-GAP-003/013 running server persistence | Three isolated real Flutter-process cases execute the production server and actual bridge: failed discovery write releases the listener and retry reuses the port; failed rotated-profile persistence never revives the old credential, stale profile fails and retry reconnects; SIGKILL leaves durable Hive/profile/discovery, a replacement process reopens them, changes port when the old one is occupied, rewrites discovery/PID and reads a note through the bridge. | `test/mcp/mcp_desktop_persistence_test.dart`; `test/support/mcp_desktop_process_probe.dart` |
| MCP-GAP-016 | Connect through actual IPv4 loopback, reject Host/Origin abuse, and probe IPv6 loopback plus IPv4 addresses assigned to this machine; no listener accepts the MCP port through those alternate interfaces. | `test/mcp/mcp_http_integration_test.dart` |
| MCP-GAP-018 | An isolated subprocess creates real directories and repeatedly writes profile/discovery files: directories stay 0700 and files 0600 on this macOS host. Credential replacement persists. A file obstructing the configuration directory fails explicitly. | `test/mcp/mcp_stdio_process_test.dart`; `test/support/mcp_paths_probe.dart` |
| TC-MODAL-016 / browser UI | Actual Chromium executes modal polling/lifecycle/retry tests, the Settings registry/error UI, manual-code/PIN linking, source normal-sync overlap, durable restore, post-transfer registration warnings and wrong-PIN rejection. Camera callback tests explicitly skip in browser; they execute natively. | `test/recovery_approval_dialog_test.dart`; `test/device_registry_ui_test.dart`; `test/device_link_integration_test.dart` |
| TC-STATE-013 browser wall clock | Change the isolated page's actual JavaScript Date by ±365 days, then reverse the skew between source approval and requester completion. With server Date exposed, registration completes idempotently. With Date hidden, a fast source expires the request and a slow source rejects its request time; neither registers the target or persists recovery keys. This characterizes the known CORS/clock limitation; it does not certify strict server-time expiry without that header. | `test/device_registry_gaps_test.dart`; `test/support/browser_clock_web.dart`; `test/support/browser_clock_stub.dart` |

The crash harness runs the production registry/storage/restore services in a
headless Flutter process. The disk authority implements SHA compare-and-swap
locally; it does not reproduce GitHub's distributed failure semantics or the
installed application's startup/navigation/plugin lifecycle. POSIX termination
checks explicitly require macOS/Linux; they are not a Windows kill test.

Browser runner note: Flutter 3.29.3's test HTTP handler matches any URL containing
`host.dart.js`, so it mistakenly serves the test host script for the application's
`mcp_approval_host.dart.js` module. The affected suites hang before executing any
case. The browser runs used an exact `/static/host.dart.js` match in the disposable
`/tmp/gitvault-flutter-3.29.3` SDK, then restored its original source and tool
snapshot byte-for-byte. No application files were renamed for the workaround.
Reproduction on this SDK requires the same test-runner correction; failed loader
runs are not counted as executed cases. Chromium was the cached headless shell
159.0.8154.6 on this macOS machine.

### Current remaining trusted-device checks

| ID | Status | Remaining boundary |
| --- | --- | --- |
| TC-MODAL-012 | Partial | Actual mobile suspend/resume and background timers; synthetic lifecycle tests already pass. |
| TC-E2E-001 | Partial | Independent physical-device phrase recovery against live GitHub. Full local Settings/restore UI passes. |
| TC-E2E-002 | Partial | Physical/live-service third-device overlap; local normal-sync and simulated competing authority already pass. |
| TC-E2E-003 | Partial | Physical/live-service reconnect-before-expiry run; the exact full local UI/restore journey now passes. |
| TC-E2E-004 | Partial | Physical/live-service late reconnect/new-request run; the exact full local UI/restore journey now passes. |
| TC-E2E-005 | Partial | Live token access/revocation and independent physical devices; full local token recovery passes. |
| TC-E2E-006 | Partial | Actual camera capture, OS/platform initial-sync behavior, independent devices and live GitHub; source-sync overlap with QR event/manual/PIN and encrypted restore now passes locally. |
| TC-E2E-007 | Partial | Live throttling and independent physical devices. Combined local setup/request/source-response failure journeys now pass, as do requester polling/completion and restore failures. |
| TC-E2E-008 | Partial | Installed-app termination/startup, every content type/plugin/credential-write sub-boundary, and OS termination semantics. Ten real service-process/disk boundaries plus partial-note restore now pass. |
| TC-STATE-013 | Partial (known limitation) | The actual browser ±365-day skew matrix now runs. Hidden GitHub Date still prevents strict server-time expiry under arbitrary clock skew: the tests demonstrate early expiry or invalid-request-time rejection. Resolving that constraint requires a reliable exposed time authority or a documented change to expiry semantics. |
| TC-OBS-007 | Not run (external) | Live commit/revision-history correlation. |
| TC-E2E-010 | Not run (external) | Inspect and decrypt actual GitHub revision history. |

TC-MODAL-016, TC-OBS-004, TC-OBS-005 and TC-OBS-006 are now **locally passed**. All other
trusted-device rows retain the preceding locally passed status. The local-only
constraint still excludes real GitHub acceptance; Git remains a polling transport.

### Current MCP status and remaining boundaries

| ID | Status | Remaining verification / limits |
| --- | --- | --- |
| MCP-GAP-001 | Partial | Full per-tool/resource maximum-output and exact dated protocol-version boundaries. All tool categories now reject invalid arguments under each of the three SDK compatibility profiles. |
| MCP-GAP-002 | Local passed | Defined 129,024-case permission/policy/tag/tool matrix passes; arbitrary tag strings are not an infinite exhaustive input domain. |
| MCP-GAP-003 | Partial | Broader both-transport negative combinations and disk failures while persisting the registry itself. Actual running-server profile/discovery failures, failed profile rotation, stale-profile rejection and persisted-registry reload after SIGKILL now pass locally. |
| MCP-GAP-004 | Partial | Installed lifecycle and every application hook × every tool/resource combination. Four actual hooks now each pass at pending approval, actual encryption and actual decryption boundaries. |
| MCP-GAP-005 | Local passed | Defined 90-case write/policy/decision matrix, prior repeat/exemption checks and actual approval-dialog UI pass. |
| MCP-GAP-006 | Local passed | Prior retention/expiry/redaction tests remain passing. Cross-platform crash/log acceptance is separate. |
| MCP-GAP-007 | Local passed | Prior scoped-resource/read/lock/revoke checks remain passing. |
| MCP-GAP-008 | Local passed | Prior real encrypted CRUD/reopen checks remain passing. |
| MCP-GAP-009 | Local passed | Six actual editor/MCP autosave/archive/delete races now pass in both orders. |
| MCP-GAP-010 | Local passed | Actual offline debounce, automatic foreground attempts, reconnect upload and encrypted restore now pass. |
| MCP-GAP-011 | Partial | Long-duration load, broader protocol fuzzing, oversized/incomplete-frame memory limits and per-tool output limits. Raw fragmented/coalesced frames, malformed UTF-8/JSON and incomplete-frame EOF now pass; current corpora and bursts are finite. |
| MCP-GAP-012 | Partial | Every actual hook × every individual read/write path, plus actual duress-PIN UI. Four production hooks now each block approval/encryption/decryption; separate service tests cover seven authorization transitions across all eight encrypted writes, eight reads and queued deletion. |
| MCP-GAP-013 | Partial | Installed-app/plugin startup and OS lifecycle acceptance. A real production-service process now survives SIGKILL/reload with stale discovery, persisted profiles, forced port change and successful bridge reconnection. |
| MCP-GAP-014 | Partial | Actual supported external host applications. Two real bridge processes now run locally, in addition to scoped independent protocol clients. |
| MCP-GAP-015 | Partial | Complete installed Windows/macOS/Linux user journey. |
| MCP-GAP-016 | Partial | Another physical network host and the other supported OS networking stacks; this host's assigned-interface/IPv6 probes pass. |
| MCP-GAP-017 | Partial | Success/failure/crash logs across installed desktop platforms and all remote error shapes. The reproduced parser-source leak is fixed and covered by subprocess canaries. |
| MCP-GAP-018 | Partial | Linux execution, Windows ACLs, chmod/icacls failure behavior and installed update/restart matrix. Current macOS directory/file modes and blocked-path handling pass. |
| MCP-GAP-019 | Local passed | Exact note-only tool/resource surface and forbidden-tool probes remain passing. |
| MCP-GAP-020 | Not run (external) | Installed-app lifecycle/distribution acceptance. |
| MCP-GAP-021 | Partial | Real supported-host configuration after installed-app update/move/restart. |
| MCP-GAP-022 | Partial | Desktop/mobile artifact builds, launches, signing/notarization/checksums and compatibility matrix. Web compilation alone does not establish these. |

### Verification for this continuation

Commands are run from the repository root using Flutter 3.29.3 and its bundled
Dart SDK. No changes are staged or committed.

```sh
flutter test --concurrency=4 --reporter expanded
dart analyze --format machine
flutter build web --release
git diff --check
```

The Chromium run additionally uses the cached headless browser and the temporary
test-runner routing correction described above:

```sh
CHROME_EXECUTABLE=/Users/giofahreza/Library/Caches/ms-playwright/chromium_headless_shell-1255/chrome-headless-shell-mac-arm64/chrome-headless-shell \
  flutter test --platform chrome \
  test/device_registry_gaps_test.dart \
  test/device_registry_ui_test.dart \
  test/recovery_approval_dialog_test.dart \
  test/device_link_integration_test.dart \
  --reporter expanded --timeout 60s
```

| Verification | Final result | Evidence / scope |
| --- | --- | --- |
| Complete native Flutter suite | **737 passed, 2 explicitly skipped, 0 failures** | `/tmp/gitvault-round3-native-final.log`. Skips are the live GitHub opt-in and the older Linux-only stale-endpoint case; new macOS process tests execute stale discovery separately. The permission matrix performs 129,024 checks within its test rows. |
| Chromium suite | **107 passed, 2 explicitly skipped, 0 failures** | `/tmp/gitvault-round3-browser-final.log`. Skips are the two camera/QR callback variants; manual linking and browser registration warnings execute. No physical camera or mobile lifecycle is claimed. |
| Static analysis | **0 errors; 11 distinct pre-existing warnings; no new warning/error records** | `/tmp/gitvault-round3-analysis-final.log`, compared with `/tmp/gitvault-final-analysis-machine.log` after deduplicating records. Analyzer exits 2 because of existing warnings; informational lints remain. |
| Release web build | **Passed** | `/tmp/gitvault-round3-web-final.log`. Built `build/web` using the restored original Flutter SDK; browser tests above are separate runtime evidence. |
| Diff whitespace | Passed | `git diff --check`. The original staged changes are preserved; this work stages or commits nothing. |

These counts are execution results, not full feature acceptance. The remaining
tables above are authoritative: some local combinations and hardening checks
remain open in addition to the unavailable live GitHub, installed-app,
physical-device, external-host and other-OS acceptance runs. The hidden-Date
clock issue is demonstrated behavior requiring a design decision, not merely an
unexecuted test.

## Local verification completion — round four, 2026-11-24

This section supersedes the preceding execution counts and remaining MCP table.
The authorized environment remains **local only**. Installed applications,
physical devices, live GitHub, external AI hosts and other operating systems
remain outside the executed acceptance boundary. Passing a defined finite test
matrix does not establish exhaustive behavior for arbitrary inputs or crashes.

### Additional defects reproduced and fixed

| Defect / IDs | Reproduction and correction | Regression evidence |
| --- | --- | --- |
| Registry changes became visible before persistence succeeded — MCP-GAP-003 | Closing the actual Hive settings box caused create, grants, scope/policy updates, credential rotation, revocation and removal to fail while some proposed changes remained in memory. Serialize complete mutations, persist first, then publish. Any persistence failure disables access for that registry instance until a fresh reload. Reload preserves the last durable state; it does not falsely report the failed change as saved. | `test/mcp/mcp_registry_persistence_failure_test.dart`; `/tmp/gitvault-round4-registry-before.log` reproduces seven failures. |
| Authentication could propagate a storage failure before the HTTP response handler — MCP-GAP-003 | Updating last-used state failed on a closed settings box and threw from authentication. Authentication now rejects the credential after the mutation has disabled access. | Authentication regression first fails in `/tmp/gitvault-round4-auth-before.log`; the same test now expects a null authentication result and unchanged last-used state. |
| Oversized stdio input executed its valid JSON prefix — MCP-GAP-011 | A valid call followed by more than 1 MiB of legal trailing whitespace still executed. `BoundedStdioInput` buffers bounded complete frames, rejects at overflow, discards through the next newline and then recovers. It never forwards the oversized frame's valid prefix to the SDK. | `test/mcp/bounded_stdio_input_test.dart`; actual OS-pipe tests in `test/mcp/mcp_stdio_process_test.dart`; `/tmp/gitvault-round4-stdio-before.log` reproduces execution. |
| Several collection outputs were unbounded — MCP-GAP-001/011 | 105 tags, link matches, backlinks, headings, blocks or block-reference matches exceeded the intended 100-item boundary. Cap these collections, report original totals/counts and truncation, bound previews and imported metadata, and reject full reads/resources of pre-existing content over 262144 Dart string code units. Tool/resource descriptions document the new behavior. | `test/mcp/mcp_protocol_gap_test.dart`; `/tmp/gitvault-round4-output-before.log` reproduces failures under three protocol labels. The corrected test explicitly connects with each profile. |
| Failed permission commands were silently ignored — MCP-GAP-018 | Isolated child processes ran with either a failing `chmod` executable or no executable. Directory permissions stayed broader than intended, yet credential writes continued. Nonzero exit/missing command now throws a fixed filesystem error; credential creation stops when directory restriction fails. Missing Windows owner or failed `icacls` likewise fails explicitly, but Windows execution remains unverified. | Two real subprocess regressions in `test/mcp/mcp_stdio_process_test.dart`; `/tmp/gitvault-round4-permissions-diagnostic.log` records the insecure directory-mode reproduction. |

The persistence-failure injection closes a real Hive box; it is not an OS
disk-full, torn-sector or hardware-failure simulation. The fail-closed registry
latch is intentionally retained until a new registry instance reloads storage.
Failed revocations remain failed operations and must be retried; restarting
cannot manufacture a revocation that was never durably saved.

Collection limits are a behavior change for large imported vaults. Nonpaginated
collections report `total`/counts and `truncated`; list/search retain pagination.
Metadata clipping is marked `metadata_truncated`. Full oversized bodies produce
an explicit error rather than a partial body. The existing content limit uses
Dart string length, so it must not be interpreted as a UTF-8 byte limit.

### Test case — additional execution and corner cases

| IDs / area | Executed cases and corner cases | Evidence |
| --- | --- | --- |
| MCP-GAP-003 registry | Failed create, grant, tag scope, policy, rotate, revoke, restore, revoke-all, approval exemption, touch, remove, disable, port, startup and tray persistence. Assert no proposed client/settings publication, denied access, unchanged durable reload. Concurrent permission/scope changes both persist. Authentication fails without throwing on storage failure; an actual HTTP request receives rejection or connection closure within five seconds. Queued rotation rejects an old-token authentication awaiting touch. Invalid input neither disables access nor poisons the mutation queue. | `test/mcp/mcp_registry_persistence_failure_test.dart` |
| MCP-GAP-001 input boundaries | **68 exact/one-over checks per profile, 204 total**, across all bounded tool fields: page size, queries, note/block IDs, titles, bodies, append text, daily template, section heading/content, tag/alias count and element length, checklist count and item text. Every rejection preserves repository state and leaves no pending approval. Exact section replacement content that would exceed the aggregate body cap is rejected before mutation. | `test/mcp/mcp_protocol_gap_test.dart` |
| MCP-GAP-001 output/resource boundaries | Under stable, legacy and require2026 profiles, return at most 100 list/search/tag/link/backlink/outline/block results from 105+ items. Imported overlong titles, tags and aliases are clipped and marked; large search bodies become bounded snippets. Full tool/resource read at the content cap succeeds; one over fails. No metadata-only body exposure. | `test/mcp/mcp_protocol_gap_test.dart` |
| MCP-GAP-001 dated HTTP compatibility | Each SDK-supported initialized version — 2024-10-07, 2024-11-05, 2025-03-26, 2025-06-18 and 2025-11-25 — initializes, completes its notification, calls a note tool and deletes its session. Unsupported dated/string headers are rejected. 2026-07-28 stateless requests include required method header and per-request metadata. Unsupported initialization proposal exercises legacy fallback. | `test/mcp/mcp_http_boundaries_test.dart` |
| MCP-GAP-004/012 actual hooks | **135 actual application-hook cases:** five hooks (Settings wipe, foreground device revocation, inactivity lock, desktop quit and real six-digit duress-PIN verification) × nine pending-approval writes, eight encrypted writes, eight decrypted read tools, one decrypted MCP resource and one approved delete queued behind actual local encryption. Existing notes survive rejected MCP changes; no new MCP note persists. Check cleared approvals, terminal session/key/credential effects, hidden locked-screen previews and legitimate local queue-holder completion. | `test/mcp/mcp_app_hooks_test.dart` |
| MCP-GAP-011 stdio | Exactly bounded frames, one-over, CRLF, incomplete final frame at EOF and 100 deterministic random UTF-8 chunk splits. Actual OS pipe sends an oversized valid prefix plus whitespace and an oversized frame without a newline; neither executes, overflow is rejected before newline, and a following valid frame succeeds. Existing fragmented/coalesced/malformed/null/UTF-8 cases remain. Buffer bounds are established by implementation and deterministic overflow tests; no process-RSS benchmark is claimed. | `test/mcp/bounded_stdio_input_test.dart`; `test/mcp/mcp_stdio_process_test.dart` |
| MCP-GAP-011 HTTP load | 1000 actual authenticated requests with 25 in flight: precisely 120 accepted by the limiter and 880 rejected. Another credential remains usable. After 61 real seconds, 120 requests are accepted again and the next is rejected. Accepted requests intentionally lack a session and return HTTP 400; this tests transport admission/recovery, not successful-note throughput. | `test/mcp/mcp_http_boundaries_test.dart` |
| MCP-GAP-018 permissions | Real macOS 0700/0600 directory/file modes, replacement writes, obstructed directory, failing command and missing command. On directory restriction failure, no credential file is created. Other-OS command/ACL behavior remains external. | `test/mcp/mcp_stdio_process_test.dart`; `test/support/mcp_paths_probe.dart` |
| TC-E2E-008 / TC-OBS-005/006 | **14 real SIGKILL boundaries**, now including before/after the complete GitHub credential write, partial password restore and partial SSH restore. Every restore journey reopens **five notes, one password/TOTP entry and two SSH credentials**, then retries again without duplication. Notes include ordinary Markdown, legacy checklist, journal date/alias and archive state; SSH covers password and private-key/passphrase forms. Existing registry PUT/cache/key/partial-note boundaries and optimistic-cache rejection remain. | `test/registry_process_restart_test.dart`; `test/support/registry_process_probe.dart` |

The headless restore harness acknowledges the IME cache notification using its
own binary messenger because there is no installed native plugin. Production
repository encryption, Hive writes, sync and decryption still execute. The
process stays alive while asynchronous work is pending and flushes output before
exit, so an early process exit cannot masquerade as a completed restore.
This does not validate installed IME, keychain, camera or lifecycle integration.

### Remaining acceptance boundaries

| IDs / category | Current local status | Remaining boundary |
| --- | --- | --- |
| MCP-GAP-001 | Local matrix executed | Arbitrary protocol/input space is not exhaustively enumerable; actual external host compatibility remains separate. |
| MCP-GAP-003 | Local failure matrix executed | OS disk-full/torn writes and installed-platform storage failures. Closed-Hive and profile/discovery/permission-command failures execute locally. |
| MCP-GAP-004/012 | Local hook matrix executed | Installed lifecycle/plugin behavior. All five production hooks now execute against the defined tools/resource/queue boundaries; the native duress manager is exercised through its real PIN UI. |
| MCP-GAP-011 | Local bounded-input/load matrix executed | Multi-hour soak, successful-operation throughput/RSS profiling and arbitrary fuzz inputs. The real rate-window recovery test is finite. |
| MCP-GAP-018 | macOS local cases executed | Linux run, Windows ACL/`icacls` run and installed update/restart permissions. |
| TC-E2E-008 | Expanded local process matrix executed | Installed startup/navigation, native plugins, other OS termination semantics and preemption inside each individual credential/Hive internal write. The complete credential write's before/after boundaries execute. |
| TC-STATE-013 | Known limitation remains characterized | Browser ±365-day skew passes with exposed server Date. When GitHub Date is hidden by CORS, strict server-time expiry still needs a reliable time authority or a deliberate expiry-semantics decision. Local tests cannot remove that architectural constraint. |
| Other trusted-device partial/external rows | Earlier local results retained | Physical suspend/camera/independent-device runs, live GitHub token/throttling/history checks and installed lifecycle remain as listed in the preceding trusted-device table. |
| Other MCP partial/external rows | Earlier local results retained | Installed supported hosts, another physical network host, Windows/Linux runners, desktop/mobile artifact launch/signing/distribution and update/move/restart remain unexecuted here. |

GitHub Contents API remains a polling authority; Git does not provide realtime
device notifications. The verified local fix prevents stale/optimistic state and
coordinates retry/refresh, but does not convert that transport into push sync.

### Final verification

No changes are staged or committed. Verification used Flutter 3.29.3 and its
bundled Dart SDK from the repository root.

| Verification | Result | Evidence |
| --- | --- | --- |
| Complete native suite | **899 passed, 2 explicit skips, 0 failures** | `/tmp/gitvault-round4-native-final.log`; `flutter test --concurrency=4 --reporter expanded`. Skips remain the live GitHub opt-in and older Linux-only stale-endpoint test; newer macOS stale-endpoint processes execute. |
| Final boundary regressions | **4 passed, 0 failures** | `/tmp/gitvault-round4-final-boundaries.log`. One additional actual-HTTP storage-failure case plus the three strengthened per-profile tests now explicitly reading `get_note` at exactly 262144 code units. These ran after the complete suite; they are not four additional unique tests. Across both runs, 900 distinct native test rows have passing evidence. |
| Chromium runtime suite | **107 passed, 2 camera/QR callback skips, 0 failures** | `/tmp/gitvault-round4-browser-final.log`; same four browser suites/command as the preceding record. Manual linking, wrong PIN, recovery/modal/registry UI and real browser clock skew execute. |
| Static analysis | **0 errors; 11 distinct existing warnings; no new warning/error records** | `/tmp/gitvault-round4-analysis-final.log`; `dart analyze --format machine`, normalized warning/error comparison with `/tmp/gitvault-final-analysis-machine.log`. Exit 2 reflects existing warnings; informational lints remain. |
| Release web build | **Passed** | `/tmp/gitvault-round4-web-final.log`; `flutter build web --release`, using the restored original SDK. |
| Whitespace / staging | **Passed; no staging or commit performed** | `git diff --check`; pre-existing staged changes are retained. |
| Browser-runner restoration | **Original source and snapshot verified byte-for-byte** | Disposable SDK source SHA-256 `af584e04eeed0a546738ddc879ca6b6b97098f98789875eb5f7d7136741d9fd7`; tool snapshot SHA-256 `178f994fdd1ef4f21665421647e047d42dc07dbcc70f1e08c6e55f2d827f2f2f`. The temporary host-script routing workaround is described in the preceding record. |

The final focused command was:

```sh
flutter test test/mcp/mcp_http_boundaries_test.dart \
  test/mcp/mcp_protocol_gap_test.dart \
  --name 'storage failure terminates|bounds imported metadata' \
  --reporter expanded
```

The earlier failed round-four runs are reproduction/harness evidence, not
passing execution counts. Five new defect categories are corrected and the
defined local regression matrices pass. **Full feature acceptance is still not
certified**: the remaining acceptance table and the hidden-Date browser clock
limitation above are explicit limits of this local-only verification.

## Release preparation — proposed v1.0.135

Implementation, tests, CI coverage and this verification record are committed
as `d07e553` (`fix: reconcile trusted devices and harden MCP access`). The
proposed next release tag is **v1.0.135**, following origin's v1.0.134, with
Flutter package version **1.0.135+1000135**. No release tag is created during
this preparation step; tag creation is held for the user's next instruction.

The production web configuration builds successfully with `/app/`, no PWA
service worker, and `GITVAULT_VERSION=1.0.135` /
`GITVAULT_BUILD_NUMBER=1000135`. Its version manifest and compiled version are
verified. Evidence: `/tmp/gitvault-v1.0.135-pretag-web.log`. This is a versioned
web build, not execution of the tag-triggered Android/desktop release pipeline.

The existing workflow uses one `v*` tag to build Android APKs, Linux, Windows,
macOS and web, publish release artifacts, and deploy Pages. A normal master
push already runs desktop CI and the separate Pages deployment. All remaining
acceptance limits in the preceding section still apply to this proposed release.
