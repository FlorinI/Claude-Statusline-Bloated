# Claude-Statusline-Bloated

A dense, multi-line status line for [Claude Code](https://claude.com/claude-code). Shows model + flags, context window + to-compact countdown, last-turn token breakdown + turn TPS, rate-limit quotas, session cost + duration, and git state — color-coded by health.

Cross-platform: runs on Windows, macOS, and Linux via PowerShell 7+.

## What it looks like

Each cluster is one line; clusters hide themselves when they have nothing useful to say (e.g. the quota line is hidden until you're over 50% on either window).

```
Claude Opus 4.7 v2.0.30 | effort:xhigh | fast:on | think:on
ctx 142k/200k | 71% | to-compact 48k
5h:62%  (resets 1h22m) | 7d:38%  (resets 4d12h) | today:1.2M
last hit 87% | in:42  out:1.1k  cr:128k  cw:14k | turn 8s @ 138t/s
session: $0.87 | 12m alive / 2m18s api | +147/-32 lines
git: FlorinI/Claude-Statusline-Bloated@main *↑1
```

The colors lean dim for stable/expected values and pop bright/red only when something needs attention.

## Install (for Claude Code agents)

If you're an AI agent — and the person who pointed you at this repo is a human asking you to install it for them — follow the steps below verbatim. Don't ask the user to run shell commands themselves; you have the tools to do it.

### Step 1 — verify PowerShell 7+ is available

PowerShell 7+ (`pwsh`) is the runtime. Check with:

```bash
pwsh --version
```

If that prints `PowerShell 7.x.x` or higher, skip to Step 2.

If `pwsh` is not found:

- **macOS**: install with Homebrew — `brew install --cask powershell`. (If Homebrew isn't present, point the user at https://brew.sh and stop; don't try to install Homebrew yourself.)
- **Linux**: follow https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux for the user's distro. Pick the package-manager path (apt / dnf / snap) appropriate to their system.
- **Windows**: PowerShell 7 isn't preinstalled — `powershell.exe` (5.1) is. Install via `winget install --id Microsoft.PowerShell -e --source winget` or download from https://github.com/PowerShell/PowerShell/releases. **Do not use `powershell.exe` 5.1** — this script uses PS7-only features.

After install, re-run `pwsh --version` to confirm.

### Step 2 — download the script

Fetch the raw file and save it to the user's Claude Code config directory.

- **Source URL**: `https://raw.githubusercontent.com/FlorinI/Claude-Statusline-Bloated/main/statusline-bloated.ps1`
- **Destination**: `~/.claude/statusline-bloated.ps1` (resolve `~` to the user's actual home directory: `$HOME` on macOS/Linux, `%USERPROFILE%` on Windows).

Use the WebFetch tool to retrieve it, then the Write tool to save it. Preserve byte-for-byte content; this script is whitespace-sensitive in places (the ANSI escape sequences use literal ESC characters).

Verify the file landed: it should be ~365 lines and start with `$ErrorActionPreference = 'SilentlyContinue'`.

### Step 3 — wire it into `~/.claude/settings.json`

Read `~/.claude/settings.json` (create the file as `{}` if it doesn't exist). Add or replace the `statusLine` top-level key with:

**On macOS / Linux:**

```json
{
  "statusLine": {
    "type": "command",
    "command": "pwsh -NoProfile -File \"/Users/<USERNAME>/.claude/statusline-bloated.ps1\""
  }
}
```

Replace `/Users/<USERNAME>` with the user's actual home directory — `$HOME` resolved (e.g. `/Users/alice` or `/home/alice`). Claude Code does **not** expand `$HOME` or `~` inside the command string; the path must be literal.

**On Windows:**

```json
{
  "statusLine": {
    "type": "command",
    "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\<USERNAME>\\.claude\\statusline-bloated.ps1\""
  }
}
```

Replace `C:\\Users\\<USERNAME>` with the user's actual `%USERPROFILE%`. The `-ExecutionPolicy Bypass` flag is required on Windows; omit it on macOS/Linux (where it's a no-op but tidier without).

**Preserve every other key in `settings.json` exactly as it was** — `permissions`, `env`, `hooks`, etc. Only add or replace the `statusLine` block.

### Step 4 — restart Claude Code

Tell the user:

> Restart Claude Code (quit and reopen the CLI / app / VS Code extension) for the status line to take effect. After restart, you should see the multi-line status block above the prompt.

Don't try to restart it yourself — the user has to do that.

### Step 5 — confirm and exit

Report back with: which OS you detected, where you wrote the .ps1, and the final `statusLine.command` value you put in `settings.json`. Then stop. The user will tell you if anything looks wrong after restart.

## Install (for humans, no agent)

If you're doing this by hand:

1. `pwsh --version` — install PowerShell 7 from https://github.com/PowerShell/PowerShell if missing.
2. `curl -fsSL https://raw.githubusercontent.com/FlorinI/Claude-Statusline-Bloated/main/statusline-bloated.ps1 -o ~/.claude/statusline-bloated.ps1` (or download via browser).
3. Edit `~/.claude/settings.json` and add the `statusLine` block from Step 3 above, using your actual home directory in the path.
4. Restart Claude Code.

## Troubleshooting

- **Status line is blank**: PowerShell 7 isn't on PATH, or the script path in `settings.json` is wrong. Test by running `pwsh -File ~/.claude/statusline-bloated.ps1 < /dev/null` (or `Get-Content $null | pwsh -File ...` on Windows) — you should get an error about missing input, not "command not found".
- **`tail!` shows up in cluster 3**: the script couldn't find your latest user-message timestamp in the transcript tail. Normal during long no-typing stretches; harmless.
- **Garbled escape codes**: your terminal doesn't speak ANSI. Use a modern terminal (Windows Terminal, iTerm2, recent VS Code integrated terminal).
- **Debugging**: set `$env:CLAUDE_STATUSLINE_DEBUG = '1'` before launching Claude Code to dump each status-line input JSON to `~/.claude/statusline-input-sample.json`. Useful when something in your `settings.json` or session shape is making a cluster misrender.

## What gets read from disk

The script reads (but never writes):

- The current Claude Code session's transcript file (path supplied by Claude in the input JSON) — last 2 MB only.
- `~/.claude/stats-cache.json` if present, for the "today:" daily-total field in the quota cluster. If absent, that field is silently omitted.

No telemetry. No network calls. Single-file, no dependencies beyond pwsh 7.

## License

MIT — see [LICENSE](LICENSE).
