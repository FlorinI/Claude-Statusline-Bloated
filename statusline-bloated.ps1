$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$input_json = [Console]::In.ReadToEnd()
$d = $input_json | ConvertFrom-Json

if ($env:CLAUDE_STATUSLINE_DEBUG -eq '1') {
    $input_json | Out-File -FilePath (Join-Path $HOME '.claude/statusline-input-sample.json') -Encoding utf8
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

function ColorByTokenCount($tokens, $text) {
    if ($null -eq $tokens) { return $text }
    if ($tokens -lt 10000)  { return "${ESC}[38;5;46m$text${ESC}[0m" }
    if ($tokens -lt 50000)  { return "${ESC}[38;5;40m$text${ESC}[0m" }
    if ($tokens -lt 200000) { return (Yellow $text) }
    if ($tokens -lt 500000) { return (Orange $text) }
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

$DIM_SEP = Dim ' | '

# Per-session cumulative-token rollups, cached in stats-cache.json. Reading the entire
# jsonl transcript on every status-line refresh would be wasteful (transcripts can hit
# 15+ MB), so we remember the last byte offset we processed and only consume newly
# appended lines on each invocation. Tracked totals: nAssistantTurns (one per assistant
# API call — note that a conversational turn can span several), sumInputBilled (input +
# cache_read + cache_creation across every assistant entry), sumOutputTokens, and the
# last cumulative cost we saw (used to derive last-turn cost as a delta).
function UpdateSessionRollups($sessionId, $tpath, $currentCost) {
    if (-not $sessionId -or -not $tpath -or -not (Test-Path -LiteralPath $tpath)) { return $null }
    $statsPath = (Join-Path $HOME '.claude/stats-cache.json')
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
            nAssistantTurns  = [int]0
            sumInputBilled   = [long]0
            sumOutputTokens  = [long]0
            lastMsgId        = ''
            lastInputBilled  = [int]0
            lastOutputTokens = [int]0
            lastSeenCost     = [double]0
            lastTurnCost     = $null
        }
    }
    # Migration shim: rollups written by earlier versions of this script counted one
    # "turn" per content block (each text/tool_use block was logged as its own transcript
    # entry, so a single API call produced 3-5 lines). Older caches without lastMsgId
    # are inflated and unsafe to extend; reset them so the next pass repopulates clean.
    if ($r.PSObject.Properties.Match('lastMsgId').Count -eq 0) {
        $r | Add-Member -NotePropertyName 'lastMsgId' -NotePropertyValue ''
        $r.lastByteOffset = 0; $r.nAssistantTurns = 0
        $r.sumInputBilled = 0; $r.sumOutputTokens = 0
    }
    $nTurnsBefore = [int]$r.nAssistantTurns

    $fs = $null
    try {
        $fs = [System.IO.File]::Open($tpath, 'Open', 'Read', 'ReadWrite')
        $totalLen = $fs.Length
        # Transcript shrank → file rotated/rewound → discard prior rollup and reprocess.
        if ([long]$r.lastByteOffset -gt $totalLen) {
            $r.lastByteOffset = 0; $r.nAssistantTurns = 0
            $r.sumInputBilled = 0; $r.sumOutputTokens = 0
            $r.lastInputBilled = 0; $r.lastOutputTokens = 0
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
                        $r.nAssistantTurns  = [int]$r.nAssistantTurns + 1
                        $r.sumInputBilled   = [long]$r.sumInputBilled + $inp
                        $r.sumOutputTokens  = [long]$r.sumOutputTokens + $out
                        $r.lastMsgId        = $msgId
                        $r.lastInputBilled  = $inp
                        $r.lastOutputTokens = $out
                    } catch {}
                }
                $r.lastByteOffset = [long]$r.lastByteOffset + $consumedBytes
            }
        }
    } catch {}
    finally { if ($fs) { try { $fs.Close() } catch {} } }

    # Last-turn cost = delta of cumulative_cost since previous refresh. Only update when
    # we've genuinely advanced turns (otherwise idle refreshes would zero it out) and
    # when this isn't the first time we've seen the session (lastSeenCost would be 0,
    # making the delta equal full session cost — a bogus "last turn cost" of the whole run).
    if ($hadPrior -and [int]$r.nAssistantTurns -gt $nTurnsBefore) {
        $delta = [double]$currentCost - [double]$r.lastSeenCost
        if ($delta -gt 0) { $r.lastTurnCost = $delta }
    }
    $r.lastSeenCost = [double]$currentCost

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
    $ctxParts += (Dim (FmtPct $ctxPct))
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
#   - next $X.XX/leg ×R.R (avg $X.XX) forecast of the next leg vs historical avg-$-per-leg,
#                                     with the next/avg ratio as the headline signal.
#                                     Forecast = (total_cost / sumInputBilled) × current_ctx_tokens.
#                                     Avg is anchored to past (smaller-context) legs; forecast
#                                     scales to current context. Ratio = forecast / avg — a
#                                     direct measure of how much the current context is
#                                     inflating the next leg vs typical past legs. 1.0 = parity,
#                                     2.0 = next leg costs 2x a typical past leg (handover candidate).
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
if ($rollup -and $costUsd -gt 0 -and [int]$rollup.nAssistantTurns -gt 0 `
        -and [long]$rollup.sumInputBilled -gt 0 -and $null -ne $ctxTok -and $ctxTok -gt 0) {
    $avgPerLeg        = [double]$costUsd / [double]$rollup.nAssistantTurns
    $blendedInputRate = [double]$costUsd / [double]$rollup.sumInputBilled
    $forecast         = $blendedInputRate * [double]$ctxTok
    $ratio            = if ($avgPerLeg -gt 0) { $forecast / $avgPerLeg } else { $null }
    $forecastStr      = '$' + ('{0:N2}' -f $forecast)
    $avgStr           = '$' + ('{0:N2}' -f $avgPerLeg)
    $part = (Dim 'next leg ') + (ColorHigh $forecast $forecastStr 0.20 1.00)
    if ($null -ne $ratio) {
        $ratioStr = '{0:N1}' -f $ratio
        $part += (Dim ' = ') + (ColorHigh $ratio $ratioStr 1.5 3.0) + (Dim " x $avgStr (avg)")
    } else {
        $part += (Dim " (avg $avgStr)")
    }
    $cacheParts += $part
}
if ($rollup -and $null -ne $rollup.lastTurnCost -and [double]$rollup.lastTurnCost -gt 0) {
    $ltc    = [double]$rollup.lastTurnCost
    $ltcStr = '$' + ('{0:N2}' -f $ltc)
    $cacheParts += (Dim 'last = ') + (ColorHigh $ltc $ltcStr 0.05 0.50)
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
    $statsPath = (Join-Path $HOME '.claude/stats-cache.json')
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

$out = @()
$out += $line1
if ($line2)   { $out += $line2 }
if ($line4)   { $out += $line4 }
if ($line3)   { $out += $line3 }
if ($line5)   { $out += $line5 }
if ($gitLine) { $out += $gitLine }

[Console]::Out.Write(($out -join "`n"))
