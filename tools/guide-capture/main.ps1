# Lab-side runner. The scheduled task starts it in the interactive session. It runs steps.ps1
# and writes the finished flag: 'finished', or 'failed: <reason>' when the steps stopped.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'steps.ps1 is dot-sourced and reads appDir and Capture.')]
param([string]$GuideRoot)
$ErrorActionPreference = 'Stop'
$OutDir = Join-Path $GuideRoot 'ui\out'; New-Item -ItemType Directory $OutDir -Force | Out-Null
$appDir = $GuideRoot
$flag = 'finished'
try {
    . (Join-Path $GuideRoot 'ui\guilib.ps1')
    # Settings that Invoke-GuideCapture.ps1 passes in (site code, SMS Provider, device names).
    $Capture = Get-Content -LiteralPath (Join-Path $GuideRoot 'ui\capture.json') -Raw | ConvertFrom-Json
    . (Join-Path $GuideRoot 'ui\steps.ps1')
}
catch {
    $flag = 'failed: ' + $_.Exception.Message
    try { Log ('ERROR: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace) } catch { $null = $_ }
}
finally { $flag | Set-Content (Join-Path $OutDir 'finished.flag') }
