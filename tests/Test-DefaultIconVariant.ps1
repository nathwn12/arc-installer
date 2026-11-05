$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\bin\Default-IconVariant.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    $actualText = (@($Actual) -join "`0")
    $expectedText = (@($Expected) -join "`0")
    if ($actualText -cne $expectedText) {
        throw ("{0}: expected [{1}], got [{2}]" -f $Message, (@($Expected) -join ', '), (@($Actual) -join ', '))
    }
}

Assert-Equal (Get-ArcIconsDefaultVariant '' $false '') 'dark-grey' 'fresh default'
Assert-Equal (Get-ArcIconsDefaultVariant 'neutral-grey' $true 'dark-grey') 'neutral-grey' 'explicit selection'
Assert-Equal (Get-ArcIconsDefaultVariant 'dark-grey' $false 'neutral-brown') 'neutral-brown' 'installed variant precedence'
Assert-Equal (Get-ArcIconsApplyVariantArguments 'dark-grey') @('-Variant', 'dark-grey') 'apply argument'

$apply = Join-Path $PSScriptRoot '..\apply.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($apply, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$variant = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Variant' }
if (-not $variant -or $variant.DefaultValue.Extent.Text -ne "'dark-grey'") {
    throw 'Standalone apply default is not dark-grey.'
}

Write-Output 'DEFAULT-ICON-VARIANT: PASS (fresh, explicit, installed, and apply-argument selection)'
