# ArcIcons install-autorepair.ps1
# Task lifecycle for Scheduled Task `ArcIcons-Repair` (SYSTEM, startup +
# 2-minute delay) that runs repair.ps1.
#
# Default verb REGISTER: idempotently registers/re-registers the task. The task
# action carries the VALIDATED ABSOLUTE -Root (canonicalized with
# [IO.Path]::GetFullPath, refused when the directory or repair.ps1 is absent)
# plus the absolute live -SystemResourceDir, and points at the absolute
# repair.ps1 path - no relative or fallback resolution at repair time. No
# network requirement; hidden. Prints the resulting task definition.
#
# -Uninstall removes the task plus the owned artifacts under -Root and then
# verifies the cleanup. It is safe by default:
#   - refuses unless the recorded state is mode=original (restore.ps1 is a
#     revert, not an uninstall: run it, or ARC-Icons.ps1 -Action uninstall,
#     first), and refuses an inconsistent state (no declared mode while
#     installed-manifest.json exists);
#   - refuses unless verify.ps1 PASSes for the same -Root/-SystemResourceDir
#     (a live hash/SD mismatch is not an uninstall candidate);
#   - removes the task through remove-autorepair.ps1 (one task name, one
#     removal path) and confirms it is gone;
#   - removes everything under -Root (tooling, state.json,
#     installed-manifest.json, originals\, stage\, logs\).
# -KeepState keeps state.json, installed-manifest.json and originals\ so a
# reinstall stays safe; everything else is still removed. -DryRun prints the
# plan and changes nothing.
#
# Windows PowerShell 5.1 compatible (no ?. / ?? / ternary / -AsHashtable).
[CmdletBinding()]
param(
  [string]$Root = (Join-Path $env:ProgramData 'ArcIcons'),
  [string]$SystemResourceDir = (Join-Path $env:SystemRoot 'SystemResources'),
  [string]$TaskName = 'ArcIcons-Repair',
  [switch]$Uninstall,
  [switch]$KeepState,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bin\Set-BaselineSecurity.ps1')

function Fail-AutoRepair([string]$Message) {
  [Console]::Error.WriteLine(("ARC-ICONS-AUTOREPAIR: FAIL {0}" -f $Message))
  exit 1
}

# Windows PowerShell 5.1 is the verified child interpreter: the installed
# payload and the exe run under it, and it removes any dependence on pwsh.exe
# being installed or on PATH.
$PSExe5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if ($Uninstall) {
  $RootC = Resolve-ArcIconsCanonicalPath $Root
  $SysC = Resolve-ArcIconsCanonicalPath $SystemResourceDir
  $taskOff = Join-Path $PSScriptRoot 'remove-autorepair.ps1'
  if (-not (Test-Path -LiteralPath $taskOff -PathType Leaf)) {
    Fail-AutoRepair ("remove-autorepair.ps1 not found beside install-autorepair.ps1 ({0})." -f $taskOff)
  }

  # Refuse a target that is not an installed data root: a drive root, the
  # Windows/Program Files tree, or a git checkout must never be dismantled.
  if ($RootC -match '^[A-Za-z]:\\?$') {
    Fail-AutoRepair ("refused -Root '{0}': a drive root is never an ArcIcons data root." -f $RootC)
  }
  $guardedDirs = @()
  $guardedDirs += [string]$env:SystemRoot
  $guardedDirs += [string]$env:ProgramFiles
  $guardedDirs += [string]${env:ProgramFiles(x86)}
  $guardedDirs += [string]$env:SystemDrive
  foreach ($guarded in $guardedDirs) {
    if (-not $guarded) { continue }
    $g = Resolve-ArcIconsCanonicalPath $guarded
    if (($RootC -ieq $g) -or (Test-ArcIconsPathInside $g $RootC)) {
      Fail-AutoRepair ("refused -Root '{0}': it is or contains the system tree '{1}'." -f $RootC, $g)
    }
  }
  $defaultRootC = Resolve-ArcIconsCanonicalPath (Join-Path $env:ProgramData 'ArcIcons')
  if (($RootC -ine $defaultRootC) -and (Test-Path -LiteralPath (Join-Path $RootC '.git'))) {
    Fail-AutoRepair ("refused -Root '{0}': it is a git checkout; uninstall targets the installed data root, never the source tree." -f $RootC)
  }

  # Gate 1: state must say original, and must not be inconsistent.
  $statePath = Join-Path $RootC 'state.json'
  $instManPath = Join-Path $RootC 'installed-manifest.json'
  $mode = 'original'
  $modeDeclared = $false
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Read-ArcIconsJsonFile $statePath }
    catch { Fail-AutoRepair ("state.json unreadable: {0}" -f $_) }
    if ([string]$state.mode) { $mode = [string]$state.mode; $modeDeclared = $true }
  }
  Write-Output ("ARC-ICONS-AUTOREPAIR: uninstall mode={0} root={1}" -f $mode, $RootC)
  if ($modeDeclared -and ($mode -ne 'original')) {
    Fail-AutoRepair ("state.json mode={0}; uninstall only runs over a reverted theme. Run ARC-Icons.ps1 -Action uninstall (restore + per-user refresh + verify) or restore.ps1 first." -f $mode)
  }
  if ((-not $modeDeclared) -and (Test-Path -LiteralPath $instManPath -PathType Leaf)) {
    Fail-AutoRepair 'installed-manifest.json exists but state.json declares no mode: inconsistent state, so mode=original cannot be assumed. Re-run apply.ps1 or restore.ps1 to rewrite state.json, then re-run uninstall.'
  }

  # Gate 2: verify must PASS in mode=original against the live payloads.
  $verify = Join-Path $PSScriptRoot 'verify.ps1'
  if (-not (Test-Path -LiteralPath $verify -PathType Leaf)) {
    Fail-AutoRepair ("verify.ps1 not found beside install-autorepair.ps1 ({0})." -f $verify)
  }
  $verifyOut = & $PSExe5 -NoProfile -ExecutionPolicy Bypass -File $verify -Root $RootC -SystemResourceDir $SysC 2>&1
  $verifyCode = $LASTEXITCODE
  if ($verifyCode -ne 0) {
    foreach ($line in @($verifyOut)) { Write-Output ("  verify| {0}" -f $line) }
    Fail-AutoRepair ("verify.ps1 did not PASS (exit {0}); refusing to remove state over an unverified or installed theme." -f $verifyCode)
  }
  $verifyTail = @($verifyOut | Where-Object { "$_" -match '^ARC-ICONS-VERIFY: ' } | Select-Object -Last 1)
  if ($verifyTail.Count -gt 0) { Write-Output ("  {0}" -f $verifyTail[0]) }

  # Plan.
  $keepNames = @()
  if ($KeepState) { $keepNames = @('state.json', 'installed-manifest.json', 'originals') }
  $rootExisted = Test-Path -LiteralPath $RootC -PathType Container
  Write-Output ("  task   : {0}" -f $TaskName)
  if ($rootExisted) {
    Write-Output ("  remove : {0}" -f $RootC)
    foreach ($c in @(Get-ChildItem -LiteralPath $RootC -Force)) {
      if ($keepNames -contains $c.Name.ToLowerInvariant()) { Write-Output ("    keep   {0}" -f $c.FullName) }
      else { Write-Output ("    remove {0}" -f $c.FullName) }
    }
  } else {
    Write-Output ("  remove : (data root already absent: {0})" -f $RootC)
  }
  if ($DryRun) {
    Write-Output 'ARC-ICONS-AUTOREPAIR: uninstall DRYRUN PASS (nothing changed)'
    exit 0
  }

  # The task goes first: it must not fire mid-cleanup.
  & $PSExe5 -NoProfile -ExecutionPolicy Bypass -File $taskOff -TaskName $TaskName
  if ($LASTEXITCODE -ne 0) { Fail-AutoRepair ("scheduled-task removal failed (exit {0})." -f $LASTEXITCODE) }
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Fail-AutoRepair ("scheduled task '{0}' is still registered after removal." -f $TaskName)
  }

  # Remove the owned artifacts.
  $removed = @()
  $kept = @()
  if ($rootExisted) {
    foreach ($c in @(Get-ChildItem -LiteralPath $RootC -Force)) {
      if ($keepNames -contains $c.Name.ToLowerInvariant()) { $kept += $c.FullName; continue }
      try { Remove-Item -LiteralPath $c.FullName -Recurse -Force -ErrorAction Stop }
      catch { Fail-AutoRepair ("could not remove {0}: {1}" -f $c.FullName, $_) }
      $removed += $c.FullName
      Write-Output ("  removed {0}" -f $c.FullName)
    }
    if (-not $KeepState) {
      try { Remove-Item -LiteralPath $RootC -Recurse -Force -ErrorAction Stop }
      catch { Fail-AutoRepair ("could not remove the data root {0}: {1}" -f $RootC, $_) }
      $removed += $RootC
      Write-Output ("  removed {0}" -f $RootC)
    }
  }

  # Verification: the cleanup is guaranteed, not assumed.
  $left = @()
  if ($KeepState) {
    if (-not $rootExisted) { $left += ("data root missing while -KeepState was requested: {0}" -f $RootC) }
    foreach ($n in @('state.json', 'installed-manifest.json', 'originals')) {
      if (-not (Test-Path -LiteralPath (Join-Path $RootC $n))) { $left += ("keeping {0} failed" -f $n) }
    }
    foreach ($n in @('stage', 'logs', 'bin', 'theme')) {
      if (Test-Path -LiteralPath (Join-Path $RootC $n)) { $left += ("{0}\ still present" -f $n) }
    }
  } else {
    if (Test-Path -LiteralPath $RootC) { $left += ("{0} still present" -f $RootC) }
  }
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    $left += ("scheduled task '{0}' still registered" -f $TaskName)
  }
  if ($left.Count -gt 0) {
    foreach ($l in $left) { Write-Output ("  leftover: {0}" -f $l) }
    Fail-AutoRepair 'cleanup incomplete; see the leftover lines above.'
  }

  Write-Output ("ARC-ICONS-AUTOREPAIR: uninstall removed {0} item(s); scheduled task '{1}' confirmed absent." -f $removed.Count, $TaskName)
  if ($kept.Count -gt 0) {
    Write-Output '  kept (reinstall-safe):'
    foreach ($k in $kept) { Write-Output ("    {0}" -f $k) }
  }
  Write-Output 'ARC-ICONS-AUTOREPAIR: uninstall PASS'
  exit 0
}

