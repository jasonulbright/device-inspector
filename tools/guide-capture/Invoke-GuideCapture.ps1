<#
.SYNOPSIS
    Regenerates every image of the user guide with one command.

.DESCRIPTION
    Copies this app to a lab workstation, runs the capture steps in an interactive
    session of a lab account (scheduled task, interactive logon), copies the PNG
    files back, and removes the task and the copy. Only the images that already
    exist in docs\images are replaced. When the run log has an error, or an image
    of the guide is missing, the script stops and replaces no image.

    One capture runs at a time on a lab computer. The script takes the lock file
    C:\guide\capture.lock (New-Item fails when the file exists) and waits while another
    capture holds it. The script touches the lock every 5 seconds while its capture runs, so a
    live capture never looks stale. A lock older than 60 minutes is stale and the script removes it.
    The script works in its own folder C:\guide\device-inspector and its own task
    GuideShots-device-inspector. It removes the lock and its own files at the end. It never
    removes the folder C:\guide.

    The lab workstation needs a Configuration Manager console, a reachable SMS
    Provider and PowerShell remoting for the account in the credential script.
    The capture turns on Enable Actions for the action images, but it only chooses Dry Run or Cancel in a confirmation dialog. It never chooses Run, so it changes nothing on the site or on the devices.

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

.PARAMETER UninstallApp
    The name of an application on the lab workstation that the Applications panel lists as an MSI row with the Uninstall entry on,
    for the images of the right-click menu and of the uninstall confirmation. The capture never runs the uninstall: it chooses Cancel.
    The default is the Microsoft Visual C++ 2022 X86 Minimum Runtime. Name another application when the workstation lists that one as a
    system component.

.PARAMETER Minutes
    The time limit of the capture run.

.PARAMETER LockWaitMinutes
    How long to wait for the capture lock of another capture before the script stops.

.PARAMETER Section
    The names of the sections of steps-guide.ps1 to run, for example 'inspect the client'. Only these sections run, and the
    console-missing steps do not run. The app starts with no saved settings. When neither 'first run' nor 'options' is selected,
    the run first enters the site server and the site code, as those sections do, and takes no image of that. A section uses the state that the
    sections before it leave, so select every section that your images need, in the order of the file. The section 'action menus'
    holds the uninstall images: leave it out on a workstation with no harmless uninstallable application row. The script stops
    before it connects when a name is not a section. Without -Section, every section runs.

