Set-StrictMode -Version Latest

# Every change to a device or to the site goes through this file. Each action has a
# dry run: the same code path reads the current state and lists the steps, and skips
# every call that changes state. The window runs an action only when the person has
# turned on Enable actions and confirmed the action.

#region Remote script blocks

# Runs on the device. Requests machine policy, then evaluates it. A ReturnValue other
# than 0 stops the run, because the evaluation of old policy has no use.
$script:scriptBlockPolicyUpdate = {
    param ([Parameter(Mandatory = $true)][bool]$DryRun)

    $ErrorActionPreference = 'Stop'
    $listStep = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $arrSchedule = @(
        @{ Id = '{00000000-0000-0000-0000-000000000021}'; Name = 'Machine policy retrieval (Machine Policy Assignments Request)' }
        @{ Id = '{00000000-0000-0000-0000-000000000022}'; Name = 'Machine policy evaluation (Machine Policy Evaluation)' }
    )
    try {
        $objClient = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client'
    } catch {
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The Configuration Manager client does not answer: {0}' -f $_.Exception.Message); Steps = @($listStep) }
    }
    if ($null -eq $objClient) {
        return [pscustomobject]@{ Succeeded = $false; Summary = 'The Configuration Manager client is not installed on the device.'; Steps = @($listStep) }
    }
    $listStep.Add(('Client version {0} answers.' -f [string]$objClient.ClientVersion))
    foreach ($hashtableSchedule in $arrSchedule) {
        if ($DryRun) {
            $listStep.Add(('Dry run: would trigger {0} {1}.' -f $hashtableSchedule.Name, $hashtableSchedule.Id))
            continue
        }
        try {
            $objReturn = Invoke-CimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' -MethodName 'TriggerSchedule' -Arguments @{ sScheduleID = $hashtableSchedule.Id }
            $objReturnValue = $null
            if ($null -ne $objReturn -and $null -ne $objReturn.PSObject.Properties['ReturnValue']) {
                $objReturnValue = $objReturn.ReturnValue
            }
            $boolRefused = ($null -ne $objReturnValue -and [int64]$objReturnValue -ne 0)
        } catch {
            $listStep.Add(('{0} failed: {1}' -f $hashtableSchedule.Name, $_.Exception.Message))
            return [pscustomobject]@{ Succeeded = $false; Summary = ('{0} failed. The earlier steps, if any, ran.' -f $hashtableSchedule.Name); Steps = @($listStep) }
        }
        if ($boolRefused) {
            $listStep.Add(('{0} failed: TriggerSchedule returned {1}.' -f $hashtableSchedule.Name, $objReturnValue))
            return [pscustomobject]@{ Succeeded = $false; Summary = ('{0} failed with return value {1}.' -f $hashtableSchedule.Name, $objReturnValue); Steps = @($listStep) }
        }
        $listStep.Add(('Triggered {0} {1}.' -f $hashtableSchedule.Name, $hashtableSchedule.Id))
    }
    $strSummary = 'The client requested and evaluated machine policy.'
    if ($DryRun) {
        $strSummary = 'Dry run: the client answers. Nothing changed.'
    }
    [pscustomobject]@{ Succeeded = $true; Summary = $strSummary; Steps = @($listStep) }
}

# Runs on the device. Deletes the status record of the hardware inventory action, then
# starts a hardware inventory cycle. Without the record, the client sends a full report
# instead of a delta, so the site replaces all hardware inventory of the device.
$script:scriptBlockFullInventory = {
    param ([Parameter(Mandatory = $true)][bool]$DryRun)

    $ErrorActionPreference = 'Stop'
    $listStep = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $strActionId = '{00000000-0000-0000-0000-000000000001}'
    $strFormat = 'yyyy-MM-ddTHH:mm:ssZ'
    $objCulture = [System.Globalization.CultureInfo]::InvariantCulture
    try {
        $objClient = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client'
    } catch {
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The Configuration Manager client does not answer: {0}' -f $_.Exception.Message); Steps = @($listStep) }
    }
    if ($null -eq $objClient) {
        return [pscustomobject]@{ Succeeded = $false; Summary = 'The Configuration Manager client is not installed on the device.'; Steps = @($listStep) }
    }
    $listStep.Add(('Client version {0} answers.' -f [string]$objClient.ClientVersion))
    try {
        $arrStatus = @(Get-CimInstance -Namespace 'root\ccm\invagt' -ClassName 'InventoryActionStatus' -Filter ("InventoryActionID = '{0}'" -f $strActionId))
    } catch {
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The hardware inventory status cannot be read: {0}' -f $_.Exception.Message); Steps = @($listStep) }
    }
    foreach ($objStatus in $arrStatus) {
        try {
            $strCycle = ''
            $strReport = ''
            if ($null -ne $objStatus.LastCycleStartedDate) {
                $strCycle = ([datetime]$objStatus.LastCycleStartedDate).ToUniversalTime().ToString($strFormat, $objCulture)
            }
            if ($null -ne $objStatus.LastReportDate) {
                $strReport = ([datetime]$objStatus.LastReportDate).ToUniversalTime().ToString($strFormat, $objCulture)
            }
            $listStep.Add(('Hardware inventory status: last cycle {0}, last report {1}, report version {2}.{3}.' -f $strCycle, $strReport, $objStatus.LastMajorReportVersion, $objStatus.LastMinorReportVersion))
        } catch {
            $listStep.Add('Hardware inventory status: a record exists. Its values cannot be read.')
        }
    }
    if ($arrStatus.Count -eq 0) {
        $listStep.Add('No hardware inventory status record exists. The next cycle sends a full report.')
    }
    if ($DryRun) {
        foreach ($objStatus in $arrStatus) {
            $listStep.Add(('Dry run: would delete the InventoryActionStatus record {0} in root\ccm\invagt.' -f $strActionId))
        }
        $listStep.Add(('Dry run: would trigger Hardware Inventory {0}.' -f $strActionId))
        return [pscustomobject]@{ Succeeded = $true; Summary = 'Dry run: the client answers. Nothing changed.'; Steps = @($listStep) }
    }
    foreach ($objStatus in $arrStatus) {
        try {
            Remove-CimInstance -InputObject $objStatus
        } catch {
            $listStep.Add(('Delete of the status record failed: {0}' -f $_.Exception.Message))
            return [pscustomobject]@{ Succeeded = $false; Summary = 'The hardware inventory status record cannot be deleted. The schedule was not triggered.'; Steps = @($listStep) }
        }
        $listStep.Add(('Deleted the InventoryActionStatus record {0}.' -f $strActionId))
    }
    try {
        $objReturn = Invoke-CimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' -MethodName 'TriggerSchedule' -Arguments @{ sScheduleID = $strActionId }
        $objReturnValue = $null
        if ($null -ne $objReturn -and $null -ne $objReturn.PSObject.Properties['ReturnValue']) {
            $objReturnValue = $objReturn.ReturnValue
        }
        $boolRefused = ($null -ne $objReturnValue -and [int64]$objReturnValue -ne 0)
    } catch {
        $listStep.Add(('Hardware Inventory trigger failed: {0}' -f $_.Exception.Message))
        return [pscustomobject]@{ Succeeded = $false; Summary = 'The status record is deleted, but the cycle did not start. The next scheduled cycle sends a full report.'; Steps = @($listStep) }
    }
    if ($boolRefused) {
        $listStep.Add(('Hardware Inventory trigger failed: TriggerSchedule returned {0}.' -f $objReturnValue))
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The cycle did not start (return value {0}). The next scheduled cycle sends a full report.' -f $objReturnValue); Steps = @($listStep) }
    }
    $listStep.Add(('Triggered Hardware Inventory {0}.' -f $strActionId))
    [pscustomobject]@{ Succeeded = $true; Summary = 'The client started a hardware inventory cycle with no status record, so it sends a full report. InventoryAgent.log on the device shows the report.'; Steps = @($listStep) }
}

