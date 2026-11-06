# ArcIcons apply.ps1
# THE one install command (no separate finalizer step): installs the merged icon
# theme into a SystemResources directory.
# Measured mechanism per file: resolve the surviving WinSxS sibling with
# `fsutil hardlink list` BEFORE mutating (takeown touches the shared inode),
# journal the intent to logs\apply.journal.jsonl, then take ownership ->
# grant Administrators:F -> unlink (delete the hardlink; the WinSxS payload
# survives) -> copy the staged file in -> restore the COMPLETE baseline
# security descriptor (owner + group + DACL + protection flag, verified by full
# SDDL compare) on BOTH the new file AND the surviving sibling -> assert live
# hash == mergedSha256. Owner/group writes use privileges enabled IN-PROCESS
# (SeRestorePrivilege/SeBackupPrivilege/SeTakeOwnershipPrivilege via
# AdjustTokenPrivileges; a child process like `icacls /setowner` fails without
# that). NEVER writes through the hardlink.
# Directory ACL (measured): Administrators hold only read+execute on the live
# SystemResources directory and SeRestorePrivilege does NOT bypass it for
# creating a name, so the directory is takeown'd + granted Administrators:F
# before the first file and its baseline SDDL
# (originals\acl\SystemResources.dir.sddl) is restored in a `finally` (the
# D:PAI baseline's AI bit cannot be reproduced by the write — that one
# access-neutral control-bit difference is journaled, not hidden).
# Holders: a live file mapped by a running process cannot be deleted (share
# lock, not ACL); holders come from the Restart Manager API and are named in
# the failure; -CloseHolders stops them immediately before replacing that file.
# Icon cache: ie4uinit -show alone is NOT enough — for EVERY logged-on profile,
# iconcache*.db AND thumbcache*.db are deleted and that profile's explorer is
# restarted inside its own session (see bin\ArcIcons-UserRefresh.ps1; skipped
# for sandbox runs / -SkipIconCacheRefresh).
# Shell guarantee: every exit path runs Restore-ArcIconsShell, so explorer.exe is
# never left stopped (verified restart, pid reported — see Set-BaselineSecurity).
# Preflight (pristine/stage hashes, 3 unique allowlisted names, owner+SDDL
# present and parseable, sibling captured before mutation) is UNCONDITIONAL:
# -Force can never bypass it. -Force only overrides an unexpected LIVE hash (or
# a missing live file, which is then created). Any mid-sequence failure rolls
# back the files already mutated to the pristine originals, records state.json
# mode=partial, and fails loudly.
# Serialized with restore.ps1 / repair.ps1 via logs\ArcIcons.lock.
# Supersedes bin\Live-Install.ps1 + bin\Finalize-Security.ps1 (kept as measured
# reference only).
# First install: on a provably-fresh machine (no state.json AND no
# installed-manifest.json AND no originals\) the single apply captures the
# pristine originals from -SystemResourceDir, merges -Variant (default arc),
# applies and verifies - no separate capture step, no restore step (nothing is
# installed yet). Partial state (any of the three present while
# originals\manifest.json is missing) refuses with the preflight reason below;
# -Force can never bypass that. -DryRun on a fresh machine refuses: a first
# install must write (capture + merge), so there is no preview.
# -Yes is accepted for controller/proof compatibility; apply never prompts.
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Force,
  [switch]$CloseHolders,
  [switch]$SkipIconCacheRefresh,
  [string]$Root = (Join-Path $env:ProgramData 'ArcIcons'),
  [string]$SystemResourceDir = (Join-Path $env:SystemRoot 'SystemResources'),
  [string]$Variant = 'dark-grey',
  [switch]$Yes,
  [switch]$NoLock
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bin\Set-BaselineSecurity.ps1')
$DefaultRoot = Join-Path $env:ProgramData 'ArcIcons'

function Fail-Apply([string]$Msg) {
  [Console]::Error.WriteLine($Msg)
  # shell guarantee: NO exit path — preflight, refusal, lock, failure — may
  # leave explorer.exe stopped.
  [void](Restore-ArcIconsShell 'apply.ps1 exit')
  exit 1
}

