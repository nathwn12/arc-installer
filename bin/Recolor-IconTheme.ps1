# Recolor-IconTheme.ps1 - derive a darker Windhawk resource payload from an
# existing one, WITHOUT touching the source payload.
#
# Mechanism: read every RT_ICON (#3) bitmap of -Source, multiply each bitmap's
# R, G and B channel by an effective factor (alpha and every other byte
# untouched), then write the recolored bitmaps into a copy of the file at -Dest
# with the Win32 resource-update API (BeginUpdateResource / UpdateResource /
# EndUpdateResource, the same proven write path as bin\Merge-IconTheme.ps1).
#
# Bitmap kinds handled (all of them; an unhandled kind FAILS the run instead of
# being skipped silently):
#   32bpp BI_RGB DIB   - every pixel's B,G,R multiplied
#   24bpp BI_RGB DIB   - every pixel's B,G,R multiplied
#   1/4/8bpp BI_RGB    - the color table (palette) is multiplied; the palette
#                        indices, the AND mask and every other byte are untouched
#   PNG                - decoded, RGB multiplied, alpha preserved, re-encoded
#                        (System.Drawing / GDI+)
# A PNG re-encode changes the entry's byte length, so any RT_GROUP_ICON (#14)
# entry whose directory declares the OLD length is updated to the new one in the
# same write session. The theme sources hold the invariant "declared size ==
# RT_ICON length" exactly (measured on all three Neutral Grey payloads), and the
# destination is re-checked against it after the write.
#
# Luminance floor, one factor per GROUP: a straight multiply sends an
# already-dark icon toward black (measured: the Hard drive family sits at mean
# luminance 78-91, and k = 0.55 alone drove it to ~43-50). Every RT_GROUP_ICON
# (#14) gets ONE effective factor for ALL of its RT_ICON sizes:
#   kEff = min(1, max(K, Floor / groupMeanLuminance))
# so a glyph cannot come out dark at 16 px and light at 256 px (a dyed size).
# The factor is a single scalar, so every channel of every member is scaled by
# the same number: hue and saturation ratios are preserved EXACTLY - this tool
# never desaturates. A per-PIXEL floor was rejected on purpose: clamping each
# channel separately lands all three channels on the same value, which IS
# desaturation. groupMeanLuminance is the visible-pixel-weighted mean over the
# group's members; an RT_ICON in no group falls back to its own mean.
# Mean luminance is measured over VISIBLE pixels only (alpha >= 128 for 32bpp /
# PNG; the AND mask decides for 24bpp and palette bitmaps), so a transparent
# background cannot drag the mean down.
#
# Neutral-axis guard (checked on the recolored bytes, fails closed):
#   * a neutral source entry (its mean channel spread <= 6, i.e. grey) must
#     stay neutral: output spread <= 6. A residual tint means a dyed grey.
#   * a chromatic source entry (spread > 6, e.g. the blue network glyph) may
#     keep its hue, but the recolor must stay ON the neutral axis: every output
#     channel mean equals sourceMean * kEff within 1, and the output spread
#     equals srcSpread * kEff within 2. Any other deviation is a reject.
#   * fully transparent entries (no visible pixel) are skipped byte-for-byte:
#     there is nothing to darken, and a PNG re-encode would only churn bytes.
# Indexed (1/4/8bpp) bitmaps recolor the palette only; indices, mask and every
# other byte keep their exact source value.
#
# Params: -Source <payload DLL to read>   (never modified)
#         -Dest   <payload DLL to write>  (created; must not equal -Source)
#         -K      <0 < k <= 1>            (RGB multiply factor)
#         -Floor  <0..255>                (per-icon mean-luminance floor; default 64)
#         -DryRun (plan only: reads, recolors in memory, writes nothing)
#
# Never writes to C:\Windows, never writes to its own -Source.
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Dest,
    [Parameter(Mandatory = $true)][double]$K,
    [double]$Floor = 64,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($K -le 0 -or $K -gt 1) { throw "-K must be greater than 0 and at most 1 (got $K)." }
if ($Floor -lt 0 -or $Floor -gt 255) { throw "-Floor must be between 0 and 255 (got $Floor)." }
$Source = (Resolve-Path -LiteralPath $Source).Path
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Source payload not found: $Source" }
$DestFull = [IO.Path]::GetFullPath($Dest)
if ($DestFull -like 'C:\Windows*') { throw "Refusing to write under C:\Windows (got '$DestFull')." }
if ($DestFull -eq $Source) { throw "Refusing to recolor in place: -Dest must differ from -Source ($Source)." }

