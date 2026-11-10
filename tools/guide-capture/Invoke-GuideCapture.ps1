<#
.SYNOPSIS
    Regenerates every image of the user guide with one command.

.DESCRIPTION
    Copies this app to a lab workstation, runs the capture steps in an interactive
    session of a lab account (scheduled task, interactive logon), copies the PNG
    files back, and removes the task and the copy. Only the images that already
    exist in docs\images are replaced. When the run log has an error, or an image
    of the guide is missing, the script stops and replaces no image.

    The lab workstation needs a Configuration Manager console, a reachable SMS
    Provider and PowerShell remoting for the account in the credential script.
    The app only reads. The capture changes nothing on the site or on the devices.

.PARAMETER CredentialScript
    A script that sets $LabCredential (a PSCredential). Keep it outside the repository.

.PARAMETER Target
    The lab workstation name or address. The capture runs there.

.PARAMETER LogonUser
    The domain account that has the interactive session on the lab workstation.

.PARAMETER SmsProvider
    The site server (SMS Provider) name that the capture enters in Options.

.PARAMETER SiteCode
    The site code that the capture enters in Options.

.PARAMETER Device
    The client device that the capture inspects (most panels of the guide).

.PARAMETER SecondDevice
    A second device, a server, for the server images (device-server.png and the others).

.PARAMETER UnreachableDevice
    A device name that does not exist, for the images of an unreachable device.

.PARAMETER AddNew
    Also copy images that are not in docs\images yet. Use it for the first capture of a new page.

.EXAMPLE
    .\tools\guide-capture\Invoke-GuideCapture.ps1 -CredentialScript <credential script> -Target <workstation> -LogonUser <domain\account> -SmsProvider <site server> -SiteCode <code> -Device <client> -SecondDevice <server>
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialScript', Justification = 'The path of a script that sets the credential; it holds no password.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CredentialScript,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$LogonUser,
    [Parameter(Mandatory)][string]$SmsProvider,
    [Parameter(Mandatory)][string]$SiteCode,
    [Parameter(Mandatory)][string]$Device,
    [Parameter(Mandatory)][string]$SecondDevice,
    [string]$UnreachableDevice = 'no-such-device',
    [int]$Minutes = 20,
    [switch]$AddNew
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
$app = Split-Path $repo -Leaf
$images = Join-Path $repo 'docs\images'
. $CredentialScript
$captureJson = @{ SiteCode = $SiteCode; SmsProvider = $SmsProvider; Device = $Device; SecondDevice = $SecondDevice; UnreachableDevice = $UnreachableDevice } | ConvertTo-Json
$failed = New-Object System.Collections.Generic.List[string]
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('guide-capture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
# Runs on the lab computer. Stops the task, the runner and the app that run from C:\guide.
$stopCapture = {
    Stop-ScheduledTask -TaskName GuideShots -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*C:\guide\*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    $left = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*C:\guide\*' -and $_.ProcessId -ne $PID })
    if ($left.Count) { throw ('These processes from C:\guide did not stop: ' + (($left | ForEach-Object { $_.ProcessId }) -join ', ')) }
}
$session = New-PSSession -ComputerName $Target -Credential $LabCredential
$completed = $false
try {
    foreach ($steps in 'steps-guide.ps1', 'steps-console-missing.ps1') {
        $dest = "C:\guide\$app"
        # A fresh copy for each run: no saved settings, no window state, no log of an earlier run.
        Invoke-Command $session $stopCapture
        Invoke-Command $session { param($d) if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d, 'C:\guide\ui' -Force | Out-Null } -ArgumentList $dest
        foreach ($item in Get-ChildItem -LiteralPath $repo -Force | Where-Object { $_.Name -notin '.git', '.claude', '.github', 'Logs', 'Reports', 'screenshots', 'TestResults', 'docs', 'Tests', 'tools' -and $_.Name -notlike '*.prefs.json' -and $_.Name -notlike '*.windowstate.json' -and $_.Name -notlike '*.local.*' -and $_.Name -notlike '*.png' }) {
            Copy-Item -LiteralPath $item.FullName -Destination "$dest\$($item.Name)" -ToSession $session -Recurse -Force
        }
        Copy-Item (Join-Path $here 'guilib.ps1') 'C:\guide\ui\guilib.ps1' -ToSession $session -Force
        Copy-Item (Join-Path $here 'main.ps1') 'C:\guide\ui\main.ps1' -ToSession $session -Force
        Copy-Item (Join-Path $here $steps) 'C:\guide\ui\steps.ps1' -ToSession $session -Force
        Invoke-Command $session { param($j) Set-Content C:\guide\ui\capture.json $j -Encoding UTF8 } -ArgumentList $captureJson
        Invoke-Command $session -ScriptBlock {
            param($a, $user)
            Remove-Item C:\guide\ui\out -Recurse -Force -ErrorAction SilentlyContinue
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\guide\ui\main.ps1 -App `"$a`""
            $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
            Register-ScheduledTask -TaskName GuideShots -Action $act -Principal $pr -Force | Out-Null
            Start-ScheduledTask GuideShots
        } -ArgumentList $app, $LogonUser
        $end = (Get-Date).AddMinutes($Minutes)
        do { Start-Sleep 5; $done = Invoke-Command $session { Test-Path C:\guide\ui\out\finished.flag } } while (-not $done -and (Get-Date) -lt $end)
        if (-not $done) { throw "The capture did not finish: $steps" }
        $out = Join-Path $tmp ([IO.Path]::GetFileNameWithoutExtension($steps))
        New-Item -ItemType Directory $out | Out-Null
        Copy-Item 'C:\guide\ui\out\*' $out -FromSession $session -Recurse -Force
        $flag = Get-Content (Join-Path $out 'finished.flag') -Raw
        if ($flag -match 'failed') { $failed.Add(('{0}: {1}' -f $steps, $flag.Trim())) }
        $log = Join-Path $out 'run.log'
        if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match 'ERROR' } | ForEach-Object { Write-Warning $_; $failed.Add($_) } }
    }
    # A failed section stops the capture before any guide image is replaced.
    if ($failed.Count) { throw ("The capture failed. No image was replaced.`n" + ($failed -join "`n")) }
    $captured = @(Get-ChildItem $tmp -Recurse -Filter *.png | Where-Object { $_.Name -notlike 'fail-*' })
    $missing = @(Get-ChildItem $images -Filter *.png | Where-Object { $captured.Name -notcontains $_.Name } | ForEach-Object { $_.Name })
    if ($missing.Count) { throw ("The capture did not produce these guide images. No image was replaced.`n" + ($missing -join "`n")) }
    foreach ($png in $captured) {
        if ($AddNew -or (Test-Path (Join-Path $images $png.Name))) { Copy-Item $png.FullName (Join-Path $images $png.Name) -Force }
    }
    $completed = $true
}
finally {
    # After a timeout or a failure the app can still run on the lab computer. Stop it before the cleanup.
    $cleanupError = $null
    try {
        Invoke-Command $session $stopCapture
        Invoke-Command $session {
            Unregister-ScheduledTask GuideShots -Confirm:$false -ErrorAction SilentlyContinue
            if (Test-Path C:\guide) { Remove-Item C:\guide -Recurse -Force -ErrorAction Stop }
        }
    }
    catch { $cleanupError = $_ }
    Remove-PSSession $session
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($cleanupError) {
        $message = "The cleanup of C:\guide on the lab computer failed: $cleanupError"
        # A failed run already throws its own error. Do not replace it: show the cleanup failure as a warning.
        if ($completed) { throw $message } else { Write-Warning $message }
    }
}
