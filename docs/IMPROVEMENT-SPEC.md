# Improvement spec — hardening pass (2026-11-06)

## Upstream distill (niivu/resource-redirect-icon-themes, verified live 2026-11-06)

1. Icon theme packs for Windhawk's **Resource Redirect** mod: load-time
   redirection, no OS file is ever mutated.
2. Manual install = unzip a pack, paste the theme-folder path into the mod's
   settings box (per-variant `theme.ini` maps
   `%SystemRoot%\System32\{imageres,imagesp1,zipfldr}.dll` to
   `.\Windhawk Resources\*.dll`).
3. Cache clearing = `Scripts\Clear_icon_cache.bat`: `taskkill /f` explorer,
   delete `IconCache.db` + `iconcache_*.db` + `thumbcache_*.db`,
   `start explorer.exe` — no verification the shell returns.
4. ARC, Arc Neutral Brown, Arc Neutral Grey ship as pinned zips
   (`ARC.zip`, `arc-neutral brown/grey.zip`); this repo pins 3 SHA-256 in
   `fetch-theme.ps1` and fails closed on re-zip.
5. This repo diverges on purpose: it **merges** theme DLL resources into the
   stock `.mun` payloads via the Win32 update API
   (`takeown`/unlink/copy/SDDL-restore into `C:\Windows\SystemResources`),
   and derives Arc Dark Grey locally (`k=0.55`, floor 64) — neither exists
   upstream.

## Lens findings (8)

- F1 `ARC-Icons.ps1` header called dark-grey a partial PoC (only zipfldr
  recolored); all three payloads are recolored per
  `docs\arc-dark-grey-variant.md`.
- F2 Variant table triple-duplicated (`ARC-Icons.ps1`, `Merge-IconTheme.ps1`,
  `Get-ArcIconsVariantInfo`) with no parity check.
- F3 `--selftest` proved extraction only (sample hashes printed, none
  compared) — a corrupt payload passed.
- F4 Fetch pins lived only in `fetch-theme.ps1`; no `theme\source.json`.
- F5 `sourceOrigin.archive` rarely flowed: merge looked only for
  `theme\<Archive>.zip`, which fetch never lands there and build never ships.
- F6 `build.ps1` staged by location with no empty-stage refusal and no staged
  file list; drift invisible.
- F7 `repair.ps1` had no `-DryRun` while apply/restore do.
- F8 Undocumented: why upstream `Clear_icon_cache.bat` differs from the
  measured `iconcache*.db` + verified-restart path; empty Unreleased section.

## Ranked fixes (all applied)

1. F1 header corrected (comment only). 2. `tests\Test-VariantParity.ps1`
   asserts all three tables = `@(arc, neutral-brown, neutral-grey,
   dark-grey)` + `ThemeDir` mapping. 3. `build.ps1` writes
   `staging\files\payload-manifest.json` (rel path + sha256, 41 files);
   `DoSelfTest` fails unless every extracted hash matches and counts agree.
   4. `fetch-theme.ps1` writes `theme\source.json`
   (`repo`, `urls`, `sha256`, `fetchedAt`); merge falls back to that pin for
   `archive`/`repo` when the zip file is absent (never invented).
   5. Build throws on empty stage; logs root/bin staged lists.
   6. `repair.ps1 -DryRun`: classification-only
   (`healthy`/`original`/`drift` per file), no lock, no writes;
   `ARC-Icons.ps1` passes it through. 7. REPAIR-MANUAL subsection on the
   cache-clear difference. 8. CHANGELOG Unreleased lists all of the above.

## Verification log (this pass)

- `build.ps1`: staged 41, `payload.zip` 10191830 B,
  `dist\ArcInstaller.exe` 10269184 B
  sha256 `1BD3B138BE95FC5CE3CAE4BE22EA9AB0EBF5324C3C32C7800F82A257671727F8`.
- `--selftest` (via `Start-Process -Wait`): `entries: 42`,
  `manifest: 41/41 files verified`, exit `0`.
- `Test-VariantParity.ps1`: `VARIANT-PARITY: PASS (4 ids + ThemeDir)`.
- `Test-DefaultIconVariant.ps1`: `DEFAULT-ICON-VARIANT: PASS`.
- `repair.ps1 -DryRun` sandbox (`%TEMP%` root+sys, never live): no-state
  path prints preview with 0 writes; synthetic installed state prints
  `original`/`healthy`/`drift` per file, state.json untouched, no `logs\`.
- Parse-checked all 6 edited/added PS files via AST (0 errors).
- NOT run: live apply/restore, merge, or any write under
  `C:\Windows\SystemResources`.

## Superseded (2026-11-06 variant pass)

- Fifth variant **ARC Symbolic** (`arc-symbolic`) pinned and wired through both
  tables, the GUI, provenance and `tests\Test-VariantParity.ps1` (now 5 ids).
- `bin\Recolor-IconTheme.ps1` now derives one kEff per `RT_GROUP_ICON` and
  enforces the neutral-axis guard; Arc Dark Grey was regenerated and now ships
  `Extra\preview.png`.
- Authoritative numbers now live in `docs\arc-dark-grey-variant.md`; the
  per-entry counts in the verification log above describe the superseded run.
