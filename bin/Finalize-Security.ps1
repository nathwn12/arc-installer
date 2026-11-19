param(
    [string]$Root = (Join-Path $env:ProgramData 'ArcIcons'),
    [string]$SystemResourceDir = (Join-Path $env:SystemRoot 'SystemResources'),
    [switch]$Plan
)
$ErrorActionPreference = 'Stop'
$TI = 'NT SERVICE\TrustedInstaller'
$SID = 'arcinstaller'
$Log = Join-Path $Root 'logs\finalize-security.jsonl'

if (-not ('Fin' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Fin {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool LookupPrivilegeValueW(string host, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TOKEN_PRIVILEGES ns, uint len, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool SetFileSecurityW(string path, uint info, byte[] sd);
    public static bool Enable(string name) {
        IntPtr tok; if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
        LUID luid; if (!LookupPrivilegeValueW(null, name, out luid)) return false;
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES(); tp.PrivilegeCount = 1;
        tp.Privileges.Luid = luid; tp.Privileges.Attributes = 2;
        bool ok = AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        return ok && Marshal.GetLastWin32Error() == 0;
    }
}
'@
}
foreach ($pv in 'SeRestorePrivilege', 'SeBackupPrivilege', 'SeTakeOwnershipPrivilege') { [void][Fin]::Enable($pv) }

$OWNER = 0x1; $GROUP = 0x2; $DACL = 0x4; $PROTECTED = [uint32]2147483652
function Bin($sddl) {
    $rsd = New-Object System.Security.AccessControl.RawSecurityDescriptor($sddl)
    $b = New-Object byte[] $rsd.BinaryLength
    $rsd.GetBinaryForm($b, 0)
    return $b
}
function Full($p) { (Get-Acl -LiteralPath $p).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All) }

function Set-Baseline($p, $sddl) {
    [void][Fin]::SetFileSecurityW($p, [uint32]($OWNER -bor $GROUP), (Bin $sddl))
    [void][Fin]::SetFileSecurityW($p, [uint32]$DACL, (Bin $sddl))
    $now = Full $p
    if ($now -ne $sddl) {
        [void][Fin]::SetFileSecurityW($p, $PROTECTED, (Bin $sddl))
        $now = Full $p
    }
    return $now
}

$man = Get-Content (Join-Path $Root 'originals\manifest.json') -Raw | ConvertFrom-Json
$targets = @()
foreach ($f in $man.files) {
    $targets += [pscustomobject]@{ Label = "live $($f.name)"; Path = (Join-Path $SystemResourceDir $f.name); Sddl = $f.sddl }
}
$winsxs = Join-Path $env:SystemRoot 'WinSxS'
foreach ($f in $man.files) {
    $hits = @(Get-ChildItem $winsxs -Recurse -Filter $f.name -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like "*microsoft-windows-$($f.name -replace '\.dll\.mun$','')*" })
    foreach ($h in $hits) { $targets += [pscustomobject]@{ Label = "winsxs $($f.name)"; Path = $h.FullName; Sddl = $f.sddl } }
}

Write-Host '=== baseline security apply ==='
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t.Path)) { Write-Host "  $($t.Label): MISSING"; continue }
    if ($Plan) { Write-Host "  $($t.Label): would set owner+group+DACL"; continue }
    $before = Full $t.Path
    $after = Set-Baseline $t.Path $t.Sddl
    $exact = ($after -eq $t.Sddl)
    $note = if ($exact) { 'exact' } else { 'ACEs match, control-flag difference only: ' + (($t.Sddl -split '\(')[0]) + ' vs ' + (($after -split '\(')[0]) }
    Write-Host ("  {0,-26} owner={1,-28} exact={2}" -f $t.Label, (Get-Acl -LiteralPath $t.Path).Owner, $exact)
    if (-not $exact) { Write-Host "      baseline: $($t.Sddl)"; Write-Host "      now     : $after" }
    ($t | Add-Member -NotePropertyName before -NotePropertyValue $before -Force) | Out-Null
    @{ ts = (Get-Date).ToString('o'); session = $SID; label = $t.Label; path = $t.Path; exact = $exact; sddl = $after } | ConvertTo-Json -Compress | Add-Content -LiteralPath $Log -Encoding UTF8
}