# Runs on the device. Installs the updates of the client policy that the client
# reports as missing (ComplianceState 0) and that have no install job in progress
# (EvaluationState None, Available or Error). An empty UpdateId list means all of them.
# The new evaluation state of each update is read back after the request, because
# InstallUpdates returns when the client accepts the job, not when it ends.
$script:scriptBlockUpdateInstall = {
    param (
        [Parameter(Mandatory = $true)][bool]$DryRun,
        [Parameter(Mandatory = $false)][string[]]$UpdateId = @()
    )

    $ErrorActionPreference = 'Stop'
    $listStep = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $arrStateName = @('None', 'Available', 'Submitted', 'Detecting', 'PreDownload', 'Downloading', 'WaitInstall', 'Installing', 'PendingSoftReboot', 'PendingHardReboot', 'WaitReboot', 'Verifying', 'InstallComplete', 'Error', 'WaitServiceWindow', 'WaitUserLogon', 'WaitUserLogoff', 'WaitJobUserLogon', 'WaitUserReconnect', 'PendingUserLogoff', 'PendingUpdate', 'WaitingRetry', 'WaitPresModeOff', 'WaitForOrchestration')
    $scriptBlockState = {
        param($objValue)
        $intValue = [int]$objValue
        if ($intValue -ge 0 -and $intValue -lt $arrStateName.Count) {
            return ('{0} ({1})' -f $arrStateName[$intValue], $intValue)
        }
        return ('{0}' -f $intValue)
    }
    try {
        $objClient = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client'
    } catch {
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The Configuration Manager client does not answer: {0}' -f $_.Exception.Message); Steps = @($listStep) }
    }
    if ($null -eq $objClient) {
        return [pscustomobject]@{ Succeeded = $false; Summary = 'The Configuration Manager client is not installed on the device.'; Steps = @($listStep) }
    }
    $listStep.Add(('Client version {0} answers.' -f [string]$objClient.ClientVersion))
    try {
        $arrAll = @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_SoftwareUpdate')
    } catch {
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The updates of the client policy cannot be read: {0}' -f $_.Exception.Message); Steps = @($listStep) }
    }
    $arrRequired = @($arrAll | Where-Object { [int]$_.ComplianceState -eq 0 })
    $arrCandidate = $arrRequired
    if (@($UpdateId).Count -gt 0) {
        $arrCandidate = @($arrRequired | Where-Object { @($UpdateId) -contains [string]$_.UpdateID })
    }
    $arrTarget = @($arrCandidate | Where-Object { @(0, 1, 13) -contains [int]$_.EvaluationState })
    foreach ($objBusy in @($arrCandidate | Where-Object { @(0, 1, 13) -notcontains [int]$_.EvaluationState })) {
        $listStep.Add(('Skipped KB{0}: an install job is in progress or complete, state {1}.' -f [string]$objBusy.ArticleID, (& $scriptBlockState $objBusy.EvaluationState)))
    }
    $listStep.Add(('Updates in the client policy: {0}. Missing on the device (ComplianceState 0): {1}. To install: {2}.' -f $arrAll.Count, $arrRequired.Count, $arrTarget.Count))
    foreach ($objUpdate in $arrTarget) {
        $listStep.Add(('KB{0} {1}, state {2}.' -f [string]$objUpdate.ArticleID, [string]$objUpdate.Name, (& $scriptBlockState $objUpdate.EvaluationState)))
    }
    if ($arrTarget.Count -eq 0) {
        $strNone = 'No update to install: the client policy has no matching update that is missing on the device.'
        if ($arrCandidate.Count -gt 0) {
            $strNone = 'No update to install: each matching update has an install job in progress or complete.'
        }
        return [pscustomobject]@{ Succeeded = $false; Summary = $strNone; Steps = @($listStep) }
    }
    if ($DryRun) {
        $listStep.Add(('Dry run: would call CCM_SoftwareUpdatesManager.InstallUpdates for {0} updates.' -f $arrTarget.Count))
        return [pscustomobject]@{ Succeeded = $true; Summary = 'Dry run: the client answers. Nothing changed.'; Steps = @($listStep) }
    }
    try {
        $objReturn = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_SoftwareUpdatesManager' -MethodName 'InstallUpdates' -Arguments @{ CCMUpdates = [CimInstance[]]$arrTarget }
        $objReturnValue = $null
        if ($null -ne $objReturn -and $null -ne $objReturn.PSObject.Properties['ReturnValue']) {
            $objReturnValue = $objReturn.ReturnValue
        }
        $boolRefused = ($null -ne $objReturnValue -and [int64]$objReturnValue -ne 0)
    } catch {
        $listStep.Add(('InstallUpdates failed: {0}' -f $_.Exception.Message))
        return [pscustomobject]@{ Succeeded = $false; Summary = 'The client did not accept the install request.'; Steps = @($listStep) }
    }
    if ($boolRefused) {
        $listStep.Add(('InstallUpdates returned {0}.' -f $objReturnValue))
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The client refused the install request (return value {0}).' -f $objReturnValue); Steps = @($listStep) }
    }
    if ($null -eq $objReturnValue) {
        $listStep.Add('InstallUpdates gave no return value. The state read below shows the outcome.')
    }
    $listStep.Add(('InstallUpdates accepted {0} updates.' -f $arrTarget.Count))
    Start-Sleep -Seconds 5
    try {
        $arrTargetId = @($arrTarget | ForEach-Object { [string]$_.UpdateID })
        foreach ($objUpdate in @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_SoftwareUpdate' | Where-Object { $arrTargetId -contains [string]$_.UpdateID })) {
            $listStep.Add(('After the request: KB{0}, state {1}, percent complete {2}.' -f [string]$objUpdate.ArticleID, (& $scriptBlockState $objUpdate.EvaluationState), [int]$objUpdate.PercentComplete))
        }
    } catch {
        $listStep.Add(('The state after the request cannot be read: {0}' -f $_.Exception.Message))
    }
    [pscustomobject]@{ Succeeded = $true; Summary = ('The client accepted the install of {0} updates. It downloads and installs them now. A restart can follow, as the deployment sets.' -f $arrTarget.Count); Steps = @($listStep) }
}

