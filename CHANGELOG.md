# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.2] — 2026-11-09

### Added

- **README screenshots.** The shipped window, the five-variant picker, and the
  details log are captured from `dist\ArcInstaller.exe` and shown at the top of
  the README.
- **README known limitations.** The user-facing README now names the audited
  failure modes it used to hide: the Windows 10 `imagesp1.dll.mun` dependency,
  English-only (1033) theme resources on non-English Windows, interrupted-apply
  recovery and the `apply.journal.jsonl` record, the Windows Update refusal and
  the revert/uninstall rollback trap, uninstall traces (new files instead of the
  original hardlinks, `D:PAI`, the leftover scheduled task), the multi-user
  refresh proof scope, and the absence of an ARM64 build.
- **Repair-manual recovery subsections** for an interrupted apply, a Windows
  Update rebase, a refused stale stage, and a refused uninstall, each with the
  exact advanced command.

### Changed

- **One primary action, three verbs.** The window now exposes `Install theme`
  (primary, installs the selected variant), `Check status` (read-only), and
  `More ▾` (`Remove theme…`, `Repair…`, `Open logs folder`), with `Details ▸`
  for the log strip. The console menu is `1 Install theme`, `2 Remove theme`,
  `3 Check status`, `4 Choose theme variant`, `q Quit`. The destructive verbs no
  longer compete with install for the same click.
- **Variant switch confirms once and refuses an unknown live payload.** Merge,
  restore and apply run only after the single prompt; declining leaves the
  previous theme installed and nothing is mutated. Before that prompt every live
  payload is classified, and an unknown one refuses the switch instead of being
  clobbered.
- **Icon:** one grey 2x2 swatch mark across the SVG, ICO and PNG renders.

### Fixed

- **Failures are always visible.** A failed action now turns the status line
  red, shows the first error in a red bar, and opens the details strip
  automatically. A non-zero child exit is never reported as `OK`, and a script
  that prints `FAIL` or `FAILED` is treated as failed even when it exits 0.

### Security

- **Payload manifest verified before every launch, with a decompression cap.**
  Before the first byte is written, the single launch gate checks that every
  archive path stays under the install root, that the declared uncompressed
  total fits the 704 MiB cap (measured payload: 172,568,413 bytes), that
  `payload-manifest.json` exists and parses, and that every archive entry and
  every manifest row agree by SHA-256; extraction then verifies the bytes it
  writes. `--selftest` runs the same gate and adds the extra-file check.
- **Stale stage is detected and rebuilt, never applied.** `install` re-hashes the
  theme on disk against `sourceOrigin` in `installed-manifest.json`; a
  disagreement, or a manifest that cannot prove its stage, makes the stage stale,
  so `install` re-merges (merge -> restore -> apply -> verify) instead of
  trusting it. `apply` refuses with a named stale-stage reason
  (`staged hash ... != manifest merged ...`) and names the rebuild path, and a
  `-Pair` merge refuses an untouched row whose stage no longer matches.
- **Unknown live payload is refused.** `install` classifies every live file
  before mutating anything and refuses one that matches neither the recorded
  original nor the recorded merge; `repair` reports `drift-unknown-payload` and
  writes nothing.

## [0.2.0] — 2026-11-07

### Added

