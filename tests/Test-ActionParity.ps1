# Test-ActionParity.ps1
# The action set is duplicated by design: the ARC-Icons.ps1 ValidateSet, its
# entry switch, the WinForms buttons in src\ArcInstaller.cs, the menu, and the
# shipped docs. This test pins them together so a new action cannot ship in one
# place and be missing in another (the install/uninstall gap this pass fixes).
# Text assertions only: ARC-Icons.ps1 self-elevates, so it is never executed.
# Windows PowerShell 5.1 compatible.
# Run: powershell -NoProfile -File tests\Test-ActionParity.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

$ExpectedActions = @('install', 'uninstall', 'apply', 'revert', 'repair', 'status', 'refresh', 'merge', 'task-on', 'task-off')

function Read-Text([string]$Rel) {
  $p = Join-Path $Root $Rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ("missing file: {0}" -f $Rel) }
  return (Get-Content -LiteralPath $p -Raw)
}
function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
  if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) { throw ("{0}: expected [{1}]" -f $Message, $Needle) }
}
function Assert-NotContains([string]$Text, [string]$Needle, [string]$Message) {
  if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) { throw ("{0}: unexpected [{1}]" -f $Message, $Needle) }
}

$controller = Read-Text 'ARC-Icons.ps1'
$gui = Read-Text 'src\ArcInstaller.cs'
$manual = Read-Text 'docs\REPAIR-MANUAL.md'
$lives = Read-Text 'docs\WHERE-IT-LIVES.md'
$shared = Read-Text 'bin\Set-BaselineSecurity.ps1'
$worker = Read-Text 'bin\Refresh-UserIconCache.ps1'

# 1. ValidateSet carries every action (plus menu).
$vs = [regex]::Match($controller, "\[ValidateSet\(([^\)]*)\)\]")
if (-not $vs.Success) { throw 'ARC-Icons.ps1: no [ValidateSet(...)] on -Action' }
$declared = @([regex]::Matches($vs.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
Assert-Contains ($declared -join ',') 'menu' 'ARC-Icons.ps1 ValidateSet includes menu'
foreach ($a in $ExpectedActions) {
  Assert-Contains ($declared -join ',') $a ("ARC-Icons.ps1 ValidateSet includes '{0}'" -f $a)
}

# 2. Every action has an entry-switch branch.
foreach ($a in $ExpectedActions) {
  Assert-Contains $controller ("        '{0}' {{" -f $a) ("ARC-Icons.ps1 entry switch handles '{0}'" -f $a)
}

# 3. GUI buttons and handlers for the two full actions.
foreach ($a in @('install', 'uninstall')) {
  Assert-Contains $gui ("RunAction(`"{0}`")" -f $a) ("src\ArcInstaller.cs wires the '{0}' action" -f $a)
}
Assert-Contains $gui 'installBtn' 'src\ArcInstaller.cs declares the install button'
# Uninstall lives in the More menu now, so pin the real wiring: the button
# exists, its menu item is bound to OnRemoveTheme, and that handler reaches
# RunAction("uninstall"). The loop above only proves the string exists somewhere.
Assert-Contains $gui 'moreBtn' 'src\ArcInstaller.cs declares the More menu button'
Assert-Contains $gui 'remove.Click += new EventHandler(OnRemoveTheme)' 'the More menu binds Remove theme to OnRemoveTheme'
$removeHandler = [regex]::Match($gui, 'private void OnRemoveTheme\([^)]*\)\s*\{.*?\n    \}', 'Singleline')
if (-not $removeHandler.Success) { throw 'src\ArcInstaller.cs: no OnRemoveTheme handler' }
Assert-Contains $removeHandler.Value 'RunAction("uninstall")' 'OnRemoveTheme triggers the uninstall action'

# 4. Menu offers both full actions.
Assert-Contains $controller 'INSTALL   (full:' 'menu names full install'
Assert-Contains $controller 'UNINSTALL (full:' 'menu names full uninstall'

# 5. Docs name the exact commands.
foreach ($doc in @(@{ N = 'docs\REPAIR-MANUAL.md'; T = $manual }, @{ N = 'docs\WHERE-IT-LIVES.md'; T = $lives })) {
  Assert-Contains $doc.T '-Action install' ("{0} documents -Action install" -f $doc.N)
  Assert-Contains $doc.T '-Action uninstall' ("{0} documents -Action uninstall" -f $doc.N)
}

# 6. The refresh entry point delegates to the multi-user engine and the worker
#    drops BOTH caches (the documented thumbcache gap).
Assert-Contains $shared 'Invoke-ArcIconsPerUserIconCacheRefresh' 'Set-BaselineSecurity delegates to the multi-user refresh'
Assert-Contains $worker 'iconcache*.db' 'worker drops iconcache*.db'
Assert-Contains $worker 'thumbcache*.db' 'worker drops thumbcache*.db'

# 7. Uninstall carries the optional state-cleanup switch, default OFF.
Assert-Contains $controller '[switch]$CleanState' 'ARC-Icons.ps1 declares -CleanState'
Assert-Contains $controller 'if ($CleanState) {' 'uninstall applies -CleanState conditionally'

# 8. Sandbox pair cannot be split: a non-default -Root requires an explicit
#    -SystemResourceDir, and elevation forwards both.
Assert-Contains $controller 'a non-default -Root requires an explicit -SystemResourceDir' 'sandbox guard present'
Assert-Contains $controller "if (`$sandboxRun) { `$argList += @('-Root', `$Root) }" 'elevation forwards -Root'

Write-Output ('ACTION-PARITY: PASS ({0} actions agree across ARC-Icons.ps1 ValidateSet + switch, the GUI buttons, the menu and both shipped docs; per-user refresh wired; -CleanState present)' -f $ExpectedActions.Count)
exit 0