# Runs on the device. Uninstalls or repairs one entry of the uninstall registry keys
# (HKLM, 64-bit or 32-bit view). The window sends the view and the key name only,
# never a command line. This block reads the key again on the device, checks the
# rules again, and builds the command line itself.
#   MSI (key name is a product code in braces, and the uninstall string starts with
#   msiexec or WindowsInstaller is 1): Uninstall and Repair run msiexec with the
#   product code. Repair uses /i with REINSTALL=ALL and REINSTALLMODE=omus, because
#   /f ignores properties on the command line.
#   EXE: Uninstall runs the QuietUninstallString as written. The tool adds no
#   switches. There is no Repair, because the key holds no repair command.
# The inner script blocks hold the rules and take no outside state, so the tests
# can run them alone.
$script:scriptBlockApplicationAction = {
    param (
        [Parameter(Mandatory = $true)][bool]$DryRun,
        [Parameter(Mandatory = $true)][ValidateSet('Uninstall', 'Repair')][string]$Operation,
        [Parameter(Mandatory = $true)][ValidateSet('64-bit', '32-bit')][string]$View,
        [Parameter(Mandatory = $true)][string]$KeyName
    )

    $ErrorActionPreference = 'Stop'
    $listStep = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $intTimeoutMilliseconds = 600000

    # MSI when the key name is a product code in braces and the uninstall string starts
    # with msiexec (optionally quoted, with or without a path), or WindowsInstaller is 1.
    $scriptBlockIsMsi = {
        param([string]$strKeyName, [string]$strUninstallString, [int]$intWindowsInstaller)
        $boolGuid = $strKeyName -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}\z'
        $boolMsiexec = $strUninstallString -match '^\s*"?(?:[^"]*[\\/])?msiexec(?:\.exe)?"?(?:\s|\z)'
        return [bool]($boolGuid -and ($boolMsiexec -or $intWindowsInstaller -eq 1))
    }

    # Splits a command line into a file path and the arguments. A quoted path ends at
    # the closing quote. Without quotes the path is the text up to and including the
    # first .exe that ends a word. Returns $null when no path is found, and when the path
    # is relative with a separator (for example .\x.exe), because the session folder
    # of WinRM would decide where it points. A full path (drive or UNC) and a bare file
    # name are the only forms that the tool accepts.
    $scriptBlockSplitCommand = {
        param([string]$strCommand)
        $strText = $strCommand.Trim()
        if ($strText.Length -eq 0) {
            return $null
        }
        $strPath = ''
        $strRest = ''
        if ($strText.StartsWith('"')) {
            $intEnd = $strText.IndexOf('"', 1)
            if ($intEnd -lt 2) {
                return $null
            }
            $strPath = $strText.Substring(1, $intEnd - 1)
            $strRest = $strText.Substring($intEnd + 1).Trim()
        } else {
            $objMatch = [regex]::Match($strText, '^(?<path>.+?\.exe)(?=\s|\z)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $objMatch.Success) {
                return $null
            }
            $strPath = $objMatch.Groups['path'].Value
            $strRest = $strText.Substring($strPath.Length).Trim()
        }
        $boolFull = $strPath -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/])'
        $boolBare = $strPath.IndexOfAny([char[]]@('\', '/')) -lt 0
        if (-not ($boolFull -or $boolBare)) {
            return $null
        }
        return [pscustomobject]@{ FilePath = $strPath; Arguments = $strRest }
    }

    # Maps the exit code of the installer. 0 is success. 3010 and 1641 are success with
    # a restart needed. 1605 on Uninstall is success only when the key is gone. 1618
    # means that another installation is in progress. Any other code is a failure.
    $scriptBlockMapExitCode = {
        param([string]$strOperation, [int]$intCode, [bool]$boolKeyGone, [bool]$boolKeyKnown = $true)
        $boolSucceeded = $false
        $boolRestart = $false
        $strText = ''
        if ($intCode -eq 0) {
            $boolSucceeded = $true
            $strText = 'The installer finished with exit code 0.'
            if ($strOperation -eq 'Uninstall' -and -not $boolKeyKnown) {
                $strText = '{0} The tool could not read the uninstall key after the run.' -f $strText
            } elseif ($strOperation -eq 'Uninstall' -and -not $boolKeyGone) {
                $strText = '{0} The uninstall key is still there. The installer can remove it later. Inspect the device again.' -f $strText
            }
        } elseif ($intCode -eq 3010 -or $intCode -eq 1641) {
            $boolSucceeded = $true
            $boolRestart = $true
            $strText = ('The installer finished with exit code {0}. A restart of the device is needed to finish. The tool never restarts the device.' -f $intCode)
            if ($strOperation -eq 'Uninstall' -and -not $boolKeyKnown) {
                $strText = '{0} The tool could not read the uninstall key after the run.' -f $strText
            } elseif ($strOperation -eq 'Uninstall' -and -not $boolKeyGone) {
                $strText = '{0} The uninstall key is still there. The installer can remove it later. Inspect the device again.' -f $strText
            }
        } elseif ($intCode -eq 1605 -and $strOperation -eq 'Uninstall') {
            if (-not $boolKeyKnown) {
                $strText = 'The installer returned 1605 (the product is not installed), but the tool could not read the uninstall key after the run. The result is not known.'
            } elseif ($boolKeyGone) {
                $boolSucceeded = $true
                $strText = 'The installer returned 1605 (the product is not installed), and the uninstall key is gone. The product is already removed.'
            } else {
                $strText = 'The installer returned 1605 (the product is not installed), but the uninstall key is still there. The entry is stale.'
            }
        } elseif ($intCode -eq 1618) {
            $strText = 'The installer returned 1618: another installation is in progress. Try again later.'
        } else {
            $strText = ('The installer failed with exit code {0}.' -f $intCode)
        }
        return [pscustomobject]@{ Succeeded = $boolSucceeded; RestartNeeded = $boolRestart; Text = $strText }
    }

    # Reads one uninstall key by view and key name. Returns $null when the key is not there.
    $scriptBlockReadKey = {
        param([string]$strView, [string]$strName)
        $strParent = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        if ($strView -eq '32-bit') {
            $strParent = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        }
        $objBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try {
            $objKey = $objBase.OpenSubKey(('{0}\{1}' -f $strParent, $strName), $false)
            if ($null -eq $objKey) {
                return $null
            }
            try {
                $scriptBlockValue = {
                    param($objOpenKey, [string]$strValueName)
                    $objValue = $objOpenKey.GetValue($strValueName, $null)
                    if ($null -eq $objValue) {
                        return ''
                    }
                    return [string]$objValue
                }
                $intSystemComponent = 0
                $intWindowsInstaller = 0
                [void][int]::TryParse((& $scriptBlockValue $objKey 'SystemComponent'), [ref]$intSystemComponent)
                [void][int]::TryParse((& $scriptBlockValue $objKey 'WindowsInstaller'), [ref]$intWindowsInstaller)
                return [pscustomobject]@{
                    DisplayName          = (& $scriptBlockValue $objKey 'DisplayName')
                    UninstallString      = (& $scriptBlockValue $objKey 'UninstallString')
                    QuietUninstallString = (& $scriptBlockValue $objKey 'QuietUninstallString')
                    SystemComponent      = $intSystemComponent
                    WindowsInstaller     = $intWindowsInstaller
                }
            } finally {
                $objKey.Dispose()
            }
        } finally {
            $objBase.Dispose()
        }
    }

    if ($KeyName -notmatch '^[^\\/:*?"<>|\x00-\x1F]{1,255}\z') {
        return [pscustomobject]@{ Succeeded = $false; Summary = 'The key name has characters that the tool does not accept.'; Steps = @($listStep) }
    }
    try {
        $objEntry = & $scriptBlockReadKey $View $KeyName
    } catch {
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The uninstall key cannot be read: {0}' -f $_.Exception.Message); Steps = @($listStep) }
    }
    if ($null -eq $objEntry) {
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The uninstall key {0} ({1} view) is not on the device now. Inspect the device again.' -f $KeyName, $View); Steps = @($listStep) }
    }
    $strDisplay = $objEntry.DisplayName
    if ([string]::IsNullOrWhiteSpace($strDisplay)) {
        $strDisplay = $KeyName
    }
    $boolMsi = & $scriptBlockIsMsi $KeyName $objEntry.UninstallString $objEntry.WindowsInstaller
    $strType = 'EXE'
    if ($boolMsi) {
        $strType = 'MSI'
    }
    $listStep.Add(('Key {0} ({1} view): {2}, type {3}.' -f $KeyName, $View, $strDisplay.Trim(), $strType))
    if ($objEntry.SystemComponent -eq 1) {
        return [pscustomobject]@{ Succeeded = $false; Summary = ('{0} is a system component, part of another product. The tool does not {1} it.' -f $strDisplay.Trim(), $Operation.ToLowerInvariant()); Steps = @($listStep) }
    }

    $strFilePath = ''
    $strArguments = ''
    $strCommandText = ''
    if ($boolMsi) {
        $strFilePath = 'msiexec.exe'
        if ($Operation -eq 'Uninstall') {
            $strArguments = '/x {0} /qn /norestart REBOOT=ReallySuppress' -f $KeyName
        } else {
            $strArguments = '/i {0} REINSTALL=ALL REINSTALLMODE=omus /qn /norestart REBOOT=ReallySuppress' -f $KeyName
        }
        $strCommandText = '{0} {1}' -f $strFilePath, $strArguments
    } else {
        if ($Operation -eq 'Repair') {
            return [pscustomobject]@{ Succeeded = $false; Summary = 'There is no documented repair command for this installer. The tool repairs MSI products only.'; Steps = @($listStep) }
        }
        if ([string]::IsNullOrWhiteSpace($objEntry.QuietUninstallString)) {
            return [pscustomobject]@{ Succeeded = $false; Summary = 'The entry has no quiet uninstall string. The tool does not guess silent switches.'; Steps = @($listStep) }
        }
        $strQuiet = [System.Environment]::ExpandEnvironmentVariables($objEntry.QuietUninstallString.Trim())
        $objSplit = & $scriptBlockSplitCommand $strQuiet
        if ($null -eq $objSplit) {
            return [pscustomobject]@{ Succeeded = $false; Summary = 'The quiet uninstall string has no file path that ends in .exe, or the path is relative. The tool does not guess the command.'; Steps = @($listStep) }
        }
        $strFilePath = $objSplit.FilePath
        $strArguments = $objSplit.Arguments
        if ($strFilePath.IndexOfAny([char[]]@('\', '/')) -lt 0) {
            # A bare file name is looked up in System32 only, never in the session folder.
            $strFilePath = Join-Path -Path ([System.Environment]::SystemDirectory) -ChildPath $strFilePath
        }
        if (-not (Test-Path -LiteralPath $strFilePath -PathType Leaf)) {
            return [pscustomobject]@{ Succeeded = $false; Summary = ('The uninstall program {0} is not on the device. The tool does not run the command.' -f $strFilePath); Steps = @($listStep) }
        }
        $strCommandText = $strQuiet
    }

    if ($DryRun) {
        $listStep.Add(('Dry run: would run: {0}' -f $strCommandText))
        return [pscustomobject]@{ Succeeded = $true; Summary = 'Dry run: the key is on the device and the command is ready. Nothing changed.'; Steps = @($listStep) }
    }

    $listStep.Add(('Running: {0}' -f $strCommandText))
    try {
        $hashtableStart = @{
            FilePath    = $strFilePath
            PassThru    = $true
            WindowStyle = 'Hidden'
        }
        if (-not [string]::IsNullOrEmpty($strArguments)) {
            $hashtableStart['ArgumentList'] = $strArguments
        }
        $objProcess = Start-Process @hashtableStart
        # Reading the handle keeps the exit code readable after the process ends.
        $null = $objProcess.Handle
        $boolExited = $objProcess.WaitForExit($intTimeoutMilliseconds)
    } catch {
        $listStep.Add(('The command did not start: {0}' -f $_.Exception.Message))
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The {0} did not start: {1}' -f $Operation.ToLowerInvariant(), $_.Exception.Message); Steps = @($listStep) }
    }
    if (-not $boolExited) {
        $listStep.Add(('The installer (process {0}) still runs after 10 minutes.' -f $objProcess.Id))
        return [pscustomobject]@{ Succeeded = $false; Summary = 'The installer is still running after 10 minutes. The outcome is not known. Inspect the device again later.'; Steps = @($listStep) }
    }
    $intExitCode = [int]$objProcess.ExitCode
    $listStep.Add(('The installer ended with exit code {0}.' -f $intExitCode))

    $boolKeyGone = $false
    $boolKeyKnown = $true
    if ($Operation -eq 'Uninstall') {
        try {
            $boolKeyGone = ($null -eq (& $scriptBlockReadKey $View $KeyName))
            if ($boolKeyGone) {
                $listStep.Add(('Check after the uninstall: the key {0} is gone.' -f $KeyName))
            } else {
                $listStep.Add(('Check after the uninstall: the key {0} is still there.' -f $KeyName))
            }
        } catch {
            $boolKeyKnown = $false
            $listStep.Add(('Check after the uninstall: the tool could not read the uninstall key: {0}' -f $_.Exception.Message))
        }
    }
    $objMap = & $scriptBlockMapExitCode $Operation $intExitCode $boolKeyGone $boolKeyKnown
    $strSummary = ('{0} of {1}: {2}' -f $Operation, $strDisplay.Trim(), $objMap.Text)
    [pscustomobject]@{ Succeeded = $objMap.Succeeded; Summary = $strSummary; Steps = @($listStep) }
}

#endregion Remote script blocks

#region Private helpers

function Invoke-ActionDeviceScript {
    # .SYNOPSIS
    # Runs one action script block on the device with Invoke-Command.
    #
    # .DESCRIPTION
    # The only place where the action code connects to a device. It exists as a
    # function so that tests can replace it.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER ScriptBlock
    # The script block to run on the device.
    #
    # .PARAMETER ArgumentList
    # The arguments for the script block.
    #
    # .PARAMETER Credential
    # An optional credential for the WinRM connection.
    #
    # .EXAMPLE
    # $objRaw = Invoke-ActionDeviceScript -ComputerName 'WS01' -ScriptBlock $script:scriptBlockPolicyUpdate -ArgumentList @($true)
    #
    # # $objRaw.Succeeded is $true when the client answers.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [object] The output of the script block.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([object])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$ArgumentList = @(),

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $hashtableArgument = @{
            ComputerName = $ComputerName
            ScriptBlock  = $ScriptBlock
            ArgumentList = $ArgumentList
            ErrorAction  = 'Stop'
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableArgument['Credential'] = $Credential
        }
        Invoke-Command @hashtableArgument
    }
}

function New-DeviceInspectorActionRecord {
    # .SYNOPSIS
    # Builds the result object that every action returns, or a start record.
    #
    # .DESCRIPTION
    # The window writes a start record to the action log before a run, so a run
    # that stops part way still leaves a line. Outcome is OK, FAILED, STARTED or
    # CLOSED. The ID ties the start line and the result line of one run together.
    #
    # .PARAMETER Action
    # The name of the action.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER DryRun
    # $true when the action ran as a dry run.
    #
    # .PARAMETER Succeeded
    # $true when the action did what it had to do.
    #
    # .PARAMETER ActionId
    # Optional. The ID of the run, from New-DeviceInspectorActionId. An action function
    # does not know the ID. The window adds it to the result with Add-DeviceInspectorActionId.
    #
    # .PARAMETER Outcome
    # Optional. STARTED for a start record. CLOSED for a run that was still open when the
    # window closed. When omitted, Succeeded gives OK or FAILED.
    #
    # .PARAMETER Summary
    # One sentence about the outcome.
    #
    # .PARAMETER Steps
    # One line for each step that ran or would run.
    #
    # .EXAMPLE
    # $objResult = New-DeviceInspectorActionRecord -Action 'Client policy update' -ComputerName 'WS01' -DryRun $true -Succeeded $true -Summary 'Done.' -Steps @()
    #
    # # $objResult.Mode = 'DRY RUN'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties: ActionId, Action, ComputerName, DryRun, Mode, StartedAt,
    # Account, Succeeded, Outcome, Summary, Steps.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.1.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [bool]$DryRun,

        [Parameter(Mandatory = $true)]
        [bool]$Succeeded,

        [Parameter(Mandatory = $false)]
        [string]$ActionId = '',

        [Parameter(Mandatory = $false)]
        [ValidateSet('OK', 'FAILED', 'STARTED', 'CLOSED')]
        [string]$Outcome,

        [Parameter(Mandatory = $true)]
        [string]$Summary,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Steps
    )

    process {
        $strMode = 'RUN'
        if ($DryRun) {
            $strMode = 'DRY RUN'
        }
        $strOutcome = $Outcome
        if ([string]::IsNullOrEmpty($strOutcome)) {
            $strOutcome = 'FAILED'
            if ($Succeeded) {
                $strOutcome = 'OK'
            }
        }
        $strAccount = [System.Environment]::UserName
        if (-not [string]::IsNullOrEmpty([System.Environment]::UserDomainName)) {
            $strAccount = '{0}\{1}' -f [System.Environment]::UserDomainName, [System.Environment]::UserName
        }
        [pscustomobject]@{
            ActionId     = $ActionId
            Action       = $Action
            ComputerName = $ComputerName
            DryRun       = $DryRun
            Mode         = $strMode
            StartedAt    = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            Account      = $strAccount
            Succeeded    = $Succeeded
            Outcome      = $strOutcome
            Summary      = $Summary
            Steps        = @($Steps)
        }
    }
}

