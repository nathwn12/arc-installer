# AGENTS.md

ArcInstaller puts the ARC icon theme on Windows 10/11 x64 by replacing three merged payloads in `C:\Windows\SystemResources`, and puts the stock payloads back on revert. One self-contained WinForms exe (`src\ArcInstaller.cs`) wrapping a PowerShell payload. No package manager, project file, test suite or CI.

## Build

- Order is fetch, then build. A clone has no `theme\` (gitignored), so `build.ps1` stops with `missing <root>\theme - run fetch-theme.ps1 first`.
- `pwsh -File .\fetch-theme.ps1` downloads four pinned upstream archives (ARC, ARC Symbolic, Arc Neutral Brown, Arc Neutral Grey) into `staging\theme-cache`, verifies each SHA-256, extracts `theme\`, then derives `theme\Arc Dark Grey` and its preview with `bin\Recolor-IconTheme.ps1` / `bin\New-IconThemePreview.ps1`. It needs network; `-Force` re-downloads. A hash mismatch is deliberate protection: re-pin only with a reason, never skip the check.
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1` is the verified build path (Windows PowerShell 5.1). The script header records that PowerShell 7 mangles the `csc` `/resource:` quoting. Output is `dist\ArcInstaller.exe`.
- `theme\`, `staging\` and `dist\` are gitignored, but untracked does not mean disposable: `theme\` costs a network fetch to rebuild, and `staging\theme-cache` is the verified download cache.
- Packaging is by location, not by a list: every root `*.ps1`/`*.cmd` except `fetch-theme.ps1` and `build.ps1`, every `bin\*.ps1`, `theme\` minus `.zip`, plus `docs\REPAIR-MANUAL.md` renamed to payload `README.md` and `docs\WHERE-IT-LIVES.md`. A new root or `bin` script ships silently; root `README.md` is not shipped, so edit `docs\REPAIR-MANUAL.md` to change what an installed copy documents.
- Icon artwork only: `powershell -File .\icon\build.ps1` recompiles `icon\src\IconForge.cs` and rewrites the tracked `icon\*.ico` and `icon\*.png` files.

## Checks

- `.\dist\ArcInstaller.exe --selftest` extracts the embedded payload to `%TEMP%\arcinstaller-selftest-<pid>` and exits 0 only when the archive yields the expected entry count, the three sample files are present, and every extracted file matches the embedded `payload-manifest.json` SHA-256. It prints the entry count and the manifest verification result; a mismatch is a nonzero exit. The manifest in `src\app.manifest` is `requireAdministrator`, so run it from an elevated shell.
- From PowerShell 7, `&` returns before this GUI-subsystem exe finishes and `$LASTEXITCODE` stays empty. Use `Start-Process -Wait -PassThru` and read `.ExitCode` (verified `0`).
- `pwsh -File .\verify.ps1` checks the host, not the repo: it reads `%ProgramData%\ArcIcons` manifests and compares hashes, owner/DACL and resource invariants against the live `C:\Windows\SystemResources` files. A FAIL reports the installed host's state (drifted payload, missing or partial manifests), not the source tree; `[hash] MISMATCH` on `mode=installed` means the live payload no longer matches the recorded merge (Windows Update or a manual change).
- `powershell -NoProfile -File tests\Test-ActionParity.ps1` pins the action set across the `ARC-Icons.ps1` ValidateSet + entry switch, the WinForms buttons in `src\ArcInstaller.cs`, the menu and both shipped docs; it also asserts the refresh delegates to the multi-user engine and the worker drops both cache families.
- `powershell -NoProfile -File tests\Test-UserRefreshTransport.ps1` (elevated) registers the same one-shot InteractiveToken task the installer uses, runs `bin\Refresh-UserIconCache.ps1` in `-DryRun` for one logged-on profile, and asserts the receipt came from that SID/session/profile with the explorer pid set unchanged. It proves the cross-session transport without restarting any shell.
- Merge check without touching OS files (verified, needs an installed host for `originals\`): copy `%ProgramData%\ArcIcons\originals` and `theme\<variant>` into a temp root, then run `pwsh -File .\bin\Merge-IconTheme.ps1 -Root <tmp> -Build -Variant dark-grey`. It writes `stage\` and `installed-manifest.json` under `<tmp>` and prints `ARC-MERGE: PASS`.
- There is no CI config in the repo; the gate is the build, `--selftest`, `verify.ps1`, the merge check, and the `tests\` parity/transport scripts (`Test-VariantParity.ps1`, `Test-DefaultIconVariant.ps1`, `Test-ActionParity.ps1`, `Test-UserRefreshTransport.ps1`).

## Live-install safety

- `apply.ps1` is the one file-mutating install command; `restore.ps1` reverts; `repair.ps1` re-applies only when live matches the recorded original. `ARC-Icons.ps1 -Action install` / `-Action uninstall` are the one-action wrappers (payload + per-user refresh + verify PASS). `bin\Live-Install.ps1` and `bin\Finalize-Security.ps1` are superseded reference: never run them.
- The three live commands mutate `C:\Windows\SystemResources\*.mun`: take ownership, delete the hardlink (never write through it), copy, restore the full SDDL on the file and its WinSxS sibling, then refresh the icon cache for every logged-on profile (per-user `iconcache*.db` + `thumbcache*.db` drop, verified explorer restart in each session) and restart `explorer`. Treat a live run as host-mutating acceptance, never as a test; recover with `restore.ps1` or `-Action uninstall`.
- `apply.ps1`, `restore.ps1` and `repair.ps1` do not self-elevate; start from an elevated shell. `ARC-Icons.ps1` does self-elevate and is the entry point the exe drives.
- `%ProgramData%\ArcIcons\originals` is the only pristine copy; never edit or delete it. `-Force` cannot bypass preflight. Never force a stale merge over a payload replaced by Windows Update: re-merge instead (see `docs\REPAIR-MANUAL.md`).
- A non-default `-Root` requires an explicit `-SystemResourceDir`; that pair is the only supported sandbox form.

## Architecture

- The exe embeds `staging\payload.zip` and on each launch except `--selftest` extracts it to `%ProgramData%\ArcIcons`, rewriting only files whose hash differs; `--cli` then runs the installed `ARC-Icons.ps1` under Windows PowerShell 5.1 with `PSModulePath` narrowed. The exe never runs the repo copy, so script edits need a rebuild, and launching a built exe can overwrite files in the installed tree.
- Shipped PowerShell must stay 5.1 compatible (no `??`, no ternary): the exe and the CLI path use `powershell.exe`. `bin\Set-BaselineSecurity.ps1` states the rule and is dot-sourced by apply, restore, repair and verify.
- `src\ArcInstaller.cs` is the whole app: `Program.Main`, payload extraction, `--selftest`, the CLI shim and `MainForm`. It is the only `.cs` file under `src\`.
- `ARC-Icons.ps1` is the action controller. `bin\Set-BaselineSecurity.ps1` owns the three-name allowlist (`imageres.dll.mun`, `imagesp1.dll.mun`, `zipfldr.dll.mun`), privilege enabling, SDDL restore, the lock and the shell guard. It dot-sources `bin\ArcIcons-UserRefresh.ps1` last: that file owns logged-on profile enumeration (WTS + ProfileList), the in-process refresh for the caller and the one-shot InteractiveToken scheduled task used for every other profile; `bin\Refresh-UserIconCache.ps1` is the worker that runs inside the target session.
- The variant table is duplicated three times: `ARC-Icons.ps1` (`$Variants`), `bin\Merge-IconTheme.ps1` (`$VariantTable`) and `bin\Set-BaselineSecurity.ps1` (`Get-ArcIconsVariantInfo`); change all three. Theme sources are `theme\Windhawk Resources\` (arc), `theme\ARC Symbolic\Windhawk Resources\`, `theme\Arc Neutral Brown\Windhawk Resources\`, `theme\Arc Neutral Grey\Windhawk Resources\` and `theme\Arc Dark Grey\Windhawk Resources\`.
- `theme\Arc Dark Grey` is a complete variant: `bin\Recolor-IconTheme.ps1` derives one kEff per `RT_GROUP_ICON` (k = 0.55, group luminance floor 64) and refuses to write when the neutral-axis guard would ship a tinted grey. `docs\arc-dark-grey-variant.md` is authoritative and carries the measured hashes, sizes and group counts.

## Docs

- `README.md` is user-facing and ends in the house footer; leave the footer alone.
- `docs\REPAIR-MANUAL.md` is the measured mechanism and recovery ladder; `docs\WHERE-IT-LIVES.md` maps the install root; `docs\arc-dark-grey-variant.md` is the recolor proof.
