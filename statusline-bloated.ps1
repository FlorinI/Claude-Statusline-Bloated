$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$input_json = [Console]::In.ReadToEnd()
$d = $input_json | ConvertFrom-Json

# Cross-platform home dir: $env:USERPROFILE on Windows, $HOME on macOS/Linux.
$ClaudeHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }

if ($env:CLAUDE_STATUSLINE_DEBUG -eq '1') {
    $input_json | Out-File -FilePath "$ClaudeHome/.claude/statusline-input-sample.json" -Encoding utf8
}

function FmtPct($v) { if ($null -eq $v) { '--' } else { '{0:N0}%' -f $v } }
function FmtNum($v) {
    if ($null -eq $v) { return '--' }
    if ($v -ge 1e6) { return ('{0:N2}M' -f ($v / 1e6)) }
    if ($v -ge 1e3) { return ('{0:N1}k' -f ($v / 1e3)) }
    return ('{0:N0}' -f $v)
}
function FmtDuration($sec) {
    if ($null -eq $sec) { return '--' }
    $sec = [int]$sec
    if ($sec -lt 0) { return 'now' }
    if ($sec -lt 60)    { return ("{0}s" -f $sec) }
    if ($sec -lt 3600)  { return ("{0}m{1:D2}s" -f [int][Math]::Floor($sec/60), ($sec % 60)) }
    if ($sec -lt 86400) { return ("{0}h{1:D2}m" -f [int][Math]::Floor($sec/3600), [int][Math]::Floor(($sec % 3600)/60)) }
    return ("{0}d{1:D2}h" -f [int][Math]::Floor($sec/86400), [int][Math]::Floor(($sec % 86400)/3600))
}

# ANSI color helpers
$ESC = [char]27
function Dim($t)        { "${ESC}[2m$t${ESC}[0m" }
function Bold($t)       { "${ESC}[1m$t${ESC}[0m" }
function Red($t)        { "${ESC}[31m$t${ESC}[0m" }
function Green($t)      { "${ESC}[32m$t${ESC}[0m" }
function Yellow($t)     { "${ESC}[33m$t${ESC}[0m" }
function Cyan($t)       { "${ESC}[36m$t${ESC}[0m" }
function RedBold($t)    { "${ESC}[1;31m$t${ESC}[0m" }
function White($t)      { "${ESC}[97m$t${ESC}[0m" }
function Orange($t)     { "${ESC}[38;5;208m$t${ESC}[0m" }
function Magenta($t)    { "${ESC}[95m$t${ESC}[0m" }
function BrightCyan($t) { "${ESC}[96m$t${ESC}[0m" }
function DarkGray($t)   { "${ESC}[38;5;240m$t${ESC}[0m" }
function BoldBright($t) { "${ESC}[1;97m$t${ESC}[0m" }

function ColorEffort($lvl) {
    switch ($lvl) {
        'low'    { return "${ESC}[38;5;220m$lvl${ESC}[0m" }
        'medium' { return "${ESC}[38;5;40m$lvl${ESC}[0m" }
        'high'   { return "${ESC}[38;5;147m$lvl${ESC}[0m" }
        'xhigh'  { return "${ESC}[38;5;61m$lvl${ESC}[0m" }
        'max'    { return "${ESC}[1;38;5;255mMAX${ESC}[0m" }
        default  { return $lvl }
    }
}

function ColorCost($v, $text) {
    if ($null -eq $v) { return $text }
    if ($v -lt 1)   { return (Dim $text) }
    if ($v -le 5)   { return $text }
    if ($v -le 10)  { return (White $text) }
    if ($v -le 20)  { return (Yellow $text) }
    if ($v -le 50)  { return (Orange $text) }
    return (RedBold $text)
}

# Absolute context-rot bands, recalibrated for 2026 frontier models (see
# docs/long-context-degradation-2026.md). The old 50k/200k thresholds were
# 2023-era (small-window) and fired far too early. Near-full intelligence holds
# to ~128k; gradual weakening on hard multi-fact tasks 128-256k; real degradation
# 256-500k; heavy past 500k. This is the absolute-rot axis; the fill-% chip
# (BgFill) carries the window-relative ~60-65% cliff. Together they're the hybrid.
function ColorByTokenCount($tokens, $text) {
    if ($null -eq $tokens) { return $text }
    if ($tokens -lt 32000)   { return "${ESC}[38;5;46m$text${ESC}[0m" }
    if ($tokens -lt 128000)  { return "${ESC}[38;5;40m$text${ESC}[0m" }
    if ($tokens -lt 256000)  { return (Yellow $text) }
    if ($tokens -lt 500000)  { return (Orange $text) }
    return (RedBold $text)
}

# Threshold colorizers. okMax/warnMax: green below okMax, yellow below warnMax, red above (for "high is bad" metrics).
# okMin/warnMin: green above okMin, yellow above warnMin, red below (for "low is bad" metrics).
function ColorHigh($v, $text, $okMax, $warnMax) {
    if ($null -eq $v) { return $text }
    if ($v -lt $okMax)   { return (Green $text) }
    if ($v -lt $warnMax) { return (Yellow $text) }
    return (RedBold $text)
}
function ColorLow($v, $text, $okMin, $warnMin) {
    if ($null -eq $v) { return $text }
    if ($v -gt $okMin)   { return (Green $text) }
    if ($v -gt $warnMin) { return (Yellow $text) }
    return (RedBold $text)
}