# ---- Win32 interop: resource read (LoadLibraryEx + enumeration) and the
# ---- resource-update write path, both as measured in bin\Merge-IconTheme.ps1.
if (-not ([System.Management.Automation.PSTypeName]'ArcRecolor').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class ArcRecolorEntry {
    public bool NameIsInt; public int NameInt; public string NameForm;
    public ushort Lang; public byte[] Data;
}

public static class ArcRecolor {
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

    // RT_ICON (#3) entries only - kept as the named entry point.
    public static List<ArcRecolorEntry> ReadIcons(string path) { return ReadType(path, 3); }

    // Every entry of one integer resource type: (name, language, raw bytes).
    public static List<ArcRecolorEntry> ReadType(string path, int wantType) {
        IntPtr h = LoadLibraryEx(path, IntPtr.Zero, 2u);
        if (h == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LoadLibraryEx failed: " + path);
        List<ArcRecolorEntry> all = new List<ArcRecolorEntry>();
        try {
            TProc tc = (hm, tp, lp) => {
                if (!IsInt(tp) || tp.ToInt64() != wantType) return true;
                NProc nc = (hm2, tp2, np, lp2) => {
                    bool ni = IsInt(np);
                    string nf = FormOf(np);
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
                                ArcRecolorEntry e = new ArcRecolorEntry();
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

    // GetLastWin32Error is captured inside the same call: PowerShell's own Win32
    // traffic between a raw P/Invoke return and a PS-side read can clobber it.
    public static int LastError;
    public static IntPtr BeginUpd(string f) {
        IntPtr h = BeginUpdateResource(f, false);
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
    public static bool BytesEqual(byte[] a, byte[] b) {
        if (Object.ReferenceEquals(a, b)) return true;
        if (a == null || b == null) return false;
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    // ---- pixel work (C#, not PowerShell: ~1300 entries x up to 65k pixels) ----
    static double Lum(byte r, byte g, byte b) { return 0.2126 * r + 0.7152 * g + 0.0722 * b; }
    static byte Mul(byte v, double k) { return (byte)Math.Round(v * k, MidpointRounding.AwayFromZero); }

    // returns { meanLuminance, visiblePixels }
    public static double[] Mean32(byte[] b, int off, int pixelBytes) {
        double s = 0; int n = 0;
        for (int i = 0; i < pixelBytes; i += 4) {
            if (b[off + i + 3] < 128) continue;
            s += Lum(b[off + i + 2], b[off + i + 1], b[off + i]); n++;
        }
        return new double[] { n == 0 ? 0.0 : s / n, n };
    }
    public static long Mul32(byte[] s, byte[] d, int off, int pixelBytes, double k) {
        long ch = 0;
        for (int i = 0; i < pixelBytes; i += 4) {
            for (int c = 0; c < 3; c++) {
                byte v = s[off + i + c]; byte nv = Mul(v, k);
                if (nv != v) { d[off + i + c] = nv; ch++; }
            }
        }
        return ch;
    }
    // AND mask: 1bpp, MSB first, 1 = transparent (that pixel is not painted).
    static bool Masked(byte[] b, int maskOff, int maskStride, int x, int y) {
        int i = maskOff + y * maskStride + (x >> 3);
        return ((b[i] >> (7 - (x & 7))) & 1) == 1;
    }
    public static double[] Mean24(byte[] b, int off, int stride, int w, int h, int maskOff, int maskStride) {
        double s = 0; int n = 0;
        for (int y = 0; y < h; y++) {
            int row = off + y * stride;
            for (int x = 0; x < w; x++) {
                if (maskOff >= 0 && Masked(b, maskOff, maskStride, x, y)) continue;
                int p = row + x * 3;
                s += Lum(b[p + 2], b[p + 1], b[p]); n++;
            }
        }
        return new double[] { n == 0 ? 0.0 : s / n, n };
    }
    public static long Mul24(byte[] s, byte[] d, int off, int stride, int w, int h, double k) {
        long ch = 0;
        for (int y = 0; y < h; y++) {
            int row = off + y * stride;
            for (int x = 0; x < w; x++) {
                for (int c = 0; c < 3; c++) {
                    byte v = s[row + x * 3 + c]; byte nv = Mul(v, k);
                    if (nv != v) { d[row + x * 3 + c] = nv; ch++; }
                }
            }
        }
        return ch;
    }
    static int IndexAt(byte[] b, int off, int stride, int bpp, int x, int y) {
        int row = off + y * stride;
        if (bpp == 8) return b[row + x];
        if (bpp == 4) { byte v = b[row + (x >> 1)]; return (x & 1) == 0 ? (v >> 4) : (v & 0xF); }
        return (b[row + (x >> 3)] >> (7 - (x & 7))) & 1;
    }
    public static double[] MeanIndexed(byte[] b, int palOff, int palCount, int pixOff, int stride,
                                       int w, int h, int bpp, int maskOff, int maskStride) {
        double s = 0; int n = 0;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                if (maskOff >= 0 && Masked(b, maskOff, maskStride, x, y)) continue;
                int idx = IndexAt(b, pixOff, stride, bpp, x, y);
                if (idx < 0 || idx >= palCount) continue;
                int p = palOff + idx * 4;
                s += Lum(b[p + 2], b[p + 1], b[p]); n++;
            }
        }
        return new double[] { n == 0 ? 0.0 : s / n, n };
    }
    // A palette is the bitmap's RGB source: multiplying it is the same operation
    // as multiplying the pixels, and it leaves the indices and the mask alone.
    public static long MulPalette(byte[] s, byte[] d, int palOff, int palCount, double k) {
        long ch = 0;
        for (int i = 0; i < palCount; i++) {
            int p = palOff + i * 4;
            for (int c = 0; c < 3; c++) {
                byte v = s[p + c]; byte nv = Mul(v, k);
                if (nv != v) { d[p + c] = nv; ch++; }
            }
        }
        return ch;
    }
    // locked GDI+ buffers: 4 bytes per pixel (BGRA) / 3 bytes per pixel (BGR)
    public static double[] MeanRgba32(byte[] buf, int stride, int w, int h) {
        double s = 0; int n = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 4;
                if (buf[i + 3] < 128) continue;
                s += Lum(buf[i + 2], buf[i + 1], buf[i]); n++;
            }
        }
        return new double[] { n == 0 ? 0.0 : s / n, n };
    }
    public static long MulRgba32(byte[] buf, int stride, int w, int h, double k) {
        long ch = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 4;
                for (int c = 0; c < 3; c++) {
                    byte v = buf[i + c]; byte nv = Mul(v, k);
                    if (nv != v) { buf[i + c] = nv; ch++; }
                }
            }
        }
        return ch;
    }
    public static double[] MeanRgb24(byte[] buf, int stride, int w, int h) {
        double s = 0; int n = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 3;
                s += Lum(buf[i + 2], buf[i + 1], buf[i]); n++;
            }
        }
        return new double[] { n == 0 ? 0.0 : s / n, n };
    }
    public static long MulRgb24(byte[] buf, int stride, int w, int h, double k) {
        long ch = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 3;
                for (int c = 0; c < 3; c++) {
                    byte v = buf[i + c]; byte nv = Mul(v, k);
                    if (nv != v) { buf[i + c] = nv; ch++; }
                }
            }
        }
        return ch;
    }

    // ---- mean RGB per visible pixel (for the per-GROUP factor + neutral guard).
    // Returns { meanR, meanG, meanB, visibleCount }. Luminance of the mean equals
    // the mean luminance because the Rec.709 weights are linear.
    static double[] Pack(double sr, double sg, double sb, int n) {
        if (n == 0) return new double[] { 0, 0, 0, 0 };
        return new double[] { sr / n, sg / n, sb / n, n };
    }
    public static double[] Stats32(byte[] b, int off, int pixelBytes) {
        double r = 0, g = 0, bl = 0; int n = 0;
        for (int i = 0; i < pixelBytes; i += 4) {
            if (b[off + i + 3] < 128) continue;
            bl += b[off + i]; g += b[off + i + 1]; r += b[off + i + 2]; n++;
        }
        return Pack(r, g, bl, n);
    }
    public static double[] Stats24(byte[] b, int off, int stride, int w, int h, int maskOff, int maskStride) {
        double r = 0, g = 0, bl = 0; int n = 0;
        for (int y = 0; y < h; y++) {
            int row = off + y * stride;
            for (int x = 0; x < w; x++) {
                if (maskOff >= 0 && Masked(b, maskOff, maskStride, x, y)) continue;
                int p = row + x * 3;
                bl += b[p]; g += b[p + 1]; r += b[p + 2]; n++;
            }
        }
        return Pack(r, g, bl, n);
    }
    public static double[] StatsIndexed(byte[] b, int palOff, int palCount, int pixOff, int stride,
                                        int w, int h, int bpp, int maskOff, int maskStride) {
        double r = 0, g = 0, bl = 0; int n = 0;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                if (maskOff >= 0 && Masked(b, maskOff, maskStride, x, y)) continue;
                int idx = IndexAt(b, pixOff, stride, bpp, x, y);
                if (idx < 0 || idx >= palCount) continue;
                int p = palOff + idx * 4;
                bl += b[p]; g += b[p + 1]; r += b[p + 2]; n++;
            }
        }
        return Pack(r, g, bl, n);
    }
    public static double[] StatsRgba32(byte[] buf, int stride, int w, int h) {
        double r = 0, g = 0, bl = 0; int n = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 4;
                if (buf[i + 3] < 128) continue;
                bl += buf[i]; g += buf[i + 1]; r += buf[i + 2]; n++;
            }
        }
        return Pack(r, g, bl, n);
    }
    public static double[] StatsRgb24(byte[] buf, int stride, int w, int h) {
        double r = 0, g = 0, bl = 0; int n = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 3;
                bl += buf[i]; g += buf[i + 1]; r += buf[i + 2]; n++;
            }
        }
        return Pack(r, g, bl, n);
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
function Free-ResPtr($r) { if ($r.Free) { [Runtime.InteropServices.Marshal]::FreeHGlobal($r.Ptr) } }

