$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$input_json = [Console]::In.ReadToEnd()
$d = $input_json | ConvertFrom-Json

# Status-line software version (OUR version, not Claude Code's). Rendered as a
# trailing `bsl<ver>` badge on line 1 and logged per-row in the calibration samples
# so every reading is anchored to the threshold regime that produced it. Bump on
# any change that shifts what the numbers mean (froz5 anchors, quality bands, cost
# math, cold-cache logic). See docs/froz5-calibration-samples.md.
$SlVersion = '4.1.0.0'

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
# Like FmtDuration but minute-granularity with zero sub-units suppressed — for the quota
# line's runway/blackout estimates, where seconds are noise: "27m", "1h12m", "21h", "2d15h", "2d".
function FmtDurShort($sec) {
    if ($null -eq $sec) { return '--' }
    $sec = [int][Math]::Floor([double]$sec)
    if ($sec -lt 0) { $sec = 0 }
    if ($sec -ge 86400) {
        $d = [int][Math]::Floor($sec / 86400); $h = [int][Math]::Floor(($sec % 86400) / 3600)
        return $(if ($h -eq 0) { "${d}d" } else { "${d}d${h}h" })
    }
    if ($sec -ge 3600) {
        $h = [int][Math]::Floor($sec / 3600); $m = [int][Math]::Floor(($sec % 3600) / 60)
        return $(if ($m -eq 0) { "${h}h" } else { "${h}h${m}m" })
    }
    return ("{0}m" -f [int][Math]::Round($sec / 60.0))
}
function Median($arr) {
    $vals = @($arr | Where-Object { $null -ne $_ } | Sort-Object)
    $n = $vals.Count
    if ($n -eq 0) { return 0.0 }
    $mid = [int][Math]::Floor($n / 2)
    if ($n % 2 -eq 1) { return [double]$vals[$mid] }
    return ([double]$vals[$mid - 1] + [double]$vals[$mid]) / 2.0
}