# Truecolor gradient for the per-leg cost sparkline. Anchors: $0.05 = green,
# $0.28 = yellow, $0.50 = red. Below $0.05 clamps to green; above $0.50 clamps
# to red. Linear RGB interpolation between anchors. Tune the three anchor
# dollar values below to recalibrate.
function LegRGB($cost) {
    $greenAnchor = 0.05; $yellowAnchor = 0.28; $redAnchor = 0.50
    $g = @(0, 215, 0); $y = @(215, 215, 0); $r = @(215, 0, 0)
    if ($cost -le $greenAnchor) { return $g }
    if ($cost -ge $redAnchor)   { return $r }
    if ($cost -le $yellowAnchor) {
        $t = ($cost - $greenAnchor) / ($yellowAnchor - $greenAnchor)
        return @(
            [int][Math]::Round($g[0] + ($y[0] - $g[0]) * $t),
            [int][Math]::Round($g[1] + ($y[1] - $g[1]) * $t),
            [int][Math]::Round($g[2] + ($y[2] - $g[2]) * $t)
        )
    }
    $t = ($cost - $yellowAnchor) / ($redAnchor - $yellowAnchor)
    return @(
        [int][Math]::Round($y[0] + ($r[0] - $y[0]) * $t),
        [int][Math]::Round($y[1] + ($r[1] - $y[1]) * $t),
        [int][Math]::Round($y[2] + ($r[2] - $y[2]) * $t)
    )
}
function ColorLegCell($cost, $text) {
    if ($null -eq $cost) { return $text }
    $rgb = LegRGB $cost
    return "${ESC}[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$text${ESC}[0m"
}

# Truecolor band palette for the "muted tint" background chips (the M8 style):
# the value is drawn in its bright band color on a 30%-intensity tint of the
# same hue, with one space of padding each side. Used for the background-colored
# metrics — the cluster-2 fill-% chip and the cluster-3 froz5 cost ratio.
$BAND_GREEN  = @(0, 200, 0)
$BAND_YELLOW = @(220, 200, 0)
$BAND_ORANGE = @(255, 140, 0)
$BAND_RED    = @(210, 0, 0)
function BgTint($rgb, $text) {
    $m0 = [int]($rgb[0] * 0.30); $m1 = [int]($rgb[1] * 0.30); $m2 = [int]($rgb[2] * 0.30)
    "${ESC}[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2]);48;2;$m0;$m1;${m2}m $text ${ESC}[0m"
}
# Context fill-fraction → tint chip. Window-relative quality axis (% of the
# model's window in use), capturing the ~60-65% effective-context cliff seen
# across 2026 frontier models (see docs/long-context-degradation-2026.md):
# yellow as you approach it, orange past it, red near the 95% auto-compact wall.
# Pairs with ColorByTokenCount (absolute rot) to form the hybrid quality read.
function BgFill($pct, $text) {
    if ($null -eq $pct) { return (Dim $text) }
    if ($pct -lt 50) { return (BgTint $BAND_GREEN $text) }
    if ($pct -lt 70) { return (BgTint $BAND_YELLOW $text) }
    if ($pct -lt 85) { return (BgTint $BAND_ORANGE $text) }
    return (BgTint $BAND_RED $text)
}
# Froz5 dollar-ratio → tint chip via a DIVERGING gradient pinned WHITE at parity (1.0):
# green below 1 (cache reads make the next leg cheaper than a cold early leg), warming
# yellow→orange→red above 1 as cost outgrows the frozen early baseline. Multi-stop so the
# warm side reads yellow/orange instead of the muddy pink a straight white→red lerp gives.
# Anchors are provisional — the red anchor (7×) is model-dependent (200k sessions mostly
# live green→yellow; 1M deep-context sessions reach orange/red); tune the $stops to
# recalibrate. The old fixed 5×/12× token-ratio bands are kept in docs/status-line.md.
function Froz5RGB($ratio) {
    $stops = @(
        @(0.5, $BAND_GREEN),
        @(1.0, @(230, 230, 230)),
        @(2.0, $BAND_YELLOW),
        @(4.0, $BAND_ORANGE),
        @(7.0, $BAND_RED)
    )
    if ($ratio -le $stops[0][0])  { return $stops[0][1] }
    if ($ratio -ge $stops[-1][0]) { return $stops[-1][1] }
    for ($i = 0; $i -lt $stops.Count - 1; $i++) {
        $lo = $stops[$i]; $hi = $stops[$i + 1]
        if ($ratio -le $hi[0]) {
            $t = ($ratio - $lo[0]) / ($hi[0] - $lo[0])
            $a = $lo[1]; $b = $hi[1]
            return @(
                [int][Math]::Round($a[0] + ($b[0] - $a[0]) * $t),
                [int][Math]::Round($a[1] + ($b[1] - $a[1]) * $t),
                [int][Math]::Round($a[2] + ($b[2] - $a[2]) * $t)
            )
        }
    }
    return $stops[-1][1]
}
function BgFroz5($ratio, $text) {
    if ($null -eq $ratio) { return (Dim $text) }
    return (BgTint (Froz5RGB $ratio) $text)
}

$DIM_SEP = Dim ' | '