function Get-BitmapPlan([byte[]]$b) {
    # Geometry of one RT_ICON bitmap. 32bpp keeps the original PoC reading: the
    # XOR bitmap is width*4 per row, an icon DIB carries a doubled biHeight and a
    # 1bpp AND mask after the XOR rows. Returns Ok=$false plus a named Reason.
    $r = @{
        Ok = $false; Kind = ''; Reason = ''; Width = 0; Height = 0; Bpp = 0; Stride = 0
        PixelOffset = 0; PixelBytes = 0; PaletteOffset = 0; PaletteCount = 0
        MaskOffset = -1; MaskStride = 0
    }
    if ($b.Length -lt 40) { $r.Reason = 'shorter than a BITMAPINFOHEADER'; return $r }
    $biSize = [BitConverter]::ToUInt32($b, 0)
    if ($biSize -lt 40 -or $biSize -gt $b.Length) { $r.Reason = "biSize=$biSize"; return $r }
    $w = [BitConverter]::ToInt32($b, 4)
    $hdrH = [BitConverter]::ToInt32($b, 8)
    $bpp = [BitConverter]::ToUInt16($b, 14)
    $comp = [BitConverter]::ToUInt32($b, 16)
    $clrUsed = [BitConverter]::ToUInt32($b, 32)
    $r.Bpp = $bpp
    if ($comp -ne 0) { $r.Reason = "compression=$comp (BI_RGB only)"; return $r }
    if (@(1, 4, 8, 24, 32) -notcontains [int]$bpp) { $r.Reason = "${bpp}bpp (no recolor path)"; return $r }
    if ($w -le 0 -or $hdrH -le 0) { $r.Reason = "width=$w height=$hdrH"; return $r }
    $palCount = if ($bpp -le 8) { if ($clrUsed -gt 0) { [int]$clrUsed } else { [int][Math]::Pow(2, $bpp) } } else { 0 }
    $palOff = [int]$biSize
    $stride = [int]([Math]::Floor(($w * $bpp + 31) / 32) * 4)
    $maskStride = [int](([Math]::Floor(($w + 31) / 32)) * 4)
    $pixelsAt = $palOff + $palCount * 4
    # Prefer the icon convention (doubled height + AND mask); fall back to the
    # full biHeight only when the AND mask really is absent.
    foreach ($h in @([int]($hdrH / 2), $hdrH)) {
        if ($h -le 0) { continue }
        $iconFormat = ($hdrH -eq 2 * $h)
        $need = $pixelsAt + $stride * $h
        if ($iconFormat) { $need += $maskStride * $h }
        if ($need -le $b.Length) {
            $r.Ok = $true; $r.Width = $w; $r.Height = $h; $r.Stride = $stride
            $r.PixelOffset = $pixelsAt; $r.PixelBytes = $stride * $h
            $r.PaletteOffset = $palOff; $r.PaletteCount = $palCount
            $r.MaskStride = $maskStride
            $r.MaskOffset = if ($iconFormat) { $pixelsAt + $stride * $h } else { -1 }
            $r.Kind = if ($bpp -eq 32) { 'dib32' } elseif ($bpp -eq 24) { 'dib24' } else { 'indexed' }
            return $r
        }
    }
    $r.Reason = "bitmap data does not fit ($($b.Length) bytes for ${w}x${hdrH})"
    return $r
}

