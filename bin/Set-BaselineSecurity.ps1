# ArcIcons bin\Set-BaselineSecurity.ps1
# Shared library: DOT-SOURCE ONLY (no side effects on load). Used by apply.ps1,
# restore.ps1, repair.ps1 and verify.ps1. Owns:
#  - privilege enabling (SeRestorePrivilege + SeTakeOwnershipPrivilege +
#    SeBackupPrivilege via AdjustTokenPrivileges, so owner writes are
#    deterministic, not luck-of-the-token);
#  - complete baseline security restore (owner + group + DACL + protection flag
#    in one SetSecurityDescriptorSddlForm, verified by full SDDL compare);
#  - WinSxS sibling resolution via `fsutil hardlink list` (caller captures the
#    sibling BEFORE mutating, because takeown touches the shared inode);
#  - the atomic logs\ArcIcons.lock protocol (CreateNew + stale timeout);
#  - the shell guarantee: icon-cache refresh = delete iconcache*.db + verified
#    explorer restart, plus Restore-ArcIconsShell for every exit path;
#  - manifest allowlist validation, path canonicalization/confinement,
#    hashing and journal appends.
# Windows PowerShell 5.1 compatible (no ?. / ?? / ternary).

function Resolve-ArcIconsCanonicalPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path)
}

function Test-ArcIconsPathInside([string]$Path, [string]$Dir) {
  $p = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
  $d = ([IO.Path]::GetFullPath($Dir)).TrimEnd('\')
  if ($p -ieq $d) { return $true }
  return $p.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)
}

# Manifest-supplied paths are DATA, never trusted destinations. Refuse any
# resolved path under a system-owned resource tree: the rebase writes only
# inside -Root, so a manifest row can never aim a copy at SystemResources/WinSxS.
function Assert-ArcIconsNoSystemResourceWrite([string]$FullPath, [string]$Label) {
  $c = [IO.Path]::GetFullPath($FullPath)
  $guarded = @()
  if ($env:SystemRoot) {
    $guarded += (Resolve-ArcIconsCanonicalPath (Join-Path $env:SystemRoot 'SystemResources'))
    $guarded += (Resolve-ArcIconsCanonicalPath (Join-Path $env:SystemRoot 'WinSxS'))
  }
  foreach ($g in $guarded) {
    if (Test-ArcIconsPathInside $c $g) {
      throw ("refused {0} '{1}': resolves inside the system-owned directory {2}; the rebase writes only under -Root." -f $Label, $FullPath, $g)
    }
  }
}

