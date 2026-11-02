<p align="center">
  <img src="icon/ArcInstaller.ico" width="120" height="120" alt="ArcInstaller icon" />
</p>

# ArcInstaller

Applies the ARC icon theme to Windows, and restores the stock icons on revert. Built for admins on 64-bit Windows 10 or 11.

## Install

No released installer yet; build from source. Needs Windows 10 or 11 (x64) with admin rights, PowerShell 7 for the fetch step, and network access at build time:

```powershell
git clone https://github.com/nathwn12/arc-installer.git
cd arc-installer
pwsh -File .\fetch-theme.ps1
powershell -File .\build.ps1
```

The fetch step downloads the icon packs from upstream, each verified against a pinned SHA-256. The build step compiles `dist\ArcInstaller.exe`.

## Usage

Run `dist\ArcInstaller.exe`, pick a variant, and press Apply. The same actions work from a command line:

```powershell
.\dist\ArcInstaller.exe --cli -Action status
.\dist\ArcInstaller.exe --cli -Action apply -Variant dark-grey -Yes
```

`status` reports the install state. `apply` merges the variant and refreshes the icon cache; `revert` puts the backed-up originals back.

## Configuration

| Key | Default | Effect |
| --- | --- | --- |
| `-Variant` | `dark-grey` | `arc`, `neutral-brown`, `neutral-grey`, or `dark-grey` |
| `-Yes` | off | Skip confirmations |
| `-DryRun` | off | Preview an apply or revert without writing |

Recovery ladder and install map: [docs/REPAIR-MANUAL.md](docs/REPAIR-MANUAL.md), [docs/WHERE-IT-LIVES.md](docs/WHERE-IT-LIVES.md).

## Development

```powershell
powershell -File .\verify.ps1
```

Read-only host check: compares live SystemResources files against recorded hashes, exits 0 on PASS and 1 on FAIL.

## License

MIT — see [LICENSE](LICENSE).
