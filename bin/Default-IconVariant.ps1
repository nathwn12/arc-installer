function Get-ArcIconsDefaultVariant([string]$Requested, [bool]$WasExplicit, [string]$Installed) {
    if ($WasExplicit) { return $Requested }
    if ($Installed) { return $Installed }
    return 'dark-grey'
}

function Get-ArcIconsApplyVariantArguments([string]$VariantId) {
    return @('-Variant', $VariantId)
}
