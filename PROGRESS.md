# DSMT — Session Notes & Open Tasks

This file is the persistent memory between chat/coding sessions. Every session
that changes the project must update it before finishing: move done items to
"Recently completed", add anything left open to "Open tasks", and record any
useful context under "Notes" so a fresh session (with no chat history) can
pick up immediately.

## Current version
3.32.3 (API + Console) — see `CHANGELOG.md` for the authoritative log.

## Open tasks
- **Design-mockup integration into real index.html - user approved the
  index-new.html demo (all 3 palettes + dark/light look good) and wants it
  merged into production. User explicitly asked to break this into
  separate tasks and do ONE AT A TIME (token budget is tight this
  session/account) - do NOT batch these into one big change. Wait for the
  user to say "go" on each one before starting the next.**
  1. **DONE (this session) - Settings sub-nav layout: top pills -> left
     vertical rail**, in `index-new.html`. Added all 8 real tab names
     (General/Database/Connection/Certificate Authority/Access &
     Permissions/Secrets/Roles/Backup) as a left rail matching Soft Sage's
     `<nav style="width:212px...">` block; Access & Permissions is the one
     real/functional tab, the other 7 show a placeholder card (same
     "isOther" pattern the mockups already used) so the rail's look and
     feel can be judged without building out 7 more pages. Verified with
     Playwright: clicking every rail tab switches correctly, switching back
     to Access & Permissions still has full working mappings/toggles/local
     accounts, zero page errors. Rebuilt from a fresh copy of the real
     index.html each time (not layered on the palette-only demo) so
     `index-new.html` always reflects "real app + this one change", not an
     accumulating pile of demo-only edits.
  2. **DECIDED (this session): Settings -> General.** Add a new
     "Customize"/"Appearance" section there, alongside (not replacing) the
     existing Light/Dark toggle. Not yet built - this was a decision-only
     step per the user's "one task at a time" request. Next coding step is
     still #1 (nav layout) or #3 (the picker itself) - user to say which.
  3. **DONE (this session) - Implement the palette picker for real**, in
     `index-new.html`. Moved it out of the global header (which only kept
     the light/dark toggle) into a new "Customize" card in Settings ->
     General, per the task 2 decision: 3 card-style buttons (DSMT Blue/
     Warm Paper/Soft Sage) each with a color swatch and a checkmark on the
     active one, plus the existing light/dark toggle repeated in the same
     card so both axes live together. `renderVals()` now computes
     `paletteCards` (replacing the old header `paletteItems`) and adds
     `isGeneral` alongside `isAccess`/`isOther` bindings so General shows
     the new card instead of the placeholder. Verified with Playwright:
     clicking "General" in the rail shows the Customize card, clicking each
     palette swatch changes `--accent` (confirmed distinct hex values per
     palette), the in-card theme toggle flips `--bg`, and Access &
     Permissions still works fully (mappings/local accounts) after
     switching palettes from the new location - zero page errors, manifest/
     template both `json.loads()` clean, brace/paren balanced.
  4. **Roll the new visual language (warmer colors/pill or rail styling)
     into other pages beyond Access & Permissions**, once 1-3 are solid -
     explicitly the biggest, most token-expensive step; user flagged this
     as "a lot of work and testing" - break it into per-page sub-tasks
     when we get there rather than one giant sweep.
  - **DONE (this session) - full visual merge of `AccessWarmPaper.dc.html`**,
    in `index-new.html`. User explicitly asked to match that mockup file
    "everything including the nav structure", superseding task 1's left
    rail: replaced it with the mockup's actual structure - a slim `<aside>`
    brand/user-footer shell (logo, "Directory Services Management Tool",
    admin footer + theme toggle) plus a top pill-row of the 8 Settings tabs
    inside `<main>` (matches the mockup; the rail was our own earlier
    approximation before the real file was shared). Also added: Hanken
    Grotesk + IBM Plex Mono fonts (Google Fonts link, same as the mockup -
    falls back to system font if offline, this file isn't shipped so no
    CLAUDE.md offline-mandate conflict), SVG icons on the Console access /
    Sign-in groups & roles card headers, the "Let's finish setting up
    access" amber banner + green "setup complete" banner (was already
    close, restyled to match), a "Connected" status pill in the header,
    and card drop-shadows (new `--card-shadow` token per palette). All 3
    palettes' token sets extended with `green`/`greenSoft`/`greenBorder`/
    `accentShadow`/`cardShadow` to support the above. Verified with
    Playwright: aside/header/Connected badge/setup banners all render,
    clicking a top pill switches tabs (Database -> placeholder, Access ->
    real content), removing the System Administrator mapping flips the
    banner from "complete" back to "pending", zero page errors, manifest
    (25 keys) + template both `json.loads()` clean, braces/parens balanced.
  Every step needs the same verification rigor used this session
  (json.loads on manifest+template, brace/paren balance, headless render,
  Playwright interaction test) before shipping - this app has already had
  multiple sessions where a change looked fine in a quick dump-dom check
  but was actually broken (see the systemic table-rendering bug, 3.32.3).
  - **Working convention while this redesign is in progress**: do all of
    steps 1-4 IN `index-new.html`, not `index.html` - user wants
    `index.html` kept untouched as a known-good rollback/backup copy
    throughout the whole redesign process. Once the user is happy with
    where `index-new.html` ends up (could be a while, given "one task at a
    time"), THEY will decide when/whether to promote it to replace
    `index.html` as the real deployed file - don't do that swap
    unprompted. Until then `index-new.html` is not part of the deploy ZIP
    and CLAUDE.md's file-location table (it's a working file, not a
    shipped one).
