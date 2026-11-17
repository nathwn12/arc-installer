# ArcIcons remove-autorepair.ps1
# Cleanly unregisters the ArcIcons-Repair scheduled task (if present) and
# confirms it is gone.
[CmdletBinding()]
param(
  [string]$TaskName = 'ArcIcons-Repair'
)
$ErrorActionPreference = 'Stop'
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
  Write-Output "ARC-ICONS-AUTOREPAIR: task '$TaskName' not present; nothing to remove."
  exit 0
}
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
$gone = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($gone) { Write-Error "ARC-ICONS-AUTOREPAIR: FAIL task '$TaskName' still present."; exit 1 }
Write-Output "ARC-ICONS-AUTOREPAIR: removed task '$TaskName'; confirmed gone."