# ---- F4 path confinement: canonicalize everything, no cross-root fallback ----
$RootC = Resolve-ArcIconsCanonicalPath $Root
$DefaultRootC = Resolve-ArcIconsCanonicalPath $DefaultRoot
if (($RootC -ine $DefaultRootC) -and (-not $PSBoundParameters.ContainsKey('SystemResourceDir'))) {
  Fail-Apply 'ARC-ICONS-APPLY: FAIL sandbox run requires an explicit -SystemResourceDir. No changes made.'
}
$SysC = Resolve-ArcIconsCanonicalPath $SystemResourceDir
if (-not (Test-Path -LiteralPath $SysC -PathType Container)) {
  Fail-Apply ("ARC-ICONS-APPLY: FAIL SystemResourceDir not found: {0}. No changes made." -f $SysC)
}

# ---- F2 unconditional preflight (-Force can NOT bypass any of this) ----
$origManPath = Join-Path $RootC 'originals\manifest.json'
$instManPath = Join-Path $RootC 'installed-manifest.json'
$VariantInfo = Get-ArcIconsVariantInfo $Variant
if (-not $VariantInfo) {
  Fail-Apply ("ARC-ICONS-APPLY: FAIL unknown -Variant '{0}'. Allowed: arc | arc-symbolic | neutral-brown | neutral-grey | dark-grey (the display names work too). No changes made." -f $Variant)
}
$wasFreshInstall = $false
try {
  if (Test-ArcIconsFreshInstall $RootC) {
    if ($DryRun) { throw 'fresh machine (no state.json, no installed-manifest.json, no originals\): -DryRun cannot preview a first install because capture + merge must write. Re-run without -DryRun.' }
    $wasFreshInstall = $true
    Write-Output 'ARC-ICONS-APPLY: fresh machine (no state.json, no installed-manifest.json, no originals\) - capture -> merge -> apply -> verify.'
    Invoke-ArcIconsOriginalsCapture $RootC $SysC $VariantInfo
    Write-Output ("ARC-ICONS-APPLY: fresh-machine merge for variant '{0}'" -f $VariantInfo.Display)
    $mergePs = Join-Path $PSScriptRoot 'bin\Merge-IconTheme.ps1'
    & $mergePs -Root $RootC -Build -Variant $VariantInfo.Id
    $mergeOk = $?
    if (-not $mergeOk) {
      $mergeCode = $LASTEXITCODE
      if (-not $mergeCode) { $mergeCode = 1 }
      throw ("fresh-machine merge FAILED (exit {0}) for variant '{1}'; nothing applied." -f $mergeCode, $VariantInfo.Display)
    }
  }
  if (-not (Test-Path -LiteralPath $origManPath -PathType Leaf)) { throw 'originals\manifest.json not found.' }
  $origMan = Read-ArcIconsJsonFile $origManPath
  Assert-ArcIconsOriginalsManifest $origMan
  if (-not (Test-Path -LiteralPath $instManPath -PathType Leaf)) { throw 'installed-manifest.json not found (merge worker has not landed it yet).' }
  $instMan = Read-ArcIconsJsonFile $instManPath
  Assert-ArcIconsInstalledManifest $instMan
  $baseline = @{}
  foreach ($b in $origMan.files) {
    $nm = [string]$b.name
    if (-not [string]$b.owner) { throw ("{0}: baseline owner missing." -f $nm) }
    if (-not [string]$b.sddl) { throw ("{0}: baseline sddl missing." -f $nm) }
    try { [void](New-Object System.Security.AccessControl.RawSecurityDescriptor([string]$b.sddl)) }
    catch { throw ("{0}: baseline sddl does not parse: {1}" -f $nm, $_.Exception.Message) }
    if (-not [string]$b.originalSha256) { throw ("{0}: originalSha256 missing." -f $nm) }
    if (-not [string]$b.originalPath) { throw ("{0}: originalPath missing." -f $nm) }
    $src = Resolve-ArcIconsCanonicalPath (Join-Path $RootC ([string]$b.originalPath))
    if (-not (Test-ArcIconsPathInside $src $RootC)) { throw ("{0}: originalPath escapes -Root." -f $nm) }
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw ("{0}: pristine backup missing ({1})." -f $nm, $b.originalPath) }
    $sh = Get-ArcIconsSha256 $src
    if ($sh -ne ([string]$b.originalSha256).ToUpperInvariant()) { throw ("{0}: pristine backup hash {1} != manifest original {2}." -f $nm, $sh, $b.originalSha256) }
    $baseline[$nm] = $b
  }
  $staged = @{}
  foreach ($f in $instMan.files) {
    $nm = [string]$f.name
    $base = $baseline[$nm]
    if (-not $base) { throw ("{0}: no baseline entry in originals manifest." -f $nm) }
    if (-not [string]$f.stagePath) { throw ("{0}: stagePath missing." -f $nm) }
    if (-not [string]$f.mergedSha256) { throw ("{0}: mergedSha256 missing." -f $nm) }
    $st = Resolve-ArcIconsCanonicalPath (Join-Path $RootC ([string]$f.stagePath))
    if (-not (Test-ArcIconsPathInside $st $RootC)) { throw ("{0}: stagePath escapes -Root." -f $nm) }
    if (-not (Test-Path -LiteralPath $st -PathType Leaf)) { throw ("{0}: staged file missing ({1})." -f $nm, $f.stagePath) }
    $sh = Get-ArcIconsSha256 $st
    if ($sh -ne ([string]$f.mergedSha256).ToUpperInvariant()) { throw ("{0}: staged hash {1} != manifest merged {2}." -f $nm, $sh, $f.mergedSha256) }
    $staged[$nm] = $st
  }
} catch {
  Fail-Apply ("ARC-ICONS-APPLY: PREFLIGHT FAIL {0} (-Force cannot bypass; no changes made.)" -f $_)
}

