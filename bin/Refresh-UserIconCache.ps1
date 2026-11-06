# ArcIcons Refresh-UserIconCache.ps1
# Per-user worker. Runs INSIDE one target user's interactive session (started by
# bin\ArcIcons-UserRefresh.ps1 through a one-shot InteractiveToken scheduled
# task, or directly by the user), so %LOCALAPPDATA% and explorer ownership are
# that user's by construction. It is not meant to be run by hand from another
# account: it refuses when the requested SID is not the current token's SID.
#
# Sequence (measured order matters):
#   1. stop ONLY this session's explorer (cache files are held open meanwhile);
#   2. delete iconcache*.db AND thumbcache*.db in the profile's Explorer dir,
#      plus the legacy %LOCALAPPDATA%\IconCache.db;
#   3. ie4uinit.exe -show;
#   4. start explorer.exe and wait until an explorer pid exists in THIS session;
#   5. write a receipt JSON (deleted files, pids, ok) and exit 0/4.
# -DryRun writes the receipt without touching the shell or any file: that is the
# transport proof used by tests\Test-UserRefreshTransport.ps1.
#
# Windows PowerShell 5.1 compatible. Never writes outside the target profile.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ProfileSid,
  [Parameter(Mandatory = $true)][string]$ReceiptPath,
  [switch]$DryRun,
  [int]$TimeoutSec = 20
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ArcIcons-UserRefresh.ps1')

function Write-ArcIconsRefreshReceipt($Obj) {
  try {
    $dir = Split-Path -Parent $ReceiptPath
    if ($dir -and (-not (Test-Path -LiteralPath $dir -PathType Container))) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    ([pscustomobject]$Obj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ReceiptPath -Encoding utf8
  } catch { }
}

$me = $null
try { $me = [System.Security.Principal.WindowsIdentity]::GetCurrent() } catch { }
$mySid = ''
$myAccount = ''
if ($me) { $mySid = $me.User.Value; $myAccount = $me.Name }
$mySession = (Get-Process -Id $PID).SessionId
$profilePath = Get-ArcIconsProfilePathBySid $ProfileSid
$receipt = [ordered]@{
  ts = (Get-Date).ToString('o')
  requestedSid = $ProfileSid
  sid = $mySid
  account = $myAccount
  sessionId = $mySession
  profilePath = $profilePath
  dryRun = [bool]$DryRun
  deleted = @()
  stoppedExplorer = @()
  explorerPids = @(Get-ArcIconsExplorerPids $mySession)
  ok = $false
  reason = ''
}

if (-not $me) {
  $receipt.reason = 'cannot read the current Windows identity'
  Write-ArcIconsRefreshReceipt $receipt; exit 2
}
if ($mySid -ne $ProfileSid) {
  $receipt.reason = ("token SID {0} != requested {1}; refusing to touch another profile" -f $mySid, $ProfileSid)
  Write-ArcIconsRefreshReceipt $receipt; exit 2
}
if ($mySession -eq 0) {
  $receipt.reason = 'session 0: cannot restart an interactive shell from a service session'
  Write-ArcIconsRefreshReceipt $receipt; exit 3
}
if (-not $profilePath) {
  $receipt.reason = ("no ProfileList ProfileImagePath for {0}" -f $ProfileSid)
  Write-ArcIconsRefreshReceipt $receipt; exit 5
}
$myProfile = ''
try { $myProfile = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\') } catch { }
$wantProfile = ''
try { $wantProfile = [IO.Path]::GetFullPath($profilePath).TrimEnd('\') } catch { $wantProfile = $profilePath.TrimEnd('\') }
if ($myProfile -and ($myProfile -ine $wantProfile)) {
  $receipt.reason = ("USERPROFILE {0} != requested profile {1}; refusing (wrong token)" -f $myProfile, $wantProfile)
  Write-ArcIconsRefreshReceipt $receipt; exit 2
}
$receipt.profilePath = $wantProfile

if ($DryRun) {
  # Transport proof only: no shell stop, no file delete, no registry write.
  $receipt.ok = $true
  $receipt.reason = 'dry-run'
  Write-ArcIconsRefreshReceipt $receipt
  exit 0
}

# No progress receipt: the parent polls for this file, so it must appear only
# once, with the final verdict (an early ok=false would read as a failure).
$r = Invoke-ArcIconsProfileCacheDrop -ProfilePath $wantProfile -SessionId $mySession
$receipt.deleted = @($r.Deleted)
$receipt.stoppedExplorer = @($r.Stopped)
$receipt.explorerPids = @(Get-ArcIconsExplorerPids $mySession)
$receipt.ok = ($null -ne $r.Shell) -and $r.Shell.Running
if ($receipt.ok) {
  $receipt.reason = 'explorer running after cache drop'
} else {
  $receipt.reason = 'explorer did NOT come back in this session'
}
Write-ArcIconsRefreshReceipt $receipt
if ($receipt.ok) { exit 0 }
exit 4
