# .SYNOPSIS
# Runs PSScriptAnalyzer and the Pester tests for this repository.
#
# .DESCRIPTION
# Runs PSScriptAnalyzer with PSScriptAnalyzerSettings.psd1 on every PowerShell
# file, then Pester on the tests folder. The tests need no lab. The script
# exits with code 1 when the analyzer reports a finding or a test fails.
#
# .EXAMPLE
# .\Invoke-Checks.ps1
#
# # Prints the analyzer findings and the Pester summary.
#
# .INPUTS
# None. You can't pipe objects to this script.
#
# .OUTPUTS
# None. The script sets the process exit code.
#
# .NOTES
# Positional parameters: none.
#
# Version: 2026.11.06.0001
[CmdletBinding(PositionalBinding = $false)]
[OutputType([void])]
param ()

Set-StrictMode -Version Latest

$strSettingsPath = Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
$strTestPath = Join-Path -Path $PSScriptRoot -ChildPath 'Tests'
$strLibPath = Join-Path -Path $PSScriptRoot -ChildPath 'Lib'
$arrFile = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File | Where-Object { -not $_.FullName.StartsWith($strLibPath, [System.StringComparison]::OrdinalIgnoreCase) })

$listFinding = New-Object -TypeName 'System.Collections.Generic.List[object]'
$intAnalyzerFailure = 0
foreach ($objFile in $arrFile) {
    # PSScriptAnalyzer 1.25.0 sometimes throws a NullReferenceException on the first
    # call for a file. A retry gives the real result. Three failed calls count as a failure.
    $boolDone = $false
    for ($intAttempt = 1; $intAttempt -le 3 -and -not $boolDone; $intAttempt++) {
        try {
            foreach ($objFinding in @(Invoke-ScriptAnalyzer -Path $objFile.FullName -Settings $strSettingsPath -ErrorAction Stop)) {
                $listFinding.Add($objFinding)
            }
            $boolDone = $true
        } catch {
            Write-Debug -Message $_.Exception.Message
        }
    }
    if (-not $boolDone) {
        $intAnalyzerFailure++
        Write-Warning -Message ('PSScriptAnalyzer failed three times on {0}' -f $objFile.FullName)
    }
}
$arrFinding = $listFinding.ToArray()
$arrFinding | Format-Table -Property Severity, RuleName, ScriptName, Line, Message -AutoSize | Out-String -Width 200 | Write-Output
Write-Output ('PSScriptAnalyzer findings: {0}' -f $arrFinding.Count)

$objConfiguration = New-PesterConfiguration
$objConfiguration.Run.Path = $strTestPath
$objConfiguration.Run.PassThru = $true
$objConfiguration.Output.Verbosity = 'Normal'
$objResult = Invoke-Pester -Configuration $objConfiguration

if ($arrFinding.Count -gt 0 -or $intAnalyzerFailure -gt 0 -or $objResult.FailedCount -gt 0) {
    exit 1
}
exit 0
