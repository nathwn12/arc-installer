<!-- ArcIcons repair manual -->

# ArcIcons — repair manual

Icon-theme installer for `C:\Windows\SystemResources`: replaces three
resource payloads with **merged** copies (stock resources + ARC theme icons),
and can undo it. Root: `%ProgramData%\ArcIcons`.

`apply.ps1` is the one file-mutating install command; there is no separate
finalizer step (the finalize logic lives inside apply/restore).
`ARC-Icons.ps1 -Action install` / `-Action uninstall` / `-Action status` are the
three normal verbs: install, remove, and a read-only check. Every other action
(`apply`, `revert`, `repair`, `refresh`, `merge`, `task-on`, `task-off`) is an
advanced recovery or diagnostic verb, documented under Commands.
`bin\Live-Install.ps1` and `bin\Finalize-Security.ps1` are kept as measured
reference only and are superseded; do not run them alongside `apply.ps1`.

## The measured mechanism and why each step exists

Every step below was measured live, not assumed:

- **Directory ACL first.** Administrators hold only read+execute on
  `C:\Windows\SystemResources`, so creating or deleting a NAME in that
  directory is denied — and `SeRestorePrivilege` does NOT bypass the directory
  ACL for creating a name (measured: denied). So before the first file:
  `takeown /f C:\Windows\SystemResources` +
  `icacls C:\Windows\SystemResources /grant *S-1-5-32-544:F`.
  The directory baseline SDDL is saved at
  `originals\acl\SystemResources.dir.sddl` and MUST be restored in a `finally`
  (owner + full DACL via the in-process native write), even on failure.
- **Per-file delete right.** Administrators hold read+execute on the files too,
  so each file gets `takeown /f <file>` +
  `icacls <file> /grant *S-1-5-32-544:F` before its delete. Replacement is
  delete + copy (never a write through the hardlink).
- **In-process privileges.** Owner/group writes need `SeRestorePrivilege` /
  `SeBackupPrivilege` / `SeTakeOwnershipPrivilege` enabled IN THIS PROCESS via
  `AdjustTokenPrivileges` (`Enable-ArcIconsPrivileges` in
  `bin\Set-BaselineSecurity.ps1`) before calling the native
  `NtSetSecurityObject` whole-descriptor write (`Set-ArcIconsBaselineSecurity`).
  A child process such as `icacls /setowner` fails without that, and .NET
  `Set-Acl` leaves a stray `AI` flag behind — the native write reproduces the
  per-file baseline SDDL byte-identically (verified `exact=True`).
- **Sibling SD restore.** `takeown` touches the SHARED inode, so the surviving
  WinSxS sibling's owner+DACL must be restored too. Its path is captured with
  `fsutil hardlink list <live>` BEFORE the delete — after the copy the new
  file has no hardlink, so capturing later finds nothing.
- **Holder handling.** A live file mapped by a running process cannot be
  deleted (share lock, not ACL). Holders are found with the Restart Manager
  API (`Get-ArcIconsHolders`; `imageres.dll.mun` is typically held by
  `explorer` and a `RuntimeBroker`). Without `-CloseHolders` the run fails
  naming the holders; with `-CloseHolders` they are stopped immediately before
  replacing that file.
- **The `D:PAI` note.** A plain whole-descriptor write reproduces each
  per-file baseline (`D:P`) exactly. The DIRECTORY baseline is `D:PAI` and the
  `AI` (auto-inherited) bit cannot be reproduced by the write — the restore
  step journals `exact=false` with `aceMatch=true` and the before/after SDDL
  strings instead of hiding that one access-neutral control-bit difference.