# Per-session cumulative-token rollups, cached in stats-cache.json. Reading the entire
# jsonl transcript on every status-line refresh would be wasteful (transcripts can hit
# 15+ MB), so we remember the last byte offset we processed and only consume newly
# appended lines on each invocation. Tracked totals: nLegs (one per assistant API call =
# one "leg" — note that a conversational turn can span several legs), sumInputBilled (input +
# cache_read + cache_creation across every assistant entry), sumOutputTokens, and the
# last cumulative cost we saw (used to derive last-leg cost as a delta).
function UpdateSessionRollups($sessionId, $tpath, $currentCost) {
    if (-not $sessionId -or -not $tpath -or -not (Test-Path -LiteralPath $tpath)) { return $null }
    $statsPath = "$ClaudeHome/.claude/stats-cache.json"
    $stats = $null
    if (Test-Path $statsPath) {
        try { $stats = Get-Content $statsPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json } catch {}
    }
    if (-not $stats) { $stats = [pscustomobject]@{} }
    if ($stats.PSObject.Properties.Match('sessionRollups').Count -eq 0) {
        $stats | Add-Member -NotePropertyName 'sessionRollups' -NotePropertyValue ([pscustomobject]@{})
    }
    $sessions = $stats.sessionRollups
    $hadPrior = ($sessions.PSObject.Properties.Match($sessionId).Count -gt 0)
    if ($hadPrior) {
        $r = $sessions.$sessionId
    } else {
        $r = [pscustomobject]@{
            lastByteOffset   = [long]0
            nLegs            = [int]0
            sumInputBilled   = [long]0
            sumOutputTokens  = [long]0
            lastMsgId        = ''
            lastInputBilled  = [int]0
            lastOutputTokens = [int]0
            lastSeenCost     = [double]0
            lastLegCost      = $null
            perLegInputs     = @()
            freshBaselineUsd = $null
        }
    }
    # Migration shim: ensure all required fields exist. Older caches may lack
    # lastMsgId or perLegInputs (the per-leg billable-input series behind the
    # sparkline; it replaced the older frozen perLegCosts cost-delta attribution),
    # use the pre-rename turn-named fields (nAssistantTurns / lastTurnCost — now
    # nLegs / lastLegCost, since each counts one assistant API call = one leg), or
    # lack freshBaselineUsd (the frozen fresh-leg dollar baseline). Adding any
    # missing field resets all aggregates so the next pass re-scans from byte 0
    # and refills them consistently.
    $needsReset = $false
    if ($r.PSObject.Properties.Match('lastMsgId').Count -eq 0) {
        $r | Add-Member -NotePropertyName 'lastMsgId' -NotePropertyValue ''
        $needsReset = $true
    }
    if ($r.PSObject.Properties.Match('perLegInputs').Count -eq 0) {
        $r | Add-Member -NotePropertyName 'perLegInputs' -NotePropertyValue @()
        $needsReset = $true
    }
    if ($r.PSObject.Properties.Match('nLegs').Count -eq 0) {
        $r | Add-Member -NotePropertyName 'nLegs' -NotePropertyValue ([int]0)
        $r.PSObject.Properties.Remove('nAssistantTurns')
        $needsReset = $true
    }
    if ($r.PSObject.Properties.Match('lastLegCost').Count -eq 0) {
        $r | Add-Member -NotePropertyName 'lastLegCost' -NotePropertyValue $null
        $r.PSObject.Properties.Remove('lastTurnCost')
        $needsReset = $true
    }
    if ($r.PSObject.Properties.Match('freshBaselineUsd').Count -eq 0) {
        $r | Add-Member -NotePropertyName 'freshBaselineUsd' -NotePropertyValue $null
        $needsReset = $true
    }
    if ($needsReset) {
        $r.lastByteOffset   = [long]0
        $r.nLegs            = [int]0
        $r.sumInputBilled   = [long]0
        $r.sumOutputTokens  = [long]0
        $r.lastMsgId        = ''
        $r.lastInputBilled  = [int]0
        $r.lastOutputTokens = [int]0
        $r.lastSeenCost     = [double]0
        $r.lastLegCost      = $null
        $r.perLegInputs     = @()
        $r.freshBaselineUsd = $null
    }
    if ($null -eq $r.perLegInputs) { $r.perLegInputs = @() }
    $skipLastLegCost = $needsReset
    $nLegsBefore = [int]$r.nLegs

    $fs = $null
    try {
        $fs = [System.IO.File]::Open($tpath, 'Open', 'Read', 'ReadWrite')
        $totalLen = $fs.Length
        # Transcript shrank → file rotated/rewound → discard prior rollup and reprocess.
        # (Note: /clear starts a NEW session_id + new file, so it's handled by the
        # fresh-rollup path, not here. This guards genuine same-id file rewinds.) Reset
        # freshBaselineUsd too, or post-rewind legs would compare against a stale anchor.
        if ([long]$r.lastByteOffset -gt $totalLen) {
            $r.lastByteOffset = 0; $r.nLegs = 0
            $r.sumInputBilled = 0; $r.sumOutputTokens = 0
            $r.lastInputBilled = 0; $r.lastOutputTokens = 0
            $r.perLegInputs = @(); $r.freshBaselineUsd = $null
        }
        if ([long]$r.lastByteOffset -lt $totalLen) {
            $fs.Seek([long]$r.lastByteOffset, 'Begin') | Out-Null
            $remaining = $totalLen - [long]$r.lastByteOffset
            $buf = New-Object byte[] $remaining
            $null = $fs.Read($buf, 0, $remaining)
            $newText = [System.Text.Encoding]::UTF8.GetString($buf)

            # Only consume complete \n-terminated lines; leave any trailing partial line
            # for next invocation. Byte offsets must advance by UTF-8 byte length, not
            # character count, or multi-byte characters would desync our seek position.
            $lastNl = $newText.LastIndexOf("`n")
            if ($lastNl -ge 0) {
                $processable = $newText.Substring(0, $lastNl + 1)
                $consumedBytes = [System.Text.Encoding]::UTF8.GetByteCount($processable)
                foreach ($line in ($processable -split "`n")) {
                    $line = $line.Trim()
                    if (-not $line) { continue }
                    if ($line -notmatch '"type"\s*:\s*"assistant"') { continue }
                    try {
                        $p = $line | ConvertFrom-Json
                        if ($p.type -ne 'assistant') { continue }
                        # Deduplicate by message.id: a single API call's response often
                        # spans multiple content blocks (text + tool_use), each written
                        # as its own transcript line but sharing the same message.id and
                        # usage block. Count once per unique id. Comparing only against
                        # the *most recent* id is safe because entries for one API call
                        # are always written contiguously.
                        $msgId = $p.message.id
                        if (-not $msgId -or $msgId -eq $r.lastMsgId) { continue }
                        $u = $p.message.usage
                        if (-not $u) { continue }
                        $inp = [int]$u.input_tokens + [int]$u.cache_creation_input_tokens + [int]$u.cache_read_input_tokens
                        $out = [int]$u.output_tokens
                        $r.nLegs            = [int]$r.nLegs + 1
                        $r.sumInputBilled   = [long]$r.sumInputBilled + $inp
                        $r.sumOutputTokens  = [long]$r.sumOutputTokens + $out
                        $r.lastMsgId        = $msgId
                        $r.lastInputBilled  = $inp
                        $r.lastOutputTokens = $out
                        # Store the leg's billable input. Per-leg DOLLAR cost is derived at
                        # read time as input × (total_cost / sumInputBilled) — stable and
                        # always reconciling. We deliberately do NOT attribute cost deltas
                        # per refresh: total_cost lags the transcript, so each catch-up got
                        # dumped onto whatever recent leg was observed, producing escalating
                        # phantom spikes.
                        $r.perLegInputs += $inp
                    } catch {}
                }
                $r.lastByteOffset = [long]$r.lastByteOffset + $consumedBytes
            }
        }
    } catch {}
    finally { if ($fs) { try { $fs.Close() } catch {} } }

    # Last-leg cost = delta of cumulative_cost since previous refresh. Only update when
    # we've genuinely advanced legs (otherwise idle refreshes would zero it out) and
    # when this isn't the first time we've seen the session (lastSeenCost would be 0,
    # making the delta equal full session cost — a bogus "last leg cost" of the whole run).
    # Also skip after a migration-driven reset: lastSeenCost was wiped to 0 so the
    # delta would equal full session cost.
    if ($hadPrior -and -not $skipLastLegCost -and [int]$r.nLegs -gt $nLegsBefore) {
        $delta = [double]$currentCost - [double]$r.lastSeenCost
        if ($delta -gt 0) { $r.lastLegCost = $delta }
    }
    $r.lastSeenCost = [double]$currentCost

    # Fresh-leg dollar baseline: the actual mean cost of the first ≤5 legs, snapshotted
    # once and then FROZEN. Per-leg dollars = billable input × blended rate
    # (total_cost / sumInputBilled); we recompute the baseline only while fewer than 5
    # legs have been seen (it evolves at near-early rates as those legs arrive) and lock
    # it the moment the 5th leg appears — context is still small then, so the blended
    # rate ≈ the true early-leg rate. Once frozen it never moves, so the displayed
    # "(fresh)" dollar value stays put while later legs (which benefit from cache reads)
    # can genuinely read cheaper or pricier against it. Caveat: if the status line first
    # observes an already-long session (fresh/migrated cache → bulk catch-up scan), nLegs
    # jumps past 5 in one pass and the snapshot is taken at the current low rate, under-
    # pricing fresh for that session only — we have no historical per-leg cost to do
    # better. Sessions observed from launch (the normal case) capture it correctly.
    if (($null -eq $r.freshBaselineUsd) -or ([int]$r.nLegs -lt 5)) {
        if ([long]$r.sumInputBilled -gt 0 -and [double]$currentCost -gt 0 -and $r.perLegInputs.Count -ge 1) {
            $rate   = [double]$currentCost / [double]$r.sumInputBilled
            $bn     = [Math]::Min(5, $r.perLegInputs.Count)
            $sumTok = 0.0; for ($i = 0; $i -lt $bn; $i++) { $sumTok += [double]$r.perLegInputs[$i] }
            $r.freshBaselineUsd = $rate * ($sumTok / $bn)
        }
    }

    if ($hadPrior) {
        $sessions.$sessionId = $r
    } else {
        $sessions | Add-Member -NotePropertyName $sessionId -NotePropertyValue $r
    }

    try {
        $stats | ConvertTo-Json -Depth 10 | Out-File -FilePath $statsPath -Encoding utf8 -Force
    } catch {}

    return $r
}