function Get-EffectiveFactor([double]$mean, [int]$visible) {
    # min(1, max(K, Floor/mean)): one scalar per GROUP, so no member size can
    # drift and hue is untouched. mean = 0 (no visible pixel) takes K.
    $eff = $K
    if ($visible -gt 0 -and $mean -gt 0) {
        $need = $Floor / $mean
        if ($need -ge 1.0) { $eff = 1.0 }
        elseif ($need -gt $K) { $eff = $need }
    }
    return $eff
}
function Get-Lum([double]$r, [double]$g, [double]$b) {
    return 0.2126 * $r + 0.7152 * $g + 0.0722 * $b
}
function Get-BitmapStats([byte[]]$b, $plan) {
    $st = switch ($plan.Kind) {
        'dib32' { [ArcRecolor]::Stats32($b, $plan.PixelOffset, $plan.PixelBytes) }
        'dib24' { [ArcRecolor]::Stats24($b, $plan.PixelOffset, $plan.Stride, $plan.Width, $plan.Height, $plan.MaskOffset, $plan.MaskStride) }
        'indexed' { [ArcRecolor]::StatsIndexed($b, $plan.PaletteOffset, $plan.PaletteCount, $plan.PixelOffset, $plan.Stride, $plan.Width, $plan.Height, $plan.Bpp, $plan.MaskOffset, $plan.MaskStride) }
        default { throw "Get-BitmapStats got an unknown kind '$($plan.Kind)'." }
    }
    return $st
}
function Get-BitmapRecolored([byte[]]$b, $plan, [double]$eff) {
    # One group factor is passed in; this function only multiplies and reports
    # the recolored mean RGB so the neutral-axis guard can check the real bytes.
    $out = New-Object byte[] $b.Length
    [Array]::Copy($b, $out, $b.Length)
    $changed = switch ($plan.Kind) {
        'dib32' { [ArcRecolor]::Mul32($b, $out, $plan.PixelOffset, $plan.PixelBytes, $eff) }
        'dib24' { [ArcRecolor]::Mul24($b, $out, $plan.PixelOffset, $plan.Stride, $plan.Width, $plan.Height, $eff) }
        'indexed' { [ArcRecolor]::MulPalette($b, $out, $plan.PaletteOffset, $plan.PaletteCount, $eff) }
        default { throw "Get-BitmapRecolored got an unknown kind '$($plan.Kind)'." }
    }
    $outStats = switch ($plan.Kind) {
        'dib32' { [ArcRecolor]::Stats32($out, $plan.PixelOffset, $plan.PixelBytes) }
        'dib24' { [ArcRecolor]::Stats24($out, $plan.PixelOffset, $plan.Stride, $plan.Width, $plan.Height, $plan.MaskOffset, $plan.MaskStride) }
        'indexed' { [ArcRecolor]::StatsIndexed($out, $plan.PaletteOffset, $plan.PaletteCount, $plan.PixelOffset, $plan.Stride, $plan.Width, $plan.Height, $plan.Bpp, $plan.MaskOffset, $plan.MaskStride) }
    }
    return @{ Bytes = $out; Changed = $changed; R = $outStats[0]; G = $outStats[1]; B = $outStats[2]; Visible = [int]$outStats[3] }
}