- **Icon-cache refresh — per user, not per caller.** After installing,
  `ie4uinit.exe -show` alone is NOT enough — delete
  `%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache*.db` **and**
  `thumbcache*.db`, then restart that profile's explorer, or the shell keeps
  painting the old icons. Measured 2026-11-06: an elevated installer that read
  only the CALLER's `%LOCALAPPDATA%` (and headless SYSTEM runs, whose
  `%LOCALAPPDATA%` belongs to nobody) cleared the wrong profile; the owning
  non-elevated user still saw light folders until they cleared iconcache
  **and** thumbcache by hand. The refresh is therefore multi-user:
  `bin\ArcIcons-UserRefresh.ps1` enumerates logged-on interactive sessions
  (WTS) and maps each account to its SID/profile (`HKLM\...\ProfileList`),
  refreshes the caller in-process, and for every OTHER profile registers a
  one-shot scheduled task with an **InteractiveToken** principal (no password,
  no TCB; works for local and domain accounts), starts it, waits for the
  worker's receipt, then deletes that task. The worker
  (`bin\Refresh-UserIconCache.ps1`) refuses a SID that is not its own token,
  stops only its own session's explorer, drops both caches, runs
  `ie4uinit -show`, restarts explorer and proves an explorer pid is back in
  that same session. `apply.ps1` and `restore.ps1` do this automatically on
  live runs (`-SkipIconCacheRefresh` opts out; sandbox runs never touch a
  shell).

### Why not upstream's Clear_icon_cache.bat

Upstream `resource-redirect-icon-themes` ships `Scripts\Clear_icon_cache.bat`
(verified 2026-11-06 against the live repo): `taskkill /f /im explorer.exe`,
delete `%LocalAppData%\IconCache.db` + `Explorer\iconcache_*.db` +
`Explorer\thumbcache_*.db`, `start explorer.exe`. This repo now drops the same
two cache families for every logged-on profile, but differs in three measured
ways: it runs the drop **inside each user's own session** (a session-0 or
cross-user caller cannot restart a desktop it does not own), it treats the
restart as a guarded unit per session (the worker only reports ok when an
explorer pid is back in that session), and it runs `ie4uinit.exe -show`
in-process. The old note that `thumbcache` was "upstream's thumbnail concern"
was wrong: the live symptom was stale folder thumbnails surviving an
`iconcache`-only clear, which is exactly why the owner had to clear both by
hand.

## What was changed and why

- **Merge, not swap.** A whole-file swap of a theme DLL would drop stock-only
  resource IDs. The stage files keep every stock resource and only replace the
  icon images with the ARC versions, so nothing the OS expects goes missing.
- **`.mun` is resolved by module basename.** `imageres.dll.mun` serves
  `%SystemRoot%\System32\imageres.dll`, etc. That is why the theme sources are
  `theme\Windhawk Resources\imageres.dll`, `imagesp1.dll`, `zipfldr.dll` and
  the targets are `C:\Windows\SystemResources\{imageres,imagesp1,zipfldr}.dll.mun`.
- **Targets are hardlinks into WinSxS.** `C:\Windows\SystemResources\*.mun`
  link to component-store payloads
  (`\Windows\WinSxS\amd64_microsoft-windows-imageres_…\imageres.dll.mun`).
  Writing through the link would mutate the pristine component-store copy, so
  the tools **never** do that. Replacement = resolve the surviving WinSxS
  sibling with `fsutil hardlink list` BEFORE touching anything (taking
  ownership changes the security descriptor of the SHARED inode, so the
  sibling is affected too) → `takeown /f` +
  `icacls /grant *S-1-5-32-544:F` → **delete** the SystemResources path
  (unlinks; the WinSxS copy survives untouched) → copy the new file into
  place → restore the COMPLETE baseline security descriptor (owner + group +
  DACL + protection flag, verified by full SDDL string compare) on BOTH the
  new file AND the surviving sibling. Owner writes use explicitly enabled
  `SeRestorePrivilege` / `SeTakeOwnershipPrivilege` (AdjustTokenPrivileges in
  `bin\Set-BaselineSecurity.ps1`, shared by apply and restore), so they are
  deterministic. The native whole-descriptor write reproduces the baseline
  SDDL byte-identically (a .NET `Set-Acl` leaves a stray `AI` flag behind).
