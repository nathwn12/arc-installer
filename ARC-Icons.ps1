# ARC-Icons.ps1 - all-in-one controller for the ARC icon theme on this PC
# variant selector, repair verb, payload table
# variant-aware verify/merge, self-chaining
#   variant switch, visible refusals, guaranteed explorer restart/restore
#
# Usage:
#   ARC-Icons.cmd                     -> interactive menu (double-click this):
#                                        1  Install theme
#                                        2  Remove theme
#                                        3  Check status
#                                        4  Choose theme variant
#                                        q  Quit
#   ARC-Icons.ps1 -Action install     -> INSTALL   (full: capture-if-fresh, merge the
#                                        chosen variant, restore-if-switching, apply,
#                                        refresh EVERY logged-on profile's icon +
#                                        thumbnail cache, verify PASS)
#   ARC-Icons.ps1 -Action uninstall   -> UNINSTALL (full: restore the pristine
#                                        originals, refresh every logged-on profile,
#                                        verify PASS (mode=original))
#   ARC-Icons.ps1 -Action status      -> read-only: show state + verify (exit non-zero
#                                        when verification fails)
#
# Advanced (CLI only; not in the menu. Names and behavior unchanged):
#   ARC-Icons.ps1 -Action apply       -> apply / re-apply the ARC icons (no variant switch)
#   ARC-Icons.ps1 -Action revert      -> put Windows' own icons back
#   ARC-Icons.ps1 -Action repair      -> re-apply ONLY if the live payload drifted, then refresh the icon cache
#   ARC-Icons.ps1 -Action refresh     -> rebuild every logged-on profile's shell icon cache
#   ARC-Icons.ps1 -Action merge       -> rebuild the merged files from originals + theme
#   ARC-Icons.ps1 -Action task-on     -> enable auto-repair at startup
#   ARC-Icons.ps1 -Action task-off    -> disable auto-repair at startup
#
#   Every action exits 0 only when its whole chain succeeded. A verify FAIL after
#   any action, a refresh that leaves a profile without explorer, a child script
#   exiting non-zero, or a stale stage all exit non-zero.
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
# the operator never has to run three commands by hand. Before that chain moves
# anything, EVERY live payload is classified (recorded original | recorded
# merge | unknown) and an unknown one refuses the switch, naming the file, its
# hash and the rebase path: a switch must never clobber a newer Windows
# payload. The chain asks ONCE, before the first mutation; declining leaves the
# machine exactly as it was.
# apply.ps1 on its own still refuses a live payload that is neither the
# recorded original nor the recorded merge, because at that point live holds
# the PREVIOUS theme's merge.
# Stale stage: installed-manifest.json records the theme sha256 the stage was
# merged from (sourceOrigin.files[]). Install and Apply re-hash the theme on
# disk first; when any recorded hash disagrees (or the manifest cannot prove
# it: no sourceOrigin, older manifest) the stage is STALE and this controller
# re-merges the requested variant (merge -> restore -> apply -> verify) instead
# of trusting it. apply.ps1 never re-merges by itself; it refuses with a
# stale-stage reason and names this rebuild path.
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
# Stale-stage check: installed-manifest.json's sourceOrigin.files[] holds the
# sha256 of every theme file the stage was merged from. Re-hash the theme on
# disk for the manifest's variant and report any disagreement. Returns
# { Stale, VariantId, VariantDisplay, SourceDir, Reason, Detail }. A manifest
# with no usable sourceOrigin is treated as stale on purpose: an unprovable
# stage is never trusted, it is rebuilt. Never throws.
# Kept byte-for-byte in step with the copy in apply.ps1 (same function name;
# apply.ps1 runs as a child process, never in this process).
function Get-ArcIconsStageStaleness($InstalledManifest, [string]$RootC) {
    $res = [pscustomobject]@{
        Stale = $true; VariantId = ''; VariantDisplay = ''; SourceDir = ''; Reason = ''; Detail = @()
    }
    $man = $InstalledManifest
    if ($null -eq $man) {
        $res.Reason = 'installed-manifest.json is missing, so the stage cannot be proven against the theme on disk. Rebuild it: run ARC-Icons.ps1 -Action install -Variant <id> -Yes (re-merge -> restore pristine originals -> apply -> verify).'
        return $res
    }
    $vid = ''
    if ($man.PSObject.Properties['variantId']) { $vid = [string]$man.variantId }
    $res.VariantId = $vid
    $vinfo = $null
    if ($vid) { $vinfo = Get-ArcIconsVariantInfo $vid }
    if ($vinfo) { $res.VariantDisplay = [string]$vinfo.Display }
    elseif ($man.PSObject.Properties['theme']) { $res.VariantDisplay = [string]$man.theme }
    $label = $vid
    if (-not $label) { $label = '<variant>' }
    $rebuild = ("Rebuild it: run ARC-Icons.ps1 -Action install -Variant '{0}' -Yes (re-merge -> restore pristine originals -> apply -> verify)." -f $label)

    $so = $null
    if ($man.PSObject.Properties['sourceOrigin']) { $so = $man.sourceOrigin }
    $rows = @()
    if ($so -and $so.PSObject.Properties['files']) { $rows = @($so.files) }
    if ((-not $so) -or ($rows.Count -eq 0)) {
        $res.Reason = ('installed-manifest.json carries no sourceOrigin theme hashes (older manifest), so the stage cannot be proven against the theme on disk. ' + $rebuild)
        return $res
    }
    $rel = ''
    if ($so.PSObject.Properties['sourceDir']) { $rel = [string]$so.sourceDir }
    if ((-not $rel) -and $vinfo) { $rel = 'theme\' + $vinfo.ThemeDir }
    if (-not $rel) {
        $res.Reason = ('installed-manifest.json records no theme source directory (sourceOrigin.sourceDir), so the stage cannot be proven against the theme on disk. ' + $rebuild)
        return $res
    }
    try { $srcDir = Resolve-ArcIconsRootChildPath $RootC $rel 'sourceOrigin.sourceDir' }
    catch {
        $res.Reason = ("installed-manifest.json sourceOrigin.sourceDir '{0}' is not a usable path under -Root ({1}). {2}" -f $rel, $_, $rebuild)
        return $res
    }
    $res.SourceDir = $srcDir

    $byName = @{}
    foreach ($r in $rows) {
        $n = ([string]$r.name).ToLowerInvariant()
        if ($n) { $byName[$n] = $r }
    }
    $mismatch = @()
    $missing = @()
    foreach ($n in @('imageres.dll', 'imagesp1.dll', 'zipfldr.dll')) {
        $row = $byName[$n]
        if ($null -eq $row) { $missing += ("{0}: no sourceOrigin row" -f $n); continue }
        $rec = ''
        if ($row.PSObject.Properties['sha256']) { $rec = ([string]$row.sha256).ToUpperInvariant() }
        if (-not $rec) { $missing += ("{0}: sourceOrigin row carries no sha256" -f $n); continue }
        $diskPath = Join-Path $srcDir $n
        if (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) { $missing += ("{0}: theme file missing on disk ({1})" -f $n, $diskPath); continue }
        try { $disk = Get-ArcIconsSha256 $diskPath }
        catch { $missing += ("{0}: theme file unreadable ({1}): {2}" -f $n, $diskPath, $_); continue }
        if ($disk -ne $rec) { $mismatch += ("{0}: recorded {1}, theme on disk {2}" -f $n, $rec, $disk) }
    }
    if (($mismatch.Count -gt 0) -or ($missing.Count -gt 0)) {
        $parts = @()
        if ($mismatch.Count -gt 0) { $parts += ('theme hash mismatch: ' + ($mismatch -join '; ')) }
        if ($missing.Count -gt 0) { $parts += ('recorded row missing: ' + ($missing -join '; ')) }
        $res.Detail = @($mismatch + $missing)
        $res.Reason = ("installed-manifest.json was merged from a different theme generation than the theme on disk on this PC ({0}). {1}" -f ($parts -join ' | '), $rebuild)
        return $res
    }
    $res.Stale = $false
    return $res
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
    # a closed / exhausted stdin must quit, never hang or spin the menu: a
    # redirected read that returns $null is EOF, and an empty line is a quit.
    # Read-Host does NOT read a redirected stdin under -File, so redirected
    # input uses Console.In directly (that also makes the menu scriptable).
    try {
        if ([Console]::IsInputRedirected) {
            $line = [Console]::In.ReadLine()
            if ($null -eq $line) { return 'q' }
            if (-not $line.Trim()) { return 'q' }
            return $line
        }
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
    # Read-only verb, but never a false OK: the verify exit code IS this
    # action's exit code (a FAIL must reach the caller, GUI or shell). Every
    # action resets the code here at its start, so a cancelled or previewed
    # action returns 0 while a failure is never wiped by the menu loop.
    $script:ExitCode = 0
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
        Write-Host '        run INSTALL once - it is idempotent - to record the state and get a PASS.' -ForegroundColor Yellow
    } else {
        & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
        $script:ExitCode = [int]$LASTEXITCODE
        if ($script:ExitCode -ne 0) {
            Write-Host ("  status  : verify FAILED (exit {0}) - read the FAIL lines above." -f $script:ExitCode) -ForegroundColor Red
        }
    }
    Write-Host ''
}
function Invoke-Apply {
    $script:ExitCode = 0
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
    # Variant switch = the documented recipe (merge -> restore -> apply) run for
    # the operator. Nothing here mutates anything until the SINGLE confirmation
    # in the preflight below: the old flow merged+restored first and then asked
    # again, so declining left stock icons installed with no theme (t28).
    # ---- preflight: nothing has been mutated yet ----
    $switching = ($built -ne $v.Display)
    $stale = Get-ArcIconsStageStaleness (Read-Json $InstMan) (Resolve-ArcIconsCanonicalPath $Root)
    $rebuild = [bool]$stale.Stale
    $liveState = Get-ArcIconsLivePayloadState
    $needRestore = ($switching -or ($rebuild -and ($liveState -eq 'merged')))
    Write-Host ("  target : {0}\{{imageres,imagesp1,zipfldr}}.dll.mun" -f $SysDir)
    if ($switching) {
        Write-Host ("  variant switch: built payload is '{0}', requested '{1}'." -f $(if ($built) { $built } else { 'none' }), $v.Display)
    }
    if ($rebuild) {
        # one line naming why the rebuild happens, before anything is touched
        Write-Host ("  stale stage - rebuilding instead of trusting it: {0}" -f $stale.Reason)
    }
    if ($needRestore) {
        Write-Host '  chain : merge this variant -> restore pristine originals -> apply -> verify'
    } else {
        Write-Host '  chain : apply the recorded stage -> verify'
    }
    if ($DryRun) {
        Write-Host '  -DryRun: nothing changed.'
        return
    }
    # A restore overwrites the live payload, so classify EVERY live file before
    # any mutation: an unknown payload (Windows Update or a manual change) is
    # never clobbered by a switch. apply.ps1 refuses it too, but only after the
    # merge and restore would already have run.
    if ($needRestore) {
        $liveRows = @(Get-ArcIconsLivePayloadClassification)
        $unknown = @($liveRows | Where-Object { $_.State -eq 'unknown' })
        if ($unknown.Count -gt 0) {
            $detail = (@(Format-ArcIconsUnknownLivePayload $unknown) -join "`n  ")
            $detail += ("`n  Rebase path: bin\Rebase-ArcIconsOriginal.ps1 -Root <root> -SystemResourceDir <dir> -Name <file> -ExpectLiveHash <hash> -Commit, then re-run this switch (docs\REPAIR-MANUAL.md, ""After a Windows Update""). Nothing changed.")
            Stop-Visible ("ARC-ICONS-SWITCH: REFUSED - at least one live payload is neither the recorded original nor the recorded merge, so a variant switch would clobber it:`n  " + $detail) 1 ''
        }
    }
    # ONE confirmation, before the first mutation. Every later step is
    # non-interactive, so there is no point at which a decline can strand the
    # machine between merge and apply.
    $what = 'Apply now?'
    if ($needRestore) { $what = ("Switch to '{0}' now (merge -> restore pristine originals -> apply -> verify)?" -f $v.Display) }
    if (-not (Confirm $what)) { Write-Host '  cancelled'; return }
    if ($needRestore) {
        Write-Host ''
        Write-Host ("  [1/3] MERGE   - rebuild stage\ + installed-manifest.json for {0}" -f $v.Display)
        & $PSExe -NoProfile -File $Merge -Root $Root -Build -Variant $v.Id
        if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-MERGE: FAILED (exit {0}) for variant '{1}'; live payload untouched, nothing applied." -f $LASTEXITCODE, $v.Display) $LASTEXITCODE }
        Write-Host ("  [2/3] RESTORE - put the pristine originals back into {0} (icon cache left to the apply step)" -f $SysDir)
        & $PSExe -NoProfile -File $Restore -Root $Root -SystemResourceDir $SysDir -CloseHolders -SkipIconCacheRefresh
        if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-RESTORE: FAILED (exit {0}); nothing applied." -f $LASTEXITCODE) $LASTEXITCODE }
        Write-Host '  [3/3] APPLY   - install the merged payload'
    }
    $a = @('-NoProfile', '-File', $Apply, '-Root', $Root, '-SystemResourceDir', $SysDir, '-CloseHolders') + (Get-ArcIconsApplyVariantArguments $v.Id)
    & $PSExe @a
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-APPLY: FAILED (exit {0}) - see the output above." -f $LASTEXITCODE) $LASTEXITCODE 'the shell was restored; live files are rolled back to the pristine originals.' }
    Write-Host ''
    & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-VERIFY: FAILED (exit {0}) after apply." -f $LASTEXITCODE) $LASTEXITCODE 'the payload is installed but does not verify; read the FAIL lines above before using the shell.' }
    $script:ExitCode = 0
}
function Show-RefreshProfiles($r) {
    foreach ($p in @($r.Profiles)) {
        $mark = if ($p.Ok) { 'ok' } else { 'FAIL' }
        Write-Host ("    session {0,-3} {1,-26} {2,-15} {3}  {4}" -f $p.SessionId, $p.Account, $p.Mode, $mark, $p.Note)
    }
}
function Get-ArcIconsLivePayloadClassification {
    # One row per allowlisted payload: State is 'original' (live == recorded
    # pristine original), 'merged' (live == the RECORDED merge) or 'unknown'
    # (anything else: Windows Update, a manual edit, a missing file). A switch
    # refuses on ANY 'unknown' before it touches the machine.
    $man = Read-Json $OrigMan
    $inst = Read-Json $InstMan
    $rows = @()
    foreach ($t in $Targets) {
        $name = $t.Name
        $p = Join-Path $SysDir $name
        $h = ''
        $state = 'unknown'
        $note = ''
        $orgRow = $null
        if ($man) { $orgRow = @($man.files | Where-Object { [string]$_.name -eq $name })[0] }
        $instRow = $null
        if ($inst) { $instRow = @($inst.files | Where-Object { [string]$_.name -eq $name })[0] }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            $note = 'live file missing'
        } else {
            try { $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToUpperInvariant() }
            catch { $h = ''; $note = 'live hash unreadable' }
            if ($h -and $orgRow -and ($h -eq ([string]$orgRow.originalSha256).ToUpperInvariant())) {
                $state = 'original'
            } elseif ($h -and $instRow -and ($h -eq ([string]$instRow.mergedSha256).ToUpperInvariant())) {
                $state = 'merged'
            } elseif ($h) {
                $state = 'unknown'
            }
        }
        $rows += [pscustomobject]@{ Name = $name; Live = $p; Hash = $h; State = $state; Note = $note }
    }
    return $rows
}
function Format-ArcIconsUnknownLivePayload($Rows) {
    # file name + its actual hash for every unknown live payload (the switch
    # refusal must let the operator run the rebase with the real value).
    $lines = @()
    foreach ($r in @($Rows)) {
        $h = [string]$r.Hash
        if (-not $h) { $h = '<unreadable>' }
        $note = ''
        if ($r.Note) { $note = ' (' + [string]$r.Note + ')' }
        $lines += ("{0}: live hash {1} is neither the recorded original nor the recorded merge{2}" -f $r.Name, $h, $note)
    }
    return $lines
}
function Get-ArcIconsLivePayloadState {
    # 'original' = every live file is the pristine original; 'merged' = the rest
    # are the RECORDED merge and none is unknown; 'unknown' = at least one live
    # file matches neither (Windows Update or a manual edit) and must not be
    # overwritten by a full install.
    $rows = @(Get-ArcIconsLivePayloadClassification)
    if (@($rows | Where-Object { $_.State -eq 'unknown' }).Count -gt 0) { return 'unknown' }
    if (@($rows | Where-Object { $_.State -eq 'merged' }).Count -gt 0) { return 'merged' }
    return 'original'
}
function Invoke-Install {
    $script:ExitCode = 0
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
    $staleReason = ''
    if (-not $freshMachine) {
        $liveState = Get-ArcIconsLivePayloadState
        # Same stale-stage check apply.ps1 runs. Install always re-merges, so
        # the effect here is that an unprovable stage is named and rebuilt
        # rather than applied on trust (t28: a 2026-10-14 stage applied after
        # the theme was regenerated 2026-11-06).
        $stale = Get-ArcIconsStageStaleness (Read-Json $InstMan) (Resolve-ArcIconsCanonicalPath $Root)
        if ($stale.Stale) { $staleReason = [string]$stale.Reason }
    }
    Write-Host ("  root   : {0}" -f $Root)
    Write-Host ("  target : {0}\{{imageres,imagesp1,zipfldr}}.dll.mun" -f $SysDir)
    Write-Host ("  state  : {0}; built variant: {1}; live payload: {2}" -f (Get-Mode), $(if ($built) { $built } else { 'none' }), $liveState)
    if ($staleReason) {
        Write-Host ("  stale stage - rebuilding instead of trusting it: {0}" -f $staleReason)
    }
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
        $rows = @(Get-ArcIconsLivePayloadClassification)
        $unknown = @($rows | Where-Object { $_.State -eq 'unknown' })
        $detail = (@(Format-ArcIconsUnknownLivePayload $unknown) -join "`n  ")
        $detail += ("`n  Rebase path: bin\Rebase-ArcIconsOriginal.ps1 -Root <root> -SystemResourceDir <dir> -Name <file> -ExpectLiveHash <hash> -Commit (docs\REPAIR-MANUAL.md, ""After a Windows Update""), then install again. Nothing changed.")
        Stop-Visible ("ARC-ICONS-INSTALL: REFUSED - at least one live payload is neither the recorded original nor the recorded merge (Windows Update or a manual change):`n  " + $detail) 1 ''
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
    $script:ExitCode = 0
}
function Invoke-Uninstall {
    $script:ExitCode = 0
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
    # Removal is the destructive direction: say plainly that the ARC icons go
    # away and the stock Windows icons come back BEFORE asking.
    Write-Host '  WARNING: removing the theme puts the stock Windows icons back; the ARC icons will no longer be shown.' -ForegroundColor Yellow
    if (-not (Confirm 'Remove the ARC theme and restore the stock Windows icons now?')) { Write-Host '  cancelled'; return }
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
    $script:ExitCode = 0
}
function Invoke-Revert {
    $script:ExitCode = 0
    Write-Head 'REVERT - put Windows own icons back'
    Write-Host '  restores the pristine files backed up before the theme was installed'
    if (-not (Confirm 'Revert now?')) { Write-Host '  cancelled'; return }
    $a = @('-NoProfile', '-File', $Restore, '-Root', $Root, '-SystemResourceDir', $SysDir, '-CloseHolders')
    if ($DryRun) { $a += '-DryRun' }
    & $PSExe @a
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-RESTORE: FAILED (exit {0}) - see the output above." -f $LASTEXITCODE) $LASTEXITCODE 'the shell was restored; live files are rolled back to the pristine originals.' }
    if ($DryRun) { Write-Host '  -DryRun: preview only; nothing restored.'; return }
    Write-Host ''
    & $PSExe -NoProfile -File $Verify -Root $Root -SystemResourceDir $SysDir
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-VERIFY: FAILED (exit {0}) after revert." -f $LASTEXITCODE) $LASTEXITCODE 'the restore ran but the live payload does not verify; follow docs\REPAIR-MANUAL.md.' }
    $script:ExitCode = 0
}
function Invoke-Repair {
    $script:ExitCode = 0
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
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-VERIFY: FAILED (exit {0}) after repair." -f $LASTEXITCODE) $LASTEXITCODE 'the repair ran but the live payload does not verify; follow docs\REPAIR-MANUAL.md.' }
    $script:ExitCode = 0
}
function Invoke-Refresh {
    $script:ExitCode = 0
    Write-Head 'REFRESH - rebuild every logged-on profile''s shell icon cache'
    # one mechanism only: the shared multi-user refresh stops each profile's own
    # explorer, drops iconcache*.db AND thumbcache*.db, runs ie4uinit -show,
    # restarts that shell and proves it came back in that session.
    $r = Invoke-ArcIconsPerUserIconCacheRefresh -Root $Root -SysDir $SysDir -Skip $false
    Write-Host ("  {0}" -f $r.Note)
    Show-RefreshProfiles $r
    [void](Restore-ArcIconsShell 'refresh')
    # A refresh that leaves any logged-on profile without its explorer is a
    # FAILED action, not a note: exit non-zero and name the profile.
    if (-not $r.Ok) {
        Stop-Visible ("ARC-ICONS-REFRESH: FAIL - at least one logged-on profile has no verified explorer after the refresh: {0}" -f ($r.Failures -join '; ')) 1 'the profile list above names what failed; sign out/in and run these icons again.'
    }
    $script:ExitCode = 0
}
function Invoke-Merge {
    $script:ExitCode = 0
    Write-Head 'MERGE - rebuild the merged files from the pristine originals + theme'
    Write-Host '  use this after a Windows Update replaced the originals (then re-apply)'
    $v = $script:VariantInfo
    Write-Host ("  variant: {0}   source: theme\{1}" -f $v.Display, $v.ThemeDir)
    if (-not (Confirm 'Rebuild merged files now?')) { Write-Host '  cancelled'; return }
    & $PSExe -NoProfile -File $Merge -Root $Root -Build -Variant $v.Id
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-MERGE: FAILED (exit {0}) for variant '{1}'." -f $LASTEXITCODE, $v.Display) $LASTEXITCODE }
    & $PSExe -NoProfile -File $Merge -Root $Root -Verify -Variant $v.Id
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-MERGE: VERIFY FAILED (exit {0}) for variant '{1}'; the stage was rebuilt but does not verify." -f $LASTEXITCODE, $v.Display) $LASTEXITCODE }
    $script:ExitCode = 0
}
function Invoke-Task($on) {
    $script:ExitCode = 0
    if ($on) {
        Write-Head 'AUTO-REPAIR - enable at startup'
        & $PSExe -NoProfile -File $TaskOn -Root $Root -SystemResourceDir $SysDir
    } else {
        Write-Head 'AUTO-REPAIR - disable'
        & $PSExe -NoProfile -File $TaskOff
    }
    if ($LASTEXITCODE -ne 0) { Stop-Visible ("ARC-ICONS-TASK: FAILED (exit {0}) - the scheduled task was not changed." -f $LASTEXITCODE) $LASTEXITCODE }
    $script:ExitCode = 0
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
        Write-Head 'ARC icon theme'
        Write-Host ("  variant : {0}  [{1}]" -f $script:VariantInfo.Display, $script:VariantInfo.Id)
        Write-Host '  What do you want to do?'
        Write-Host '    1  Install theme'
        Write-Host '    2  Remove theme'
        Write-Host '    3  Check status'
        Write-Host '    4  Choose theme variant'
        Write-Host '    q  Quit'
        $c = Read-Choice '  choice'
        # No reset here: every action resets the code itself, so a soft failure
        # (a Show-Status verify FAIL) survives until the next action and
        # quitting right after it exits non-zero instead of inventing an OK.
        switch ($c) {
            '1' { Invoke-Install }
            '2' { Invoke-Uninstall }
            '3' { Show-Status }
            '4' { Show-VariantMenu }
            { $_ -in 'q', 'Q' } { return }
            default { Write-Host '  ?' }
        }
    }
}

# ---- entry ----
# One exit code for the whole run: every action sets it (0 on success, non-zero
# on a soft failure) and hard failures exit through Stop-Visible. The final
# `exit` below must never invent an OK.
$script:ExitCode = 0
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
exit ([int]$script:ExitCode)
