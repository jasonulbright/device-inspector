# The start message on a computer without the Configuration Manager console.
# Test copy only: make the module path lookup return nothing, as on a computer without the console.
$f = Join-Path $appDir 'Lib\SuiteCommon\SuiteCommon.psm1'
$t = Get-Content -LiteralPath $f -Raw
$t = $t -replace '(?s)(function Resolve-ConfigurationManagerModulePath \{)', '$1 return $null;'
Set-Content -LiteralPath $f -Value $t -Encoding UTF8
Remove-Item Env:SMS_ADMIN_UI_PATH -ErrorAction SilentlyContinue
Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', (Join-Path $appDir 'start-deviceinspector.ps1'))
# The app stops before its window opens and shows a system message box titled with the app name.
$m = Find-Top 'Device Inspector' 40
Start-Sleep -Seconds 1
Shot $m 'start-console-missing'
Focus-Win $m; Send-Keys '{ENTER}'; Start-Sleep -Seconds 2
Stop-App 'start-deviceinspector.ps1'
