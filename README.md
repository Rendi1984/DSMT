# Directory Services Management Tool — On‑Prem Deployment

This package turns the HTML console (`index.html`) into a **real, working
on‑prem system**. The browser UI talks to a PowerShell **REST API** that performs
the actual Active Directory / SQL / Certificate‑Services work.

```
Browser (index.html, Live mode)
        │  HTTPS + Bearer token
        ▼
PowerShell REST API (Pode)  ──►  Active Directory (LDAP + RSAT cmdlets)
   server/DSMT.Api.ps1        ──►  SQL Server (config, audit, roles, sessions)
                              ──►  AD Connect server (delta sync, PSRemoting)
                              ──►  AD Certificate Services (certutil)
```

> The UI ships in **Demo** mode (mock data, works offline). Switch it to **Live**
> and point it at this API to drive the real environment.

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
pwsh ./DSMT.Api.ps1      # or:  powershell -File .\DSMT.Api.ps1
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
| Contractor Info | `GET /api/contractor/:user` |
| Audit Log | `GET /api/audit` |
| Certificate Authority | `GET /api/ca/{certs,pending}`, `POST /api/ca/{publish-crl,revoke}` |

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
  DSMT.Api.ps1            REST API (Pode) — all endpoints
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
