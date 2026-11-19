param(
    [string]$Root = (Join-Path $env:ProgramData 'ArcIcons'),
    [string]$SystemResourceDir = (Join-Path $env:SystemRoot 'SystemResources'),
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ExpectLiveHash,
    [string]$BaseVersion = '',
    [switch]$DryRun = $true,
    [switch]$Commit,
    [int]$LockTimeoutSec = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Set-BaselineSecurity.ps1')

try {
    if ($Commit -and $PSBoundParameters.ContainsKey('DryRun') -and [bool]$DryRun) {
        throw '-DryRun and -Commit are mutually exclusive: give -Commit alone to write, or omit -Commit to preview.'
    }
    $isDryRun = -not $Commit.IsPresent
    $RootC = Resolve-ArcIconsCanonicalPath $Root
    if (-not (Test-Path -LiteralPath $RootC -PathType Container)) { throw ("-Root not found: {0}" -f $RootC) }
    if ($RootC -like 'C:\Windows*') { throw ("Refusing a -Root under C:\Windows (got '{0}')." -f $RootC) }
    $SysC = Resolve-ArcIconsCanonicalPath $SystemResourceDir
    if (-not (Test-Path -LiteralPath $SysC -PathType Container)) { throw ("-SystemResourceDir not found: {0}" -f $SysC) }
    $r = Invoke-ArcIconsOriginalRebase -RootC $RootC -SysC $SysC -Name $Name -ExpectLiveHash $ExpectLiveHash -BaseVersion $BaseVersion -DryRun $isDryRun -LockTimeoutSec $LockTimeoutSec
    if (-not $r) { throw 'rebase produced no result object.' }
}
catch {
    Write-Output ("ARC-REBASE: REFUSED, no changes made: {0}" -f $_)
    exit 1
}

foreach ($line in @($r.Plan)) { Write-Output $line }
if ($r.Status -eq 'already-rebased') {
    Write-Output ("ARC-REBASE: OK already-rebased {0} (recorded original {1} == live, pristine backup verified); no changes made" -f $r.Name, $r.OriginalSha)
}
elseif ($r.Status -eq 'planned') {
    Write-Output 'ARC-REBASE: DRY-RUN plan (no changes made)'
    Write-Output ("ARC-REBASE: OK dry-run plan for {0}; re-run with -Commit to write" -f $r.Name)
}
else {
    Write-Output ("ARC-REBASE: OK rebased {0}: original {1} -> {2}, superseded {3}" -f $r.Name, $r.MergedSha, $r.LiveSha, $r.SupersededDir)
}
exit 0
