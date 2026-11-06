# Merge-IconTheme.ps1 — merge a selectable ARC (by niivu) theme variant into
# copies of the pristine .mun originals using the Win32 resource-update API only.
# Params: -Build (default) | -Verify | -Root (default (Join-Path $env:ProgramData 'ArcIcons')) |
#         -Pair <name> | -Variant <arc|arc-symbolic|neutral-brown|neutral-grey|dark-grey>
# -Variant picks the theme source directory AND the label recorded in
# installed-manifest.json (theme + per-file themeFile + variantSource), so the
# whole build/apply/verify pipeline stays pinned to the variant it built.
# installed-manifest.json also carries sourceOrigin - the provenance of the
# variant payload this build consumed: the source dir + a sha256 of every theme
# file used, the landed variant archive's name + sha256 when that archive is
# still on this PC (theme\ARC.zip / theme\arc-neutral-*.zip - the Archive field
# of the variant table below), and repo/commit ONLY when the payload ships its
# own source.json (a value that cannot be read is never invented).
# The variant table below is the single owner of that mapping (ARC-Icons.ps1
# keeps the operator-facing copy for the selector).
# Never writes to C:\Windows; never modifies originals\ or theme\.
# Writes stage\<name> copies + installed-manifest.json at the root.
param(
    [switch]$Build,
    [switch]$Verify,
    [string]$Root = (Join-Path $env:ProgramData 'ArcIcons'),
    [string]$Pair = '',
    [string]$Variant = 'arc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Build -and -not $Verify) { $Build = $true }

$Root = (Resolve-Path -LiteralPath $Root).Path
if ($Root -like 'C:\Windows*') { throw "Refusing to use a Root under C:\Windows (got '$Root')." }

# ---- variant selection: one table owns the theme dir + the manifest label ----
$VariantTable = [ordered]@{
    'arc'           = [pscustomobject]@{ Id = 'arc';           Display = 'ARC (by niivu)';    ThemeDir = 'Windhawk Resources';                   Archive = 'ARC.zip' }
    'arc-symbolic'  = [pscustomobject]@{ Id = 'arc-symbolic';  Display = 'ARC Symbolic';      ThemeDir = 'ARC Symbolic\Windhawk Resources';      Archive = 'ARC Symbolic.zip' }
    'neutral-brown' = [pscustomobject]@{ Id = 'neutral-brown'; Display = 'Arc Neutral Brown'; ThemeDir = 'Arc Neutral Brown\Windhawk Resources';  Archive = 'arc-neutral-brown.zip' }
    'neutral-grey'  = [pscustomobject]@{ Id = 'neutral-grey';  Display = 'Arc Neutral Grey';  ThemeDir = 'Arc Neutral Grey\Windhawk Resources';   Archive = 'arc-neutral-grey.zip' }
    'dark-grey'     = [pscustomobject]@{ Id = 'dark-grey';     Display = 'Arc Dark Grey';     ThemeDir = 'Arc Dark Grey\Windhawk Resources';      Archive = '' }
}
function Resolve-VariantKey([string]$Name) {
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
    if ($alias.ContainsKey($key)) { return $alias[$key] }
    throw ("Unknown -Variant '{0}'. Allowed: {1} (the display names work too)." -f $Name, (@($VariantTable.Keys) -join ' | '))
}
$VariantInfo = $VariantTable[(Resolve-VariantKey $Variant)]
$ThemeRel = 'theme\' + $VariantInfo.ThemeDir
$ThemeDirAbs = Join-Path $Root $ThemeRel
if (-not (Test-Path -LiteralPath $ThemeDirAbs -PathType Container)) {
    throw ("Variant '{0}' source is not on this PC: {1} (expected imageres.dll, imagesp1.dll, zipfldr.dll)." -f $VariantInfo.Display, $ThemeDirAbs)
}
Write-Output ("VARIANT: {0} source={1}" -f $VariantInfo.Display, $ThemeRel)

$Pairs = @(
    @{ Name = 'zipfldr.dll.mun';  Theme = 'zipfldr.dll'   },
    @{ Name = 'imagesp1.dll.mun'; Theme = 'imagesp1.dll'  },
    @{ Name = 'imageres.dll.mun'; Theme = 'imageres.dll'  }
)
if ($Pair) {
    $Pairs = @($Pairs | Where-Object { $_.Name -eq $Pair -or $_.Name -like "$Pair*" })
    if (-not $Pairs -or $Pairs.Count -eq 0) { throw "Unknown -Pair '$Pair'." }
}

$LangDefault = [uint16]0x0409

# ---- Win32 interop (resource read via C# callbacks; update via Begin/Update/End) ----
if (-not ([System.Management.Automation.PSTypeName]'ArcResMerge').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class ArcMergeEntry {
    public bool TypeIsInt; public int TypeInt; public string TypeForm;
    public bool NameIsInt; public int NameInt; public string NameForm;
    public ushort Lang; public byte[] Data;
}

public static class ArcResMerge {
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
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr BeginUpdateResource(string f, bool del);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool UpdateResource(IntPtr h, IntPtr t, IntPtr n, ushort l, byte[] d, uint c);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool EndUpdateResource(IntPtr h, bool discard);

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

    public static List<ArcMergeEntry> Read(string path) {
        IntPtr h = LoadLibraryEx(path, IntPtr.Zero, 2u);
        if (h == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LoadLibraryEx failed: " + path);
        List<ArcMergeEntry> all = new List<ArcMergeEntry>();
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
                                        ArcMergeEntry e = new ArcMergeEntry();
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

    // Wrappers capture GetLastWin32Error inside the same call: PowerShell's own
    // Win32 traffic between a raw P/Invoke return and a PS-side read can clobber it.
    public static int LastError;
    public static IntPtr BeginUpd(string f) {
        IntPtr h = BeginUpdateResource(f, false);
        LastError = Marshal.GetLastWin32Error();
        return h;
    }
    public static IntPtr BeginUpdDel(string f) {
        IntPtr h = BeginUpdateResource(f, true);
        LastError = Marshal.GetLastWin32Error();
        return h;
    }
    public static bool UpdRes(IntPtr h, IntPtr t, IntPtr n, ushort l, byte[] d, uint c) {
        bool ok = UpdateResource(h, t, n, l, d, c);
        LastError = Marshal.GetLastWin32Error();
        return ok;
    }
    public static bool EndUpd(IntPtr h, bool discard) {
        bool ok = EndUpdateResource(h, discard);
        LastError = Marshal.GetLastWin32Error();
        return ok;
    }

    public static bool BytesEqual(byte[] a, byte[] b) {        if (Object.ReferenceEquals(a, b)) return true;
        if (a == null || b == null) return false;
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }
}
'@
}

function New-ResPtr([string]$Form, [bool]$IsInt) {
    if ($IsInt) {
        if ($Form -notmatch '^#(\d+)$') { throw "Ordinal resource name expected, got '$Form'." }
        return @{ Ptr = [IntPtr][int]$Matches[1]; Free = $false }
    }
    return @{ Ptr = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($Form); Free = $true }
}
function Free-ResPtr($r) {
    if ($r.Free) { [Runtime.InteropServices.Marshal]::FreeHGlobal($r.Ptr) }
}

# GRPICONDIR helpers: header WORD idReserved, WORD idType, WORD idCount;
# each entry 14 bytes, nID = WORD at entry offset +12.
function Get-GrpIconIds([byte[]]$b) {
    $ids = @()
    if ($b.Length -lt 6) { return $ids }
    $count = [BitConverter]::ToUInt16($b, 4)
    for ($i = 0; $i -lt $count; $i++) {
        $off = 6 + $i * 14
        if ($off + 14 -le $b.Length) { $ids += [BitConverter]::ToUInt16($b, $off + 12) }
    }
    return $ids
}
function Set-GrpIconId([byte[]]$b, [int]$Old, [int]$New) {
    if ($b.Length -lt 6) { return }
    $count = [BitConverter]::ToUInt16($b, 4)
    $nb = [BitConverter]::GetBytes([uint16]$New)
    for ($i = 0; $i -lt $count; $i++) {
        $off = 6 + $i * 14 + 12
        if ($off + 2 -le $b.Length -and [BitConverter]::ToUInt16($b, $off) -eq $Old) {
            $b[$off] = $nb[0]; $b[$off + 1] = $nb[1]
        }
    }
}

function Get-IconMaps($Entries) {
    # Returns @{ DestLang=@{}; Groups=@{}; IconOrds=@{} } for types #3/#14 only.
    $destLang = @{}
    $groups = @{}
    $iconOrds = @{}
    foreach ($e in $Entries) {
        if ($e.TypeForm -ne '#3' -and $e.TypeForm -ne '#14') { continue }
        $k = "$($e.TypeForm)|$($e.NameForm)"
        if (-not $destLang.ContainsKey($k)) { $destLang[$k] = $e.Lang }
        if ($e.TypeForm -eq '#14') {
            if (-not $groups.ContainsKey($e.NameForm)) { $groups[$e.NameForm] = $e.Data }
        }
        elseif ($e.NameIsInt) { $iconOrds[$e.NameInt] = $true }
    }
    return @{ DestLang = $destLang; Groups = $groups; IconOrds = $iconOrds }
}

function Sort-RebuildEntries($Entries) {
    # Order: numeric types ascending, then string types in first-seen order;
    # within a type, enumeration order (stable via original index).
    $strOrder = @{}
    $next = 0
    foreach ($e in $Entries) {
        if (-not $e.TypeIsInt -and -not $strOrder.ContainsKey($e.TypeForm)) {
            $strOrder[$e.TypeForm] = $next; $next++
        }
    }
    $i = 0
    $decor = foreach ($e in $Entries) { [pscustomobject]@{ E = $e; Ord = $i; SOrd = if ($e.TypeIsInt) { -1 } else { $strOrder[$e.TypeForm] } }; $i++ }
    $sorted = @($decor | Sort-Object -Property @{ Expression = { if ($_.E.TypeIsInt) { 0 } else { 1 } } }, @{ Expression = { if ($_.E.TypeIsInt) { $_.E.TypeInt } else { $_.SOrd } } }, @{ Expression = { $_.Ord } } | ForEach-Object { $_.E })
    return $sorted
}

function Add-ResEntry($h, $e, $Op) {
    $tp = New-ResPtr $e.TypeForm ([bool]$e.TypeIsInt)
    try {
        $np = New-ResPtr $e.NameForm ([bool]$e.NameIsInt)
        try {
            $ok = [ArcResMerge]::UpdRes($h, $tp.Ptr, $np.Ptr, [uint16]$e.Lang, $e.Data, [uint32]$e.Data.Length)
            if (-not $ok) {
                $w = New-Object ComponentModel.Win32Exception([ArcResMerge]::LastError)
                throw "$Op type '$($e.TypeForm)' name '$($e.NameForm)' lang $($e.Lang) failed: code $([ArcResMerge]::LastError) $($w.Message) — STOPPING."
            }
        }
        finally { Free-ResPtr $np }
    }
    finally { Free-ResPtr $tp }
}

function Invoke-MergePair($PairName, $ThemeFile) {
    $orig  = Join-Path $Root "originals\$PairName"
    $theme = Join-Path $Root "$ThemeRel\$ThemeFile"
    $stage = Join-Path $Root "stage\$PairName"
    if ($stage -like 'C:\Windows*') { throw "Refusing to write under C:\Windows (got '$stage')." }
    foreach ($p in @($orig, $theme)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Missing input file: $p" }
    }

    $destRes  = [ArcResMerge]::Read($orig)
    $themeRes = [ArcResMerge]::Read($theme)

    $dest  = Get-IconMaps $destRes
    $themeIcons = @($themeRes | Where-Object { $_.TypeForm -eq '#3' })
    $themeGroups = @($themeRes | Where-Object { $_.TypeForm -eq '#14' })

    # --- collision safety: theme icon ordinals referenced by untouched dest groups ---
    # A group directory entry declares the byte length of the RT_ICON it names, so
    # substituting theme bytes under an ordinal an untouched group already points
    # at is only safe when the length is identical. When it is not, that group is
    # left declaring a stale size (measured on imageres: 7 stock groups / 27
    # entries) and the icon renderer slices the wrong bytes, so the theme icon is
    # moved to a fresh ordinal and every theme group that names it follows.
    #
    # NB: Get-GrpIconIds returns [uint16] (BitConverter), while NameInt is
    # [int]; a Hashtable does not consider [uint16]289 and [int]289 the same key
    # (measured), so both sides are cast to [int] or the remap silently never
    # fires.
    $untouched = @($dest.Groups.Keys | Where-Object { -not (Test-IsThemeGroup $_ $themeGroups) })
    $protected = @{}
    foreach ($g in $untouched) {
        foreach ($id in (Get-GrpIconIds $dest.Groups[$g])) { $protected[[int]$id] = $true }
    }
    $destIconLen = @{}
    foreach ($e in $destRes) {
        if ($e.TypeForm -eq '#3' -and $e.NameIsInt) { $destIconLen[[int]$e.NameInt] = [uint32]$e.Data.Length }
    }
    $used = @{}
    foreach ($k in $dest.IconOrds.Keys) { $used[[int]$k] = $true }
    foreach ($e in $themeIcons) { if ($e.NameIsInt) { $used[[int]$e.NameInt] = $true } }
    $maxUsed = 0
    foreach ($k in $used.Keys) { if ($k -gt $maxUsed) { $maxUsed = $k } }
    $remap = @{}
    foreach ($e in $themeIcons) {
        if (-not $e.NameIsInt) { continue }
        $id = [int]$e.NameInt
        if (-not $protected.ContainsKey($id)) { continue }
        if ($remap.ContainsKey($id)) { continue }
        # same byte length: the untouched group's declaration stays true, so the
        # theme art can take the ordinal in place (no duplication in the payload)
        if ($destIconLen.ContainsKey($id) -and $destIconLen[$id] -eq [uint32]$e.Data.Length) { continue }
        do { $maxUsed++ } while ($used.ContainsKey($maxUsed))
        if ($maxUsed -gt 65535) { throw "Ordinal space exhausted while remapping icon #$id." }
        $used[$maxUsed] = $true
        $remap[$id] = $maxUsed
    }
    foreach ($ge in $themeGroups) {
        foreach ($old in $remap.Keys) { Set-GrpIconId $ge.Data $old $remap[$old] }
    }

    # --- copy pristine original to stage, then delete-first full rebuild ---
    $stageDir = Split-Path -Parent $stage
    if (-not (Test-Path -LiteralPath $stageDir)) { New-Item -ItemType Directory -Path $stageDir | Out-Null }
    Copy-Item -LiteralPath $orig -Destination $stage -Force

    $rebuild = Sort-RebuildEntries $destRes

    $h = [ArcResMerge]::BeginUpdDel($stage)
    if ($h -eq [IntPtr]::Zero) {
        $w = New-Object ComponentModel.Win32Exception([ArcResMerge]::LastError)
        throw "BeginUpdateResource(deleteExisting=TRUE) failed on '$stage': code $([ArcResMerge]::LastError) $($w.Message) — STOPPING."
    }
    $committed = $false
    $h = [IntPtr]::Zero
    try {
        # Single-write rule: within one update session each (type,name,lang) may
        # be written exactly once (a second UpdateResource on the same key fails
        # with code 50). Theme bytes are therefore substituted inline in the op
        # list; genuinely-new theme entries are appended once. Measured: one
        # session also caps out near ~3200 ops / ~23MB staged (imageres failed
        # at PNG #5021 after ~3224 ops / ~23.4MB), while small pairs pass, and
        # an incremental session on a rebuilt file succeeds. Ops are therefore
        # packed into chunks (<=1200 entries and <=8MB each): chunk 0 opens
        # with deleteExisting=TRUE, later chunks continue incrementally. Every
        # key is still written exactly once, with the exact type/name form and
        # language, using only the Win32 resource API.
        $themeOverlay = @{}
        foreach ($e in $themeIcons) {
            $nm = if ($e.NameIsInt -and $remap.ContainsKey([int]$e.NameInt)) { '#' + $remap[[int]$e.NameInt] } else { $e.NameForm }
            $themeOverlay["#3|$nm"] = @{ TypeForm = '#3'; TypeIsInt = $true; Data = $e.Data; NameForm = $nm; NameIsInt = $true; Lang = [uint16]$e.Lang }
        }
        foreach ($ge in $themeGroups) {
            $themeOverlay["#14|$($ge.NameForm)"] = @{ TypeForm = '#14'; TypeIsInt = $true; Data = $ge.Data; NameForm = $ge.NameForm; NameIsInt = [bool]$ge.NameIsInt; Lang = [uint16]$ge.Lang }
        }
        $coveredTN = @{}
        $ops = New-Object System.Collections.ArrayList
        $muiOps = New-Object System.Collections.ArrayList
        foreach ($e in $rebuild) {
            $tn = "$($e.TypeForm)|$($e.NameForm)"
            if (($e.TypeForm -eq '#3' -or $e.TypeForm -eq '#14') -and $themeOverlay.ContainsKey($tn)) {
                $ov = $themeOverlay[$tn]
                $coveredTN[$tn] = $true
                [void]$ops.Add(@{ TypeForm = $ov.TypeForm; TypeIsInt = $ov.TypeIsInt; NameForm = $ov.NameForm; NameIsInt = $ov.NameIsInt; Lang = [uint16]$e.Lang; Data = $ov.Data; Op = "theme-substitute $($e.TypeForm) $($e.NameForm) lang $($e.Lang)" })
            }
            elseif ($e.TypeForm -ceq 'MUI') {
                # Measured: once a MUI entry exists (staged or committed), any
                # later UpdateResource for type PNG fails with code 50
                # (bisect: mui-then-png FAIL; img-then-png/img+icons/wave-then-png
                # PASS; png-then-img+mui PASS). MUI ops go strictly last.
                [void]$muiOps.Add(@{ TypeForm = $e.TypeForm; TypeIsInt = [bool]$e.TypeIsInt; NameForm = $e.NameForm; NameIsInt = [bool]$e.NameIsInt; Lang = [uint16]$e.Lang; Data = $e.Data; Op = "rebuild $($e.TypeForm) $($e.NameForm) lang $($e.Lang)" })
            }
            else {
                [void]$ops.Add(@{ TypeForm = $e.TypeForm; TypeIsInt = [bool]$e.TypeIsInt; NameForm = $e.NameForm; NameIsInt = [bool]$e.NameIsInt; Lang = [uint16]$e.Lang; Data = $e.Data; Op = "rebuild $($e.TypeForm) $($e.NameForm) lang $($e.Lang)" })
            }
        }
        foreach ($tn in $themeOverlay.Keys) {
            if ($coveredTN.ContainsKey($tn)) { continue }
            $ov = $themeOverlay[$tn]
            # A remapped icon has no dest entry at its new ordinal, so it lands
            # under the language the theme itself carries, not a guessed one.
            $tlang = $LangDefault
            if ($dest.DestLang.ContainsKey($tn)) { $tlang = [uint16]$dest.DestLang[$tn] }
            elseif ($ov.ContainsKey('Lang')) { $tlang = [uint16]$ov.Lang }
            [void]$ops.Add(@{ TypeForm = $ov.TypeForm; TypeIsInt = $ov.TypeIsInt; NameForm = $ov.NameForm; NameIsInt = $ov.NameIsInt; Lang = [uint16]$tlang; Data = $ov.Data; Op = "theme-add $tn lang $tlang" })
        }
        foreach ($op in $muiOps) { [void]$ops.Add($op) }
        $chunks = New-Object System.Collections.ArrayList
        $cur = New-Object System.Collections.ArrayList
        $curBytes = 0
        foreach ($op in $ops) {
            if ($cur.Count -gt 0 -and ($cur.Count -ge 1200 -or ($curBytes + $op.Data.Length) -gt 8MB)) {
                [void]$chunks.Add($cur.ToArray()); $cur = New-Object System.Collections.ArrayList; $curBytes = 0
            }
            [void]$cur.Add($op); $curBytes += $op.Data.Length
        }
        if ($cur.Count -gt 0) { [void]$chunks.Add($cur.ToArray()) }
        Write-Host "SESSIONS ${PairName}: $($ops.Count) ops in $($chunks.Count) chunk(s)"
        $ci = 0
        foreach ($chunk in $chunks) {
            # 5.1-safe byte sum (Measure-Object -Property does not take a
            # scriptblock on Windows PowerShell 5.1).
            $cb = 0
            foreach ($ce in $chunk) { $cb += $ce.Data.Length }
            Write-Host ("CHUNK {0}: {1} ops, {2} bytes, first={3} {4}, last={5} {6}" -f $ci, $chunk.Count, $cb, $chunk[0].TypeForm, $chunk[0].NameForm, $chunk[$chunk.Count-1].TypeForm, $chunk[$chunk.Count-1].NameForm)
            $ci++
        }
        $si = 0
        foreach ($chunk in $chunks) {
            $delFirst = ($si -eq 0)
            $h = if ($delFirst) { [ArcResMerge]::BeginUpdDel($stage) } else { [ArcResMerge]::BeginUpd($stage) }
            if ($h -eq [IntPtr]::Zero) {
                $w = New-Object ComponentModel.Win32Exception([ArcResMerge]::LastError)
                throw "BeginUpdateResource(deleteExisting=$delFirst) session $si failed on '$stage': code $([ArcResMerge]::LastError) $($w.Message) — STOPPING."
            }
            $sessionOk = $false
            try {
                foreach ($op in $chunk) {
                    $tp = New-ResPtr $op.TypeForm ([bool]$op.TypeIsInt)
                    try {
                        $np = New-ResPtr $op.NameForm ([bool]$op.NameIsInt)
                        try {
                            $ok = [ArcResMerge]::UpdRes($h, $tp.Ptr, $np.Ptr, [uint16]$op.Lang, $op.Data, [uint32]$op.Data.Length)
                            if (-not $ok) {
                                $w = New-Object ComponentModel.Win32Exception([ArcResMerge]::LastError)
                                throw "UpdateResource session $si $($op.Op) failed: code $([ArcResMerge]::LastError) $($w.Message) — STOPPING."
                            }
                        }
                        finally { Free-ResPtr $np }
                    }
                    finally { Free-ResPtr $tp }
                }
                if (-not [ArcResMerge]::EndUpd($h, $false)) {
                    $w = New-Object ComponentModel.Win32Exception([ArcResMerge]::LastError)
                    throw "EndUpdateResource session $si failed on '$stage': code $([ArcResMerge]::LastError) $($w.Message) — STOPPING."
                }
                $h = [IntPtr]::Zero
                $sessionOk = $true
            }
            finally {
                if (-not $sessionOk -and $h -ne [IntPtr]::Zero) { try { [void][ArcResMerge]::EndUpd($h, $true) } catch {}; $h = [IntPtr]::Zero }
            }
            $si++
        }
        $committed = $true
    }
    finally {
        if (-not $committed -and $h -ne [IntPtr]::Zero) { try { [void][ArcResMerge]::EndUpd($h, $true) } catch {} }
    }

    # --- read back the merged copy for stats ---
    $mergedRes = [ArcResMerge]::Read($stage)
    $merged = Get-IconMaps $mergedRes
    $themeGroupNames = @($themeGroups | ForEach-Object { $_.NameForm } | Sort-Object -Unique)
    $added = @($themeGroupNames | Where-Object { -not $merged.Groups.ContainsKey($_) -or -not $dest.Groups.ContainsKey($_) } |
        Where-Object { -not $dest.Groups.ContainsKey($_) })

    return @{
        Name = $PairName
        GroupsOriginal = $dest.Groups.Count
        GroupsMerged = $merged.Groups.Count
        GroupsFromTheme = $themeGroupNames.Count
        GroupsAdded = $added.Count
        RemappedIcons = $remap.Count
        RemapDetail = ($remap.Keys | Sort-Object | ForEach-Object { "$_->$($remap[$_])" }) -join ','
        ThemeIcons = $themeIcons.Count
    }
}

function Test-IsThemeGroup($Name, $ThemeGroupEntries) {
    foreach ($ge in $ThemeGroupEntries) { if ($ge.NameForm -ceq $Name) { return $true } }
    return $false
}

# GRPICONDIR directory entries as fields, so a group can be compared field by
# field instead of byte for byte (a collision remap changes the nID field only).
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

# True only when a merged group differs from the theme group for one reason: the
# nID of an entry was rewritten by the collision remap. Every other directory
# field must be identical, and the merged icon behind the new nID must be exactly
# as long as the theme entry declares - so a moved group cannot smuggle in a
# wrong-size (or truncated) image.
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

# A stock group (one the theme does not provide) keeps the original directory
# verbatim, so every entry must still declare the byte length of the RT_ICON it
# names - that is what a length-changing substitution breaks (measured on the
# pre-fix dark-grey merge: 27 entries across 7 stock groups). Theme-provided
# groups are exempt: their declarations are reproduced from the theme byte for
# byte, and the upstream ARC payload declares a few entries against renumbered
# icons (measured: arc theme group #17 declares 74792 for a 969-byte icon), which
# the merge must neither "fix" nor fail on.
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

function Test-PairInvariants($PairName, $ThemeFile) {
    # Strict byte checks: (a) superset, (b) theme groups identical, (c) untouched identical.
    # NOTE: if collision remap rewrote theme groups, (b) reports which groups differ.
    $orig  = Join-Path $Root "originals\$PairName"
    $theme = Join-Path $Root "$ThemeRel\$ThemeFile"
    $stage = Join-Path $Root "stage\$PairName"
    $lines = @()
    $ok = $true
    if (-not (Test-Path -LiteralPath $stage)) {
        return @{ Ok = $false; Lines = @("CHECK stage-exists: FAIL ($PairName not built)") }
    }
    $oEntries = [ArcResMerge]::Read($orig)
    $mEntries = [ArcResMerge]::Read($stage)
    $t = [ArcResMerge]::Read($theme)
    $o = Get-IconMaps $oEntries
    $m = Get-IconMaps $mEntries
    $tGroups = @{}
    $tGroupLang = @{}
    foreach ($e in ($t | Where-Object { $_.TypeForm -eq '#14' })) {
        if (-not $tGroups.ContainsKey($e.NameForm)) { $tGroups[$e.NameForm] = $e.Data; $tGroupLang[$e.NameForm] = [uint16]$e.Lang }
    }
    $mIconLen = @{}
    foreach ($e in $mEntries) { if ($e.TypeForm -eq '#3') { $mIconLen["$($e.NameForm)|$($e.Lang)"] = [uint32]$e.Data.Length } }

    $missing = @($o.Groups.Keys | Where-Object { -not $m.Groups.ContainsKey($_) })
    if ($missing.Count -eq 0) { $lines += "CHECK ${PairName} group-superset: PASS (original $($o.Groups.Count), merged $($m.Groups.Count))" }
    else { $lines += "CHECK ${PairName} group-superset: FAIL (missing $($missing.Count): $($missing -join ','))"; $ok = $false }

    $badT = @()
    $remappedGroups = @()
    foreach ($n in $tGroups.Keys) {
        if (-not $m.Groups.ContainsKey($n)) { $badT += "$n(absent)"; continue }
        if ([ArcResMerge]::BytesEqual($m.Groups[$n], $tGroups[$n])) { continue }
        # A theme group the collision remap rewrote differs in its nID fields
        # only; anything else is a real divergence and still fails.
        if (Test-GroupRemapAllowed $m.Groups[$n] $tGroups[$n] $tGroupLang[$n] $mIconLen) { $remappedGroups += $n; continue }
        $badT += $n
    }
    if ($badT.Count -eq 0) {
        $remapNote = ''
        if ($remappedGroups.Count -gt 0) { $remapNote = ", $($remappedGroups.Count) via collision remap" }
        $lines += "CHECK ${PairName} theme-groups-identical: PASS ($($tGroups.Count)/$($tGroups.Count)$remapNote)"
    }
    else { $lines += "CHECK ${PairName} theme-groups-identical: FAIL ($($tGroups.Count - $badT.Count)/$($tGroups.Count) match; differ: $($badT -join ','))"; $ok = $false }

    $badO = @()
    foreach ($n in $o.Groups.Keys) {
        if ($tGroups.ContainsKey($n)) { continue }
        if (-not [ArcResMerge]::BytesEqual($m.Groups[$n], $o.Groups[$n])) { $badO += $n }
    }
    if ($badO.Count -eq 0) { $lines += "CHECK ${PairName} original-groups-preserved: PASS" }
    else { $lines += "CHECK ${PairName} original-groups-preserved: FAIL (differ: $($badO -join ','))"; $ok = $false }

    $sizeCheck = Get-GroupSizeIssues $mEntries $tGroups 6
    if ($sizeCheck.Bad.Count -eq 0) { $lines += "CHECK ${PairName} stock-group-sizes: PASS ($($sizeCheck.Checked) stock-group directory entries declare their RT_ICON length)" }
    else { $lines += "CHECK ${PairName} stock-group-sizes: FAIL ($($sizeCheck.Bad -join ','))"; $ok = $false }

    try {
        $probe1 = [ArcResMerge]::Read($stage) | ForEach-Object { $_.TypeForm } | Sort-Object -Unique
        $lines += "CHECK ${PairName} merged-loads-datafile: PASS (types $($probe1 -join ','))"
    }
    catch { $lines += "CHECK ${PairName} merged-loads-datafile: FAIL ($_)"; $ok = $false }

    return @{ Ok = $ok; Lines = $lines }
}

if ($Verify) {
    $allOk = $true
    foreach ($p in $Pairs) {
        $r = Test-PairInvariants $p.Name $p.Theme
        foreach ($l in $r.Lines) { Write-Output $l }
        if (-not $r.Ok) { $allOk = $false }
    }
    # manifest consistency: staged hashes must match installed-manifest.json
    $mf = Join-Path $Root 'installed-manifest.json'
    if (Test-Path -LiteralPath $mf) {
        try {
            $man = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
            foreach ($p in $Pairs) {
                $st = Join-Path $Root "stage\$($p.Name)"
                if (-not (Test-Path -LiteralPath $st)) { continue }
                $h = (Get-FileHash -LiteralPath $st -Algorithm SHA256).Hash
                $row = @($man.files | Where-Object { $_.name -eq $p.Name })[0]
                if ($null -eq $row) { Write-Output "CHECK $($p.Name) manifest-row: FAIL (no row)"; $allOk = $false }
                elseif ($row.mergedSha256 -ne $h) { Write-Output "CHECK $($p.Name) manifest-row: FAIL (hash mismatch)"; $allOk = $false }
                else { Write-Output "CHECK $($p.Name) manifest-row: PASS" }
            }
        }
        catch { Write-Output "CHECK manifest: FAIL ($_)"; $allOk = $false }
    }
    else { Write-Output 'CHECK manifest: FAIL (installed-manifest.json missing)'; $allOk = $false }
    if ($allOk) { Write-Output 'ARC-MERGE: PASS' } else { Write-Output 'ARC-MERGE: FAIL' }
    if (-not $allOk) { exit 1 }
    exit 0
}

# ---- Build (zipfldr -> imagesp1 -> imageres; verify each pair before the next) ----
$results = @()
foreach ($p in $Pairs) {
    $r = Invoke-MergePair $p.Name $p.Theme
    $results += $r
    Write-Output ("BUILD {0}: groupsOriginal={1} groupsMerged={2} groupsFromTheme={3} groupsAdded={4} themeIcons={5} remappedIcons={6}{7}" -f `
        $r.Name, $r.GroupsOriginal, $r.GroupsMerged, $r.GroupsFromTheme, $r.GroupsAdded, $r.ThemeIcons, $r.RemappedIcons, `
        $(if ($r.RemappedIcons -gt 0) { " [$($r.RemapDetail)]" } else { '' }))
    $chkNow = Test-PairInvariants $p.Name $p.Theme
    foreach ($l in $chkNow.Lines) { Write-Output $l }
    if (-not $chkNow.Ok) { throw "Build verification failed for '$($p.Name)' — STOPPING before the next pair." }
}

# installed-manifest.json — the record of WHICH variant this build is pinned to
# (theme = label, variantSource = theme dir, per-file themeFile = exact input),
# so apply.ps1 / verify.ps1 / repair.ps1 never have to guess from originals\.
$files = @()
$originFiles = @()
foreach ($r in $results) {
    $stage = Join-Path $Root "stage\$($r.Name)"
    $orig  = Join-Path $Root "originals\$($r.Name)"
    $pairTheme = (@($Pairs | Where-Object { $_.Name -eq $r.Name })[0]).Theme
    $chk = Test-PairInvariants $r.Name $pairTheme
    $inv = if ($chk.Ok) { 'pass' } else { 'fail' }
    foreach ($l in $chk.Lines) { Write-Output $l }
    $files += [ordered]@{
        name           = $r.Name
        stagePath      = "stage\$($r.Name)"
        originalSha256 = (Get-FileHash -LiteralPath $orig -Algorithm SHA256).Hash
        mergedSha256   = (Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash
        mergedSize     = (Get-Item -LiteralPath $stage).Length
        groupsOriginal = $r.GroupsOriginal
        groupsMerged   = $r.GroupsMerged
        groupsFromTheme = $r.GroupsFromTheme
        groupsAdded    = $r.GroupsAdded
        remappedIcons  = $r.RemappedIcons
        invariant      = $inv
        themeFile      = "$ThemeRel\$pairTheme"
    }
    $themeInput = Join-Path $ThemeDirAbs $pairTheme
    $originFiles += [ordered]@{
        name   = $pairTheme
        source = "$ThemeRel\$pairTheme"
        sha256 = (Get-FileHash -LiteralPath $themeInput -Algorithm SHA256).Hash
        size   = (Get-Item -LiteralPath $themeInput).Length
    }
}

# ---- pair-only rebuild: the manifest keeps all THREE rows, never drops rows ----
# A -Pair build writes ONE stage file, but installed-manifest.json is the record
# of all three files. Folding the rebuilt row into the existing manifest is only
# sound when every UNTOUCHED row still matches its stage file on disk: otherwise
# the build is stale and apply.ps1 would refuse that pair at preflight - so throw
# instead of writing a manifest that claims a state the disk does not have.
$mfPath = Join-Path $Root 'installed-manifest.json'
$existingMan = $null
if ($Pair) {
    if (-not (Test-Path -LiteralPath $mfPath -PathType Leaf)) {
        throw ("-Pair '{0}' needs an existing installed-manifest.json (three rows); run a full -Build first." -f $Pair)
    }
    $existingMan = Get-Content -LiteralPath $mfPath -Raw | ConvertFrom-Json
    $existingFiles = @($existingMan.files)
    if ($existingFiles.Count -ne 3) {
        throw ("-Pair '{0}': existing installed-manifest.json carries {1} row(s), expected 3; run a full -Build." -f $Pair, $existingFiles.Count)
    }
    if ([string]$existingMan.variantId -ne $VariantInfo.Id) {
        throw ("-Pair '{0}': existing manifest is variant '{1}', this build is '{2}'; a pair-only rebuild cannot mix variants - run a full -Build -Variant {2}." -f $Pair, [string]$existingMan.variantId, $VariantInfo.Id)
    }
    $rebuiltRows = @{}
    foreach ($f in $files) { $rebuiltRows[[string]$f.name] = $f }
    $mergedRows = @()
    foreach ($row in $existingFiles) {
        $nm = [string]$row.name
        if ($rebuiltRows.ContainsKey($nm)) { $mergedRows += $rebuiltRows[$nm]; [void]$rebuiltRows.Remove($nm); continue }
        $st = Join-Path $Root ([string]$row.stagePath)
        if (-not (Test-Path -LiteralPath $st -PathType Leaf)) {
            throw ("-Pair '{0}': untouched row '{1}' has no stage file ({2}); run a full -Build." -f $Pair, $nm, [string]$row.stagePath)
        }
        $h = (Get-FileHash -LiteralPath $st -Algorithm SHA256).Hash
        if ($h -ne ([string]$row.mergedSha256)) {
            throw ("-Pair '{0}': untouched row '{1}' stage hash {2} != recorded merged {3}; the build is stale - run a full -Build." -f $Pair, $nm, $h, [string]$row.mergedSha256)
        }
        $mergedRows += $row
        Write-Output ("KEEP {0}: untouched, stage hash matches recorded merged" -f $nm)
    }
    foreach ($k in @($rebuiltRows.Keys)) { $mergedRows += $rebuiltRows[$k] }
    if ($mergedRows.Count -ne 3) { throw ("-Pair '{0}': merged manifest would carry {1} rows, expected 3." -f $Pair, $mergedRows.Count) }
    $files = $mergedRows
}

# ---- sourceOrigin: the applied theme's provenance is never blank ----
# Always: the variant source dir + a sha256 of every theme file this build
# consumed (so the exact payload can be re-fetched and re-checked). The landed
# variant archive adds its name + sha256 while theme\<Archive> is still here.
# repo/commit come ONLY from the payload's own source.json - a value that is not
# readable is left out, never guessed.
$sourceOrigin = [ordered]@{ sourceDir = $ThemeRel }
$sourceOrigin['files'] = $originFiles
$zipCandidate = Join-Path $Root ("theme\{0}" -f $VariantInfo.Archive)
if ($VariantInfo.Archive -and (Test-Path -LiteralPath $zipCandidate -PathType Leaf)) {
    $sourceOrigin['archive'] = [ordered]@{
        name   = (Split-Path -Leaf $zipCandidate)
        sha256 = (Get-FileHash -LiteralPath $zipCandidate -Algorithm SHA256).Hash
    }
} elseif ($VariantInfo.Archive) {
    # The landed archive is usually NOT under theme\ (fetch caches zips in
    # staging\theme-cache and build never ships them). Fall back to the
    # fetch-time pin in theme\source.json - recorded provenance, not invention:
    # only the name + sha256 fetch pinned are recorded, and only when readable.
    $fetchProvenance = Join-Path $Root 'theme\source.json'
    if (Test-Path -LiteralPath $fetchProvenance -PathType Leaf) {
        try {
            $fp = Get-Content -LiteralPath $fetchProvenance -Raw | ConvertFrom-Json
            $fh = $null
            if ($fp.sha256 -and $fp.sha256.PSObject.Properties[$VariantInfo.Archive]) { $fh = [string]$fp.sha256.($VariantInfo.Archive) }
            if ($fh) {
                $sourceOrigin['archive'] = [ordered]@{
                    name   = $VariantInfo.Archive
                    sha256 = $fh
                    via    = 'theme\source.json (fetch-time pin; archive file not present)'
                }
            }
            if (-not $sourceOrigin.Contains('repo') -and $fp.PSObject.Properties['repo'] -and [string]$fp.repo) {
                $sourceOrigin['repo'] = [string]$fp.repo
            }
        } catch { Write-Output ("WARN source.json unreadable; archive/repo not recorded: {0}" -f $_) }
    }
}
$originSidecar = Join-Path $ThemeDirAbs 'source.json'
if (Test-Path -LiteralPath $originSidecar -PathType Leaf) {
    try {
        $so = Get-Content -LiteralPath $originSidecar -Raw | ConvertFrom-Json
        foreach ($k in @('repo', 'commit', 'archivePath')) {
            if ($so.PSObject.Properties[$k] -and [string]$so.$k) { $sourceOrigin[$k] = [string]$so.$k }
        }
    } catch { Write-Output ("WARN source.json unreadable; repo/commit not recorded: {0}" -f $_) }
}

$manifest = [ordered]@{
    theme         = $VariantInfo.Display
    variantId     = $VariantInfo.Id
    variantSource = $ThemeRel
    sourceOrigin  = $sourceOrigin
    session       = 'arcinstaller'
    generated     = (Get-Date -Format 'o')
    files         = $files
}
if ($existingMan) {
    # Pair-only rebuild: the header (theme + variant + sourceOrigin) describes the
    # payload the UNTOUCHED rows came from. Keep it rather than claim this
    # one-pair rebuild re-verified provenance it never read.
    $manifest.theme = [string]$existingMan.theme
    $manifest.variantId = [string]$existingMan.variantId
    $manifest.variantSource = [string]$existingMan.variantSource
    $manifest.sourceOrigin = $existingMan.sourceOrigin
    Write-Output 'WARN pair-only rebuild: manifest header + sourceOrigin kept from the existing build (untouched rows not re-provenanced)'
}
$mfPath = Join-Path $Root 'installed-manifest.json'
($manifest | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $mfPath -Encoding utf8
Write-Output "MANIFEST: $mfPath"
$buildFail = @($files | Where-Object { $_.invariant -ne 'pass' })
if ($buildFail.Count -eq 0) { Write-Output 'ARC-MERGE: PASS' } else { Write-Output 'ARC-MERGE: FAIL'; exit 1 }