# Canonicalize a RELATIVE child of -Root and enforce confinement: reject
# rooted/UNC values, reject anything that resolves outside -Root or onto -Root
# itself, and reject system-resource destinations. Every rebase write target is
# produced here, whether the value came from a manifest row or was derived.
function Resolve-ArcIconsRootChildPath([string]$RootC, [string]$Relative, [string]$Label) {
  $rel = ([string]$Relative).Trim()
  if (-not $rel) { throw ("refused {0}: empty path; a manifest row must name a path under -Root." -f $Label) }
  if ([IO.Path]::IsPathRooted($rel) -or $rel.StartsWith('\\') -or ($rel -match '^[A-Za-z]:')) {
    throw ("refused {0} '{1}': must be relative to -Root, not absolute or UNC." -f $Label, $Relative)
  }
  $root = ([IO.Path]::GetFullPath($RootC)).TrimEnd('\')
  $full = [IO.Path]::GetFullPath((Join-Path $root $rel))
  if (-not (Test-ArcIconsPathInside $full $root)) {
    throw ("refused {0} '{1}': resolves to '{2}', which escapes -Root '{3}'." -f $Label, $Relative, $full, $root)
  }
  if ($full.TrimEnd('\') -ieq $root) {
    throw ("refused {0} '{1}': resolves to -Root itself, not a path under it." -f $Label, $Relative)
  }
  Assert-ArcIconsNoSystemResourceWrite $full $Label
  return $full
}

function Test-ArcIconsAllowedName([string]$Name) {
  if (-not $Name) { return $false }
  if ([IO.Path]::GetFileName($Name) -ne $Name) { return $false }
  $allowed = @('IMAGERES.DLL.MUN', 'IMAGESP1.DLL.MUN', 'ZIPFLDR.DLL.MUN')
  return $allowed -contains $Name.ToUpperInvariant()
}

# Count + unique-name + bare-allowlisted-basename checks always run. When the
# caller passes -RootC, every row's write paths are ALSO canonicalized and
# confined to that root (originalPath must name the row's own file), so a
# manifest cannot redirect a rebase copy outside -Root.
function Assert-ArcIconsOriginalsManifest($Manifest, [string]$RootC = '') {
  $files = @()
  if ($Manifest.files) { $files = @($Manifest.files) }
  if ($files.Count -ne 3) {
    throw "originals manifest must carry exactly three entries (found $($files.Count)). -Force cannot bypass."
  }
  $names = @($files | ForEach-Object { [string]$_.name })
  $upper = @($names | ForEach-Object { $_.ToUpperInvariant() })
  if ((@($upper | Sort-Object -Unique)).Count -ne 3) {
    throw 'originals manifest must carry three UNIQUE names. -Force cannot bypass.'
  }
  foreach ($n in $names) {
    if (-not (Test-ArcIconsAllowedName $n)) {
      throw "refused manifest name '$n': not a bare allowlisted basename {imageres.dll.mun, imagesp1.dll.mun, zipfldr.dll.mun}. -Force cannot bypass."
    }
  }
  if ($RootC) {
    $root = ([IO.Path]::GetFullPath($RootC)).TrimEnd('\')
    foreach ($f in $files) {
      $nm = [string]$f.name
      $op = Resolve-ArcIconsRootChildPath $root ([string]$f.originalPath) ("{0}: originalPath" -f $nm)
      if ([IO.Path]::GetFileName($op) -ine $nm) {
        throw ("refused manifest row '{0}': originalPath '{1}' does not name that file. -Force cannot bypass." -f $nm, [string]$f.originalPath)
      }
      [void](Resolve-ArcIconsRootChildPath $root ([string]$f.aclFile) ("{0}: aclFile" -f $nm))
      [void](Resolve-ArcIconsRootChildPath $root ([string]$f.stagePath) ("{0}: stagePath" -f $nm))
    }
  }
}

function Assert-ArcIconsInstalledManifest($Manifest) {
  $files = @()
  if ($Manifest.files) { $files = @($Manifest.files) }
  if ($files.Count -ne 3) {
    throw "installed manifest must carry exactly three entries (found $($files.Count)). -Force cannot bypass."
  }
  $names = @($files | ForEach-Object { [string]$_.name })
  $upper = @($names | ForEach-Object { $_.ToUpperInvariant() })
  if ((@($upper | Sort-Object -Unique)).Count -ne 3) {
    throw 'installed manifest must carry three UNIQUE names. -Force cannot bypass.'
  }
  foreach ($n in $names) {
    if (-not (Test-ArcIconsAllowedName $n)) {
      throw "refused manifest name '$n': not a bare allowlisted basename {imageres.dll.mun, imagesp1.dll.mun, zipfldr.dll.mun}. -Force cannot bypass."
    }
  }
}

# Variant resolution for scripts that merge or capture (apply.ps1). Mirrors the
# variant tables in bin\Merge-IconTheme.ps1 and ARC-Icons.ps1: same ids,
# display labels and theme dirs, same alias normalization. Returns a
# pscustomobject {Id, Display, ThemeDir} or $null for an unknown name.
function Get-ArcIconsVariantInfo([string]$Name) {
  $key = ([string]$Name).Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $key = $key.Trim('-')
  $alias = @{
    'arc' = 'arc'; 'arc-by-niivu' = 'arc'; 'niivu' = 'arc'; 'default' = 'arc'
    'neutral-brown' = 'neutral-brown'; 'arc-neutral-brown' = 'neutral-brown'; 'brown' = 'neutral-brown'
    'neutral-grey' = 'neutral-grey'; 'arc-neutral-grey' = 'neutral-grey'; 'grey' = 'neutral-grey'
    'gray' = 'neutral-grey'; 'neutral-gray' = 'neutral-grey'; 'arc-neutral-gray' = 'neutral-grey'
    'dark-grey' = 'dark-grey'; 'arc-dark-grey' = 'dark-grey'; 'dark-gray' = 'dark-grey'; 'arc-dark-gray' = 'dark-grey'
  }
  if (-not $alias.ContainsKey($key)) { return $null }
  $id = $alias[$key]
  if ($id -eq 'arc') { return [pscustomobject]@{ Id = 'arc'; Display = 'ARC (by niivu)'; ThemeDir = 'Windhawk Resources' } }
  if ($id -eq 'neutral-brown') { return [pscustomobject]@{ Id = 'neutral-brown'; Display = 'Arc Neutral Brown'; ThemeDir = 'Arc Neutral Brown\Windhawk Resources' } }
  if ($id -eq 'neutral-grey') { return [pscustomobject]@{ Id = 'neutral-grey'; Display = 'Arc Neutral Grey'; ThemeDir = 'Arc Neutral Grey\Windhawk Resources' } }
  return [pscustomobject]@{ Id = 'dark-grey'; Display = 'Arc Dark Grey'; ThemeDir = 'Arc Dark Grey\Windhawk Resources' }
}

# Provably-fresh machine: no state.json AND no installed-manifest.json AND no
# originals\ directory. Anything else with originals\manifest.json missing is
# partial state and must refuse, never auto-capture.
function Test-ArcIconsFreshInstall([string]$RootC) {
  if (Test-Path -LiteralPath (Join-Path $RootC 'state.json')) { return $false }
  if (Test-Path -LiteralPath (Join-Path $RootC 'installed-manifest.json')) { return $false }
  if (Test-Path -LiteralPath (Join-Path $RootC 'originals')) { return $false }
  return $true
}

# First-install capture: copies the live {imageres,imagesp1,zipfldr}.dll.mun
# from $SysC into originals\ with the SAME manifest schema + ACL baseline the
# existing originals\manifest.json uses (per-file owner + full SDDL, .acl
# sidecars, the directory SDDL). Call ONLY on a Test-ArcIconsFreshInstall
# root; anything partial must refuse instead. Throws with a named reason.
function Invoke-ArcIconsOriginalsCapture([string]$RootC, [string]$SysC, $VariantInfo) {
  $pairs = @(
    [pscustomobject]@{ Mun = 'imageres.dll.mun'; Dll = 'imageres.dll' },
    [pscustomobject]@{ Mun = 'imagesp1.dll.mun'; Dll = 'imagesp1.dll' },
    [pscustomobject]@{ Mun = 'zipfldr.dll.mun'; Dll = 'zipfldr.dll' }
  )
  # themeOrigin provenance: arc + both neutrals ship from niivu's
  # resource-redirect repo (archive name from the landed theme dir, same repo
  # the live manifest records); dark-grey is generated on this PC.
  $origin = 'generated on this PC by bin\Recolor-IconTheme.ps1; see theme\Arc Dark Grey\NOTES.md'
  if ($VariantInfo.Id -eq 'arc') { $origin = 'https://github.com/niivu/resource-redirect-icon-themes  Resource Redirect themes/ARC.zip' }
  if ($VariantInfo.Id -eq 'neutral-brown') { $origin = 'https://github.com/niivu/resource-redirect-icon-themes  Resource Redirect themes/arc-neutral-brown.zip' }
  if ($VariantInfo.Id -eq 'neutral-grey') { $origin = 'https://github.com/niivu/resource-redirect-icon-themes  Resource Redirect themes/arc-neutral-grey.zip' }
  $origDir = Join-Path $RootC 'originals'
  $aclDir = Join-Path $origDir 'acl'
  foreach ($d in @($origDir, $aclDir)) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }
  $rows = @()
  foreach ($pr in $pairs) {
    $src = Join-Path $SysC $pr.Mun
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw ("ARC-ICONS-CAPTURE: FAIL {0} not found in {1}; cannot capture pristine originals." -f $pr.Mun, $SysC) }
    $sha = Get-ArcIconsSha256 $src
    $size = (Get-Item -LiteralPath $src).Length
    $owner = (Get-Acl -LiteralPath $src).Owner
    $full = Get-ArcIconsFullSddl $src
    Copy-Item -Force -LiteralPath $src -Destination (Join-Path $origDir $pr.Mun)
    $di = $full.IndexOf('D:')
    if ($di -lt 0) { throw ("ARC-ICONS-CAPTURE: FAIL no DACL section in baseline SDDL for {0}." -f $pr.Mun) }
    [IO.File]::WriteAllText((Join-Path $aclDir ($pr.Mun + '.acl')), ($pr.Mun + "`r`n" + $full.Substring($di) + "S:`r`n"), [Text.Encoding]::Unicode)
    $rows += [pscustomobject]@{ Mun = $pr.Mun; Dll = $pr.Dll; Sha = $sha; Size = $size; Owner = $owner; Sddl = $full }
    Write-Output ("  capture {0,-18} sha256={1} size={2} owner={3}" -f $pr.Mun, $sha, $size, $owner)
  }
  $dirSddl = (Get-Acl -LiteralPath $SysC).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
  [IO.File]::WriteAllText((Join-Path $aclDir 'SystemResources.dir.sddl'), ($dirSddl + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $osBuild = 'unknown'
  try {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $osBuild = ("{0}.{1} ({2})" -f $cv.CurrentBuild, $cv.UBR, $cv.DisplayVersion)
  } catch { }
  $sess = 'operator'   # recorded in the manifest; no operator identity is collected
  $themeRel = 'theme\' + $VariantInfo.ThemeDir
  $files = @()
  foreach ($r in $rows) {
    $files += [ordered]@{
      name = $r.Mun
      target = (Join-Path $SysC $r.Mun)
      originalPath = ('originals\' + $r.Mun)
      aclFile = ('originals\acl\' + $r.Mun + '.acl')
      originalSha256 = $r.Sha
      originalSize = $r.Size
      owner = $r.Owner
      sddl = $r.Sddl
      stagePath = ('stage\' + $r.Mun)
      themeFile = ($themeRel + '\' + $r.Dll)
    }
  }
  $man = [ordered]@{
    generated = (Get-Date).ToString('o')
    session = [string]$sess
    theme = $VariantInfo.Display
    themeOrigin = $origin
    osBuild = $osBuild
    root = $RootC
    files = $files
  }
  [IO.File]::WriteAllText((Join-Path $origDir 'manifest.json'), ($man | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
  Write-Output ("ARC-ICONS-CAPTURE: OK originals\manifest.json (3 files, theme '{0}')" -f $VariantInfo.Display)
}

# Single-file original rebase (measured 2026-10-30). A Windows component
# update replaces a live .mun with a NEW WinSxS build: live is hardlinked to the
# new component, owner is TrustedInstaller again, and the recorded original is
# stale. apply.ps1 then refuses ("live hash is neither recorded original nor
# recorded merged") and -Force would paper over a real baseline change. The
# rebase adopts the CURRENT LIVE file as the pristine original for ONE name,
# archiving the superseded original + its acl sidecar + the old row so the
# previous baseline stays recoverable. Nothing outside $RootC is written.
#
# Gates (all refuse, never -Force-overridable):
#   - $Name must be an allowlisted bare basename and have a row in the manifest;
#   - every manifest write path must canonicalize INSIDE -Root (no rooted/UNC
#     value, no .. escape, never SystemResources/WinSxS);
#   - live must exist and hash EXACTLY to -ExpectLiveHash (caller-supplied);
#   - live must NOT equal the recorded merged hash (that means our install is
#     live, not an updated OS baseline: restore pristine first);
#   - live == recorded original -> ALREADY-REBASED (no-op, verified consistent);
#   - the live file must be hardlinked to a WinSxS component whose directory
#     name parses as <arch>_<name>_<pubkey>_<version>_<culture>_<hash>
#     (strict attribution; an unattributed or non-WinSxS sibling fails closed).
# Caller must hold read access to live; no privilege is enabled here.
#
# ORDER: the validation below is read-only and is what -DryRun reports. The
# commit path acquires logs\ArcIcons.lock FIRST and then runs this same
# validation again under the lock, so the hashes/manifest/attribution that
# justify the write are read while the lock is held - a concurrent
# apply/restore cannot slide between the check and the commit.

# Parse WinSxS component packaging from a hardlink sibling path:
#   <arch>_<name>_<publicKeyToken>_<a.b.c.d>_<culture>_<hash>
# Returns @{Name, Version} or $null (caller fails closed).
function Get-ArcIconsWinSxSComponent([string]$Sibling) {
  $leaf = Split-Path -Leaf (Split-Path -Parent ([string]$Sibling))
  if (-not $leaf) { return $null }
  if ($leaf -notmatch '^[A-Za-z0-9]+_.+_[0-9A-Fa-f]{16}_(\d+\.\d+\.\d+\.\d+)_[A-Za-z0-9-]+_[0-9A-Fa-f]{16}$') { return $null }
  return [pscustomobject]@{ Name = $leaf; Version = $Matches[1] }
}

# One read-only validation pass: every gate plus every value the commit needs.
# Called by the dry-run path (no lock, no writes) and again by the commit path
# AFTER the lock is held.
function Get-ArcIconsRebasePlan {
  param(
    [string]$RootC,
    [string]$SysC,
    [string]$Name,
    [string]$ExpectLiveHash,
    [string]$BaseVersion = ''
  )
  $rootFull = ([IO.Path]::GetFullPath($RootC)).TrimEnd('\')
  $sysFull = ([IO.Path]::GetFullPath($SysC)).TrimEnd('\')
  if (Test-ArcIconsPathInside $rootFull $sysFull) {
    throw ("refused -Root '{0}': it is inside -SystemResourceDir '{1}'; the rebase never writes system-owned paths." -f $rootFull, $sysFull)
  }
  Assert-ArcIconsNoSystemResourceWrite $rootFull '-Root'
  $manPath = Join-Path $rootFull 'originals\manifest.json'
  if (-not (Test-Path -LiteralPath $manPath -PathType Leaf)) { throw ("originals manifest missing: {0}" -f $manPath) }
  $man = Read-ArcIconsJsonFile $manPath
  Assert-ArcIconsOriginalsManifest $man $rootFull
  $row = @($man.files | Where-Object { ([string]$_.name) -ieq $Name })[0]
  if ($null -eq $row) { throw ("{0}: no row in originals\manifest.json." -f $Name) }
  $canonName = [string]$row.name
  $live = Resolve-ArcIconsCanonicalPath (Join-Path $sysFull $canonName)
  if (-not (Test-ArcIconsPathInside $live $sysFull)) { throw ("{0}: live path escapes -SystemResourceDir." -f $canonName) }
  if (-not (Test-Path -LiteralPath $live -PathType Leaf)) { throw ("{0}: live file missing ({1}); nothing to rebase from." -f $canonName, $live) }

  $expect = ([string]$ExpectLiveHash).Trim().ToUpperInvariant()
  if (-not $expect) { throw ("{0}: -ExpectLiveHash is required (the exact live hash this rebase may adopt)." -f $canonName) }
  $liveSha = Get-ArcIconsSha256 $live
  if ($liveSha -ne $expect) {
    throw ("{0}: live hash {1} != -ExpectLiveHash {2}; live moved since the hash was read - re-read it and retry." -f $canonName, $liveSha, $expect)
  }

  $mergedSha = ''
  $instPath = Join-Path $rootFull 'installed-manifest.json'
  if (Test-Path -LiteralPath $instPath -PathType Leaf) {
    $inst = Read-ArcIconsJsonFile $instPath
    $irow = @($inst.files | Where-Object { ([string]$_.name) -ieq $canonName })[0]
    if ($null -ne $irow) { $mergedSha = ([string]$irow.mergedSha256).ToUpperInvariant() }
  }
  if ($mergedSha -and ($liveSha -eq $mergedSha)) {
    throw ("{0}: live hash {1} IS the recorded merged hash - our install is live, not an updated OS baseline. Run restore/apply first; rebasing would adopt a themed file as pristine." -f $canonName, $liveSha)
  }

  $oldSha = ([string]$row.originalSha256).ToUpperInvariant()
  $oldFile = Resolve-ArcIconsRootChildPath $rootFull ([string]$row.originalPath) ("{0}: originalPath" -f $canonName)
  $aclPath = Resolve-ArcIconsRootChildPath $rootFull ([string]$row.aclFile) ("{0}: aclFile" -f $canonName)
  if ($liveSha -eq $oldSha) {
    if (-not (Test-Path -LiteralPath $oldFile -PathType Leaf)) { throw ("{0}: live already equals the recorded original but the pristine backup is missing ({1}); re-run the capture/restore path." -f $canonName, [string]$row.originalPath) }
    $backupSha = Get-ArcIconsSha256 $oldFile
    if ($backupSha -ne $oldSha) {
      throw ("{0}: live == recorded original {1} but {2} hashes {3}; the manifest and originals disagree - repair before rebasing." -f $canonName, $oldSha, [string]$row.originalPath, $backupSha)
    }
    return [pscustomobject]@{ Status = 'already-rebased'; Name = $canonName; Live = $live; LiveSha = $liveSha; OldSha = $oldSha; MergedSha = $mergedSha; Sibling = ''; Component = ''; BaseVersion = ''; SupersededRel = ''; SupersededDir = ''; Plan = @() }
  }

  if (-not (Test-Path -LiteralPath $oldFile -PathType Leaf)) { throw ("{0}: pristine backup missing ({1}); cannot archive the superseded original." -f $canonName, [string]$row.originalPath) }
  $backupSha = Get-ArcIconsSha256 $oldFile
  if ($backupSha -ne $oldSha) {
    throw ("{0}: pristine backup hash {1} != recorded original {2}; originals are inconsistent - repair before rebasing." -f $canonName, $backupSha, $oldSha)
  }

  $targets = @(Get-ArcIconsHardlinkTargets $live)
  $sibling = Get-ArcIconsWinSxSSibling $live $targets
  if (-not $sibling) {
    throw ("{0}: no WinSxS hardlink sibling for {1} (fsutil returned {2} target(s)); cannot attribute the live file to an OS component - refusing to rebase from an unattributed file (a plain hardlink is not attribution)." -f $canonName, $live, $targets.Count)
  }
  if (-not (Test-Path -LiteralPath $sibling -PathType Leaf)) {
    throw ("{0}: WinSxS hardlink sibling does not exist on disk: {1}; refusing." -f $canonName, $sibling)
  }
  $comp = Get-ArcIconsWinSxSComponent $sibling
  if (-not $comp) {
    throw ("{0}: WinSxS sibling is not a parseable component directory: {1}; cannot attribute the live file to a component version - refusing." -f $canonName, $sibling)
  }
  $component = $comp.Name
  if (-not $BaseVersion) { $BaseVersion = $comp.Version }
  if (-not $BaseVersion) {
    try {
      $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
      $BaseVersion = ("{0}.{1}.{2}" -f $cv.CurrentMajorVersionNumber, $cv.CurrentBuild, $cv.UBR)
    } catch { $BaseVersion = 'unknown' }
  }

  $size = (Get-Item -LiteralPath $live).Length
  $owner = (Get-Acl -LiteralPath $live).Owner
  $full = Get-ArcIconsFullSddl $live
  $di = $full.IndexOf('D:')
  if ($di -lt 0) { throw ("{0}: no DACL section in the live SDDL; cannot record a baseline ACL." -f $canonName) }
  $daclSddl = $full.Substring($di)
  if ($oldSha -notmatch '^[0-9A-F]{64}$') {
    throw ("{0}: recorded original hash '{1}' is not a SHA-256 hex digest; refusing to derive the archive path from it." -f $canonName, [string]$row.originalSha256)
  }
  $supersededRel = 'originals\superseded\' + $oldSha
  $supersededDir = Resolve-ArcIconsRootChildPath $rootFull $supersededRel ("{0}: superseded archive" -f $canonName)

  $newRow = [ordered]@{
    name           = $canonName
    target         = [string]$row.target
    originalPath   = [string]$row.originalPath
    aclFile        = [string]$row.aclFile
    originalSha256 = $liveSha
    originalSize   = $size
    owner          = $owner
    sddl           = $full
    stagePath      = [string]$row.stagePath
    themeFile      = [string]$row.themeFile
    capturedFrom   = ('live: ' + $live)
    winSxSComponent = $component
    baseVersion    = $BaseVersion
    rebasedFrom    = $oldSha
    rebasedAt      = (Get-Date).ToString('o')
  }

  $plan = @(
    ("ARC-REBASE plan ({0})" -f $canonName)
    ("  live      : {0}" -f $live)
    ("  liveSha   : {0} (size {1}, owner {2})" -f $liveSha, $size, $owner)
    ("  old orig  : {0} -> archive {1}" -f $oldSha, $supersededRel)
    ("  merged    : {0}" -f $(if ($mergedSha) { $mergedSha + ' (live differs: OK)' } else { '<none recorded>' }))
    ("  sibling   : {0}" -f $sibling)
    ("  component : {0}  baseVersion {1}" -f $component, $BaseVersion)
    ("  writes    : {0} (copy), {1} (sidecar), {2}\manifest.json (row rewrite), logs\rebase.journal.jsonl" -f [string]$row.originalPath, [string]$row.aclFile, 'originals')
  )
  return [pscustomobject]@{
    Status = 'planned'; Name = $canonName; Live = $live; LiveSha = $liveSha; OldSha = $oldSha; MergedSha = $mergedSha
    Sibling = $sibling; Component = $component; BaseVersion = $BaseVersion
    SupersededRel = $supersededRel; SupersededDir = $supersededDir
    OldFile = $oldFile; AclPath = $aclPath; ManPath = $manPath; Manifest = $man; Row = $row
    Size = $size; Owner = $owner; Sddl = $full; DaclSddl = $daclSddl; NewRow = $newRow; Plan = $plan
  }
}

# Shape the public result object. Status is 'already-rebased' (no-op),
# 'planned' (dry run) or 'rebased' (committed).
function New-ArcIconsRebaseResult($V, [string]$Status, [bool]$DryRun) {
  $orig = $V.OldSha
  if ($Status -eq 'rebased') { $orig = $V.LiveSha }
  $sib = $V.Sibling; $comp = $V.Component; $ver = $V.BaseVersion; $sup = $V.SupersededRel; $plan = $V.Plan
  if ($Status -eq 'already-rebased') { $sib = ''; $comp = ''; $ver = ''; $sup = ''; $plan = @() }
  return [pscustomobject]@{
    Name = $V.Name; Status = $Status; LiveSha = $V.LiveSha; OriginalSha = $orig; MergedSha = $V.MergedSha
    Sibling = $sib; Component = $comp; BaseVersion = $ver; SupersededDir = $sup; DryRun = $DryRun; Plan = $plan
  }
}

function Invoke-ArcIconsOriginalRebase {
  param(
    [string]$RootC,
    [string]$SysC,
    [string]$Name,
    [string]$ExpectLiveHash,
    [string]$BaseVersion = '',
    [bool]$DryRun = $true,
    [int]$LockTimeoutSec = 90
  )
  if (-not (Test-ArcIconsAllowedName $Name)) {
    throw ("refused rebase name '{0}': not a bare allowlisted basename {imageres.dll.mun, imagesp1.dll.mun, zipfldr.dll.mun}." -f $Name)
  }
  $rootFull = ([IO.Path]::GetFullPath($RootC)).TrimEnd('\')
  if ($DryRun) {
    # Read-only preview: no lock file, no writes.
    $v = Get-ArcIconsRebasePlan -RootC $rootFull -SysC $SysC -Name $Name -ExpectLiveHash $ExpectLiveHash -BaseVersion $BaseVersion
    if ($v.Status -eq 'already-rebased') { return (New-ArcIconsRebaseResult $v 'already-rebased' $true) }
    return (New-ArcIconsRebaseResult $v 'planned' $true)
  }

  $logDir = Join-Path $rootFull 'logs'
  if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
  # Lock BEFORE validating: the commit reads every hash, row and destination
  # again under the lock, so a concurrent apply/restore/match cannot move the
  # live file or rewrite the manifest between the check and the write.
  [void](Acquire-ArcIconsLock $logDir $LockTimeoutSec)
  try {
    $v = Get-ArcIconsRebasePlan -RootC $rootFull -SysC $SysC -Name $Name -ExpectLiveHash $ExpectLiveHash -BaseVersion $BaseVersion
    if ($v.Status -eq 'already-rebased') { return (New-ArcIconsRebaseResult $v 'already-rebased' $false) }
    $canonName = $v.Name
    $live = $v.Live
    $liveSha = $v.LiveSha
    $oldSha = $v.OldSha
    Write-ArcIconsJournal $logDir 'rebase.journal.jsonl' ([ordered]@{
      ts = (Get-Date).ToString('o'); op = 'rebase-begin'; name = $canonName; from = $live; oldSha = $oldSha; newSha = $liveSha; superseded = $v.SupersededRel; component = $v.Component; baseVersion = $v.BaseVersion
    })
    if (-not (Test-Path -LiteralPath $v.SupersededDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $v.SupersededDir | Out-Null }
    Copy-Item -Force -LiteralPath $v.OldFile -Destination (Join-Path $v.SupersededDir $canonName)
    if (Test-Path -LiteralPath $v.AclPath -PathType Leaf) {
      Copy-Item -Force -LiteralPath $v.AclPath -Destination (Join-Path $v.SupersededDir ($canonName + '.acl'))
    }
    $supRecord = [ordered]@{
      supersededAt = (Get-Date).ToString('o')
      reason       = 'Windows component update: live ' + $canonName + ' was hardlinked to ' + $v.Sibling
      newSha256    = $liveSha
      winSxSComponent = $v.Component
      baseVersion  = $v.BaseVersion
      row          = $v.Row
    }
    [IO.File]::WriteAllText((Join-Path $v.SupersededDir 'superseded.json'), ($supRecord | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))

    Copy-Item -Force -LiteralPath $live -Destination $v.OldFile
    $copied = Get-ArcIconsSha256 $v.OldFile
    if ($copied -ne $liveSha) { throw ("{0}: copied original hashes {1} != live {2}; manifest not rewritten." -f $canonName, $copied, $liveSha) }
    $aclDir = Split-Path -Parent $v.AclPath
    if (-not (Test-Path -LiteralPath $aclDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $aclDir | Out-Null }
    [IO.File]::WriteAllText($v.AclPath, ($canonName + "`r`n" + $v.DaclSddl + "S:`r`n"), [Text.Encoding]::Unicode)

    $files = @()
    foreach ($f in $v.Manifest.files) {
      if (([string]$f.name) -ieq $canonName) { $files += $v.NewRow } else { $files += $f }
    }
    $v.Manifest.files = $files
    [IO.File]::WriteAllText($v.ManPath, ($v.Manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    Write-ArcIconsJournal $logDir 'rebase.journal.jsonl' ([ordered]@{
      ts = (Get-Date).ToString('o'); op = 'rebase-end'; name = $canonName; ok = $true; oldSha = $oldSha; newSha = $liveSha; superseded = $v.SupersededRel
    })
  } catch {
    try { Write-ArcIconsJournal $logDir 'rebase.journal.jsonl' ([ordered]@{ ts = (Get-Date).ToString('o'); op = 'rebase-fail'; name = $Name; error = [string]$_ }) } catch { }
    throw
  } finally {
    Release-ArcIconsLock $logDir
  }
  return (New-ArcIconsRebaseResult $v 'rebased' $false)
}

function Read-ArcIconsJsonFile([string]$Path) {
  return (Get-Content -Raw -Encoding utf8 -LiteralPath $Path | ConvertFrom-Json)
}

function Get-ArcIconsSha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Enable-ArcIconsPrivileges {
  if (-not ([System.Management.Automation.PSTypeName]'ArcIconsPriv').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ArcIconsPriv {
    const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
    const uint TOKEN_QUERY = 0x8;
    const uint SE_PRIVILEGE_ENABLED = 0x2;
    [StructLayout(LayoutKind.Sequential)]
    struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)]
    struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_PRIVILEGES {
        public uint PrivilegeCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=1)]
        public LUID_AND_ATTRIBUTES[] Privileges;
    }
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string s, string n, out LUID l);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool AdjustTokenPrivileges(IntPtr t, bool d, ref TOKEN_PRIVILEGES p, uint l, IntPtr pr, IntPtr rl);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);
    public static void Enable(string name) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out tok))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed");
        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, name, out luid))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "LookupPrivilegeValue failed: " + name);
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Privileges = new LUID_AND_ATTRIBUTES[1];
            tp.Privileges[0].Luid = luid;
            tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
            if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "AdjustTokenPrivileges failed: " + name);
            int err = Marshal.GetLastWin32Error();
            if (err != 0)
                throw new System.ComponentModel.Win32Exception(err, "privilege not held: " + name);
        } finally { CloseHandle(tok); }
    }
}
'@
  }
  [ArcIconsPriv]::Enable('SeTakeOwnershipPrivilege')
  [ArcIconsPriv]::Enable('SeRestorePrivilege')
  [ArcIconsPriv]::Enable('SeBackupPrivilege')
  return $true
}

function Get-ArcIconsFullSddl([string]$LiteralPath) {
  $sections = [System.Security.AccessControl.AccessControlSections]::Owner -bor `
    [System.Security.AccessControl.AccessControlSections]::Group -bor `
    [System.Security.AccessControl.AccessControlSections]::Access
  return (Get-Acl -LiteralPath $LiteralPath).GetSecurityDescriptorSddlForm($sections)
}

# Wholesale SD restore. .NET Set-Acl and SetNamedSecurityInfo both leave the
# SE_DACL_AUTO_INHERITED (AI) flag behind, so a post-hoc set reads back D:PAI
# instead of the baseline D:P (measured in sandbox isolation). NtSetSecurityObject
# with a full self-relative SD parsed from the baseline SDDL replaces owner +
# group + DACL + control flags wholesale and reads back byte-identical to the
# baseline string (measured: exact=True). Caller must already hold WRITE_DAC /
# WRITE_OWNER on the path — in our flow that is true because the caller either
# just created the file (owner=self) or ran takeown on the shared inode first.
function Ensure-ArcIconsNativeSD {
  if ([System.Management.Automation.PSTypeName]'ArcIconsNativeSD'.Type) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ArcIconsNativeSD {
    const uint WRITE_DAC = 0x40000;
    const uint WRITE_OWNER = 0x80000;
    const uint FILE_SHARE_ALL = 0x7;
    const uint OPEN_EXISTING = 3;
    const uint BACKUP_SEMANTICS = 0x02000000;
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CreateFile(string f, uint acc, uint share, IntPtr sa, uint disp, uint flags, IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s, uint rev, out IntPtr sd, out uint len);
    [DllImport("ntdll.dll")]
    static extern int NtSetSecurityObject(IntPtr h, uint info, IntPtr sd);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr LocalFree(IntPtr h);
    public static void Apply(string path, string sddl) {
        IntPtr sd = IntPtr.Zero; uint len = 0;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out sd, out len))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "ConvertStringSD failed");
        try {
            IntPtr h = CreateFile(path, WRITE_DAC | WRITE_OWNER, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, BACKUP_SEMANTICS, IntPtr.Zero);
            if (h.ToInt64() == -1)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateFile(WRITE_DAC|WRITE_OWNER) failed: " + path);
            try {
                int st = NtSetSecurityObject(h, 0x1 | 0x2 | 0x4, sd);
                if (st != 0) throw new System.ComponentModel.Win32Exception(st, "NtSetSecurityObject failed: " + path);
            } finally { CloseHandle(h); }
        } finally { LocalFree(sd); }
    }
}
'@
}

