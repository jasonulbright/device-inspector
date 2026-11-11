# .SYNOPSIS
# Prints a read-only report of one device and optionally writes the same facts as JSON.
#
# .DESCRIPTION
# Imports the DeviceInspector module from the src folder next to this script,
# runs Get-DeviceInspection, prints the report, and writes JSON when JsonPath
# is set. The script never changes the site or the device. The only file it
# writes is the JSON file that the caller names.
#
# .PARAMETER ComputerName
# The device name.
#
# .PARAMETER SiteServer
# The site server (SMS Provider) name. Omit it to skip the site facts.
#
# .PARAMETER SiteCode
# The site code. It is required with SiteServer.
#
# .PARAMETER Credential
# An optional credential for the site server and the device.
#
# .PARAMETER SkipDevice
# Skip the facts from the device itself.
#
# .PARAMETER JsonPath
# A path for the JSON file. The file is written in UTF-8 without a byte order mark.
#
# .PARAMETER MaximumListedItems
# The most entries to print in each list of the report. The default is 25.
#
# .EXAMPLE
# .\Invoke-DeviceInspector.ps1 -ComputerName WS01 -SiteServer sms01.example.com -SiteCode XYZ -Credential $LabCredential -JsonPath .\ws01.json
#
# # Prints the report for WS01 and writes ws01.json.
#
# .INPUTS
# None. You can't pipe objects to this script.
#
# .OUTPUTS
# [string] The report text.
#
# .NOTES
# Positional parameters: position 0 is ComputerName.
#
# Version: 2026.11.11.0008
[CmdletBinding(PositionalBinding = $false)]
[OutputType([string])]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [string]$SiteServer,

    [Parameter(Mandatory = $false)]
    [string]$SiteCode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDevice,

    [Parameter(Mandatory = $false)]
    [string]$JsonPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100000)]
    [int]$MaximumListedItems = 25
)

Set-StrictMode -Version Latest

$strModulePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Module') -ChildPath 'DeviceInspectorCommon.psd1'
Import-Module -Name $strModulePath -Force -ErrorAction Stop

$objInputCheck = Test-DeviceInspectorInput -ComputerName $ComputerName -SiteServer $SiteServer -SiteCode $SiteCode
if (-not $objInputCheck.IsValid) {
    throw ($objInputCheck.Errors -join ' ')
}

$hashtableArgument = @{ ComputerName = $ComputerName }
foreach ($strName in @('SiteServer', 'SiteCode', 'Credential')) {
    if ($PSBoundParameters.ContainsKey($strName)) {
        $hashtableArgument[$strName] = $PSBoundParameters[$strName]
    }
}
if ($SkipDevice.IsPresent) {
    $hashtableArgument['SkipDevice'] = $true
}

$objInspection = Get-DeviceInspection @hashtableArgument
ConvertTo-DeviceInspectionReport -Inspection $objInspection -MaximumListedItems $MaximumListedItems

if ($PSBoundParameters.ContainsKey('JsonPath')) {
    $strJsonFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JsonPath)
    $strJson = (($objInspection | ConvertTo-Json -Depth 8) -replace "`r`n", "`n") + "`n"
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($strJsonFullPath))
    $objUtf8NoBomEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($strJsonFullPath, $strJson, $objUtf8NoBomEncoding)
    Write-Verbose -Message ('JSON written to {0}' -f $strJsonFullPath)
}
