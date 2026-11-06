# ArcInstaller icon — design + render notes

Artifact: `ArcInstaller.ico` — the application icon for `ArcInstaller.exe`, a tool that
installs / repairs / reverts four Windows icon-theme variants (ARC, Arc Neutral Brown,
Arc Neutral Grey, Arc Dark Grey) by swapping resource payloads under
`C:\Windows\SystemResources`.

Everything here is **original art drawn by code**. No third-party asset, no download,
no system font glyph, no traced bitmap.

---

## 1. Concept

**Primary: Candidate A — "four variants in one tile".**
A rounded app tile carrying a 2×2 grid of four flat grey swatches, stepped along the
grey ladder from lightest (top-left) to darkest (bottom-right). The tile gives the
icon an app-icon silhouette that reads at any size; the four swatches state the tool's
whole job — four theme variants — and the light→dark ramp states that they are shades
of one theme family rather than four unrelated things. A plate behind the swatches
keeps the mark legible on *both* a light and a dark desktop, which a bare light-grey
tile would not be.

### The three candidates (drawn at 256px, in `candidates/`)

| Candidate | Idea | 16px read (ASCII-ramp probe) | Verdict |
|---|---|---|---|
| **A** — variant grid | app tile + 2×2 grey ladder | four distinct swatches survive, dark separators intact | **chosen** |
| B — layered stack | three offset tiles = payloads swapped in place | collapses to a single blob; the 3 layer offsets blur into one square | rejected: fails at 16px |
| C — Arc "A" | light tile, knockout geometric **A**, arc sweep | the A *does* survive at 16px; strongest brand read | runner-up: says "Arc" but not "four variants / theme tool" |

Candidate B is kept as the honest negative result — it looks correct at 256px but its
message is destroyed at 16px, which is the size that decides the taskbar and Explorer
column views.

### Palette

Strictly the briefed dark-grey band, plus black at low alpha for the drop shadow:

| Role | Value |
|---|---|
| tile plate (gradient) | `#4E4E4E` → `#404040` |
| plate rim (≥24px only) | `#A0A0A0` @ alpha 130 |
| swatch ladder | `#C0C0C0`, `#A8A8A8`, `#909090`, `#707070` |
| shadow | `#000000` @ alpha 12 × 5 passes |

No hue is introduced anywhere: the icon stays a neutral grey, matching an
icon-theme tool and sitting correctly next to the monochrome Arc shell icons.

---

## 2. Render method

