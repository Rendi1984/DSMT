# Directory Services Management Tool — On‑Prem Deployment

This package turns the HTML console (`index.html`) into a **real, working
on‑prem system**. The browser UI talks to a PowerShell **REST API** that performs
the actual Active Directory / SQL / Certificate‑Services work.

```
Browser (index.html, Live mode)
        │  HTTPS + Bearer token
        ▼
PowerShell REST API (Pode)  ──►  Active Directory (LDAP + RSAT cmdlets)
   server/DSMT_Api.ps1        ──►  SQL Server (config, audit, roles, sessions)
                              ──►  AD Connect server (delta sync, PSRemoting)
                              ──►  AD Certificate Services (certutil)
```

> The UI ships in **Demo** mode (mock data, works offline). Switch it to **Live**
> and point it at this API to drive the real environment.

---

## Fully offline / air-gapped installs

Every part of DSMT is designed to run with zero internet access — but the *installer*
needs two things staged in advance if the app server has none at all:

| Dependency | Default source | Air-gapped fix |
|---|---|---|
| **Pode** (API framework) | PowerShellGallery.com | Prep `server\vendor\Pode` once (see below) |
| **RSAT-AD-PowerShell / IIS role** | Local Windows component store (works out of the box on most servers) | If the image had source files stripped, pass `-WindowsFeatureSource` |
| Everything else (SQL, AD, the console itself) | Nothing — no download ever needed | — |

**One-time prep, on any PC with internet** (does not need to be domain-joined or related to the target server at all):
```powershell
Save-Module -Name Pode -Path .\vendor
```
Copy the resulting `vendor\Pode\` folder into this package's `server\vendor\Pode\`, then install with:
```powershell
.\Install-DSMT.ps1 -Offline -SqlServer SQL01 -LdapServer DC01.lab.local -BaseDN "DC=lab,DC=local"
```
`-Offline` makes the installer **skip every network call outright** (no PSGallery, no Windows Update fallback) and fail immediately with the exact fix needed, instead of hanging on a timeout. If the target's Windows Feature source was stripped from the image, add:
```powershell
.\Install-DSMT.ps1 -Offline -WindowsFeatureSource "D:\sources\sxs" ...
```
(`D:\sources\sxs` = a mounted Windows Server ISO/ESD, or an extracted `install.wim`.)

The console itself (`index.html`) has no external references at all (fonts, scripts, everything is embedded) — nothing to prepare there.

---

## Quick install — one script (recommended)

On the domain-joined app server, in an **elevated Windows PowerShell**:
```powershell
cd C:\DSMT\server
.\Install-DSMT.ps1
```
`Install-DSMT.ps1` runs **every** step end to end — prerequisites (RSAT-AD + Pode),
`config.json`, database + schema, local break-glass admin, the API Windows
service, and the IIS-hosted console. It prompts for any required value you don't
pass (SQL server, LDAP host, Base DN, admin password); everything else uses
sensible defaults. Re-running is safe. Skip parts with `-SkipPrereqs`,
`-SkipService`, `-SkipFrontend`. Unattended example:
```powershell
.\Install-DSMT.ps1 -SqlServer SQL01 -LdapServer DC01.lab.local `
    -BaseDN "DC=lab,DC=local" -Domains "lab.local" -ServiceAccount "LAB\svc_dsmt$"
```

### Browser-based first-run wizard (alternative)

Initial deployment can also be completed **from the browser**, without answering
anything on the command line:

1. Bootstrap install — in an elevated PowerShell:
   ```powershell
   .\Install-DSMT.ps1 -SetupViaBrowser
   ```
   This skips every SQL / directory / admin question: it installs prerequisites,
   deploys the files, registers the `DSMT-Api` service (which starts in
   **SETUP MODE**) and the IIS console, and writes deployment metadata to
   `HKLM:\SOFTWARE\DSMT`.
2. Open the console, use the **Demo / Live toggle on the sign-in screen** to
   switch to Live (API URL is pre-filled), and click **"Run the setup wizard"**.
3. The wizard asks the same questions the script would — SQL server, database,
   domain controller / LDAP host, Base DN, administrator account (defaults to
   `admin` / `admin`) — and drives the real setup API: verifies the SQL server,
   creates the database + schema, writes `config.json`, and seeds the
   break-glass administrator.
4. Sign in with that administrator. The alerts bell then shows the remaining
   **setup tasks** until they are done: change the default password, and map an
   LDAP security group to the **System Administrator** role (Access Control) so
   domain admins can sign in with their own accounts.

Both paths are equivalent — `Install.cmd` / `Install-DSMT.ps1` remains fully
supported for unattended or all-in-one installs.

The numbered steps below document the **manual / granular** path (via `Install.ps1`),
useful when you want to run a single stage at a time.

---

## 0. Build a safe lab first
Do **not** test against production. Stand up an isolated lab (Hyper‑V snapshots recommended):

| Role | Host | Notes |
|------|------|-------|
| Domain Controller | `dc01.lab.local` | + AD CS optional (`CA-01`) |
| App server (this API) | `app01.lab.local` | domain‑joined member server |
| SQL Server | `sql01.lab.local` | SQL Express is fine |
| AD Connect | `adc-sync-01` | only if testing Azure sync |

