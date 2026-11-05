# tests\Test-RebasePlan.ps1 — red/green proof for the single-file original rebase
# and the pair-only manifest merge. Runs ENTIRELY on temp copies made from
# %ProgramData%\ArcIcons (originals + stage + theme + manifest): it never reads or
# writes C:\Windows\SystemResources and never mutates the real install root.
#
# Green (must pass): wrong -ExpectLiveHash / merged-live / sibling-less live /
# a plain hardlink that is NOT in WinSxS / a manifest originalPath or aclFile
# that escapes -Root are all REFUSED (exit 1, nothing written); a -Commit while
# logs\ArcIcons.lock is held is refused by the LOCK before any validation runs
# (proving lock-then-validate); a real rebase plans (exit 0), commits, archives
# the superseded original, rewrites only that row, is idempotent on re-run, and
# flips apply.ps1 -DryRun from REFUSED to a plan; merge -Pair keeps 3 rows with
# 2 untouched and throws when an untouched stage disagrees with its merged hash.
# RED before the change: bin\Rebase-ArcIconsOriginal.ps1 does not exist (exit 1,
# "not recognized"), and -Pair build writes a 1-row manifest (apply preflight
# then fails "must carry exactly three entries").
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$script:fails = 0

function Check([bool]$Condition, [string]$Message) {
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
    return [pscustomobject]@{ Out = $out; Code = $code }
}
function New-RootCopy([string]$Source, [string]$Dest) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    foreach ($d in @('originals', 'stage')) { Copy-Item -Recurse -Force -LiteralPath (Join-Path $Source $d) -Destination (Join-Path $Dest $d) }
    Copy-Item -Recurse -Force -LiteralPath (Join-Path $Source 'theme\Arc Dark Grey') -Destination (Join-Path $Dest 'theme\Arc Dark Grey')
    Copy-Item -Force -LiteralPath (Join-Path $Source 'installed-manifest.json') -Destination (Join-Path $Dest 'installed-manifest.json')
}
function New-FakeLive([string]$Dir, [string]$SeedZipfldr, [switch]$SameBytes) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Copy-Item -Force -LiteralPath $SeedZipfldr -Destination (Join-Path $Dir 'zipfldr.dll.mun')
    if (-not $SameBytes) {
        # change a byte OUTSIDE the resource area (DOS-stub padding, past
        # e_lfanew at 0x3C): the file is still a valid PE, and a later merge
        # produces a payload distinct from the old merged file.
        $b = [IO.File]::ReadAllBytes((Join-Path $Dir 'zipfldr.dll.mun'))
        $b[0x40] = [byte](($b[0x40] + 1) % 256)
        [IO.File]::WriteAllBytes((Join-Path $Dir 'zipfldr.dll.mun'), $b)
    }
    return (Join-Path $Dir 'zipfldr.dll.mun')
}
function Add-WinSxSSibling([string]$LiveFile, [string]$Root) {
    $cd = Join-Path $Root 'WinSxS\amd64_microsoft-windows-zipfldr_31bf3856ad364e35_10.0.26100.9711_none_13a8b26ae566b441'
    New-Item -ItemType Directory -Force -Path $cd | Out-Null
    $p = Join-Path $cd 'zipfldr.dll.mun'
    New-Item -ItemType HardLink -Path $p -Target $LiveFile | Out-Null
    return $p
}

