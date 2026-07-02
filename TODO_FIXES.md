# DSMT — Pending Fixes (open this when starting a new chat)

**Current version:** Console `index.html` = 3.22.5 · API `DSMT_Api.ps1` = 3.22.6

---

## 🔴 Console fixes needed (index.html)

These 5 functions are still stubs — they show a toast but do NOT call the API in Live mode.

### 1. `saveConfig`
Current (stub):
```js
saveConfig = () => this.showToast('Configuration saved', 'var(--green,#1a7f37)');
```
Fix: call `POST /api/config` with `{ directory: { ldapServer, baseDN }, domains, contractorOUs }`.

### 2. `saveDb`
Current (stub):
```js
saveDb = () => this.showToast('Data source saved', 'var(--green,#1a7f37)');
```
Fix: call `POST /api/db/config` with `{ host, port, name, auth, user, password, encrypt }`.

### 3. `saveCa`
Current (stub):
```js
saveCa = () => this.showToast('Certificate Authority settings saved', 'var(--green,#1a7f37)');
```
Fix: call `POST /api/ca/config` with `{ host: caHost, commonName: caCommonName }`.

### 4. `exportDl`
Current (bug — uses wrong variable):
```js
exportDl = () => {
  ...
  this.DL_DATA.length   // ← wrong! should be this.state.dlResults.length
  ...
};
```
Fix: replace `this.DL_DATA.length` with `(this.state.dlResults || []).length`.

### 5. `createUser` / `addMember` / `removeMember` / `jobToggle` / `jobRun`
These fire demo toasts in Live mode instead of calling the API.

**createUser** — fix: call `POST /api/users` with `{ sam, name, ou }`, then reload users.

**addMember** — fix: call `POST /api/groups/:name/members` with `{ sam }` (prompt for SAM first).

**removeMember** — fix: call `DELETE /api/groups/:name/members/:sam`.

**jobToggle** — fix: call `POST /api/jobs/:name/toggle` with `{ enabled: !current }`.

**jobRun** — fix: call `POST /api/jobs/:name/run`.

---

## 🟡 Version to bump to: 3.22.7
After all 5 fixes above, bump version in ALL 5 places inside index.html:
- Sidebar label (`v3.22.5` → `v3.22.7`)
- Overview badge
- About modal
- Installer-wizard label
- `buildConfig()` version field

---

## ✅ Already done (do NOT redo)
- `Write-401` helper added to API (fixes CORS+401 race)
- `DELETE` added to CORS allowed methods
- All 31 bare 401 responses replaced with `Write-401`
- Routes added: `/api/users/:sam/lock`, `/api/users` (POST), `/api/groups/:name/members` (POST+DELETE), `/api/jobs/:name/toggle`, `/api/jobs/:name/run`, `/api/config` (POST), `/api/ca/config` (POST), `/api/db/config` (POST)
- Console: `userLock`, `userActionLive` (lock/unlock), `importConfig`, `exportDl` bug found

---

## 🔵 Known environment facts
- SQL Server: `192.168.1.50:1433` (use IP — `sql01.lab.local` DNS may not resolve)
- Domain controller: `dc.lab.local` / Base DN: `DC=LAB,DC=LOCAL`
- IIS identity: `LAB\IIS$` (db_datareader + db_datawriter on DSMTOOL)
- API port: **8780**, Console port: **8080** (IIS)
- Windows service name: `DSMT-Api`
- Deploy paths: API → `C:\Program Files\DSMT\server\` · Console → `C:\inetpub\dsmt\index.html`
- After replacing DSMT_Api.ps1: run `Restart-Service DSMT-Api`