function Invoke-ActionOnDevice {
    # .SYNOPSIS
    # Runs one device action script block and turns its output into a result object.
    #
    # .DESCRIPTION
    # A connection failure or a script failure becomes a result with Succeeded
    # $false. The function does not throw for these failures.
    #
    # .PARAMETER Action
    # The name of the action.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER ScriptBlock
    # The script block. Its first parameter is DryRun. It returns an object with
    # Succeeded, Summary and Steps.
    #
    # .PARAMETER ArgumentList
    # More arguments for the script block, after DryRun.
    #
    # .PARAMETER DryRun
    # Read the state and list the steps only.
    #
    # .PARAMETER Credential
    # An optional credential for the WinRM connection.
    #
    # .EXAMPLE
    # $objResult = Invoke-ActionOnDevice -Action 'Client policy update' -ComputerName 'WS01' -ScriptBlock $script:scriptBlockPolicyUpdate -DryRun
    #
    # # $objResult.Steps lists what the action would do.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] See New-DeviceInspectorActionRecord.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$ArgumentList = @(),

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $boolDryRun = $DryRun.IsPresent
        $hashtableInvoke = @{
            ComputerName = $ComputerName
            ScriptBlock  = $ScriptBlock
            ArgumentList = @(, $boolDryRun) + @($ArgumentList)
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableInvoke['Credential'] = $Credential
        }
        try {
            $objRaw = @(Invoke-ActionDeviceScript @hashtableInvoke) | Select-Object -Last 1
        } catch {
            Write-Debug -Message $_.Exception.Message
            $strSummary = 'Cannot run the action on {0}: {1}' -f $ComputerName, $_.Exception.Message
            if (-not $boolDryRun) {
                $strSummary = '{0} The connection can fail after a step ran. Inspect the device to see its state.' -f $strSummary
            }
            return New-DeviceInspectorActionRecord -Action $Action -ComputerName $ComputerName -DryRun $boolDryRun -Succeeded $false -Summary $strSummary -Steps @()
        }
        if ($null -eq $objRaw -or $null -eq $objRaw.PSObject.Properties['Succeeded']) {
            return New-DeviceInspectorActionRecord -Action $Action -ComputerName $ComputerName -DryRun $boolDryRun -Succeeded $false -Summary 'The device returned no result.' -Steps @()
        }
        New-DeviceInspectorActionRecord -Action $Action -ComputerName $ComputerName -DryRun $boolDryRun -Succeeded ([bool]$objRaw.Succeeded) -Summary ([string]$objRaw.Summary) -Steps ([string[]]@($objRaw.Steps))
    }
}

#endregion Private helpers

#region Public functions

function Invoke-DeviceInspectorPolicyUpdate {
    # .SYNOPSIS
    # Makes the Configuration Manager client on a device request and evaluate machine policy.
    #
    # .DESCRIPTION
    # Runs on the device over WinRM. It triggers the client schedules Machine Policy
    # Assignments Request and Machine Policy Evaluation with the TriggerSchedule
    # method of SMS_Client, in that order. With DryRun it checks that the client
    # answers and lists the two steps, and changes nothing.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER DryRun
    # Check the client and list the steps only.
    #
    # .PARAMETER Credential
    # An optional credential for the WinRM connection.
    #
    # .EXAMPLE
    # Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01' -DryRun
    #
    # # Lists the two schedules. Nothing changes.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties: Action, ComputerName, DryRun, Mode, StartedAt,
    # Account, Succeeded, Outcome, Summary, Steps.
    #
    # .NOTES
    # Non-throwing contract: a failure gives Succeeded $false and a Summary.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]{1,255}\z')]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $hashtableAction = @{
            Action       = 'Client policy update'
            ComputerName = $ComputerName
            ScriptBlock  = $script:scriptBlockPolicyUpdate
            DryRun       = $DryRun
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableAction['Credential'] = $Credential
        }
        Invoke-ActionOnDevice @hashtableAction
    }
}

function Invoke-DeviceInspectorFullInventory {
    # .SYNOPSIS
    # Makes the Configuration Manager client on a device send a full hardware inventory.
    #
    # .DESCRIPTION
    # Runs on the device over WinRM. It deletes the InventoryActionStatus record of
    # hardware inventory in root\ccm\invagt, then triggers the Hardware Inventory
    # schedule with SMS_Client.TriggerSchedule. With DryRun it reads the record,
    # lists the steps, and changes nothing.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER DryRun
    # Read the record and list the steps only.
    #
    # .PARAMETER Credential
    # An optional credential for the WinRM connection.
    #
    # .EXAMPLE
    # Invoke-DeviceInspectorFullInventory -ComputerName 'WS01' -DryRun
    #
    # # Shows the status record and the two steps. Nothing changes.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] See New-DeviceInspectorActionRecord.
    #
    # .NOTES
    # Non-throwing contract: a failure gives Succeeded $false and a Summary.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]{1,255}\z')]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $hashtableAction = @{
            Action       = 'Full hardware inventory'
            ComputerName = $ComputerName
            ScriptBlock  = $script:scriptBlockFullInventory
            DryRun       = $DryRun
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableAction['Credential'] = $Credential
        }
        Invoke-ActionOnDevice @hashtableAction
    }
}

