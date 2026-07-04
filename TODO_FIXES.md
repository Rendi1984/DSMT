# DSMT — Pending Fixes (open this when starting a new chat)

**Current version:** Console `index.html` = 3.29.1 · API `DSMT_Api.ps1` = 3.29.1

---

## 🟢 Nothing pending

All previously listed fixes are DONE and merged to `main`. See `CHANGELOG.md`
for the full history. Highlights of what was completed since 3.22.x:

- **3.22.7** — all 5 console stub functions wired to the real API in Live mode
  (`saveConfig`, `saveDb`, `saveCa`, `exportDl`, `createUser`/`addMember`/
  `removeMember`/`jobToggle`/`jobRun`); fixed `/api/db/info` 500 with SQL-login
  auth (`Get-Session` now catches SQL failures → clean 401) and `/api/db/config`
  dropping `User`/`Password`.
- **3.23.x** — new Password Expiry Report page + `GET /api/passwords/expiring`;
  `Install.ps1 -InitDb` SSPI fix (Encrypt now from config.json); `runOffboard`,
  `saveSecret`, `testSecret` wired to Live.
- **3.24.0** — full audit of all 98 button handlers; everything now does
  something real (CA approve/deny/backup routes added, Access Control persisted
  to SQL, real CSV export, real config import, missing Publish CRL button
  added, etc.).
- **3.25.0** — PSO-accurate password expiry (`msDS-UserPasswordExpiryTimeComputed`),
  report CSV export, editable LDAP server / Base DN in Settings.
- **3.26.0** — browser first-run wizard performs a REAL install
  (`/api/setup/test-server` → `create-db` → `save`, which now also persists the
  Directory block and seeds the break-glass admin).
- **3.27.0** — Demo/Live toggle on the sign-in screen; mode + API URL persist
  across refreshes (localStorage).
- **3.28.0** — `Install-DSMT.ps1 -SetupViaBrowser` bootstrap mode; registry
  metadata under `HKLM:\SOFTWARE\DSMT`; wizard defaults to admin/admin with a
  warning; post-setup task alerts ("Connect an LDAP admin group",
  "Default administrator password in use").
- **3.29.0** — new Event Viewer page (`GET /api/events`, remote event logs over
  RPC — no RDP needed).
- **3.29.1** — DC/Exchange diagnostics no longer report a false "unreachable"
  when ICMP is blocked (ping is only a hint; SCM query runs regardless).

---

## 🟡 Ideas / nice-to-have (not scheduled)

- `Get-Session` in-memory token cache (short TTL) to cut the per-request SQL
  round-trip. Not urgent at current load; mind cross-runspace invalidation on
  logout if implemented.
- CA `Get-IssuedCertificates` / `Get-PendingRequests` parse certutil CSV output;
  consider hardening against subjects containing commas/quotes.
- MFA verification is a client-side gate only (any 6-digit code passes);
  server-side TOTP would make it real.
- Event Viewer: consider a saved-servers dropdown and an export button.

---

## 🔵 Known environment facts
- SQL Server: `192.168.1.50:1433` (use IP — `sql01.lab.local` DNS may not resolve)
- Domain controller: `dc.lab.local` / Base DN: `DC=LAB,DC=LOCAL`
- IIS identity: `LAB\IIS$` (db_datareader + db_datawriter on DSMTOOL)
- API port: **8780**, Console port: **8080** (IIS)
- Windows service name: `DSMT-Api`
- Deploy paths: API → `C:\Program Files\DSMT\server\` · Console → `C:\inetpub\dsmt\index.html`
- Registry metadata: `HKLM:\SOFTWARE\DSMT` (InstallDir, Version, ports, SetupMode)
- After replacing DSMT_Api.ps1 or modules: run `Restart-Service DSMT-Api`