function Set-ArcIconsBaselineSecurity([string]$LiteralPath, [string]$BaselineSddl) {
  Enable-ArcIconsPrivileges | Out-Null
  Ensure-ArcIconsNativeSD
  [ArcIconsNativeSD]::Apply($LiteralPath, $BaselineSddl)
  $now = Get-ArcIconsFullSddl $LiteralPath
  if ($now -cne $BaselineSddl) {
    throw ("baseline SD verify failed for {0}:`n  now     ={1}`n  baseline={2}" -f $LiteralPath, $now, $BaselineSddl)
  }
  return $now
}

function Test-ArcIconsBaselineSecurity([string]$LiteralPath, [string]$BaselineSddl) {
  return ((Get-ArcIconsFullSddl $LiteralPath) -ceq $BaselineSddl)
}

function Get-ArcIconsAceSet([string]$DaclSddl) {
  $r = New-Object System.Security.AccessControl.RawSecurityDescriptor($DaclSddl)
  $list = @()
  foreach ($ace in $r.DiscretionaryAcl) {
    $list += ('{0}|{1:X8}|{2}|{3}|{4}|{5}' -f $ace.AceType, $ace.AccessMask, $ace.AceFlags, $ace.InheritanceFlags, $ace.PropagationFlags, $ace.SecurityIdentifier.Value)
  }
  return @($list | Sort-Object)
}

