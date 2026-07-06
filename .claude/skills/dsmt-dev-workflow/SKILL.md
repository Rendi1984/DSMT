---
name: dsmt-dev-workflow
description: Development workflow for the Directory Services Management Tool (DSMT) repo — editing the single-line index.html bundle safely, PowerShell rules, versioning, git/PR flow, and keeping the deployment guide/ZIP in sync. Use for ANY code change in this repo (console, API, PowerShell modules, installers) or when asked to update/regenerate the deployment guide or deploy package.
---

# DSMT Development Workflow

This project has sharp edges that aren't visible from a normal file listing. Read this before editing anything.

## 1. `index.html` is a compiled bundle, not source

The entire console (all class methods, all page markup) lives on **one physical line** (~292K+ characters) inside a `text/x-dc` script block. There is no `source/` folder in this repo to rebuild from — you are editing the compiled output directly.

**Consequences:**
- The `Read` tool cannot load the whole file (exceeds token limits) and the `Edit` tool is impractical for this file. Use a **Python script** that does uniqueness-asserted string replacement instead (see pattern below).
- Line 173-ish "line numbers" are meaningless. Locate code via `grep -o` / `python3 -c "content.find(...)"` on unique anchor strings, not line numbers.
- **Escaping is byte-literal, not re-derived**: quotes appear as literal `\"` (backslash+quote, 2 chars), closing tags as `</div>` (6 literal chars, NOT a real `/`), newlines inside JS as literal `\n` (2 chars) in some spots. **Unicode punctuation (`·`, `→`, `—`, `–`) appears as the literal UTF-8 character**, not as `·` etc. — always grep the real file for the exact bytes around your target before constructing a replacement string; don't guess the escaping.
- When adding brand-new markup (a new page/button), don't hand-type a full block from scratch — copy the surrounding pattern of an existing analogous page (find via `grep -o "<sc-if value=\\\\\"{{ isXxx }}\\\\\""` and read a ~2-4KB window) and adapt field names.

**The standard edit script pattern** (put in the scratchpad, run with `python3`):
```python
path = "/home/user/DSMT/index.html"
out_path = "<scratchpad>/index_vX.Y.Z.html"
content = open(path, encoding="utf-8").read()

replacements = [(old1, new1), (old2, new2), ...]
for i, (old, new) in enumerate(replacements, 1):
    count = content.count(old)
    if count != 1:
        print(f"ERROR: replacement #{i} found {count} times (expected 1)"); sys.exit(1)
    content = content.replace(old, new, 1)

# version bump: assert exact count (5 occurrences) before blind-replacing
count_ver = content.count("OLD.VER.SION")
assert count_ver == 5
content = content.replace("OLD.VER.SION", "NEW.VER.SION")
open(out_path, "w", encoding="utf-8").write(content)
```
Write the script's output to a scratchpad path first, run the verification checklist below against it, and only `cp` it over the repo's `index.html` once it passes. Editing a 292K-character single-line file in place with no intermediate check is how a bad replacement (wrong occurrence count, broken escaping) silently corrupts the file — the scratchpad step exists to catch that before it lands on the tracked file, not to route around any tooling restriction.

## 2. Verification checklist (every index.html change)

Run all of these before committing — they catch the three failure modes that actually occur (unbalanced edits, duplicate/missing anchors, illegal JSON escapes):
```bash
python3 -c "
import json
c = open('<scratchpad>/index_vX.Y.Z.html').read()
print('braces', c.count('{'), c.count('}'))   # must match
print('parens', c.count('('), c.count(')'))   # must match
print('OLDVER left:', c.count('OLD.VER'), '| NEWVER:', c.count('NEW.VER'))  # 0 and 5
# Brace/paren counts do NOT catch a bad JSON escape (e.g. a backslash-escaped
# single quote, \\' — not legal JSON) inside a __bundler/template edit. Always
# also json.loads() both embedded blocks directly, not just the outer file:
idx = c.find('<script type=\"__bundler/manifest\">{')
json.loads(c[c.find('>', idx)+1 : c.find('</script>', idx)])
idx2 = c.find('<script type=\"__bundler/template\">')
json.loads(c[c.find('>', idx2)+1 : c.find('</script>', idx2)])
print('manifest + template JSON: OK')
"
# then headless-render it:
cp <scratchpad>/index_vX.Y.Z.html <scratchpad>/index.html
(python3 -m http.server 8899 --directory <scratchpad> &)
/opt/pw-browsers/chromium-1194/chrome-linux/chrome --headless --disable-gpu --no-sandbox \
  --virtual-time-budget=9000 --dump-dom http://localhost:8899/index.html > dom.html
grep -io "dsmt\|<new feature text>" dom.html   # confirms it renders, no blank page
```
Also grep for each new `*Live` handler you added — it should appear **exactly twice** (its `= async () => {` definition, and its one call site). Once = orphaned; three+ = probably duplicated.

