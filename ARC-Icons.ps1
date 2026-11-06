# ARC-Icons.ps1 - all-in-one controller for the ARC icon theme on this PC
# variant selector, repair verb, payload table
# variant-aware verify/merge, self-chaining
#   variant switch, visible refusals, guaranteed explorer restart/restore
#
# Usage:
#   ARC-Icons.cmd                     -> interactive menu (double-click this)
#   ARC-Icons.ps1 -Action status      -> show state + verify
#   ARC-Icons.ps1 -Action install     -> FULL install in one action: capture-if-fresh,
#                                        merge the chosen variant, restore-if-switching,
#                                        apply, refresh EVERY logged-on profile's icon +
#                                        thumbnail cache, verify PASS
#   ARC-Icons.ps1 -Action uninstall   -> FULL uninstall in one action: restore the
#                                        pristine originals, refresh every logged-on
#                                        profile, verify PASS (mode=original)
#   ARC-Icons.ps1 -Action apply       -> apply / re-apply the ARC icons (no variant switch)
#   ARC-Icons.ps1 -Action revert      -> put Windows' own icons back (no full verify)
#   ARC-Icons.ps1 -Action repair      -> re-apply ONLY if the live payload drifted, then refresh the icon cache
#   ARC-Icons.ps1 -Action refresh     -> rebuild every logged-on profile's shell icon cache
#   ARC-Icons.ps1 -Action merge       -> rebuild the merged files from originals + theme
#   ARC-Icons.ps1 -Action task-on     -> enable auto-repair at startup
#   ARC-Icons.ps1 -Action task-off    -> disable auto-repair at startup
#   add -Yes to skip confirmations, -DryRun to preview an install/apply/uninstall.
#   add -CleanState to uninstall to also remove state.json, installed-manifest.json
#   and stage\ (default KEEPS them so a reinstall stays safe; originals\ is never
#   removed by any flag).
#   add -Variant <arc|arc-symbolic|neutral-brown|neutral-grey|dark-grey> to choose which ARC
#   build is installed; switching away from the built variant re-merges, restores
#   the pristine originals, then applies (one action, no manual steps).
#   Every install/uninstall/apply/refresh/repair ends with every logged-on
#   profile's explorer.exe running: the icon-cache refresh runs per user (the
#   caller in-process, every other profile through a one-shot interactive task)
#   and verifies each shell came back in its own session.
#   Sandbox: -Root <dir> -SystemResourceDir <dir> (both required together; the
#   live SystemResources directory is never touched by a sandbox run).
#
# Variants (arc/brown/grey are niivu's ARC set; -Variant also accepts the display
# name). arc-symbolic is niivu's official symbolic pack. dark-grey is NOT
# niivu's - it is generated on this PC by bin\Recolor-IconTheme.ps1 from Arc
# Neutral Grey (k=0.55, one kEff per RT_GROUP_ICON with a group luminance floor
# of 64) and is a COMPLETE variant: all three payloads are recolored (see
# docs\arc-dark-grey-variant.md), not a partial PoC:
#   arc            ARC (by niivu)      theme\Windhawk Resources                     <- upstream default
#   arc-symbolic   ARC Symbolic        theme\ARC Symbolic\Windhawk Resources
#   neutral-brown  Arc Neutral Brown   theme\Arc Neutral Brown\Windhawk Resources
#   neutral-grey   Arc Neutral Grey    theme\Arc Neutral Grey\Windhawk Resources
#   dark-grey      Arc Dark Grey       theme\Arc Dark Grey\Windhawk Resources      (tool default)
# A variant installs only when its source payload is present. Selecting a
# different variant THAN THE BUILT ONE self-chains the documented recipe —
# merge that variant -> restore the pristine originals -> apply -> verify — so
# the operator never has to run three commands by hand. apply.ps1 on its own
# still refuses a live payload that is neither the recorded original nor the
# recorded merge, because at that point live holds the PREVIOUS theme's merge.
# On a provably-fresh machine (no state.json, no installed-manifest.json, no
# originals\) the single apply instead captures the pristine originals first,
# then merge -> apply -> verify, with no restore step (nothing is installed
# yet). Anything partial refuses with a named reason.
# Anything that cannot be done fails loudly with a named reason and holds the
# window open instead of silently installing another theme.
#
# The payload table below is the complete set the tooling touches: apply.ps1 /
# restore.ps1 / verify.ps1 refuse any name outside the allowlist in
# bin\Set-BaselineSecurity.ps1 ({imageres,imagesp1,zipfldr}.dll.mun), so this
# controller cannot add a fourth target - it carries the per-payload role and
# the merged icon counts instead of bare names.
#
# Everything it calls lives beside this file; nothing is downloaded.
param(
    [ValidateSet('menu', 'install', 'uninstall', 'apply', 'revert', 'repair', 'status', 'refresh', 'merge', 'task-on', 'task-off')]
    [string]$Action = 'menu',
    [string]$Variant = 'dark-grey',
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$CleanState,
    [string]$Root = '',
    [string]$SystemResourceDir = ''
)