function Invoke-DeviceInspectorInventoryRepair {
    # .SYNOPSIS
    # Repairs a corrupt site inventory of a device with a full hardware inventory.
    #
    # .DESCRIPTION
    # The same device steps as Invoke-DeviceInspectorFullInventory, under the action
    # name Corrupt-inventory repair. The window offers it only when
    # Test-DeviceInspectionInventory returns the state Corrupt.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER DryRun
    # Read the record and list the steps only.
    #
    # .PARAMETER Credential
    # An optional credential for the WinRM connection.
    #
    # .EXAMPLE
    # Invoke-DeviceInspectorInventoryRepair -ComputerName 'WS01' -DryRun
    #
    # # Shows the status record and the two steps. Nothing changes.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] See New-DeviceInspectorActionRecord.
    #
    # .NOTES
    # Non-throwing contract: a failure gives Succeeded $false and a Summary.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]{1,255}\z')]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $hashtableAction = @{
            Action       = 'Corrupt-inventory repair'
            ComputerName = $ComputerName
            ScriptBlock  = $script:scriptBlockFullInventory
            DryRun       = $DryRun
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableAction['Credential'] = $Credential
        }
        Invoke-ActionOnDevice @hashtableAction
    }
}

function Invoke-DeviceInspectorUpdateInstall {
    # .SYNOPSIS
    # Installs the pending software updates of the client policy on a device.
    #
    # .DESCRIPTION
    # Runs on the device over WinRM. It reads CCM_SoftwareUpdate, keeps the updates
    # that are missing on the device (ComplianceState 0), and passes them to
    # CCM_SoftwareUpdatesManager.InstallUpdates. UpdateId limits the list. With
    # DryRun it lists the updates and changes nothing.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER UpdateId
    # Optional. The UpdateID values of the updates to install. Omit it for all
    # updates that are missing on the device. The window always passes the IDs of
    # the rows that the person confirmed.
    #
    # .PARAMETER Scope
    # Selected or All. Sets only the action name in the log.
    #
    # .PARAMETER DryRun
    # List the updates only.
    #
    # .PARAMETER Credential
    # An optional credential for the WinRM connection.
    #
    # .EXAMPLE
    # Invoke-DeviceInspectorUpdateInstall -ComputerName 'WS01' -DryRun
    #
    # # Lists the updates that the run would install. Nothing changes.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] See New-DeviceInspectorActionRecord.
    #
    # .NOTES
    # Non-throwing contract: a failure on the device gives Succeeded $false and a
    # Summary. A ComputerName or an UpdateId outside its pattern throws before the
    # function runs.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.1
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]{1,255}\z')]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [ValidatePattern('^[A-Za-z0-9_{}/.-]{1,200}\z')]
        [string[]]$UpdateId = @(),

        [Parameter(Mandatory = $false)]
        [ValidateSet('Selected', 'All')]
        [string]$Scope,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $strAction = 'Install all pending updates'
        if ($Scope -eq 'Selected' -or ([string]::IsNullOrEmpty($Scope) -and @($UpdateId).Count -gt 0)) {
            $strAction = 'Install selected pending updates'
        }
        $hashtableAction = @{
            Action       = $strAction
            ComputerName = $ComputerName
            ScriptBlock  = $script:scriptBlockUpdateInstall
            ArgumentList = @(, [string[]]@($UpdateId))
            DryRun       = $DryRun
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableAction['Credential'] = $Credential
        }
        Invoke-ActionOnDevice @hashtableAction
    }
}

function Invoke-DeviceInspectorApplicationAction {
    # .SYNOPSIS
    # Uninstalls or repairs one entry of the uninstall registry keys on a device.
    #
    # .DESCRIPTION
    # Runs on the device over WinRM. The caller names the entry by registry view and
    # key name only. The device reads that key again, checks the rules again, and
    # builds the command line itself. A caller cannot send a command line.
    #
    # MSI entry (key name is a product code in braces, and the uninstall string
    # starts with msiexec or WindowsInstaller is 1): Uninstall runs
    # msiexec.exe /x {GUID} /qn /norestart REBOOT=ReallySuppress. Repair runs
    # msiexec.exe /i {GUID} REINSTALL=ALL REINSTALLMODE=omus /qn /norestart
    # REBOOT=ReallySuppress.
    #
    # EXE entry: Uninstall runs the QuietUninstallString as written, and adds no
    # switches. An EXE entry has no Repair, and an entry without a quiet uninstall
    # string has no Uninstall. The tool does not guess silent switches. A system
    # component (SystemComponent 1) has neither.
    #
    # The run waits up to 10 minutes for the installer. Exit codes: 0 is success.
    # 3010 and 1641 are success, and the summary says that the device needs a
    # restart. The tool never restarts the device. 1605 on Uninstall is success only
    # when the key is gone after the run. 1618 is a failure: another installation is
    # in progress. Any other code is a failure with the code in the summary. After
    # Uninstall the device checks that the key is gone and adds a step line.
    #
    # With DryRun it reads the key, checks the rules, lists the exact command, and
    # changes nothing.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER Operation
    # Uninstall or Repair.
    #
    # .PARAMETER View
    # The registry view of the entry: 64-bit (HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall)
    # or 32-bit (HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall).
    #
    # .PARAMETER KeyName
    # The name of the subkey under Uninstall. For an MSI product it is the product code
    # in braces. The name cannot hold a backslash, a slash or other path characters.
    #
    # .PARAMETER DryRun
    # Read the key and list the command only.
    #
    # .PARAMETER Credential
    # An optional credential for the WinRM connection.
    #
    # .EXAMPLE
    # Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -Operation Uninstall -View '64-bit' -KeyName '{AC76BA86-7AD7-1033-7B44-AC0F074E4100}' -DryRun
    #
    # # Lists the msiexec command that the run would use. Nothing changes.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] See New-DeviceInspectorActionRecord.
    #
    # .NOTES
    # Non-throwing contract: a failure on the device gives Succeeded $false and a
    # Summary. A parameter outside its pattern throws before the function runs.
    #
    # Version 2 replaced the ApplicationId parameter (Configuration Manager
    # application policy) with View and KeyName (breaking change).
    #
    # Positional parameters: none.
    #
    # Version: 2.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]{1,255}\z')]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Uninstall', 'Repair')]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [ValidateSet('64-bit', '32-bit')]
        [string]$View,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[^\\/:*?"<>|\x00-\x1F]{1,255}\z')]
        [string]$KeyName,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $hashtableAction = @{
            Action       = ('{0} application' -f $Operation)
            ComputerName = $ComputerName
            ScriptBlock  = $script:scriptBlockApplicationAction
            ArgumentList = @($Operation, $View, $KeyName)
            DryRun       = $DryRun
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableAction['Credential'] = $Credential
        }
        Invoke-ActionOnDevice @hashtableAction
    }
}