function Test-ArcIconsDaclProtected([string]$FullSddl) {
  return (New-Object System.Security.AccessControl.RawSecurityDescriptor($FullSddl)).AreAccessRulesProtected
}

function Get-ArcIconsHardlinkTargets([string]$LiteralPath) {
  $raw = & fsutil.exe hardlink list $LiteralPath 2>&1
  if ($LASTEXITCODE -ne 0) { return @() }
  $canon = [IO.Path]::GetFullPath($LiteralPath)
  $drive = ([IO.Path]::GetPathRoot($canon)).TrimEnd('\')
  $out = @()
  foreach ($line in @($raw | ForEach-Object { "$_".Trim() })) {
    if (-not $line) { continue }
    $t = $line
    if ($t.StartsWith('\') -and -not $t.StartsWith('\\')) { $t = $drive + $t }
    if (-not ($t.StartsWith('\\') -or [IO.Path]::IsPathRooted($t))) { continue }
    try { $t = [IO.Path]::GetFullPath($t) } catch { continue }
    $out += $t
  }
  return @($out | Sort-Object -Unique)
}

# STRICT attribution: only a target inside a WinSxS component directory counts.
# An ordinary hardlink (e.g. a user's own copy) is NOT evidence that the live
# file came from an OS component, so it is never returned as a fallback.
function Get-ArcIconsWinSxSSibling([string]$LiteralPath, [string[]]$Targets) {
  $canon = [IO.Path]::GetFullPath($LiteralPath)
  $others = @($Targets | Where-Object { $_ -ine $canon })
  if ($others.Count -eq 0) { return $null }
  $winsxs = @($others | Where-Object { $_ -like '*\WinSxS\*' })
  if ($winsxs.Count -eq 0) { return $null }
  return $winsxs[0]
}

function Acquire-ArcIconsLock([string]$LogsDir, [int]$TimeoutSec = 90) {
  $lock = Join-Path $LogsDir 'ArcIcons.lock'
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ($true) {
    try {
      $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try {
        $bytes = [Text.Encoding]::UTF8.GetBytes("pid=$PID ts=$([DateTime]::UtcNow.ToString('o'))")
        $fs.Write($bytes, 0, $bytes.Length)
      } finally { $fs.Close() }
      return $lock
    } catch [IO.IOException] {
      $stale = $false
      try {
        $age = (Get-Item -LiteralPath $lock).LastWriteTimeUtc
        if ((((Get-Date).ToUniversalTime() - $age).TotalSeconds) -gt 600) { $stale = $true }
      } catch { }
      if ($stale) {
        try { Remove-Item -Force -LiteralPath $lock } catch { }
        continue
      }
      if ((Get-Date) -gt $deadline) {
        throw "could not acquire $lock within ${TimeoutSec}s (held by another apply/restore/repair run)."
      }
      Start-Sleep -Seconds 1
    }
  }
}

function Release-ArcIconsLock([string]$LogsDir) {
  Remove-Item -Force -LiteralPath (Join-Path $LogsDir 'ArcIcons.lock') -ErrorAction SilentlyContinue
}

function Write-ArcIconsJournal([string]$LogsDir, [string]$FileName, $Entry) {
  if (-not (Test-Path -LiteralPath $LogsDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
  }
  ($Entry | ConvertTo-Json -Depth 5 -Compress) | Add-Content -Encoding utf8 -LiteralPath (Join-Path $LogsDir $FileName)
}

# ---- Measured live mechanism (see README): holders, directory ACL, icon cache ----
# A live file mapped by a running process cannot be deleted (share lock, not ACL).
# Holders are found with the Restart Manager API (measured: imageres.dll.mun is
# typically held by explorer and a RuntimeBroker).

function Get-ArcIconsHoldersInProcess([string[]]$Paths) {
  # Raw Restart Manager query. Runs in a CHILD process (see Get-ArcIconsHolders):
  # a native interop fault here must never take down the caller.
  if (-not ([System.Management.Automation.PSTypeName]'ArcIconsRM').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ArcIconsRM {
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] static extern int RmStartSession(out uint h, int f, string k);
    [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint h);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] static extern int RmRegisterResources(uint h, uint n, string[] f, uint a, IntPtr ap, uint s, string[] sn);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint needed, ref uint count, [In,Out] RMPI[] arr, ref uint reasons);
    [StructLayout(LayoutKind.Sequential, Pack=4)] struct RUP { public int pid; public uint ftLow; public uint ftHigh; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode, Pack=4)] struct RMPI { public RUP proc; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string app; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string svc; public int type; public uint status; public uint sess; [MarshalAs(UnmanagedType.Bool)] public bool restart; }
    public static int[] Holders(string[] files) {
        uint h; if (RmStartSession(out h, 0, Guid.NewGuid().ToString()) != 0) return new int[0];
        try {
            if (RmRegisterResources(h, (uint)files.Length, files, 0, IntPtr.Zero, 0, null) != 0) return new int[0];
            uint need = 0, cnt = 0, r = 0;
            RmGetList(h, out need, ref cnt, null, ref r);
            if (need == 0) return new int[0];
            var arr = new RMPI[need]; cnt = need;
            RmGetList(h, out need, ref cnt, arr, ref r);
            var pids = new List<int>();
            for (int i = 0; i < cnt; i++) pids.Add(arr[i].proc.pid);
            return pids.ToArray();
        } finally { RmEndSession(h); }
    }
}
'@
  }
  return @([ArcIconsRM]::Holders($Paths))
}

