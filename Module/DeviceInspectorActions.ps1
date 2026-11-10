Set-StrictMode -Version Latest

# Every change to a device or to the site goes through this file. Each action has a
# dry run: the same code path reads the current state and lists the steps, and skips
# every call that changes state. The window runs an action only when the person has
# turned on Enable actions and confirmed the action.

#region Remote script blocks

# Runs on the device. Requests machine policy, then evaluates it. A ReturnValue other
# than 0 stops the run, because the evaluation of old policy has no use.
$script:scriptBlockPolicyUpdate = {
    param ([bool]$DryRun)

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
            return [pscustomobject]@{ Succeeded = $false; Summary = ('{0} failed. The steps before it ran.' -f $hashtableSchedule.Name); Steps = @($listStep) }
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