# ---- live plan: ONLY the live-hash check is -Force-overridable ----
$plan = @()
$refusals = @()
foreach ($f in $instMan.files) {
  $nm = [string]$f.name
  $live = Resolve-ArcIconsCanonicalPath (Join-Path $SysC $nm)
  if (-not (Test-ArcIconsPathInside $live $SysC)) { $refusals += ("{0}: destination escapes -SystemResourceDir." -f $nm); continue }
  $liveHash = $null
  $missing = $false
  if (Test-Path -LiteralPath $live -PathType Leaf) {
    try { $liveHash = Get-ArcIconsSha256 $live }
    catch { $refusals += ("{0}: live hash unreadable ({1})." -f $nm, $_.Exception.Message); continue }
  } else { $missing = $true }
  $wantOrig = ([string]$baseline[$nm].originalSha256).ToUpperInvariant()
  $wantMerged = ([string]$f.mergedSha256).ToUpperInvariant()
  if ($missing) { $refusals += ("{0}: live file missing ({1})." -f $nm, $live) }
  elseif (($liveHash -ne $wantOrig) -and ($liveHash -ne $wantMerged)) {
    $refusals += ("{0}: live hash {1} is neither recorded original nor recorded merged." -f $nm, $liveHash)
  }
  $plan += [pscustomobject]@{ Name = $nm; Live = $live; LiveHash = $liveHash; Missing = $missing; Stage = $staged[$nm]; WantMerged = $wantMerged; Baseline = $baseline[$nm] }
}
if (($refusals.Count -gt 0) -and (-not $Force)) {
  Fail-Apply ("ARC-ICONS-APPLY: REFUSED, no changes made:`n  " + ($refusals -join "`n  ") + "`nRe-run with -Force to override the LIVE-hash refusals above (preflight failures can never be overridden).`nSwitching variants? Run ARC-Icons.ps1 -Action apply -Variant <arc|arc-symbolic|neutral-brown|neutral-grey|dark-grey> -Yes: it re-merges that variant, restores the pristine originals, then applies.")
}
if ($DryRun) {
  Write-Output 'ARC-ICONS-APPLY: DRY-RUN plan (no changes made)'
  Write-Output ("  directory: take ownership + grant Administrators:F on {0}, restore baseline SDDL afterwards" -f $SysC)
  foreach ($p in $plan) {
    $act = 'takeown -> unlink -> copy -> restore baseline SD on new file + surviving sibling'
    if ($p.Missing) { $act = 'CREATE from stage -> restore baseline SD (live was missing; -Force given)' }
    Write-Output ("  {0}`n    live : {1} [{2}]`n    stage: {3} [{4}]`n    act  : {5}" -f $p.Name, $p.Live, $p.LiveHash, $p.Stage, $p.WantMerged, $act)
  }
  Write-Output ("  holders: " + ($(if ($CloseHolders) { '-CloseHolders given: mapped files stop their holders first' } else { 'mapped live files FAIL naming their Restart-Manager holders (re-run with -CloseHolders)' })))
  Write-Output ("  icon cache: " + ($(if ($SkipIconCacheRefresh) { 'skipped (-SkipIconCacheRefresh)' } elseif ($SysC -ine (Resolve-ArcIconsCanonicalPath (Join-Path $env:SystemRoot 'SystemResources'))) { 'skipped (non-live SystemResourceDir)' } else { 'delete iconcache*.db + restart explorer' })))
  exit 0
}

