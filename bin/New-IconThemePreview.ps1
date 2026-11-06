# New-IconThemePreview.ps1 - render a preview sheet from a theme payload.
#
# The neutral variants ship niivu's marketing preview; a derived variant has no
# upstream sheet, so this draws one from the payload it will actually install:
# the first resolvable RT_GROUP_ICON ids at 48 px on a dark card, each labelled
# with its group id. Read-only on the payload; writes exactly -Dest.
#
# Params: -Source <dir holding imageres.dll / imagesp1.dll / zipfldr.dll>
#         -Dest   <png to write; must not be inside C:\Windows>
#         -Title  <sheet title, e.g. 'Arc Dark Grey'>
#         -Note   <one-line derivation note>
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Dest,
    [string]$Title = 'ARC',
    [string]$Note = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Source = (Resolve-Path -LiteralPath $Source).Path
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "payload dir not found: $Source" }
$DestFull = [IO.Path]::GetFullPath($Dest)
if ($DestFull -like 'C:\Windows*') { throw "Refusing to write under C:\Windows (got '$DestFull')." }

Add-Type -AssemblyName System.Drawing
if (-not ([System.Management.Automation.PSTypeName]'ArcPreviewIcons').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ArcPreviewIcons {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr LoadLibraryEx(string f, IntPtr h, uint fl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeLibrary(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr FindResource(IntPtr h, IntPtr n, IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr LoadResource(IntPtr h, IntPtr r);
    [DllImport("kernel32.dll")]
    static extern IntPtr LockResource(IntPtr d);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint SizeofResource(IntPtr h, IntPtr r);
    [DllImport("user32.dll", SetLastError = true)]
    static extern int LookupIconIdFromDirectoryEx(byte[] d, bool fIcon, int cx, int cy, uint fl);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr CreateIconFromResourceEx(byte[] b, uint sz, bool fIcon, uint ver, int cx, int cy, uint fl);
    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr h);

    static byte[] Read(IntPtr hMod, IntPtr hRes) {
        uint sz = SizeofResource(hMod, hRes);
        if (sz == 0) return null;
        IntPtr p = LockResource(LoadResource(hMod, hRes));
        if (p == IntPtr.Zero) return null;
        byte[] b = new byte[(int)sz];
        Marshal.Copy(p, b, 0, (int)sz);
        return b;
    }

    // IntPtr.Zero when the group or a usable member does not exist; the caller
    // wraps the returned HICON in System.Drawing.Icon and destroys it.
    public static IntPtr Load(string file, int groupId, int size) {
        IntPtr hMod = LoadLibraryEx(file, IntPtr.Zero, 2u);
        if (hMod == IntPtr.Zero) return IntPtr.Zero;
        try {
            IntPtr hGroup = FindResource(hMod, (IntPtr)groupId, (IntPtr)14);
            if (hGroup == IntPtr.Zero) return IntPtr.Zero;
            byte[] group = Read(hMod, hGroup);
            if (group == null) return IntPtr.Zero;
            int iconId = LookupIconIdFromDirectoryEx(group, true, size, size, 0);
            if (iconId == 0) return IntPtr.Zero;
            IntPtr hIcon = FindResource(hMod, (IntPtr)iconId, (IntPtr)3);
            if (hIcon == IntPtr.Zero) return IntPtr.Zero;
            byte[] bits = Read(hMod, hIcon);
            if (bits == null) return IntPtr.Zero;
            return CreateIconFromResourceEx(bits, (uint)bits.Length, true, 0x00030000, size, size, 0);
        }
        finally { FreeLibrary(hMod); }
    }
    public static void Destroy(IntPtr h) { if (h != IntPtr.Zero) DestroyIcon(h); }
}
'@
}

# group ids are numeric resources; sorted for a deterministic sheet.
$dll = Join-Path $Source 'imageres.dll'
if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw "missing $dll" }
$iconIds = @()
for ($id = 1; $iconIds.Count -lt 32 -and $id -le 400; $id++) {
    $h = [ArcPreviewIcons]::Load($dll, $id, 48)
    if ($h -ne [IntPtr]::Zero) {
        [ArcPreviewIcons]::Destroy($h)
        $iconIds += $id
    }
}

$cols = 8
$rows = 4
$cell = 72
$padX = 32
$top = 76
$width = $padX * 2 + $cols * $cell
$height = $top + $rows * $cell + 64
$bg = [Drawing.Color]::FromArgb(27, 27, 27)
$fg = [Drawing.Color]::FromArgb(224, 224, 224)
$dim = [Drawing.Color]::FromArgb(140, 140, 140)
$line = [Drawing.Color]::FromArgb(48, 48, 48)

$bmp = New-Object Drawing.Bitmap($width, $height)
$g = [Drawing.Graphics]::FromImage($bmp)
try {
    $g.Clear($bg)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $titleFont = New-Object Drawing.Font('Segoe UI', 15, [Drawing.FontStyle]::Bold)
    $noteFont = New-Object Drawing.Font('Segoe UI', 8.5)
    $idFont = New-Object Drawing.Font('Segoe UI', 6.5)
    try {
        $g.DrawString($Title, $titleFont, (New-Object Drawing.SolidBrush($fg)), 30, 22)
        if ($Note) { $g.DrawString($Note, $noteFont, (New-Object Drawing.SolidBrush($dim)), 32, 50) }
        $pen = New-Object Drawing.Pen($line, 1)
        try { $g.DrawRectangle($pen, 31, 70, $width - 62, $rows * $cell + 2) } finally { $pen.Dispose() }
        for ($i = 0; $i -lt $iconIds.Count; $i++) {
            $id = $iconIds[$i]
            $x = $padX + ($i % $cols) * $cell
            $y = $top + [Math]::Floor($i / $cols) * $cell
            $h = [ArcPreviewIcons]::Load($dll, $id, 48)
            if ($h -ne [IntPtr]::Zero) {
                $ico = [Drawing.Icon]::FromHandle($h)
                try { $g.DrawIcon($ico, ($x + 12), ($y + 8)) }
                finally { $ico.Dispose(); [ArcPreviewIcons]::Destroy($h) }
            }
            $g.DrawString(("#" + $id), $idFont, (New-Object Drawing.SolidBrush($dim)), ($x + 4), ($y + 56))
        }
    }
    finally { $titleFont.Dispose(); $noteFont.Dispose(); $idFont.Dispose() }
    $dir = Split-Path -Parent $DestFull
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($DestFull, [Drawing.Imaging.ImageFormat]::Png)
}
finally { $g.Dispose(); $bmp.Dispose() }

$size = (Get-Item -LiteralPath $DestFull).Length
$sha = (Get-FileHash -LiteralPath $DestFull -Algorithm SHA256).Hash
Write-Output ("PREVIEW {0} {1}x{2} icons={3} size={4} sha256={5}" -f (Split-Path -Leaf $DestFull), $width, $height, $iconIds.Count, $size, $sha)