.PARAMETER Image
    The names of the images to copy into docs\images, without the .png extension, for example device-panel. Other images that the
    run takes are not copied. The script stops and replaces no image when a named image was not taken. Use it with -Section. With -Section and no -Image, every image that the sections take is copied, and the check for a
    missing guide image is off.

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
    [string]$UninstallApp = 'Microsoft Visual C++ 2022 X86 Minimum Runtime',
    [int]$Minutes = 20,
    [int]$LockWaitMinutes = 90,
    [string[]]$Section,
    [string[]]$Image,
    [switch]$AddNew
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
$app = 'device-inspector'
$images = Join-Path $repo 'docs\images'
if (-not (Test-Path -LiteralPath $CredentialScript -PathType Leaf)) { throw "The credential script does not exist: $CredentialScript" }
$LabCredential = $null
. $CredentialScript
if (-not ($LabCredential -is [System.Management.Automation.PSCredential])) { throw 'The credential script must set $LabCredential to a PSCredential.' }
# A name that is not a section would run nothing and look like a success: stop before the first connection.
$knownSections = @([regex]::Matches([IO.File]::ReadAllText((Join-Path $here 'steps-guide.ps1')), "(?m)^Section '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
foreach ($name in @($Section | Where-Object { $_ })) {
    if ($knownSections -notcontains $name) { throw ("Unknown section '{0}'. The sections are: {1}" -f $name, ($knownSections -join ', ')) }
}
$captureJson = @{ SiteCode = $SiteCode; SmsProvider = $SmsProvider; Device = $Device; SecondDevice = $SecondDevice; UnreachableDevice = $UnreachableDevice; UninstallApp = $UninstallApp; Sections = @($Section | Where-Object { $_ }) } | ConvertTo-Json
# Own folder and own task name, so that two captures in the lab never meet. The C:\guide folder itself stays.
$root = "C:\guide\$app"
$taskName = "GuideShots-$app"
$lockPath = 'C:\guide\capture.lock'
$lockToken = [guid]::NewGuid().ToString('N')
$haveLock = $false
$failed = New-Object System.Collections.Generic.List[string]
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('guide-capture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$succeeded = $false
$session = $null
try {
    $session = New-PSSession -ComputerName $Target -Credential $LabCredential
    # The lock: New-Item with -ErrorAction Stop fails with an IOException when the file exists.
    # Wait for the holder. A lock that is older than the stale age belongs to a dead capture and is removed.
    $haveLock = Invoke-Command $session {
        param($path, $token, $staleMinutes, $waitMinutes)
        New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force | Out-Null
        $deadline = (Get-Date).AddMinutes($waitMinutes)
        while ($true) {
            try {
                # One call creates the file and writes the token. It fails with an IOException when the file exists.
                $null = New-Item -ItemType File -Path $path -Value $token -ErrorAction Stop
                return $true
            }
            catch [System.IO.IOException] {
                $held = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                if ($held -and ((Get-Date) - $held.LastWriteTime).TotalMinutes -gt $staleMinutes) {
                    # Read the age again right before the rename: the holder may have touched the lock. Rename the stale
                    # lock to a name of this capture (only one waiter wins the rename; a lost rename counts as busy), then
                    # delete the renamed file. A waiter never deletes a fresh lock. Retry at once only when the lock is gone.
                    # Otherwise fall to the deadline check and the sleep, so the loop never spins.
                    $again = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                    if ($again -and ((Get-Date) - $again.LastWriteTime).TotalMinutes -gt $staleMinutes) {
                        $stale = "$path.stale.$token"
                        try {
                            Move-Item -LiteralPath $path -Destination $stale -ErrorAction Stop
                            # The file that was moved may be a fresh lock that another waiter created between the read and the
                            # rename. Read its age again. A lock that is not older than the stale age goes back and counts as busy.
                            $moved = Get-Item -LiteralPath $stale -ErrorAction Stop
                            if (((Get-Date) - $moved.LastWriteTime).TotalMinutes -gt $staleMinutes) {
                                Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
                            }
                            else {
                                # A live lock goes back. When it cannot go back, delete the stale-named file and count the lock as busy.
                                try { Move-Item -LiteralPath $stale -Destination $path -ErrorAction Stop }
                                catch { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
                            }
                        }
                        catch { $null = $_ }
                    }
                    if (-not (Test-Path -LiteralPath $path)) { continue }
                }
                if ((Get-Date) -gt $deadline) { return $false }
                Start-Sleep -Seconds 15
            }
        }
    } -ArgumentList $lockPath, $lockToken, 60, $LockWaitMinutes
    if (-not $haveLock) { throw "Another capture holds $lockPath. The wait of $LockWaitMinutes minutes is over." }
    # A run with -Section takes the guide steps only: the console-missing steps have no section.
    $stepFiles = if ($Section) { @('steps-guide.ps1') } else { @('steps-guide.ps1', 'steps-console-missing.ps1') }
    foreach ($steps in $stepFiles) {
        $dest = $root
        # A fresh copy for each run: no saved settings, no window state, no log of an earlier run. Stop only the leftovers
        # of an earlier capture of this app.
        Invoke-Command $session {
            param($d)
            Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$d\*" -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2
            if (Test-Path $d) { Remove-Item $d -Recurse -Force }
            New-Item -ItemType Directory $d, (Join-Path $d 'ui') -Force | Out-Null
        } -ArgumentList $dest
        # The app files only: no saved settings, logs, reports, tests or documentation.
        foreach ($item in Get-ChildItem -LiteralPath $repo -Force | Where-Object { $_.Name -notin '.git', '.claude', '.github', '.vs', '.vscode', '.idea', 'node_modules', 'TestOutput', 'Logs', 'Reports', 'screenshots', 'TestResults', 'docs', 'Tests', 'tools' -and $_.Name -notlike '*.prefs.json' -and $_.Name -notlike '*.windowstate.json' -and $_.Name -notlike '*.local.*' -and $_.Name -notlike '*.png' }) {
            Copy-Item -LiteralPath $item.FullName -Destination "$dest\$($item.Name)" -ToSession $session -Recurse -Force
        }
        Copy-Item (Join-Path $here 'guilib.ps1') (Join-Path $root 'ui\guilib.ps1') -ToSession $session -Force
        Copy-Item (Join-Path $here 'main.ps1') (Join-Path $root 'ui\main.ps1') -ToSession $session -Force
        Copy-Item (Join-Path $here $steps) (Join-Path $root 'ui\steps.ps1') -ToSession $session -Force
        Invoke-Command $session {
            param($r, $user, $json, $task)
            Set-Content (Join-Path $r 'ui\capture.json') $json -Encoding UTF8
            Remove-Item (Join-Path $r 'ui\out') -Recurse -Force -ErrorAction SilentlyContinue
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$r\ui\main.ps1`" -GuideRoot `"$r`""
            $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
            Register-ScheduledTask -TaskName $task -Action $act -Principal $pr -Force | Out-Null
            Start-ScheduledTask $task
        } -ArgumentList $root, $LogonUser, $captureJson, $taskName
        $end = (Get-Date).AddMinutes($Minutes)
        $done = $false
        do {
            Start-Sleep 5
            # The poll also touches the lock, so that a long capture is never taken for a stale one.
            try {
            $state = Invoke-Command $session {
                param($r, $path, $task, $token)
                # The capture stops when its lock is gone or belongs to another capture.
                $lock = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                if (-not $lock -or ([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim() -ne $token) { throw 'The capture lock is lost.' }
                $lock.LastWriteTime = Get-Date
                [pscustomobject]@{ Done = (Test-Path (Join-Path $r 'ui\out\finished.flag')); Task = (Get-ScheduledTask $task -ErrorAction SilentlyContinue).State; Result = (Get-ScheduledTaskInfo $task -ErrorAction SilentlyContinue).LastTaskResult }
            } -ArgumentList $root, $lockPath, $taskName, $lockToken
            }
            catch {
                # A lost lock is not ours: the clean-up must not touch the task, the processes and the folder of another capture.
                if ($_.Exception.Message -match 'The capture lock is lost') { $haveLock = $false }
                throw
            }
            $done = $state.Done
            # The task is not running any more, no finished flag exists and the last result is an error: stop now.
            if (-not $done -and $state.Task -eq 'Ready' -and $state.Result -notin 0, 267009, 267011) { throw ('The capture task stopped with result {0}: {1}' -f $state.Result, $steps) }
        } while (-not $done -and (Get-Date) -lt $end)
        if (-not $done) { throw "The capture did not finish: $steps" }
        $out = Join-Path $tmp ([IO.Path]::GetFileNameWithoutExtension($steps))
        New-Item -ItemType Directory $out | Out-Null
        Copy-Item (Join-Path $root 'ui\out\*') $out -FromSession $session -Recurse -Force
        $flag = (Get-Content -LiteralPath (Join-Path $out 'finished.flag') -Raw).Trim()
        if ($flag -ne 'finished') { Write-Warning ('{0}: {1}' -f $steps, $flag); $failed.Add(('{0}: {1}' -f $steps, $flag)) }
        $log = Join-Path $out 'run.log'
        if (-not (Test-Path $log)) { throw "The capture wrote no run.log: $steps" }
        Get-Content $log | Where-Object { $_ -match '^\d\d:\d\d:\d\d\s+ERROR' } | ForEach-Object { Write-Warning $_; $failed.Add($_) }
    }
    # A failed step stops the capture before any guide image is replaced.
    if ($failed.Count) { throw ("The capture failed. No image was replaced.`n" + ($failed -join "`n")) }
    $captured = @(Get-ChildItem $tmp -Recurse -Filter *.png | Where-Object { $_.Name -notlike 'fail-*' })
    $capturedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $duplicate = New-Object System.Collections.Generic.List[string]
    foreach ($png in $captured) { if (-not $capturedNames.Add($png.Name)) { $duplicate.Add($png.Name) } }
    if ($duplicate.Count) { throw ("Two runs produced the same image. No image was replaced.`n" + ($duplicate -join "`n")) }
    $wanted = @($Image | Where-Object { $_ } | ForEach-Object { $_ -replace '\.png$', '' })
    if ($wanted.Count) {
        $missing = @($wanted | Where-Object { $captured.BaseName -notcontains $_ })
        if ($missing.Count) { throw ("The capture did not produce these named images. No image was replaced.`n" + ($missing -join "`n")) }
        $captured = @($captured | Where-Object { $wanted -contains $_.BaseName })
    }
    elseif (-not $Section) {
        $missing = @(Get-ChildItem $images -Filter *.png | Where-Object { -not $capturedNames.Contains($_.Name) } | ForEach-Object { $_.Name })
        if ($missing.Count) { throw ("The capture did not produce these guide images. No image was replaced.`n" + ($missing -join "`n")) }
    }
    # Stage the new files first and move them in one pass. A failed move restores the old files.
    $staging = Join-Path $tmp 'staging'
    New-Item -ItemType Directory $staging | Out-Null
    $backup = Join-Path $tmp 'backup'
    New-Item -ItemType Directory $backup | Out-Null
    $placed = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($png in $captured) {
            $target = Join-Path $images $png.Name
            if (-not ($AddNew -or (Test-Path $target))) { continue }
            Copy-Item $png.FullName (Join-Path $staging $png.Name) -Force
        }
        foreach ($file in Get-ChildItem $staging -Filter *.png) {
            $target = Join-Path $images $file.Name
            if (Test-Path $target) { Copy-Item $target (Join-Path $backup $file.Name) -Force }
            Copy-Item $file.FullName $target -Force
            $placed.Add($file.Name)
        }
    }
    catch {
        foreach ($name in $placed) {
            $old = Join-Path $backup $name
            if (Test-Path $old) { Copy-Item $old (Join-Path $images $name) -Force } else { Remove-Item (Join-Path $images $name) -Force -ErrorAction SilentlyContinue }
        }
        throw
    }
    $succeeded = $true
}
finally {
    # Each cleanup runs on its own, so that a failed cleanup cannot replace the original error.
    # Stop a capture that still runs (a timeout leaves it running), then remove the task. Stop the task first, then the
    # powershell.exe processes of this folder, then unregister, so that nothing keeps writing into the folder or the lock.
    # Only a capture that holds the lock cleans up: without the lock the task, the folder and the processes belong to another capture.
    if ($session -and $haveLock) { try {
        Invoke-Command $session {
            param($t, $r)
            Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$r\*" -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2
            Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        } -ArgumentList $taskName, $root
    } catch { Write-Warning "Cleanup of the scheduled task failed: $($_.Exception.Message)" }
    try { Invoke-Command $session { param($r) Remove-Item $r -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $root } catch { Write-Warning "Cleanup of $root failed: $($_.Exception.Message)" } }
    # Remove the lock only when this capture took it.
    try {
        if ($haveLock -and $session) {
            Invoke-Command $session { param($path, $token) if ((Test-Path -LiteralPath $path) -and (([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim() -eq $token)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } -ArgumentList $lockPath, $lockToken
        }
    } catch { Write-Warning "Removing the capture lock failed: $($_.Exception.Message)" }
    try { if ($session) { Remove-PSSession $session } } catch { Write-Warning "Closing the session failed: $($_.Exception.Message)" }
    if (-not $succeeded) { Write-Warning "The captured files stay in $tmp for inspection." }
    else { try { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Warning "Cleanup of $tmp failed: $($_.Exception.Message)" } }
}
