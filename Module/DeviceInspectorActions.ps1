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

# Runs on the device. Several revisions of one application ID can be in the client
# policy; the highest revision is the one that the method acts on.
$script:scriptBlockApplicationAction = {
    param (
        [Parameter(Mandatory = $true)][bool]$DryRun,
        [Parameter(Mandatory = $true)][string]$ApplicationId,
        [Parameter(Mandatory = $true)][ValidateSet('Uninstall', 'Repair')][string]$Operation
    )

    $ErrorActionPreference = 'Stop'
    $listStep = New-Object -TypeName 'System.Collections.Generic.List[string]'
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
        $arrMatch = @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' | Where-Object { [string]$_.Id -eq $ApplicationId })
    } catch {
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The applications of the client policy cannot be read: {0}' -f $_.Exception.Message); Steps = @($listStep) }
    }
    if ($arrMatch.Count -eq 0) {
        return [pscustomobject]@{ Succeeded = $false; Summary = 'The client policy has no application with this ID now. Inspect the device again.'; Steps = @($listStep) }
    }
    $scriptBlockRevision = {
        param($objValue)
        $intRevision = [uint64]0
        if ([uint64]::TryParse([string]$objValue, [ref]$intRevision)) {
            return $intRevision
        }
        return [uint64]0
    }
    $objApplication = @($arrMatch | Sort-Object -Property { & $scriptBlockRevision $_.Revision } -Descending)[0]
    if ($arrMatch.Count -gt 1) {
        $listStep.Add(('The client holds {0} revisions. Picked the highest, revision {1}.' -f $arrMatch.Count, [string]$objApplication.Revision))
    }
    if (-not [bool]$objApplication.IsMachineTarget) {
        return [pscustomobject]@{ Succeeded = $false; Summary = 'The application is deployed to a user. The tool acts only on applications deployed to the device.'; Steps = @($listStep) }
    }
    $arrAllowed = @($objApplication.AllowedActions | ForEach-Object { [string]$_ })
    $listStep.Add(('{0}, revision {1}, install state {2}, allowed actions: {3}.' -f [string]$objApplication.Name, [string]$objApplication.Revision, [string]$objApplication.InstallState, ($arrAllowed -join ', ')))
    $boolAllowed = $arrAllowed -contains $Operation
    if ($Operation -eq 'Uninstall' -and -not $boolAllowed) {
        $boolAllowed = ([string]$objApplication.InstallState) -eq 'Installed' -and -not [bool]$objApplication.IsPreflightOnly
    }
    if (-not $boolAllowed) {
        $strWhy = 'The application is not installed, or the deployment is a simulation.'
        if ($Operation -eq 'Repair') {
            $strWhy = 'The deployment type needs a repair command.'
        }
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The client does not allow {0} for this application now. {1}' -f $Operation, $strWhy); Steps = @($listStep) }
    }
    if (-not ($arrAllowed -contains $Operation)) {
        $listStep.Add(('The allowed actions of the client do not list {0}. The application is installed, so the tool sends the request.' -f $Operation))
    }
    if ($DryRun) {
        $listStep.Add(('Dry run: would call CCM_Application.{0} for {1}, revision {2}.' -f $Operation, [string]$objApplication.Name, [string]$objApplication.Revision))
        return [pscustomobject]@{ Succeeded = $true; Summary = 'Dry run: the client answers. Nothing changed.'; Steps = @($listStep) }
    }
    $hashtableArgument = @{
        Id                = [string]$objApplication.Id
        Revision          = [string]$objApplication.Revision
        IsMachineTarget   = [bool]$objApplication.IsMachineTarget
        EnforcePreference = [uint32]0
        Priority          = 'High'
        IsRebootIfNeeded  = $false
    }
    try {
        $objReturn = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' -MethodName $Operation -Arguments $hashtableArgument
        $objReturnValue = $null
        $strJobId = ''
        if ($null -ne $objReturn -and $null -ne $objReturn.PSObject.Properties['ReturnValue']) {
            $objReturnValue = $objReturn.ReturnValue
        }
        if ($null -ne $objReturn -and $null -ne $objReturn.PSObject.Properties['JobId']) {
            $strJobId = [string]$objReturn.JobId
        }
        $boolRefused = ($null -ne $objReturnValue -and [int64]$objReturnValue -ne 0)
    } catch {
        $listStep.Add(('{0} failed: {1}' -f $Operation, $_.Exception.Message))
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The client did not accept the {0} request.' -f $Operation); Steps = @($listStep) }
    }
    if ($boolRefused) {
        $listStep.Add(('{0} returned {1}.' -f $Operation, $objReturnValue))
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The client refused the {0} request (return value {1}).' -f $Operation, $objReturnValue); Steps = @($listStep) }
    }
    if ($null -eq $objReturnValue) {
        $listStep.Add(('{0} gave no return value. The request is not confirmed.' -f $Operation))
        return [pscustomobject]@{ Succeeded = $false; Summary = ('The client gave no return value for the {0} request. Inspect the device again to see the state.' -f $Operation); Steps = @($listStep) }
    }
    if ([string]::IsNullOrEmpty($strJobId)) {
        $listStep.Add(('{0} accepted.' -f $Operation))
    } else {
        $listStep.Add(('{0} accepted. Job {1}.' -f $Operation, $strJobId))
    }
    Start-Sleep -Seconds 10
    try {
        $objAfter = @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' | Where-Object { [string]$_.Id -eq $ApplicationId -and [string]$_.Revision -eq [string]$objApplication.Revision })[0]
        if ($null -ne $objAfter) {
            $listStep.Add(('After the request: install state {0}, evaluation state {1}.' -f [string]$objAfter.InstallState, [int]$objAfter.EvaluationState))
        }
    } catch {
        $listStep.Add(('The state after the request cannot be read: {0}' -f $_.Exception.Message))
    }
    [pscustomobject]@{ Succeeded = $true; Summary = ('The client accepted the {0} of {1}. AppEnforce.log on the device shows the run.' -f $Operation, [string]$objApplication.Name); Steps = @($listStep) }
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
    # that stops part way still leaves a line. Outcome is OK, FAILED or STARTED.
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
    # .PARAMETER Outcome
    # Optional. STARTED for a start record. When omitted, Succeeded gives OK or FAILED.
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
    # [pscustomobject] Properties: Action, ComputerName, DryRun, Mode, StartedAt,
    # Account, Succeeded, Outcome, Summary, Steps.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.1
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
        [ValidateSet('OK', 'FAILED', 'STARTED')]
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
    # Uninstalls or repairs one Configuration Manager application on a device.
    #
    # .DESCRIPTION
    # Runs on the device over WinRM. It finds the application in CCM_Application by
    # its ID, checks that the client allows the operation, and calls the Uninstall
    # or the Repair method with the immediate enforce preference. With DryRun it
    # reads the application and lists the step, and changes nothing.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER ApplicationId
    # The Id of the application in CCM_Application.
    #
    # .PARAMETER Operation
    # Uninstall or Repair.
    #
    # .PARAMETER DryRun
    # Read the application and list the step only.
    #
    # .PARAMETER Credential
    # An optional credential for the WinRM connection.
    #
    # .EXAMPLE
    # Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -ApplicationId 'ScopeId_1/Application_2' -Operation Uninstall -DryRun
    #
    # # Shows the application and its allowed actions. Nothing changes.
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
        [ValidatePattern('^[A-Za-z0-9_{}/.-]{1,300}\z')]
        [string]$ApplicationId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Uninstall', 'Repair')]
        [string]$Operation,

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
            ArgumentList = @($ApplicationId, $Operation)
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
                        Write-Debug -Message $_.Exception.Message
                    }
                } until ($boolSeen -or $intTry -ge 12)
                if ($boolSeen) {
                    $listStep.Add(('The site shows the new membership after {0} seconds.' -f ($intTry * 5)))
                } else {
                    $listStep.Add('The site did not show the new membership within 60 seconds. The client gets it at a later policy cycle.')
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
    # The first line holds the time, the account, the device, the action, the mode,
    # the outcome and the summary. One indented line follows for each step. Line
    # breaks and control characters in a field become one space, so text from the
    # device cannot add a line to the action log.
    #
    # .PARAMETER Result
    # The object that an action function returns.
    #
    # .EXAMPLE
    # ConvertTo-DeviceInspectorActionText -Result $objResult
    #
    # # <UTC time> | <domain\account> | WS01 | Client policy update | DRY RUN | OK | Dry run: ...
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
    # Version: 1.0.20261110.0
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
        $arrField = @($Result.StartedAt, $Result.Account, $Result.ComputerName, $Result.Action, $Result.Mode, $strOutcome, $Result.Summary) | ForEach-Object { & $scriptBlockLine $_ }
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

#endregion Public functions