# === Cluster 1: model + flags ===
$model    = if ($d.model.display_name) { $d.model.display_name } else { 'unknown' }
$version  = $d.version
$effort   = if ($d.effort.level) { $d.effort.level } else { '?' }
$style    = if ($d.output_style.name) { $d.output_style.name } else { 'default' }
$fast     = $d.fast_mode
$thinking = $d.thinking.enabled

$line1Parts = @()
$modelLabel = if ($version) { (Bold $model) + (Dim " v$version") } else { Bold $model }
$line1Parts += $modelLabel
$line1Parts += (Dim 'effort:') + (ColorEffort $effort)
if ($null -ne $fast) {
    $val = if ($fast) { Magenta 'on' } else { 'off' }
    $line1Parts += (Dim 'fast:') + $val
}
if ($null -ne $thinking) {
    $val = if ($thinking) { 'on' } else { BrightCyan 'off' }
    $line1Parts += (Dim 'think:') + $val
}
if ($style -and $style -ne 'default') { $line1Parts += (Dim 'style:') + $style }
$line1 = $line1Parts -join $DIM_SEP

# === Cluster 2: context window ===
$ctxPct   = $d.context_window.used_percentage
$ctxUsed  = $d.context_window.total_input_tokens
$ctxSize  = $d.context_window.context_window_size
$ctxParts = @()
if ($null -ne $ctxUsed -and $null -ne $ctxSize) {
    $ctxParts += (Dim 'ctx ') + (ColorByTokenCount $ctxUsed (FmtNum $ctxUsed)) + (Dim ('/' + (FmtNum $ctxSize)))
}
if ($null -ne $ctxPct) {
    # Fill-% chip (window-aware quality axis). The token count above keeps its
    # absolute foreground coloring — the two run side by side so we can compare.
    $ctxParts += (BgFill $ctxPct (FmtPct $ctxPct))
}
if ($null -ne $ctxUsed -and $null -ne $ctxSize) {
    $compactAt = [int]($ctxSize * 0.95)
    $remaining = $compactAt - $ctxUsed
    if ($remaining -gt 0) {
        $colored = ColorLow $remaining (FmtNum $remaining) 200000 50000
        $ctxParts += (Dim 'to-compact ') + $colored
    } else {
        $ctxParts += (RedBold 'to-compact NOW')
    }
}
$line2 = if ($ctxParts.Count -gt 0) { $ctxParts -join $DIM_SEP } else { $null }