function Open-PngBuffer([byte[]]$b) {
    # Decode -> a 32bpp ARGB (or source 24bpp) bitmap plus one locked buffer's
    # copy. Returns the pieces so stats and recolor share no state.
    $ms = New-Object IO.MemoryStream(, $b)
    $img = [System.Drawing.Bitmap]::FromStream($ms)
    $bmp = $img
    $owned = $false
    $fmt = $img.PixelFormat
    if ($fmt -ne [System.Drawing.Imaging.PixelFormat]::Format32bppArgb -and
        $fmt -ne [System.Drawing.Imaging.PixelFormat]::Format24bppRgb) {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $img.Width, $img.Height)
        $bmp = $img.Clone($rect, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $owned = $true
        $fmt = $bmp.PixelFormat
    }
    return @{ Ms = $ms; Img = $img; Bmp = $bmp; Owned = $owned; Fmt = $fmt }
}
function Close-PngBuffer($p) {
    if ($p.Owned) { $p.Bmp.Dispose() }
    $p.Img.Dispose(); $p.Ms.Dispose()
}
function Get-PngStats([byte[]]$b) {
    # Decode only: mean RGB of the visible pixels. Recolored bytes are measured
    # separately, so the guard never trusts the scalar arithmetic alone.
    $p = Open-PngBuffer $b
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $p.Bmp.Width, $p.Bmp.Height)
        $lock = $p.Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $p.Fmt)
        try {
            $stride = $lock.Stride
            $len = $stride * $p.Bmp.Height
            $buf = New-Object byte[] $len
            [Runtime.InteropServices.Marshal]::Copy($lock.Scan0, $buf, 0, $len)
            if ($p.Fmt -eq [System.Drawing.Imaging.PixelFormat]::Format32bppArgb) {
                return [ArcRecolor]::StatsRgba32($buf, $stride, $p.Bmp.Width, $p.Bmp.Height)
            }
            return [ArcRecolor]::StatsRgb24($buf, $stride, $p.Bmp.Width, $p.Bmp.Height)
        }
        finally { $p.Bmp.UnlockBits($lock) }
    }
    finally { Close-PngBuffer $p }
}
function Get-PngRecolored([byte[]]$b, [double]$eff) {
    # Decode -> multiply RGB in place on the locked buffer -> re-encode. Alpha
    # survives untouched; the recolored buffer is measured before encoding.
    $p = Open-PngBuffer $b
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $p.Bmp.Width, $p.Bmp.Height)
        $lock = $p.Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, $p.Fmt)
        try {
            $stride = $lock.Stride
            $len = $stride * $p.Bmp.Height
            $buf = New-Object byte[] $len
            [Runtime.InteropServices.Marshal]::Copy($lock.Scan0, $buf, 0, $len)
            if ($p.Fmt -eq [System.Drawing.Imaging.PixelFormat]::Format32bppArgb) {
                $changed = [ArcRecolor]::MulRgba32($buf, $stride, $p.Bmp.Width, $p.Bmp.Height, $eff)
                $outStats = [ArcRecolor]::StatsRgba32($buf, $stride, $p.Bmp.Width, $p.Bmp.Height)
            } else {
                $changed = [ArcRecolor]::MulRgb24($buf, $stride, $p.Bmp.Width, $p.Bmp.Height, $eff)
                $outStats = [ArcRecolor]::StatsRgb24($buf, $stride, $p.Bmp.Width, $p.Bmp.Height)
            }
            [Runtime.InteropServices.Marshal]::Copy($buf, 0, $lock.Scan0, $len)
        }
        finally { $p.Bmp.UnlockBits($lock) }
        $out = New-Object IO.MemoryStream
        try {
            $p.Bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
            $new = $out.ToArray()
        }
        finally { $out.Dispose() }
        return @{ Bytes = $new; Changed = $changed; R = $outStats[0]; G = $outStats[1]; B = $outStats[2]; Visible = [int]$outStats[3] }
    }
    finally { Close-PngBuffer $p }
}

Add-Type -AssemblyName System.Drawing

# ---- plan ----
$srcSize = (Get-Item -LiteralPath $Source).Length
$srcSha = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
$entries = @([ArcRecolor]::ReadIcons($Source) | Sort-Object -Property NameInt)
Write-Output ("SOURCE {0} size={1} sha256={2} RT_ICON={3}" -f (Split-Path -Leaf $Source), $srcSize, $srcSha, $entries.Count)

function Get-IconKey($entry) { return ("{0}|{1}" -f $entry.NameForm, $entry.Lang) }

$analysis = New-Object System.Collections.ArrayList
$unsupported = @()
foreach ($e in $entries) {
    $isPng = ($e.Data.Length -ge 4 -and $e.Data[0] -eq 0x89 -and $e.Data[1] -eq 0x50 -and $e.Data[2] -eq 0x4E -and $e.Data[3] -eq 0x47)
    if ($isPng) {
        $st = Get-PngStats $e.Data
        $plan = $null
        $kind = 'png'
        $geo = "png {0} B" -f $e.Data.Length
    } else {
        $plan = Get-BitmapPlan $e.Data
        if (-not $plan.Ok) {
            $unsupported += [pscustomobject]@{ Name = $e.NameForm; Reason = $plan.Reason; Bytes = $e.Data.Length }
            continue
        }
        $st = Get-BitmapStats $e.Data $plan
        $kind = $plan.Kind
        $geo = "{0} {1}x{2} {3}B pixel={4} B" -f $plan.Kind, $plan.Width, $plan.Height, $e.Data.Length, $plan.PixelBytes
    }
    $spread = [Math]::Max([Math]::Max($st[0], $st[1]), $st[2]) - [Math]::Min([Math]::Min($st[0], $st[1]), $st[2])
    [void]$analysis.Add([pscustomobject]@{
        Entry = $e; Kind = $kind; Plan = $plan; IsPng = $isPng; Data = $e.Data; Geo = $geo
        R = $st[0]; G = $st[1]; B = $st[2]; Visible = [int]$st[3]
        Lum = (Get-Lum $st[0] $st[1] $st[2]); Spread = $spread
        Neutral = ($spread -le 6); KEff = 0.0; GroupKey = ''; Ungrouped = $false
    })
}
foreach ($s in $unsupported) { Write-Output ("UNSUPPORTED {0} {1} B - {2}" -f $s.Name, $s.Bytes, $s.Reason) }