Create a **test OU** and throw‑away users/groups so nothing real is touched.

---

## 1. Prerequisites (on the app server)
- Windows Server 2019/2022, **domain‑joined**.
- **Windows PowerShell 5.1** (built in) — uses `System.Data.SqlClient` with no extra module.
- A **run-as identity** for the API. A **gMSA** (`LAB\svc_dsmt$`) is **recommended but optional** — a regular domain service account works too, and for a lab you can simply run as **NetworkService** (omit `-ServiceAccount`). Whichever you pick, grant it only:
  - read on the directory, and (for write actions) delegated *reset password / enable‑disable / create user* on the **test OU**;
  - **PSRemoting + local admin on the AD Connect server** (for sync);
  - **Issue & Manage Certificates** on the CA (for CA actions);
  - `db_owner` on the `DSMTOOL` database (or `db_datareader/writer` + execute).

Install the tooling:
```powershell
cd C:\DSMT\server
.\Install.ps1 -Prereqs        # RSAT-AD-PowerShell + Pode
```

---

## 2. Configure
```powershell
copy config.sample.json config.json
notepad config.json
```
Set **Database**, **Directory** (LdapServer, BaseDN), **Sync.ADConnectServer**, and
**CertificateAuthority.ConfigString** (`CA-HOST\CA-COMMON-NAME`). For production set
`Api.Protocol = https` and supply a certificate (see §6).

---

## 3. Create the database
```powershell
.\Install.ps1 -InitDb
```
Creates the `DSMTOOL` DB, all tables, and seeds default config + role mappings.

---

## 4. Create the local break‑glass admin
A **local, domain‑independent** account for first run / when LDAP is down:
```powershell
.\Install.ps1 -SeedLocalAdmin -LocalAdminUser administrator
# (prompts for a password; stored as a PBKDF2 salted hash in SQL, never plain text)
```

---

## 5. Run the API
Foreground (for testing):
```powershell
pwsh ./DSMT_Api.ps1      # or:  powershell -File .\DSMT_Api.ps1
```
As a Windows service (auto‑start) — a native service host is compiled and registered automatically. `-ServiceAccount` is **optional**:
```powershell
.\Install.ps1 -RegisterService -ServiceAccount 'LAB\svc_dsmt$'   # gMSA or domain account
.\Install.ps1 -RegisterService                                  # omit = NetworkService
```
Smoke test:
```powershell
Invoke-RestMethod http://localhost:8780/api/health
```

---

## 6. Point the UI at the API (Live mode)
1. Open **index.html** (host it on the app server or any web server / IIS).
2. Sign in (local admin), open **⚙ Settings → Connection**.
3. Switch **Mode** to **Live** and set **API base URL** to `http://app01.lab.local:8780` (or your HTTPS URL), then **Test connection**.
4. Sign out and back in — you're now driving the real domain.

**HTTPS / production:** put the API behind IIS with **Windows Authentication** and an
HTTPS binding, or give Pode a cert (`Api.Protocol=https`, `Api.CertThumbprint`). Restrict
`Api.CorsOrigins` to the exact URL that serves the HTML.

---

## 7. What each screen calls
| Screen | Endpoint |
|--------|----------|
| Sign in | `POST /api/auth/login` |
| Dashboard health | `GET /api/health` |
| Azure Cloud Sync | `POST /api/sync`, `GET /api/sync/status` |
| DL Groups | `GET /api/dl/:group` |
| User Management | `GET /api/users`, `POST /api/users/:sam/{reset,enable}` |
| Password Expiry Report | `GET /api/passwords/expiring` |
| Event Viewer | `GET /api/events` |
| Contractor Info | `GET /api/contractor/:user` |
| Audit Log | `GET /api/audit` |
| Certificate Authority | `GET /api/ca/{certs,pending}`, `POST /api/ca/{publish-crl,revoke,approve,deny,backup}` |
| Access Control | `GET/POST /api/access/mappings`, `GET/POST /api/access/local`, `POST /api/access/require-group`, `GET/POST /api/secrets` |

---

## 8. Security checklist before leaving the lab
- [ ] API on **HTTPS** only; CORS locked to the console URL.
- [ ] Run-as identity is least privilege, scoped to the intended OUs (gMSA recommended, not required).
- [ ] SQL reachable only from the app server; `Encrypt=true`.
- [ ] Local admin password is strong and stored (hashed) in SQL.
- [ ] Audit log reviewed; sessions expire (`Api.TokenTtlHours`).
- [ ] Start **read‑only** (lists/lookups), enable write actions one at a time.

---

### Files
```
server/
  DSMT_Api.ps1            REST API (Pode) — all endpoints
  Install.ps1             prereqs / DB init / seed local admin / service
  config.sample.json      copy to config.json and edit
  sql/schema.sql          database schema + seed data
  modules/
    Db.psm1               SQL access, config, audit
    Auth.psm1             LDAP bind, group->role, local accounts (PBKDF2)
    Directory.psm1        AD user/group operations (RSAT)
    Sync.psm1             AD Connect delta sync (PSRemoting)
    Contractor.psm1       contractor OU verdict + Juniper attrs
    CertAuthority.psm1    ADCS via certutil
```