# === Cluster 3: cost density (five numbers, three groups) ===
# Designed to surface context-driven cost escalation. The dominant economic fact:
# every API call ("leg" — a conversational turn often spans multiple legs when
# tools are used) re-sends the entire conversation as input, so per-leg cost
# grows linearly with current context size, and total session cost grows
# quadratically with session length. The display:
#   - $X.XX                          absolute cumulative session spend.
#   - next $X.XX =R.Rx $X.XX (fresh)  forecast of the next leg vs the FROZEN "fresh leg"
#                                     baseline — the actual mean dollar cost of the first
#                                     up-to-5 legs, snapshotted once early and never moved.
#                                     Forecast = (total_cost / sumInputBilled) × current_ctx_tokens.
#                                     Ratio = forecast / fresh = a TRUE dollar-escalation
#                                     signal: reads below 1 when cache reads make the next
#                                     leg cheaper than a cold early leg, and climbs past 1 as
#                                     context cost outgrows the early anchor. Rendered as a
#                                     muted-tint chip via a diverging gradient (see Froz5RGB):
#                                     green below 1, white at parity (1.0), warming to red as it
#                                     climbs. Gradient anchors are provisional, pending real data.
#   - last leg $X.XX                 most recent leg's cost (spike detector).
$cacheParts = @()
$tpath = $d.transcript_path
$sessionId = $d.session_id
$costUsd = $d.cost.total_cost_usd
$ctxTok = $d.context_window.total_input_tokens

