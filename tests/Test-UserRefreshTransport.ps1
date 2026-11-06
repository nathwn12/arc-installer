# Test-UserRefreshTransport.ps1
# Proves the cross-session transport the installer uses to refresh ANOTHER
# user's icon cache from an elevated context: a one-shot scheduled task with an
# InteractiveToken principal, started for the target session's user, running
# bin\Refresh-UserIconCache.ps1 in -DryRun mode.
#
# Why -DryRun: the full worker stops and restarts that user's explorer. This test
# proves the transport and the profile/token resolution WITHOUT touching a shell
# (the explorer pid set must be unchanged afterwards). The real cache drop runs
# only on a live install/uninstall, which this repo never performs as a test.
#
# Requires: elevated (registers a task) and at least one logged-on interactive
# profile. Exit 0 = PASS, 1 = FAIL. Windows PowerShell 5.1 compatible.
# Run: powershell -NoProfile -File tests\Test-UserRefreshTransport.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'bin\ArcIcons-UserRefresh.ps1')

function Fail([string]$Message) {
  Write-Output ('REFRESH-TRANSPORT: FAIL - ' + $Message)
  exit 1
}

$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($me)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Fail 'requires an elevated shell (a scheduled task must be registered)'
}
if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
  Fail 'ScheduledTasks module unavailable'
}

$profiles = @(Get-ArcIconsLoggedOnProfiles | Where-Object { $_.Resolved })
if ($profiles.Count -eq 0) { Fail 'no resolved logged-on interactive profile found' }

$worker = Join-Path $Root 'bin\Refresh-UserIconCache.ps1'
if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) { Fail "worker missing: $worker" }
$receiptDir = Join-Path $env:TEMP 'arcicons-refresh-transport'
if (Test-Path -LiteralPath $receiptDir) { Remove-Item -LiteralPath $receiptDir -Recurse -Force -ErrorAction SilentlyContinue }

$rows = @()
foreach ($p in $profiles) {
  $before = @(Get-ArcIconsExplorerPids ([int]$p.SessionId))
  $r = Invoke-ArcIconsScheduledProfileRefresh -Profile $p -Worker $worker -ReceiptDir $receiptDir -DryRun -TimeoutSec 45
  $after = @(Get-ArcIconsExplorerPids ([int]$p.SessionId))
  $sameShell = ((@($before) -join ',') -eq (@($after) -join ','))
  $sidOk = $false
  $sessionOk = $false
  $profileOk = $false
  if ($r.Receipt) {
    $sidOk = ([string]$r.Receipt.sid -eq [string]$p.Sid)
    $sessionOk = ([int]$r.Receipt.sessionId -eq [int]$p.SessionId)
    $profileOk = ([string]$r.Receipt.profilePath -ieq [string]$p.ProfilePath)
  }
  $ok = [bool]$r.Ok -and $sidOk -and $sessionOk -and $profileOk -and $sameShell
  $rows += [pscustomobject]@{
    Session = $p.SessionId; Account = $p.Account; Ok = $ok; Transport = $r.Note
    SidOk = $sidOk; SessionOk = $sessionOk; ProfileOk = $profileOk
    ShellUnchanged = $sameShell; Mode = $r.Mode
  }
}

$rows | Format-Table Session, Account, Mode, Ok, SidOk, SessionOk, ProfileOk, ShellUnchanged -AutoSize | Out-String -Width 200 | Write-Output
foreach ($row in $rows) { Write-Output ("  {0}: {1}" -f $row.Account, $row.Transport) }
$bad = @($rows | Where-Object { -not $_.Ok })
if ($bad.Count -gt 0) {
  Fail ("{0} of {1} profile(s) failed the interactive-token transport (see rows above)" -f $bad.Count, $rows.Count)
}
Write-Output ('REFRESH-TRANSPORT: PASS ({0} profile(s): interactive-token task ran as the target user in its own session; shells untouched; receipts in {1})' -f $rows.Count, $receiptDir)
exit 0