Single C# source, `src/IconForge.cs`, compiled with the in-box
`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` (C# 5, `System.Drawing` only).

- Geometry is authored in **logical pixels** (`N` = target size) with size-aware clamps,
  then scaled into a **4× supersampled** canvas and downsampled with `HighQualityBicubic`.
  Same source produces every size; there is no "draw once, shrink forever" pass.
- Clamps keep every feature above the pixel floor at 16px: plate inset ≥1px, grid pad
  ≥1px, inter-swatch gap ≥1.5px, corner radii ≥0.5px. Hairline plate rim is skipped
  below 24px; the shadow stays soft and small.
- The ICO is written by hand in `IconForge.cs` (`WriteIco` / `ToDib` / `ToPng`):
  32bpp BGRA DIB payloads (bottom-up rows + 4-byte-aligned AND mask) for the small
  sizes, PNG payloads for 128 and 256.
- `IconForge extract` parses the finished `.ico` back off disk and decodes both payload
  kinds, so every exported PNG is a genuine re-read of the file that ships.

Reproduce everything:

```powershell
pwsh -NoProfile -File .\build.ps1 -Variant A
```

---

## 3. Sizes embedded in `ArcInstaller.ico`

7 entries, in order (verified by `IconForge enum` — a direct header parse, not a claim):

| # | size | format | payload bytes |
|---|---|---|---|
| 0 | 16×16 | 32bpp BGRA DIB | 1128 |
| 1 | 24×24 | 32bpp BGRA DIB | 2440 |
| 2 | 32×32 | 32bpp BGRA DIB | 4264 |
| 3 | 48×48 | 32bpp BGRA DIB | 9640 |
| 4 | 64×64 | 32bpp BGRA DIB | 16936 |
| 5 | 128×128 | PNG | 5715 |
| 6 | 256×256 | PNG | 14640 |

Total file: 54881 bytes.

---

## 4. Proof (all local, all verbatim)

1. **Enumeration** — `IconForge enum ArcInstaller.ico` → the 7 sizes above.
2. **Back-render from the .ico** — `icon-256.png` and `icon-32.png` are decoded from the
   ICO entry payloads; `icon-16-zoom8x.png` is the 16px frame decoded from the ICO and
   shown at 8× nearest-neighbour over white / mid-grey / #1E1E1E panels.
3. **sha256** — see the manifest below. `icon-32.png` and `candidates/candidate-A-32.png`
   share a hash, i.e. the DIB round trip through the ICO is bit-exact at 32px.
4. **Compiler acceptance** (`csc /win32icon`, temp probe, since deleted) — csc exits 0 and
   **all 7 payloads appear byte-for-byte inside the compiled .exe**, PNG entries included:
   `16@2888 24@4016 32@6456 48@10720 64@20360 128@37296 256@43016`, all `verbatim=True`.
5. **Windows reads it back** — `Icon.ExtractAssociatedIcon(stub.exe)` returns 32×32 and its
   pixel sha256 equals `icon-32.png`'s
   (`ba9e32bc0d0d03970948532233b5fc15e6e7cf86be74a10a2ab9a9b200c6da20`).
6. **16px legibility** — measured by ASCII-ramp dump of the 16px frame decoded from the
   ICO: two swatch columns split by a 2px dark separator, two swatch rows split by a 2px
   dark separator, four swatches at four distinct luminances, 72% ink coverage, 28×28
   bbox at 32px and a 14×14 bbox at 16px. This is a text-source read, not a visual verdict.

### sha256 manifest

```
2f1833d8b64193754a30e4959ce48835da723247dd93c283a0093a8aaeccea9e2  ArcInstaller.ico
28eb6eaa9109a955726f076f4ef1f25a105bc425125672228efb108a6b058995  icon-256.png
ff2750a543fdbe34663c0d908d5e65a13f72ae37dfa05b37387d68a5f31c78e6  icon-32.png
1adbd4319b6a84277c545d04a9e3fadaecc813c33d554213d78eade13e5b7fd0  icon-16-zoom8x.png
f2838d91245876368649de722c5d9be283b4ebc06af4ac034112699b151fc231  candidates/candidate-A.png
9163988887021af95e1745e0a3fc6ad7b4ccaccca33cd2db021f37e5fb0aaa23  candidates/candidate-B.png
905c62d05946f66a29e1111dc4a288271aeacaf31addb260f0c3ed6759678ea7  candidates/candidate-C.png
```

---

## 5. Concerns / limits

- **No visual verdict was rendered by me.** This seat is text-source only: it cannot take
  a screenshot or an image payload, so legibility was established by pixel metrics
  (coverage, bbox, quadrant ink balance, contrast against a white and a `#1E1E1E`
  desktop) and by ASCII-ramp dumps of the real decoded frames. A final human/vision
  eyeball of `icon-16-zoom8x.png` and `candidates/` is still the right last step —
  route it to `build-vision`, never to this seat.
- **PNG round-trip alpha rounding.** `icon-256.png` differs from `candidates/candidate-A.png`
  in 1616 of 65536 pixels, max channel delta 5, only on semi-transparent anti-aliased edge
  pixels (max alpha among the differing pixels: 253). Cause: GDI+ decodes PNG through
  premultiplied alpha. Opaque pixels are identical; the difference cannot be seen. The DIB
  path is bit-exact (see the shared 32px hash).
- **`IconForge.exe` in `tools/`** is a build product kept for convenience. If it is ever
  treated as untrusted, re-run `build.ps1` — the source is the authority.
- **Not proven here:** how the icon looks in Windows Explorer/taskbar, how it reads next to
  the four Arc shell icon sets, and DPI-scaled rendering at 125/150/175%. These need the
  live desktop.