if ($null -ne $costUsd) {
    $cacheParts += (ColorCost $costUsd ('$' + ('{0:N2}' -f $costUsd)))
}
$rollup = $null
if ($sessionId -and $tpath -and $null -ne $costUsd) {
    $rollup = UpdateSessionRollups $sessionId $tpath $costUsd
}
# Per-leg dollar costs, derived from stored per-leg billable inputs at the session
# blended rate ($/token). Stable, no zeros, always sums to total_cost. Used by both
# the froz5 fresh baseline (cluster 3) and the sparkline (cluster 5).
$perLegCostArr = @()
if ($rollup -and $null -ne $rollup.perLegInputs -and [long]$rollup.sumInputBilled -gt 0 -and $costUsd -gt 0) {
    $rate = [double]$costUsd / [double]$rollup.sumInputBilled
    $perLegCostArr = @($rollup.perLegInputs | ForEach-Object { [double]$rate * [double]$_ })
}
if ($rollup -and $costUsd -gt 0 -and [int]$rollup.nLegs -gt 0 `
        -and [long]$rollup.sumInputBilled -gt 0 -and $null -ne $ctxTok -and $ctxTok -gt 0) {
    $blendedInputRate = [double]$costUsd / [double]$rollup.sumInputBilled
    $forecast         = $blendedInputRate * [double]$ctxTok
    # "Fresh leg" baseline: the actual mean dollar cost of the first ≤5 legs, snapshotted
    # once early and FROZEN in the rollup (see UpdateSessionRollups → freshBaselineUsd).
    # Because it never moves, the displayed "(fresh)" value stays put, and
    # ratio = forecast ÷ fresh is a TRUE dollar-escalation signal: it reads BELOW 1 when
    # cache reads make the next leg cheaper than a cold early leg, and climbs past 1 as
    # context cost outgrows the early anchor. (The old all-legs average collapsed toward
    # 1.0 at high-context plateaus; a frozen anchor can't chase the numerator, so the
    # signal stays honest.) The chip is coloured by a diverging gradient (BgFroz5/Froz5RGB):
    # green <1, white at parity, warming to red as it climbs; gradient anchors provisional.
    $freshBaseline = if ($null -ne $rollup.freshBaselineUsd) { [double]$rollup.freshBaselineUsd } else { $null }
    $ratio       = if ($freshBaseline -and $freshBaseline -gt 0) { $forecast / $freshBaseline } else { $null }
    $forecastStr = '$' + ('{0:N2}' -f $forecast)
    $part = (Dim 'next leg ') + (ColorLegCell $forecast $forecastStr)
    if ($null -ne $ratio) {
        $ratioStr = ('{0:N1}' -f $ratio) + 'x'
        $freshStr = '$' + ('{0:N2}' -f $freshBaseline)
        $part += (Dim ' =') + (BgFroz5 $ratio $ratioStr) + (Dim "$freshStr (fresh)")
    }
    $cacheParts += $part
}
if ($rollup -and $null -ne $rollup.lastLegCost -and [double]$rollup.lastLegCost -gt 0) {
    $ltc    = [double]$rollup.lastLegCost
    $ltcStr = '$' + ('{0:N2}' -f $ltc)
    $cacheParts += (Dim 'last = ') + (ColorLegCell $ltc $ltcStr)
}

# Full-turn TPS anchored to the latest user-message timestamp.
# Reads the last 2 MB of the transcript. If that tail doesn't contain a `type:user`
# entry AND the file is larger than the tail, surface a red `tail!` warning so we
# know the metric is missing for a real reason (not just a quiet turn).
# The rendered TPS string is stashed in $tpsRendered and appended in Cluster 5
# (session line) — TPS belongs with the other session-time stats, not with cost.
$tailBytes = 2097152
$tailWarning = $false
$tpsRendered = $null
if ($tpath -and (Test-Path -LiteralPath $tpath)) {
    try {
        $fs = [System.IO.File]::Open($tpath, 'Open', 'Read', 'ReadWrite')
        $len = $fs.Length
        $tailSize = [Math]::Min($tailBytes, $len)
        $fs.Seek(-$tailSize, 'End') | Out-Null
        $bytes = New-Object byte[] $tailSize
        $null = $fs.Read($bytes, 0, $tailSize)
        $fs.Close()
        $tail = [System.Text.Encoding]::UTF8.GetString($bytes)
        $lines = $tail -split "`n"
        # If we didn't read the whole file, drop the first (likely partial) line.
        $startIdx = if ($len -gt $tailSize) { 1 } else { 0 }

        $latestUserTs = $null
        $latestUserIdx = -1
        for ($i = $lines.Count - 1; $i -ge $startIdx; $i--) {
            $line = $lines[$i].Trim()
            if (-not $line) { continue }
            # Quick regex pre-filter: skip lines that clearly aren't an actual typed user prompt.
            # Real typed prompts have type:"user", string content, no isMeta, no origin field.
            # Filter out:
            #   - tool results (array content with tool_result objects)
            #   - meta entries (isMeta:true — slash-command caveats etc.)
            #   - system-injected entries (have an "origin" field, e.g. task-notification)
            if ($line -notmatch '"type"\s*:\s*"user"') { continue }
            if ($line -notmatch '"timestamp"')         { continue }
            if ($line -match    '"tool_result"')       { continue }
            if ($line -match    '"isMeta"\s*:\s*true') { continue }
            if ($line -match    '"origin"\s*:\s*\{')   { continue }
            # Use LastIndexOf to find the TOP-LEVEL "timestamp" field. Claude Code serializes
            # top-level entry fields after nested message content, so the last "timestamp"
            # occurrence is the entry's own timestamp. Earlier matches (e.g., for image-inlined
            # prompts, ~400KB+ lines) can be inside nested image source metadata and produce
            # bogus times that break duration math.
            $lastTsIdx = $line.LastIndexOf('"timestamp"')
            if ($lastTsIdx -lt 0) { continue }
            $tsSection = $line.Substring($lastTsIdx, [Math]::Min(120, $line.Length - $lastTsIdx))
            if ($tsSection -match '"timestamp"\s*:\s*"([^"]+)"') {
                try {
                    $latestUserTs = [DateTime]::Parse($matches[1]).ToUniversalTime()
                    $latestUserIdx = $i
                    break
                } catch {}
            }
        }

        if (-not $latestUserTs -and $len -gt $tailSize) {
            $tailWarning = $true
        }

        if ($latestUserTs) {
            $outputSum = 0
            for ($i = $latestUserIdx + 1; $i -lt $lines.Count; $i++) {
                $line = $lines[$i].Trim()
                if (-not $line) { continue }
                try {
                    $parsed = $line | ConvertFrom-Json
                    if ($parsed.type -eq 'assistant' -and $parsed.message -and $parsed.message.usage -and $parsed.message.usage.output_tokens) {
                        $outputSum += [int]$parsed.message.usage.output_tokens
                    }
                } catch {}
            }
            # T_end is the transcript file's last-write time. Claude Code uses API-call-start
            # time for assistant entry timestamps, which equals the user prompt time for fast
            # turns — making timestamp-based duration math broken. mtime advances on every
            # write, so it reflects actual wall-clock progress through the turn.
            $latestTs = (Get-Item -LiteralPath $tpath).LastWriteTimeUtc
            if ($latestTs -lt $latestUserTs) { $latestTs = $latestUserTs }

            if ($outputSum -gt 0) {
                $duration = ($latestTs - $latestUserTs).TotalSeconds
                if ($duration -lt 0.001) { $duration = 0.001 }
                $tps = $outputSum / $duration
                $tpsStr = '{0:N0}t/s' -f $tps
                $coloredTps = ColorLow $tps $tpsStr 30 15
                $tpsRendered = (Dim 'turn ') + (FmtDuration ([int]$duration)) + (Dim ' @ ') + $coloredTps
            }
        }
    } catch {}
}

$line3 = if ($cacheParts.Count -gt 0) { $cacheParts -join $DIM_SEP } else { $null }