function Get-ArcIconsHolders([string[]]$Paths) {
  # Child-process isolation: the Restart Manager interop runs in a fresh host
  # with a timeout, so a native fault returns "holders unknown" instead of
  # crashing apply/restore/repair. Returns int PIDs (possibly empty).
  $tmp = $null
  try {
    $lib = Join-Path $PSScriptRoot 'Set-BaselineSecurity.ps1'
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $quoted = @($Paths | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" })
    $script = ". '" + ($lib -replace "'", "''") + "'`r`nGet-ArcIconsHoldersInProcess -Paths @(" + ($quoted -join ', ') + ") | ForEach-Object { [int]`$_ }`r`n"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ArcIconsHolders_{0}_{1}.ps1" -f $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    [System.IO.File]::WriteAllText($tmp, $script, [System.Text.Encoding]::UTF8)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $tmp + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $pr = [System.Diagnostics.Process]::Start($psi)
    if (-not $pr.WaitForExit(30000)) { try { $pr.Kill() } catch { }; return @() }
    if ($pr.ExitCode -ne 0) { return @() }
    $out = $pr.StandardOutput.ReadToEnd()
    $pids = @()
    foreach ($line in @($out -split "`r?`n")) {
      $t = "$line".Trim()
      $n = 0
      if ([int]::TryParse($t, [ref]$n)) { $pids += $n }
    }
    return @($pids)
  } catch { return @() }
  finally { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue } }
}