$ErrorActionPreference = 'Stop'
# $Tool = where the scripts live (this file + bin\); $Root = the DATA root
# (state, manifests, originals, theme, logs). They are the same directory for a
# normal repo/installed run and differ only for a sandbox run.
$Tool = $PSScriptRoot
if (-not $Root) { $Root = $Tool }
if (-not $SystemResourceDir) { $SystemResourceDir = Join-Path $env:SystemRoot 'SystemResources' }
$Bin = Join-Path $Tool 'bin'
$Apply = Join-Path $Tool 'apply.ps1'
$Restore = Join-Path $Tool 'restore.ps1'
$Verify = Join-Path $Tool 'verify.ps1'
$Repair = Join-Path $Tool 'repair.ps1'
$Merge = Join-Path $Tool 'bin\Merge-IconTheme.ps1'
$TaskOn = Join-Path $Tool 'install-autorepair.ps1'
$TaskOff = Join-Path $Tool 'remove-autorepair.ps1'
$StateFile = Join-Path $Root 'state.json'
$InstMan = Join-Path $Root 'installed-manifest.json'
$OrigMan = Join-Path $Root 'originals\manifest.json'
$SysDir = $SystemResourceDir

# Shared library (dot-source only, no side effects): owns the icon-cache refresh,
# the verified explorer restart and the shell guard used on every exit path.
. (Join-Path $Bin 'Set-BaselineSecurity.ps1')
. (Join-Path $Bin 'Default-IconVariant.ps1')

