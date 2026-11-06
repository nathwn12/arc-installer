<!-- ArcIcons repair manual -->

# ArcIcons — repair manual

Icon-theme installer for `C:\Windows\SystemResources`: replaces three
resource payloads with **merged** copies (stock resources + ARC theme icons),
and can undo it. Root: `%ProgramData%\ArcIcons`.

`apply.ps1` is THE one file-mutating install command — there is no separate
finalizer step (the finalize logic lives inside apply/restore).
`ARC-Icons.ps1 -Action install` / `-Action uninstall` orchestrate it: one
action each, ending in a per-user icon-cache refresh and a VERIFY PASS.
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
  that same session. Apply and restore do this automatically on live runs
  (`-SkipIconCacheRefresh` opts out; sandbox runs never touch a shell).

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

All scripts accept `-Root <path>` / `-SystemResourceDir <path>` for sandbox
runs (sandbox runs REQUIRE an explicit `-SystemResourceDir`). Live defaults:
`-Root %ProgramData%\ArcIcons`
`-SystemResourceDir C:\Windows\SystemResources`. Run elevated.

```powershell
# FULL INSTALL in one action: capture-if-fresh -> merge the chosen variant ->
# restore-if-switching -> apply -> refresh EVERY logged-on profile -> verify PASS
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action install -Variant dark-grey -Yes
# FULL UNINSTALL in one action: pristine originals -> refresh every profile ->
# verify PASS (mode=original). Add -CleanState to also remove state.json,
# installed-manifest.json and stage\; originals\ and logs\ are always kept.
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action uninstall -Yes
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action uninstall -CleanState -Yes
# icon cache only, every logged-on profile
pwsh -NoProfile -File "$env:ProgramData\ArcIcons\ARC-Icons.ps1" -Action refresh -Yes
# preview only (changes nothing)
pwsh -NoProfile -File %ProgramData%\ArcIcons\ARC-Icons.ps1 -Action install -DryRun
pwsh -NoProfile -File %ProgramData%\ArcIcons\apply.ps1 -DryRun
# install the merged theme without the controller (no variant switch, no verify)
pwsh -NoProfile -File %ProgramData%\ArcIcons\apply.ps1
# install, stopping mapped-file holders (explorer/RuntimeBroker) first
pwsh -NoProfile -File %ProgramData%\ArcIcons\apply.ps1 -CloseHolders
# check current state (prints ARC-ICONS-VERIFY: PASS / FAIL)
pwsh -NoProfile -File %ProgramData%\ArcIcons\verify.ps1
# undo: put the pristine originals back (recreates a missing target)
pwsh -NoProfile -File %ProgramData%\ArcIcons\restore.ps1
# auto-repair registration (SYSTEM task, startup + 2 min delay)
pwsh -NoProfile -File %ProgramData%\ArcIcons\install-autorepair.ps1
pwsh -NoProfile -File %ProgramData%\ArcIcons\remove-autorepair.ps1
```

Flags: `-Action install|uninstall` (full, one action, ends in PASS),
`-CleanState` (uninstall: also drop state.json / installed-manifest.json /
stage\), `-DryRun` (plan only), `-CloseHolders` (apply/restore: stop
Restart-Manager holders of mapped files first), `-SkipIconCacheRefresh`
(apply/restore: skip the per-user cache delete + explorer restart),
`-Root` / `-SystemResourceDir` (sandbox runs REQUIRE an explicit
`-SystemResourceDir`; the pair is the only supported sandbox form, and a
non-default `-Root` may never pair with the live SystemResources directory).

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
copies) with new binaries: the theme visibly reverts and `repair.ps1`
reports `drift-unknown-payload`. Do NOT `-Force` the old stage files over
the new payload — they were merged against the OLD originals. The exact
re-merge procedure:

1. Re-fetch the theme (same origin recorded in `originals\manifest.json`).
2. Back up the NEW originals: copy the three live
   `C:\Windows\SystemResources\*.mun` files plus their fresh SDDL/owner rows
   into a new `originals\` set (new hashes, new baseline — the old
   `originals\manifest.json` entries no longer describe these files).
3. Run `bin\Merge-IconTheme.ps1 -Build` to produce fresh `stage\` files and a
   fresh `installed-manifest.json` (with the NEW `originalSha256` values).
4. `apply.ps1 -DryRun`, then `apply.ps1`, then `verify.ps1` → PASS.

## Swapping in a newer theme

1. Land the newer payload (`imageres.dll`, `imagesp1.dll`, `zipfldr.dll`) in the
   variant source dir `theme\<variant>\Windhawk Resources\`. Do not land
   `stage\` or `installed-manifest.json` by hand — the merge step writes both.
2. Let the selector run the recipe: `ARC-Icons.ps1 -Action install -Variant <id>`
   self-chains merge → restore → apply → per-user refresh → verify for a
   variant switch (menu 11 → 1); a newer payload for the SAME variant is menu 7
   (merge) → 4 (revert) → 3 (apply).
3. A refusal is loud, never a silent close: the reason is named (missing variant
   source, or a live payload that is neither the recorded original nor the
   recorded merge) and the window holds open. Nothing is applied then.

## Recovery ladder

1. `ARC-Icons.ps1 -Action uninstall -Yes` (or `restore.ps1` directly): puts the
   pristine originals back, refreshes every logged-on profile's icon and
   thumbnail cache, and re-checks hash/owner/DACL on both paths; it recreates a
   missing target instead of refusing.
2. `verify.ps1` in `original` mode → PASS means the OS files are pristine
   (theme invariants report `not-applicable` there by design).
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