function Test-ArcIconsLocked([string]$LiteralPath) {
  # A share lock (file mapped/open elsewhere) is an IOException; an ACL denial is NOT a lock.
  try { $f = [System.IO.File]::Open($LiteralPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None); $f.Close(); return $false }
  catch [System.IO.IOException] { return $true }
  catch { return $false }
}

function Get-ArcIconsHolderNames([int[]]$Pids) {
  $names = @()
  foreach ($id in @($Pids)) {
    $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($pr) { $names += ("{0}({1})" -f $pr.ProcessName, $id) }
    else { $names += ("pid({0})" -f $id) }
  }
  return $names
}

# Directory ACL cycle (measured): Administrators hold only read+execute on
# C:\Windows\SystemResources, so creating/deleting a NAME there is denied and
# SeRestorePrivilege does NOT bypass it. The working sequence takes ownership of
# the DIRECTORY + grants Administrators:F (baseline saved at
# originals\acl\SystemResources.dir.sddl, D:PAI) and restores it in a finally.
# For a non-live -SystemResourceDir (sandbox proof) the current SDDL is captured
# as the baseline and restored the same way.
function Resolve-ArcIconsDirBaselineSddl([string]$SysDir, [string]$RootC) {
  $liveDefault = Resolve-ArcIconsCanonicalPath (Join-Path $env:SystemRoot 'SystemResources')
  if ($SysDir -ieq $liveDefault) {
    $f = Join-Path $RootC 'originals\acl\SystemResources.dir.sddl'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "directory baseline SDDL missing: $f" }
    return ((Get-Content -Raw -LiteralPath $f).Trim())
  }
  return (Get-Acl -LiteralPath $SysDir).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
}