# Nested calls run on PowerShell 7 when present, else Windows PowerShell 5.1 —
# no hard dependence on pwsh.exe being installed or on PATH.
$PSExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $PSExe) { $PSExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

# The allowlisted payload set (name in SystemResources, source file in the theme, what it paints).
$Targets = @(
    [pscustomobject]@{ Name = 'imageres.dll.mun'; Source = 'imageres.dll'; Role = 'shell + file-type icons' }
    [pscustomobject]@{ Name = 'imagesp1.dll.mun'; Source = 'imagesp1.dll'; Role = 'secondary shell icon set' }
    [pscustomobject]@{ Name = 'zipfldr.dll.mun'; Source = 'zipfldr.dll'; Role = 'compressed-folder icons' }
)

# The selectable ARC builds. ThemeDir is relative to <root>\theme\.
$Variants = [ordered]@{
    'arc'           = [pscustomobject]@{ Id = 'arc';           Display = 'ARC (by niivu)';    ThemeDir = 'Windhawk Resources' }
    'arc-symbolic'  = [pscustomobject]@{ Id = 'arc-symbolic';  Display = 'ARC Symbolic';      ThemeDir = 'ARC Symbolic\Windhawk Resources' }
    'neutral-brown' = [pscustomobject]@{ Id = 'neutral-brown'; Display = 'Arc Neutral Brown'; ThemeDir = 'Arc Neutral Brown\Windhawk Resources' }
    'neutral-grey'  = [pscustomobject]@{ Id = 'neutral-grey';  Display = 'Arc Neutral Grey';  ThemeDir = 'Arc Neutral Grey\Windhawk Resources' }
    'dark-grey'     = [pscustomobject]@{ Id = 'dark-grey';     Display = 'Arc Dark Grey';     ThemeDir = 'Arc Dark Grey\Windhawk Resources' }
}

function Write-Head($t) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
function Read-Json($path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}
function Get-Mode {
    if (Test-Path $StateFile) {
        try { return (Get-Content $StateFile -Raw | ConvertFrom-Json).mode } catch { return 'unreadable' }
    }
    return 'unknown'
}
function Get-BuiltTheme {
    $m = Read-Json $InstMan
    if (-not $m -or -not $m.theme) { return '' }
    return [string]$m.theme
}
function Resolve-Variant([string]$Name) {
    $key = ([string]$Name).Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $key = $key.Trim('-')
    $alias = @{
        'arc' = 'arc'; 'arc-by-niivu' = 'arc'; 'niivu' = 'arc'; 'default' = 'arc'
        'arc-symbolic' = 'arc-symbolic'; 'symbolic' = 'arc-symbolic'
        'neutral-brown' = 'neutral-brown'; 'arc-neutral-brown' = 'neutral-brown'; 'brown' = 'neutral-brown'
        'neutral-grey' = 'neutral-grey'; 'arc-neutral-grey' = 'neutral-grey'; 'grey' = 'neutral-grey'
        'gray' = 'neutral-grey'; 'neutral-gray' = 'neutral-grey'; 'arc-neutral-gray' = 'neutral-grey'
        'dark-grey' = 'dark-grey'; 'arc-dark-grey' = 'dark-grey'; 'dark-gray' = 'dark-grey'; 'arc-dark-gray' = 'dark-grey'
    }
    if ($alias.ContainsKey($key)) { return $Variants[$alias[$key]] }
    Write-Host ''
    Write-Host "  unknown -Variant '$Name'." -ForegroundColor Red
    Write-Host ("  allowed: " + (@($Variants.Keys) -join ' | '))
    Write-Host "  the display names work too, e.g. -Variant 'Arc Neutral Brown'."
    exit 1
}
function Get-VariantSourceDir($v) { return (Join-Path $Root ("theme\{0}" -f $v.ThemeDir)) }
function Get-MissingVariantSource($v) {
    $dir = Get-VariantSourceDir $v
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @($dir) }
    $missing = @()
    foreach ($t in $Targets) {
        $p = Join-Path $dir $t.Source
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing += $p }
    }
    return $missing
}
function Get-PayloadRows {
    $inst = Read-Json $InstMan
    $man = Read-Json $OrigMan
    $rows = @()
    foreach ($t in $Targets) {
        $n = $t.Name
        $p = Join-Path $SysDir $n
        $live = 'MISSING'
        $size = 0
        if (Test-Path -LiteralPath $p) {
            $size = (Get-Item -LiteralPath $p).Length
            $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
            $row = if ($inst) { $inst.files | Where-Object name -eq $n } else { $null }
            $org = if ($man) { $man.files | Where-Object name -eq $n } else { $null }
            $live = if ($row -and $h -eq $row.mergedSha256) { 'ARC' } elseif ($org -and $h -eq $org.originalSha256) { 'windows-default' } else { 'UNKNOWN' }
        }
        $m = if ($inst) { $inst.files | Where-Object name -eq $n } else { $null }
        $groups = $null; $fromTheme = $null; $added = $null
        if ($m) {
            if ($m.PSObject.Properties['groupsMerged']) { $groups = $m.groupsMerged }
            if ($m.PSObject.Properties['groupsFromTheme']) { $fromTheme = $m.groupsFromTheme }
            if ($m.PSObject.Properties['groupsAdded']) { $added = $m.groupsAdded }
        }
        $rows += [pscustomobject]@{ Name = $n; Role = $t.Role; Live = $live; Size = $size; Groups = $groups; FromTheme = $fromTheme; Added = $added }
    }
    return $rows
}
function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
function Read-Choice([string]$prompt = '  choice') {
    # a closed / exhausted stdin must quit, never hang or spin the menu
    try {
        if ([Console]::IsInputRedirected -and [Console]::In.Peek() -eq -1) { return 'q' }
        return (Read-Host $prompt)
    } catch { return 'q' }
}
function Confirm($what) {
    if ($Yes) { return $true }
    $a = Read-Choice "  $what [y/N]"
    return ($a -match '^(y|yes)$')
}
function Stop-Visible([string]$msg, [int]$code = 1, [string]$detail = 'nothing changed.') {
    # A refusal must be READ, never vanish: name the reason, then hold the window
    # open on a real console (an elevated window has no launcher to pause for it).
    Write-Host ''
    Write-Host "  $msg" -ForegroundColor Red
    if ($detail) { Write-Host "  $detail" -ForegroundColor Yellow }
    if ((-not $Yes) -and (-not [Console]::IsInputRedirected)) { [void](Read-Choice '  press Enter to close') }
    exit $code
}
function Show-Status {
    Write-Head 'ARC icon theme - status'
    $v = $script:VariantInfo
    $built = Get-BuiltTheme
    $builtTxt = if ($built) { $built } else { 'no installed-manifest.json' }
    $mark = if (-not $built) { 'unknown' } elseif ($built -eq $v.Display) { 'ok' } else { 'MISMATCH' }
    Write-Host "  folder  : $Root"
    Write-Host "  state   : $(Get-Mode)"
    Write-Host "  variant : $($v.Display)  [$($v.Id)]   built: $builtTxt  ($mark)"
    $missing = Get-MissingVariantSource $v
    if ($missing.Count -eq 0) {
        Write-Host "  source  : $($v.ThemeDir) - present"
    } else {
        Write-Host "  source  : $($v.ThemeDir) - MISSING:" -ForegroundColor Yellow
        foreach ($m in $missing) { Write-Host "            $m" -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host '  payloads (the full allowlisted set):'
    foreach ($r in Get-PayloadRows) {
        $icons = if ($null -ne $r.Groups) { "icons $($r.Groups) ($($r.FromTheme) from theme, $($r.Added) added)" } else { 'icons n/a' }
        Write-Host ("    {0,-18} {1,-16} {2,-34} {3,12:N0} B  {4}" -f $r.Name, $r.Live, $icons, $r.Size, $r.Role)
    }
    Write-Host ''
    if (-not (Test-Path $StateFile)) {
        Write-Host '  note: this folder has no state.json yet, so full verification is skipped.' -ForegroundColor Yellow
        Write-Host '        run option 1 (apply) once - it is idempotent - to record the state and get a PASS.' -ForegroundColor Yellow
    } else {
        & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
    }
    Write-Host ''
}
function Invoke-Apply {
    $v = $script:VariantInfo
    Write-Head "APPLY - install the ARC icon resources ($($v.Display))"
    $missing = Get-MissingVariantSource $v
    if ($missing.Count -gt 0) {
        Write-Host "  variant source for '$($v.Display)' is not on this PC:" -ForegroundColor Red
        foreach ($m in $missing) { Write-Host "    $m" -ForegroundColor Red }
        Write-Host "  expected: <root>\theme\$($v.ThemeDir)\{imageres,imagesp1,zipfldr}.dll" -ForegroundColor Yellow
        Stop-Visible "ARC-ICONS-APPLY: REFUSED - variant '$($v.Display)' source is missing; land the payload in theme\$($v.ThemeDir) first."
    }
    $built = Get-BuiltTheme
    $freshMachine = (-not (Test-Path -LiteralPath $StateFile)) -and (-not (Test-Path -LiteralPath $InstMan)) -and (-not (Test-Path -LiteralPath (Join-Path $Root 'originals')))
    if ($freshMachine) {
        # Provably-fresh machine: one action captures the pristine originals,
        # merges this variant, applies and verifies - with no restore step
        # (nothing is installed yet). apply.ps1 owns that whole chain and
        # already verified, so return after it instead of falling through.
        Write-Host '  fresh machine: capture pristine originals -> merge -> apply -> verify (no restore: nothing installed yet).'
        if ($DryRun) { Write-Host '  -DryRun: a first install must write (capture + merge), so there is no preview; nothing changed.'; return }
        if (-not (Confirm ("Install '$($v.Display)' now?"))) { Write-Host '  cancelled'; return }
        $a = @('-NoProfile', '-File', $Apply, '-Root', $Root, '-SystemResourceDir', $SysDir, '-CloseHolders') + (Get-ArcIconsApplyVariantArguments $v.Id)
        & $PSExe @a
        if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-APPLY: FAILED (exit {0}) - see the output above." -f $LASTEXITCODE) $LASTEXITCODE 'the shell was restored; live files are rolled back to the pristine originals.' }
        return
    }
    if ($built -ne $v.Display) {
        # Variant switch. The built payload is pinned to one theme, so switching
        # IS the documented recipe (restore -> merge -> apply) run for the
        # operator: re-merge this variant, put the pristine originals back, then
        # apply. Without the restore step apply.ps1 correctly refuses, because
        # live would hold the PREVIOUS theme's merge.
        Write-Host ("  variant switch: built payload is '{0}', requested '{1}'." -f $(if ($built) { $built } else { 'none' }), $v.Display)
        Write-Host "  chain: merge this variant -> restore pristine originals -> apply (apply alone would refuse: live holds the previous theme)."
        if ($DryRun) { Write-Host '  -DryRun: the switch would run merge -> restore -> apply; nothing changed.'; return }
        if (-not (Confirm "Switch to '$($v.Display)' now?")) { Write-Host '  cancelled'; return }
        Write-Host ''
        Write-Host ("  [1/3] MERGE   - rebuild stage\ + installed-manifest.json for {0}" -f $v.Display)
        & $PSExe -NoProfile -File $Merge -Root $Root -Build -Variant $v.Id
        if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-MERGE: FAILED (exit {0}) for variant '{1}'; live payload untouched, nothing applied." -f $LASTEXITCODE, $v.Display) $LASTEXITCODE }
        Write-Host ("  [2/3] RESTORE - put the pristine originals back into {0} (icon cache left to the apply step)" -f $SysDir)
        & $PSExe -NoProfile -File $Restore -Root $Root -SystemResourceDir $SysDir -CloseHolders -SkipIconCacheRefresh
        if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-RESTORE: FAILED (exit {0}); nothing applied." -f $LASTEXITCODE) $LASTEXITCODE }
        Write-Host '  [3/3] APPLY   - install the merged payload'
    }
    Write-Host ("  target : {0}\{{imageres,imagesp1,zipfldr}}.dll.mun" -f $SysDir)
    if (-not (Confirm 'Apply now?')) { Write-Host '  cancelled'; return }
    $a = @('-NoProfile', '-File', $Apply, '-Root', $Root, '-SystemResourceDir', $SysDir, '-CloseHolders') + (Get-ArcIconsApplyVariantArguments $v.Id)
    if ($DryRun) { $a += '-DryRun' }
    & $PSExe @a
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-APPLY: FAILED (exit {0}) - see the output above." -f $LASTEXITCODE) $LASTEXITCODE 'the shell was restored; live files are rolled back to the pristine originals.' }
    Write-Host ''
    & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-VERIFY: FAILED (exit {0}) after apply." -f $LASTEXITCODE) $LASTEXITCODE 'the payload is installed but does not verify; read the FAIL lines above before using the shell.' }
}
function Show-RefreshProfiles($r) {
    foreach ($p in @($r.Profiles)) {
        $mark = if ($p.Ok) { 'ok' } else { 'FAIL' }
        Write-Host ("    session {0,-3} {1,-26} {2,-15} {3}  {4}" -f $p.SessionId, $p.Account, $p.Mode, $mark, $p.Note)
    }
}
function Get-ArcIconsLivePayloadState {
    # 'original' = every live file is the pristine original; 'merged' = the rest
    # are the RECORDED merge and none is unknown; 'unknown' = at least one live
    # file matches neither (Windows Update or a manual edit) and must not be
    # overwritten by a full install.
    $man = Read-Json $OrigMan
    if (-not $man) { return 'unknown' }
    $inst = Read-Json $InstMan
    $unknown = @()
    $merged = 0
    foreach ($b in @($man.files)) {
        $name = [string]$b.name
        $p = Join-Path $SysDir $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $unknown += $name; continue }
        try { $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } catch { $unknown += $name; continue }
        if ($h -eq ([string]$b.originalSha256).ToUpperInvariant()) { continue }
        $row = if ($inst) { $inst.files | Where-Object name -eq $name } else { $null }
        if ($row -and $h -eq ([string]$row.mergedSha256).ToUpperInvariant()) { $merged++ }
        else { $unknown += $name }
    }
    if ($unknown.Count -gt 0) { return 'unknown' }
    if ($merged -gt 0) { return 'merged' }
    return 'original'
}
function Invoke-Install {
    # One action = the whole install: source check, capture-if-fresh,
    # merge the requested variant, restore-if-switching (or if live holds a
    # previous merge), apply, per-user refresh for EVERY logged-on profile,
    # verify PASS. The icon-cache refresh is done once at the end (apply runs
    # with -SkipIconCacheRefresh) so the shell restarts once per profile.
    $v = $script:VariantInfo
    Write-Head "INSTALL - full install ($($v.Display))"
    $missing = Get-MissingVariantSource $v
    if ($missing.Count -gt 0) {
        Write-Host "  variant source for '$($v.Display)' is not on this PC:" -ForegroundColor Red
        foreach ($m in $missing) { Write-Host "    $m" -ForegroundColor Red }
        Write-Host "  expected: <root>\theme\$($v.ThemeDir)\{imageres,imagesp1,zipfldr}.dll" -ForegroundColor Yellow
        Stop-Visible "ARC-ICONS-INSTALL: REFUSED - variant '$($v.Display)' source is missing; land the payload in theme\$($v.ThemeDir) first."
    }
    $built = Get-BuiltTheme
    $freshMachine = (-not (Test-Path -LiteralPath $StateFile)) -and (-not (Test-Path -LiteralPath $InstMan)) -and (-not (Test-Path -LiteralPath (Join-Path $Root 'originals')))
    $switching = (-not $freshMachine) -and ($built -ne $v.Display)
    $liveState = 'unknown'
    if (-not $freshMachine) { $liveState = Get-ArcIconsLivePayloadState }
    Write-Host ("  root   : {0}" -f $Root)
    Write-Host ("  target : {0}\{{imageres,imagesp1,zipfldr}}.dll.mun" -f $SysDir)
    Write-Host ("  state  : {0}; built variant: {1}; live payload: {2}" -f (Get-Mode), $(if ($built) { $built } else { 'none' }), $liveState)
    if ($freshMachine) {
        Write-Host '  plan   : capture pristine originals + merge + apply -> refresh every profile -> verify'
    } elseif ($switching) {
        Write-Host '  plan   : merge this variant -> restore pristine originals -> apply -> refresh every profile -> verify'
    } else {
        Write-Host '  plan   : merge this variant -> restore pristine originals if live holds a previous merge -> apply -> refresh every profile -> verify'
    }
    if ($DryRun) {
        Write-Host '  -DryRun: nothing changed (apply/uninstall DryRun previews live in those verbs).'
        return
    }
    if ((-not $freshMachine) -and ($liveState -eq 'unknown')) {
        Stop-Visible 'ARC-ICONS-INSTALL: REFUSED - at least one live payload is neither the recorded original nor the recorded merge (Windows Update or a manual change).' 1 'a full install will not overwrite an unknown payload. Re-capture the originals and re-merge (docs\REPAIR-MANUAL.md, "After a Windows Update"), then install again.'
    }
    if (-not (Confirm "Install '$($v.Display)' now?")) { Write-Host '  cancelled'; return }
    if (-not $freshMachine) {
        Write-Host ''
        Write-Host ("  [1/4] MERGE   - rebuild stage\ + installed-manifest.json for {0} from originals + theme" -f $v.Display)
        & $PSExe -NoProfile -File $Merge -Root $Root -Build -Variant $v.Id
        if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-INSTALL: MERGE FAILED (exit {0}) for variant '{1}'; live payload untouched, nothing applied." -f $LASTEXITCODE, $v.Display) $LASTEXITCODE }
        if ($switching -or ($liveState -eq 'merged')) {
            Write-Host ("  [2/4] RESTORE - put the pristine originals back into {0} (cache refresh deferred to step 4)" -f $SysDir)
            & $PSExe -NoProfile -File $Restore -Root $Root -SystemResourceDir $SysDir -CloseHolders -SkipIconCacheRefresh
            if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-INSTALL: RESTORE FAILED (exit {0}); nothing applied." -f $LASTEXITCODE) $LASTEXITCODE }
        } else {
            Write-Host '  [2/4] RESTORE - not needed: live already holds the pristine originals'
        }
    }
    if ($freshMachine) {
        Write-Host '  [1/4] APPLY   - capture pristine originals + merge + install (fresh machine)'
    } else {
        Write-Host '  [3/4] APPLY   - install the merged payload'
    }
    $a = @('-NoProfile', '-File', $Apply, '-Root', $Root, '-SystemResourceDir', $SysDir, '-CloseHolders', '-SkipIconCacheRefresh') + (Get-ArcIconsApplyVariantArguments $v.Id)
    & $PSExe @a
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-INSTALL: APPLY FAILED (exit {0}) - see the output above." -f $LASTEXITCODE) $LASTEXITCODE 'the shell was restored; live files are rolled back to the pristine originals.' }
    Write-Host '  [4/4] REFRESH - every logged-on profile: iconcache + thumbcache drop, verified explorer restart'
    $r = Invoke-ArcIconsPerUserIconCacheRefresh -Root $Root -SysDir $SysDir -Skip $false
    Write-Host ("    {0}" -f $r.Note)
    Show-RefreshProfiles $r
    Write-Host ''
    Write-Host '  VERIFY'
    & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
    $vcode = $LASTEXITCODE
    if ($vcode -ne 0) { Stop-Visible ("ARC-ICONS-VERIFY: FAILED (exit {0}) after install." -f $vcode) $vcode 'the payload is installed but does not verify; read the FAIL lines above before using the shell.' }
    if (-not $r.Ok) {
        Stop-Visible ("ARC-ICONS-INSTALL: FAIL - payload installed and verified, but the icon cache was NOT refreshed for every logged-on profile: {0}" -f ($r.Failures -join '; ')) 1 'sign out/in or run -Action refresh; the profile list above names what failed.'
    }
    Write-Host ''
    Write-Host '  ARC-ICONS-INSTALL: PASS'
}
function Invoke-Uninstall {
    # One action = full uninstall: restore the pristine originals, refresh every
    # logged-on profile, verify PASS (mode=original). -CleanState additionally
    # removes state.json / installed-manifest.json / stage\; originals\ (the only
    # pristine copy) and logs\ are never removed. Default keeps the manifests so
    # a reinstall stays safe.
    Write-Head 'UNINSTALL - full uninstall (restore pristine originals)'
    if (-not (Test-Path -LiteralPath $OrigMan -PathType Leaf)) {
        Stop-Visible ("ARC-ICONS-UNINSTALL: REFUSED - {0} is missing; there is no pristine copy to restore." -f $OrigMan) 1 'if Windows Update replaced the payloads, re-capture originals first (see docs\REPAIR-MANUAL.md).'
    }
    Write-Host ("  root   : {0}" -f $Root)
    Write-Host ("  target : {0}\{{imageres,imagesp1,zipfldr}}.dll.mun" -f $SysDir)
    Write-Host ("  state  : {0}" -f (Get-Mode))
    Write-Host '  plan   : restore pristine originals -> refresh every profile -> verify (mode=original)'
    if ($CleanState) { Write-Host '  -CleanState: also removes state.json, installed-manifest.json and stage\ (originals\ and logs\ are kept)' }
    if ($DryRun) {
        Write-Host '  -DryRun: nothing changed (restore -DryRun previews live in that verb).'
        return
    }
    if (-not (Confirm 'Uninstall now?')) { Write-Host '  cancelled'; return }
    Write-Host ''
    Write-Host ("  [1/3] RESTORE - put the pristine originals back into {0}" -f $SysDir)
    & $PSExe -NoProfile -File $Restore -Root $Root -SystemResourceDir $SysDir -CloseHolders -SkipIconCacheRefresh
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-UNINSTALL: RESTORE FAILED (exit {0}) - see the output above." -f $LASTEXITCODE) $LASTEXITCODE }
    Write-Host '  [2/3] REFRESH - every logged-on profile: iconcache + thumbcache drop, verified explorer restart'
    $r = Invoke-ArcIconsPerUserIconCacheRefresh -Root $Root -SysDir $SysDir -Skip $false
    Write-Host ("    {0}" -f $r.Note)
    Show-RefreshProfiles $r
    Write-Host ''
    Write-Host '  [3/3] VERIFY'
    & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
    $vcode = $LASTEXITCODE
    if ($vcode -ne 0) { Stop-Visible ("ARC-ICONS-VERIFY: FAILED (exit {0}) after uninstall." -f $vcode) $vcode 'the live files were not fully restored; run restore.ps1 again or follow docs\REPAIR-MANUAL.md.' }
    if (-not $r.Ok) {
        Stop-Visible ("ARC-ICONS-UNINSTALL: FAIL - originals restored and verified, but the icon cache was NOT refreshed for every logged-on profile: {0}" -f ($r.Failures -join '; ')) 1 'sign out/in or run -Action refresh; the profile list above names what failed.'
    }
    if ($CleanState) {
        Write-Host ''
        Write-Host '  CLEAN STATE (originals\ and logs\ kept)'
        $targets = @(
            (Join-Path $Root 'state.json'),
            (Join-Path $Root 'installed-manifest.json'),
            (Join-Path $Root 'stage')
        )
        foreach ($t in $targets) {
            if (Test-Path -LiteralPath $t) {
                try { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction Stop; Write-Host ("    removed {0}" -f $t) }
                catch { Stop-Visible ("ARC-ICONS-UNINSTALL: CLEAN FAILED removing {0}: {1}" -f $t, $_) 1 }
            } else { Write-Host ("    absent  {0}" -f $t) }
        }
        Write-Host '  re-verify after state cleanup (state.json absent means mode=original)'
        & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
        if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-VERIFY: FAILED (exit {0}) after -CleanState." -f $LASTEXITCODE) $LASTEXITCODE }
    }
    Write-Host ''
    Write-Host '  ARC-ICONS-UNINSTALL: PASS (mode=original)'
}
function Invoke-Revert {
    Write-Head 'REVERT - put Windows own icons back'
    Write-Host '  restores the pristine files backed up before the theme was installed'
    if (-not (Confirm 'Revert now?')) { Write-Host '  cancelled'; return }
    $a = @('-NoProfile', '-File', $Restore, '-Root', $Root, '-SystemResourceDir', $SysDir, '-CloseHolders')
    if ($DryRun) { $a += '-DryRun' }
    & $PSExe @a
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-RESTORE: FAILED (exit {0}) - see the output above." -f $LASTEXITCODE) $LASTEXITCODE 'the shell was restored; live files are rolled back to the pristine originals.' }
    Write-Host ''
    & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
}
function Invoke-Repair {
    Write-Head 'REPAIR - re-apply only when the live payload drifted, then refresh the icon cache'
    Write-Host '  classifies each live file: no-action | repaired | drift-unknown-payload'
    Write-Host '  an unknown (post-Windows-Update) payload is never overwritten'
    if (-not (Confirm 'Repair now?')) { Write-Host '  cancelled'; return }
    $ra = @('-NoProfile', '-File', $Repair, '-Root', $Root, '-SystemResourceDir', $SysDir)
    if ($DryRun) { $ra += '-DryRun' }
    $out = & $PSExe @ra 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($out)) { Write-Host "  $line" }
    if ($DryRun) { Write-Host '  -DryRun: preview only; nothing re-applied, icon cache untouched.'; return }
    if ($code -ne 0) {
        Write-Host "  repair exited $code - icon cache left alone." -ForegroundColor Red
        Stop-Visible ("ARC-ICONS-REPAIR: FAILED (exit {0}) - see the output above." -f $code) $code
    }
    if (@($out) -match 'ARC-ICONS-REPAIR: repaired') { Invoke-Refresh } else { Write-Host '  nothing re-applied; icon cache left alone.' }
    Write-Host ''
    & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
}
function Invoke-Refresh {
    Write-Head 'REFRESH - rebuild every logged-on profile''s shell icon cache'
    # one mechanism only: the shared multi-user refresh stops each profile's own
    # explorer, drops iconcache*.db AND thumbcache*.db, runs ie4uinit -show,
    # restarts that shell and proves it came back in that session.
    $r = Invoke-ArcIconsPerUserIconCacheRefresh -Root $Root -SysDir $SysDir -Skip $false
    Write-Host ("  {0}" -f $r.Note)
    Show-RefreshProfiles $r
    [void](Restore-ArcIconsShell 'refresh')
}
function Invoke-Merge {
    Write-Head 'MERGE - rebuild the merged files from the pristine originals + theme'
    Write-Host '  use this after a Windows Update replaced the originals (then re-apply)'
    $v = $script:VariantInfo
    Write-Host ("  variant: {0}   source: theme\{1}" -f $v.Display, $v.ThemeDir)
    if (-not (Confirm 'Rebuild merged files now?')) { Write-Host '  cancelled'; return }
    & $PSExe -NoProfile -File $Merge -Root $Root -Build -Variant $v.Id
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-MERGE: FAILED (exit {0}) for variant '{1}'." -f $LASTEXITCODE, $v.Display) $LASTEXITCODE }
    & $PSExe -NoProfile -File $Merge -Root $Root -Verify -Variant $v.Id
}
function Invoke-Task($on) {
    if ($on) {
        Write-Head 'AUTO-REPAIR - enable at startup'
        & $PSExe -NoProfile -File $TaskOn -Root $Root -SystemResourceDir $SysDir
    } else {
        Write-Head 'AUTO-REPAIR - disable'
        & $PSExe -NoProfile -File $TaskOff
    }
}
function Show-VariantMenu {
    $ids = @($Variants.Keys)
    $built = Get-BuiltTheme
    while ($true) {
        Write-Head 'VARIANT - which ARC build to install'
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $v = $Variants[$ids[$i]]
            $src = if ((Get-MissingVariantSource $v).Count -eq 0) { 'source present' } else { 'source MISSING' }
            $b = if ($built -eq $v.Display) { 'built' } elseif ($built) { "built: $built" } else { 'not built' }
            $cur = if ($v.Id -eq $script:VariantInfo.Id) { '<- current' } else { '' }
            Write-Host ("    {0}  {1,-18} {2,-14} {3,-18} {4}" -f ($i + 1), $v.Display, $src, $b, $cur)
        }
        Write-Host '    b  Back'
        $c = Read-Choice '  choice'
        if ($c -in @('b', 'B', 'q', 'Q')) { return }
        if ($c -match '^[1-9]$' -and [int]$c -le $ids.Count) {
            $script:VariantInfo = $Variants[$ids[[int]$c - 1]]
            Write-Host "  selected: $($script:VariantInfo.Display)"
            Write-Host "  source  : $(Get-VariantSourceDir $script:VariantInfo)"
            Write-Host ''
            continue
        }
        Write-Host '  ?'
    }
}
function Show-Menu {
    while ($true) {
        Show-Status
        Write-Host '  What do you want to do?'
        Write-Host '    1  INSTALL   (full: apply + refresh every logged-on profile + verify PASS)'
        Write-Host '    2  UNINSTALL (full: restore originals + refresh every profile + verify PASS)'
        Write-Host '    3  Apply / re-apply the ARC icons'
        Write-Host '    4  Revert to Windows default icons'
        Write-Host '    5  Status + verification (above)'
        Write-Host '    6  Refresh every profile''s icon cache'
        Write-Host '    7  Re-merge after a Windows Update'
        Write-Host '    8  Enable auto-repair at startup'
        Write-Host '    9  Disable auto-repair at startup'
        Write-Host '   10  Repair (re-apply if drifted + refresh the icon cache)'
        Write-Host '   11  Choose the icon variant (ARC / ARC Symbolic / Arc Neutral Brown / Arc Neutral Grey / Arc Dark Grey)'
        Write-Host '    q  Quit'
        $c = Read-Choice '  choice'
        switch ($c) {
            '1' { Invoke-Install }
            '2' { Invoke-Uninstall }
            '3' { Invoke-Apply }
            '4' { Invoke-Revert }
            '5' { }
            '6' { Invoke-Refresh }
            '7' { Invoke-Merge }
            '8' { Invoke-Task $true }
            '9' { Invoke-Task $false }
            '10' { Invoke-Repair }
            '11' { Show-VariantMenu }
            { $_ -in 'q', 'Q' } { return }
            default { Write-Host '  ?' }
        }
    }
}

