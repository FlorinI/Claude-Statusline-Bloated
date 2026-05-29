# Claude-Statusline-Bloated

A dense, multi-line status line for [Claude Code](https://claude.com/claude-code). Surfaces every dial that affects the model's intelligence, latency, and cost: model + flags, context window (with a two-axis quality read), a per-leg cost-escalation cluster + sparkline, rate-limit quotas, session duration + turn TPS, and git state — all color-coded by health.

Cross-platform: runs on Windows, macOS, and Linux via PowerShell 7+.

## What it looks like

Each cluster is one line; clusters hide themselves when they have nothing useful to say (e.g. the quota line is hidden until you're over 50% on either window).

```
Opus 4.8 (1M context) v2.1.156 | effort:high | fast:off | think:on
ctx 226.9k/1.00M | 23% | to-compact 723.1k
5h:52% (resets 27m) | 7d:6% (resets 1d17h)
$10.38 | next leg $0.45 = 2.4x $0.19 (fresh) | last = $0.13
legs: $0.17 $0.29 $0.38 $0.37 $0.06 $0.20 $0.22 $0.13 (37)
session: 2h35m alive / 38m api | +542/-75 lines | turn 3m24s @ 228t/s
git: you/your-project@main *✓
```

The colors lean dim for stable/expected values and pop bright/red only when something needs attention.

## Reading the cost & context signals

This status line is built around one question: *when should I hand the conversation over to a fresh session?* Two independent axes answer it.

**Cost** — the `$… | next leg $X = Rx $Y (fresh) | last = $Z` line. A **leg** is one model API call (a tool-using turn spans several). `next leg $X` forecasts the next leg's cost; `Rx` is that forecast divided by a frozen baseline of your first few legs (`$Y`, "fresh") — so `R` reads as *"the next leg costs R times a fresh one."* It's a window-independent bloat signal: green `<5x` · yellow `5–12x` · red `≥12x`. `last` is the most recent leg's realized cost (a spike detector). The `legs:` line is a sparkline of average $/leg across the session, oldest → newest, so the cost trajectory is visible at a glance. All `$/leg` figures share one green→yellow→red gradient.

**Context quality** — the `ctx <count> | <fill%>` cluster. Long-context degradation has two real components, so it shows two signals:
- the **token count** is colored by *absolute* "context rot" (gradual weakening that tracks raw token count): green ≤128k · yellow 128–256k · orange 256–500k · red 500k+;
- the **`%` chip** is colored by *fill fraction* (the sharp cliff near ~60–65% of the window): green <50% · yellow 50–70% · orange 70–85% · red 85%+.

On a 1M-token model the count usually warns first; on a 200k model the fill chip does. `to-compact` shows raw headroom before auto-compaction. (Thresholds reflect 2025–2026 frontier-model long-context benchmarks — not the obsolete 2023-era "~50k and it's dumb" rule of thumb.)

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

Verify the file landed: it should start with `$ErrorActionPreference = 'SilentlyContinue'`.

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
- **`tail!` shows up at the end of the session line**: the script couldn't find your latest user-message timestamp in the transcript tail. Normal during long no-typing stretches; harmless.
- **Garbled escape codes**: your terminal doesn't speak ANSI. Use a modern terminal (Windows Terminal, iTerm2, recent VS Code integrated terminal).
- **Debugging**: set `$env:CLAUDE_STATUSLINE_DEBUG = '1'` before launching Claude Code to dump each status-line input JSON to `~/.claude/statusline-input-sample.json`. Useful when something in your `settings.json` or session shape is making a cluster misrender.

## What gets read and written

**Reads:**

- The current Claude Code session's transcript file (path supplied by Claude in the input JSON) — incrementally (only newly-appended lines each refresh), plus a 2 MB tail for the turn-TPS metric.

**Writes** (under your `~/.claude/` directory):

- `stats-cache.json` — per-session rollups (leg counts, billable input per leg, daily token totals) so the cost cluster and sparkline don't re-scan the whole transcript on every refresh.
- `statusline-last.json` — a snapshot of the rendered values (context, fill, cost, the next-leg/fresh ratio, etc.), handy for companion tooling that wants to read the line programmatically.

No telemetry. No network calls. Single file, no dependencies beyond pwsh 7.

## License

MIT — see [LICENSE](LICENSE).
