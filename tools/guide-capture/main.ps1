# Lab-side runner. The scheduled task starts it in the interactive session. It runs steps.ps1
# and writes the finished flag: 'finished', or 'failed: <reason>' when the steps stopped.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'steps.ps1 is dot-sourced and reads appDir and Capture.')]
param([string]$App)
$ErrorActionPreference = 'Stop'
$OutDir = 'C:\guide\ui\out'; New-Item -ItemType Directory $OutDir -Force | Out-Null
$appDir = Join-Path 'C:\guide' $App
$flag = 'finished'
try {
    . C:\guide\ui\guilib.ps1
    # Settings that Invoke-GuideCapture.ps1 passes in (site code, SMS Provider, device names).
    $Capture = Get-Content -LiteralPath C:\guide\ui\capture.json -Raw | ConvertFrom-Json
    . C:\guide\ui\steps.ps1
}
catch {
    $flag = 'failed: ' + $_.Exception.Message
    try { Log ('ERROR: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace) } catch { $null = $_ }
}
finally { $flag | Set-Content (Join-Path $OutDir 'finished.flag') }
