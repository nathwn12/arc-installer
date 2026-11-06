# ArcIcons repair.ps1
# Auto-repair entry point (run by Scheduled Task ArcIcons-Repair as SYSTEM).
# Reads state.json + both manifests and classifies each live file:
#   live == mergedSha256   -> healthy, nothing to do;
#   live == originalSha256 -> safe re-apply (the payload this theme was built
#                             from is still there; apply.ps1 needs no -Force);
#   anything else (e.g. a newer Windows Update payload, or a missing file)
#                             -> drift-unknown-payload: writes NOTHING, records
#                             state.json mode=drifted, logs it, exits 0.
# Repair NEVER force-overwrites an unknown payload: clobbering a newer Windows
# payload with a stale merged theme would regress OS resources. A drifted
# machine needs a human re-merge (see README), not an automatic overwrite.
# Serialized with apply.ps1 / restore.ps1 via logs\ArcIcons.lock (held across
# the nested apply call via its internal -NoLock switch).
[CmdletBinding()]
param(
  [string]$Root = (Join-Path $env:ProgramData 'ArcIcons'),
  [string]$SystemResourceDir = (Join-Path $env:SystemRoot 'SystemResources'),
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bin\Set-BaselineSecurity.ps1')
$DefaultRoot = Join-Path $env:ProgramData 'ArcIcons'

function Fail-Repair([string]$Msg) { [Console]::Error.WriteLine($Msg); exit 1 }

$RootC = Resolve-ArcIconsCanonicalPath $Root
$DefaultRootC = Resolve-ArcIconsCanonicalPath $DefaultRoot
if (($RootC -ine $DefaultRootC) -and (-not $PSBoundParameters.ContainsKey('SystemResourceDir'))) {
  Fail-Repair 'ARC-ICONS-REPAIR: FAIL sandbox run requires an explicit -SystemResourceDir. No changes made.'
}
$SysC = Resolve-ArcIconsCanonicalPath $SystemResourceDir
if (-not (Test-Path -LiteralPath $SysC -PathType Container)) {
  Fail-Repair ("ARC-ICONS-REPAIR: FAIL SystemResourceDir not found: {0}. No changes made." -f $SysC)
}

$logDir = Join-Path $RootC 'logs'
$lockHeld = $false
if ($DryRun) {
  # Preview only: no lock file, no log dir, no writes of any kind.
  $logDir = $null
} else {
  if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
  try { [void](Acquire-ArcIconsLock $logDir 90); $lockHeld = $true }
  catch { Fail-Repair ("ARC-ICONS-REPAIR: FAIL lock: {0}" -f $_) }
}

try {
  $statePath = Join-Path $RootC 'state.json'
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    if ($DryRun) { Write-Output 'ARC-ICONS-REPAIR-DRYRUN: no-action (no state.json); wrote NOTHING.'; exit 0 }
    Write-ArcIconsJournal $logDir 'repair.jsonl' ([ordered]@{ ts = (Get-Date).ToString('o'); op = 'repair'; verdict = 'no-action'; reason = 'state.json absent; nothing installed by this tooling' })
    Write-Output 'ARC-ICONS-REPAIR: no-action (no state.json).'
    exit 0
  }
  $mode = [string]((Read-ArcIconsJsonFile $statePath).mode)
  if ($mode -ne 'installed') {
    if ($DryRun) { Write-Output ("ARC-ICONS-REPAIR-DRYRUN: no-action (mode={0}); wrote NOTHING." -f $mode); exit 0 }
    Write-ArcIconsJournal $logDir 'repair.jsonl' ([ordered]@{ ts = (Get-Date).ToString('o'); op = 'repair'; verdict = 'no-action'; reason = "mode=$mode; theme not installed" })
    Write-Output ("ARC-ICONS-REPAIR: no-action (mode={0})." -f $mode)
    exit 0
  }

  $origManPath = Join-Path $RootC 'originals\manifest.json'
  $instManPath = Join-Path $RootC 'installed-manifest.json'
  if (-not (Test-Path -LiteralPath $origManPath -PathType Leaf)) { Fail-Repair 'ARC-ICONS-REPAIR: FAIL originals\manifest.json not found.' }
  if (-not (Test-Path -LiteralPath $instManPath -PathType Leaf)) { Fail-Repair 'ARC-ICONS-REPAIR: FAIL installed-manifest.json not found.' }
  try {
    $origMan = Read-ArcIconsJsonFile $origManPath
    Assert-ArcIconsOriginalsManifest $origMan
    $instMan = Read-ArcIconsJsonFile $instManPath
    Assert-ArcIconsInstalledManifest $instMan
  } catch { Fail-Repair ("ARC-ICONS-REPAIR: FAIL manifest completeness: {0}" -f $_) }
  $baseline = @{}
  foreach ($b in $origMan.files) { $baseline[[string]$b.name] = $b }

  $before = [ordered]@{}
  $classOf = [ordered]@{}
  $unknown = @()
  $originals = @()
  foreach ($f in $instMan.files) {
    $nm = [string]$f.name
    $live = Resolve-ArcIconsCanonicalPath (Join-Path $SysC $nm)
    if (-not (Test-ArcIconsPathInside $live $SysC)) { Fail-Repair ("ARC-ICONS-REPAIR: FAIL {0}: destination escapes -SystemResourceDir." -f $nm) }
    $h = '<missing>'
    if (Test-Path -LiteralPath $live -PathType Leaf) {
      try { $h = Get-ArcIconsSha256 $live } catch { $h = '<unreadable>' }
    }
    $before[$nm] = $h
    $wantMerged = ([string]$f.mergedSha256).ToUpperInvariant()
    $wantOrig = ([string]$baseline[$nm].originalSha256).ToUpperInvariant()
    if ($h -eq $wantMerged) { $classOf[$nm] = 'merged' }
    elseif ($h -eq $wantOrig) { $classOf[$nm] = 'original'; $originals += $nm }
    else { $classOf[$nm] = 'unknown'; $unknown += $nm }
  }

  if ($DryRun) {
    # Classification only: per-file verdict, no journal, no state.json, no nested apply.
    foreach ($nm in @($classOf.Keys | Sort-Object)) {
      $verdict = 'drift'
      if ($classOf[$nm] -eq 'merged') { $verdict = 'healthy' }
      elseif ($classOf[$nm] -eq 'original') { $verdict = 'original' }
      Write-Output ("ARC-ICONS-REPAIR-DRYRUN: {0} {1} live={2}" -f $nm, $verdict, $before[$nm])
    }
    Write-Output 'ARC-ICONS-REPAIR-DRYRUN: preview only; wrote NOTHING.'
    exit 0
  }

  if ($unknown.Count -eq 0 -and $originals.Count -eq 0) {
    Write-ArcIconsJournal $logDir 'repair.jsonl' ([ordered]@{ ts = (Get-Date).ToString('o'); op = 'repair'; verdict = 'no-action'; reason = 'all live hashes == mergedSha256'; before = $before })
    Write-Output 'ARC-ICONS-REPAIR: no-action (live files match merged theme).'
    exit 0
  }

  if ($unknown.Count -gt 0) {
    $uinfo = @()
    foreach ($n in $unknown) { $uinfo += ("{0} live={1}" -f $n, $before[$n]) }
    ([ordered]@{
      mode = 'drifted'; op = 'repair'
      reason = 'live payload matches neither mergedSha256 nor originalSha256; NOT overwritten (re-merge required)'
      completedAt = (Get-Date).ToString('o')
      files = @($unknown | ForEach-Object { [ordered]@{ name = $_; status = 'drift-unknown-payload'; liveSha256 = $before[$_] } })
    } | ConvertTo-Json -Depth 5) | Set-Content -Encoding utf8 -LiteralPath $statePath
    Write-ArcIconsJournal $logDir 'repair.jsonl' ([ordered]@{
      ts = (Get-Date).ToString('o'); op = 'repair'; verdict = 'drift-unknown-payload'
      reason = 'live payload is unknown; wrote NOTHING (state.json mode=drifted)'
      before = $before; classes = $classOf; files = @($unknown)
    })
    Write-Output ("ARC-ICONS-REPAIR: drift-unknown-payload ({0}); wrote NOTHING; state.json mode=drifted." -f ($uinfo -join '; '))
    exit 0
  }

  Write-Output ("ARC-ICONS-REPAIR: safe re-apply for original-payload drift in {0} (no -Force; live is the pristine original)." -f ($originals -join ', '))
  & (Join-Path $PSScriptRoot 'apply.ps1') -Root $RootC -SystemResourceDir $SysC -NoLock
  if ($LASTEXITCODE -ne 0) { Fail-Repair 'ARC-ICONS-REPAIR: FAIL re-apply failed (see apply output above).' }

  $after = [ordered]@{}
  $stillBad = @()
  foreach ($f in $instMan.files) {
    $nm = [string]$f.name
    $h = Get-ArcIconsSha256 (Join-Path $SysC $nm)
    $after[$nm] = $h
    if ($h -ne ([string]$f.mergedSha256).ToUpperInvariant()) { $stillBad += $nm }
  }
  if ($stillBad.Count -gt 0) {
    Write-ArcIconsJournal $logDir 'repair.jsonl' ([ordered]@{ ts = (Get-Date).ToString('o'); op = 'repair'; verdict = 'failed'; before = $before; after = $after; files = @($stillBad) })
    Fail-Repair ("ARC-ICONS-REPAIR: FAIL still mismatched: " + ($stillBad -join ', '))
  }
  Write-ArcIconsJournal $logDir 'repair.jsonl' ([ordered]@{ ts = (Get-Date).ToString('o'); op = 'repair'; verdict = 'repaired'; before = $before; after = $after; files = @($originals) })
  Write-Output ("ARC-ICONS-REPAIR: repaired {0}." -f ($originals -join ', '))
} finally {
  if ($lockHeld) { Release-ArcIconsLock $logDir }
}