# Composition-weighted cost accounting (Option C, see docs/status-line-redesign.md).
# A leg's token types don't cost the same per token, so summing them into one flat
# count makes the derived $/token rate drift down over a session as cheap cache-read
# tokens dominate. Instead we weight each token type by Anthropic's public list-price
# RATIO (relative to base input price — ratios survive the Max-plan ~10x cost scaling),
# yielding cost "units". The derived base ($/unit = total_cost / Σunits) is then flat,
# and cache-heavy legs price correctly (cheap) instead of reading as spikes.
$M_INPUT       = 1.0     # base input price
$M_CACHE_WRITE = 1.25    # 5-min ephemeral cache creation (Claude Code default)
$M_CACHE_READ  = 0.10    # cache hit
$M_OUTPUT      = 5.0     # output : input for Opus/Sonnet/Haiku 4.x ($15/$75, $3/$15, $1/$5)

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
function ColdBlue($t)   { "${ESC}[38;5;33m$t${ESC}[0m" }   # cold-cache marker — readable deep blue (256-color 33)
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
# Anchors RECALIBRATED 2026-06-01 from real data (docs/froz5-calibration-samples.md): the
# ratio asymptotes ~4× at the 1M wall (0.7@124k → 1.4@252k → 2.3@401k → 2.9@555k → 3.9@800k),
# so the old orange@4/red@7 never fired. Warm half pulled in to white@1 / yellow@1.8 /
# orange@2.8 / red@3.8 so a genuinely-extreme deep session actually renders red.
# The old fixed 5×/12× token-ratio bands are kept in docs/status-line.md.
function Froz5RGB($ratio) {
    $stops = @(
        @(0.5, $BAND_GREEN),
        @(1.0, @(230, 230, 230)),
        @(1.8, $BAND_YELLOW),
        @(2.8, $BAND_ORANGE),
        @(3.8, $BAND_RED)
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
# one "leg" — note that a conversational turn can span several legs), sumUnits
# (composition-weighted cost units summed across every assistant entry — see the
# $M_* weights above), sumOutputTokens, the per-leg unit series (perLegUnits and
# perLegOwnUnits, the latter excluding the cache-read context re-read), and the last
# cumulative cost we saw (used to derive last-leg cost as a delta).
function UpdateSessionRollups($sessionId, $tpath, $currentCost, $projRoot) {
    if (-not $sessionId -or -not $tpath -or -not (Test-Path -LiteralPath $tpath)) { return $null }
    # Per-session rollup file: each session is the SOLE writer of its own file. This eliminates
    # the read-modify-write clobber race the single shared stats-cache.json suffered — every open
    # session rewriting one file every refreshInterval was last-write-wins, which wiped costBaseline
    # (→ inflated $), reset the cold anchor, and dropped lastLegCost. Prefer a project-local dir
    # (co-located with the sidecar, same $projRoot/$cwd source); fall back to the global home when no
    # project dir is resolvable (still per-session → still race-free). The file holds the bare rollup.
    $statsDir = if ($projRoot) { Join-Path $projRoot '.claude\statusline-stats' } else { Join-Path $ClaudeHome '.claude\statusline-stats' }
    try { if (-not (Test-Path -LiteralPath $statsDir)) { New-Item -ItemType Directory -Force -Path $statsDir | Out-Null } } catch {}
    $statsPath = Join-Path $statsDir ($sessionId + '.json')
    $r = $null
    if (Test-Path -LiteralPath $statsPath) {
        try { $r = Get-Content $statsPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json } catch {}
    }
    $hadPrior = ($null -ne $r)
    if (-not $hadPrior) {
        $r = [pscustomobject]@{
            lastByteOffset   = [long]0
            nLegs            = [int]0
            sumUnits         = [double]0
            sumOutputTokens  = [long]0
            lastMsgId        = ''
            lastInputBilled  = [int]0
            lastOutputTokens = [int]0
            lastSeenCost     = [double]0
            lastLegCost      = $null
            perLegUnits      = @()
            perLegOwnUnits   = @()
            costBaseline     = $null   # genuinely-new session: captured on first leg (see ~line 371)
            lastLegTs        = $null   # epoch sec of the most recent leg (cold-cache gap detector + idle countdown anchor)
            nColdLegs        = [int]0     # legs that hit a cold cache re-create after an idle gap
            coldWastedUnits  = [double]0  # avoidable cost units burned on cold re-caches (cw × (1.25-0.10))
            lastColdLegIdx   = [int]0     # nLegs index of the most recent cold leg (recency: surface a fresh tax)
        }
    }
    # Migration shim (Option C schema). If ANY required field is absent — an older
    # cache predating composition-weighting (it has perLegInputs/sumInputBilled/
    # freshBaselineUsd instead of perLegUnits/sumUnits/perLegOwnUnits), or the
    # pre-rename turn-named fields (nAssistantTurns/lastTurnCost) — we discard the
    # whole rollup and rebuild it fresh, forcing a one-time re-scan from byte 0. The
    # transcript's per-leg `usage` block retains the full token breakdown permanently,
    # so the re-scan recomputes units/ownUnits exactly. Rebuilding as a brand-new
    # object (rather than patching member-by-member) also drops any stale old-named
    # properties so they don't linger in the serialized JSON.
    # NB: the cold-cache fields (lastLegTs/nColdLegs/coldWastedUnits) are deliberately NOT in
    # $requiredFields — they're additive and get patched in below WITHOUT a destructive reset.
    # Putting them here would force a full reset+rescan on every existing rollup that lacks them,
    # which (combined with the shared stats-cache.json being rewritten by concurrent sessions every
    # refreshInterval) thrashed: it wiped costBaseline → inflated every $ figure, reset the cold
    # countdown anchor, and dropped lastLegCost. Only genuinely-incompatible OLD schemas reset here.
    $requiredFields = @('lastByteOffset','nLegs','sumUnits','sumOutputTokens',
        'lastMsgId','lastInputBilled','lastOutputTokens','lastSeenCost',
        'lastLegCost','perLegUnits','perLegOwnUnits','costBaseline')
    $needsReset = $false
    foreach ($f in $requiredFields) {
        if ($r.PSObject.Properties.Match($f).Count -eq 0) { $needsReset = $true; break }
    }
    # Preserve a legitimately-captured costBaseline across a genuine reset (it means the same thing
    # under any schema — the /clear carryover to exclude). Losing it re-includes the carryover and
    # inflates base. $null if the old schema never had it.
    $priorBaseline = if ($r.PSObject.Properties.Match('costBaseline').Count -gt 0) { $r.costBaseline } else { $null }
    if ($needsReset) {
        $r = [pscustomobject]@{
            lastByteOffset   = [long]0
            nLegs            = [int]0
            sumUnits         = [double]0
            sumOutputTokens  = [long]0
            lastMsgId        = ''
            lastInputBilled  = [int]0
            lastOutputTokens = [int]0
            lastSeenCost     = [double]0
            lastLegCost      = $null
            perLegUnits      = @()
            perLegOwnUnits   = @()
            costBaseline     = $(if ($null -ne $priorBaseline) { $priorBaseline } else { 0 })  # preserve carryover-exclusion across reset; 0 only if the old schema never captured one
            lastLegTs        = $null
            nColdLegs        = [int]0
            coldWastedUnits  = [double]0
            lastColdLegIdx   = [int]0
        }
    }
    if ($null -eq $r.perLegUnits)    { $r.perLegUnits = @() }
    if ($null -eq $r.perLegOwnUnits) { $r.perLegOwnUnits = @() }
    # Patch in additive cold-cache fields if an existing (non-reset) rollup predates them — no reset,
    # so costBaseline and all history are preserved.
    if ($r.PSObject.Properties.Match('lastLegTs').Count -eq 0)       { $r | Add-Member -NotePropertyName lastLegTs -NotePropertyValue $null }
    if ($r.PSObject.Properties.Match('nColdLegs').Count -eq 0)       { $r | Add-Member -NotePropertyName nColdLegs -NotePropertyValue ([int]0) }
    if ($r.PSObject.Properties.Match('coldWastedUnits').Count -eq 0) { $r | Add-Member -NotePropertyName coldWastedUnits -NotePropertyValue ([double]0) }
    if ($r.PSObject.Properties.Match('lastColdLegIdx').Count -eq 0)  { $r | Add-Member -NotePropertyName lastColdLegIdx -NotePropertyValue ([int]0) }
    $skipLastLegCost = $needsReset
    $nLegsBefore = [int]$r.nLegs

    $fs = $null
    try {
        $fs = [System.IO.File]::Open($tpath, 'Open', 'Read', 'ReadWrite')
        $totalLen = $fs.Length
        # Transcript shrank → file rotated/rewound → discard prior rollup and reprocess.
        # (Note: /clear starts a NEW session_id + new file, so it's handled by the
        # fresh-rollup path, not here. This guards genuine same-id file rewinds.)
        if ([long]$r.lastByteOffset -gt $totalLen) {
            $r.lastByteOffset = 0; $r.nLegs = 0
            $r.sumUnits = 0; $r.sumOutputTokens = 0
            $r.lastInputBilled = 0; $r.lastOutputTokens = 0
            $r.perLegUnits = @(); $r.perLegOwnUnits = @()
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
                        $inTok  = [int]$u.input_tokens
                        $cwTok  = [int]$u.cache_creation_input_tokens
                        $crTok  = [int]$u.cache_read_input_tokens
                        $outTok = [int]$u.output_tokens
                        # Composition-weighted cost units (Option C): weight each token type
                        # by its public list-price ratio so the derived $/unit base is flat
                        # over the session. `units` = the leg's full cost; `ownUnits` = units
                        # minus the cache-read term (the cost of re-reading prior context),
                        # i.e. the leg's "own work" — what the forecast's trailing median uses.
                        $units    = $inTok * $M_INPUT + $cwTok * $M_CACHE_WRITE + $crTok * $M_CACHE_READ + $outTok * $M_OUTPUT
                        $ownUnits = $inTok * $M_INPUT + $cwTok * $M_CACHE_WRITE + $outTok * $M_OUTPUT
                        $r.nLegs            = [int]$r.nLegs + 1
                        $r.sumUnits         = [double]$r.sumUnits + $units
                        $r.sumOutputTokens  = [long]$r.sumOutputTokens + $outTok
                        $r.lastMsgId        = $msgId
                        $r.lastInputBilled  = $inTok + $cwTok + $crTok
                        $r.lastOutputTokens = $outTok
                        # Store per-leg units. Per-leg DOLLARS are derived at read time as
                        # units × base (= total_cost / sumUnits) — stable, no drift, always
                        # reconciling to total_cost. We deliberately do NOT attribute cost
                        # deltas per refresh: total_cost lags the transcript, so each catch-up
                        # got dumped onto whatever recent leg was observed → phantom spikes.
                        $r.perLegUnits    += $units
                        $r.perLegOwnUnits += $ownUnits
                        # Cold re-cache detection. The first leg after an idle gap longer than the
                        # ~5-min ephemeral-cache TTL re-creates the WHOLE context at cache_write (1.25×)
                        # instead of cache_read (0.10×). Signature: a big cache_creation with almost no
                        # cache_read, preceded by a >5-min gap (the gap rules out a legit big paste — that
                        # keeps the prior context warm, so cache_read stays substantial). Avoidable waste =
                        # cw × (write − read) units. lastLegTs feeds the next leg's gap.
                        # Parse the leg's UTC timestamp to epoch seconds. ConvertFrom-Json (PS7) coerces the
                        # ISO-8601 "…Z" string to a [datetime] (Kind=Utc); [string]-ing that DROPS the offset,
                        # and a RoundtripKind re-parse then assumes LOCAL — a silent timezone shift (−3h in
                        # UTC+3) that froze lastLegTs ~3h in the past and pinned the cold state to "cold now".
                        # Handle the coerced [datetime] directly (cast respects Kind); fall back to
                        # AssumeUniversal for the raw-string case (PS 5.1 doesn't coerce). Gap-based nColdLegs
                        # was immune (both legs shifted equally → difference unchanged); only now-vs-lastLegTs broke.
                        $legTs = $null
                        if ($p.timestamp) {
                            try {
                                $ts = $p.timestamp
                                if ($ts -is [datetime]) {
                                    if ($ts.Kind -eq [System.DateTimeKind]::Unspecified) { $ts = [datetime]::SpecifyKind($ts, [System.DateTimeKind]::Utc) }
                                    $legTs = ([DateTimeOffset]$ts).ToUnixTimeSeconds()
                                } else {
                                    $legTs = [DateTimeOffset]::Parse([string]$ts, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal).ToUnixTimeSeconds()
                                }
                            } catch {}
                        }
                        if ($null -ne $legTs -and $null -ne $r.lastLegTs) {
                            $gap = [double]$legTs - [double]$r.lastLegTs
                            if ($gap -gt 300 -and $cwTok -ge 50000 -and $crTok -lt (0.5 * $cwTok)) {
                                $r.nColdLegs       = [int]$r.nColdLegs + 1
                                $r.coldWastedUnits = [double]$r.coldWastedUnits + ($cwTok * ($M_CACHE_WRITE - $M_CACHE_READ))
                                $r.lastColdLegIdx  = [int]$r.nLegs   # this leg's index — for the "paid N legs ago" recency read

                            }
                        }
                        if ($null -ne $legTs) { $r.lastLegTs = $legTs }
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
    # Sanity guard: a loaded costBaseline can never legitimately exceed the current cumulative
    # cost (the global total only grows from the carryover point). If it does, it's stale/corrupt
    # (e.g. a value left by an earlier write race, or a billing-period total reset) and would clamp
    # sessionCost to ~0 downstream — silently suppressing the cold chip + countdown. Null it so the
    # capture below re-establishes a sane baseline (the real carryover if still early, else 0).
    if (($r.PSObject.Properties.Match('costBaseline').Count -gt 0) -and ($null -ne $r.costBaseline) -and ([double]$r.costBaseline -gt [double]$currentCost)) {
        $r.costBaseline = $null
    }
    # Per-session cost baseline. /clear starts a new session_id but does NOT reset
    # total_cost_usd (it carries across — confirmed v2.1.158), so without this the inherited
    # cumulative gets divided over the post-clear legs and smeared onto leg-1. Capture the
    # inherited total ONCE, on a genuinely-new session (its costBaseline starts $null);
    # migrated/pre-existing sessions start it at 0 so their legitimate total isn't excluded.
    # Downstream, base/per-leg $/fresh use (currentCost - costBaseline). Leg-1 reads ≈$0
    # (its cost can't be isolated from the inherited total) — an accepted, bounded edge.
    if (($r.PSObject.Properties.Match('costBaseline').Count -gt 0) -and ($null -eq $r.costBaseline) -and ([int]$r.nLegs -gt 0)) {
        # Capture ONLY when observed from near the start (≤5 legs) — a genuine new/cleared session,
        # where currentCost is the inherited /clear carryover to exclude. If first observed already-long
        # (bulk catch-up of a pre-existing session), baseline 0: use the global total, since the true
        # start can't be reconstructed and zeroing a long history would be wrong.
        if ([int]$r.nLegs -le 5) { $r.costBaseline = [double]$currentCost } else { $r.costBaseline = 0 }
    }
    $r.lastSeenCost = [double]$currentCost

    # No frozen fresh-leg baseline under Option C: `fresh` is computed live downstream as
    # base × mean(perLegUnits[0..4]). Because `base` is flat over the session, that value
    # doesn't drift, and `base` cancels in the froz5 ratio (nextUnits / mean-first-5-units),
    # so it's rock-stable without snapshotting anything. (The old freshBaselineUsd freeze
    # was a symptom-patch for the blended-rate drift that composition-weighting removes.)

    try {
        $r | ConvertTo-Json -Depth 10 | Out-File -FilePath $statsPath -Encoding utf8 -Force
    } catch {}

    # Prune stale per-session rollups on a session's FIRST render only (rare → cheap; a directory
    # scan every refresh in every idle session would reintroduce overhead). Delete siblings not
    # written in >7 days; never the current file. Fully guarded so it can't break the line.
    if (-not $hadPrior) {
        try {
            $cutoff = (Get-Date).AddDays(-7)
            $self = $sessionId + '.json'
            Get-ChildItem -LiteralPath $statsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $self -and $_.LastWriteTime -lt $cutoff } |
                ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {} }
        } catch {}
    }

    return $r
}

# Seconds between full sub-agent directory walks. The aggregate fleet KPIs tolerate a few seconds of
# lag (D2 — agents are watched in aggregate, never per-leg), so we don't re-walk on every idle render.
$AGENT_SCAN_THROTTLE = 15

# Sub-agent cost rollup (Solution A — see docs/agent-cost-accounting.md). Claude Code folds every
# spawned sub-agent's cost into the session's total_cost_usd, but their transcripts live OUTSIDE the
# main file, under <transcript-minus-.jsonl>/subagents/** — both Task/Agent-tool agents directly in
# subagents/ AND workflow agents under subagents/workflows/wf_*/. So the main scan's sumUnits counts
# only main legs while total_cost includes agents → base = sessionCost / main_units inflates every
# per-leg $ by (total_units / main_units). This scans the agent transcripts incrementally (per-file
# byte offsets cached in <sessionId>.agents.json, like the main scan — a finished agent's file is read
# once; throttled walk) and returns the agent unit total + aggregate KPIs, so base can be taken over
# the COMBINED unit pool (de-inflated) and the fleet shown separately. Returns $null when no sub-agents
# exist (the common case → cheap Test-Path skip). The transcripts are local (~/.claude/projects), so the
# only cost is the directory walk, which the throttle bounds.
function UpdateAgentRollups($sessionId, $tpath, $projRoot) {
    if (-not $sessionId -or -not $tpath) { return $null }
    $subDir = ($tpath -replace '\.jsonl$', '') + [IO.Path]::DirectorySeparatorChar + 'subagents'
    if (-not (Test-Path -LiteralPath $subDir)) { return $null }
    $statsDir = if ($projRoot) { Join-Path $projRoot '.claude\statusline-stats' } else { Join-Path $ClaudeHome '.claude\statusline-stats' }
    try { if (-not (Test-Path -LiteralPath $statsDir)) { New-Item -ItemType Directory -Force -Path $statsDir | Out-Null } } catch {}
    $cachePath = Join-Path $statsDir ($sessionId + '.agents.json')
    $cache = $null
    if (Test-Path -LiteralPath $cachePath) {
        try { $cache = Get-Content $cachePath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json } catch {}
    }
    if ($null -eq $cache -or $cache.PSObject.Properties.Match('agents').Count -eq 0) {
        $cache = [pscustomobject]@{ lastScanTs = [int]0; agents = @() }
    }
    if ($null -eq $cache.agents) { $cache.agents = @() }
    $nowEpoch = [int][double]::Parse((Get-Date -UFormat %s))
    # path -> entry lookup from the cached array (one entry per agent transcript).
    $byPath = @{}
    foreach ($a in @($cache.agents)) { if ($a -and $a.path) { $byPath[[string]$a.path] = $a } }
    $doScan = (@($cache.agents).Count -eq 0) -or (($nowEpoch - [int]$cache.lastScanTs) -ge $AGENT_SCAN_THROTTLE)
    if ($doScan) {
        try {
            $files = Get-ChildItem -LiteralPath $subDir -Recurse -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                $key = $f.FullName
                $e = $byPath[$key]
                if (-not $e) {
                    $e = [pscustomobject]@{ path = $key; offset = [long]0; units = [double]0; ownUnits = [double]0; legs = [int]0; out = [long]0; maxCtx = [int]0; lastMsgId = '' }
                    $byPath[$key] = $e
                }
                # File shrank (rotated) → reprocess from the start.
                if ([long]$e.offset -gt $f.Length) { $e.offset = 0; $e.units = 0; $e.ownUnits = 0; $e.legs = 0; $e.out = 0; $e.maxCtx = 0; $e.lastMsgId = '' }
                if ([long]$e.offset -lt $f.Length) {
                    $fs = $null
                    try {
                        $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
                        $fs.Seek([long]$e.offset, 'Begin') | Out-Null
                        $remaining = $f.Length - [long]$e.offset
                        $buf = New-Object byte[] $remaining
                        $null = $fs.Read($buf, 0, $remaining)
                        $txt = [System.Text.Encoding]::UTF8.GetString($buf)
                        $lastNl = $txt.LastIndexOf("`n")
                        if ($lastNl -ge 0) {
                            $proc = $txt.Substring(0, $lastNl + 1)
                            $consumed = [System.Text.Encoding]::UTF8.GetByteCount($proc)
                            foreach ($line in ($proc -split "`n")) {
                                $line = $line.Trim()
                                if (-not $line) { continue }
                                if ($line -notmatch '"type"\s*:\s*"assistant"') { continue }
                                try {
                                    $p = $line | ConvertFrom-Json
                                    if ($p.type -ne 'assistant') { continue }
                                    $mid = $p.message.id
                                    if (-not $mid -or $mid -eq $e.lastMsgId) { continue }
                                    $u = $p.message.usage
                                    if (-not $u) { continue }
                                    $inTok = [int]$u.input_tokens; $cwTok = [int]$u.cache_creation_input_tokens; $crTok = [int]$u.cache_read_input_tokens; $outTok = [int]$u.output_tokens
                                    $e.units    = [double]$e.units + ($inTok * $M_INPUT + $cwTok * $M_CACHE_WRITE + $crTok * $M_CACHE_READ + $outTok * $M_OUTPUT)
                                    $e.ownUnits = [double]$e.ownUnits + ($inTok * $M_INPUT + $cwTok * $M_CACHE_WRITE + $outTok * $M_OUTPUT)
                                    $e.legs     = [int]$e.legs + 1
                                    $e.out      = [long]$e.out + $outTok
                                    $ctx = $inTok + $cwTok + $crTok
                                    if ($ctx -gt [int]$e.maxCtx) { $e.maxCtx = $ctx }
                                    $e.lastMsgId = $mid
                                } catch {}
                            }
                            $e.offset = [long]$e.offset + $consumed
                        }
                    } catch {}
                    finally { if ($fs) { try { $fs.Close() } catch {} } }
                }
            }
            $cache.lastScanTs = $nowEpoch
            $cache.agents = @($byPath.Values)
            try { $cache | ConvertTo-Json -Depth 6 | Out-File -FilePath $cachePath -Encoding utf8 -Force } catch {}
        } catch {}
    }
    # Aggregate the fleet KPIs from the (possibly throttle-stale) cache. Only count agents with ≥1 leg.
    $live = @($cache.agents | Where-Object { $_ -and [int]$_.legs -gt 0 })
    if ($live.Count -eq 0) { return $null }
    $sumUnits = 0.0; $sumLegs = 0; $sumOut = 0; $sumMaxCtx = 0; $maxCtx = 0; $maxUnits = 0.0; $ctxList = @()
    foreach ($a in $live) {
        $sumUnits += [double]$a.units; $sumLegs += [int]$a.legs; $sumOut += [long]$a.out
        $sumMaxCtx += [int]$a.maxCtx; $ctxList += [int]$a.maxCtx
        if ([int]$a.maxCtx -gt $maxCtx)    { $maxCtx = [int]$a.maxCtx }
        if ([double]$a.units -gt $maxUnits) { $maxUnits = [double]$a.units }
    }
    $ctxSorted = @($ctxList | Sort-Object)
    $medCtx = $ctxSorted[[int][Math]::Floor($ctxSorted.Count / 2)]
    return [pscustomobject]@{
        nAgents = $live.Count; sumUnits = $sumUnits; sumLegs = $sumLegs; sumOut = $sumOut
        sumMaxCtx = $sumMaxCtx; medCtx = $medCtx; maxCtx = $maxCtx; maxUnits = $maxUnits
    }
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
# Trailing status-line-version badge ('bsl' = bloated status line; distinct from the
# Claude Code 'v' next to the model). Dim, parked at the end of line 1.
$line1Parts += (DarkGray "bsl$SlVersion")
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
# quadratically with session length. Costs derive from composition-weighted units
# (Option C, see docs/status-line-redesign.md): base = total_cost / sumUnits is flat
# over the session, so all three numbers below are honest and non-drifting. The display:
#   - $X.XX                          absolute cumulative session spend.
#   - next $X.XX =R.Rx $X.XX (fresh)  ambitious forecast of the next leg vs a live "fresh leg"
#                                     baseline (= base × mean of the first ≤5 legs' units).
#                                     Forecast = base × (0.10×ctx_tokens   [EXACT floor: re-read
#                                     the current context as a cache hit] + median of the last 5
#                                     legs' own-work units). Ratio = nextUnits / mean-first-5-units
#                                     (base cancels → rock-stable, anchored to the first 5 legs):
#                                     a TRUE escalation signal that reads below 1 when caching makes
#                                     the next leg cheaper than a cold early leg, and climbs past 1
#                                     as context cost outgrows the early anchor. Rendered as a
#                                     muted-tint chip via a diverging gradient (see Froz5RGB):
#                                     green below 1, white at parity (1.0), warming to red as it
#                                     climbs. Gradient anchors are provisional, pending real data.
#   - last leg $X.XX                 most recent leg's cost (spike detector).
$cacheParts = @()
$tpath = $d.transcript_path
$sessionId = $d.session_id
$costUsd = $d.cost.total_cost_usd
$ctxTok = $d.context_window.total_input_tokens
# Project dir (from the stdin JSON — same source the sidecar dual-write uses below). Derived here,
# earlier than its git-cluster use, so the per-session rollup file can be project-local.
$cwd = if ($d.workspace.current_dir) { $d.workspace.current_dir } else { $d.cwd }

if ($null -ne $costUsd) {
    $cacheParts += (ColorCost $costUsd ('$' + ('{0:N2}' -f $costUsd)))
}
$rollup = $null
if ($sessionId -and $tpath -and $null -ne $costUsd) {
    $rollup = UpdateSessionRollups $sessionId $tpath $costUsd $cwd
}
# Session-local cost: exclude any cost inherited across a /clear (see costBaseline in
# UpdateSessionRollups), so per-leg $ / forecast / fresh reflect THIS session's spend rather
# than the global wallet total. The displayed $total chip (above) stays global on purpose.
$sessionCost = $costUsd
if ($rollup -and $rollup.PSObject.Properties.Match('costBaseline').Count -gt 0 -and $null -ne $rollup.costBaseline) {
    $sessionCost = [double]$costUsd - [double]$rollup.costBaseline
    if ($sessionCost -lt 0) { $sessionCost = 0 }
}
# Sub-agent units (Solution A — docs/agent-cost-accounting.md): total_cost_usd includes every spawned
# sub-agent's cost, but their units live OUTSIDE the main transcript. Fold them into the denominator so
# base reflects the COMBINED pool — otherwise base = sessionCost / main_units inflates every per-leg $ by
# (total/main) in agent-heavy sessions. $agentAgg is $null (→ agentUnits 0 → de-inflation is a no-op) when
# there are no sub-agents, so sessions without agents are byte-for-byte unchanged.
$agentAgg = $null
if ($sessionId -and $tpath) { try { $agentAgg = UpdateAgentRollups $sessionId $tpath $cwd } catch {} }
$agentUnits = if ($agentAgg) { [double]$agentAgg.sumUnits } else { 0.0 }
$mainUnits  = if ($rollup)   { [double]$rollup.sumUnits } else { 0.0 }
$totalUnits = $mainUnits + $agentUnits
# Split the session spend main vs agents (feeds the agents cluster). base is taken over $totalUnits
# everywhere below, so the main per-leg / sparkline / fresh / cold-tax numbers come out de-inflated.
$agentsUsd = $null; $mainSessionUsd = $null; $baseTrue = $null
if ($totalUnits -gt 0 -and $sessionCost -gt 0) {
    $baseTrue       = [double]$sessionCost / $totalUnits
    $mainSessionUsd = $baseTrue * $mainUnits
    $agentsUsd      = $baseTrue * $agentUnits
}
# Per-leg dollar costs = stored per-leg cost units × base (= session_cost / total_units, agents folded in).
# Composition-weighted, so cache-heavy legs price correctly (cheap, not a token-count
# spike), the bar sums to session_cost exactly, and — because base is flat over the
# session — it does NOT drift down as cache reads accumulate. Feeds the sparkline (cluster 5).
$perLegCostArr = @()
$nextPart = $null   # forecast chip, assembled below — appended AFTER last-leg so the line reads $total | last leg | next …
if ($rollup -and $null -ne $rollup.perLegUnits -and [double]$rollup.sumUnits -gt 0 -and $sessionCost -gt 0) {
    $base = [double]$sessionCost / $totalUnits
    $perLegCostArr = @($rollup.perLegUnits | ForEach-Object { [double]$base * [double]$_ })
}
if ($rollup -and $sessionCost -gt 0 -and [int]$rollup.nLegs -gt 0 `
        -and [double]$rollup.sumUnits -gt 0 -and $null -ne $ctxTok -and $ctxTok -gt 0) {
    $base = [double]$sessionCost / $totalUnits
    # Ambitious next-leg forecast (Option C): an EXACT floor — re-reading the current
    # context as a cache hit, priced at 0.10× (M_CACHE_READ × ctx_tokens) — plus a robust
    # own-work estimate (trailing median of the last ≤5 legs' own-work units, so one fat-
    # output leg doesn't skew it). The floor is the "how did you know" signal: exact, and
    # ~90% of the real next-leg cost once context is deep.
    $floorUnits = $M_CACHE_READ * [double]$ctxTok
    $ownArr     = @($rollup.perLegOwnUnits)
    $ownTail    = if ($ownArr.Count -gt 5) { @($ownArr[($ownArr.Count - 5)..($ownArr.Count - 1)]) } else { $ownArr }
    $nextUnits  = $floorUnits + (Median $ownTail)
    $forecast   = $base * $nextUnits
    # "Fresh leg" baseline computed live: base × mean(first ≤5 legs' units). base is flat,
    # so this doesn't drift; and it equals mean(first-5 sparkline cells) by construction.
    # ratio = forecast ÷ fresh = nextUnits / mean-first-5-units — base CANCELS, so the ratio
    # is base-independent and rock-stable, anchored to the first 5 legs in honest cost-units.
    # It reads BELOW 1 when caching makes the next leg cheaper than a cold early leg, and
    # climbs past 1 as context cost outgrows the early anchor. Coloured by a diverging
    # gradient (BgFroz5/Froz5RGB): green <1, white at parity, warming to red; anchors provisional.
    $unitsArr   = @($rollup.perLegUnits)
    $bn         = [Math]::Min(5, $unitsArr.Count)
    $freshUnits = 0.0; for ($i = 0; $i -lt $bn; $i++) { $freshUnits += [double]$unitsArr[$i] }
    if ($bn -gt 0) { $freshUnits = $freshUnits / $bn }
    $freshBaseline = if ($freshUnits -gt 0) { $base * $freshUnits } else { $null }
    $ratio         = if ($freshUnits -gt 0) { $nextUnits / $freshUnits } else { $null }
    $forecastStr = '$' + ('{0:N2}' -f $forecast)
    $part = (Dim 'next ') + (ColorLegCell $forecast $forecastStr)
    if ($null -ne $ratio) {
        $ratioStr = ('{0:N1}' -f $ratio) + 'x'
        $freshStr = '$' + ('{0:N2}' -f $freshBaseline)
        $part += (Dim ' =') + (BgFroz5 $ratio $ratioStr) + (Dim "$freshStr (fresh)")
    }
    $nextPart = $part
}
if ($rollup -and $null -ne $rollup.lastLegCost -and [double]$rollup.lastLegCost -gt 0) {
    $ltc    = [double]$rollup.lastLegCost
    $ltcStr = '$' + ('{0:N2}' -f $ltc)
    $cacheParts += (Dim 'last leg ') + (ColorLegCell $ltc $ltcStr)
}
# Forecast comes AFTER last-leg so the cost line reads: $total | last leg | next … (Florian's order).
if ($nextPart) { $cacheParts += $nextPart }
# === Cold-cache stats — its own line, rendered below the cost line ===
# Idle gaps past the ~5-min ephemeral-cache TTL force a full cold RE-CREATE of the context at
# cache_write (1.25×) instead of cache_read (0.10×). This line quantifies that waste so it's
# preventable: the retrospective tax already burned (tax + cold-leg share) plus the prospective
# stake the NEXT leg pays if resumed cold. Split off the cost line (which got too long) and marked
# by a single leading ❆ in deep blue (ColdBlue) so segments can stay terse. $coldStakes/$coldRemain
# are ALSO read by the sidecar snapshot block below — keep computing them here.
$snow = "❆" + [char]0x2009   # thin-space (U+2009) padding between the marker and the first segment.
# Glyph is ❆ (U+2746), NOT ❄ (U+2744): U+2744 is the only snowflake with an emoji presentation, so
# terminals/fonts render it as a fixed blue emoji bitmap that IGNORES the SGR colour — the marker
# colour (dim→blue cooling ramp, below) was a no-op on it. ❆/❅ are pure text dingbats and honour colour.
$coldParts = @()
$coldMarkerCol = '2'   # ❆ marker colour: dim by default (retrospective-only / S0 runway), brightens with the cooling ramp
$coldStakes = $null; $coldRemain = $null
$coldRecent = $false   # set true when a cold leg landed within the last $RECENT_COLD_WINDOW legs (makes a fresh tax pop)
$RECENT_COLD_WINDOW = 8   # "recent" = cold leg in the last N legs (≈ the sparkline span); tune here
# Retrospective: tax (% of the displayed $total) + cold-leg share — shown once ≥1 cold leg recorded.
if ($rollup -and [int]$rollup.nColdLegs -ge 1 -and [double]$rollup.sumUnits -gt 0 -and $sessionCost -gt 0) {
    $coldTax = ([double]$sessionCost / $totalUnits) * [double]$rollup.coldWastedUnits
    $nCold   = [int]$rollup.nColdLegs
    $taxPct  = if ($null -ne $costUsd -and [double]$costUsd -gt 0) { [int][Math]::Round(100.0 * $coldTax / [double]$costUsd) } else { 0 }
    $nL      = [int]$rollup.nLegs
    # Recency: how many legs ago the most recent cold leg landed. A dim cumulative tally hides a
    # tax you JUST paid (it looks identical to one paid 200 legs back), so within the window we
    # brighten the tax to blue + append a "just paid / N legs ago" tag. Stale → stays dim as before.
    $lastColdIdx = if ($rollup.PSObject.Properties.Match('lastColdLegIdx').Count -gt 0) { [int]$rollup.lastColdLegIdx } else { 0 }
    $legsAgo     = if ($lastColdIdx -gt 0) { $nL - $lastColdIdx } else { 9999 }
    $coldRecent  = ($lastColdIdx -gt 0 -and $legsAgo -lt $RECENT_COLD_WINDOW)
    if ($coldRecent) {
        $recencyTag = if ($legsAgo -le 0) { 'just paid' } elseif ($legsAgo -eq 1) { '1 leg ago' } else { "$legsAgo legs ago" }
        $coldParts += "${ESC}[38;5;33mtax ${taxPct}% (`$$('{0:N2}' -f $coldTax))${ESC}[0m" + [char]0x2002 + "${ESC}[1;38;5;33m$recencyTag${ESC}[0m"
    } else {
        $coldParts += (Dim 'tax ') + (Dim ($taxPct.ToString() + '% (')) + (ColorCost $coldTax ('$' + ('{0:N2}' -f $coldTax))) + (Dim ')')
    }
    $legPct  = if ($nL -gt 0) { [int][Math]::Round(100.0 * $nCold / $nL) } else { 0 }
    $coldParts += (Dim "legs $nCold/$nL ($legPct%)")
}
# Prospective: the EXTRA $ the next leg pays to re-create the context cold (avoidable units × base).
if ($rollup -and $null -ne $ctxTok -and $ctxTok -gt 0 -and [double]$rollup.sumUnits -gt 0 -and $sessionCost -gt 0) {
    $coldBase   = [double]$sessionCost / $totalUnits
    $coldStakes = $coldBase * [double]$ctxTok * ($M_CACHE_WRITE - $M_CACHE_READ)
    if ($coldStakes -ge 0.25) {
        $stakesStr = '+$' + ('{0:N2}' -f $coldStakes)   # leading + = cost ADDED on top of a normal leg
        if ($null -ne $rollup.lastLegTs) {
            # Countdown anchored to the last ACTUAL leg's timestamp (the cache-TTL clock), NOT render
            # time — robust to idle re-renders and rollup resets (which would otherwise re-stamp "now").
            $nowEpoch   = [int][double]::Parse((Get-Date -UFormat %s))
            $coldRemain = 300 - ($nowEpoch - [double]$rollup.lastLegTs)
            if ($coldRemain -gt 0) {
                # Escalation ramp across the 5-min cooling window: muted while there's runway, louder as
                # the cache nears expiry so it grabs attention while a SEND can still save the re-create.
                # (5 min is Anthropic's MINIMUM TTL — entries are "promptly, though not immediately,
                # deleted", so a send slightly past 0 can still hit a warm cache; this is a conservative
                # risk signal, not a guarantee. Each sent leg re-reads the cached prefix → resets the clock.)
                $wCol = if ($coldRemain -gt 240) { '2' } else { '38;5;33' }                      # word 'cold': dim while >4m left, then deep blue
                $tCol = if ($coldRemain -gt 240) { '2' } elseif ($coldRemain -gt 180) { '97' }   # timer: dim -> white
                        elseif ($coldRemain -gt 120) { '38;5;220' }                              #        -> yellow
                        elseif ($coldRemain -gt 60)  { '38;5;208' }                              #        -> orange
                        else { '1;31' }                                                          #        -> red
                $coldMarkerCol = $wCol   # ❆ marker tracks the cooling word: dim at S0, deep blue once urgency rises
                $amt = if ($coldRemain -gt 180) { Dim $stakesStr } else { ColorLegCell $coldStakes $stakesStr }  # amount: dim until <3m left, then leg-cost gradient
                $coldParts += "${ESC}[${wCol}mcold${ESC}[0m${ESC}[${tCol}m in $(FmtDuration ([int]$coldRemain)) ${ESC}[0m" + $amt
            } else {
                # Past the (minimum) TTL — stay NON-definitive: likely cold, but Anthropic's "not immediately
                # deleted" slack means a send just past 5m can still hit warm. So "cold? >5m", not "cold now".
                $coldMarkerCol = '38;5;33'
                $coldParts += (ColdBlue 'cold?') + "${ESC}[1;31m >5m ${ESC}[0m" + (ColorLegCell $coldStakes $stakesStr)
            }
        } else {
            $coldMarkerCol = '38;5;33'
            $coldParts += (ColdBlue 'cold') + (Dim ' risk ') + (ColorLegCell $coldStakes $stakesStr)
        }
    }
}
# A cold tax paid within the last $RECENT_COLD_WINDOW legs lifts the ❆ marker from dim to blue even on
# prospective runway (>4m → the cooling ramp leaves it dim), so a fresh hit draws the eye. The ramp can
# still push it brighter (it runs above); we only raise the floor here.
if ($coldRecent -and $coldMarkerCol -eq '2') { $coldMarkerCol = '38;5;33' }

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
# Dedicated cold-cache line (Variant B): one leading ❆ marker in deep blue, then terse segments.
# Absent entirely when there's no cold activity (no past cold legs and no live ≥$0.25 stake).
$coldLine = if ($coldParts.Count -gt 0) { "${ESC}[${coldMarkerCol}m${snow}${ESC}[0m" + ' ' + ($coldParts -join $DIM_SEP) } else { $null }

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
    # Label: ≤8 legs → one leg per cell ("$/leg:"); >8 → cells are bucket-averages ("$/leg avg:").
    # Dim [old]/[new] anchors mark the axis direction (oldest left → newest right).
    $legLabel = if ($n -le $maxBuckets) { '$/leg: ' } else { '$/leg avg: ' }
    $legsLine = (Dim $legLabel) + (Dim '[old] ') + ($cells -join '') + (Dim ' [new]') + (Dim " ($n)")
}

# === Cluster 5b: sub-agent fleet (event-gated — only when sub-agents exist) ===
# Separate from the main cost line by design (D1/D2 in docs/agent-cost-accounting.md): the main session
# is watched for Florian's own drift/bloat (a failure mode agents don't have); agents are watched as an
# AGGREGATE fleet — count · total context (median·max per agent) · cost (+ share) · depth — never per-leg.
# Agents never go cold (they run to completion), so there's no cold line here.
$agentsLine = $null
if ($agentAgg -and [int]$agentAgg.nAgents -gt 0) {
    # Legibility (Florian): every stat NUMBER renders at default foreground so it reads at a glance; only the
    # LABELS / punctuation are dimmed, and the agent `$` keeps its bright cost-gradient. (Previously med/max,
    # the share %, and legs/ag were fully dim and took too much effort to read — esp. the max-ctx fat-agent tell.)
    $aParts = @()
    $aParts += [string][int]$agentAgg.nAgents
    $aParts += (Dim 'Σctx ') + (FmtNum ([int]$agentAgg.sumMaxCtx)) + (Dim ' (med ') + (FmtNum ([int]$agentAgg.medCtx)) + (Dim '·max ') + (FmtNum ([int]$agentAgg.maxCtx)) + (Dim ')')
    if ($null -ne $agentsUsd) {
        $costChip = (ColorCost $agentsUsd ('$' + ('{0:N2}' -f [double]$agentsUsd)))
        if ($sessionCost -gt 0) { $costChip += (Dim ' (') + ([int][Math]::Round(100.0 * [double]$agentsUsd / [double]$sessionCost)).ToString() + (Dim '%)') }
        $aParts += $costChip
    }
    $avgLegs = if ([int]$agentAgg.nAgents -gt 0) { [double]$agentAgg.sumLegs / [int]$agentAgg.nAgents } else { 0 }
    $aParts += ('{0:N1}' -f $avgLegs) + (Dim ' legs/ag')
    $agentsLine = (Dim 'agents: ') + ($aParts -join $DIM_SEP)
}

# === Cluster 4: quota (per-window blackout-projection pace gauges) ===
# Each window (5h, 7d) gets its OWN line, shown only when that window is ≥50% consumed (event-driven —
# most sessions never surface it). Layout: "<win> quota →NN%▄▅NN%← time | <verdict> | <detail> | resets".
# Two block-bars (left=consumed/quota, right=elapsed/time; full glyph = 100%) sit BETWEEN the two numbers.
# Severity projects the CURRENT cumulative pace forward to a quota blackout (q,t = consumed/elapsed fractions):
#   beta = blackout as a fraction of the window = max(0, 1 - t/q)
#   B    = beta * W       how long you'll be locked out
#   S    = (t/q - t) * W  runway: real time before the blackout starts        (identity: S + B = time-to-reset)
# Colour rides beta (scale-free — a small overshoot near the cap is a small blackout, so near-cap can't
# false-alarm), bumped +1 rung when the ABSOLUTE blackout B ≥ 8h so a multi-hour 7d lockout can't wear a
# calm colour. The detail field spells the two human numbers: "<S> to act → <B> dark". Bands (on beta):
# q≤t green · ≤.10 yellow · ≤.25 orange · >.25 red; consumed ≥100% is an "exhausted" red override.
$qBlocks = ' ',[char]0x2581,[char]0x2582,[char]0x2583,[char]0x2584,[char]0x2585,[char]0x2586,[char]0x2587,[char]0x2588
$nowQ = [int][double]::Parse((Get-Date -UFormat %s))
function QLvl($p) { $l = [int][Math]::Round($p / 100.0 * 8); if ($p -gt 0 -and $l -lt 1) { $l = 1 }; if ($l -gt 8) { $l = 8 }; return $l }
function QuotaLine($label, $rl, $winSec) {
    if ($null -eq $rl.used_percentage) { return $null }
    $consumed = [double]$rl.used_percentage
    if ($consumed -lt 50) { return $null }
    $elapsed = $null
    if ($rl.resets_at) {
        $remain  = [double]$rl.resets_at - $nowQ
        $elapsed = (($winSec - $remain) / $winSec) * 100.0
        if ($elapsed -lt 0) { $elapsed = 0 }; if ($elapsed -gt 100) { $elapsed = 100 }
    }
    $q = $consumed / 100.0
    $t = if ($null -ne $elapsed) { $elapsed / 100.0 } else { $null }
    $exhausted = ($consumed -ge 100)

    # Project current cumulative pace forward to a blackout (see cluster header for the model).
    $beta = $null; $B = $null; $S = $null
    if ($null -ne $t -and $t -gt 0 -and -not $exhausted) {
        $beta = [Math]::Max([double]0, 1.0 - ($t / $q))                       # blackout as fraction of window
        $B    = $beta * $winSec                                               # blackout duration (sec)
        $S    = if ($q -gt $t) { (($t / $q) - $t) * $winSec } else { [double]0 }  # runway / time-to-act (sec)
    }

    # Rung 0/1/2/3 = green/yellow/orange/red. beta drives it; absolute blackout bumps +1.
    # When elapsed is unknown (no resets_at) fall back to absolute-consumed bands.
    $rung =
        if ($exhausted) { 3 }
        elseif ($null -eq $beta) { if ($consumed -ge 90) { 3 } elseif ($consumed -ge 70) { 1 } else { 0 } }
        elseif ($beta -le 0)    { 0 }
        elseif ($beta -le 0.10) { 1 }
        elseif ($beta -le 0.25) { 2 }
        else                    { 3 }
    if ($null -ne $B -and $B -ge 28800 -and $rung -lt 3) { $rung++ }          # +1 rung when blackout ≥ 8h
    $col = switch ($rung) { 0 { '38;5;40' } 1 { '38;5;220' } 2 { '38;5;208' } default { '1;31' } }

    # Verdict follows the FINAL rung (so a bumped line gets the louder words); detail spells the stakes.
    # used_percentage can exceed 100 (API reports overage as >100 → pay-per-use usage credits), hence the
    # exhausted override and the "+N%" that reconciles with the displayed NN% (e.g. 112% → +12%).
    if ($exhausted) {
        $over    = [int][Math]::Round($consumed - 100)
        $verdict = if ($over -ge 1) { "quota exhausted - on usage +$over%" } else { 'quota exhausted' }
        $detail  = 'dark until reset'
    } else {
        $verdict = switch ($rung) { 0 { 'you can keep this pace' } 1 { 'slow down just a bit' } 2 { 'slow down' } default { 'slow down hard' } }
        if ($rung -eq 0 -and $null -ne $t -and $t -gt 0) {
            $rho    = $q / $t                                                 # projected end consumption if pace holds
            $detail = ('ends ~{0}% ' -f [int][Math]::Round($rho * 100)) + ([char]0x00B7) + (' {0}% spare' -f [int][Math]::Round((1 - $rho) * 100))
        } elseif ($null -ne $B) {
            $detail = (FmtDurShort $S) + ' to act ' + ([char]0x2192) + ' ' + (FmtDurShort $B) + ' dark'
        } else {
            $detail = $null
        }
    }

    # Gauge: "<win> quota →NN%▄▅NN%← time" — bars between the numbers, arrows pointing inward.
    $cbar = $qBlocks[(QLvl $consumed)]
    $ebar = if ($null -ne $elapsed) { $qBlocks[(QLvl $elapsed)] } else { ' ' }
    $qn   = [int][Math]::Round($consumed)
    $tn   = if ($null -ne $elapsed) { [int][Math]::Round($elapsed) } else { $null }
    $mid  = ([char]0x2192) + "$qn%$cbar$ebar" + $(if ($null -ne $tn) { "$tn%" } else { '' }) + ([char]0x2190)
    $gauge = (Dim "$label quota ") + "$ESC[${col}m$mid$ESC[0m" + (Dim ' time')

    $s = $gauge
    if ($verdict) { $s += $DIM_SEP + "$ESC[${col}m$verdict$ESC[0m" }
    if ($detail)  { $s += $DIM_SEP + "$ESC[${col}m$detail$ESC[0m" }
    if ($rl.resets_at) { $s += $DIM_SEP + (Dim ('resets ' + (FmtDurShort ([int]([double]$rl.resets_at - $nowQ))))) }
    return $s
}
$qLines = @()
$q5 = QuotaLine '5h' $d.rate_limits.five_hour 18000
$q7 = QuotaLine '7d' $d.rate_limits.seven_day 604800
if ($q5) { $qLines += $q5 }
if ($q7) { $qLines += $q7 }

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
# Daily cross-session token usage — moved here from the quota cluster (now event-gated at ≥50%), so
# it stays visible. stats-cache.json holds ONLY the externally-populated dailyModelTokens counter;
# per-session rollups live in <project>/.claude/statusline-stats/<sessionId>.json (race fix).
$statsPath = "$ClaudeHome/.claude/stats-cache.json"
if (Test-Path $statsPath) {
    try {
        $stats = Get-Content $statsPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $todayEntry = $stats.dailyModelTokens | Where-Object { $_.date -eq $today }
        if ($todayEntry) {
            $sumToday = 0
            $todayEntry.tokensByModel.PSObject.Properties | ForEach-Object { $sumToday += [int]$_.Value }
            if ($sumToday -gt 0) { $costParts += (Dim ('today:' + (FmtNum $sumToday))) }
        }
    } catch {}
}
$line5 = if ($costParts.Count -gt 0) { (Dim 'session: ') + ($costParts -join $DIM_SEP) } else { $null }

# === Cluster 6: git ===
# $cwd derived earlier (near the cost cluster) for the per-session rollup path; reused here.
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
        $gitLine = (Dim 'git: ') + $repo + ' ' + $sync
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
    # Discretized froz5 state, aligned to the Froz5RGB diverging-gradient stops (parity at
    # 1.0). Provisional — the gradient anchors are mid-recalibration under Option C; the
    # /handover-check consumer reads froz5Ratio qualitatively, not this field.
    $froz5State = if ($null -eq $ratio) { $null }
        elseif ($ratio -lt 1.0) { 'green' }
        elseif ($ratio -lt 1.8) { 'white' }
        elseif ($ratio -lt 2.8) { 'yellow' }
        elseif ($ratio -lt 3.8) { 'orange' }
        else { 'red' }
    $toCompactTok = if ($null -ne $ctxUsed -and $null -ne $ctxSize) { [int]($ctxSize * 0.95) - [int]$ctxUsed } else { $null }
    $activityPct  = if ($aliveSec -and [int]$aliveSec -gt 0 -and $null -ne $apiSec) { [Math]::Round(100.0 * $apiSec / $aliveSec, 1) } else { $null }
    # Cold-cache snapshot fields — mirror the §Cold-cache chip (A/B) state machine so /handover-check
    # can surface the PROSPECTIVE stake (the ❆ chip), not just the retrospective cold-tax. These reuse
    # $coldStakes / $coldRemain computed in the chip block above. coldStakeUsd = EXTRA $ the next leg
    # pays if taken cold now (null below the $0.25 surface threshold); coldState ∈ cooling|cold|idle-cold.
    $coldStakeUsd = $null; $coldState = $null; $coldCoolRemainSec = $null
    if ($null -ne $coldStakes -and $coldStakes -ge 0.25) {
        $coldStakeUsd = [Math]::Round([double]$coldStakes, 2)
        if ($null -ne $rollup.lastLegTs) {
            if ($null -ne $coldRemain -and $coldRemain -gt 0) { $coldState = 'cooling'; $coldCoolRemainSec = [int]$coldRemain }
            else { $coldState = 'cold' }
        } else { $coldState = 'idle-cold' }
    }
    $snapshot = [ordered]@{
        schema         = 3
        sessionId      = $sessionId
        renderedAt     = [int][double]::Parse((Get-Date -UFormat %s))   # epoch seconds (UTC); a NUMBER so ConvertFrom-Json won't coerce it to a culture-formatted [DateTime] on the read side
        transcriptPath = $tpath
        costBaseline   = $(if ($rollup) { $rollup.costBaseline } else { $null })
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
        nColdLegs        = $(if ($rollup) { [int]$rollup.nColdLegs } else { $null })
        coldWastedUsd    = $(if ($rollup -and [double]$rollup.sumUnits -gt 0 -and $sessionCost -gt 0) { [Math]::Round(([double]$sessionCost / $totalUnits) * [double]$rollup.coldWastedUnits, 2) } else { $null })
        coldStakeUsd      = $coldStakeUsd
        coldState         = $coldState
        coldCoolRemainSec = $coldCoolRemainSec
        legCosts     = @($perLegCostArr | ForEach-Object { [Math]::Round([double]$_, 4) })
        aliveSec     = $aliveSec
        apiSec       = $apiSec
        activityPct  = $activityPct
        linesAdded   = $d.cost.total_lines_added
        linesRemoved = $d.cost.total_lines_removed
        tps          = $(if ($null -ne $tps) { [int]$tps } else { $null })
        base           = $baseTrue
        nAgents        = $(if ($agentAgg) { [int]$agentAgg.nAgents } else { $null })
        agentsUsd      = $(if ($null -ne $agentsUsd) { [Math]::Round([double]$agentsUsd, 2) } else { $null })
        mainSessionUsd = $(if ($null -ne $mainSessionUsd) { [Math]::Round([double]$mainSessionUsd, 2) } else { $null })
        agentLegs      = $(if ($agentAgg) { [int]$agentAgg.sumLegs } else { $null })
        agentCtxMax    = $(if ($agentAgg) { [int]$agentAgg.maxCtx } else { $null })
        gitRepo      = $repo
    }
    # Dual write (see docs/status-line.md → Sidecar). PRIMARY is project-local
    # (<cwd>/.claude/statusline-last.json) so concurrent sessions in different projects stop
    # clobbering each other's snapshot; the GLOBAL home file is kept as a fallback (first render
    # before the project file exists) and as the most-recently-rendered-across-all marker.
    $json = $snapshot | ConvertTo-Json -Depth 5 -Compress
    if ($cwd) {
        $projDir = Join-Path $cwd '.claude'
        if (-not (Test-Path -LiteralPath $projDir)) { New-Item -ItemType Directory -Force -Path $projDir | Out-Null }
        $json | Out-File -FilePath (Join-Path $projDir 'statusline-last.json') -Encoding utf8 -Force
    }
    $json | Out-File -FilePath "$ClaudeHome/.claude/statusline-last.json" -Encoding utf8 -Force
} catch {}

# Session line (alive/api · lines · turn TPS) is HIDDEN per Florian (rarely read). $line5 is still
# BUILT above — and its $aliveSec/$apiSec feed the sidecar's activityPct — so this only suppresses
# DISPLAY, code intact. Flip $ShowSessionLine to $true to restore.
$ShowSessionLine = $false

$out = @()
$out += $line1
if ($line2)    { $out += $line2 }
foreach ($q in $qLines) { if ($q) { $out += $q } }   # quota: 0–2 per-window pace-gauge lines
if ($line3)    { $out += $line3 }
if ($coldLine) { $out += $coldLine }                 # cold-cache stats line, directly under cost
if ($legsLine) { $out += $legsLine }
if ($agentsLine) { $out += $agentsLine }             # sub-agent fleet (event-gated, only when agents exist)
if ($line5 -and $ShowSessionLine) { $out += $line5 }
if ($gitLine)  { $out += $gitLine }

[Console]::Out.Write(($out -join "`n"))
