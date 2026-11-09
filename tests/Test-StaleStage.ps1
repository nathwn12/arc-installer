# tests\Test-StaleStage.ps1 — t28: a stage merged from an older theme generation
# must never be applied, and a variant switch must never clobber an unknown live
# payload.
#
# (a) apply.ps1 on a root whose installed-manifest.json sourceOrigin theme hash
#     disagrees with the theme on disk is REFUSED with a "stale stage" reason,
#     names the rebuild path, and writes NOTHING (manifest, state, stage and
#     live hashes unchanged; no apply journal is created).
# (b) the SAME root after a real re-merge (bin\Merge-IconTheme.ps1 -Build) passes
#     the same preflight (apply -DryRun plans, exit 0).
# (c) ARC-Icons.ps1 -Action apply (a variant switch) on a root whose live
#     payload matches neither the recorded original nor the recorded merge
#     REFUSES before it mutates anything: the refusal names the file, its hash
#     and the rebase path, and the manifest is unchanged (no merge ran).
# (d) the switch chain asks ONCE, before any mutation: declining leaves the
#     payload exactly as it was (no merge/restore, no stock-icons state).
#
# Every root is a TEMP copy made from %ProgramData%\ArcIcons. C:\Windows is
# never read (beyond the copied manifests) and never written. Windows PowerShell
# 5.1 only (executes ARC-Icons.ps1, so run from an elevated shell).
# Run: powershell -NoProfile -File tests\Test-StaleStage.ps1 [-Keep]
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$script:fails = 0
$script:checks = 0

