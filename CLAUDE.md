# DSMT — Project Rules for Claude

## What is this project
**Directory Services Management Tool** — on-prem Active Directory management console.
- **Console**: `index.html` — offline self-contained HTML (no internet required), served by IIS on port 8080.
- **API**: `DSMT_Api.ps1` — PowerShell REST API (Pode framework), Windows service `DSMT-Api` on port 8780.
- **Domain**: `lab.local`

---

## Interface language (MANDATORY)
- The entire UI is **English only**. All labels, buttons, tooltips, toasts, modal text, placeholder text, and log/console strings must be written in English.
- Do NOT add other languages, localization files, or an i18n layer.
- This applies to everything that ships in the product: the app UI, any printable/exported documents, and all script or server output (log lines, error messages, console text).
- Assistant chat replies to the user may be in the user's language, but product content stays English.

## Interface tech stack
- **UI** — DC (Data Conductor) framework, self-contained offline HTML bundle. No React, no Vue, no external CDN.
- **Server** — Windows PowerShell 5.1 + Pode REST API framework
- **Database** — SQL Server (System.Data.SqlClient / SqlClient NuGet)
- **Build** — `super_inline_html(source/index.html → index.html)` bundles everything into one file

---

## File locations

### Project files (source — what's uploaded here):
All files are flat (no folder structure in the project). Logical mapping:
```
index.html          → deploy bundle (root)
DSMT_Api.ps1        → server/
Install-DSMT.ps1    → server/  ← recommended: one-click, full install
Install.ps1         → server/  ← granular commands for maintenance on an EXISTING install (re-register service, reset local admin password, re-run schema) - not a competing way to do a fresh install
Register-DsmtService.ps1 → server/  ← shared native-service registration logic; both installers above dot-source this, so there is exactly one copy of it
Install.cmd         → root/  ← one-click self-elevating installer, double-click entry point
Start-Install.ps1   → root/
Uninstall-DSMT.ps1  → root/
Auth.psm1           → server/modules/
Db.psm1             → server/modules/
Directory.psm1      → server/modules/
Sync.psm1           → server/modules/
Contractor.psm1     → server/modules/
CertAuthority.psm1  → server/modules/
Secrets.psm1        → server/modules/
Diagnostics.psm1    → server/modules/
schema.sql          → server/sql/
config.sample.json  → server/
iis-reverse-proxy.web.config → root/  ← optional; copy to IIS webroot as web.config for single-origin proxy
install-answers_sample.json → root/
CHANGELOG.md        → root/
README.md           → root/
Deployment_Guide.html → root/  ← full step-by-step guide, keep in sync with every change
PROGRESS.md         → root/
CLAUDE.md           → root/  ← this file
```

### On the server (after install):
```
C:\Program Files\DSMT\server\   ← API + modules + config.json
C:\inetpub\dsmt\index.html      ← console (IIS port 8080)
```

---