# ---- F1/F3/F5 mutate: journal before each change, lock, rollback on failure ----
$logDir = Join-Path $RootC 'logs'
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$lockHeld = $false
if (-not $NoLock) {
  try { [void](Acquire-ArcIconsLock $logDir 90); $lockHeld = $true }
  catch { Fail-Apply ("ARC-ICONS-APPLY: FAIL lock: {0}" -f $_) }
}
$mutated = @()
$failedName = $null
$dirTaken = $false
$dirBaseline = $null
try {
  $dirBaseline = Resolve-ArcIconsDirBaselineSddl $SysC $RootC
  Enable-ArcIconsPrivileges | Out-Null
  Take-ArcIconsDirAcl $SysC; $dirTaken = $true
  Write-ArcIconsJournal $logDir 'apply.journal.jsonl' ([ordered]@{
    ts = (Get-Date).ToString('o'); op = 'take-dir-acl'; dir = $SysC
  })
  $results = @()
  foreach ($p in $plan) {
    $failedName = $p.Name
    if ((-not $p.Missing) -and (Test-ArcIconsLocked $p.Live)) {
      $hids = @(Get-ArcIconsHolders @($p.Live))
      $hnames = @(Get-ArcIconsHolderNames $hids)
      if ($CloseHolders) {
        foreach ($id in $hids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 400
      }
      if (Test-ArcIconsLocked $p.Live) { throw ("{0}: live file is mapped by a running process (holders: {1}); re-run with -CloseHolders to stop them first." -f $p.Name, ($hnames -join ',')) }
    }
    $siblings = @()
    if (-not $p.Missing) { $siblings = @(Get-ArcIconsHardlinkTargets $p.Live) }
    $winsxs = Get-ArcIconsWinSxSSibling $p.Live $siblings
    $action = 'replace'
    if ($p.Missing) { $action = 'create' }
    Write-ArcIconsJournal $logDir 'apply.journal.jsonl' ([ordered]@{
      ts = (Get-Date).ToString('o'); op = 'apply'; action = $action; name = $p.Name; live = $p.Live;
      liveHashBefore = $p.LiveHash; stage = $p.Stage; wantMerged = $p.WantMerged;
      baselineSddl = [string]$p.Baseline.sddl; winSxSSibling = $winsxs; forced = [bool]$Force
      closeHolders = [bool]$CloseHolders
    })
    if (-not $p.Missing) {
      & takeown.exe /f $p.Live | Out-Null
      if ($LASTEXITCODE -ne 0) { throw ("takeown failed for {0} (exit {1})." -f $p.Live, $LASTEXITCODE) }
      & icacls.exe $p.Live /grant '*S-1-5-32-544:F' | Out-Null
      if ($LASTEXITCODE -ne 0) { throw ("icacls grant failed for {0} (exit {1})." -f $p.Live, $LASTEXITCODE) }
      Remove-Item -Force -LiteralPath $p.Live
    }
    Copy-Item -Force -LiteralPath $p.Stage -Destination $p.Live
    Set-ArcIconsBaselineSecurity $p.Live ([string]$p.Baseline.sddl) | Out-Null
    if ($winsxs -and (Test-Path -LiteralPath $winsxs -PathType Leaf)) {
      Set-ArcIconsBaselineSecurity $winsxs ([string]$p.Baseline.sddl) | Out-Null
    }
    $after = Get-ArcIconsSha256 $p.Live
    if ($after -ne $p.WantMerged) { throw ("{0}: live hash {1} != merged {2} after copy." -f $p.Name, $after, $p.WantMerged) }
    if (-not (Test-ArcIconsBaselineSecurity $p.Live ([string]$p.Baseline.sddl))) { throw ("{0}: post-apply SDDL mismatch on {1}." -f $p.Name, $p.Live) }
    if ($winsxs -and (Test-Path -LiteralPath $winsxs -PathType Leaf)) {
      if (-not (Test-ArcIconsBaselineSecurity $winsxs ([string]$p.Baseline.sddl))) { throw ("{0}: post-apply SDDL mismatch on surviving sibling {1}." -f $p.Name, $winsxs) }
    }
    $owner = (Get-Acl -LiteralPath $p.Live).Owner
    $mutated += $p
    $results += [pscustomobject]@{ name = $p.Name; before = $p.LiveHash; after = $after; owner = $owner }
    Write-Output ("  {0}: {1} -> {2} owner={3}" -f $p.Name, $p.LiveHash, $after, $owner)
    $failedName = $null
  }
  $state = [ordered]@{
    mode      = 'installed'
    appliedAt = (Get-Date).ToString('o')
    files     = @($results | ForEach-Object { [ordered]@{ name = $_.name; liveSha256 = $_.after; owner = $_.owner } })
  }
  $state | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $RootC 'state.json')
  Write-ArcIconsJournal $logDir 'apply.jsonl' ([ordered]@{
    ts = (Get-Date).ToString('o'); op = 'apply'; mode = 'installed'
    dryRun = $false; forced = [bool]$Force; result = 'ok'
    files = @($results | ForEach-Object { [ordered]@{ name = $_.name; before = $_.before; after = $_.after; owner = $_.owner } })
  })
  # post-state refresh: never let a shell hiccup throw into the rollback catch
  # (the payload is already installed and state.json already says installed).
  try { $cacheNote = Invoke-ArcIconsIconCacheRefresh $SysC ([bool]$SkipIconCacheRefresh) $RootC }
  catch { $cacheNote = ("icon-cache refresh failed: {0}" -f $_) }
  Write-ArcIconsJournal $logDir 'apply.journal.jsonl' ([ordered]@{
    ts = (Get-Date).ToString('o'); op = 'icon-cache-refresh'; note = $cacheNote
  })
  Write-Output ("  icon cache: {0}" -f $cacheNote)
  Write-Output 'ARC-ICONS-APPLY: OK'
} catch {
  $errMsg = "$_"
  $rbTargets = @($mutated)
  $failedEntry = @($plan | Where-Object { $_.Name -eq $failedName })
  if (($failedEntry.Count -gt 0) -and ((@($mutated | Where-Object { $_.Name -eq $failedName })).Count -eq 0)) {
    $fe = $failedEntry[0]
    $include = $true
    if (Test-Path -LiteralPath $fe.Live -PathType Leaf) {
      try { $lhNow = Get-ArcIconsSha256 $fe.Live } catch { $lhNow = '<unreadable>' }
      if ($lhNow -eq $fe.LiveHash) { $include = $false }
    }
    if ($include) { $rbTargets += $fe }
  }
  $rbFails = @()
  for ($i = $plan.Count - 1; $i -ge 0; $i--) {
    $rp = $plan[$i]
    if ((@($rbTargets | Where-Object { $_.Name -eq $rp.Name })).Count -eq 0) { continue }
    try {
      $rsibs = @(Get-ArcIconsHardlinkTargets $rp.Live)
      $rwin = Get-ArcIconsWinSxSSibling $rp.Live $rsibs
      $pristine = Resolve-ArcIconsCanonicalPath (Join-Path $RootC ([string]$rp.Baseline.originalPath))
      $wantOrig = ([string]$rp.Baseline.originalSha256).ToUpperInvariant()
      Write-ArcIconsJournal $logDir 'apply.journal.jsonl' ([ordered]@{
        ts = (Get-Date).ToString('o'); op = 'apply-rollback'; name = $rp.Name; live = $rp.Live;
        pristine = $pristine; wantOriginal = $wantOrig; winSxSSibling = $rwin
      })
      if (Test-Path -LiteralPath $rp.Live -PathType Leaf) {
        & takeown.exe /f $rp.Live | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ("rollback takeown failed for {0}." -f $rp.Live) }
        & icacls.exe $rp.Live /grant '*S-1-5-32-544:F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ("rollback icacls grant failed for {0}." -f $rp.Live) }
        Remove-Item -Force -LiteralPath $rp.Live
      }
      Copy-Item -Force -LiteralPath $pristine -Destination $rp.Live
      Set-ArcIconsBaselineSecurity $rp.Live ([string]$rp.Baseline.sddl) | Out-Null
      if ($rwin -and (Test-Path -LiteralPath $rwin -PathType Leaf)) {
        Set-ArcIconsBaselineSecurity $rwin ([string]$rp.Baseline.sddl) | Out-Null
      }
      $rh = Get-ArcIconsSha256 $rp.Live
      if ($rh -ne $wantOrig) { throw ("rollback hash {0} != original {1}." -f $rh, $wantOrig) }
    } catch { $rbFails += ("{0}: rollback failed: {1}" -f $rp.Name, $_) }
  }
  $sfiles = @()
  foreach ($e in $plan) {
    $st = 'pending'
    if ((@($mutated | Where-Object { $_.Name -eq $e.Name })).Count -gt 0) { $st = 'applied-then-rolled-back' }
    elseif ($e.Name -eq $failedName) { $st = 'failed' }
    $lh = '<missing>'
    if (Test-Path -LiteralPath $e.Live -PathType Leaf) {
      try { $lh = Get-ArcIconsSha256 $e.Live } catch { $lh = '<unreadable>' }
    }
    $sfiles += [ordered]@{ name = $e.Name; status = $st; liveSha256 = $lh }
  }
  ([ordered]@{
    mode = 'partial'; op = 'apply'; error = $errMsg
    completedAt = (Get-Date).ToString('o'); files = $sfiles
  } | ConvertTo-Json -Depth 5) | Set-Content -Encoding utf8 -LiteralPath (Join-Path $RootC 'state.json')
  Write-ArcIconsJournal $logDir 'apply.jsonl' ([ordered]@{
    ts = (Get-Date).ToString('o'); op = 'apply'; mode = 'partial'
    dryRun = $false; forced = [bool]$Force; result = 'failed'; error = $errMsg
    rolledBack = @($rbTargets | ForEach-Object { $_.Name }); rollbackFailures = @($rbFails)
  })
  $msg = ("ARC-ICONS-APPLY: FAIL {0}`n  Rolled back {1} file(s) to pristine originals; state.json mode=partial." -f $errMsg, $rbTargets.Count)
  if ($rbFails.Count -gt 0) { $msg += ("`n  ROLLBACK FAILURES:`n  " + ($rbFails -join "`n  ")) }
  Fail-Apply $msg
} finally {
  if ($dirTaken) {
    $dr = Restore-ArcIconsDirAcl $SysC $dirBaseline
    Write-ArcIconsJournal $logDir 'apply.journal.jsonl' ([ordered]@{
      ts = (Get-Date).ToString('o'); op = 'restore-dir-acl'; dir = $SysC
      exact = $dr.Exact; aceMatch = $dr.AceMatch; note = $dr.Note; sddl = $dr.After
    })
    Write-Output ("  directory ACL restored: exact={0} aceMatch={1} {2}" -f $dr.Exact, $dr.AceMatch, $dr.Note)
  }
  # shell guarantee: runs on success, failure, refusal and interrupt alike
  [void](Restore-ArcIconsShell 'apply.ps1 finally')
  if ($lockHeld) { Release-ArcIconsLock $logDir }
}

# Fresh-machine tail: the chain above already merged + applied + recorded
# state.json; verify the installed payload now (read-only). Runs only when the
# apply itself succeeded - any failure above exited inside Fail-Apply, never
# here - so a verify FAIL reports without rolling back the installed files.
if ($wasFreshInstall) {
  Write-Output 'ARC-ICONS-APPLY: fresh-machine verify'
  $verifyPs = Join-Path $PSScriptRoot 'verify.ps1'
  $vout = & $verifyPs -Root $RootC -SystemResourceDir $SysC 2>&1
  $vok = $?
  $vcode = $LASTEXITCODE
  foreach ($line in @($vout)) { Write-Output ("  " + $line) }
  if (-not $vok) {
    if (-not $vcode) { $vcode = 1 }
    Fail-Apply ("ARC-ICONS-VERIFY: FAILED (exit {0}) after first install; the payload IS installed (state.json mode=installed) but does not verify - read the FAIL lines above." -f $vcode)
  }
}