- CONFIRMED END TO END: the full install -> setup wizard -> sign-in chain
  now works. User granted the NT AUTHORITY\SYSTEM SQL login sysadmin (fixed
  the loopback permission issue) and successfully signed in as the local
  administrator created by Install.cmd. Found and fixed 9 real blocking bugs
  total across 3.29.13-3.29.21 this session (see Recently completed below
  for the full list) - the install flow itself is no longer suspected of
  hiding further bugs.
- Told the user to scope the NT AUTHORITY\SYSTEM grant down from sysadmin
  (server-wide) to just db_datareader/db_datawriter on DSMTOOL - sysadmin
  works but is much broader than needed; not yet confirmed they've done
  this narrowing.
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
- Hit this exact bug in 3.31.2: wrote `\'IBM Plex Mono\'` (backslash-escaped
  single quotes) in a new template snippet. Brace/paren counts stayed
  perfectly balanced (single quotes don't affect them), so that check passed
  clean - but `\'` is not a legal JSON escape (JSON only allows
  `\" \\ \/ \b \f \n \r \t \uXXXX`), so `JSON.parse` on the template string
  failed at runtime with "Error unpacking: Bad escaped character", which
  only surfaced via the headless-render dump-dom check, not the brace-count
  one. Lesson: single quotes inside a `__bundler/template` edit must NEVER
  be backslash-escaped (look at any neighboring `font-family:'IBM Plex
  Mono'` for the correct un-escaped style) - and always literally run
  `json.loads()` on both the extracted manifest AND template strings as a
  dedicated pre-flight step, don't rely on brace-counting or headless-render
  alone to catch this class of error.
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
- 3.32.3: MAJOR FIND. User kept reporting "Add mapping doesn't work" /
  "DL Groups shows a count but no member details" across several rounds -
  root-caused it all the way down via direct Playwright automation
  (headless Chrome + real click/type simulation, not just static dump-dom)
  to a single systemic bug: every data table in the whole app only ever
  rendered exactly 1 row, confirmed present even in the oldest commit in
  this repo (tested against commit 7e20891 and against v3.31.3, both
  showed the identical defect - this has nothing to do with anything
  changed this session). Root cause: real `<table>/<tbody>/<tr>/<td>/<th>`
  tags trigger the browser's HTML table content-model parsing rules, which
  silently drop or foster-parent-away any `<sc-for>` (or its children)
  nested inside them - the DC framework's compiled runtime has
  `sc-raw-table`/`sc-raw-tbody`/`sc-raw-tr`/`sc-raw-td`/`sc-raw-th`/
  `sc-raw-thead` aliases specifically to work around this (confirmed by
  reading the decompressed runtime source - RAW_WRAP/RAW_UNWRAP - and by
  directly testing the fix empirically before committing to it), but NONE
  of this app's 9 tables used them. Fixed all 9 (Sign-in groups & roles,
  Users, DL Groups, Jobs, Audit Log, Certificate Authority, Password
  Expiry, Event Viewer, Roles permission matrix) - each verified via
  Playwright to show the correct row count end-to-end, not just headless
  dump-dom. First attempt only aliased table/tbody/tr/td and missed thead/
  header-tr/th, which caused a NEW regression (headers vanishing) caught
  immediately by the same Playwright check before shipping - lesson:
  when converting a table to sc-raw-* aliases, the header thead/tr/th need
  the exact same treatment as the body, not just the looped row.
  NOTE FOR FUTURE SESSIONS: if a new table/list is ever added to this app,
  it MUST use `sc-raw-table`/`sc-raw-tbody`/`sc-raw-thead`/`sc-raw-tr`/
  `sc-raw-td`/`sc-raw-th` instead of the real tag names, or it will hit
  this exact bug again silently (renders fine with 0-1 items, breaks with
  2+).