- **ARC Symbolic** (niivu's official symbolic pack) as a fifth variant:
  `arc-symbolic` / `theme\ARC Symbolic\Windhawk Resources`, pinned in
  `fetch-theme.ps1` (`ARC Symbolic.zip`, SHA-256 `78C09817...`) and carried by
  all three variant tables, the GUI dropdown, `apply.ps1`'s allowlist message,
  the originals provenance and `tests\Test-VariantParity.ps1` (now five ids).
- **One-command install and uninstall** on `ARC-Icons.ps1`:
  `-Action install` checks the variant source, captures the pristine payloads on
  a fresh machine, merges and restores when switching variants, applies with the
  cache refresh deferred, refreshes every logged-on profile, and verifies PASS.
  `-Action uninstall` restores the pristine originals, refreshes every profile,
  and verifies `mode=original`; `-CleanState` additionally removes `state.json`,
  `installed-manifest.json` and `stage\`, while `originals\` and `logs\` are
  always kept.
- `-Root` / `-SystemResourceDir` on `ARC-Icons.ps1` for sandbox runs: both are
  required together, and a sandbox run never touches the live directory.
- Per-user icon-cache refresh: `bin\ArcIcons-UserRefresh.ps1` enumerates
  logged-on interactive sessions, refreshes the caller in process, and runs
  `bin\Refresh-UserIconCache.ps1` for every other profile through a one-shot
  InteractiveToken scheduled task. Each worker stops only its own session's
  Explorer, drops `iconcache*.db`, `thumbcache*.db` and the legacy
  `IconCache.db`, runs `ie4uinit -show`, restarts Explorer, and proves an
  Explorer pid is back in that session before writing `ok=true`.
- `bin\New-IconThemePreview.ps1`: renders a preview sheet from a payload's own
  `RT_GROUP_ICON` entries; `fetch-theme.ps1` uses it to give the derived
  `Arc Dark Grey` a real `Extra\preview.png`.
- `tests\Test-VariantParity.ps1`: pins the triple-duplicated variant table
  (`ARC-Icons.ps1` `$Variants`, `Merge-IconTheme.ps1` `$VariantTable`,
  `Get-ArcIconsVariantInfo`) to the same five ids + `ThemeDir` mapping, and
  checks each fetched variant has its three payload files.
- `payload-manifest.json` (rel path + sha256 per staged file) embedded by
  `build.ps1`; `--selftest` verifies every extracted hash, requires the entry
  and file counts to agree, and fails on any extra file.
- `theme\source.json` fetch provenance (`repo`, `urls`, `sha256`, `fetchedAt`);
  `Merge-IconTheme.ps1` records the archive hash from that pin when the landed
  archive file is absent (never invented).
- `repair.ps1 -DryRun`: classification-only preview (`healthy` / `original` /
  `drift` per file), no lock, no writes; `ARC-Icons.ps1 -Action repair -DryRun`
  passes it through.
- `docs\IMPROVEMENT-SPEC.md`: upstream distill, lens findings, ranked fixes,
  verification log.
- `docs\REPAIR-MANUAL.md`: why upstream `Clear_icon_cache.bat` differs from
  the measured `iconcache*.db` + verified-restart path.

### Changed

- `bin\Recolor-IconTheme.ps1` derives **one kEff per `RT_GROUP_ICON`** from
  the visible-pixel-weighted mean of all its sizes, so a glyph cannot be dark
  at one size and light at another. Indexed icons still recolor the palette
  only.
- The derived variant is **pristine per group**: neutral groups must stay
  neutral (spread <= 6); chromatic groups may keep hue only along the neutral
  axis (`channel mean = source * kEff` within 1, spread within 2); any
  violation writes nothing (fail closed). Fully transparent `RT_ICON` entries
  are skipped byte-for-byte instead of being multiplied.
- `theme\Arc Dark Grey` regenerated under the group rule (`imageres.dll`
  `85558A15...`, 48726528 B; `imagesp1.dll` and `zipfldr.dll` unchanged);
  `docs\arc-dark-grey-variant.md` / `NOTES.md` rewritten with the measured
  group counts (217 groups, 136 clamped, 8 held, 632 neutral / 609 chromatic
  guarded, 0 rejected).
- `ARC-Icons.ps1` menu and status text cover the fifth variant and the
  per-user refresh result; the menu now leads with Install and Uninstall and
  renumbers the maintenance actions.

### Fixed

- **Collision-remap merge fix.** A theme icon whose ordinal is referenced by an
  untouched stock group with a different declared byte length used to leave
  that group pointing at a stale size, so the icon renderer sliced the wrong
  bytes (measured on `imageres`: 7 stock groups / 27 directory entries). The
  merge now moves that icon to a fresh ordinal and every theme group that names
  it follows. The `Get-GrpIconIds` (`uint16`) / `NameInt` (`int`) key mismatch
  that silently disabled the remap is fixed by casting both sides to `int`.
- **Per-user refresh no longer clears the wrong profile.** The old refresh read
  the caller's `%LOCALAPPDATA%` and stopped every `explorer.exe` on the machine;
  run elevated by a different admin, it refreshed the wrong cache and left the
  owning user with the old icons. It now refreshes each logged-on profile inside
  its own session and never touches a profile that is not signed in.
- `ARC-Icons.ps1` header: dark-grey is a complete variant (all three payloads
  recolored), not a partial PoC.
- `build.ps1` throws on an empty stage instead of shipping an empty payload,
  and logs the staged root/bin file lists.
- `ArcInstaller.cs` no longer hardcodes the dark-grey dropdown index; it looks
  the id up, so inserting a variant cannot preselect the wrong theme.

## [0.1.0] — 2026-10-14

### Added

- Initial release: a self-contained Windows installer for the ARC icon theme, carrying four
  variants (ARC, Arc Neutral Brown, Arc Neutral Grey and a locally derived Arc Dark Grey).
- Merge-based apply: every stock resource is preserved and only icon images are replaced.
- Repair, refresh and revert, with the pristine payloads captured before the first write.
- A single-window UI: variant dropdown preselecting what is installed, a themed folder-glyph
  preview, and a details log that stays collapsed until it is needed.
