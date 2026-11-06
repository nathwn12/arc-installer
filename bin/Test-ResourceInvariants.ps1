# Test-ResourceInvariants.ps1 — read-only resource-byte comparison.
# CLI: -Original <pe> -Merged <pe> -Theme <pe>
# Prints one line per check + final ARC-ICONS-INVARIANT: PASS|FAIL, exit 0|1.
# Safe to point at live files (e.g. C:\Windows\SystemResources\<name>): opens
# read-only via LoadLibraryEx and always frees the module. Writes nothing.
param(
    [Parameter(Mandatory = $true)][string]$Original,
    [Parameter(Mandatory = $true)][string]$Merged,
    [Parameter(Mandatory = $true)][string]$Theme
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ([System.Management.Automation.PSTypeName]'ArcResTest').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class ArcTestEntry {
    public bool TypeIsInt; public int TypeInt; public string TypeForm;
    public bool NameIsInt; public int NameInt; public string NameForm;
    public ushort Lang; public byte[] Data;
}

public static class ArcResTest {
    const uint AS_DATAFILE = 2u;
    const uint AS_IMAGE_RESOURCE = 0x20u;
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr LoadLibraryEx(string f, IntPtr h, uint fl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeLibrary(IntPtr h);
    delegate bool TProc(IntPtr h, IntPtr t, IntPtr p);
    delegate bool NProc(IntPtr h, IntPtr t, IntPtr n, IntPtr p);
    delegate bool LProc(IntPtr h, IntPtr t, IntPtr n, ushort l, IntPtr p);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool EnumResourceTypes(IntPtr h, TProc c, IntPtr p);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool EnumResourceNames(IntPtr h, IntPtr t, NProc c, IntPtr p);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool EnumResourceLanguages(IntPtr h, IntPtr t, IntPtr n, LProc c, IntPtr p);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr FindResourceEx(IntPtr h, IntPtr t, IntPtr n, ushort l);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr LoadResource(IntPtr h, IntPtr i);
    [DllImport("kernel32.dll")]
    static extern IntPtr LockResource(IntPtr d);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint SizeofResource(IntPtr h, IntPtr i);

    static bool IsInt(IntPtr p) { return (((long)p) >> 16) == 0; }
    // Resource-directory strings are COUNTED (WORD length prefix), not
    // null-terminated: PtrToStringUni over-reads into adjacent data.
    static string ExactStr(IntPtr p) {
        try {
            short len = Marshal.ReadInt16(new IntPtr(p.ToInt64() - 2));
            if (len > 0 && len <= 512) {
                char[] c = new char[len];
                for (int i = 0; i < len; i++)
                    c[i] = (char)Marshal.ReadInt16(new IntPtr(p.ToInt64() + i * 2));
                return new string(c);
            }
        } catch { }
        return Marshal.PtrToStringUni(p);
    }
    static string FormOf(IntPtr p) {
        if (IsInt(p)) return "#" + ((int)p.ToInt64()).ToString();
        return ExactStr(p);
    }

    static List<ArcTestEntry> ReadWithFlags(string path, uint flags) {
        IntPtr h = LoadLibraryEx(path, IntPtr.Zero, flags);
        if (h == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LoadLibraryEx failed: " + path);
        List<ArcTestEntry> all = new List<ArcTestEntry>();
        try {
            TProc tc = (hm, tp, lp) => {
                NProc nc = (hm2, tp2, np, lp2) => {
                    string tf = FormOf(tp2);
                    string nf = FormOf(np);
                    bool ti = IsInt(tp2);
                    bool ni = IsInt(np);
                            int tii = ti ? (int)tp2.ToInt64() : -1;
                            int nii = ni ? (int)np.ToInt64() : -1;
                            LProc lc = (hm3, tp3, np3, lang, lp3) => {
                                IntPtr hi = FindResourceEx(hm3, tp3, np3, lang);
                                if (hi != IntPtr.Zero) {
                                    IntPtr hd = LoadResource(hm3, hi);
                                    if (hd != IntPtr.Zero) {
                                        IntPtr ptr = LockResource(hd);
                                        uint sz = SizeofResource(hm3, hi);
                                        byte[] buf = new byte[sz];
                                        if (sz > 0) Marshal.Copy(ptr, buf, 0, (int)sz);
                                        ArcTestEntry e = new ArcTestEntry();
                                        e.TypeIsInt = ti; e.TypeInt = tii; e.TypeForm = tf;
                                        e.NameIsInt = ni; e.NameInt = nii; e.NameForm = nf;
                                        e.Lang = lang; e.Data = buf;
                                        all.Add(e);
                                    }
                                }
                                return true;
                            };
                            EnumResourceLanguages(hm2, tp2, np, lc, IntPtr.Zero);
                            GC.KeepAlive(lc);
                        return true;
                    };
                    EnumResourceNames(hm, tp, nc, IntPtr.Zero);
                    GC.KeepAlive(nc);
                return true;
            };
            EnumResourceTypes(h, tc, IntPtr.Zero);
            GC.KeepAlive(tc);
        }
        finally { FreeLibrary(h); }
        return all;
    }

    public static List<ArcTestEntry> ReadDataFile(string path) { return ReadWithFlags(path, AS_DATAFILE); }
    public static List<ArcTestEntry> ReadImageResource(string path) { return ReadWithFlags(path, AS_IMAGE_RESOURCE); }

    public static bool BytesEqual(byte[] a, byte[] b) {
        if (Object.ReferenceEquals(a, b)) return true;
        if (a == null || b == null) return false;
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }
}
'@
}

function Get-Groups($Entries) {
    $g = @{}
    foreach ($e in $Entries) {
        if ($e.TypeForm -ne '#14') { continue }
        if (-not $g.ContainsKey($e.NameForm)) { $g[$e.NameForm] = $e.Data }
    }
    return $g
}

# GRPICONDIR directory entries as fields: a collision remap rewrites one 2-byte
# field (nID) and the comparison must be able to tell that apart from corruption.
function Get-GroupEntryList([byte[]]$b) {
    $list = New-Object System.Collections.ArrayList
    if ($b.Length -lt 6) { return ,$list }
    $count = [BitConverter]::ToUInt16($b, 4)
    for ($i = 0; $i -lt $count; $i++) {
        $off = 6 + $i * 14
        if ($off + 14 -gt $b.Length) { return ,$list }
        [void]$list.Add([pscustomobject]@{
            W = [int]$b[$off]; H = [int]$b[$off + 1]; Colors = [int]$b[$off + 2]; Reserved = [int]$b[$off + 3]
            Planes = [BitConverter]::ToUInt16($b, $off + 4); Bits = [BitConverter]::ToUInt16($b, $off + 6)
            Bytes = [BitConverter]::ToUInt32($b, $off + 8); Id = [int][BitConverter]::ToUInt16($b, $off + 12)
        })
    }
    return ,$list
}

# A merged group may differ from the theme group for exactly one reason: the
# collision remap rewrote an entry's nID because the theme icon had a different
# byte length than the stock icon an untouched group still names. Everything
# else must match, and the merged icon behind the new nID must be exactly as long
# as the theme entry declares - so this cannot hide a wrong-size or truncated
# image.
function Test-GroupRemapAllowed([byte[]]$mergedBytes, [byte[]]$themeBytes, [uint16]$lang, $iconLen) {
    if ($null -eq $mergedBytes -or $null -eq $themeBytes) { return $false }
    if ($mergedBytes.Length -ne $themeBytes.Length) { return $false }
    if ($mergedBytes.Length -lt 6) { return $false }
    for ($i = 0; $i -lt 6; $i++) { if ($mergedBytes[$i] -ne $themeBytes[$i]) { return $false } }
    $a = Get-GroupEntryList $mergedBytes
    $b = Get-GroupEntryList $themeBytes
    if ($a.Count -ne $b.Count -or $a.Count -eq 0) { return $false }
    $moved = 0
    for ($i = 0; $i -lt $b.Count; $i++) {
        $x = $a[$i]; $y = $b[$i]
        if ($x.W -ne $y.W -or $x.H -ne $y.H -or $x.Colors -ne $y.Colors -or $x.Reserved -ne $y.Reserved -or
            $x.Planes -ne $y.Planes -or $x.Bits -ne $y.Bits -or $x.Bytes -ne $y.Bytes) { return $false }
        if ($x.Id -ne $y.Id) {
            $key = "#$($x.Id)|$lang"
            if (-not $iconLen.ContainsKey($key)) { return $false }
            if ([uint32]$iconLen[$key] -ne [uint32]$y.Bytes) { return $false }
            $moved++
        }
    }
    return ($moved -gt 0)
}

# A stock group (the theme does not provide it) keeps the original directory
# verbatim, so every entry must still declare the byte length of the RT_ICON it
# names: that is exactly what a length-changing icon substitution breaks (the
# pre-fix dark-grey merge broke 27 entries across 7 stock groups). Theme-provided
# groups are exempt because their declarations are reproduced from the theme byte
# for byte - the upstream ARC payload declares a few entries against renumbered
# icons (measured: arc theme group #17 declares 74792 for a 969-byte icon), and a
# merge must neither "fix" that nor fail on it.
function Get-GroupSizeIssues($Entries, $ThemeGroupNames, [int]$limit) {
    $iconLen = @{}
    foreach ($ent in $Entries) {
        if ($ent.TypeForm -eq '#3') { $iconLen["$($ent.NameForm)|$($ent.Lang)"] = [uint32]$ent.Data.Length }
    }
    $checked = 0
    $bad = @()
    foreach ($ent in $Entries) {
        if ($ent.TypeForm -ne '#14') { continue }
        if ($ThemeGroupNames.ContainsKey($ent.NameForm)) { continue }
        $b = $ent.Data
        if ($b.Length -lt 6) { continue }
        $count = [BitConverter]::ToUInt16($b, 4)
        for ($i = 0; $i -lt $count; $i++) {
            $off = 6 + $i * 14
            if ($off + 14 -gt $b.Length) { continue }
            $key = '#' + [BitConverter]::ToUInt16($b, $off + 12) + '|' + $ent.Lang
            if (-not $iconLen.ContainsKey($key)) { continue }
            $checked++
            $decl = [BitConverter]::ToUInt32($b, $off + 8)
            if ($decl -ne $iconLen[$key] -and $bad.Count -lt $limit) { $bad += "$($ent.NameForm)#$i(declares $decl actual $($iconLen[$key]))" }
        }
    }
    return @{ Checked = $checked; Bad = $bad }
}

$fail = $false

try { $oE = [ArcResTest]::ReadDataFile($Original) } catch { Write-Output "CHECK load-original: FAIL ($_)"; Write-Output 'ARC-ICONS-INVARIANT: FAIL'; exit 1 }
try { $mE = [ArcResTest]::ReadDataFile($Merged) } catch { Write-Output "CHECK load-merged: FAIL ($_)"; Write-Output 'ARC-ICONS-INVARIANT: FAIL'; exit 1 }
try { $tE = [ArcResTest]::ReadDataFile($Theme) } catch { Write-Output "CHECK load-theme: FAIL ($_)"; Write-Output 'ARC-ICONS-INVARIANT: FAIL'; exit 1 }

$oG = Get-Groups $oE
$mG = Get-Groups $mE
$tG = Get-Groups $tE

$tGLang = @{}
foreach ($e in $tE) { if ($e.TypeForm -eq '#14' -and -not $tGLang.ContainsKey($e.NameForm)) { $tGLang[$e.NameForm] = [uint16]$e.Lang } }
$mIconLen = @{}
foreach ($e in $mE) { if ($e.TypeForm -eq '#3') { $mIconLen["$($e.NameForm)|$($e.Lang)"] = [uint32]$e.Data.Length } }

# (a) merged group-name set is a superset of the original group-name set
$missing = @($oG.Keys | Where-Object { -not $mG.ContainsKey($_) })
if ($missing.Count -eq 0) { Write-Output "CHECK group-names-superset: PASS (original $($oG.Count), merged $($mG.Count))" }
else { Write-Output "CHECK group-names-superset: FAIL (missing $($missing.Count): $($missing -join ','))"; $fail = $true }

# (b) every theme-provided group is present in merged and either byte-identical
# or differs only by the collision remap's nID rewrite (see Test-GroupRemapAllowed)
$badT = @()
$remappedT = @()
foreach ($n in $tG.Keys) {
    if (-not $mG.ContainsKey($n)) { $badT += "$n(absent)"; continue }
    if ([ArcResTest]::BytesEqual($mG[$n], $tG[$n])) { continue }
    if (Test-GroupRemapAllowed $mG[$n] $tG[$n] $tGLang[$n] $mIconLen) { $remappedT += $n; continue }
    $badT += $n
}
if ($badT.Count -eq 0) {
    $noteT = ''
    if ($remappedT.Count -gt 0) { $noteT = ", $($remappedT.Count) via collision remap ($($remappedT -join ','))" }
    Write-Output "CHECK theme-groups-identical: PASS ($($tG.Count)/$($tG.Count)$noteT)"
}
else { Write-Output "CHECK theme-groups-identical: FAIL ($($tG.Count - $badT.Count)/$($tG.Count) match; differ: $($badT -join ','))"; $fail = $true }

# (c) every group the theme does NOT provide is byte-identical to the original
$badO = @()
foreach ($n in $oG.Keys) {
    if ($tG.ContainsKey($n)) { continue }
    if (-not [ArcResTest]::BytesEqual($mG[$n], $oG[$n])) { $badO += $n }
}
$untouched = $oG.Count - @($oG.Keys | Where-Object { $tG.ContainsKey($_) }).Count
if ($badO.Count -eq 0) { Write-Output "CHECK original-groups-preserved: PASS ($untouched untouched)" }
else { Write-Output "CHECK original-groups-preserved: FAIL (differ: $($badO -join ','))"; $fail = $true }

# (c2) all-resources-preserved: every original (type,name,lang) entry survives,
# except type 3/14 entries whose name the theme provides. Those must carry the
# theme's bytes, with one documented exception: when the theme icon at that
# ordinal was moved by the collision remap (its byte length did not fit the
# untouched stock group that names it), the original bytes stay put and no merged
# theme group may still point at that ordinal.
function Get-ResKey($e) { return "$($e.TypeForm)`0$($e.NameForm)`0$($e.Lang)" }
$dictCmp = [System.StringComparer]::Ordinal
$oMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ($dictCmp)
foreach ($e in $oE) { $oMap[(Get-ResKey $e)] = $e }
$mMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ($dictCmp)
foreach ($e in $mE) { $mMap[(Get-ResKey $e)] = $e }
$themeByTN = New-Object 'System.Collections.Generic.Dictionary[string,object]' ($dictCmp)
foreach ($e in $tE) {
    if ($e.TypeForm -ne '#3' -and $e.TypeForm -ne '#14') { continue }
    $k = "$($e.TypeForm)`0$($e.NameForm)"
    if (-not $themeByTN.ContainsKey($k)) { $themeByTN[$k] = $e }
}

# ordinals the MERGED theme groups still name: those icons must be theme bytes
$themeGroupIcons = @{}
foreach ($n in $tG.Keys) {
    if (-not $mG.ContainsKey($n)) { continue }
    $gb = $mG[$n]
    if ($gb.Length -lt 6) { continue }
    $cnt = [BitConverter]::ToUInt16($gb, 4)
    for ($i = 0; $i -lt $cnt; $i++) {
        $off = 6 + $i * 14
        if ($off + 14 -gt $gb.Length) { continue }
        $themeGroupIcons['#' + [BitConverter]::ToUInt16($gb, $off + 12) + '|' + $tGLang[$n]] = $true
    }
}

$missingR = @()
$diffR = @()
$themeOverR = 0
$remapKeptR = 0
foreach ($k in $oMap.Keys) {
    # NB: $oe/$te would overwrite the $oE/$tE entry lists - PowerShell names are
    # case-insensitive - so the picked entries get distinct names.
    $origEnt = $oMap[$k]
    if (($origEnt.TypeForm -eq '#3' -or $origEnt.TypeForm -eq '#14') -and $themeByTN.ContainsKey("$($origEnt.TypeForm)`0$($origEnt.NameForm)")) {
        $thmEnt = $themeByTN["$($origEnt.TypeForm)`0$($origEnt.NameForm)"]
        if (-not $mMap.ContainsKey($k)) { $missingR += "$k(absent)"; continue }
        if ([ArcResTest]::BytesEqual($mMap[$k].Data, $thmEnt.Data)) { $themeOverR++; continue }
        if ($origEnt.TypeForm -eq '#14') {
            if (Test-GroupRemapAllowed $mMap[$k].Data $thmEnt.Data $tGLang[$origEnt.NameForm] $mIconLen) { $remapKeptR++; continue }
            $diffR += "$($origEnt.TypeForm):$($origEnt.NameForm):$($origEnt.Lang)"
            continue
        }
        $stillReferenced = $themeGroupIcons.ContainsKey("$($origEnt.NameForm)|$($origEnt.Lang)")
        if ((-not $stillReferenced) -and [ArcResTest]::BytesEqual($mMap[$k].Data, $origEnt.Data)) { $remapKeptR++; continue }
        $diffR += "$($origEnt.TypeForm):$($origEnt.NameForm):$($origEnt.Lang)"
        continue
    }
    if (-not $mMap.ContainsKey($k)) { $missingR += "$k(absent)"; continue }
    if (-not [ArcResTest]::BytesEqual($mMap[$k].Data, $origEnt.Data)) { $diffR += "$($origEnt.TypeForm):$($origEnt.NameForm):$($origEnt.Lang)" }
}
$badAll = @($missingR) + @($diffR)
if ($badAll.Count -eq 0) {
    Write-Output ("CHECK all-resources-preserved: PASS (original {0}, merged {1}, theme-overlaid {2}, remap-deferred {3})" -f $oMap.Count, $mMap.Count, $themeOverR, $remapKeptR)
}
else {
    $show = ($badAll | Select-Object -First 20) -join ','
    $more = if ($badAll.Count -gt 20) { " (+$($badAll.Count - 20) more)" } else { '' }
    Write-Output "CHECK all-resources-preserved: FAIL (original $($oMap.Count), merged $($mMap.Count); diff $($badAll.Count): $show$more)"
    $fail = $true
}

# (c3) nothing is invented: every merged entry the original did not have must be
# bytes the theme actually provides (a remapped icon, a theme-added group).
$badNew = @()
foreach ($k in $mMap.Keys) {
    if ($oMap.ContainsKey($k)) { continue }
    $mrgEnt = $mMap[$k]
    $found = $false
    if ($mrgEnt.TypeForm -eq '#14') {
        $thmGroups = @($tE | Where-Object { $_.TypeForm -eq '#14' -and $_.NameForm -ceq $mrgEnt.NameForm })
        foreach ($thmGrp in $thmGroups) {
            if ([ArcResTest]::BytesEqual($mrgEnt.Data, $thmGrp.Data)) { $found = $true; break }
            if (Test-GroupRemapAllowed $mrgEnt.Data $thmGrp.Data ([uint16]$thmGrp.Lang) $mIconLen) { $found = $true; break }
        }
    }
    else {
        foreach ($thmEnt in $tE) {
            if ($thmEnt.TypeForm -ne $mrgEnt.TypeForm) { continue }
            if ($thmEnt.Data.Length -ne $mrgEnt.Data.Length) { continue }
            if ([ArcResTest]::BytesEqual($thmEnt.Data, $mrgEnt.Data)) { $found = $true; break }
        }
    }
    if (-not $found) { $badNew += "$($mrgEnt.TypeForm):$($mrgEnt.NameForm):$($mrgEnt.Lang)" }
}
if ($badNew.Count -eq 0) { Write-Output "CHECK merged-entries-are-theme-bytes: PASS ($(@($mMap.Keys | Where-Object { -not $oMap.ContainsKey($_) }).Count) entries added, all present in the theme)" }
else {
    $showNew = ($badNew | Select-Object -First 20) -join ','
    Write-Output "CHECK merged-entries-are-theme-bytes: FAIL ($($badNew.Count) not found in the theme: $showNew)"
    $fail = $true
}

# (e) structural: a stock group keeps the original directory verbatim, so every
# entry must still declare the byte length of the RT_ICON it names.
$sizeCheck = Get-GroupSizeIssues $mE $tG 6
if ($sizeCheck.Bad.Count -eq 0) { Write-Output "CHECK merged-stock-group-sizes: PASS ($($sizeCheck.Checked) stock-group directory entries declare their RT_ICON length)" }
else { Write-Output "CHECK merged-stock-group-sizes: FAIL ($($sizeCheck.Bad -join ','))"; $fail = $true }

# (d) merged loads both ways and enumerates its types
try {
    $d = [ArcResTest]::ReadDataFile($Merged)
    $types = @($d | ForEach-Object { $_.TypeForm } | Sort-Object -Unique)
    Write-Output "CHECK merged-loads-datafile: PASS (entries $($d.Count), types $($types -join ','))"
}
catch { Write-Output "CHECK merged-loads-datafile: FAIL ($_)"; $fail = $true }

try {
    $im = [ArcResTest]::ReadImageResource($Merged)
    $typesIm = @($im | ForEach-Object { $_.TypeForm } | Sort-Object -Unique)
    Write-Output "CHECK merged-loads-image-resource: PASS (entries $($im.Count), types $($typesIm -join ','))"
}
catch { Write-Output "CHECK merged-loads-image-resource: FAIL ($_)"; $fail = $true }

try {
    $all = [ArcResTest]::ReadDataFile($Merged)
    $typesAll = @($all | ForEach-Object { $_.TypeForm } | Sort-Object -Unique)
    if ($typesAll.Count -gt 0) { Write-Output "CHECK merged-enumerates-types: PASS ($($typesAll -join ','))" }
    else { Write-Output 'CHECK merged-enumerates-types: FAIL (no types)'; $fail = $true }
}
catch { Write-Output "CHECK merged-enumerates-types: FAIL ($_)"; $fail = $true }

if ($fail) { Write-Output 'ARC-ICONS-INVARIANT: FAIL'; exit 1 }
Write-Output 'ARC-ICONS-INVARIANT: PASS'
exit 0