## Session notes (MANDATORY)
`PROGRESS.md` (repo root) is the persistent memory between chat/coding
sessions — a new session with no chat history must be able to read it and
continue. Every session that changes the project MUST update it before
finishing:
- Move finished work into "Recently completed".
- Add anything still open (bugs found but not fixed, follow-ups the user
  mentioned but didn't ask for yet, things to verify next time) to "Open
  tasks".
- Record any non-obvious context a fresh session would need under "Notes".

## How changes are delivered
- In git-connected sessions (Claude Code / GitHub): develop on a feature branch,
  commit, push, open a PR and merge to `main` — `main` is the source of truth.
- In chat-only sessions (no repo access): deliver fixed files as downloads and
  the user replaces them manually on the server.
- After replacing `DSMT_Api.ps1` or any module → run `Restart-Service DSMT-Api`
- After replacing `index.html` → refresh browser (Ctrl+F5)
- **After any serious change** (a real bug fix or feature, not a typo/doc tweak):
  in addition to the PR, build and send the user a deployment ZIP with every
  file in the correct on-server folder layout (mirrors the table in
  "File locations" above: root files loose, `server/`, `server/modules/`,
  `server/sql/`, including `Deployment_Guide.html`). Stage into a scratch
  folder, `zip -r` it, and send it via `SendUserFile` — don't just describe
  the changed files and expect the user to reassemble the package themselves.
- **The ZIP filename MUST include the current version**, e.g.
  `DSMT-Deploy-v3.29.26.zip` — never a bare `DSMT-Deploy.zip`. Use the
  version being shipped in that same change (the one just bumped in
  `index.html`/`CHANGELOG.md`), not a stale one.
- **`Deployment_Guide.html` is a tracked, committed file** (root) — keep it in
  sync with every change that affects install steps, ports/firewall rules,
  permissions, troubleshooting symptoms, or the version number. Update it in
  the same PR as the code change, not as an afterthought.
- **Always state exactly which file(s) changed and where to copy them**, every
  time a fix ships — the user should hot-swap individual files on an already
  running install instead of uninstalling/reinstalling from scratch. Format:
  `<file> -> <on-server path>` plus the one required follow-up action. Examples:
  - `DSMT_Api.ps1` / any `modules/*.psm1` -> `<InstallDir>\server\` (or `\server\modules\`), then `Restart-Service DSMT-Api`
  - `index.html` -> the IIS webroot (e.g. `C:\inetpub\dsmt\index.html`), then hard-refresh the browser (Ctrl+F5) — no service restart needed
  - `config.sample.json`, `schema.sql` -> informational only unless the user is re-running `-InitDb`/`-RegisterService`; don't imply a reinstall is needed
  - `Install-DSMT.ps1` / `Install.ps1` / `Uninstall-DSMT.ps1` -> only relevant on the **next** install/uninstall run, not to an already-running instance
  Only recommend a full uninstall+reinstall when the change actually requires it (e.g. a schema migration with no in-place path, or the user's install is already in a broken/inconsistent state).

---

## Current version: 3.29.22 (API + Console)
Check `CHANGELOG.md` (top entry) for the authoritative current version before
picking the next number.

### Versioning policy (MANDATORY)
Format: `MAJOR.FEATURE.FIX`
- MAJOR: breaking change
- FEATURE: new feature (reset FIX to 0)
- FIX: bug fix only

Bump version in ALL these places when changing index.html:
1. Sidebar label (`v3.22.x`)
2. Overview badge
3. About modal
4. Installer-wizard label
5. `buildConfig()` version field
6. Sign-in screen, under the Demo/Live toggle (added 3.31.1)

---

## PowerShell rules (MANDATORY)
All scripts must be **Windows PowerShell 5.1 compatible**:
- NO `??` null-coalescing operator
- NO ternary operator `? :`
- NO `&&` / `||` operators
- NO `pwsh` — use `powershell.exe`
- ASCII only in .ps1 files (no Unicode characters in code)

---

## API rules
- Framework: **Pode** (not Express, not anything else)
- Auth: Bearer token via `Authorization` header, checked by `Get-Session $WebEvent`
- All 401 responses MUST use `Write-401` helper (stamps CORS headers before 401)
- CORS allowed methods: `GET, POST, DELETE, OPTIONS`
- All routes inside `Start-PodeServer { }` block
- Use `$using:Config` to access outer variables inside route scriptblocks

---

## Console rules
- Framework: **DC (Data Conductor)** — NOT standalone React, NOT Vue, NOT Angular
- Deployed `index.html` is a self-contained bundle — no external CDN, no internet
- All API calls go through `this.apiFetch(path, opts)` which adds the Bearer token
- Demo mode: returns fake data. Live mode: calls real API
- All Live-mode branches must check `if (this.state.connMode === 'live')` before calling apiFetch

### No fake data in Live mode (MANDATORY audit before calling console work done)
Every page has a hardcoded demo array as a class field (`GROUPS`, `AUDIT`, `CA_TEMPLATES`, `PWEXP_DATA`, etc.) for Demo mode. History: three separate rounds of real-world testing found pages that rendered this demo data **unconditionally**, even signed into Live mode against a real server — `System Team → Groups`/`Scheduled Jobs` showed fixed fake names that didn't exist in the real AD/Task Scheduler (every click 400'd), and `Audit Log` showed static fake entries with **zero** live fetch wired at all, despite `/api/audit` already existing and working server-side. The user's own words after finding this twice: "לא להציג נתונים כוזבים במערכת" (don't show fake data in the system).

Before considering ANY console change or session complete, grep the decoded template for every `NAME = [` class-field array (`python3 -c "... t.count('\n  NAME = [')..."` per the edit-script pattern above) and for each one check:
1. Is it real UI/nav config (role names, palette list, tab labels, static specs of the app's own fixed behavior)? — fine to leave hardcoded.
2. Is it presented as if it reflects the real domain/server/database (a list of groups, users, jobs, audit events, certificates, anything with real-world names/timestamps)? — MUST have a `*Live` counterpart that fetches from a real API route and is used instead whenever `connMode === 'live'`, with the demo array only reachable in Demo mode. If the backend route doesn't exist yet, build it — do not ship a page that silently shows fake data instead.
3. If a *Live function already exists but isn't called anywhere (dead code) or the corresponding renderVals computed value still references the demo array unconditionally, that is the exact bug pattern to search for — grep `this.DEMO_ARRAY_NAME` usages and confirm each one is behind a `connMode==='live'` check with a loaded-live-data fallback, not used bare.
4. Also check field-name casing: API routes that return raw SQL rows (`Invoke-Sql` results) must map to lowercase keys explicitly (`@{ time=...; actor=...; }`) — returning a raw SQL row hashtable straight through `Write-PodeJsonResponse` sends PascalCase keys that silently don't match what the console reads, and the page looks "empty"/wrong with no visible error.

---

## Known environment facts
- SQL Server: `192.168.1.50:1433` (hostname `sql01` resolves, `sql01.lab.local` may NOT — DNS suffix issue)
- Domain controller: `dc.lab.local` / Base DN: `DC=LAB,DC=LOCAL`
- IIS app pool identity: `LAB\IIS$` (has db_datareader + db_datawriter on DSMTOOL)
- API port: 8780, Console port: 8080
- Windows service name: `DSMT-Api`

---

## What NOT to upload to this project
- Screenshot PNG files
- `_image-slots_state.json`
- `support.js`, `image-slot.js` (source-only build helpers)
- `source/` folder files (editable build — needs internet, not deployed)