- **Ownership/DACL.** Baseline owner/group is `NT SERVICE\TrustedInstaller`
  and the baseline DACL is protected (`D:P`) granting Administrators
  READ+EXECUTE only, so every write needs takeown first and every
  install/restore must put the full descriptor back exactly on both paths.
  Baselines (hashes, SDDL, sizes) live in `originals\manifest.json` — read it,
  never modify it, and never modify `originals\` or `theme\`.
- **Truth files.** `installed-manifest.json` (from the merge worker) records
  per file `{name, stagePath, originalSha256, mergedSha256, mergedSize}`, plus
  `sourceOrigin` — the built variant's provenance (source dir + a sha256 of each
  theme input, the landed variant archive's name + sha256 — `theme\ARC.zip` or
  `theme\arc-neutral-*.zip` — when present, and repo/commit only when the
  payload ships its own `source.json`).
  `state.json` records `{mode: installed|original|partial|drifted, ...}` with
  per-file progress; `mode=partial` means the last run did not complete.
- **Journal + rollback.** Every mutation is preceded by a per-file journal
  line in `logs\apply.journal.jsonl` / `logs\restore.journal.jsonl`. A
  mid-sequence failure automatically rolls the already-mutated files back to
  the pristine originals (re-copy + full SD restore on both paths), records
  `mode=partial`, and fails loudly — never a silent partial success.
- **Lock.** `apply.ps1`, `restore.ps1` and `repair.ps1` serialize behind the
  atomic `logs\ArcIcons.lock` file (released in a `finally`), so repair can
  never act while a restore is mid-run.
- **Path confinement.** Every path is canonicalized with
  `[IO.Path]::GetFullPath`; destinations outside the validated
  SystemResources directory are refused; manifest names must be bare
  allowlisted basenames (`imageres.dll.mun`, `imagesp1.dll.mun`,
  `zipfldr.dll.mun`) — a traversal entry such as `..\System32\kernel32.dll`
  is refused in preflight before any change. There is no cross-root fallback:
  paths resolve under `-Root` only, and any non-default `-Root` run requires
  an explicit `-SystemResourceDir`.

## Commands

Normal use is three verbs. Run elevated. Live defaults:
`-Root %ProgramData%\ArcIcons`,
`-SystemResourceDir C:\Windows\SystemResources`.

```powershell
# install: capture-if-fresh -> merge the chosen variant -> restore-if-switching
# -> apply -> refresh EVERY logged-on profile -> verify PASS
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action install -Variant dark-grey -Yes
# remove: pristine originals -> refresh every profile -> verify PASS (mode=original)
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action uninstall -Yes
# check status: read-only; prints PASS or FAIL (needs state.json) and exits non-zero on FAIL
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action status
```

`-Action uninstall -CleanState -Yes` also removes `state.json`,
`installed-manifest.json` and `stage\`; `originals\` and `logs\` are always
kept. `-DryRun` previews an install, apply, uninstall or repair without writing.

### Advanced commands

These are for recovery and diagnostics, not normal use. Every one runs through
the same controller and exits non-zero when its chain fails.

| Action | What it does |
| --- | --- |
| `apply` | Apply or re-apply the recorded merge without a variant switch |
| `revert` | Restore the pristine originals without the full removal chain |
| `repair` | Re-apply only when the live payload matches the recorded original; an unknown payload is never overwritten |
| `refresh` | Rebuild the icon and thumbnail cache for every logged-on profile |
| `merge` | Rebuild `stage\` and `installed-manifest.json` from the originals and the theme |
| `task-on` | Enable auto-repair at startup |
| `task-off` | Disable auto-repair at startup |

For example:

```powershell
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action repair -DryRun
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action merge -Variant dark-grey -Yes
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action apply -Yes
```

### Underlying scripts

`apply.ps1`, `restore.ps1`, `verify.ps1` and `bin\Merge-IconTheme.ps1` remain
callable directly for a measured procedure that needs one step at a time. They
are the mechanism, not the user surface:

```powershell
pwsh -NoProfile -File %ProgramData%\ArcIcons\apply.ps1 -DryRun
pwsh -NoProfile -File %ProgramData%\ArcIcons\apply.ps1 -CloseHolders
pwsh -NoProfile -File %ProgramData%\ArcIcons\verify.ps1
pwsh -NoProfile -File %ProgramData%\ArcIcons\restore.ps1
```

Controller flags: `-Variant`, `-Yes`, `-DryRun`, `-CleanState`, `-Root` /
`-SystemResourceDir` (sandbox runs REQUIRE an explicit `-SystemResourceDir`;
the pair is the only supported sandbox form, and a non-default `-Root` may
never pair with the live SystemResources directory).

Direct-script flags: `-DryRun` (plan only), `-CloseHolders` (apply/restore: stop
Restart-Manager holders of mapped files first), `-SkipIconCacheRefresh`
(apply/restore: skip the per-user cache delete + explorer restart).

Preflight is unconditional and `-Force` can NEVER bypass it: the pristine
backup must exist with `sha256 == originalSha256`, the stage file must exist
with `sha256 == mergedSha256`, the manifest must carry exactly three UNIQUE
allowlisted basenames, and owner/SDDL must be present and parse. `-Force`
only overrides an unexpected LIVE hash (or a missing live file, which is then
created from the verified stage/pristine source).

`restore.ps1` never refuses a missing target: it recreates the file from the
verified pristine backup and asserts hash + full SDDL afterwards.

## Full install and full uninstall (one action each)

`ARC-Icons.ps1 -Action install` is the whole install: variant source check,
capture-pristine-originals-if-fresh, merge the requested variant,
restore-originals-if-switching-variant, apply, refresh the icon cache for
**every logged-on interactive profile**, then `verify.ps1` and require PASS.
`-Action uninstall` is the whole uninstall: restore the pristine originals,
refresh every logged-on profile, verify PASS with `mode=original`; `-CleanState`
opts into removing `state.json`, `installed-manifest.json` and `stage\`
(default keeps them so a reinstall stays safe). `originals\` — the only
pristine copy — is never removed by any flag. Both actions are idempotent: a
second install re-applies the same merge; a second uninstall restores
already-pristine files.

The refresh step is the part an elevated installer used to get wrong. It does
not read the caller's `%LOCALAPPDATA%`; it enumerates sessions
(`WTSEnumerateSessions`), maps each `DOMAIN\user` to a SID and profile path via
the ProfileList registry key, and then:

- refreshes the caller's own profile in-process (the caller is that user in
  that session);
- for every other profile, registers `ArcIcons-Refresh-<random>` with an
  **InteractiveToken** principal for that user (no password, no stored
  credential), starts it, waits for the worker's JSON receipt, and deletes
  the task. The worker runs in that user's session, stops only that session's
  explorer, deletes `iconcache*.db` + `thumbcache*.db` + legacy `IconCache.db`,
  runs `ie4uinit -show`, restarts explorer, and exits 0 only when an explorer
  pid is back in that session.
- session 0 (the SYSTEM auto-repair task) never stops a shell it cannot
  restore; it uses the same per-user task transport for every profile.

Receipts land in `logs\refresh\`. If any logged-on profile cannot be refreshed
the action fails loudly with the profile named, even when the payload itself
verifies PASS.

## Detecting a Windows Update revert

- `verify.ps1` in `installed` mode FAILs on `[hash] MISMATCH` for a file whose
  live hash no longer equals `mergedSha256`.
- Or run `repair.ps1`. It classifies each live file and logs the verdict in
  `logs\repair.jsonl`:
  - live == `mergedSha256` for every file → `no-action`;
  - some file back at `originalSha256` (and none unknown) → safe `repaired`
    re-apply with before/after hashes (no `-Force` needed: the payload is the
    pristine original this theme was built from);
  - ANY file with an unknown hash (e.g. a newer Windows Update payload) →
    `drift-unknown-payload`: writes NOTHING, sets `state.json`
    `mode=drifted`, exits 0. Auto-repair only re-applies when the live file
    is the pristine original it was built from — it will never clobber an
    unknown newer payload with a stale theme.
- The `ArcIcons-Repair` scheduled task runs `repair.ps1` at every startup
  (2-minute delay). Its action embeds the validated absolute `-Root` and the
  absolute live `-SystemResourceDir` plus the absolute `repair.ps1` path.

## After a Windows Update: the theme reverts, re-merge it

A Windows Update replaces the SystemResources payloads (and the WinSxS
copies) with new binaries: the theme visibly reverts and `-Action repair`
reports `drift-unknown-payload`. Do NOT `-Force` the old stage files over the
new payload: they were merged against the OLD originals. `-Action install` and
the window's `Install theme` classify every live file before mutating anything
and refuse an unknown payload. `-Action revert` and `-Action uninstall` do not:
both run `restore.ps1`, which puts the pre-update originals back. Do not run
them to "clean up" before the rebase below.

The exact re-merge procedure:

1. Re-fetch the theme (same origin recorded in `originals\manifest.json`).
2. Rebase each file the refusal names onto the current live payload. `install`
   prints the file name and its live hash. The rebase is dry-run by default;
   `-Commit` writes it. It archives the superseded original under
   `originals\superseded\`, records the new hash and WinSxS component, and
   refuses a file with no attributable WinSxS sibling:

   ```powershell
   pwsh -NoProfile -File "$env:ProgramData\ArcIcons\bin\Rebase-ArcIconsOriginal.ps1" -Name imageres.dll.mun -ExpectLiveHash <live hash from the refusal> -Commit
   ```

   Repeat for `imagesp1.dll.mun` and `zipfldr.dll.mun` when they are named.
3. Rebuild and apply. `-Action install` re-merges and restores automatically once
   every live payload is classified; the explicit advanced path is `merge`,
   `revert`, then `apply`. `revert` is safe here because the rebase recorded the
   new stock payloads as the originals:

   ```powershell
   pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action merge -Variant dark-grey -Yes
   pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action revert -Yes
   pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action apply -DryRun
   pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action apply -Yes
   ```

4. Check the result: `-Action status` must print PASS.

## When an apply is interrupted

Power loss or a killed process skips the rollback path: `apply.ps1` takes the
SystemResources directory ACL before its first file and restores it in a
`finally`, so an interrupted run can leave the directory granted to
Administrators plus one payload missing. The journal at
`%ProgramData%\ArcIcons\logs\apply.journal.jsonl` records the last `apply` op
in flight (name, live hash, stage path). Recover with `revert`, then reinstall:

```powershell
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action revert -Yes
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action install -Variant dark-grey -Yes
```

`revert` runs `restore.ps1 -CloseHolders`, which recreates a missing payload
from the verified pristine backup, restores the full baseline SDDL on the new
file and the surviving WinSxS sibling, and restores the directory baseline.
`-Action repair` is not the fix: a missing or unknown live file classifies as
`drift-unknown-payload`, so repair writes nothing (`repair.ps1` lines 85-95 and
115-131).

## When uninstall refuses

`-Action uninstall` refuses before writing when `originals\manifest.json` is
missing, with `ARC-ICONS-UNINSTALL: REFUSED` and "no pristine copy to restore."
That is deliberate: with no pristine backup there is nothing safe to put back,
so the controller names the missing file instead of guessing. `verify.ps1` and
`-Action status` also need that manifest, so neither can certify the result
until the state is rebuilt or cleared.

- **The theme is already gone.** If a Windows Update replaced the payloads, the
  live files are stock and there is nothing to restore. Confirm by hand: each
  file has owner `NT SERVICE\TrustedInstaller` and a WinSxS sibling in
  `fsutil hardlink list`. Then clear the stale tool state by hand (the step
  `-CleanState` would have run): remove `state.json`, `installed-manifest.json`
  and `stage\`. Keep `originals\` and `logs\`.
- **The theme is still live.** Do not improvise a new `originals\` set from the
  live files: that would record the theme payload as pristine. Restore the
  stock payloads with the OS backstop (`sfc /scannow`, then
  `DISM /Online /Cleanup-Image /RestoreHealth`); if the component store cannot
  supply them, repair or reinstall Windows. Once the live files are stock,
  clear the state by hand as above. `restore.ps1` cannot recreate a payload with
  no recorded original; the controller refuses rather than overwrite a file it
  cannot restore.

If `originals\manifest.json` exists and uninstall fails at `RESTORE FAILED`,
that is a holder or ACL problem, not a missing backup: `-Action revert -Yes`
passes `-CloseHolders` and retries the same restore, and
`logs\restore.journal.jsonl` names the last operation in flight.

## When apply refuses a stale stage

`apply.ps1` preflight compares each `stage\` file with the hash recorded in
`installed-manifest.json`, then hashes the three theme inputs on disk against
the `sourceOrigin` hashes recorded in that manifest; it refuses on either
mismatch (`<name>: staged hash ... != manifest merged ...`, or `stale stage:
... merged from a different theme generation ...`). An older manifest with no
usable `sourceOrigin` is treated as stale on purpose. A `-Pair` merge likewise
refuses an untouched row whose stage no longer matches its recorded merge.
Rebuild the full stage and manifest for the variant, restore the pristine
originals, preview, then apply. `revert` is idempotent when live is already
original; it is required when live holds the previous merge, because the new
`mergedSha256` no longer matches that live file.

```powershell
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action merge -Variant dark-grey -Yes
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action revert -Yes
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action apply -DryRun
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action apply -Yes
```

The guard proves the stage against both the manifest hashes and the theme on
disk, so a merge built before the theme was regenerated or re-fetched is
refused. `ARC-Icons.ps1 -Action install` runs the same check and re-merges
rather than applying an unprovable stage.

## Swapping in a newer theme

1. Land the newer payload (`imageres.dll`, `imagesp1.dll`, `zipfldr.dll`) in the
   variant source dir `theme\<variant>\Windhawk Resources\`. Do not land
   `stage\` or `installed-manifest.json` by hand — the merge step writes both.
2. Run `install` for the variant. A variant switch self-chains merge -> restore
   -> apply -> per-user refresh -> verify. A newer payload for the SAME variant
   is detected as a stale stage and rebuilt by the same command.
3. A refusal is loud, never a silent close: the reason is named (missing variant
   source, or a live payload that is neither the recorded original nor the
   recorded merge), the status line turns red, and the details strip opens.
   Nothing is applied then.

## Recovery ladder

1. `ARC-Icons.ps1 -Action uninstall -Yes` (or the advanced `-Action revert`):
   puts the pristine originals back, refreshes every logged-on profile's icon
   and thumbnail cache, and re-checks hash/owner/DACL on both paths; it
   recreates a missing target instead of refusing.
2. `ARC-Icons.ps1 -Action status` in `original` mode -> PASS means the OS files
   are pristine (theme invariants report `not-applicable` there by design).
3. If the files verify but the desktop still shows stale icons, the payload was
   not the problem: run `ARC-Icons.ps1 -Action refresh -Yes` and read the
   per-profile lines; a profile listed FAIL could not restart its shell.
4. OS-level backstop only if 1–2 still fail:
   `sfc /scannow`, then
   `DISM /Online /Cleanup-Image /RestoreHealth`.

## Honest risk list

- These are protected OS files. A bad payload can break icons system-wide or,
  in the worst case, leave Explorer/shell visuals degraded until restored.
- Touching SystemResources can trip SFC (`sfc /scannow` may flag the files);
  that is expected with any resource edit and is why `restore.ps1` exists.
- Windows Updates replace these payloads — expected; repair detects it and
  refuses to overwrite unknown payloads (see above for the re-merge path).
- Never edit through the hardlink, never skip the takeown/unlink/copy cycle,
  never leave owner, group, DACL or protection flag non-baseline on either
  path, never test against the live files.
