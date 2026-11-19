[CmdletBinding()]
param([string]$Variant = 'A')

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = @(
  (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
  (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'csc.exe not found under $env:SystemRoot\Microsoft.NET\{Framework64,Framework}\v4.0.30319 (no .NET Framework C# compiler on this machine).' }
$tools = Join-Path $here 'tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null

$exe = Join-Path $tools 'IconForge.exe'
& $csc /nologo /optimize+ /target:exe "/out:$exe" `
    /reference:System.Drawing.dll `
    (Join-Path $here 'src\IconForge.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

& $exe candidates $here
& $exe build $here $Variant
& $exe enum (Join-Path $here 'ArcInstaller.ico')
& $exe analyze (Join-Path $here 'icon-256.png')
& $exe analyze (Join-Path $here 'icon-32.png')
& $exe analyze (Join-Path $here 'icon-16-zoom8x.png')

Get-ChildItem $here -Recurse -File | Where-Object { $_.Extension -in '.ico', '.png' } |
    Sort-Object FullName |
    ForEach-Object {
        '{0}  {1,8}  {2}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.Length, $_.FullName
    }