# ---- group pass: ONE kEff per RT_GROUP_ICON, shared by every member size ----
$byNid = @{}
foreach ($a in $analysis) {
    if (-not $byNid.ContainsKey($a.Entry.NameForm)) { $byNid[$a.Entry.NameForm] = $a }
}
$groupEntries = @([ArcRecolor]::ReadType($Source, 14) | Sort-Object -Property NameInt)
$groupInfo = [ordered]@{}
$iconGroups = @{}
foreach ($g in $groupEntries) {
    if ($g.Data.Length -lt 6) { continue }
    $count = [BitConverter]::ToUInt16($g.Data, 4)
    $seen = @{}
    $members = @()
    for ($i = 0; $i -lt $count; $i++) {
        $off = 6 + $i * 14
        if ($off + 14 -gt $g.Data.Length) { continue }
        $nid = '#' + [BitConverter]::ToUInt16($g.Data, $off + 12)
        if ($seen.ContainsKey($nid)) { continue }
        $seen[$nid] = $true
        if ($byNid.ContainsKey($nid)) { $members += $byNid[$nid] }
    }
    if ($members.Count -eq 0) { continue }
    $vis = 0; $sr = 0.0; $sg = 0.0; $sb = 0.0
    foreach ($m in $members) {
        if ($m.Visible -le 0) { continue }
        $vis += $m.Visible; $sr += $m.R * $m.Visible; $sg += $m.G * $m.Visible; $sb += $m.B * $m.Visible
    }
    $meanLum = 0.0
    if ($vis -gt 0) { $meanLum = Get-Lum ($sr / $vis) ($sg / $vis) ($sb / $vis) }
    $eff = Get-EffectiveFactor $meanLum $vis
    $gk = "{0}|{1}" -f $g.NameForm, $g.Lang
    $groupInfo[$gk] = [pscustomobject]@{
        Key = $gk; Name = $g.NameForm; Lang = $g.Lang; Members = @($members)
        Visible = $vis; MeanLum = $meanLum; KEff = $eff
    }
    foreach ($m in $members) {
        $ik = Get-IconKey $m.Entry
        if (-not $iconGroups.ContainsKey($ik)) { $iconGroups[$ik] = @() }
        $iconGroups[$ik] += $gk
    }
    Write-Output ("GROUP {0} lang={1} members={2} meanLum={3} visible={4} kEff={5}" -f `
            $g.NameForm, $g.Lang, $members.Count, [Math]::Round($meanLum, 2), $vis, [Math]::Round($eff, 4))
}
$groupConflicts = 0
foreach ($a in $analysis) {
    $ik = Get-IconKey $a.Entry
    if ($iconGroups.ContainsKey($ik)) {
        $gks = @($iconGroups[$ik])
        $a.GroupKey = $gks[0]
        $a.KEff = [double]$groupInfo[$a.GroupKey].KEff
        # a member referenced by two groups with different factors is a data
        # conflict, not something to paper over with an average.
        foreach ($other in $gks) {
            if ($other -ne $a.GroupKey -and [Math]::Abs([double]$groupInfo[$other].KEff - $a.KEff) -gt 0.0001) { $groupConflicts++ }
        }
    } else {
        $a.Ungrouped = $true
        $a.KEff = Get-EffectiveFactor $a.Lum $a.Visible
    }
}

# ---- recolor + neutral-axis guard (measured on the bytes just produced) ----
$planned = @()
$violations = @()
$skippedTransparent = 0
$guardNeutral = 0
$guardChromatic = 0
foreach ($a in $analysis) {
    if ($a.Visible -eq 0) {
        $skippedTransparent++
        Write-Output ("SKIP {0} {1} fully transparent - left byte-identical" -f $a.Entry.NameForm, $a.Geo)
        continue
    }
    $eff = [double]$a.KEff
    if ($a.IsPng) {
        $rc = Get-PngRecolored $a.Data $eff
        $geoOut = "png {0} B -> {1} B" -f $a.Data.Length, $rc.Bytes.Length
    } else {
        $rc = Get-BitmapRecolored $a.Data $a.Plan $eff
        $geoOut = $a.Geo
    }
    $outSpread = [Math]::Max([Math]::Max($rc.R, $rc.G), $rc.B) - [Math]::Min([Math]::Min($rc.R, $rc.G), $rc.B)
    $dev = [Math]::Max([Math]::Abs($rc.R - $a.R * $eff), [Math]::Max([Math]::Abs($rc.G - $a.G * $eff), [Math]::Abs($rc.B - $a.B * $eff)))
    $bad = ''
    if ($dev -gt 1.0) {
        $bad = ("off neutral axis: channel mean deviation {0:N2}" -f $dev)
    } elseif ($a.Neutral -and $outSpread -gt 6) {
        $bad = ("dyed grey: neutral group output spread {0:N2} > 6" -f $outSpread)
    } elseif (-not $a.Neutral -and [Math]::Abs($outSpread - $a.Spread * $eff) -gt 2.0) {
        $bad = ("chroma drift: output spread {0:N2} != source*{1:N2} (expected {2:N2})" -f $outSpread, $eff, ($a.Spread * $eff))
    }
    if ($bad) {
        $violations += ("{0} [{1}] {2} - {3}" -f $a.Entry.NameForm, $a.GroupKey, $a.Kind, $bad)
        continue
    }
    if ($a.Neutral) { $guardNeutral++ } else { $guardChromatic++ }
    $planned += [pscustomobject]@{
        Entry = $a.Entry; Kind = $a.Kind; New = $rc.Bytes; Changed = $rc.Changed
        Mean = $a.Lum; OutSpread = $outSpread; Visible = $a.Visible; Eff = $eff; GroupKey = $a.GroupKey
        FloorClamped = ($eff -gt $K); FloorHeld = ($eff -ge 1.0)
    }
    Write-Output ("PLAN {0} {1} group={2} meanLum={3} kEff={4} outSpread={5} changed={6} B" -f `
            $a.Entry.NameForm, $geoOut, $a.GroupKey, [Math]::Round($a.Lum, 2), [Math]::Round($eff, 4), [Math]::Round($outSpread, 2), $rc.Changed)
}
foreach ($v in $violations) { Write-Output ("GUARD-REJECT {0}" -f $v) }
if ($violations.Count -gt 0) {
    throw ("Nothing written: {0} entr(y/ies) failed the neutral-axis guard (see GUARD-REJECT above) - refusing to ship a dyed grey." -f $violations.Count)
}


