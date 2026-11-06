<#
.SYNOPSIS
  Fetch the ARC icon packs from upstream and build the local theme tree.

.DESCRIPTION
  ArcInstaller's payload embeds the ARC icon packs, which are niivu's work
  (https://github.com/niivu/resource-redirect-icon-themes). They are NOT
  redistributed in this repository, so the build fetches them here and verifies
  every archive against a pinned SHA-256 before extracting anything.

  Arc Dark Grey is not published upstream. It is derived on this machine from
  Arc Neutral Grey by bin\Recolor-IconTheme.ps1 - an RGB multiply with k = 0.55
  and a per-GROUP mean-luminance floor of 64 (one kEff per RT_GROUP_ICON across
  all its sizes) - so the four base variants are fetched and this one is
  generated. See docs\arc-dark-grey-variant.md.

  Resulting layout, all under .\theme:

    Windhawk Resources\     <- ARC.zip                  (the base variant)
    Extra\Preview.png       <- ARC.zip
    theme.ini               <- ARC.zip
    ARC Symbolic\           <- ARC Symbolic.zip        (official symbolic set)
    Arc Neutral Brown\      <- arc-neutral brown.zip
    Arc Neutral Grey\       <- arc-neutral grey.zip
    Arc Dark Grey\          <- generated here from Arc Neutral Grey

  Re-running is cheap: an archive already on disk with the right hash is reused.

.PARAMETER Force
  Re-download even when a verified archive is already cached.

.EXAMPLE
  pwsh -File .\fetch-theme.ps1
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Root     = $PSScriptRoot
$ThemeDir = Join-Path $Root 'theme'
$CacheDir = Join-Path $Root 'staging\theme-cache'
$PacksUrl = 'https://raw.githubusercontent.com/niivu/resource-redirect-icon-themes/main/Resource%20Redirect%20themes'

# Pinned upstream archives. Verified 2026-10-14 against the live upstream files;
# ARC Symbolic.zip re-verified 2026-11-06 (same upstream commit family).
$Packs = @(
  [pscustomobject]@{
    Name    = 'ARC.zip'
    Url     = "$PacksUrl/ARC.zip"
    Sha256  = '9C696FE24AA6216B23CBED91767474DDA91AE28D8D2A06E9E79D60C739EE4CE0'
    Inner   = 'ARC'
    Dest    = ''            # contents land in the theme root
  }
  [pscustomobject]@{
    Name    = 'ARC Symbolic.zip'
    Url     = "$PacksUrl/ARC%20Symbolic.zip"
    Sha256  = '78C0981740DBBCD5224EFFBA1085C8D5195EC9BB4AC6FEC2598577567FD76AD7'
    Inner   = 'ARC Symbolic'
    Dest    = 'ARC Symbolic'
  }
  [pscustomobject]@{
    Name    = 'arc-neutral-brown.zip'
    Url     = "$PacksUrl/arc-neutral%20brown.zip"
    Sha256  = 'D9F7C6D72C030A3847CDF646789B28C632D64216A643A7E8A096E1FC222DA112'
    Inner   = 'arc-neutral brown'
    Dest    = 'Arc Neutral Brown'
  }
  [pscustomobject]@{
    Name    = 'arc-neutral-grey.zip'
    Url     = "$PacksUrl/arc-neutral%20grey.zip"
    Sha256  = '2887D18111CC8BC70FE89CC35B89EF24448576E553DD5AB47CA9EAE91D42DB8E'
    Inner   = 'arc-neutral grey'
    Dest    = 'Arc Neutral Grey'
  }
)

foreach ($d in @($ThemeDir, $CacheDir)) {
  if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

foreach ($pack in $Packs) {
  $zip = Join-Path $CacheDir $pack.Name
  $have = (Test-Path -LiteralPath $zip -PathType Leaf) -and ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -eq $pack.Sha256)
  if (-not $have -or $Force) {
    Write-Host "download $($pack.Name)"
    Invoke-WebRequest -Uri $pack.Url -OutFile $zip -UseBasicParsing
  } else {
    Write-Host "cached   $($pack.Name)"
  }
  $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
  if ($got -ne $pack.Sha256) {
    throw "$($pack.Name): SHA-256 mismatch - expected $($pack.Sha256), got $got. Upstream may have changed; re-pin deliberately, do not skip the check."
  }

  $tmp = Join-Path $CacheDir ('x-' + $pack.Name)
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
  [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
  $inner = Join-Path $tmp $pack.Inner
  if (-not (Test-Path -LiteralPath $inner -PathType Container)) { throw "$($pack.Name): expected top-level folder '$($pack.Inner)'" }

  $dest = if ($pack.Dest) { Join-Path $ThemeDir $pack.Dest } else { $ThemeDir }
  if (-not (Test-Path -LiteralPath $dest -PathType Container)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
  Copy-Item -Path (Join-Path $inner '*') -Destination $dest -Recurse -Force
  Remove-Item -LiteralPath $tmp -Recurse -Force
  Write-Host "extract  $($pack.Name) -> theme\$($pack.Dest)"
}

# --- Arc Dark Grey: derived locally, never downloaded -------------------------
$greySrc  = Join-Path $ThemeDir 'Arc Neutral Grey\Windhawk Resources'
$darkDir  = Join-Path $ThemeDir 'Arc Dark Grey\Windhawk Resources'
if (-not (Test-Path -LiteralPath $greySrc -PathType Container)) { throw "missing $greySrc - the neutral grey pack did not extract" }
if (-not (Test-Path -LiteralPath $darkDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $darkDir | Out-Null }

$hostExe  = (Get-Process -Id $PID).Path
$recolor  = Join-Path $Root 'bin\Recolor-IconTheme.ps1'
$recolorK = 0.55
$recolorFloor = 64
foreach ($f in @('zipfldr.dll', 'imagesp1.dll', 'imageres.dll')) {
  Write-Host "recolor  $f"
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $recolor `
      -Source (Join-Path $greySrc $f) -Dest (Join-Path $darkDir $f) -K $recolorK -Floor $recolorFloor
  if ($LASTEXITCODE -ne 0) { throw "Recolor-IconTheme.ps1 failed for $f (exit $LASTEXITCODE)" }
}
Copy-Item -LiteralPath (Join-Path $ThemeDir 'Arc Neutral Grey\theme.ini') -Destination (Join-Path $ThemeDir 'Arc Dark Grey\theme.ini') -Force

# Preview sheet: the neutral packs ship niivu's marketing PNG; a generated
# variant gets one drawn from its own recolored payload (never a dyed copy of
# the source sheet, which would darken the background and stay misleading).
$previewGen = Join-Path $Root 'bin\New-IconThemePreview.ps1'
$darkPreview = Join-Path $ThemeDir 'Arc Dark Grey\Extra\preview.png'
Write-Host 'preview  Arc Dark Grey'
& $hostExe -NoProfile -ExecutionPolicy Bypass -File $previewGen `
    -Source $darkDir -Dest $darkPreview -Title 'Arc Dark Grey' `
    -Note ("derived from Arc Neutral Grey - k={0}, per-GROUP luminance floor {1}" -f $recolorK, $recolorFloor)
if ($LASTEXITCODE -ne 0) { throw "New-IconThemePreview.ps1 failed (exit $LASTEXITCODE)" }

Copy-Item -LiteralPath (Join-Path $Root 'docs\arc-dark-grey-variant.md') -Destination (Join-Path $ThemeDir 'Arc Dark Grey\NOTES.md') -Force

# --- fetch provenance: what was pinned, when ---------------------------------
# theme\source.json records the fetch this tree came from so a later merge or
# audit can re-check it. Overwritten on every fetch run (fetch-time fact, not
# a versioned artifact).
$shaMap = [ordered]@{}
$urlList = @()
foreach ($pack in $Packs) {
  $shaMap[$pack.Name] = $pack.Sha256
  $urlList += $pack.Url
}
$sourceJson = [ordered]@{
  repo      = 'https://github.com/niivu/resource-redirect-icon-themes'
  urls      = $urlList
  sha256    = $shaMap
  fetchedAt = (Get-Date).ToString('o')
}
$sourceJson | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ThemeDir 'source.json') -Encoding utf8
Write-Host 'provenance theme\source.json'

# --- report -------------------------------------------------------------------
Write-Host ''
Write-Host 'theme tree:'
$expected = @(
  'theme.ini',
  'Windhawk Resources\imageres.dll', 'Windhawk Resources\imagesp1.dll', 'Windhawk Resources\zipfldr.dll',
  'Extra\Preview.png',
  'ARC Symbolic\theme.ini',
  'ARC Symbolic\Windhawk Resources\imageres.dll', 'ARC Symbolic\Windhawk Resources\imagesp1.dll', 'ARC Symbolic\Windhawk Resources\zipfldr.dll',
  'ARC Symbolic\Extra\Preview.png',
  'Arc Neutral Brown\theme.ini',
  'Arc Neutral Brown\Windhawk Resources\imageres.dll', 'Arc Neutral Brown\Windhawk Resources\imagesp1.dll', 'Arc Neutral Brown\Windhawk Resources\zipfldr.dll',
  'Arc Neutral Brown\Extra\preview.png',
  'Arc Neutral Grey\theme.ini',
  'Arc Neutral Grey\Windhawk Resources\imageres.dll', 'Arc Neutral Grey\Windhawk Resources\imagesp1.dll', 'Arc Neutral Grey\Windhawk Resources\zipfldr.dll',
  'Arc Neutral Grey\Extra\preview.png',
  'Arc Dark Grey\theme.ini', 'Arc Dark Grey\NOTES.md',
  'Arc Dark Grey\Windhawk Resources\imageres.dll', 'Arc Dark Grey\Windhawk Resources\imagesp1.dll', 'Arc Dark Grey\Windhawk Resources\zipfldr.dll',
  'Arc Dark Grey\Extra\preview.png'
)
$missing = @()
foreach ($rel in $expected) {
  $p = Join-Path $ThemeDir $rel
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    Write-Host ("  {0,-52} {1,12} B" -f $rel, (Get-Item -LiteralPath $p).Length)
  } else {
    $missing += $rel
    Write-Host ("  {0,-52} MISSING" -f $rel)
  }
}
if ($missing.Count -gt 0) { throw "$($missing.Count) expected theme file(s) missing - the build would embed an incomplete payload." }
Write-Host ''
Write-Host "ARC-THEME-FETCH: PASS ($($expected.Count)/$($expected.Count) files)"
