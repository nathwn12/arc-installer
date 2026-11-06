# Test-VariantParity.ps1 — the variant table is triple-duplicated by design
# (ARC-Icons.ps1 $Variants, bin\Merge-IconTheme.ps1 $VariantTable,
# bin\Set-BaselineSecurity.ps1 Get-ArcIconsVariantInfo); this test pins all
# three to the same ids + ThemeDir mapping. Windows PowerShell 5.1 compatible,
# no new dependencies. Run: powershell -NoProfile -File tests\Test-VariantParity.ps1
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$ExpectedIds = @('arc', 'arc-symbolic', 'neutral-brown', 'neutral-grey', 'dark-grey')
$ExpectedDirs = @{
  'arc'           = 'Windhawk Resources'
  'arc-symbolic'  = 'ARC Symbolic\Windhawk Resources'
  'neutral-brown' = 'Arc Neutral Brown\Windhawk Resources'
  'neutral-grey'  = 'Arc Neutral Grey\Windhawk Resources'
  'dark-grey'     = 'Arc Dark Grey\Windhawk Resources'
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
  $a = (@($Actual) | ForEach-Object { "$_" }) -join "`0"
  $e = (@($Expected) | ForEach-Object { "$_" }) -join "`0"
  if ($a -cne $e) {
    throw ("{0}: expected [{1}], got [{2}]" -f $Message, ((@($Expected)) -join ', '), ((@($Actual)) -join ', '))
  }
}

# Read the two literal tables out of the file text (no execution: ARC-Icons.ps1
# self-elevates and Merge-IconTheme.ps1 merges on load-args, so regex, not run).
function Get-VariantTableFromFile([string]$Path) {
  $text = Get-Content -LiteralPath $Path -Raw
  $rows = [ordered]@{}
  $re = [regex]"(?m)^\s*'([^']+)'\s*=\s*\[pscustomobject\]@\{[^}\r\n]*ThemeDir\s*=\s*'([^']+)'"
  foreach ($m in $re.Matches($text)) {
    $rows[$m.Groups[1].Value] = $m.Groups[2].Value
  }
  return $rows
}

$ui = Get-VariantTableFromFile (Join-Path $Root 'ARC-Icons.ps1')
$merge = Get-VariantTableFromFile (Join-Path $Root 'bin\Merge-IconTheme.ps1')

Assert-Equal @($ui.Keys) $ExpectedIds 'ARC-Icons.ps1 $Variants ids'
Assert-Equal @($merge.Keys) $ExpectedIds 'Merge-IconTheme.ps1 $VariantTable ids'
foreach ($id in $ExpectedIds) {
  Assert-Equal $ui[$id] $ExpectedDirs[$id] ("ARC-Icons.ps1 ThemeDir for '{0}'" -f $id)
  Assert-Equal $merge[$id] $ExpectedDirs[$id] ("Merge-IconTheme.ps1 ThemeDir for '{0}'" -f $id)
}

# The function source of truth: dot-source is side-effect free by file header.
. (Join-Path $Root 'bin\Set-BaselineSecurity.ps1')
foreach ($id in $ExpectedIds) {
  $v = Get-ArcIconsVariantInfo $id
  if ($null -eq $v) { throw ("Get-ArcIconsVariantInfo returned null for '{0}'." -f $id) }
  Assert-Equal $v.Id $id ("Get-ArcIconsVariantInfo Id for '{0}'" -f $id)
  Assert-Equal $v.ThemeDir $ExpectedDirs[$id] ("Get-ArcIconsVariantInfo ThemeDir for '{0}'" -f $id)
}
if ($null -ne (Get-ArcIconsVariantInfo 'not-a-variant')) { throw 'Get-ArcIconsVariantInfo must return null for an unknown name.' }

# Presence: on a fetched tree every variant must have its three payload files.
# A clone has no theme\ at all (gitignored); that is not a parity failure.
$themeRoot = Join-Path $Root 'theme'
if (Test-Path -LiteralPath $themeRoot -PathType Container) {
  foreach ($id in $ExpectedIds) {
    $dir = Join-Path $themeRoot $ExpectedDirs[$id]
    foreach ($f in @('imageres.dll', 'imagesp1.dll', 'zipfldr.dll')) {
      if (-not (Test-Path -LiteralPath (Join-Path $dir $f) -PathType Leaf)) {
        throw ("variant '{0}' is listed but theme\{1}\{2} is missing" -f $id, $ExpectedDirs[$id], $f)
      }
    }
  }
}

Write-Output ('VARIANT-PARITY: PASS (ARC-Icons.ps1, Merge-IconTheme.ps1, Get-ArcIconsVariantInfo agree on {0} ids + ThemeDir; theme payloads present)' -f $ExpectedIds.Count)