# ---- RT_GROUP_ICON: a PNG re-encode changes the entry length, and the group
# ---- directory declares that length, so the declaring entry is rewritten too.
$iconLen = @{}
foreach ($p in $planned) { $iconLen["$($p.Entry.NameForm)|$($p.Entry.Lang)"] = $p.New.Length }
$groupPlans = @()
foreach ($g in $groupEntries) {
    $nb = New-Object byte[] $g.Data.Length
    [Array]::Copy($g.Data, $nb, $g.Data.Length)
    if ($nb.Length -lt 6) { continue }
    $count = [BitConverter]::ToUInt16($nb, 4)
    $touched = 0
    for ($i = 0; $i -lt $count; $i++) {
        $off = 6 + $i * 14
        if ($off + 14 -gt $nb.Length) { continue }
        $nid = [BitConverter]::ToUInt16($nb, $off + 12)
        $key = "#$nid|$($g.Lang)"
        if (-not $iconLen.ContainsKey($key)) { continue }
        $newLen = $iconLen[$key]
        if ([BitConverter]::ToUInt32($nb, $off + 8) -ne $newLen) {
            [Array]::Copy([BitConverter]::GetBytes([uint32]$newLen), 0, $nb, $off + 8, 4)
            $touched++
        }
    }
    if ($touched -gt 0) {
        $groupPlans += [pscustomobject]@{ Entry = $g; New = $nb; Touched = $touched }
        Write-Output ("GROUP {0} lang={1} resizedEntries={2}" -f $g.NameForm, $g.Lang, $touched)
    }
}

$counts = @{}
# NB: the loop variable must NOT be named $k - PowerShell names are
# case-insensitive, so $k IS the [double]$K parameter.
foreach ($kindName in @('dib32', 'dib24', 'indexed', 'png')) { $counts[$kindName] = @($planned | Where-Object Kind -eq $kindName).Count }
$totalChanged = 0
foreach ($p in $planned) { $totalChanged += $p.Changed }
$clamped = @($planned | Where-Object FloorClamped).Count
$held = @($planned | Where-Object FloorHeld).Count
$ungrouped = @($analysis | Where-Object Ungrouped).Count
Write-Output ("RECOLOR-PLAN file={0} entries={1} dib32={2} dib24={3} dib_indexed={4} png={5} unsupported={6} groups={7} ungrouped={8} floorClamped={9} floorHeld={10} skippedTransparent={11} guardNeutral={12} guardChromatic={13} guardViolations={14} groupConflicts={15} groupsResized={16} changedBytes={17} k={18} floor={19}" -f `
        (Split-Path -Leaf $Source), $entries.Count, $counts['dib32'], $counts['dib24'], $counts['indexed'], $counts['png'], `
        $unsupported.Count, $groupInfo.Count, $ungrouped, $clamped, $held, $skippedTransparent, $guardNeutral, $guardChromatic, $violations.Count, $groupConflicts, $groupPlans.Count, $totalChanged, $K, $Floor)

if ($DryRun) {
    Write-Output 'RECOLOR: DRY-RUN (nothing written)'
    exit 0
}
if ($unsupported.Count -gt 0) { throw "Nothing written: $($unsupported.Count) RT_ICON entries have no recolor path (see UNSUPPORTED above)." }
if ($planned.Count -eq 0) { throw 'Nothing to recolor: no RT_ICON bitmap in the source payload.' }

# ---- write: copy the source, then update the recolored RT_ICON entries plus
# ---- any RT_GROUP_ICON entry whose declared size changed.
# bin\Merge-IconTheme.ps1 measured one resource-update session capping out near
# ~3200 ops / ~23MB (imageres failed mid-way there), and this write is ~1300 ops
# over ~48MB, so ops are packed into chunks of <=1200 ops and <=8MB - the same
# measured policy. Each (type,name,lang) key is still written exactly once.
$ops = New-Object System.Collections.ArrayList
foreach ($p in $planned) {
    [void]$ops.Add(@{ Type = 3; NameForm = $p.Entry.NameForm; NameIsInt = [bool]$p.Entry.NameIsInt; Lang = [uint16]$p.Entry.Lang; Data = $p.New; Op = "RT_ICON $($p.Entry.NameForm) lang $($p.Entry.Lang)" })
}
foreach ($g in $groupPlans) {
    [void]$ops.Add(@{ Type = 14; NameForm = $g.Entry.NameForm; NameIsInt = [bool]$g.Entry.NameIsInt; Lang = [uint16]$g.Entry.Lang; Data = $g.New; Op = "RT_GROUP_ICON $($g.Entry.NameForm) lang $($g.Entry.Lang)" })
}
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

$destDir = Split-Path -Parent $DestFull
if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
Copy-Item -LiteralPath $Source -Destination $DestFull -Force

