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
Install-DSMT.ps1    → server/
Install.ps1         → server/
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
install-answers_sample.json → root/
CHANGELOG.md        → root/
README.md           → root/
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

---

## Current version: 3.29.12 (API + Console)
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
- `Deployment_Guide.html` (optional reference only)
- `source/` folder files (editable build — needs internet, not deployed)
