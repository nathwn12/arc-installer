<p align="center">
  <img src="assets/icon.svg" width="120" height="120" alt="ArcInstaller icon" />
</p>

<h1 align="center">ArcInstaller</h1>
<p align="center"><strong>Install, repair, and revert the ARC icon theme on Windows 10 and 11.</strong></p>

## Install

Build the one-file installer, then install a theme variant with one command. No release is published, so the build runs from source and needs network access at fetch time:

```powershell
git clone https://github.com/nathwn12/arc-installer.git
cd arc-installer
pwsh -NoProfile -File .\fetch-theme.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

`fetch-theme.ps1` downloads the four upstream packs, verifies every archive against a pinned SHA-256, and derives Arc Dark Grey locally. `build.ps1` stages the payload and compiles `dist\ArcInstaller.exe`.

Install the theme in one command. The exe requires Administrator, so Windows asks once at launch:

```powershell
.\dist\ArcInstaller.exe --cli -Action install -Variant dark-grey -Yes
```

That single command checks the variant source, captures the pristine payloads if this is a fresh machine, merges the chosen variant, installs it, refreshes every logged-on profile's icon and thumbnail cache, and verifies the result. To change variant later, run the same command with another id from the table below; the switch re-merges, restores, and reinstalls in one action.

### Or use the window

Run `dist\ArcInstaller.exe`, pick a variant, and press Apply. The window shows the installed variant and timestamp, a preview of the variant's folder glyph, and a details log. Its action buttons are Apply, Repair, Revert, and Refresh.

### Uninstall

One command puts the stock Windows payloads back, refreshes every logged-on profile, and verifies the original state:

```powershell
.\dist\ArcInstaller.exe --cli -Action uninstall -Yes
```

Uninstall keeps `originals\` (the only pristine copy) and `logs\` so a reinstall stays safe. Add `-CleanState` to also remove `state.json`, `installed-manifest.json`, and `stage\`:

```powershell
.\dist\ArcInstaller.exe --cli -Action uninstall -CleanState -Yes
```

The exe is portable and keeps its working files under `%ProgramData%\ArcIcons`. After uninstall passes verification, remove that folder to delete the tooling, the pristine backup, and the logs:

```powershell
Remove-Item -Recurse -Force "$env:ProgramData\ArcIcons"
```

Keep the folder if you may want to re-apply without rebuilding; the pristine backup is what uninstall and revert restore.

## Variants

| `-Variant` | Name | Source |
| --- | --- | --- |
| `arc` | ARC | niivu's upstream ARC pack |
| `arc-symbolic` | ARC Symbolic | niivu's upstream symbolic pack |
| `neutral-brown` | Arc Neutral Brown | niivu's upstream pack |
| `neutral-grey` | Arc Neutral Grey | niivu's upstream pack |
| `dark-grey` | Arc Dark Grey | derived locally from Arc Neutral Grey |

`dark-grey` is the tool default and a complete variant: all three payloads are recolored, one factor per icon group, with a group luminance floor of 64. The derivation and measured hashes are in [docs/arc-dark-grey-variant.md](docs/arc-dark-grey-variant.md).

## Command line

`--cli` runs the installed controller instead of opening the window. Without `--cli` the exe launches the window.

| Option | Effect |
| --- | --- |
| `-Action` | `install`, `uninstall`, `apply`, `revert`, `repair`, `refresh`, `status`, `merge`, `task-on`, `task-off` |
| `-Variant` | Variant id or display name; default `dark-grey` |
| `-Yes` | Skip confirmations |
| `-DryRun` | Preview install, uninstall, apply, revert, or repair without writing |
| `-CleanState` | With `uninstall`: also remove state and stage files; keeps `originals\` and `logs\` |

| Action | What it does |
| --- | --- |
| `install` | Full install: source check, capture if fresh, merge and restore if switching, apply, per-user refresh, verify |
| `uninstall` | Full uninstall: restore the pristine originals, per-user refresh, verify original state |
| `apply` | Apply or re-apply the selected variant; a variant change chains merge, restore, apply |
| `revert` | Restore the pristine originals and verify |
| `repair` | Re-apply only when live matches the recorded original; never overwrites an unknown payload |
| `refresh` | Rebuild the shell icon cache for every logged-on profile |
| `status` | Show state, payload hashes, and verification result |
| `merge` | Rebuild the staged payload from the originals and the theme |
| `task-on` | Enable auto-repair at startup |
| `task-off` | Disable auto-repair at startup |

Examples:

```powershell
.\dist\ArcInstaller.exe --cli -Action status
.\dist\ArcInstaller.exe --cli -Action repair -DryRun
.\dist\ArcInstaller.exe --cli -Action install -Variant neutral-grey -Yes
```

A first install cannot be previewed: it must capture the pristine payloads and merge, so `-DryRun` reports that and changes nothing.

## Requirements

- Windows 10 or 11, x64.
- Administrator rights. The exe manifest requires elevation; the scripts ask for it when run directly.
- Windows PowerShell 5.1, built into Windows, runs the installed scripts.
- PowerShell 7 for the fetch step shown above.
- The .NET Framework 4 C# compiler that ships with Windows, for the build.
- No network access after the build; the theme shapes are embedded in the exe.

## Recovery

1. Uninstall first while the live payloads are still the ones this tool installed: `.\dist\ArcInstaller.exe --cli -Action uninstall -Yes`.
2. Check the result: `.\dist\ArcInstaller.exe --cli -Action status` prints PASS or FAIL with per-check detail.
3. If a Windows Update replaced the payloads, Repair deliberately writes nothing to the new files. The repair manual's re-merge procedure captures the new originals, rebuilds, and applies.
4. If uninstall and status still fail, use the OS backstop: `sfc /scannow`, then `DISM /Online /Cleanup-Image /RestoreHealth`.

The full ladder and the measured file-replacement mechanism are in [docs/REPAIR-MANUAL.md](docs/REPAIR-MANUAL.md).

## Troubleshooting

- Icons look unchanged after install. Install, uninstall, apply, revert, and refresh rebuild every logged-on profile's icon cache and thumbnail cache, then restart that profile's Explorer. A profile that is not signed in is not touched: sign that user in and run `-Action refresh`, or sign out and back in.
- Status is FAIL after apply. Read the FAIL lines, then revert. Every exit path restores and verifies the shell, so Explorer is not left stopped.
- `variant source ... is missing`. The chosen variant's payload is absent from the extracted theme tree; rebuild with `fetch-theme.ps1`, then run the new exe.
- `needs Administrator`. Accept the UAC prompt, or start from an elevated terminal.
- `sfc /scannow` flags a SystemResources file. That is expected after a resource edit; revert before running a repair install.
- Explorer is not running. The scripts restore it before exit; if it is still absent, start it with `Start-Process explorer`.

Install layout and file roles: [docs/WHERE-IT-LIVES.md](docs/WHERE-IT-LIVES.md).

## Development

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
.\dist\ArcInstaller.exe --selftest
powershell -NoProfile -File .\verify.ps1
powershell -NoProfile -File .\tests\Test-VariantParity.ps1
```

`--selftest` unpacks the embedded payload and checks every extracted file against the embedded manifest; exit 0 means the payload is intact. It needs an elevated shell. `verify.ps1` is a read-only host check and needs the tool root with its recorded originals. `Test-VariantParity.ps1` pins the three variant tables to the same five ids.

## Status

Experimental and still moving. It works today, but it is not a finished
product: interfaces may change, features may be improved or removed, and a
release can break the one before it. This is maintained by one person, not a
team. If it breaks, open an issue with the command you ran and what you saw.

## License

MIT. See [LICENSE](LICENSE).

## Links

- [Repair manual](docs/REPAIR-MANUAL.md)
- [Install map](docs/WHERE-IT-LIVES.md)
- [Arc Dark Grey derivation](docs/arc-dark-grey-variant.md)
- [MIT](LICENSE)

<!-- nathwn12 house footer: identical in every repo. Do not edit. -->
<p align="center">
  <a href="https://github.com/nathwn12"><img src="assets/signature.svg" width="96" alt="nathwn12" /></a>
</p>
<p align="center">
  <sub>Built by <a href="https://github.com/nathwn12">nathwn12</a> · <a href="https://github.com/nathwn12?tab=repositories">All projects</a></sub>
</p>