## 3. PowerShell rules (all `.ps1` / `.psm1` files)

Windows PowerShell 5.1 compatibility is MANDATORY in this repo — see the separate **`powershell-scripting`** skill for the general rules (no `??`/ternary/`&&`, ASCII-only, brace-balance check, here-string/`$using:`/case-sensitivity gotchas). DSMT-specific on top of that:
- Every `.ps1`/`.psm1` file in this repo must pass the ASCII + brace-balance check before committing.
- Module functions are imported fresh per Pode route/runspace (see `DSMT_Api.ps1`'s `foreach ($m in 'Db','Auth',...)`) — don't assume `$script:`-scoped state survives between requests.

## 4. Versioning

Format `MAJOR.FEATURE.FIX`. Check `CHANGELOG.md`'s top entry for the current number — don't trust `CLAUDE.md`/`TODO_FIXES.md` blindly, they can drift (and should be corrected if they have).

**index.html version literal appears in exactly 6 places** (since 3.31.1) — sidebar footer, overview badge, About modal (×2), `buildConfig()`, and the sign-in screen under the Demo/Live toggle. Bump all 6 together via one assert-then-replace (see script pattern above). If a release only touches `.ps1`/`.md` files, do **not** bump the index.html literal — the next release that *does* touch index.html jumps straight from the last-bumped number (e.g. skip 3.29.1-3.29.3, go 3.29.0 → 3.29.4).

Add a `## X.Y.Z` entry to the top of `CHANGELOG.md` for every release, describing root cause + fix, not just "fixed bug in X".

## 5. Git / PR workflow

This repo is git-connected — every change goes through a PR, never a direct push to `main`:
```bash
git add -A && git commit -m "..."
git push -u origin claude/repo-dsmt-file-list-u3thrd
# create PR (head=that branch, base=main), then merge it
git fetch origin main && git checkout -B claude/repo-dsmt-file-list-u3thrd origin/main
git push -u origin claude/repo-dsmt-file-list-u3thrd   # keep the branch in sync with merged main
```
Do this resync after **every** merge — the branch must always start the next change from the latest merged `main`, not drift ahead of it with stale history.

## 6. The Live/Demo pattern (console)

Every action has a demo path (local state only) and, in Live mode, must call the real API:
```js
someAction = () => {
  if (this.state.connMode === 'live') { this.someActionLive(); return; }
  /* ...existing demo behavior, unchanged... */
};
someActionLive = async () => {
  try {
    const r = await this.apiFetch('/api/...', { method: 'POST', body: JSON.stringify({...}) });
    this.showToast('...', 'var(--green,#1a7f37)');
  } catch (e) { this.showToast('Failed: ' + e.message, 'var(--red,#cf222e)'); }
};
```
Before adding a new API-backed feature, grep whether the backend function/route **already exists** — this codebase has repeatedly had real, working PowerShell backends with no console wiring (found 9 + 3 + 4 such gaps across past sessions). Don't assume "not visible in the UI" means "not implemented server-side".

## 7. Deployment guide + ZIP — keep them in sync

`Deployment_Guide.html` (delivered to the user as a file + Artifact, NOT committed to the repo — see `CLAUDE.md`'s exclusion list) and the `DSMT-Deploy.zip` package are living documents. **Any time a user-facing behavior, port, permission, or page changes, update the guide before considering the task done**:
- New console page → add a `.feature` entry (what it does, what to configure, API routes) + a sidebar `<a>` link
- New backend requirement (firewall rule, AD/SQL permission, port) → update the Ports & Firewall / Permissions sections
- New install path/switch → update the relevant Install section
- Bump the version stamp in the sidebar brand-sub and the closing "Version" callout

To refresh the ZIP after repo changes:
```bash
ROOT=<scratchpad>/deploy_zip   # already laid out: root files + server/{modules,sql}
cp /home/user/DSMT/<changed-file> "$ROOT/<same-relative-path>"
cd <scratchpad> && rm -f DSMT-Deploy.zip && cd deploy_zip && zip -r -X ../DSMT-Deploy.zip . -x '.*'
```
The folder layout inside the ZIP mirrors `CLAUDE.md`'s file-mapping table exactly — don't improvise a different structure.