- Packaging fix (no version bump - no code changed): user noticed
  `Install.cmd` was missing from the deployment ZIP. Root cause: CLAUDE.md's
  "File locations" table (the source of truth every deploy-ZIP staging step
  reads from) never listed `Install.cmd` at all, even though it's a real,
  actively-documented root-level file (the one-click self-elevating
  installer entry point - see README.md/CHANGELOG.md). Added it to the
  table (`Install.cmd → root/`) and to the current ZIP. Worth double-
  checking the table against `ls` next time a "missing file" report comes
  in, rather than assuming the table is complete.
- 3.32.2: Batch of fixes from user testing 3.32.0 live: (1) local account
  creation used window.prompt() for the password AFTER clicking Create,
  whose message echoed the username - user read it as "asks for username,
  no password field" - replaced with a real inline password field. (2)
  "Sign-in groups & roles" group field was a fixed dropdown of hardcoded
  demo group names with no way to enter a real AD group - now free text
  (sAMAccountName or full DN). (3) DL Groups showed correct member count
  but blank name/detail cells - Get-GroupMembers had no fallback when AD's
  DisplayName is blank (common on lab accounts/nested group members); now
  falls back to sAMAccountName. Confirmed this via code trace (dlRows
  mapping in index.html is correct; the raw server data was the gap) -
  NOT independently verified against the user's live AD, worth confirming
  next session that names now show. (4) Local account toggle route had no
  try/catch - a bad ID or transient SQL hiccup surfaced as a bare 500 the
  console could only describe as "Failed to fetch"; now returns a readable
  error. (5) Clarified (did not change) that Database tab's two Test
  buttons check different things (form values vs. what's saved) - added a
  caption, since the user suspected one was redundant.
  Still open / not addressed this round: user also reported a stray
  "Sign-in groups & roles" table row with a blank group name that Add
  mapping didn't seem to add to; the free-text field change may resolve
  usability here but the specific blank row is very likely a leftover SQL
  row from earlier testing this session (before POST /api/access/mappings'
  existing group/role required-field validation) - tell the user to remove
  it via the row's x button; if Add mapping still silently fails to add a
  NEW row after that, needs a live re-test with Network tab open on the
  actual POST /api/access/mappings call to diagnose further.
- 3.32.0: Redesigned Access & Permissions per direct user request ("I don't
  want both Access security group AND role mapping - one category for
  sign-in, define groups by LDAP, define their permissions there").
  Removed the Require security-group membership toggle + Access security
  group dropdown entirely (both in Settings -> General -> Access &
  Permissions AND the first-run setup wizard's Directory step - the
  wizard's copy was purely decorative, never actually submitted anywhere,
  confirmed by grepping the setup/save POST body). Removed 'No access'
  from the role dropdown (meaningless now - not being in any mapped group
  already denies sign-in). Auth.psm1's Invoke-SignIn now denies outright
  when Resolve-ConsoleRole finds no matching group, replacing the old
  silent "fall back to Read-only" behavior. Removed the now-dead
  POST /api/access/require-group route. Updated Deployment_Guide.html's
  Access Control section and troubleshooting table to match. Verified
  headless (manifest 25 keys, template parses, renders clean) - user
  should re-verify group mapping to System Administrator still works and
  that a user in NO mapped group is now cleanly denied (with the new
  "Not a member of any group mapped for console access" message) rather
  than silently landing on Read-only.
- 3.31.5: User reported the whole Access & Permissions tab needs rethinking
  after finding: (1) mapping SG-SystemTeam-Admins to "No access" still let
  them sign in - CONFIRMED real bug, 'No access' had no rank entry in
  Resolve-ConsoleRole so it fell through as if it were a real role; fixed
  by giving it rank 0 and having Invoke-SignIn explicitly deny on it. (2)
  Toggling "Require security-group membership" (and the local admin
  disable button) failed with "Failed to fetch" / 408s in F12, 20 stacked
  "toggle" requests pending 30+s - traced to Start-PodeServer never setting
  -Threads, so Pode defaults to essentially one request at a time; any
  burst of concurrent calls (3.31.4's 4 parallel loads right after Live
  sign-in, or just clicking a toggle more than once while it's slow) queues
  up and eventually 408s even though the server itself is healthy. Fixed by
  adding -Threads 8. (3) User was confused that "Access security group" and
  "Group -> role mapping" are two separate controls - clarified in chat
  that this is intentional (WHETHER a domain user can sign in at all vs
  WHICH role they get once in) but flagged it as a real UX complaint worth
  a design pass; did NOT redesign/consolidate the tab yet - asked the user
  whether they want that as a separate follow-up before touching UI/UX.
  (4) "Local default administrator" master toggle and the individual
  account's Disable button in the Local accounts list are NOT two
  different mechanisms - toggleLocalAdmin() just calls toggleLocal() on
  whichever local account has builtin=true. The user's report that Disable
  "doesn't work" was actually the same Failed-to-fetch/408 pileup from (2),
  not a separate bug - should resolve once -Threads 8 is deployed.
  index.html unchanged this release (Auth.psm1 + DSMT_Api.ps1 only).
- 3.31.4: Fixed Settings -> General LDAP server appearing to revert after
  Save + F5 (user report). The save path (POST /api/config -> config.json)
  was fine - there was simply no load path at all: setupLdapHost/
  setupBaseDn were only ever set once from hardcoded setup-wizard defaults
  in initial state, and Live sign-in never re-fetched the real saved
  values, so every sign-in reset the form. Fixed GET /api/config to return
  directory.{ldapServer,baseDN,domains} from config.json (it previously
  only returned the unrelated SQL-backed Get-Config hash - a second,
  separate store nothing else in this flow uses), and added
  loadConfigLive() called after Live sign-in to populate the form from it.
  NOTE: domains and contractorOUs are still sent by saveConfigLive's POST
  body but silently ignored server-side (POST /api/config only reads
  d.directory.ldapServer/baseDN) - same class of bug, not yet fixed; flag
  if the user reports domains/contractor OUs also not persisting.
- 3.31.3: The 3.31.2 offline fix DIDN'T actually work - user's F12 still
  showed react/react-dom pending plus two new 404s for the vendored
  assets' own UUIDs. Root cause: appended the two new manifest entries
  without closing the PREVIOUS entry's brace first, so they landed nested
  inside that entry's value instead of as sibling top-level manifest keys -
  Object.keys(manifest) never saw them, so the unpacker never blob-ified
  their <script src> tags, browser 404'd the literal UUID as a relative
  path, window.React never got set, unpkg.com fallback still ran. This
  slipped through 3.31.2's own verification because I only checked that
  manifest json.loads()'d without error - never checked it produced the
  RIGHT NUMBER of top-level keys or that my new keys were actually present
  as top-level entries (not nested). Fixed the brace nesting and this time
  asserted len(manifest)==25 with both new UUIDs present as top-level keys
  before shipping. Re-verified headless with unpkg.com DNS-blackholed: zero
  404s, zero unpkg.com requests this time. LESSON (added to the
  dsmt-dev-workflow skill): when adding manifest/JSON entries via string
  splicing, always assert the exact expected key COUNT and check specific
  keys are top-level, not just that the whole blob parses - valid JSON can
  still be structurally wrong (nested where it should be a sibling).
- 3.31.2: Fixed the console silently requiring internet access - the compiled
  DC framework runtime bundled inside index.html always fetched React 18.3.1
  from unpkg.com CDN at boot (unconditionally, not gated by Demo/Live mode),
  which the user caught in F12 as react.production.min.js/react-dom stuck
  pending + a [bundle] error whenever the machine was offline. Fixed by
  vendoring the exact byte-identical React/ReactDOM UMD builds (verified
  against the runtime's own SRI hashes) as two new offline manifest assets,
  loaded before the DC runtime's bootstrap script so its
  "skip CDN if window.React/ReactDOM already exist" check always
  short-circuits. Verified headless with unpkg.com DNS-blackholed: renders
  identically, zero network attempts logged. Also moved the 3.31.1 sign-in
  version label to sit under the LIVE/demo status line instead of under the
  Demo/Live toggle buttons, per user clarification. The user separately
  reported the 3.31.0 LDAP "Test connection" button returning a 405 - that
  is almost certainly because their server is still running the pre-3.31.0
  DSMT_Api.ps1 (missing the /api/directory/test route); told them to
  redeploy DSMT_Api.ps1 + Restart-Service DSMT-Api. If they redeploy and
  it's STILL 405, that's a real bug to investigate next session (haven't
  been able to verify against a live server this session).
- 3.31.1: Added the version number to the sign-in screen, under the Demo/Live
  toggle (user request). Now a 6th place carries the version literal in
  index.html - updated CLAUDE.md's bump checklist and the dsmt-dev-workflow
  skill's "exactly N places" assertion from 5 to 6 so future sessions don't
  under-count and leave this one stale.
- 3.31.0: Added an LDAP "Test connection" button on Settings -> General (user
  request, same session as 3.30.0's responsive menu). New
  `POST /api/directory/test` route validates the LdapServer/BaseDN currently
  typed in the form (not the saved config) via the same Get-UserGroups probe
  `/api/health` uses. Also rewrote the Deployment Guide's config.json
  reference section with an exact per-prompt table of Install-DSMT.ps1's
  defaults (most fields have real defaults if you Enter-through the
  installer; LDAP host and SQL Server host are the only two with no default
  - the installer keeps re-prompting until you supply them). Verified via
  the same headless-render method as 3.30.0 (renders, "Test connection"
  button count went from 2 to 3 in the DOM dump as expected); not manually
  clicked in a real live-mode browser session this session.
- 3.30.0: Made the console layout responsive (user request, from an earlier
  session). Below ~860px viewport width the sidebar (workspace switcher +
  nav) collapses into a hamburger button in the header; tapping it opens
  the sidebar as a fixed/overlay panel with a dimmed backdrop, closing on
  backdrop click, hamburger toggle, or picking a nav item. Above the
  breakpoint nothing changed - same fixed 256px sidebar as always. Notable
  because this app has NO CSS classes anywhere in the templated markup
  (everything is inline `style="{{ ... }}"` bindings computed in JS) and no
  prior resize/lifecycle handling existed for layout - added a
  `window.resize` listener in `componentDidMount`/removed it in
  `componentWillUnmount` (mirroring the existing keydown-listener pattern
  used for the command palette) that flips `state.isMobile`, and the
  sidebar's style string is now computed conditionally on
  `isMobile`/`sidebarOpen` instead of being a static literal. Verified via
  headless Chrome dump-dom (renders identically to the pre-change baseline,
  same pre-existing generic `[bundle] error` false-positive both files
  produce under `--headless`) - did not verify manually in a resized real
  browser this session; worth a quick visual sanity check next time the UI
  is opened live.
- 3.29.22: Fixed Settings -> General/Database/CA "Save changes" returning
  400 every time - Save-Config's -Path parameter defaulted to the bare
  $cfgPath script variable, invisible inside a Pode route's own runspace
  (same bug class as 3.29.20's /api/setup/save fix). All 4 call sites now
  pass -Path $using:cfgPath explicitly. Also added the requested UI
  feature: a first-time-setup indicator directly on the Access &
  Permissions tab (warning marker on the tab label + a red callout inside
  listing exactly what's pending - default password, LDAP admin group
  mapping), not just the alerts bell. Clears automatically per-task, same
  as the bell.
- Full install/setup/sign-in chain confirmed working by the user: granted
  NT AUTHORITY\SYSTEM sysadmin in SQL (workaround for the loopback issue),
  signed in successfully as the local administrator from Install.cmd.
  Recommended narrowing that grant to db_datareader/db_datawriter on
  DSMTOOL only (least privilege, matches what the guide already documents).
- 3.29.21: Confirmed via user's logs that 3.29.20's /api/setup/save fix
  worked (dsmt-request.log showed the DB actually got created and
  config.json got populated for the first time this session). The next
  failure (sign-in HTTP 500) turned out to be a real SQL permissions issue
  in the environment (SQL Server and API on the same machine -> Windows
  auth loopback connections present as NT AUTHORITY\SYSTEM to SQL Server,
  not the service/computer account), not a code bug - but it exposed a
  real robustness gap: Write-Audit (Db.psm1) had no error handling at all,
  so any transient SQL failure there crashed whatever unrelated route
  called it (login, user actions, CA actions, ...) with an unhelpful raw
  500. Fixed: Write-Audit now catches and logs failures instead of
  throwing; /api/auth/login's session-creation step is now also wrapped,
  returning a readable 502 instead of an empty 500. Documented the
  NT AUTHORITY\SYSTEM loopback gotcha with exact SQL fix commands in
  README.md and Deployment_Guide.html (Permissions section + troubleshooting
  table).
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