# === Cluster 5: per-leg cost sparkline (8 buckets) ===
# Extends cluster 4's cost-escalation theme into a sparkline view: the session's
# legs (oldest → newest, left → right) are aggregated into up to 8 buckets and
# the per-bucket average $/leg is rendered with a green→yellow→red gradient.
# Position 8 (rightmost) is anchored to the most recent leg(s): when N ≤ 8,
# each leg gets its own cell and empty slots pad the LEFT; when N > 8, the
# rightmost `rem = N mod 8` buckets hold ceil(N/8) legs (the newest) and the
# leftmost 8 − rem buckets hold floor(N/8) (older chunks). Any size mismatch
# from N % 8 ≠ 0 stays at one end of the row — position 8 always reflects the
# newest legs, and earlier positions hold progressively older chunks of work.
# Each bucket's average $/leg renders as a value chip on a muted tint background
# (the gradient hue on a 30% tint of itself — the "V2" style chosen 2026-05-29).
$legsLine = $null
if ($perLegCostArr.Count -gt 0) {
    $maxBuckets = 8
    $costs = @($perLegCostArr)
    $n = $costs.Count

    $bucketAvgs = @()
    if ($n -le $maxBuckets) {
        foreach ($c in $costs) { $bucketAvgs += $c }
    } else {
        $rem = $n % $maxBuckets
        $bigSize   = [int][Math]::Ceiling($n / [double]$maxBuckets)
        $smallSize = [int][Math]::Floor($n / [double]$maxBuckets)
        $idx = 0
        for ($b = 0; $b -lt $maxBuckets; $b++) {
            $size = if ($b -ge ($maxBuckets - $rem)) { $bigSize } else { $smallSize }
            $sum = 0.0
            for ($i = 0; $i -lt $size; $i++) { $sum += $costs[$idx]; $idx++ }
            $bucketAvgs += ($sum / $size)
        }
    }
    # Pad LEFT with $null so the newest bucket stays rightmost.
    $missing = $maxBuckets - $bucketAvgs.Count
    if ($missing -gt 0) {
        $pad = @(); for ($i = 0; $i -lt $missing; $i++) { $pad += $null }
        $bucketAvgs = $pad + $bucketAvgs
    }

    $cells = foreach ($c in $bucketAvgs) {
        if ($null -eq $c) { Dim ' ····· ' } else { BgTint (LegRGB $c) ('$' + ('{0:N2}' -f $c)) }
    }
    $legsLine = (Dim 'legs: ') + ($cells -join '') + (Dim " ($n)")
}

# === Cluster 4: quota ===
# Hidden when both 5h and 7d quotas are below 50% — saves a line when there's nothing worth watching.
$qParts = @()
$rl5 = $d.rate_limits.five_hour
$rl7 = $d.rate_limits.seven_day
$p5 = if ($null -ne $rl5.used_percentage) { [double]$rl5.used_percentage } else { 0 }
$p7 = if ($null -ne $rl7.used_percentage) { [double]$rl7.used_percentage } else { 0 }
if (($p5 -ge 50) -or ($p7 -ge 50)) {
    $now = [int][double]::Parse((Get-Date -UFormat %s))
    if ($null -ne $rl5.used_percentage) {
        $colored = ColorHigh $rl5.used_percentage (FmtPct $rl5.used_percentage) 70 90
        $p = (Dim '5h:') + $colored
        if ($rl5.resets_at) {
            $p += (Dim (' (resets ' + (FmtDuration ($rl5.resets_at - $now)) + ')'))
        }
        $qParts += $p
    }
    if ($null -ne $rl7.used_percentage) {
        $colored = ColorHigh $rl7.used_percentage (FmtPct $rl7.used_percentage) 70 90
        $p = (Dim '7d:') + $colored
        if ($rl7.resets_at) {
            $p += (Dim (' (resets ' + (FmtDuration ($rl7.resets_at - $now)) + ')'))
        }
        $qParts += $p
    }
    $statsPath = "$ClaudeHome/.claude/stats-cache.json"
    if (Test-Path $statsPath) {
        try {
            $stats = Get-Content $statsPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            $today = (Get-Date).ToString('yyyy-MM-dd')
            $todayEntry = $stats.dailyModelTokens | Where-Object { $_.date -eq $today }
            if ($todayEntry) {
                $sumToday = 0
                $todayEntry.tokensByModel.PSObject.Properties | ForEach-Object { $sumToday += [int]$_.Value }
                if ($sumToday -gt 0) { $qParts += (Dim ('today:' + (FmtNum $sumToday))) }
            }
        } catch {}
    }
}
$line4 = if ($qParts.Count -gt 0) { $qParts -join $DIM_SEP } else { $null }

# === Cluster 5: session ===
# Absolute spend ($X.XX) lives in cluster 3 alongside the cost-density metrics;
# this cluster is purely session activity (time alive vs api, lines, turn TPS).
$costParts = @()
$aliveSec = $null
if ($tpath -and (Test-Path $tpath)) {
    try {
        $ctime = (Get-Item $tpath).CreationTime
        $aliveSec = [int](((Get-Date) - $ctime).TotalSeconds)
    } catch {}
}
$apiSec = if ($d.cost.total_api_duration_ms) { [int]($d.cost.total_api_duration_ms / 1000) } else { $null }
if ($null -ne $aliveSec -and $null -ne $apiSec) {
    $costParts += (Dim ((FmtDuration $aliveSec) + ' alive / ' + (FmtDuration $apiSec) + ' api'))
} elseif ($null -ne $aliveSec) {
    $costParts += (Dim ((FmtDuration $aliveSec) + ' alive'))
} elseif ($null -ne $apiSec) {
    $costParts += (Dim ((FmtDuration $apiSec) + ' api'))
}
if ($null -ne $d.cost.total_lines_added -or $null -ne $d.cost.total_lines_removed) {
    $costParts += (Dim ('+{0}/-{1} lines' -f $d.cost.total_lines_added, $d.cost.total_lines_removed))
}
if ($tpsRendered) { $costParts += $tpsRendered }
if ($tailWarning) { $costParts += (RedBold 'tail!') }
$line5 = if ($costParts.Count -gt 0) { (Dim 'session: ') + ($costParts -join $DIM_SEP) } else { $null }

