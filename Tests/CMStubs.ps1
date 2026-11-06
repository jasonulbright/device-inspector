# .SYNOPSIS
# Global stubs for the ConfigurationManager cmdlets that the tests mock.
#
# .DESCRIPTION
# The ConfigurationManager module comes only with the Configuration Manager console,
# so a test machine usually does not have it. A global function with the same name
# as the cmdlet lets Pester mock the call, with or without the console. A global
# function wins over a cmdlet of the same name. Value parameters stay untyped. A
# name in the switch list becomes a [switch], because an untyped parameter demands
# an argument and a bare -Fast would fail to bind.
#
# .NOTES
# Dot-source this file in BeforeAll. Positional parameters: none.
#
# Version: 2026.11.06.0001

$script:arrSwitchName = @('Fast', 'DisableWildcardHandling')
$script:hashtableStub = [ordered]@{
    'Get-CMSite' = @('SiteCode')
    'Get-CMDevice' = @('Name', 'Fast', 'DisableWildcardHandling')
    'Get-CMDeviceCollection' = @()
    'Get-CMDeployment' = @()
    'Get-CMSoftwareUpdate' = @('Fast')
    'Invoke-CMWmiQuery' = @('Query', 'Option')
}
foreach ($strStubName in $script:hashtableStub.Keys) {
    $arrParameter = @(foreach ($strParameter in $script:hashtableStub[$strStubName]) {
            if ($script:arrSwitchName -contains $strParameter) { '[switch]${0}' -f $strParameter } else { '${0}' -f $strParameter }
        })
    $strBody = 'function global:{0} {{ [CmdletBinding()] param ({1}) }}' -f $strStubName, ($arrParameter -join ', ')
    . ([scriptblock]::Create($strBody))
}