function Invoke-DeviceInspectorCollectionChange {
    # .SYNOPSIS
    # Adds or removes the direct membership rule of a device in a device collection.
    #
    # .DESCRIPTION
    # Runs on the site with the ConfigurationManager cmdlets. Remove deletes the
    # direct rule of the device; a membership through a query, include or other
    # rule cannot be removed this way, so the function refuses it. Add creates a
    # direct rule. After a change, the function starts a membership update of the
    # collection and asks the client for machine policy. With DryRun it checks the
    # device, the collection and the rule, and changes nothing. Built-in
    # collections (ID that starts with SMS) have no direct rules and are refused.
    #
    # .PARAMETER ComputerName
    # The device name. The part before the first dot is the site name of the device.
    #
    # .PARAMETER SiteServer
    # The SMS Provider computer.
    #
    # .PARAMETER SiteCode
    # The site code.
    #
    # .PARAMETER CollectionId
    # The eight-character collection ID.
    #
    # .PARAMETER Operation
    # Add or Remove.
    #
    # .PARAMETER ExpectedResourceId
    # Optional. The resource ID of the inspection. The function refuses the change
    # when the device record of the site now has another ID.
    #
    # .PARAMETER DryRun
    # Check and list the steps only.
    #
    # .PARAMETER Credential
    # An optional credential for the site drive.
    #
    # .EXAMPLE
    # Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove -DryRun
    #
    # # Checks that WS01 has a direct rule in XYZ0001F. Nothing changes.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] See New-DeviceInspectorActionRecord.
    #
    # .NOTES
    # Non-throwing contract: a failure gives Succeeded $false and a Summary. A
    # parameter outside its pattern throws before the function runs.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]{1,255}\z')]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteServer,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9]{3}\z')]
        [string]$SiteCode,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9]{8}\z')]
        [string]$CollectionId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Add', 'Remove')]
        [string]$Operation,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 2147483647)]
        [int]$ExpectedResourceId = 0,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $boolDryRun = $DryRun.IsPresent
        $strAction = 'Remove from collection'
        if ($Operation -eq 'Add') {
            $strAction = 'Add to collection'
        }
        $strShortName = $ComputerName.Split('.')[0]
        $listStep = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $scriptBlockEnd = {
            param([bool]$boolSucceeded, [string]$strSummary)
            New-DeviceInspectorActionRecord -Action $strAction -ComputerName $ComputerName -DryRun $boolDryRun -Succeeded $boolSucceeded -Summary $strSummary -Steps ([string[]]$listStep.ToArray())
        }
        if ($CollectionId.StartsWith('SMS', [System.StringComparison]::OrdinalIgnoreCase)) {
            return (& $scriptBlockEnd $false ('{0} is a built-in collection. Built-in collections have no direct membership rules.' -f $CollectionId))
        }
        $objConnection = $null
        try {
            $hashtableConnect = @{ SiteServer = $SiteServer; SiteCode = $SiteCode }
            if ($PSBoundParameters.ContainsKey('Credential')) {
                $hashtableConnect['Credential'] = $Credential
            }
            $objConnection = Connect-InspectorSite @hashtableConnect
            $listStep.Add(('Site {0} on {1} answers.' -f $SiteCode, $SiteServer))
            $arrDevice = @(Get-CMDevice -Name $strShortName -Fast -DisableWildcardHandling -ErrorAction Stop -WarningAction SilentlyContinue)
            if ($arrDevice.Count -ne 1) {
                return (& $scriptBlockEnd $false ('The site has {0} device records named {1}. The change needs exactly one.' -f $arrDevice.Count, $strShortName))
            }
            $strResourceId = [string]$arrDevice[0].ResourceID
            $listStep.Add(('Device {0}, resource ID {1}.' -f $strShortName, $strResourceId))
            if ($ExpectedResourceId -gt 0 -and $strResourceId -ne [string]$ExpectedResourceId) {
                return (& $scriptBlockEnd $false ('The device record of the site has resource ID {0}, not {1} as in the inspection. Inspect the device again.' -f $strResourceId, $ExpectedResourceId))
            }
            $objCollection = Get-CMDeviceCollection -Id $CollectionId -ErrorAction Stop
            if ($null -eq $objCollection) {
                return (& $scriptBlockEnd $false ('The site has no device collection {0}.' -f $CollectionId))
            }
            $listStep.Add(('Collection {0} {1}.' -f $CollectionId, [string]$objCollection.Name))
            $arrRule = @(Get-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionId -ResourceId $strResourceId -ErrorAction Stop)
            if ($Operation -eq 'Remove' -and $arrRule.Count -eq 0) {
                return (& $scriptBlockEnd $false ('The device has no direct rule in {0}. It is a member through a query, include or other rule, which this tool does not change.' -f $CollectionId))
            }
            if ($Operation -eq 'Add' -and $arrRule.Count -gt 0) {
                return (& $scriptBlockEnd $false ('The device already has a direct rule in {0}.' -f $CollectionId))
            }
            # A direct rule adds a device only when the limiting collection holds it.
            if ($Operation -eq 'Add') {
                if ($null -eq $objCollection.PSObject.Properties['LimitToCollectionID']) {
                    return (& $scriptBlockEnd $false ('The limiting collection of {0} cannot be read.' -f $CollectionId))
                }
                $strLimit = [string]$objCollection.LimitToCollectionID
                if (-not [string]::IsNullOrEmpty($strLimit)) {
                    $arrLimitMember = @(Get-CMCollectionMember -CollectionId $strLimit -ResourceId ([int]$strResourceId) -ErrorAction Stop)
                    if ($arrLimitMember.Count -eq 0) {
                        return (& $scriptBlockEnd $false ('The device is not a member of the limiting collection {0} of {1}, or the account cannot read that collection. A direct rule would not add it.' -f $strLimit, $CollectionId))
                    }
                    $listStep.Add(('The device is a member of the limiting collection {0}.' -f $strLimit))
                }
            }
            if ($boolDryRun) {
                if ($Operation -eq 'Remove') {
                    $listStep.Add(('Dry run: would remove the direct rule of resource {0} from {1}, update the collection membership, and request machine policy on the device.' -f $strResourceId, $CollectionId))
                } else {
                    $listStep.Add(('Dry run: would add a direct rule for resource {0} to {1}, update the collection membership, and request machine policy on the device.' -f $strResourceId, $CollectionId))
                }
                return (& $scriptBlockEnd $true 'Dry run: the site answers. Nothing changed.')
            }
            try {
                if ($Operation -eq 'Remove') {
                    Remove-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionId -ResourceId $strResourceId -Force -ErrorAction Stop
                    $listStep.Add(('Removed the direct rule of resource {0} from {1}.' -f $strResourceId, $CollectionId))
                } else {
                    Add-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionId -ResourceId $strResourceId -ErrorAction Stop
                    $listStep.Add(('Added a direct rule for resource {0} to {1}.' -f $strResourceId, $CollectionId))
                }
            } catch {
                $listStep.Add(('{0} failed: {1}' -f $strAction, $_.Exception.Message))
                return (& $scriptBlockEnd $false ('The site did not change the rule. {0}' -f $_.Exception.Message))
            }
            $boolUpdateStarted = $false
            try {
                Invoke-CMCollectionUpdate -CollectionId $CollectionId -ErrorAction Stop
                $boolUpdateStarted = $true
                $listStep.Add(('Started a membership update of {0}.' -f $CollectionId))
            } catch {
                $listStep.Add(('The membership update did not start: {0}. The site updates the collection on its schedule.' -f $_.Exception.Message))
            }
            # The client notification has an effect only after the site shows the new
            # membership, so the function waits for it, up to 60 seconds.
            if ($boolUpdateStarted) {
                $boolSeen = $false
                $strReadError = ''
                $intTry = 0
                do {
                    $intTry++
                    Start-Sleep -Seconds 5
                    try {
                        $arrMember = @(Get-CMCollectionMember -CollectionId $CollectionId -ResourceId ([int]$strResourceId) -ErrorAction Stop)
                        $boolDirectNow = @($arrMember | Where-Object { $true -eq $_.IsDirect }).Count -gt 0
                        if ($Operation -eq 'Remove') {
                            $boolSeen = -not $boolDirectNow
                        } else {
                            $boolSeen = $boolDirectNow
                        }
                    } catch {
                        $strReadError = $_.Exception.Message
                    }
                } until ($boolSeen -or $intTry -ge 12)
                if ($boolSeen) {
                    $listStep.Add(('The site shows the new membership after {0} seconds.' -f ($intTry * 5)))
                } else {
                    $strNotShown = 'The site did not show the new membership within 60 seconds. The client gets it at a later policy cycle.'
                    if (-not [string]::IsNullOrEmpty($strReadError)) {
                        $strNotShown = '{0} Last read error: {1}' -f $strNotShown, $strReadError
                    }
                    $listStep.Add($strNotShown)
                }
            }
            try {
                Invoke-CMClientAction -DeviceName $strShortName -ActionType 'ClientNotificationRequestMachinePolicyNow' -ErrorAction Stop
                $listStep.Add('Sent the client notification Request machine policy now.')
            } catch {
                $listStep.Add(('The client notification failed: {0}. The client gets the change at its next policy cycle.' -f $_.Exception.Message))
            }
            return (& $scriptBlockEnd $true ('The site changed the direct rule of {0} in {1}. Inspect the device again after the membership update.' -f $strShortName, $CollectionId))
        } catch {
            Write-Debug -Message $_.Exception.Message
            return (& $scriptBlockEnd $false ('Cannot run the action on site {0}: {1}' -f $SiteCode, $_.Exception.Message))
        } finally {
            Disconnect-InspectorSite -Connection $objConnection
        }
    }
}

function ConvertTo-DeviceInspectorActionText {
    # .SYNOPSIS
    # Formats an action result as text lines.
    #
    # .DESCRIPTION
    # The first line holds the time, the action ID, the account, the device, the action,
    # the mode, the outcome and the summary. A result without an ID shows a hyphen in
    # the ID field. One indented line follows for each step. Line breaks and control
    # characters in a field become one space, so text from the device cannot add a
    # line to the action log.
    #
    # .PARAMETER Result
    # The object that an action function returns.
    #
    # .EXAMPLE
    # ConvertTo-DeviceInspectorActionText -Result $objResult
    #
    # # <UTC time> | <ID> | <domain\account> | WS01 | Client policy update | DRY RUN | OK | Dry run: ...
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] One string for each line.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.1.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    process {
        $scriptBlockLine = { param($objValue) ([regex]::Replace([string]$objValue, '[\x00-\x1F\x7F]+', ' ')).Trim() }
        $strOutcome = 'FAILED'
        if ($null -ne $Result.PSObject.Properties['Outcome'] -and -not [string]::IsNullOrEmpty([string]$Result.Outcome)) {
            $strOutcome = [string]$Result.Outcome
        } elseif ($Result.Succeeded) {
            $strOutcome = 'OK'
        }
        $strActionId = '-'
        if ($null -ne $Result.PSObject.Properties['ActionId'] -and -not [string]::IsNullOrEmpty([string]$Result.ActionId)) {
            $strActionId = [string]$Result.ActionId
        }
        $arrField = @($Result.StartedAt, $strActionId, $Result.Account, $Result.ComputerName, $Result.Action, $Result.Mode, $strOutcome, $Result.Summary) | ForEach-Object { & $scriptBlockLine $_ }
        $arrField -join ' | '
        foreach ($strStep in @($Result.Steps)) {
            '    {0}' -f (& $scriptBlockLine $strStep)
        }
    }
}