function Take-ArcIconsDirAcl([string]$SysDir) {
  & takeown.exe /f $SysDir | Out-Null
  if ($LASTEXITCODE -ne 0) { throw ("directory takeown failed for {0} (exit {1})." -f $SysDir, $LASTEXITCODE) }
  & icacls.exe $SysDir /grant '*S-1-5-32-544:F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw ("directory icacls grant failed for {0} (exit {1})." -f $SysDir, $LASTEXITCODE) }
}

# Restores the directory baseline WITHOUT throwing: the directory baseline is
# D:PAI and the AI (auto-inherited) bit cannot be reproduced by the write, so an
# access-neutral control-bit difference is reported (exact=$false + aceMatch) and
# NOT hidden, instead of failing the run. Returns a psobject {After, Exact, AceMatch, Note}.
function Restore-ArcIconsDirAcl([string]$SysDir, [string]$BaselineSddl) {
  Enable-ArcIconsPrivileges | Out-Null
  Ensure-ArcIconsNativeSD
  try { [ArcIconsNativeSD]::Apply($SysDir, $BaselineSddl) }
  catch {
    return [pscustomobject]@{ After = '<write-failed>'; Exact = $false; AceMatch = $false; Note = ("restore write failed: {0}" -f $_) }
  }
  $after = (Get-Acl -LiteralPath $SysDir).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
  $exact = ($after -ceq $BaselineSddl)
  $aceMatch = $false
  $note = ''
  if (-not $exact) {
    try {
      $bD = $BaselineSddl.Substring($BaselineSddl.IndexOf('D:'))
      $aD = $after.Substring($after.IndexOf('D:'))
      $bd = @(Get-ArcIconsAceSet $bD); $ad = @(Get-ArcIconsAceSet $aD)
      $diff = @(Compare-Object $bd $ad)
      $aceMatch = ($diff.Count -eq 0)
      $note = ("control-flag difference only: baseline [{0}] vs now [{1}]; ACE set identical={2}" -f (($BaselineSddl -split '\(')[0], ($after -split '\(')[0], $aceMatch))
    } catch { $note = ("SDDL differs and ACE compare failed: {0}" -f $_) }
  }
  return [pscustomobject]@{ After = $after; Exact = $exact; AceMatch = $aceMatch; Note = $note }
}

