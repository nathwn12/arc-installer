<#
.SYNOPSIS
  Build ArcInstaller.exe - stage the tooling + theme, embed payload.zip, compile the winexe.

.DESCRIPTION
  Stages every file the installer ships, zips them to staging\payload.zip, and
  compiles the single-file winexe with payload.zip embedded as a resource.

  -Root defaults to this script's own directory (the repository root, which holds
  the tooling at the root, bin\, docs\ and theme\). Point it at another tree with
  the same layout to build from there.

  Run this from Windows PowerShell 5.1: csc argument quoting on PowerShell 7
  mangles the /resource: path.

.PARAMETER Root
  The tree to stage from. Defaults to the directory holding this script.
#>
[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'

$here        = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = $here }   # derived here, not as a param default: $PSScriptRoot is not reliable in a param block
$StageRoot   = Join-Path $here 'staging'
$StageFiles  = Join-Path $StageRoot 'files'
$ZipPath     = Join-Path $StageRoot 'payload.zip'
$SrcDir      = Join-Path $here 'src'
$DistDir     = Join-Path $here 'dist'
$IconPath    = Join-Path $here 'icon\ArcInstaller.ico'
$ManifestPath= Join-Path $SrcDir 'app.manifest'
$CsPath      = Join-Path $SrcDir 'ArcInstaller.cs'
$OutExe      = Join-Path $DistDir 'ArcInstaller.exe'
$csc         = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "missing -Root $Root" }
if (-not (Test-Path -LiteralPath $CsPath -PathType Leaf)) { throw "missing $CsPath" }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "missing $ManifestPath" }
if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) { throw "missing $IconPath" }
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw "missing csc $csc" }
if (-not (Test-Path -LiteralPath (Join-Path $Root 'theme') -PathType Container)) { throw "missing $Root\theme - run fetch-theme.ps1 first" }

foreach ($d in @($StageRoot, $StageFiles, $DistDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
if (Test-Path -LiteralPath $StageFiles) { Get-ChildItem -LiteralPath $StageFiles -Force | Remove-Item -Recurse -Force }
if (Test-Path -LiteralPath $ZipPath) { Remove-Item -Force -LiteralPath $ZipPath }

function Copy-Rel([string]$srcFull, [string]$rel) {
  $dest = Join-Path $StageFiles $rel
  $dd = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $dd -PathType Container)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
  Copy-Item -LiteralPath $srcFull -Destination $dest -Force
}

# tooling: root scripts, then bin\
$rootFiles = Get-ChildItem -Path (Join-Path $Root '*') -Include '*.ps1','*.cmd' -File | Where-Object { $_.Name -ne 'fetch-theme.ps1' -and $_.Name -ne 'build.ps1' }
foreach ($f in $rootFiles) { Copy-Rel $f.FullName $f.Name }
Write-Host "staged root: $(@($rootFiles).Count)"
Write-Host ("  root: " + ((@($rootFiles) | ForEach-Object { $_.Name } | Sort-Object) -join ', '))

# Superseded measured reference: documented in AGENTS.md and docs\REPAIR-MANUAL.md
# as never executed (apply.ps1 replaced them). They stay in the repo for history
# but are not staged into the shipped payload.
$binExcluded = @('Live-Install.ps1', 'Finalize-Security.ps1')
$binFiles = Get-ChildItem -Path (Join-Path $Root 'bin\*.ps1') -File |
  Where-Object { $binExcluded -notcontains $_.Name }
foreach ($f in $binFiles) { Copy-Rel $f.FullName (Join-Path 'bin' $f.Name) }
$binSkipped = @($binExcluded | Where-Object { Test-Path -LiteralPath (Join-Path $Root ('bin\{0}' -f $_)) }).Count
Write-Host "staged bin: $(@($binFiles).Count) (excluded $binSkipped superseded: $($binExcluded -join ', '))"
Write-Host ("  bin: " + ((@($binFiles) | ForEach-Object { $_.Name } | Sort-Object) -join ', '))

# payload docs: docs\<name> when present, else <name> at the root
$docMap = @(
  [pscustomobject]@{ Src = 'REPAIR-MANUAL.md';  Dest = 'README.md' }
  [pscustomobject]@{ Src = 'WHERE-IT-LIVES.md'; Dest = 'WHERE-IT-LIVES.md' }
)
foreach ($m in $docMap) {
  $cand = @((Join-Path $Root "docs\$($m.Src)"), (Join-Path $Root $m.Dest)) |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (-not $cand) { throw "missing payload doc '$($m.Dest)' (looked for docs\$($m.Src) and $($m.Dest) under $Root)" }
  Copy-Rel $cand $m.Dest
}
Write-Host "staged docs: $($docMap.Count)"

# theme (never the archives)
$themeRoot = Join-Path $Root 'theme'
$themeFiles = Get-ChildItem -LiteralPath $themeRoot -Recurse -File | Where-Object { $_.Extension -ne '.zip' }
foreach ($f in $themeFiles) {
  $rel = $f.FullName.Substring($Root.Length + 1)
  Copy-Rel $f.FullName $rel
}
Write-Host "staged theme (skip zip): $(@($themeFiles).Count)"

$total = (Get-ChildItem -LiteralPath $StageFiles -Recurse -File).Count
Write-Host "staged total files: $total"
if ($total -eq 0) { throw "nothing staged under $StageFiles - refusing to ship an empty payload" }

# payload manifest: rel path (forward slashes) + sha256 for every staged file.
# Embedded as payload-manifest.json so --selftest can verify hashes, not just
# extraction. The manifest lists every file EXCEPT itself (it cannot hash
# itself before it is written).
$manFiles = Get-ChildItem -LiteralPath $StageFiles -Recurse -File | Sort-Object FullName
$manRows = foreach ($f in $manFiles) {
  $rel = $f.FullName.Substring($StageFiles.Length + 1) -replace '\\', '/'
  [pscustomobject]@{ path = $rel; sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
}
$manifest = [pscustomobject]@{
  generated = (Get-Date).ToString('o')
  files = @($manRows)
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $StageFiles 'payload-manifest.json') -Encoding utf8
Write-Host ("payload-manifest.json: {0} file(s) recorded" -f @($manRows).Count)

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($StageFiles, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
$zipSize = (Get-Item -LiteralPath $ZipPath).Length
Write-Host "payload.zip: $zipSize bytes"

if (Test-Path -LiteralPath $OutExe) { Remove-Item -Force -LiteralPath $OutExe }
& $csc /nologo /optimize+ /target:winexe "/out:$OutExe" "/win32icon:$IconPath" "/win32manifest:$ManifestPath" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Core.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /resource:"$ZipPath",payload.zip "$CsPath"
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

$exeItem = Get-Item -LiteralPath $OutExe
$exeHash = (Get-FileHash -LiteralPath $OutExe -Algorithm SHA256).Hash
Write-Host ("dist ArcInstaller.exe: {0} bytes sha256={1}" -f $exeItem.Length, $exeHash)