function Write-DeviceInspectorActionLog {
    # .SYNOPSIS
    # Appends an action result to the action log file.
    #
    # .DESCRIPTION
    # The action log keeps every run and every dry run, from every session, in one
    # file. The function creates the folder and the file when they do not exist and
    # writes UTF-8 text without a byte order mark.
    #
    # .PARAMETER Path
    # The action log file.
    #
    # .PARAMETER Result
    # The object that an action function returns.
    #
    # .EXAMPLE
    # Write-DeviceInspectorActionLog -Path 'C:\Tools\Logs\DeviceInspector-actions.log' -Result $objResult
    #
    # # Returns the full path of the log file.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The full path of the log file.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    process {
        $strFullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($strFullPath))
        $strText = (@(ConvertTo-DeviceInspectorActionText -Result $Result) -join "`r`n") + "`r`n"
        $objEncoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false
        [System.IO.File]::AppendAllText($strFullPath, $strText, $objEncoding)
        $strFullPath
    }
}

function Write-DeviceInspectorCloseLog {
    # .SYNOPSIS
    # Writes one action log line for each run that was still open when the window closed.
    #
    # .DESCRIPTION
    # When the window closes, the tool stops waiting for the runs that are still open, and it
    # cannot write their result lines. A run on a device can stop before it is complete, so the
    # result is not known. The close line has the outcome CLOSED and the ID of the run, so the
    # start line of the run and the close line belong together. The function returns the number
    # of lines written.
    #
    # .PARAMETER Path
    # The action log file.
    #
    # .PARAMETER Run
    # The runs that are still open. Each run comes from New-DeviceInspectorActionRun.
    #
    # .EXAMPLE
    # $intWritten = Write-DeviceInspectorCloseLog -Path 'C:\Tools\Logs\DeviceInspector-actions.log' -Run $arrOpenRun
    #
    # # Returns 1 for one open run.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [int] The number of lines written.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Run
    )

    process {
        $intWritten = 0
        foreach ($objRun in @($Run)) {
            if ($null -eq $objRun) {
                continue
            }
            $strSummary = 'The window closed while this run was open. The tool stopped waiting for it. The run can stop before it is complete. The result is not known.'
            $objRecord = New-DeviceInspectorActionRecord -Action ([string]$objRun.Action) -ComputerName ([string]$objRun.ComputerName) -DryRun ([bool]$objRun.DryRun) -Succeeded $false -Outcome 'CLOSED' -ActionId ([string]$objRun.ActionId) -Summary $strSummary -Steps @(('The run started at {0}.' -f [string]$objRun.StartedAt))
            $null = Write-DeviceInspectorActionLog -Path $Path -Result $objRecord
            $intWritten++
        }
        $intWritten
    }
}

function Get-DeviceInspectorCloseWarningText {
    # .SYNOPSIS
    # Returns the text of the close warning for the runs that are still open.
    #
    # .DESCRIPTION
    # The text uses the singular for one run and the plural for more runs. It ends with one
    # line for each run, with the action, the device and the action ID.
    #
    # .PARAMETER Run
    # The runs that are still open. Each run comes from New-DeviceInspectorActionRun.
    #
    # .PARAMETER NewLine
    # The line break. The default is the line break of the system.
    #
    # .EXAMPLE
    # Get-DeviceInspectorCloseWarningText -Run $arrOpenRun
    #
    # # Returns "1 action is still running. ..." for one open run.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The text of the warning.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Run,

        [Parameter(Mandatory = $false)]
        [string]$NewLine = [Environment]::NewLine
    )

    process {
        $arrRun = @(@($Run) | Where-Object { $null -ne $_ })
        $intCount = $arrRun.Count
        if ($intCount -eq 1) {
            $strHead = '1 action is still running. If you close the tool, it stops waiting for it, and the run on the device can stop before it is complete. Wait for the running action to end before you close.'
        }
        else {
            $strHead = ('{0} actions are still running. If you close the tool, it stops waiting for them, and a run on a device can stop before it is complete. Wait for the running actions to end before you close.' -f $intCount)
        }
        $arrName = @($arrRun | ForEach-Object { '{0} on {1} (ID {2})' -f $_.Action, $_.ComputerName, $_.ActionId })
        '{0}{1}{1}{2}' -f $strHead, $NewLine, ($arrName -join $NewLine)
    }
}

function Get-DeviceInspectorApplicationLabel {
    # .SYNOPSIS
    # Returns the name of an application with its version, without a repeated version.
    #
    # .DESCRIPTION
    # Many display names already hold the version, for example "Microsoft Visual C++ 2022 X86
    # Minimum Runtime - 14.51.36247". The function adds the version only when the name does
    # not hold it yet. An empty version adds nothing.
    #
    # .PARAMETER Name
    # The display name of the application.
    #
    # .PARAMETER Version
    # The display version of the application.
    #
    # .EXAMPLE
    # Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool' -Version '1.2.3'
    #
    # # Returns "Contoso Tool 1.2.3".
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The name, and the version when the name does not hold it.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version
    )

    process {
        $strName = ([string]$Name).Trim()
        $strVersion = ([string]$Version).Trim()
        if ($strVersion.Length -eq 0 -or $strName.IndexOf($strVersion, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $strName
        }
        '{0} {1}' -f $strName, $strVersion
    }
}

function Add-DeviceInspectorActionId {
    # .SYNOPSIS
    # Sets the action ID on the result that an action function returned.
    #
    # .DESCRIPTION
    # An action function does not know the ID of its run. The window calls this function
    # when the run ends, so the result line carries the same ID as the start line.
    #
    # .PARAMETER Result
    # The object that an action function returned.
    #
    # .PARAMETER ActionId
    # The ID of the run.
    #
    # .EXAMPLE
    # $objResult = Add-DeviceInspectorActionId -Result $objResult -ActionId 'a1b2c3d4'
    #
    # # $objResult.ActionId = 'a1b2c3d4'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] The same result object, with the property ActionId.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result,

        [Parameter(Mandatory = $true)]
        [string]$ActionId
    )

    process {
        Add-Member -InputObject $Result -NotePropertyName 'ActionId' -NotePropertyValue $ActionId -Force
        $Result
    }
}

function New-DeviceInspectorActionId {
    # .SYNOPSIS
    # Returns a short unique ID for one action run.
    #
    # .DESCRIPTION
    # The ID has eight lower-case hexadecimal characters, taken from a new GUID. The window
    # makes one ID for each run and each dry run. The start line, the result line and the
    # close line of the action log carry it, and the list of running actions shows it.
    #
    # .EXAMPLE
    # $strId = New-DeviceInspectorActionId
    #
    # # $strId = 'a1b2c3d4'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The ID.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param ()

    process {
        [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    }
}

function New-DeviceInspectorActionRun {
    # .SYNOPSIS
    # Builds the object that describes one action run.
    #
    # .DESCRIPTION
    # The window keeps one such object for each running action. The list of running
    # actions shows it, and the one-action-for-each-device check reads it.
    #
    # .PARAMETER ActionId
    # The ID of the run, from New-DeviceInspectorActionId.
    #
    # .PARAMETER Action
    # The name of the action.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER DryRun
    # $true for a dry run.
    #
    # .PARAMETER ResourceId
    # Optional. The site resource ID of the device, when the inspection knows it. Two runs with the
    # same resource ID are runs on the same device, even when the names differ.
    #
    # .EXAMPLE
    # $objRun = New-DeviceInspectorActionRun -ActionId 'a1b2c3d4' -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false
    #
    # # $objRun.Mode = 'RUN'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties: ActionId, Action, ComputerName, DeviceKey, ResourceId, DryRun, Mode, StartedAt (local time), StartedAtUtc.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.1.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ActionId,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [bool]$DryRun,

        [Parameter(Mandatory = $false)]
        [long]$ResourceId = 0
    )

    process {
        $strMode = 'RUN'
        if ($DryRun) {
            $strMode = 'DRY RUN'
        }
        $dateStart = [datetime]::Now
        [pscustomobject]@{
            ActionId     = $ActionId
            Action       = $Action
            ComputerName = $ComputerName
            DeviceKey    = Get-DeviceInspectorDeviceKey -ComputerName $ComputerName
            ResourceId   = $ResourceId
            DryRun       = $DryRun
            Mode         = $strMode
            StartedAt    = $dateStart.ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            StartedAtUtc = $dateStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
}

function Get-DeviceInspectorRunningAction {
    # .SYNOPSIS
    # Returns the running action of a device, or nothing.
    #
    # .DESCRIPTION
    # A device has at most one running action. Two names are the same device when their keys are
    # equal (see Get-DeviceInspectorDeviceKey: lower case, no DNS suffix, an IP address as it is), or
    # when both runs know the same site resource ID.
    #
    # .PARAMETER Run
    # The running actions. Each one comes from New-DeviceInspectorActionRun.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER ResourceId
    # Optional. The site resource ID of the device, when the inspection knows it.
    #
    # .EXAMPLE
    # $objRun = Get-DeviceInspectorRunningAction -Run $arrRun -ComputerName 'ws01.corp.local'
    #
    # # Returns the run on WS01, or $null.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] The run, or nothing.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.1.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Run,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [long]$ResourceId = 0
    )

    process {
        if ([string]::IsNullOrEmpty($ComputerName)) {
            return
        }
        $strKey = Get-DeviceInspectorDeviceKey -ComputerName $ComputerName
        foreach ($objRun in @($Run)) {
            if ($null -eq $objRun) {
                continue
            }
            $strRunKey = Get-DeviceInspectorDeviceKey -ComputerName ([string]$objRun.ComputerName)
            $longRunId = 0
            if ($null -ne $objRun.PSObject.Properties['ResourceId']) {
                $longRunId = [long]$objRun.ResourceId
            }
            if ($strRunKey -eq $strKey -or ($ResourceId -gt 0 -and $longRunId -eq $ResourceId)) {
                $objRun
                return
            }
        }
    }
}

function Get-DeviceInspectorRunBlock {
    # .SYNOPSIS
    # Returns the reason why a device cannot start an action because it has a running action, or an empty string.
    #
    # .DESCRIPTION
    # A device has at most one running action at a time. The reason names the running action,
    # its ID and its start time. A running action of another device does not block.
    #
    # .PARAMETER Run
    # The running actions. Each one comes from New-DeviceInspectorActionRun.
    #
    # .PARAMETER ComputerName
    # The device that the action targets.
    #
    # .PARAMETER ResourceId
    # Optional. The site resource ID of the device, when the inspection knows it.
    #
    # .EXAMPLE
    # Get-DeviceInspectorRunBlock -Run $arrRun -ComputerName 'WS01'
    #
    # # Returns 'Client policy update (ID a1b2c3d4) is running on WS01 since 10:15:02. ...'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The reason, or an empty string.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.1.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Run,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [long]$ResourceId = 0
    )

    process {
        $objRunning = Get-DeviceInspectorRunningAction -Run @($Run) -ComputerName $ComputerName -ResourceId $ResourceId
        if ($null -eq $objRunning) {
            return ''
        }
        '{0} (ID {1}) is running on {2} since {3}. A device runs one action at a time. Wait until it ends.' -f $objRunning.Action, $objRunning.ActionId, $objRunning.ComputerName, $objRunning.StartedAt
    }
}