$chunkIndex = 0
try {
    foreach ($chunk in $chunks) {
        Write-Output ("SESSION {0}: {1} ops, {2} bytes" -f $chunkIndex, $chunk.Count, (($chunk | Measure-Object -Property { $_.Data.Length } -Sum).Sum))
        $h = [ArcRecolor]::BeginUpd($DestFull)
        if ($h -eq [IntPtr]::Zero) {
            $w = New-Object ComponentModel.Win32Exception([ArcRecolor]::LastError)
            throw "BeginUpdateResource failed on '$DestFull' (session $chunkIndex): code $([ArcRecolor]::LastError) $($w.Message) - STOPPING."
        }
        $sessionOk = $false
        try {
            foreach ($op in $chunk) {
                $tp = [IntPtr]$op.Type
                $np = New-ResPtr $op.NameForm ([bool]$op.NameIsInt)
                try {
                    $ok = [ArcRecolor]::UpdRes($h, $tp, $np.Ptr, [uint16]$op.Lang, $op.Data, [uint32]$op.Data.Length)
                    if (-not $ok) {
                        $w = New-Object ComponentModel.Win32Exception([ArcRecolor]::LastError)
                        throw "UpdateResource session $chunkIndex $($op.Op) failed: code $([ArcRecolor]::LastError) $($w.Message) - STOPPING."
                    }
                }
                finally { Free-ResPtr $np }
            }
            if (-not [ArcRecolor]::EndUpd($h, $false)) {
                $w = New-Object ComponentModel.Win32Exception([ArcRecolor]::LastError)
                throw "EndUpdateResource failed on '$DestFull' (session $chunkIndex): code $([ArcRecolor]::LastError) $($w.Message) - STOPPING."
            }
            $h = [IntPtr]::Zero
            $sessionOk = $true
        }
        finally {
            if (-not $sessionOk -and $h -ne [IntPtr]::Zero) { try { [void][ArcRecolor]::EndUpd($h, $true) } catch {}; $h = [IntPtr]::Zero }
        }
        $chunkIndex++
    }
}
catch {
    # a half-written payload must never look like a baked one: drop it and fail.
    if (Test-Path -LiteralPath $DestFull) { Remove-Item -LiteralPath $DestFull -Force -ErrorAction SilentlyContinue }
    throw
}

# ---- verify the write by reading the destination back ----
$back = @{}
$destIcons = @([ArcRecolor]::ReadIcons($DestFull))
foreach ($e in $destIcons) { $back["$($e.NameForm)|$($e.Lang)"] = $e.Data }
$bad = @()
foreach ($p in $planned) {
    # NB: never name this local $k - PowerShell variable names are
    # case-insensitive, so $k IS the [double]$K parameter (measured: assignment
    # of the string key threw "cannot convert '#1|1033' to System.Double").
    $key = "$($p.Entry.NameForm)|$($p.Entry.Lang)"
    if (-not $back.ContainsKey($key)) { $bad += "$key(absent)"; continue }
    if (-not [ArcRecolor]::BytesEqual($back[$key], $p.New)) { $bad += "$key(differs)"; continue }
}
$backGroups = @{}
foreach ($g in [ArcRecolor]::ReadType($DestFull, 14)) { $backGroups["$($g.NameForm)|$($g.Lang)"] = $g.Data }
foreach ($g in $groupPlans) {
    $key = "$($g.Entry.NameForm)|$($g.Entry.Lang)"
    if (-not $backGroups.ContainsKey($key)) { $bad += "$key(group absent)"; continue }
    if (-not [ArcRecolor]::BytesEqual($backGroups[$key], $g.New)) { $bad += "$key(group differs)" }
}
# group/icon size invariant: every directory entry must declare the length of
# the RT_ICON it names (this is what the theme sources hold, so the recolored
# payload must hold it too - a PNG re-encode is exactly what can break it).
$destLen = @{}
foreach ($e in $destIcons) { $destLen["$($e.NameForm)|$($e.Lang)"] = $e.Data.Length }
$sizeChecked = 0
$sizeBad = 0
foreach ($g in [ArcRecolor]::ReadType($DestFull, 14)) {
    $gb = $g.Data
    if ($gb.Length -lt 6) { continue }
    $count = [BitConverter]::ToUInt16($gb, 4)
    for ($i = 0; $i -lt $count; $i++) {
        $off = 6 + $i * 14
        if ($off + 14 -gt $gb.Length) { continue }
        $nid = [BitConverter]::ToUInt16($gb, $off + 12)
        $key = "#$nid|$($g.Lang)"
        if (-not $destLen.ContainsKey($key)) { continue }
        $sizeChecked++
        if ([BitConverter]::ToUInt32($gb, $off + 8) -ne $destLen[$key]) {
            $sizeBad++
            if ($sizeBad -le 5) { $bad += "$key(group declares $([BitConverter]::ToUInt32($gb, $off + 8)) actual $($destLen[$key]))" }
        }
    }
}

$dstSize = (Get-Item -LiteralPath $DestFull).Length
$dstSha = (Get-FileHash -LiteralPath $DestFull -Algorithm SHA256).Hash
Write-Output ("DEST {0} size={1} sha256={2}" -f (Split-Path -Leaf $DestFull), $dstSize, $dstSha)
Write-Output ("CHECK group-sizes: {0}/{1} directory entries declare the RT_ICON length they name ({2} bad)" -f ($sizeChecked - $sizeBad), $sizeChecked, $sizeBad)
if ($bad.Count -eq 0) {
    Write-Output ("RECOLOR: PASS entries={0} recolored={1} unsupported={2} floorClamped={3} floorHeld={4} changedBytes={5} groupsResized={6} size {7}->{8} k={9} floor={10}" -f `
            $entries.Count, $planned.Count, $unsupported.Count, $clamped, $held, $totalChanged, $groupPlans.Count, $srcSize, $dstSize, $K, $Floor)
    exit 0
}
Write-Output ("RECOLOR: FAIL readback mismatches: {0}" -f ($bad -join ','))
exit 1