function Check([bool]$Condition, [string]$Message) {
    $script:checks++
    if ($Condition) { Write-Output ("PASS {0}" -f $Message) }
    else { Write-Output ("FAIL {0}" -f $Message); $script:fails++ }
}
function Get-Sha([string]$Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant() }
function Invoke-Proc([string]$Exe, [string[]]$ArgList) {
    # child scripts write refusals to stderr; with EAP=Stop that would terminate
    # this test, so capture it as data instead.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $Exe @ArgList 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Out = $out; Code = $code; Flat = ($out -replace '\s+', ' ') }
}
function Invoke-ProcWithInput([string]$Exe, [string[]]$ArgList, [string]$InputText) {
    # confirmations read the console line; 'n' + Enter declines the single prompt
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = ($InputText | & $Exe @ArgList 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Out = $out; Code = $code; Flat = ($out -replace '\s+', ' ') }
}
function New-Root([string]$Source, [string]$Dest, [string[]]$ThemeDirs, [switch]$NoStage) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item -Recurse -Force -LiteralPath (Join-Path $Source 'originals') -Destination (Join-Path $Dest 'originals')
    if (-not $NoStage) {
        Copy-Item -Recurse -Force -LiteralPath (Join-Path $Source 'stage') -Destination (Join-Path $Dest 'stage')
    }
    foreach ($td in $ThemeDirs) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Dest (Split-Path -Parent (Join-Path 'theme' $td))) | Out-Null
        Copy-Item -Recurse -Force -LiteralPath (Join-Path $Source ('theme\' + $td)) -Destination (Join-Path $Dest ('theme\' + $td))
    }
    foreach ($f in @('installed-manifest.json', 'state.json')) {
        if (Test-Path -LiteralPath (Join-Path $Source $f)) { Copy-Item -Force -LiteralPath (Join-Path $Source $f) -Destination (Join-Path $Dest $f) }
    }
}
function New-Live([string]$StageDir, [string]$Dest) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    foreach ($n in @('imageres.dll.mun', 'imagesp1.dll.mun', 'zipfldr.dll.mun')) {
        Copy-Item -Force -LiteralPath (Join-Path $StageDir $n) -Destination (Join-Path $Dest $n)
    }
}
function Get-RootFingerprint([string]$Root, [string]$LiveDir) {
    $rows = @()
    foreach ($rel in @('installed-manifest.json', 'state.json', 'stage\imageres.dll.mun', 'stage\imagesp1.dll.mun', 'stage\zipfldr.dll.mun')) {
        $p = Join-Path $Root $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) { $rows += ($rel + '=' + (Get-Sha $p)) } else { $rows += ($rel + '=absent') }
    }
    if ($LiveDir) {
        foreach ($n in @('imageres.dll.mun', 'imagesp1.dll.mun', 'zipfldr.dll.mun')) {
            $p = Join-Path $LiveDir $n
            if (Test-Path -LiteralPath $p -PathType Leaf) { $rows += ('live\' + $n + '=' + (Get-Sha $p)) } else { $rows += ('live\' + $n + '=absent') }
        }
    }
    return ($rows -join '|')
}

$src = Join-Path $env:ProgramData 'ArcIcons'
foreach ($need in @('originals\manifest.json', 'originals\imageres.dll.mun', 'originals\imagesp1.dll.mun', 'originals\zipfldr.dll.mun',
        'stage\imageres.dll.mun', 'stage\imagesp1.dll.mun', 'stage\zipfldr.dll.mun', 'installed-manifest.json',
        'theme\Arc Dark Grey\Windhawk Resources\imageres.dll', 'theme\Arc Dark Grey\Windhawk Resources\imagesp1.dll',
        'theme\Arc Dark Grey\Windhawk Resources\zipfldr.dll', 'theme\Windhawk Resources\imageres.dll',
        'theme\Windhawk Resources\imagesp1.dll', 'theme\Windhawk Resources\zipfldr.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $src $need))) {
        throw ("this test needs a real install root at {0} (missing {1})" -f $src, $need)
    }
}
$exe = (Get-Process -Id $PID).Path
$apply = Join-Path $PSScriptRoot '..\apply.ps1'
$merge = Join-Path $PSScriptRoot '..\bin\Merge-IconTheme.ps1'
$icons = Join-Path $PSScriptRoot '..\ARC-Icons.ps1'
$T = Join-Path ([IO.Path]::GetTempPath()) ('arc-stale-test-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
New-Item -ItemType Directory -Force -Path $T | Out-Null
try {
    # ---------- (a)+(b): stale stage refused, then re-merged and accepted ----------
    $rootAB = Join-Path $T 'rootAB'
    New-Root $src $rootAB @('Arc Dark Grey\Windhawk Resources')
    $liveAB = Join-Path $T 'liveAB'
    New-Live (Join-Path $rootAB 'stage') $liveAB

    # simulate yesterday's failure: the manifest still records the OLD theme
    # generation's hash while the theme on disk was regenerated (recorded value
    # is what a 2026-10-14 merge signed; disk is the 2026-11-06 generation).
    $mfAB = Join-Path $rootAB 'installed-manifest.json'
    $manAB = Get-Content -Raw -LiteralPath $mfAB | ConvertFrom-Json
    $imageresTheme = Join-Path $rootAB 'theme\Arc Dark Grey\Windhawk Resources\imageres.dll'
    $diskHash = Get-Sha $imageresTheme
    $patched = $false
    foreach ($r in @($manAB.sourceOrigin.files)) {
        if ([string]$r.name -eq 'imageres.dll') { $r.sha256 = ('0' * 64); $patched = $true }
    }
    Check $patched 'A0 test can reach the manifest sourceOrigin row it needs to corrupt'
    [IO.File]::WriteAllText($mfAB, ($manAB | ConvertTo-Json -Depth 8), $utf8NoBom)
    $beforeAB = Get-RootFingerprint $rootAB $liveAB

    $r = Invoke-Proc $exe @('-NoProfile', '-File', $apply, '-Root', $rootAB, '-SystemResourceDir', $liveAB, '-Variant', 'dark-grey')
    Check ($r.Code -eq 1) 'A1 apply.ps1 on a stale stage exits 1'
    Check ($r.Flat -match 'stale stage') 'A2 refusal says "stale stage"'
    Check ($r.Flat -match 'installed-manifest\.json was merged from a different theme generation') 'A3 refusal names the theme-generation mismatch'
    Check ($r.Flat -match [regex]::Escape('imageres.dll')) 'A4 refusal names the disagreeing theme file'
    Check ($r.Flat -match 'ARC-Icons\.ps1 -Action install') 'A5 refusal names the rebuild path'
    Check ($r.Flat -match 'no changes made') 'A6 refusal states that nothing was written'
    $afterAB = Get-RootFingerprint $rootAB $liveAB
    Check ($beforeAB -eq $afterAB) 'A7 apply.ps1 wrote nothing (manifest, state, stage and live hashes unchanged)'
    Check (-not (Test-Path -LiteralPath (Join-Path $rootAB 'logs'))) 'A8 no apply journal directory was created'

    # (b) the documented rebuild: a real re-merge of the same variant
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $merge, '-Root', $rootAB, '-Build', '-Variant', 'dark-grey')
    Check ($r.Code -eq 0) 'B1 re-merge (Merge-IconTheme -Build) exits 0'
    $manB = Get-Content -Raw -LiteralPath $mfAB | ConvertFrom-Json
    $recB = ''
    foreach ($row in @($manB.sourceOrigin.files)) { if ([string]$row.name -eq 'imageres.dll') { $recB = ([string]$row.sha256).ToUpperInvariant() } }
    Check ($recB -eq $diskHash) 'B2 re-merge re-records the theme on disk (sourceOrigin imageres hash == disk)'
    New-Live (Join-Path $rootAB 'stage') $liveAB
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $apply, '-Root', $rootAB, '-SystemResourceDir', $liveAB, '-Variant', 'dark-grey', '-DryRun')
    Check ($r.Code -eq 0) 'B3 the same root after re-merge passes preflight (apply -DryRun exit 0)'
    Check ($r.Flat -match 'DRY-RUN plan') 'B4 the plan is printed'
    Check (-not ($r.Flat -match 'stale stage')) 'B5 the rebuilt stage is no longer called stale'

    # ---------- (c): unknown live payload refuses the variant switch ----------
    $rootC = Join-Path $T 'rootC'
    New-Root $src $rootC @('Windhawk Resources', 'Arc Dark Grey\Windhawk Resources') -NoStage
    $liveC = Join-Path $T 'liveC'
    New-Live (Join-Path $src 'stage') $liveC
    # one live file that matches neither the recorded original nor the recorded merge
    $zC = Join-Path $liveC 'zipfldr.dll.mun'
    $bytes = [IO.File]::ReadAllBytes($zC)
    $grown = New-Object byte[] ($bytes.Length + 1)
    [Array]::Copy($bytes, $grown, $bytes.Length)
    $grown[$bytes.Length] = 0x41
    [IO.File]::WriteAllBytes($zC, $grown)
    $unknownHash = Get-Sha $zC
    $beforeC = Get-RootFingerprint $rootC $liveC

    $r = Invoke-Proc $exe @('-NoProfile', '-File', $icons, '-Action', 'apply', '-Variant', 'arc', '-Root', $rootC, '-SystemResourceDir', $liveC, '-Yes')
    Check ($r.Code -eq 1) 'C1 variant switch over an unknown live payload exits 1'
    Check ($r.Flat -match 'ARC-ICONS-SWITCH: REFUSED') 'C2 refusal is tagged ARC-ICONS-SWITCH'
    Check ($r.Flat -match 'zipfldr\.dll\.mun') 'C3 refusal names the offending file'
    Check ($r.Flat -match [regex]::Escape($unknownHash)) 'C4 refusal names the live hash it found'
    Check ($r.Flat -match 'Rebase-ArcIconsOriginal') 'C5 refusal names the rebase path'
    $afterC = Get-RootFingerprint $rootC $liveC
    Check ($beforeC -eq $afterC) 'C6 nothing was mutated (no merge, no restore, live untouched)'
    Check (-not (Test-Path -LiteralPath (Join-Path $rootC 'stage'))) 'C7 the switch never reached the merge step'

    # ---------- (d): one confirmation, before any mutation ----------
    $rootD = Join-Path $T 'rootD'
    New-Root $src $rootD @('Windhawk Resources', 'Arc Dark Grey\Windhawk Resources')
    $liveD = Join-Path $T 'liveD'
    New-Live (Join-Path $rootD 'stage') $liveD
    $beforeD = Get-RootFingerprint $rootD $liveD
    $r = Invoke-ProcWithInput $exe @('-NoProfile', '-File', $icons, '-Action', 'apply', '-Variant', 'arc', '-Root', $rootD, '-SystemResourceDir', $liveD) 'n'
    Check ($r.Flat -match 'cancelled') 'D1 declining the single prompt cancels the switch'
    Check ($r.Code -eq 0) 'D2 a declined switch is a clean exit (0), not an error'
    $afterD = Get-RootFingerprint $rootD $liveD
    Check ($beforeD -eq $afterD) 'D3 decline leaves the payload as it was: no merge, no restore, no partial state'
    $instD = Get-Content -Raw -LiteralPath (Join-Path $rootD 'installed-manifest.json') | ConvertFrom-Json
    $mergedD = ''
    foreach ($row in @($instD.files)) { if ([string]$row.name -eq 'zipfldr.dll.mun') { $mergedD = ([string]$row.mergedSha256).ToUpperInvariant() } }
    Check ((Get-Sha (Join-Path $liveD 'zipfldr.dll.mun')) -eq $mergedD) 'D4 live payload is still the recorded merge after declining (never left on stock icons)'

    # D5: every confirmation happens BEFORE the first mutation. The defect was a
    # second prompt after merge+restore: declining it stranded the machine on
    # stock icons. Prove the last Confirm call in Invoke-Apply precedes the
    # merge step (and D1-D4 prove a decline mutates nothing).
    $iconsText = Get-Content -Raw -LiteralPath $icons
    $applyBody = [regex]::Match($iconsText, '(?s)function Invoke-Apply \{.*?\r?\n\}').Value
    $lastConfirm = $applyBody.LastIndexOf('Confirm', [StringComparison]::Ordinal)
    $firstMutation = $applyBody.IndexOf('-File $Merge', [StringComparison]::Ordinal)
    Check (($lastConfirm -ge 0) -and ($firstMutation -gt $lastConfirm)) 'D5 no confirmation runs after the chain starts mutating (single ask, before merge/restore)'
}
finally {
    if (($script:fails -eq 0) -and (-not $Keep)) { Remove-Item -Recurse -Force -LiteralPath $T -ErrorAction SilentlyContinue }
    else { Write-Output ("scratch kept for diagnosis: {0}" -f $T) }
}

if ($script:fails -eq 0) {
    Write-Output ('STALE-STAGE-TEST: PASS ({0} checks: stale stage refused + nothing written, re-merge accepted, unknown live refuses the switch with file+hash+rebase path, one confirmation before mutation)' -f $script:checks)
    exit 0
}
Write-Output ("STALE-STAGE-TEST: FAIL ({0} check(s))" -f $script:fails)
exit 1