# ---- default verb: register ----
$RootC = Resolve-ArcIconsCanonicalPath $Root
if (-not (Test-Path -LiteralPath $RootC -PathType Container)) {
  Fail-AutoRepair ("-Root not found: {0}." -f $RootC)
}
$repair = Resolve-ArcIconsCanonicalPath (Join-Path $RootC 'repair.ps1')
if (-not (Test-ArcIconsPathInside $repair $RootC)) {
  Fail-AutoRepair ("repair.ps1 escapes -Root: {0}." -f $repair)
}
if (-not (Test-Path -LiteralPath $repair -PathType Leaf)) {
  Fail-AutoRepair ("{0} not found." -f $repair)
}
$sysdir = Resolve-ArcIconsCanonicalPath $SystemResourceDir

$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$repair`" -Root `"$RootC`" -SystemResourceDir `"$sysdir`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT2M'
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) { Write-Output "ARC-ICONS-AUTOREPAIR: task exists; re-registering (idempotent)." }
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'ArcIcons: re-apply merged icon theme only when the live payload is the pristine original it was built from (unknown post-update payloads are left alone).' -Force | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
Write-Output 'ARC-ICONS-AUTOREPAIR: registered.'
Write-Output ("  TaskName : {0}`n  Path     : {1}`n  State    : {2}" -f $task.TaskName, $task.TaskPath, $task.State)
foreach ($a in $task.Actions) { Write-Output ("  Action   : {0} {1}" -f $a.Execute, $a.Arguments) }
foreach ($t in $task.Triggers) { Write-Output ("  Trigger  : AtStartup Delay={0} Enabled={1}" -f $t.Delay, $t.Enabled) }
Write-Output ("  Principal: {0} LogonType={1} RunLevel={2}" -f $task.Principal.UserId, $task.Principal.LogonType, $task.Principal.RunLevel)
Write-Output ("  Settings : Hidden={0} DisallowStartIfOnBatteries={1} StopIfGoingOnBatteries={2} StartWhenAvailable={3} RunOnlyIfNetworkAvailable={4}" -f $task.Settings.Hidden, $task.Settings.DisallowStartIfOnBatteries, $task.Settings.StopIfGoingOnBatteries, $task.Settings.StartWhenAvailable, $task.Settings.RunOnlyIfNetworkAvailable)
if ($info) { Write-Output ("  LastRun  : {0} LastResult={1} NextRun={2}" -f $info.LastRunTime, $info.LastTaskResult, $info.NextRunTime) }
