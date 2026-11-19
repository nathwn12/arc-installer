param(
    [string]$Root = (Join-Path $env:ProgramData 'ArcIcons'),
    [string]$SystemResourceDir = (Join-Path $env:SystemRoot 'SystemResources'),
    [switch]$Plan,
    [switch]$CloseHolders,
    [switch]$Rollback,
    [switch]$RestoreSecurity
)
$ErrorActionPreference = 'Stop'
$Log = Join-Path $Root 'logs\live-install.jsonl'
$SID = 'arcinstaller'
$TI = 'NT SERVICE\TrustedInstaller'

if (-not ('SecV4' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SecV4 {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool SetFileSecurityW(string path, uint info, byte[] sd);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] static extern int RmStartSession(out uint h, int f, string k);
    [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint h);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] static extern int RmRegisterResources(uint h, uint n, string[] f, uint a, IntPtr ap, uint s, string[] sn);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint needed, ref uint count, [In,Out] IntPtr[] arr, ref uint reasons);
    [StructLayout(LayoutKind.Sequential)] struct U { public int pid; public System.Runtime.InteropServices.ComTypes.FILETIME t; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct P { public U p; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string app; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string svc; public int type; public uint status; public uint sess; [MarshalAs(UnmanagedType.Bool)] public bool restart; }
    public static int[] Holders(string[] files) {
        uint h; if (RmStartSession(out h, 0, Guid.NewGuid().ToString()) != 0) return new int[0];
        try {
            if (RmRegisterResources(h, (uint)files.Length, files, 0, IntPtr.Zero, 0, null) != 0) return new int[0];
            uint need = 0, cnt = 0, r = 0;
            RmGetList(h, out need, ref cnt, null, ref r);
            if (need == 0) return new int[0];
            var arr = new P[need]; cnt = need;
            var buf = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(P)) * (int)need);
            try {
                var ptrs = new IntPtr[need];
                for (int i = 0; i < need; i++) ptrs[i] = IntPtr.Add(buf, i * Marshal.SizeOf(typeof(P)));
                RmGetList(h, out need, ref cnt, ptrs, ref r);
                var pids = new List<int>();
                for (int i = 0; i < cnt; i++) { var p = (P)Marshal.PtrToStructure(ptrs[i], typeof(P)); pids.Add(p.p.pid); }
                return pids.ToArray();
            } finally { Marshal.FreeHGlobal(buf); }
        } finally { RmEndSession(h); }
    }
}
'@
}

