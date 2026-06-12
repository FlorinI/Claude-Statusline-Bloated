# leg-driver.ps1 — shared per-leg cost-DRIVER labeller (single source of truth).
#
# Given one priced leg record, name what made it expensive from the token mix alone — zero
# transcript-content archaeology. Dot-sourced by BOTH statusline-bloated.ps1 (the live big-leg
# spotlight cluster, hot path) and render-spikes.ps1 (the /handover-check top-N spike panel), so
# the live line and the report row can never drift. Pure function, no side effects on source.
#
# The leg record must carry: cwUnits (per-tier cache-write units), cr (cache_read tokens),
# out (output tokens), inT (fresh input tokens), cw (cache_creation tokens), gapToPrev (idle
# seconds since the previous leg, or $null), coldTtl (the prior leg's cache TTL in seconds).
#
# Dominant cost DRIVER = the largest WEIGHTED term (what drove the cost, not the raw count).
function Get-Driver($l) {
    $terms = @{ cw = $l.cwUnits; cr = $l.cr * 0.10; out = $l.out * 5.0; inp = $l.inT * 1.0 }
    $winner = ($terms.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    switch ($winner) {
        'cw'  {
            # cw dominant has THREE causes that look identical in the weighted cost. The
            # "full-cache rewrite" signature — cw≥50k ∧ cr<0.5·cw — covers two of them: Claude
            # Code periodically re-writes the whole prefix at 1.25× with little read-back. Whether
            # that rewrite is a COLD re-cache (idle past the cache TTL expired the whole cache) or a
            # WARM rewrite (the prefix re-issued seconds later — NOT new content) is decided by whether
            # the idle gap exceeded the PRIOR cache's TTL ($l.coldTtl: 3600 on a subscription's 1h cache,
            # 300 on 5m), mirroring UpdateSessionRollups' tier-aware gap test. Only when
            # read-back is large relative to the write (cr ≳ cw — signature ABSENT) was context
            # genuinely added: the prior context stayed warm and was read back beside the new write.
            # The old two-way split mislabeled warm rewrites as "new context", and their numbers
            # summed past the context-window size (the tell).
            $isRewrite = ($l.cw -ge 50000 -and $l.cr -lt ($l.cw * 0.5))
            if ($isRewrite -and $null -ne $l.gapToPrev -and $l.gapToPrev -gt $l.coldTtl) {
                're-cached ~{0}k (cold — cache expired after idle)' -f [int][Math]::Round($l.cw / 1000)
            } elseif ($isRewrite) {
                're-cached ~{0}k (warm rewrite, not new content)' -f [int][Math]::Round($l.cw / 1000)
            } else {
                'loaded ~{0}k new context' -f [int][Math]::Round($l.cw / 1000)
            }
        }
        'out' { 'generated ~{0}k output'      -f [int][Math]::Round($l.out / 1000) }
        'cr'  { 're-read deep context (~{0}k)' -f [int][Math]::Round($l.cr / 1000) }
        default { 'large fresh input (~{0}k)'  -f [int][Math]::Round($l.inT / 1000) }
    }
}

# Composition weights — list-price ratios; cache-write is TIER-DEPENDENT (1h 2× / 5m 1.25×). Single
# source of truth for the off-hot-path scanners (render-spikes, handover-facts); MUST stay in sync with
# statusline-bloated.ps1's CacheWriteUnits.
$M_INPUT = 1.0; $M_CACHE_WRITE_5M = 1.25; $M_CACHE_WRITE_1H = 2.0; $M_CACHE_READ = 0.10; $M_OUTPUT = 5.0

# Test-ColdLeg — the ONE cold-tax predicate, shared by render-spikes (panel ❆ marks) and handover-facts
# (fact-sheet count) so the explainer's prose and its spike panel can NEVER disagree (the within-report
# "1 leg in prose / 2 in panel" contradiction). A leg is cold iff a full-prefix re-write (cw≥50k ∧
# cr<0.5·cw) was preceded by an idle gap longer than the prior cache's effective-durable TTL ($l.coldTtl).
function Test-ColdLeg($l) {
    [double]$l.cw -ge 50000 -and [double]$l.cr -lt ([double]$l.cw * 0.5) `
        -and $null -ne $l.gapToPrev -and [double]$l.gapToPrev -gt [double]$l.coldTtl
}

# Get-ScannedLegs — the ONE authoritative transcript scan for the /handover-check renderers. Per-leg
# token mix → weighted units, idle gap, and the effective-DURABLE prior-TTL (1h if any of the last 8
# cache-writing legs wrote 1h, else 5m — mirrors the status line's recentWriteTtls). Recomputed from the
# immutable transcript, so every leg is judged under CURRENT logic — no fossilized per-leg verdicts from a
# mid-session logic change (which is exactly what made the persisted incremental nColdLegs lag this scan).
# Dedup by message.id, mirroring UpdateSessionRollups. Returns priced-leg records ready for Get-Driver /
# Test-ColdLeg. Off the hot path (only /handover-check). Returns @() on a missing/unreadable transcript.
function Get-ScannedLegs([string]$transcriptPath) {
    if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { return ,@() }
    $seen = @{}; $legs = @(); $idx = 0; $prevTs = $null; $recentTtls = @()
    foreach ($line in [System.IO.File]::ReadAllLines($transcriptPath)) {
        if ($line -notmatch '"type"\s*:\s*"assistant"') { continue }
        $p = $null; try { $p = $line | ConvertFrom-Json } catch { continue }
        $mid = $p.message.id; if (-not $mid -or $seen.ContainsKey($mid)) { continue }; $seen[$mid] = $true
        $u = $p.message.usage; if ($null -eq $u) { continue }; $idx++
        $inT = [double]$u.input_tokens; $cw = [double]$u.cache_creation_input_tokens
        $cr = [double]$u.cache_read_input_tokens; $out = [double]$u.output_tokens
        $cw1h = [double]$u.cache_creation.ephemeral_1h_input_tokens; $cw5m = [double]$u.cache_creation.ephemeral_5m_input_tokens
        $cwUnits = if (($cw1h + $cw5m) -gt 0) { $cw1h * $M_CACHE_WRITE_1H + $cw5m * $M_CACHE_WRITE_5M } else { $cw * $M_CACHE_WRITE_5M }
        $units = $inT * $M_INPUT + $cwUnits + $cr * $M_CACHE_READ + $out * $M_OUTPUT
        $legTtl = if ($cw1h -gt 0) { 3600 } elseif ($cw5m -gt 0) { 300 } else { 0 }
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
        $gapToPrev = if ($null -ne $legTs -and $null -ne $prevTs) { [double]$legTs - [double]$prevTs } else { $null }
        if ($null -ne $legTs) { $prevTs = $legTs }
        $durablePrevTtl = if ($recentTtls -contains 3600) { 3600 } else { 300 }
        $legs += [pscustomobject]@{ idx = $idx; inT = $inT; cw = $cw; cwUnits = $cwUnits; cr = $cr; out = $out; units = $units; gapToPrev = $gapToPrev; coldTtl = $durablePrevTtl }
        if ($legTtl -gt 0) { $recentTtls += $legTtl; if (@($recentTtls).Count -gt 8) { $recentTtls = @($recentTtls[-8..-1]) } }
    }
    ,$legs
}
