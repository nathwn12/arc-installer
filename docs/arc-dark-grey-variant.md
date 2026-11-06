# Arc Dark Grey — variant notes

**Read this before selecting `Arc Dark Grey`.** This is a complete variant, not a
proof of concept: all three payloads are recolored, with one effective factor
per icon GROUP.

## What this variant is

A darker grey built from `Arc Neutral Grey` by `bin\Recolor-IconTheme.ps1`, with
**k = 0.55** and a per-`RT_GROUP_ICON` **mean-luminance floor of 64**. Every icon
group of all three payloads gets one scalar, shared by every size in that group;
nothing is copied through at Neutral Grey brightness, except fully transparent
entries (which have nothing to darken).

| file | state | RT_ICON entries | sha256 | size (B) |
| --- | --- | --- | --- | --- |
| `Windhawk Resources\zipfldr.dll` | recolored | 10 (10 DIB) | `0F3D177FB765C9866DC2126D332849B87ABCA7C85180810B0083AA9F4F2251ED` | 577024 |
| `Windhawk Resources\imagesp1.dll` | recolored | 45 (45 DIB) | `82F3ACC48C6886B45A9F574A92DA944CCA32CE3242E409BDD1DF7144ED758BFD` | 2594816 |
| `Windhawk Resources\imageres.dll` | recolored | 1251 (1241 recolored: 1131 32bpp DIB, 2 24bpp DIB, 54 indexed DIB, 54 PNG; 10 fully transparent left byte-identical) | `85558A15AAFBDAEB6FF2881F680B9EB5426866E3072D4817B359AE636396F693` | 48726528 |
| `theme.ini` | byte-identical copy of `Arc Neutral Grey\theme.ini` | — | — | — |
| `Extra\preview.png` | generated from this payload by `bin\New-IconThemePreview.ps1` (32 groups at 48 px) | — | `8059D277438453407973176FD4B96BBA6FD6E33F396A848F781B7FEB67AAC358` | 27677 |

1306 RT_ICON entries total, 1296 recolored, 0 unsupported, 10 fully transparent
skipped (3 32bpp, 2 indexed, 5 PNG). 217 RT_GROUP_ICON groups, 0 members left
ungrouped.

## What the recolor does

- **RGB multiply, alpha untouched.** Every pixel is `round(channel * kEff)`.
  Alpha, the AND mask, palette indices, headers and every other byte keep their
  exact source value.
- **One kEff per group, shared by all sizes.** A glyph therefore cannot be dark
  at 16 px and light at 256 px (the earlier per-entry factor could do that).
- **Palette bitmaps (1/4/8bpp) are multiplied through the color table only**,
  which is the RGB source of those bitmaps; the indices stay as they are. That
  is the same operation as the pixel multiply, and it is why 16 px shell icons
  (which ship as indexed DIBs) darken with everything else.
- **PNG entries are decoded, multiplied and re-encoded** (System.Drawing/GDI+).
  A re-encode changes the entry's byte length, so the `RT_GROUP_ICON` directory
  entry that declares that length is updated in the same write session (52
  groups in `imageres.dll`). The destination is re-checked afterwards: all 1251
  directory entries declare the true RT_ICON length.
- **Fully transparent entries are skipped byte-for-byte.** No visible pixel
  means no darkening, and skipping the PNG re-encode avoids pointless churn.

## The luminance floor: one per group

A blanket k = 0.55 drives already-dark icons toward black, which is exactly what
this variant must not do. Measured on the Neutral Grey payload:

