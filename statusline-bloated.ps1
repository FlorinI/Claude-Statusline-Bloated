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

# === Cluster 3: avg cost + turn speed ===
# avg $/Mtok: cumulative session cost extrapolated against current context size.
# Answers "what is it costing me on average to land a token of context in the model."
$cacheParts = @()
$costUsd = $d.cost.total_cost_usd
$ctxTok  = $d.context_window.total_input_tokens
if ($null -ne $costUsd -and $null -ne $ctxTok -and $ctxTok -gt 0 -and $costUsd -gt 0) {
    $perMtok = ($costUsd / $ctxTok) * 1e6
    $perMtokStr = '$' + ('{0:N2}' -f $perMtok) + '/Mtok'
    $cacheParts += (Dim 'avg ') + (ColorHigh $perMtok $perMtokStr 15 50)
}
$tpath = $d.transcript_path

# Full-turn TPS anchored to the latest user-message timestamp.
# Reads the last 128 KB of the transcript. If that tail doesn't contain a `type:user`
# entry AND the file is larger than the tail, surface a red `tail!` warning so we
# know the metric is missing for a real reason (not just a quiet turn).
$tailBytes = 2097152
$tailWarning = $false
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
                $cacheParts += (Dim 'turn ') + (FmtDuration ([int]$duration)) + (Dim ' @ ') + $coloredTps
            }
        }
    } catch {}
}
if ($tailWarning) {
    $cacheParts += (RedBold 'tail!')
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
$costParts = @()
if ($null -ne $d.cost.total_cost_usd) {
    $costParts += (ColorCost $d.cost.total_cost_usd ('$' + ('{0:N2}' -f $d.cost.total_cost_usd)))
}
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
