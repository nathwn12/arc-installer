<p align="center">
  <img src="icon/ArcInstaller.ico" width="120" height="120" alt="ArcInstaller icon" />
</p>

# ArcInstaller

Get the ARC icon theme on your Windows desktop, and put the stock icons back whenever you want.

## Install

There is no released installer yet, so you build the app from source. You need Windows 10 or 11 (x64) with admin rights:

```powershell
git clone https://github.com/nathwn12/arc-installer.git
cd ArcInstaller
pwsh -File .\fetch-theme.ps1
powershell -File .\build.ps1
```

The fetch step downloads the icon packs from upstream and checks every archive against a pinned SHA-256. The build step compiles `dist\ArcInstaller.exe`. The app replaces three icon payloads in the Windows SystemResources folder with merged copies that keep every stock resource, and it backs up your originals before the first write so revert works.

## Usage

Run `dist\ArcInstaller.exe`, pick a variant in the dropdown, and press Apply. Repair re-applies the theme when a payload drifts, Revert puts your originals back, and Refresh clears the icon cache. The same actions work from a command line:

```powershell
.\dist\ArcInstaller.exe --cli -Action status
.\dist\ArcInstaller.exe --cli -Action apply -Variant dark-grey -Yes
.\dist\ArcInstaller.exe --cli -Action revert -Yes
```

Four variants ship in the one exe: ARC, Arc Neutral Brown, Arc Neutral Grey, and Arc Dark Grey. Switching variants re-merges, restores the originals, and applies in one step.

## What it does

- One window that applies, repairs, reverts, and refreshes the ARC icon theme.
- Four ARC variants in a single self-contained exe with nothing to install first.
- Merge, not swap: stock resources stay, only icon images change.
- Genuine revert: pristine originals are captured before the first write.
- Read-only checks: `--selftest` verifies the embedded payload, `verify.ps1` compares live files against recorded hashes.
- Optional auto-repair task that re-applies the theme when Windows replaces a payload.

## Commands

You run every action through the exe. The form is `--cli -Action <name>`:

| Action | Command | What it does |
| --- | --- | --- |
| `menu` | `.\dist\ArcInstaller.exe --cli -Action menu` | Opens the interactive menu |
| `apply` | `.\dist\ArcInstaller.exe --cli -Action apply` | Applies or re-applies the theme for the selected variant |
| `revert` | `.\dist\ArcInstaller.exe --cli -Action revert` | Puts the backed-up Windows originals back |
| `repair` | `.\dist\ArcInstaller.exe --cli -Action repair` | Re-applies only payloads that drifted, then refreshes the icon cache |
| `status` | `.\dist\ArcInstaller.exe --cli -Action status` | Shows install state and verifies the payloads |
| `refresh` | `.\dist\ArcInstaller.exe --cli -Action refresh` | Rebuilds the shell icon cache |
| `merge` | `.\dist\ArcInstaller.exe --cli -Action merge` | Rebuilds the merged files from originals plus theme before you re-apply |
| `task-on` | `.\dist\ArcInstaller.exe --cli -Action task-on` | Enables the auto-repair task at startup |
| `task-off` | `.\dist\ArcInstaller.exe --cli -Action task-off` | Disables the auto-repair task |

You pick a variant with `-Variant <id>`. The four ids are `arc`, `neutral-brown`, `neutral-grey`, and `dark-grey`:

```powershell
.\dist\ArcInstaller.exe --cli -Action apply -Variant neutral-brown -Yes
```

You add `-Yes` to skip confirmations. You add `-DryRun` to preview an apply or revert without writing. Repair has no preview mode, so you run it without `-DryRun`:

```powershell
.\dist\ArcInstaller.exe --cli -Action apply -Variant dark-grey -DryRun
```

## Requirements

- Windows 10 or 11, 64-bit, with administrator rights.
- .NET Framework 4.x (its C# compiler ships with Windows and builds the exe directly).
- PowerShell 7 for the fetch step; the build step runs under Windows PowerShell 5.1.
- Network access at build time: the icon packs download from upstream, SHA-256 verified, and are never redistributed here.

## Development

```powershell
powershell -File .\verify.ps1
```

Read-only: compares live SystemResources files against recorded hashes, exits 0 on PASS and 1 on FAIL. Repair manual: [docs/REPAIR-MANUAL.md](docs/REPAIR-MANUAL.md). Where it lives: [docs/WHERE-IT-LIVES.md](docs/WHERE-IT-LIVES.md). Upstream icon packs: https://github.com/niivu/resource-redirect-icon-themes.

## License

MIT. See [LICENSE](LICENSE).