# ---- entry ----
$Variant = Get-ArcIconsDefaultVariant $Variant $PSBoundParameters.ContainsKey('Variant') (Get-BuiltTheme)
$script:VariantInfo = Resolve-Variant $Variant   # fail on an unknown variant before any elevation prompt

# Sandbox guard: a data root other than this script's own folder may never pair
# with the default live SystemResources directory. Both must be explicit.
$sandboxRun = ((Resolve-ArcIconsCanonicalPath $Root) -ine (Resolve-ArcIconsCanonicalPath $Tool))
if ($sandboxRun -and (-not $PSBoundParameters.ContainsKey('SystemResourceDir'))) {
    Write-Host ''
    Write-Host '  ARC-Icons: REFUSED - a non-default -Root requires an explicit -SystemResourceDir.' -ForegroundColor Red
    Write-Host '  usage: ARC-Icons.ps1 -Action install -Root <dir> -SystemResourceDir <dir> [-Variant <id>]' -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Admin)) {
    Write-Host '  needs Administrator - asking for elevation...'
    $exe = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Action', $Action, '-Variant', $script:VariantInfo.Id)
    if ($Yes) { $argList += '-Yes' }
    if ($DryRun) { $argList += '-DryRun' }
    if ($CleanState) { $argList += '-CleanState' }
    if ($sandboxRun) { $argList += @('-Root', $Root) }
    if ($PSBoundParameters.ContainsKey('SystemResourceDir')) { $argList += @('-SystemResourceDir', $SystemResourceDir) }
    # Wait for the elevated window and hand its exit code back to the launcher:
    # ARC-Icons.cmd pauses on a non-zero code, so a refusal is read, not lost.
    try {
        $p = Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList -PassThru -Wait
    } catch {
        Write-Host ("  elevation cancelled or failed: {0}" -f $_) -ForegroundColor Red
        exit 1
    }
    $code = 0
    try { $code = [int]$p.ExitCode } catch { $code = 0 }
    exit $code
}

try {
    switch ($Action) {
        'status' { Show-Status }
        'install' { Invoke-Install }
        'uninstall' { Invoke-Uninstall }
        'apply' { Invoke-Apply }
        'revert' { Invoke-Revert }
        'repair' { Invoke-Repair }
        'refresh' { Invoke-Refresh }
        'merge' { Invoke-Merge }
        'task-on' { Invoke-Task $true }
        'task-off' { Invoke-Task $false }
        default { Show-Menu }
    }
} finally {
    # shell guarantee: runs on success, failure, refusal and interrupt alike
    # (PowerShell runs `finally` for a script `exit` — measured 2026-10-14).
    [void](Restore-ArcIconsShell 'ARC-Icons.ps1 exit')
}
exit 0