# === Cluster 6: git ===
$cwd = if ($d.workspace.current_dir) { $d.workspace.current_dir } else { $d.cwd }
$gitLine = $null
if ($cwd) {
    $porcelain = & git -C "$cwd" --no-optional-locks status --porcelain=v2 --branch 2>$null
    if ($porcelain) {
        $branch = '?'
        $ahead = 0; $behind = 0
        $dirty = $false; $hasUpstream = $false; $detached = $false
        foreach ($pl in $porcelain) {
            if ($pl -match '^# branch\.head (.+)$') {
                $branch = $matches[1]
                if ($branch -eq '(detached)') { $detached = $true }
            }
            elseif ($pl -match '^# branch\.upstream ') { $hasUpstream = $true }
            elseif ($pl -match '^# branch\.ab \+(\d+) -(\d+)$') {
                $ahead = [int]$matches[1]; $behind = [int]$matches[2]
            }
            elseif ($pl -match '^[12?u!]') { $dirty = $true }
        }
        if ($detached)         { $sync = Red '…' }
        elseif (-not $hasUpstream) { $sync = Yellow '!' }
        elseif ($ahead -gt 0 -and $behind -gt 0) { $sync = RedBold "⇅↑$ahead↓$behind" }
        elseif ($ahead -gt 0)  { $sync = Yellow "↑$ahead" }
        elseif ($behind -gt 0) { $sync = Yellow "↓$behind" }
        else                   { $sync = Green '✓' }
        if ($dirty) { $sync = (Yellow '*') + $sync }

        $remote = ''
        $remoteUrl = & git -C "$cwd" --no-optional-locks remote get-url origin 2>$null
        if ($remoteUrl) {
            $u = $remoteUrl -replace '\.git$', ''
            if ($u -match '[:/]([^:/]+)/([^:/]+)$') { $remote = "$($matches[1])/$($matches[2])" }
        }
        $repo = if ($remote) { "$remote@$branch" } else { $branch }
        $gitLine = (Cyan 'git: ') + $repo + ' ' + $sync
    }
}

# === Sidecar: persist the computed snapshot for /handover-check ===
# The status line is the renderer of a state object; /handover-check is its
# explainer. We already write stats-cache every refresh, so dumping the finished
# numbers here is ~free, and lets the command read ground truth instead of
# re-deriving it. Wrapped so a failure here can never break the line.
try {
    $absState = if ($null -eq $ctxUsed) { $null }
        elseif ($ctxUsed -lt 32000)  { 'pristine' }
        elseif ($ctxUsed -lt 128000) { 'green' }
        elseif ($ctxUsed -lt 256000) { 'yellow' }
        elseif ($ctxUsed -lt 500000) { 'orange' }
        else { 'red' }
    $fillState = if ($null -eq $ctxPct) { $null }
        elseif ($ctxPct -lt 50) { 'green' }
        elseif ($ctxPct -lt 70) { 'yellow' }
        elseif ($ctxPct -lt 85) { 'orange' }
        else { 'red' }
    $froz5State = if ($null -eq $ratio) { $null }
        elseif ($ratio -lt 5)  { 'green' }
        elseif ($ratio -lt 12) { 'yellow' }
        else { 'red' }
    $toCompactTok = if ($null -ne $ctxUsed -and $null -ne $ctxSize) { [int]($ctxSize * 0.95) - [int]$ctxUsed } else { $null }
    $activityPct  = if ($aliveSec -and [int]$aliveSec -gt 0 -and $null -ne $apiSec) { [Math]::Round(100.0 * $apiSec / $aliveSec, 1) } else { $null }
    $snapshot = [ordered]@{
        schema       = 1
        sessionId    = $sessionId
        model        = $model
        windowSize   = $ctxSize
        effort       = $effort
        ctxTokens    = $ctxUsed
        fillPct      = $ctxPct
        ctxAbsState  = $absState
        fillState    = $fillState
        toCompact    = $toCompactTok
        costUsd      = $costUsd
        nextLegUsd   = $forecast
        froz5Ratio   = $ratio
        froz5State   = $froz5State
        freshLegUsd  = $freshBaseline
        lastLegUsd   = $(if ($rollup) { $rollup.lastLegCost } else { $null })
        nLegs        = $(if ($rollup) { [int]$rollup.nLegs } else { $null })
        legCosts     = @($perLegCostArr | ForEach-Object { [Math]::Round([double]$_, 4) })
        aliveSec     = $aliveSec
        apiSec       = $apiSec
        activityPct  = $activityPct
        linesAdded   = $d.cost.total_lines_added
        linesRemoved = $d.cost.total_lines_removed
        tps          = $(if ($null -ne $tps) { [int]$tps } else { $null })
        gitRepo      = $repo
    }
    $snapshot | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath "$ClaudeHome/.claude/statusline-last.json" -Encoding utf8 -Force
} catch {}

$out = @()
$out += $line1
if ($line2)    { $out += $line2 }
if ($line4)    { $out += $line4 }
if ($line3)    { $out += $line3 }
if ($legsLine) { $out += $legsLine }
if ($line5)    { $out += $line5 }
if ($gitLine)  { $out += $gitLine }

[Console]::Out.Write(($out -join "`n"))