function Get-DeviceInspectorDeviceKey {
    # .SYNOPSIS
    # Returns the canonical key of a device name, for the one-action-for-each-device check.
    #
    # .DESCRIPTION
    # The key is the name in lower case. For a DNS name, the text after the first dot is removed,
    # so WS01, ws01 and WS01.CORP.LOCAL give the key ws01. An IP address stays as it is, in lower case.
    #
    # .PARAMETER ComputerName
    # The device name, a DNS name or an IP address.
    #
    # .EXAMPLE
    # Get-DeviceInspectorDeviceKey -ComputerName 'WS01.CORP.LOCAL'
    #
    # # Returns 'ws01'.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The key.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ComputerName
    )

    process {
        $strKey = $ComputerName.Trim().ToLowerInvariant()
        $objAddress = $null
        if ([System.Net.IPAddress]::TryParse($strKey, [ref]$objAddress)) {
            return $strKey
        }
        $intDot = $strKey.IndexOf('.')
        if ($intDot -gt 0) {
            $strKey = $strKey.Substring(0, $intDot)
        }
        $strKey
    }
}

function Test-DeviceInspectorRunFinished {
    # .SYNOPSIS
    # Returns $true when the background work of a run has ended.
    #
    # .DESCRIPTION
    # The work sets Done in its state when it ends. If the work ends without it (for example a
    # stopped pipeline), the handle of the asynchronous call still says IsCompleted. Either one
    # counts as ended, so a run cannot keep its device for ever.
    #
    # .PARAMETER State
    # The state of the run: a dictionary with the key Done, or an object with the property Done.
    #
    # .PARAMETER Handle
    # The result of BeginInvoke, or $null.
    #
    # .EXAMPLE
    # Test-DeviceInspectorRunFinished -State @{ Done = $false } -Handle $objHandle
    #
    # # Returns $true when $objHandle.IsCompleted is $true.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [bool] $true when the work ended.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$State,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Handle = $null
    )

    process {
        $boolDone = $false
        if ($State -is [System.Collections.IDictionary]) {
            $boolDone = [bool]$State['Done']
        } elseif ($null -ne $State -and $null -ne $State.PSObject.Properties['Done']) {
            $boolDone = [bool]$State.Done
        }
        if ($boolDone) {
            return $true
        }
        if ($null -ne $Handle -and $null -ne $Handle.PSObject.Properties['IsCompleted']) {
            return [bool]$Handle.IsCompleted
        }
        $false
    }
}

function Resolve-DeviceInspectorRunResult {
    # .SYNOPSIS
    # Turns the end state of a run into exactly one action record that the window writes to the action log.
    #
    # .DESCRIPTION
    # A run ends with one result object, an error message, or something else. The function returns the
    # result with the action ID set. For an error, for no result, for more than one result and for an
    # object that is not an action result, it returns a FAILED record that says so. The result line is
    # then never missing.
    #
    # .PARAMETER Run
    # The run, from New-DeviceInspectorActionRun.
    #
    # .PARAMETER Result
    # What the background work returned. Can be $null or an array.
    #
    # .PARAMETER ErrorMessage
    # The error of the background work, or an empty string.
    #
    # .PARAMETER Detail
    # The detail lines of the action. They become the steps of a result that has no steps.
    #
    # .EXAMPLE
    # $objRecord = Resolve-DeviceInspectorRunResult -Run $objRun -Result $null -ErrorMessage '' -Detail @()
    #
    # # Returns a FAILED record: 'The action returned no result.'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] One action record.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Run,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object]$Result,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ErrorMessage = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$Detail = @()
    )

    process {
        $arrResult = @($Result | Where-Object { $null -ne $_ })
        $strProblem = $ErrorMessage
        if ([string]::IsNullOrEmpty($strProblem)) {
            if ($arrResult.Count -eq 0) {
                $strProblem = 'The action returned no result.'
            } elseif ($arrResult.Count -gt 1) {
                $strProblem = 'The action returned {0} results instead of one.' -f $arrResult.Count
            } elseif ($null -eq $arrResult[0].PSObject.Properties['Succeeded']) {
                $strProblem = 'The action returned an object that is not an action result.'
            }
        }
        if (-not [string]::IsNullOrEmpty($strProblem)) {
            return New-DeviceInspectorActionRecord -Action ([string]$Run.Action) -ComputerName ([string]$Run.ComputerName) -DryRun ([bool]$Run.DryRun) -Succeeded $false -ActionId ([string]$Run.ActionId) -Summary $strProblem -Steps @($Detail)
        }
        $objRecord = Add-DeviceInspectorActionId -Result ([pscustomobject]$arrResult[0]) -ActionId ([string]$Run.ActionId)
        if (@($objRecord.Steps).Count -eq 0 -and @($Detail).Count -gt 0) {
            Add-Member -InputObject $objRecord -NotePropertyName 'Steps' -NotePropertyValue ([string[]]@($Detail)) -Force
        }
        $objRecord
    }
}

function Register-DeviceInspectorActionRun {
    # .SYNOPSIS
    # Adds a run to the list of running actions, or refuses when the device has a running action.
    #
    # .DESCRIPTION
    # A device has at most one running action at a time. The function throws when the list
    # holds a run of the same device (same key, see Get-DeviceInspectorDeviceKey, or same resource ID).
    #
    # .PARAMETER Runs
    # The list of running actions.
    #
    # .PARAMETER Run
    # The run to add, from New-DeviceInspectorActionRun.
    #
    # .EXAMPLE
    # Register-DeviceInspectorActionRun -Runs $listRun -Run $objRun
    #
    # # Adds the run, or throws.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # None.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([void])]
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IList]$Runs,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Run
    )

    process {
        $longResourceId = 0
        if ($null -ne $Run.PSObject.Properties['ResourceId']) {
            $longResourceId = [long]$Run.ResourceId
        }
        $objRunning = Get-DeviceInspectorRunningAction -Run @($Runs) -ComputerName ([string]$Run.ComputerName) -ResourceId $longResourceId
        if ($null -ne $objRunning) {
            throw ('{0} (ID {1}) is running on {2}. A device runs one action at a time.' -f $objRunning.Action, $objRunning.ActionId, $objRunning.ComputerName)
        }
        [void]$Runs.Add($Run)
    }
}

function Unregister-DeviceInspectorActionRun {
    # .SYNOPSIS
    # Removes a run from the list of running actions.
    #
    # .DESCRIPTION
    # The window calls it when a run ends. The function returns the run that it removed,
    # or nothing when the list holds no run with that ID.
    #
    # .PARAMETER Runs
    # The list of running actions.
    #
    # .PARAMETER ActionId
    # The ID of the run to remove.
    #
    # .EXAMPLE
    # $objRun = Unregister-DeviceInspectorActionRun -Runs $listRun -ActionId 'a1b2c3d4'
    #
    # # Returns the removed run.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] The removed run, or nothing.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IList]$Runs,

        [Parameter(Mandatory = $true)]
        [string]$ActionId
    )

    process {
        for ($intIndex = 0; $intIndex -lt $Runs.Count; $intIndex++) {
            if ([string]$Runs[$intIndex].ActionId -eq $ActionId) {
                $objRun = $Runs[$intIndex]
                $Runs.RemoveAt($intIndex)
                $objRun
                return
            }
        }
    }
}

#endregion Public functions