$src = Join-Path $env:ProgramData 'ArcIcons'
foreach ($need in @('originals\manifest.json', 'originals\zipfldr.dll.mun', 'installed-manifest.json', 'stage\zipfldr.dll.mun', 'theme\Arc Dark Grey\Windhawk Resources\zipfldr.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $src $need))) { throw ("this test needs a real install root at {0} (missing {1})" -f $src, $need) }
}
$T = Join-Path ([IO.Path]::GetTempPath()) ('arc-rebase-test-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Force -Path $T | Out-Null
try {
    $exe = (Get-Process -Id $PID).Path
    $rebase = Join-Path $PSScriptRoot '..\bin\Rebase-ArcIconsOriginal.ps1'
    $merge = Join-Path $PSScriptRoot '..\bin\Merge-IconTheme.ps1'
    $apply = Join-Path $PSScriptRoot '..\apply.ps1'
    $name = 'zipfldr.dll.mun'
    $srcOrig = Join-Path $src "originals\$name"
    $srcStage = Join-Path $src "stage\$name"
    $oldSha = Get-Sha $srcOrig
    $instSrc = Get-Content -Raw -LiteralPath (Join-Path $src 'installed-manifest.json') | ConvertFrom-Json
    $mergedSha = [string](@($instSrc.files | Where-Object { $_.name -eq $name })[0].mergedSha256)

    # ---- RootA: a root whose live zipfldr is a NEW OS build (bytes differ) ----
    $rootA = Join-Path $T 'rootA'
    New-RootCopy $src $rootA
    $origRowsBefore = @{}
    foreach ($row in @((Get-Content -Raw -LiteralPath (Join-Path $rootA 'originals\manifest.json') | ConvertFrom-Json).files)) { $origRowsBefore[[string]$row.name] = [string]$row.originalSha256 }

    $liveA = Join-Path $T 'liveA'
    $zipA = New-FakeLive $liveA $srcOrig
    Copy-Item -Force -LiteralPath (Join-Path $src 'stage\imageres.dll.mun') -Destination (Join-Path $liveA 'imageres.dll.mun')
    Copy-Item -Force -LiteralPath (Join-Path $src 'stage\imagesp1.dll.mun') -Destination (Join-Path $liveA 'imagesp1.dll.mun')
    $sibA = Add-WinSxSSibling $zipA $liveA
    $newSha = Get-Sha $zipA

    # R1 red: wrong expected hash
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootA, '-SystemResourceDir', $liveA, '-Name', $name, '-ExpectLiveHash', ('0' * 64))
    Check (($r.Code -eq 1) -and ($r.Out -match 'ExpectLiveHash')) 'R1 wrong -ExpectLiveHash is REFUSED (exit 1)'

    # R2: live already equals the recorded original -> already-rebased no-op
    $liveB = Join-Path $T 'liveB'
    $zipB = New-FakeLive $liveB $srcOrig -SameBytes
    [void](Add-WinSxSSibling $zipB $liveB)
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootA, '-SystemResourceDir', $liveB, '-Name', $name, '-ExpectLiveHash', $oldSha)
    Check (($r.Code -eq 0) -and ($r.Out -match 'already-rebased')) 'R2 live == recorded original -> already-rebased, exit 0'

    # R3 red: no hardlink sibling (unattributed file)
    $liveC = Join-Path $T 'liveC'
    $zipC = New-FakeLive $liveC $srcOrig
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootA, '-SystemResourceDir', $liveC, '-Name', $name, '-ExpectLiveHash', (Get-Sha $zipC))
    Check (($r.Code -eq 1) -and ($r.Out -match 'sibling')) 'R3 live without a WinSxS sibling is REFUSED (exit 1)'

    # R3b red: a plain hardlink OUTSIDE WinSxS is not component attribution
    $liveC2 = Join-Path $T 'liveC2'
    $zipC2 = New-FakeLive $liveC2 $srcOrig
    $plainDir = Join-Path $T 'plaincopy'
    New-Item -ItemType Directory -Force -Path $plainDir | Out-Null
    New-Item -ItemType HardLink -Path (Join-Path $plainDir $name) -Target $zipC2 | Out-Null
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootA, '-SystemResourceDir', $liveC2, '-Name', $name, '-ExpectLiveHash', (Get-Sha $zipC2))
    Check (($r.Code -eq 1) -and ($r.Out -match 'WinSxS')) 'R3b live hardlinked only OUTSIDE WinSxS is REFUSED (exit 1)'

    # R4 red: live IS the recorded merged file (our install is live, not an OS baseline)
    $liveD = Join-Path $T 'liveD'
    New-Item -ItemType Directory -Force -Path $liveD | Out-Null
    Copy-Item -Force -LiteralPath $srcStage -Destination (Join-Path $liveD $name)
    [void](Add-WinSxSSibling (Join-Path $liveD $name) $liveD)
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootA, '-SystemResourceDir', $liveD, '-Name', $name, '-ExpectLiveHash', $mergedSha)
    Check (($r.Code -eq 1) -and ($r.Out -match 'merged')) 'R4 live == recorded merged is REFUSED (exit 1)'

    # R5 green: dry-run plan, and it writes nothing
    $manA = Join-Path $rootA 'originals\manifest.json'
    $manBefore = Get-Sha $manA
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootA, '-SystemResourceDir', $liveA, '-Name', $name, '-ExpectLiveHash', $newSha)
    Check (($r.Code -eq 0) -and ($r.Out -match 'DRY-RUN plan') -and ($r.Out -match [regex]::Escape($newSha))) 'R5 rebase -DryRun prints the plan and exits 0'
    Check ((Get-Sha $manA) -eq $manBefore) 'R5 dry-run wrote nothing (manifest hash unchanged)'

    # R6 red: apply.ps1 -DryRun on the same root still REFUSES (the defect)
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $apply, '-Root', $rootA, '-SystemResourceDir', $liveA, '-Variant', 'dark-grey', '-DryRun')
    Check (($r.Code -eq 1) -and ($r.Out -match 'REFUSED') -and ($r.Out -match 'zipfldr')) 'R6 apply -DryRun BEFORE rebase: REFUSED exit 1'

    # R7 green: commit the rebase
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootA, '-SystemResourceDir', $liveA, '-Name', $name, '-ExpectLiveHash', $newSha, '-Commit')
    Check (($r.Code -eq 0) -and ($r.Out -match 'ARC-REBASE: OK')) 'R7 rebase -Commit writes and exits 0'

    $manAJson = Get-Content -Raw -LiteralPath $manA | ConvertFrom-Json
    $rowA = @($manAJson.files | Where-Object { $_.name -eq $name })[0]
    Check ([string]$rowA.originalSha256 -eq $newSha) 'R8 manifest row originalSha256 == adopted live hash'
    Check ([int64]$rowA.originalSize -eq (Get-Item -LiteralPath $zipA).Length) 'R8 manifest row originalSize == adopted live size'
    Check ([string]$rowA.owner -eq (Get-Acl -LiteralPath $zipA).Owner) 'R8 manifest row owner == adopted live owner'
    Check (([string]$rowA.sddl) -match '^O:.*D:') 'R8 manifest row sddl is a full SDDL'
    Check (([string]$rowA.winSxSComponent) -match '10\.0\.26100\.9711') 'R8 row winSxSComponent names the 26100.9711 component'
    Check ([string]$rowA.baseVersion -eq '10.0.26100.9711') 'R8 row baseVersion == 10.0.26100.9711'
    Check (([string]$rowA.capturedFrom) -match [regex]::Escape($liveA)) 'R8 row capturedFrom names the live file'
    Check ((Get-Sha (Join-Path $rootA "originals\$name")) -eq $newSha) 'R8 originals\<name> now holds the adopted live bytes'
    $sup = Join-Path $rootA ("originals\superseded\" + $oldSha)
    Check ((Test-Path -LiteralPath (Join-Path $sup $name)) -and ((Get-Sha (Join-Path $sup $name)) -eq $oldSha)) 'R8 superseded\<oldSha>\<name> archives the previous original'
    Check (Test-Path -LiteralPath (Join-Path $sup 'superseded.json')) 'R8 superseded metadata written'
    Check (Test-Path -LiteralPath (Join-Path $rootA ("originals\acl\" + $name + '.acl'))) 'R8 acl sidecar rewritten'
    Check ((Test-Path -LiteralPath (Join-Path $rootA 'logs\rebase.journal.jsonl')) -and ((Get-Content -Raw -LiteralPath (Join-Path $rootA 'logs\rebase.journal.jsonl')) -match 'rebase-end')) 'R8 rebase journal records rebase-end'
    $untouchedOk = $true
    foreach ($row in @($manAJson.files)) {
        if ([string]$row.name -eq $name) { continue }
        if ([string]$row.originalSha256 -ne $origRowsBefore[[string]$row.name]) { $untouchedOk = $false }
    }
    Check $untouchedOk 'R8 the other two originals rows are untouched'

    # R9 green: idempotent re-run
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootA, '-SystemResourceDir', $liveA, '-Name', $name, '-ExpectLiveHash', $newSha)
    Check (($r.Code -eq 0) -and ($r.Out -match 'already-rebased')) 'R9 re-run on the rebased root: already-rebased exit 0'

    # R10 green: re-merge the variant ON the adopted original. Adopting stock as
    # the original must never mean stock becomes the merged payload - zipfldr has
    # to be re-merged onto the new baseline like the other two rows.
    $rowsInstBefore = @((Get-Content -Raw -LiteralPath (Join-Path $rootA 'installed-manifest.json') | ConvertFrom-Json).files)
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $merge, '-Root', $rootA, '-Build', '-Pair', $name, '-Variant', 'dark-grey')
    Check ($r.Code -eq 0) 'R10 merge -Pair on the rebased root builds (exit 0)'
    $rowsA = @((Get-Content -Raw -LiteralPath (Join-Path $rootA 'installed-manifest.json') | ConvertFrom-Json).files)
    $zipRowA = @($rowsA | Where-Object { $_.name -eq $name })[0]
    $newMergedSha = Get-Sha (Join-Path $rootA "stage\$name")
    Check ($rowsA.Count -eq 3) 'R10 re-merge keeps 3 manifest rows'
    Check ([string]$zipRowA.mergedSha256 -eq $newMergedSha) 'R10 zipfldr row re-recorded with the NEW merged hash'
    Check (([string]$zipRowA.mergedSha256 -ne $mergedSha) -and ($newMergedSha -ne $newSha)) 'R10 zipfldr merged payload is neither the old merged file nor stock'
    Check ([string]$zipRowA.originalSha256 -eq $newSha) 'R10 zipfldr row originalSha256 still the adopted live hash'
    $keptA = 0
    foreach ($row in $rowsA) {
        if ([string]$row.name -eq $name) { continue }
        $pre = @($rowsInstBefore | Where-Object { $_.name -eq $row.name })[0]
        if (([string]$row.mergedSha256 -eq [string]$pre.mergedSha256) -and ([string]$row.originalSha256 -eq [string]$pre.originalSha256)) { $keptA++ }
    }
    Check ($keptA -eq 2) 'R10 the other two rows are unchanged by the re-merge'

    # R11 green: apply -DryRun now PLANs, and the plan carries the re-merged hash
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $apply, '-Root', $rootA, '-SystemResourceDir', $liveA, '-Variant', 'dark-grey', '-DryRun')
    Check (($r.Code -eq 0) -and ($r.Out -match 'DRY-RUN plan') -and ($r.Out -match 'zipfldr')) 'R11 apply -DryRun AFTER rebase+merge: plan exit 0 (flip)'
    Check ($r.Out -match [regex]::Escape($newMergedSha)) 'R11 the plan stages the RE-MERGED zipfldr hash, not stock'

    # ---- RootB: pair-only merge keeps three rows, two untouched ----
    $rootB = Join-Path $T 'rootB'
    New-RootCopy $src $rootB
    $manB = Join-Path $rootB 'installed-manifest.json'
    $rowsBefore = @{}
    foreach ($row in @((Get-Content -Raw -LiteralPath $manB | ConvertFrom-Json).files)) { $rowsBefore[[string]$row.name] = [string]$row.mergedSha256 }
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $merge, '-Root', $rootB, '-Build', '-Pair', $name, '-Variant', 'dark-grey')
    Check ($r.Code -eq 0) 'R11 merge -Pair zipfldr builds (exit 0)'
    $manBJson = Get-Content -Raw -LiteralPath $manB | ConvertFrom-Json
    $rowsB = @($manBJson.files)
    Check ($rowsB.Count -eq 3) 'R11 pair build keeps 3 manifest rows'
    $zipRowB = @($rowsB | Where-Object { $_.name -eq $name })[0]
    Check ([string]$zipRowB.mergedSha256 -eq (Get-Sha (Join-Path $rootB "stage\$name"))) 'R11 rebuilt row mergedSha256 == new stage hash'
    Check ([string]$zipRowB.mergedSha256 -eq $rowsBefore[$name]) 'R11 same original + same theme rebuild deterministically (hash stable)'
    $kept = 0
    foreach ($row in $rowsB) {
        if ([string]$row.name -eq $name) { continue }
        if (([string]$row.mergedSha256 -eq $rowsBefore[[string]$row.name]) -and ([string]$row.originalSha256 -eq $origRowsBefore[[string]$row.name])) { $kept++ }
    }
    Check ($kept -eq 2) 'R11 the two untouched rows are unchanged'
    Check ([string]$manBJson.variantId -eq 'dark-grey') 'R11 manifest header still dark-grey'

    # R12 red: an untouched row whose stage disagrees with its merged hash throws
    Add-Content -LiteralPath (Join-Path $rootB 'stage\imagesp1.dll.mun') -Value 'stale'
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $merge, '-Root', $rootB, '-Build', '-Pair', $name, '-Variant', 'dark-grey')
    Check (($r.Code -ne 0) -and ($r.Out -match 'stale')) 'R12 untouched row with a stale stage is REFUSED (throws)'

    # ---- RootE: manifest paths are DATA (confinement) and lock precedes validation ----
    $rootE = Join-Path $T 'rootE'
    New-RootCopy $src $rootE
    $manE = Join-Path $rootE 'originals\manifest.json'
    $escFile = [IO.Path]::GetFullPath((Join-Path $rootE ('..\escape\' + $name)))
    $escAcl = [IO.Path]::GetFullPath((Join-Path $rootE '..\escape\escaped.acl'))

    # R13 red: originalPath that leaves -Root
    $mE = Get-Content -Raw -LiteralPath $manE | ConvertFrom-Json
    foreach ($row in @($mE.files)) { if ([string]$row.name -eq $name) { $row.originalPath = ('..\escape\' + $name) } }
    [IO.File]::WriteAllText($manE, ($mE | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    $manEBefore = Get-Sha $manE
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootE, '-SystemResourceDir', $liveA, '-Name', $name, '-ExpectLiveHash', $newSha)
    Check (($r.Code -eq 1) -and ($r.Out -match 'escapes -Root')) 'R13 manifest originalPath escaping -Root is REFUSED (exit 1)'
    Check (-not (Test-Path -LiteralPath $escFile)) 'R13 nothing was written outside -Root'
    Check ((Get-Sha $manE) -eq $manEBefore) 'R13 refusal did not rewrite the manifest'

    # R14 red: aclFile that leaves -Root (originalPath restored)
    $mE = Get-Content -Raw -LiteralPath $manE | ConvertFrom-Json
    foreach ($row in @($mE.files)) { if ([string]$row.name -eq $name) { $row.originalPath = ('originals\' + $name); $row.aclFile = '..\escape\escaped.acl' } }
    [IO.File]::WriteAllText($manE, ($mE | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    $manEBefore = Get-Sha $manE
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootE, '-SystemResourceDir', $liveA, '-Name', $name, '-ExpectLiveHash', $newSha)
    Check (($r.Code -eq 1) -and ($r.Out -match 'aclFile') -and ($r.Out -match 'escapes -Root')) 'R14 manifest aclFile escaping -Root is REFUSED (exit 1)'
    Check (-not (Test-Path -LiteralPath $escAcl)) 'R14 no sidecar was written outside -Root'
    Check ((Get-Sha $manE) -eq $manEBefore) 'R14 refusal did not rewrite the manifest'

    # R15 red/green: -Commit takes the lock BEFORE it validates. With the lock
    # held the refusal is the LOCK, not the still-invalid manifest; once the lock
    # is free the same manifest is refused for the escape. That ordering is only
    # observable if the lock is acquired first.
    $logE = Join-Path $rootE 'logs'
    New-Item -ItemType Directory -Force -Path $logE | Out-Null
    [IO.File]::WriteAllText((Join-Path $logE 'ArcIcons.lock'), 'held by the test')
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootE, '-SystemResourceDir', $liveA, '-Name', $name, '-ExpectLiveHash', $newSha, '-Commit', '-LockTimeoutSec', '2')
    Check (($r.Code -eq 1) -and ($r.Out -match 'could not acquire')) 'R15 -Commit locks BEFORE validating (lock refusal, exit 1)'
    Check ((Get-Sha $manE) -eq $manEBefore) 'R15 lock refusal wrote nothing'
    Remove-Item -Force -LiteralPath (Join-Path $logE 'ArcIcons.lock')
    $r = Invoke-Proc $exe @('-NoProfile', '-File', $rebase, '-Root', $rootE, '-SystemResourceDir', $liveA, '-Name', $name, '-ExpectLiveHash', $newSha, '-Commit', '-LockTimeoutSec', '2')
    Check (($r.Code -eq 1) -and ($r.Out -match 'escapes -Root')) 'R15 under the lock the same manifest is REFUSED (validate-under-lock, exit 1)'
    Check ((Get-Sha $manE) -eq $manEBefore) 'R15 validate-under-lock refusal wrote nothing'
}
finally {
    if ($script:fails -eq 0) { Remove-Item -Recurse -Force -LiteralPath $T -ErrorAction SilentlyContinue }
    else { Write-Output ("scratch kept for diagnosis: {0}" -f $T) }
}

if ($script:fails -eq 0) { Write-Output 'REBASE-PLAN-TEST: PASS (gates, strict WinSxS attribution, root confinement, lock-then-validate, plan, commit, archive, idempotent re-run, apply flip, pair merge, stale-row throw)'; exit 0 }
Write-Output ("REBASE-PLAN-TEST: FAIL ({0} check(s))" -f $script:fails)
exit 1
