# DSMT — Session Notes & Open Tasks

This file is the persistent memory between chat/coding sessions. Every session
that changes the project must update it before finishing: move done items to
"Recently completed", add anything left open to "Open tasks", and record any
useful context under "Notes" so a fresh session (with no chat history) can
pick up immediately.

## Current version
3.29.20 (API + Console) — see `CHANGELOG.md` for the authoritative log.

## Open tasks
- Waiting on user confirmation that a fresh `-SetupViaBrowser` install now
  fully works end-to-end. Found and fixed 8 blocking bugs across 3.29.13-
  3.29.20 (API crash-loop, duplicate CORS header on 401s, Start-Website
  COMException in the installer, "First run" local-admin button never
  actually authenticating in Live mode, unhandled exception in
  `/api/auth/login` returning an empty 500, a client-side re-entrancy race
  in the setup wizard's Install button, sign-in HTTP 500 from untyped SQL
  params, and finally `/api/setup/save` using a bare `$Config` reference
  that was always `$null` in its route runspace) - 3.29.20 is the strongest
  candidate yet for the actual root cause of "Install never finishes," but
  still not yet confirmed clean end-to-end in the user's lab.
- Diagnostic method worth remembering: when the user reports "button does
  nothing," ask for BOTH `dsmt-service.log` (server-side process log) AND
  `dsmt-request.log` (every HTTP request Pode received) - cross-referencing
  the two is what revealed the setup-wizard race condition (request log
  showed endless repeating request pairs with no `/api/setup/save` ever
  reached, which static code reading alone hadn't caught).
- User asked about moving basic settings (SQL server, DC, domain DN) into
  the Windows registry so they persist more reliably. Decided NOT to do this
  (see Notes) - the real bug was the fake-auth issue above, not the storage
  mechanism. If it comes up again, explain why `config.json` staying the
  single source of truth is preferable to a second registry copy that can
  drift out of sync.
- User is testing with the browser AND SQL Server on the SAME machine as the
  API/IIS (not a separate client) - remember this when reasoning about future
  reports from them (e.g. "localhost" ambiguity doesn't apply the same way).
- Remind the user (if it comes up again) that `index.html` must be opened via
  the IIS URL, not as a `file://` path - the CORS "origin: 'null'" symptom in
  one of their screenshots was because they had `C:\inetpub\dsmt\index.html`
  open directly in the browser instead of `http://localhost:8080`.
- The v3.29.7-3.29.12 console-loading incident (JSON/regex corruption in
  `index.html`) is fully resolved and merged.
- Consider updating `.claude/skills/dsmt-dev-workflow/SKILL.md`'s verification
  checklist to include the method proven necessary during that incident:
  `JSON.parse` on the extracted `__bundler/template` string, then
  `node --check` on the extracted `class Component extends DCLogic {...}`
  body (wrapped with a stub `class DCLogic {}`). The previous
  headless-DOM-text-grep check does NOT reliably catch broken JS inside the
  bundle — raw script text still shows up in a DOM dump whether or not it
  actually evaluated successfully.

## Notes for next session
- `index.html` internals: the entire app template (HTML shell + the
  `class Component extends DCLogic {...}` JS body) is stored as one JSON
  string inside `<script type="__bundler/template">`. Any edit made by
  string-replacing raw text in that region MUST double every backslash and
  escape every real newline/quote (`\n` -> `\\n`, `"` -> `\"`, a literal
  backslash -> `\\\\` if the source itself needs one JS-level backslash,
  e.g. inside a regex like `/\\/g`). Always verify with the JSON.parse +
  node --check method above before shipping any index.html edit.
- Standard git/PR workflow used throughout this project:
  commit on `claude/repo-dsmt-file-list-u3thrd` -> push -> open PR against
  `main` -> merge -> resync the branch:
  `git fetch origin main && git checkout -B claude/repo-dsmt-file-list-u3thrd origin/main && git push -u origin claude/repo-dsmt-file-list-u3thrd`.
- Version bump policy: bump in all 5 places (sidebar footer, overview badge,
  About modal x2, `buildConfig()`) only when `index.html` itself changes.

- Registry vs config.json for settings: `config.json` is re-read fresh from
  disk on every relevant API call (`Get-DbInfo`, `Get-Config`, etc.), so it's
  already a reliable single source of truth once auth actually works. The
  `HKLM:\SOFTWARE\DSMT` registry key is intentionally scoped to one-time
  deployment metadata (site name, ports) written by the installer, not
  live-editable settings - keep it that way to avoid two stores drifting.

## Recently completed (most recent first)
- Added a "Remote access" section to README.md and Deployment_Guide.html
  (accessing by server name / from another machine): the app already
  listens on all interfaces, the fix is entirely about using the right
  URL/firewall/DNS on the client side, not localhost. Docs-only.
- 3.29.20: Found and fixed what is very likely the actual root cause of the
  browser setup wizard never completing across this entire session's
  testing. POST /api/setup/save read/wrote $Config as a bare variable
  instead of via $using:Config (every other route captures it that way -
  this project has hit this exact class of bug repeatedly: 3.29.13, 3.29.15,
  3.29.18). $Config was silently $null inside that route's runspace, so the
  property writes either no-op'd or threw before Save-Config was ever
  reached - meaning /api/setup/save could never persist the SQL connection
  or seed the local admin, no matter how many times "Install" was retried,
  regardless of file:// vs proper http:// origin. Fixed by capturing
  $using:Config into a local $cfg and passing it explicitly to
  Test-SetupComplete and Save-Config (both already accept -Cfg).
- Added `iis-reverse-proxy.web.config` (optional) + a guide section for the
  single-origin IIS reverse-proxy deployment the console already advertises
  ("Behind IIS reverse proxy"). Key gotcha documented: never add IIS CORS
  `customHeaders` on /api - the API already sends them and a duplicate
  reproduces the 3.29.14 `*, *` bug. User had asked whether an ARR/CORS IIS
  setup could fix the F12 blocks - it can't (those were file:// origin
  blocks, unfixable server-side), but same-origin proxy is a good option.
- 3.29.19: Added a file:// misuse warning banner to the console - the user
  repeatedly opened `C:\inetpub\dsmt\index.html` directly from Explorer,
  which makes the browser block all API calls (origin `null`) before they
  leave the machine, so nothing appears in the server logs either. The
  console now detects `file://` at load and shows a dismissible red banner
  pointing to `http://localhost:8080`. Verified: banner renders under
  file://, absent over HTTP, app boots clean either way.
- 3.29.18: Fixed sign-in HTTP 500 - `Invoke-Sql` (Db.psm1) bound every SQL
  parameter as NVarChar(max); `DATEADD(hour, @h, ...)` in the session INSERT
  rejects a string argument, so login authenticated and then crashed creating
  the session row. Now binds bool/int/datetime with their real SQL types.
  Also silenced two 404s logged on every console load: the design-time
  image-slot helper no longer fetches its `.image-slots.state.json` sidecar
  outside the design tool, and an inline SVG favicon was embedded.
- 3.29.17: Fixed the setup wizard's Install button appearing to do nothing.
  Root cause found by cross-referencing `dsmt-request.log` (endless repeating
  `/api/setup/test-server`/`create-db` pairs, `/api/setup/save` never reached)
  with the client code: the busy-guard checked an asynchronous state flag, so
  more than one click before it committed launched overlapping, self-clobbering
  install attempts. Replaced with a synchronous instance flag set instantly on
  click and cleared on every exit path (success, each failure branch, cancel,
  demo-mode completion).
- 3.29.16: Added a friendly `GET /` (and `GET /favicon.ico`) response on the
  API - browsing straight to the API's own URL previously returned a raw
  405 Method Not Allowed, which read like a real error even though it's
  expected (no home page, API-only routes). Cosmetic, no functional change.
- Moved `Deployment_Guide.html` into the repo (previously excluded, download-only)
  as a tracked, committed root file. Updated it to v3.29.15: new troubleshooting
  rows for every bug found this session (API crash-loop, duplicate CORS header,
  Start-Website COMException, First-run fake auth, unhandled login exception),
  an offline/air-gap install callout, an http.sys URL ACL note, and expanded
  the Uninstall section with all the real switches. `CLAUDE.md` now mandates
  keeping it in sync with every install/ports/permissions/troubleshooting change,
  in the same PR as the code change.
- 3.29.15: Fixed "First run? Sign in with the local default administrator"
  never actually authenticating against the API in Live mode (was faking
  client-side auth state only, so every subsequent authenticated call 401'd
  and Settings screens kept showing demo placeholder values instead of the
  real config). Also added error handling to `/api/auth/login` so an
  unreachable LDAP server returns a readable error instead of an empty 500.
- 3.29.14: Fixed duplicate CORS header on 401 responses (`Add-PodeHeader` ->
  `Set-PodeHeader`, was producing invalid `*, *` and getting requests blocked
  by the browser) and a Start-Website COMException in `Install-DSMT.ps1`'s
  IIS deploy step (falls back to `appcmd start site`).
- 3.29.13: Fixed the API crash-looping on every start (`$using:Config.Directory.BaseDN`
  chained member-access broke Pode's startup scope scanner on PS 5.1) - this
  is what caused "Failed to fetch" / connection-refused on every Live-mode
  call even though the Windows service showed "Running". Also hardened both
  installers to auto-reserve the http.sys URL ACL for the service account.
- 3.29.12: Fixed remaining under-escaped backslash regexes in Secrets
  Manager (`rotateSecretLive`, `saveSecretLive`, secrets loader) and the CSV
  join separator — completed the 3.29.7 incident fix.
- 3.29.7/3.29.8: Fixed console-breaking JSON/regex corruption that blanked
  the entire app (raw newlines/quotes in the bundled template; broken CSV
  quoting regex).
- 3.29.6: Added `-Offline` / `-WindowsFeatureSource` switches to
  `Install-DSMT.ps1` plus README air-gap install docs.
- 3.29.5: Removed leftover Google Fonts preconnect tags (full offline audit).
- 3.29.4: Fixed the disconnected "Local default administrator" toggle on
  Access Control; clarified access-group-vs-role-mapping copy; labeled MFA
  as console-side-only.
- 3.29.3: Fixed `DSMT.Api.ps1` vs `DSMT_Api.ps1` filename mismatches across
  installers and README.
- 3.29.0/3.29.1: Added remote Event Viewer tab; fixed ping-gated DC/Exchange
  diagnostics checks.
- 3.28.0/3.26.0: Browser-based first-run setup wizard (`-SetupViaBrowser`),
  registry-stored deployment metadata, default admin/admin, post-setup task
  alerts (change password, map LDAP admin group).
- 3.27.0: Demo/Live mode toggle on sign-in screen with persistence.
- 3.25.0: PSO-accurate password expiry, CSV export, LDAP-field Settings.
- 3.24.0: Full button audit — wired remaining demo-only actions to Live API.
- 3.23.x: Fixed installer SSPI error; wired `runOffboard`/`saveSecret`/`testSecret`.
- 3.22.7: Wired 5 stub console functions to real API calls in Live mode;
  fixed `/api/db/info` 500 with SQL-login auth.

Also delivered (not committed to repo, per `CLAUDE.md`'s exclusion list):
`Deployment_Guide.html` (with Ports & Firewall + Permissions sections),
`DSMT-Deploy.zip`, and the `powershell-compatibility-standards` Claude Code
skill (as SKILL.md + zip for account import).