function Log-Event($obj) {
    $obj | Add-Member -NotePropertyName ts -NotePropertyValue (Get-Date).ToString('o') -Force
    $obj | Add-Member -NotePropertyName session -NotePropertyValue $SID -Force
    ($obj | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $Log -Encoding UTF8
}
function Full-Sddl($p) { (Get-Acl -LiteralPath $p).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All) }
function Dacl-Of($p) { (Get-Acl -LiteralPath $p).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access) }
function Base-Dacl($sddl) { 'D:' + ($sddl -split 'D:', 2)[1] }
function Set-SddlDacl($p, $sddl) {
    $rsd = New-Object System.Security.AccessControl.RawSecurityDescriptor($sddl)
    $bin = New-Object byte[] $rsd.BinaryLength
    $rsd.GetBinaryForm($bin, 0)
    $mask = [uint32]2147483652   # PROTECTED_DACL_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION
    $ok = [SecV4]::SetFileSecurityW($p, $mask, $bin)
    if (-not $ok) { throw "SetFileSecurityW failed for $p" }
}
function Set-OwnerTi($p) { if ((Get-Acl -LiteralPath $p).Owner -ne $TI) { icacls "$p" /setowner "$TI" | Out-Null } }
function Test-Locked($p) {
    try { $f = [System.IO.File]::Open($p, 'Open', 'Read', 'None'); $f.Close(); return $false }
    catch [System.IO.IOException] { return $true }
    catch { return $false }
}
function Get-Sibling($p) {
    $vol = [IO.Path]::GetPathRoot($p).TrimEnd('\')
    $lines = @(fsutil hardlink list $p) | Where-Object { $_ -and $_.Trim() }
    $paths = $lines | ForEach-Object { Join-Path $vol ($_.TrimStart('\')) }
    return @($paths | Where-Object { $_ -ne $p })
}
function Make-FileDeletable($p) {
    takeown /f "$p" | Out-Null
    icacls "$p" /grant '*S-1-5-32-544:F' | Out-Null
}
function Restore-SiblingSecurity($p, $sddl) {
    $sib = Get-Sibling $p
    foreach ($s in $sib) {
        Set-OwnerTi $s
        Set-SddlDacl $s $sddl
    }
    return $sib
}

$man = Get-Content (Join-Path $Root 'originals\manifest.json') -Raw | ConvertFrom-Json
$inst = Get-Content (Join-Path $Root 'installed-manifest.json') -Raw | ConvertFrom-Json
$dirSddlFile = Join-Path $Root 'originals\acl\SystemResources.dir.sddl'
if (-not (Test-Path $dirSddlFile)) { throw "directory baseline SDDL missing: $dirSddlFile" }
$dirSddl = (Get-Content $dirSddlFile -Raw).Trim()
$allowed = @('imageres.dll.mun', 'imagesp1.dll.mun', 'zipfldr.dll.mun')

$work = @()
foreach ($f in $man.files) {
    if ($allowed -notcontains $f.name) { throw "unexpected file name: $($f.name)" }
    $row = $inst.files | Where-Object { $_.name -eq $f.name }
    if (-not $row) { throw "no installed-manifest row for $($f.name)" }
    $live = Join-Path $SystemResourceDir $f.name
    $orig = Join-Path $Root $f.originalPath
    $stg = Join-Path $Root $f.stagePath
    $hOrig = (Get-FileHash -LiteralPath $orig -Algorithm SHA256).Hash
    $hStg = (Get-FileHash -LiteralPath $stg -Algorithm SHA256).Hash
    $hLive = (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash
    if ($hOrig -ne $f.originalSha256) { throw "pristine backup drift: $($f.name)" }
    if ($hStg -ne $row.mergedSha256) { throw "staged drift: $($f.name)" }
    $state = if ($hLive -eq $f.originalSha256) { 'original' } elseif ($hLive -eq $row.mergedSha256) { 'installed' } else { 'UNKNOWN' }
    $work += [pscustomobject]@{ Name = $f.name; Live = $live; Orig = $orig; Stage = $stg; Base = $f; Row = $row; State = $state; HOrig = $hOrig; HStg = $hStg; Holders = @([SecV4]::Holders(@($live))) }
}

Write-Host '=== PREFLIGHT ==='
Write-Host "  dir baseline SDDL saved: $dirSddlFile"
foreach ($w in $work) {
    Write-Host ("  {0,-18} state={1,-9} locked={2,-6} holders=[{3}] daclOk={4}" -f $w.Name, $w.State, (Test-Locked $w.Live), (@($w.Holders) -join ','), ((Dacl-Of $w.Live) -eq (Base-Dacl $w.Base.sddl)))
}
$unknown = @($work | Where-Object { $_.State -eq 'UNKNOWN' })
if ($unknown.Count -gt 0) { throw "live file(s) with unknown content: $(($unknown.Name) -join ', ')" }
if ($Plan) { Write-Host 'PLAN ONLY - no changes made'; return }

$dirTaken = $false
function Take-DirAcl {
    takeown /f "$SystemResourceDir" | Out-Null
    icacls "$SystemResourceDir" /grant '*S-1-5-32-544:F' | Out-Null
}
function Restore-DirAcl {
    Set-OwnerTi $SystemResourceDir
    Set-SddlDacl $SystemResourceDir $dirSddl
    $now = Full-Sddl $SystemResourceDir
    Write-Host ("  directory SDDL restored: exact={0}" -f ($now -eq $dirSddl))
    Log-Event @{ op = 'restore-dir-acl'; exact = ($now -eq $dirSddl); sddl = $now }
}

if ($RestoreSecurity) {
    Write-Host '=== RESTORE FILE SECURITY ONLY ==='
    foreach ($w in $work) {
        Set-OwnerTi $w.Live
        Set-SddlDacl $w.Live $w.Base.sddl
        Write-Host ("  {0,-18} owner={1} fullSddlExact={2}" -f $w.Name, (Get-Acl -LiteralPath $w.Live).Owner, ((Full-Sddl $w.Live) -eq $w.Base.sddl))
    }
    return
}

if ($Rollback) {
    Write-Host '=== ROLLBACK (pristine originals) ==='
    Take-DirAcl; $dirTaken = $true
    try {
        foreach ($w in $work) {
            if ((Test-Locked $w.Live) -and $CloseHolders) {
                foreach ($pid in @($w.Holders)) {
                    $pr = Get-Process -Id $pid -ErrorAction SilentlyContinue
                    if ($pr) { Write-Host "    stopping holder $($pr.ProcessName) ($pid)"; Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue }
                }
                Start-Sleep -Milliseconds 400
            }
            if (Test-Locked $w.Live) { Write-Host "  $($w.Name) LOCKED - skipping"; continue }
            Make-FileDeletable $w.Live
            Remove-Item -LiteralPath $w.Live -Force
            Copy-Item -LiteralPath $w.Orig -Destination $w.Live
            Set-OwnerTi $w.Live
            Set-SddlDacl $w.Live $w.Base.sddl
            Restore-SiblingSecurity $w.Live $w.Base.sddl | Out-Null
            $h = (Get-FileHash -LiteralPath $w.Live -Algorithm SHA256).Hash
            Write-Host ("  {0,-18} hash={1} matchesOriginal={2} sddlExact={3}" -f $w.Name, $h.Substring(0, 12), ($h -eq $w.Base.originalSha256), ((Full-Sddl $w.Live) -eq $w.Base.sddl))
        }
    } finally { Restore-DirAcl }
    Write-Host 'ROLLBACK DONE'
    return
}

Write-Host '=== INSTALL ==='
$done = @(); $blocked = @()
Take-DirAcl; $dirTaken = $true
try {
    foreach ($w in $work) {
        if ($w.State -eq 'installed') { Write-Host "  $($w.Name): already installed"; $done += $w.Name; continue }
        if (Test-Locked $w.Live) {
            if ($CloseHolders) {
                foreach ($pid in @($w.Holders)) {
                    $pr = Get-Process -Id $pid -ErrorAction SilentlyContinue
                    if ($pr) { Write-Host "    stopping holder $($pr.ProcessName) ($pid)"; Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue }
                }
                Start-Sleep -Milliseconds 400
            }
        }
        if (Test-Locked $w.Live) { Write-Host "  $($w.Name): BLOCKED (mapped)" -ForegroundColor Yellow; $blocked += $w.Name; continue }
        Make-FileDeletable $w.Live
        Remove-Item -LiteralPath $w.Live -Force
        Copy-Item -LiteralPath $w.Stage -Destination $w.Live
        Set-OwnerTi $w.Live
        Set-SddlDacl $w.Live $w.Base.sddl
        $sib = Restore-SiblingSecurity $w.Live $w.Base.sddl
        $h = (Get-FileHash -LiteralPath $w.Live -Algorithm SHA256).Hash
        $exact = (Full-Sddl $w.Live) -eq $w.Base.sddl
        Write-Host ("  {0,-18} {1} -> {2}  hashOk={3} sddlExact={4} owner={5} siblingRestored=[{6}]" -f $w.Name, $w.HOrig.Substring(0, 12), $h.Substring(0, 12), ($h -eq $w.HStg), $exact, (Get-Acl -LiteralPath $w.Live).Owner, ($sib -join ','))
        Log-Event @{ op = 'install'; name = $w.Name; hash = $h; hashOk = ($h -eq $w.HStg); sddlExact = $exact }
        if ($h -ne $w.HStg) { throw "post-install hash mismatch for $($w.Name)" }
        $done += $w.Name
    }
} finally {
    if ($dirTaken) { Restore-DirAcl }
}
if ($blocked.Count -gt 0) { Write-Host "ARC-ICONS-LIVE: PARTIAL - installed [$($done -join ', ')] blocked [$($blocked -join ', ')]" -ForegroundColor Yellow }
else { Write-Host "ARC-ICONS-LIVE: OK installed -> $($done -join ', ')" }
Log-Event @{ op = 'install-complete'; files = $done; blocked = $blocked }
