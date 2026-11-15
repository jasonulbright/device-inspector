<#
.SYNOPSIS
    Copies the capture images over the README images that are copies of them.

.DESCRIPTION
    Reads tools\guide-capture\readme-images.json: an object that maps a README image path (relative to the
    repository root) to the file of docs\images that it is a copy of. Run it after Invoke-GuideCapture.ps1.
    Every image that README.md shows now sits in docs\images and is produced by the capture, so the map is empty.
    The script fails when a source image is missing.

.PARAMETER RepoRoot
    The repository root. The default is two folders above this script.

.EXAMPLE
    .\tools\guide-capture\Sync-ReadmeImages.ps1
#>
[CmdletBinding()]
[OutputType([void])]
param(
    [string]$RepoRoot = (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent)
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$strMapPath = Join-Path -Path $PSScriptRoot -ChildPath 'readme-images.json'
$objMap = Get-Content -LiteralPath $strMapPath -Raw | ConvertFrom-Json
foreach ($objEntry in $objMap.PSObject.Properties) {
    $strTarget = Join-Path -Path $RepoRoot -ChildPath $objEntry.Name
    $strSource = Join-Path -Path $RepoRoot -ChildPath ([string]$objEntry.Value)
    if (-not (Test-Path -LiteralPath $strSource)) { throw ('The source image is missing: {0}' -f $objEntry.Value) }
    Copy-Item -LiteralPath $strSource -Destination $strTarget -Force
    Write-Host ('{0} <- {1}' -f $objEntry.Name, $objEntry.Value)
}
