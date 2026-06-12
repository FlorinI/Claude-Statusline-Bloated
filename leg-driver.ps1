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