# ---- shell guarantee (owner requirement, 2026-10-14) ----
# The icon-cache refresh stops explorer.exe, so every script that can reach it
# must be able to put the shell back. MEASURED 2026-10-14: Winlogon's
# AutoRestartShell=1 did NOT bring explorer back after the forced stop in the
# 03:53 apply (explorer_count=0 until an out-of-band restart) — so the restart
# is explicit, verified and retried, never assumed. The old note claimed
# "explorer restarted" while only ever stopping it.
function Test-ArcIconsInteractiveSession([int]$SessionId) {
  # session 0 = services/SYSTEM: it cannot paint a user's desktop.
  return ($SessionId -ne 0)
}

function Start-ArcIconsExplorer([int]$TimeoutSec = 20) {
  $exe = Join-Path $env:SystemRoot 'explorer.exe'
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    if (@(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count -gt 0) { break }
    try { Start-Process -FilePath $exe -ErrorAction Stop } catch { }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (((@(Get-Process -Name explorer -ErrorAction SilentlyContinue)).Count -eq 0) -and ((Get-Date) -lt $deadline)) {
      Start-Sleep -Milliseconds 250
    }
  }
  $p = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Sort-Object Id)
  if ($p.Count -eq 0) {
    return [pscustomobject]@{ Running = $false; Pids = @(); Note = ("explorer.exe STILL NOT RUNNING after 2 x {0}s" -f $TimeoutSec) }
  }
  $ids = @($p | ForEach-Object { $_.Id })
  $sess = @($p | ForEach-Object { $_.SessionId } | Sort-Object -Unique)
  return [pscustomobject]@{ Running = $true; Pids = $ids; Note = ("explorer running pid(s)=" + ($ids -join ',') + " session(s)=" + ($sess -join ',')) }
}

# Safe on EVERY exit path — success, failure, refusal, interrupt: it acts only
# when the shell is actually down, and reports what it saw either way.
function Restore-ArcIconsShell([string]$Where) {
  $p = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
  if ($p.Count -gt 0) {
    return ("shell guard [{0}]: explorer already running pid(s)={1} session(s)={2}" -f $Where, (@($p | ForEach-Object { $_.Id }) -join ','), (@($p | ForEach-Object { $_.SessionId } | Sort-Object -Unique) -join ','))
  }
  if (-not (Test-ArcIconsInteractiveSession (Get-Process -Id $PID).SessionId)) {
    # A session-0 start would create a session-0 explorer while the user's
    # desktop stays down — worse than useless. Say so instead of faking a pass.
    $msg = ("shell guard [{0}]: explorer.exe is NOT running and this process is in session 0; a session-0 start cannot restore the desktop — restart the shell in the interactive session." -f $Where)
    [Console]::Error.WriteLine($msg)
    return $msg
  }
  $r = Start-ArcIconsExplorer
  $msg = ("shell guard [{0}]: {1}" -f $Where, $r.Note)
  # Write-Host, not Write-Output: the guard must stay visible on a caller that
  # discards the return value ([void]) — the message IS the receipt.
  if (-not $r.Running) { [Console]::Error.WriteLine($msg) } else { Write-Host $msg }
  return $msg
}

# Icon-cache refresh (measured): ie4uinit.exe -show alone is NOT enough — the
# shell keeps painting the old icons until %LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache*.db
# is deleted and explorer restarts. Skipped automatically for a non-live
# -SystemResourceDir (sandbox proof must never touch the real shell) and with -SkipIconCacheRefresh.
# Stop + start is ONE guarded unit, and the returned note carries the explorer
# pid(s) that came back, so the caller can prove the shell is up.
function Invoke-ArcIconsIconCacheRefresh([string]$SysDir, [bool]$Skip) {
  $liveDefault = Resolve-ArcIconsCanonicalPath (Join-Path $env:SystemRoot 'SystemResources')
  if ($SysDir -ine $liveDefault) { return 'skipped (non-live SystemResourceDir; shell untouched)' }
  if ($Skip) { return 'skipped (-SkipIconCacheRefresh)' }
  if (-not (Test-ArcIconsInteractiveSession (Get-Process -Id $PID).SessionId)) {
    # the auto-repair task runs apply as SYSTEM: never stop a shell that a
    # session-0 process cannot put back.
    return 'skipped (session 0: a non-interactive process must not stop a shell it cannot restore)'
  }
  $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
  $deleted = @()
  try {
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'iconcache*.db' -File -ErrorAction SilentlyContinue)) {
      try { Remove-Item -Force -LiteralPath $f.FullName -ErrorAction Stop; $deleted += $f.Name } catch { }
    }
  } catch { }
  try { & ie4uinit.exe -show 2>$null | Out-Null } catch { }
  $stopped = $false
  try { Stop-Process -Name explorer -Force -ErrorAction Stop; $stopped = $true; Start-Sleep -Seconds 2 } catch { }
  $shell = Start-ArcIconsExplorer
  return ("iconcache deleted=[{0}]; explorer stopped={1}; {2}" -f ($deleted -join ','), $stopped, $shell.Note)
}