- the **Hard drive** family (icons #125-#129) sits at mean luminance 78-91, so
  k = 0.55 alone lands it at 43-50 — near black;
- the **Disc** family (#277-#281) sits at 99-118, landing at 54-65.

So each `RT_GROUP_ICON` gets its own effective factor:

```
kEff = min(1, max(K, Floor / groupMeanLuminance))
```

- the group mean is the **visible-pixel-weighted mean of its member sizes**, so
  one group has one factor;
- a group whose result would fall below the floor is multiplied *less*;
- a group already darker than the floor is left at `kEff = 1` (byte-identical);
- the factor stays a single scalar per group, so every channel is scaled by the
  same number and **hue and saturation ratios are preserved exactly — this
  variant never desaturates**;
- mean luminance is measured over **visible** pixels only (alpha >= 128 for
  32bpp/PNG, the AND mask for 24bpp and palette bitmaps), so a transparent
  background cannot drag the mean down.

64 = `#404040` at 25% luminance: unambiguously grey (a black pixel is 0),
comfortably above the ~48 that reads as black, and below the ~95 this variant
produces for the light grey family — so it only catches icons that were already
dark.

**How many groups the floor touched** (out of 217): 136 groups were clamped
(multiplied less than 0.55) and 8 were held at `kEff = 1` because they were
already at or below the floor (the red document family around #482-#489 and
#1050-#1063). 0 entries are outside any group.

## The neutral-axis guard (fail closed)

"Grey" must not mean "dyed". After the bytes are produced, every entry is
checked against its source means before anything is written:

- **neutral source entry** (its mean channel spread <= 6, i.e. grey): the output
  spread must stay <= 6. Any residual tint is a dyed grey, and the run is
  rejected.
- **chromatic source entry** (spread > 6, e.g. the blue network glyph): the hue
  is allowed to survive, but the recolor must stay **on the neutral axis** —
  every output channel mean must equal `sourceMean * kEff` within 1, and the
  output spread must equal `sourceSpread * kEff` within 2. A per-channel clamp
  would desaturate the glyph; a deviation outside those bounds is rejected.
- Any rejection writes **nothing** and fails with a `GUARD-REJECT` line per
  entry. The last measured run: 632 neutral entries and 609 chromatic entries
  passed, 0 rejected, 0 group conflicts.

A **per-pixel** floor was rejected on purpose: clamping each channel separately
lands all three channels on the same value, which *is* desaturation.

## Provenance

- Derived from `theme\Arc Neutral Grey\Windhawk Resources\` (zipfldr
  `73E8194ADD24BCE4D8B639B74946BB1C101066C1E87CC45F2A034B16BC13185C`, imagesp1
  `157C34B59516F3E1789CA7AA99C81AF5707CC87BF5E4F024E902CACF52A1A4FC`, imageres
  `AEF60C8D353511BFA751063FB7AF1612A00720529999A18A9FF1C46D362C3B58`) by
  `bin\Recolor-IconTheme.ps1`.
- The payloads were read back and checked independently: every recolored entry
  equals `round(sourceChannel * kEff)`, with alpha untouched, the group factor
  shared by every member, and the neutral-axis guard holding on the produced
  bytes.
- `zipfldr.dll` and `imagesp1.dll` came out byte-identical to the earlier
  per-entry run (`0F3D177F...`, `82F3ACC4...`): no group in either payload was
  turned by the floor, so the change only affects `imageres.dll`.
- There is no upstream archive for this payload (it is generated, not
  downloaded), so the variant table row carries an empty `Archive` field and
  `installed-manifest.json` records no archive for it.

## Regenerate

```powershell
foreach ($f in 'zipfldr.dll','imagesp1.dll','imageres.dll') {
  pwsh -NoProfile -File .\bin\Recolor-IconTheme.ps1 `
    -Source ".\theme\Arc Neutral Grey\Windhawk Resources\$f" `
    -Dest   ".\theme\Arc Dark Grey\Windhawk Resources\$f" `
    -K 0.55 -Floor 64
}
pwsh -NoProfile -File .\bin\New-IconThemePreview.ps1 `
  -Source ".\theme\Arc Dark Grey\Windhawk Resources" `
  -Dest   ".\theme\Arc Dark Grey\Extra\preview.png" `
  -Title 'Arc Dark Grey' -Note 'derived from Arc Neutral Grey - k=0.55, per-GROUP luminance floor 64'
```

Add `-DryRun` to plan without writing. `-K` is the RGB multiply factor
(0 < k <= 1): `1.0` is a byte-identical copy, lower is darker. `-Floor` is the
per-group mean-luminance floor in 0..255 (`0` disables it and restores a plain
blanket multiply). `fetch-theme.ps1` runs both steps after the upstream packs
land, so a fresh fetch reproduces this whole variant.

## Known gaps

- The tool fails loudly, writing nothing, if it meets an RT_ICON entry it has no
  recolor path for — it never skips an icon silently.
- Not this variant's payload, but found while checking it: a merged
  `imageres.dll.mun` can declare stale sizes for a small number of
  `RT_GROUP_ICON` directory entries (group `BLANK1`, groups #1040/#1043) after
  `bin\Merge-IconTheme.ps1`'s collision-remap step. The theme payloads themselves
  are 1251/1251 correct on the declared-size invariant.
