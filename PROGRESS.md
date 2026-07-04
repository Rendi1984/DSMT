# DSMT — Session Notes & Open Tasks

This file is the persistent memory between chat/coding sessions. Every session
that changes the project must update it before finishing: move done items to
"Recently completed", add anything left open to "Open tasks", and record any
useful context under "Notes" so a fresh session (with no chat history) can
pick up immediately.

## Current version
3.29.14 (API + Console) — see `CHANGELOG.md` for the authoritative log.

## Open tasks
- Waiting on user confirmation that a fresh `-SetupViaBrowser` install now
  fully works end-to-end. Found and fixed 3 blocking bugs across 3.29.13/
  3.29.14 (API crash-loop, duplicate CORS header on 401s, Start-Website
  COMException in the installer) - not yet confirmed clean in the user's lab.
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

## Recently completed (most recent first)
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
