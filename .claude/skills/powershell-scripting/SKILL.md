---
name: powershell-scripting
description: Writing and reviewing PowerShell scripts/modules, especially when Windows PowerShell 5.1 compatibility matters (no pwsh/PS7 available on target machines). Use whenever creating or editing .ps1/.psm1 files, or when a script needs to run on an older/locked-down Windows Server without PowerShell 7.
---

# PowerShell Scripting

General guidance for writing PowerShell that will actually run where it's deployed — most failures in practice come from assuming PowerShell 7 syntax/behavior on a box that only has Windows PowerShell 5.1.

## Windows PowerShell 5.1 compatibility (assume this unless told otherwise)

If there's any chance the target machine only has the built-in Windows PowerShell (no `pwsh`/PS7 installed — true for most on-prem Windows Servers unless someone explicitly installed PS7), avoid PS7-only syntax:

| Don't use | PS 5.1-safe alternative |
|---|---|
| `??` (null-coalescing) | `if ($null -eq $x) { $x = $default }` |
| `?:` (ternary) | `if ($cond) { $a } else { $b }` (or `$(if($cond){$a}else{$b})` inline) |
| `&&` / `\|\|` | separate statements, or `if ($?) { ... }` |
| `pwsh` in shebangs/examples | `powershell.exe` |
| `[System.Text.Json]` (PS7 built-in) | `ConvertTo-Json`/`ConvertFrom-Json` (5.1-native) |
| Pipeline chain operators, `??=` | explicit `if`/assignment |

**ASCII only in script files** — no smart quotes (`’ ‘ " "`), no em-dashes (`—`), no arrows (`→`), no non-breaking spaces. These sneak in easily when copy-pasting from a chat or a formatted doc and can break parsing or just look wrong in `cmd.exe`/legacy consoles. Verify after any edit:
```bash
python3 -c "
c = open('path/to/script.ps1', encoding='utf-8').read()
bad = [ch for ch in c if ord(ch) > 127]
print('non-ascii chars:', len(bad), set(bad))
"
```

**Verify brace/paren balance** after any edit to a script you didn't write from scratch (catches truncated here-strings, unclosed script blocks):
```bash
python3 -c "
c = open('path/to/script.ps1', encoding='utf-8').read()
print('braces', c.count('{'), c.count('}'))
print('parens', c.count('('), c.count(')'))
"
```

## Other common gotchas worth checking for

- **Here-strings** (`@' ... '@` / `@" ... "@`) — the closing `'@`/`"@` MUST be the first two characters on its own line (no leading whitespace). Easy to break with auto-indentation from an editor.
- **`$using:` scope in remote/job/runspace contexts** (Pode routes, `Invoke-Command`, background jobs) — on PS 5.1 this only reliably resolves variables that are *directly* in scope of the block using it, and member-access like `$using:Config.Property` is unreliable — capture to a local variable first (`$cfg = $using:Config`) then access members normally.
- **String comparison is case-insensitive by default** (`-eq`, `-like`) — use `-ceq`/`-clike` if case must matter; don't assume this is why something "isn't matching."
- **`Get-Service -ComputerName`, `Test-Connection`, remote queries**: a blocked ICMP ping does not mean the remote RPC/WinRM channel is down — don't gate a real check behind a ping result; treat ping as a hint at most.
- **File paths with backslashes inside C# string literals** (e.g. generating a native service host via `Add-Type`) — a regular `"..."` string literal in the embedded C# needs `\\` for each backslash; prefer a verbatim string (`@"..."`) when the content includes Windows paths.
- **Module re-import per runspace**: each Pode route (or PS job/runspace) may re-import a module fresh, resetting any module-scoped (`$script:`) state — don't assume a `$script:` variable set in one request survives into the next unless it's explicitly re-derived (e.g. lazily rebuilt from a config file on first use).

## Before shipping a change

1. ASCII + brace-balance check (above) on every touched file.
2. If you can't execute PowerShell directly in this environment, say so explicitly rather than claiming a script "works" — review logic, syntax, and known-gotcha patterns instead, and note that runtime verification is pending on the actual target.
3. Prefer additive, minimal diffs — PowerShell scripts in ops/deployment contexts are usually run unattended on a production-ish box; an unnecessary refactor is a bigger risk than it looks.
