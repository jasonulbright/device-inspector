#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Test inputs are fake device names.')]
param ()

BeforeAll {
    $strRepositoryPath = Split-Path -Path $PSScriptRoot -Parent
    $script:strActionsFile = Join-Path -Path $strRepositoryPath -ChildPath 'Module\DeviceInspectorActions.ps1'
    $script:strStartPath = Join-Path -Path $strRepositoryPath -ChildPath 'start-deviceinspector.ps1'
    $script:strXamlPath = Join-Path -Path $strRepositoryPath -ChildPath 'MainWindow.xaml'
    Import-Module -Name (Join-Path -Path $strRepositoryPath -ChildPath 'Module\DeviceInspectorCommon.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'CMStubs.ps1')
}

AfterAll {
    Remove-Module -Name DeviceInspectorCommon -Force -ErrorAction SilentlyContinue
    Remove-CMTestStub
}

Describe 'Action module surface' {
    It 'exports the action functions through the module manifest' {
        foreach ($strName in 'Invoke-DeviceInspectorPolicyUpdate', 'ConvertTo-DeviceInspectorActionText', 'Write-DeviceInspectorActionLog', 'New-DeviceInspectorActionRecord') {
            Get-Command -Name $strName -Module DeviceInspectorCommon -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $strName
        }
    }

    It 'calls Invoke-CimMethod only inside the remote script blocks' {
        $objAst = [System.Management.Automation.Language.Parser]::ParseFile($script:strActionsFile, [ref]$null, [ref]$null)
        $arrFunction = @($objAst.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        foreach ($objFunction in $arrFunction) {
            $arrCommand = @($objFunction.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
            $arrCommand | Should -Not -Contain 'Invoke-CimMethod' -Because $objFunction.Name
            $arrCommand | Should -Not -Contain 'Remove-CimInstance' -Because $objFunction.Name
            $arrCommand | Should -Not -Contain 'Start-Process' -Because $objFunction.Name
        }
    }
}

Describe 'Invoke-DeviceInspectorPolicyUpdate' {
    It 'passes DryRun <DryRun> to the device script' -ForEach @(@{ DryRun = $true }, @{ DryRun = $false }) {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @('step one') } }
        $objResult = Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01' -DryRun:$DryRun
        $objResult.Succeeded | Should -BeTrue
        $objResult.DryRun | Should -Be $DryRun
        $objResult.Mode | Should -Be $(if ($DryRun) { 'DRY RUN' } else { 'RUN' })
        $objResult.Action | Should -Be 'Client policy update'
        $objResult.ComputerName | Should -Be 'WS01'
        $objResult.Steps | Should -Be @('step one')
        $objResult.StartedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'WS01' -and $ArgumentList[0] -eq $DryRun }
    }

    It 'returns a failed result and does not throw when the device does not answer' {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { throw 'WinRM cannot complete the operation.' }
        $objResult = Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01'
        $objResult.Succeeded | Should -BeFalse
        $objResult.Summary | Should -Be 'Cannot run the action on WS01. The action log has the reason. The connection can fail after a step ran. Inspect the device to see its state.'
        $objResult.Summary | Should -Not -Match 'WinRM cannot complete'
        @($objResult.Detail) | Should -Be @('WinRM cannot complete the operation.')
    }

    It 'returns a failed result when the device returns nothing' {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { }
        (Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01').Succeeded | Should -BeFalse
    }

    It 'says on a failed run that a step can have run' {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { throw 'The WinRM client cannot process the request.' }
        (Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01').Summary | Should -Match 'can fail after a step ran'
        (Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01' -DryRun).Summary | Should -Not -Match 'can fail after a step ran'
    }

    It 'refuses a device name that carries a path, a query or a line break' {
        { Invoke-DeviceInspectorPolicyUpdate -ComputerName "WS01`n" } | Should -Throw
        { Invoke-DeviceInspectorPolicyUpdate -ComputerName 'a\b' } | Should -Throw
        { Invoke-DeviceInspectorPolicyUpdate -ComputerName "a' OR 1=1" } | Should -Throw
    }
}

Describe 'Policy update script on the device' {
    It 'changes nothing in a dry run' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } }
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockPolicyUpdate $true
            $objRaw.Succeeded | Should -BeTrue
            @($objRaw.Steps).Count | Should -Be 3
            $objRaw.Steps[1] | Should -Match '^Dry run: would trigger .*000000000021'
            $objRaw.Steps[2] | Should -Match '^Dry run: would trigger .*000000000022'
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'requests machine policy, then evaluates it' {
        InModuleScope DeviceInspectorCommon {
            $script:listSchedule = New-Object -TypeName 'System.Collections.Generic.List[string]'
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } }
            Mock Invoke-CimMethod { $script:listSchedule.Add($Arguments.sScheduleID); [pscustomobject]@{ ReturnValue = $null } }
            $objRaw = & $script:scriptBlockPolicyUpdate $false
            $objRaw.Succeeded | Should -BeTrue
            @($script:listSchedule) | Should -Be @('{00000000-0000-0000-0000-000000000021}', '{00000000-0000-0000-0000-000000000022}')
            Should -Invoke Invoke-CimMethod -Times 2 -Exactly -ParameterFilter { $Namespace -eq 'root\ccm' -and $ClassName -eq 'SMS_Client' -and $MethodName -eq 'TriggerSchedule' }
        }
    }

    It 'stops after a return value other than 0' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } }
            Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 5 } }
            $objRaw = & $script:scriptBlockPolicyUpdate $false
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'return value 5'
            Should -Invoke Invoke-CimMethod -Times 1 -Exactly
        }
    }

    It 'keeps the done steps when the second method call throws' {
        InModuleScope DeviceInspectorCommon {
            $script:intCall = 0
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } }
            Mock Invoke-CimMethod { $script:intCall++; if ($script:intCall -eq 2) { throw 'Generic failure' }; [pscustomobject]@{ ReturnValue = 0 } }
            $objRaw = & $script:scriptBlockPolicyUpdate $false
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'The earlier steps, if any, ran'
            $objRaw.Steps[1] | Should -Match '^Triggered .*000000000021'
            $objRaw.Steps[2] | Should -Match 'failed\.$'
            $objRaw.Steps[2] | Should -Not -Match 'Generic failure'
            @($objRaw.Detail) | Should -Contain 'Machine policy evaluation (Machine Policy Evaluation): Generic failure'
        }
    }

    It 'reports a device without the client and calls no method' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CimInstance { throw 'Invalid namespace' }
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockPolicyUpdate $false
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'does not answer'
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }
}

Describe 'Action log' {
    BeforeAll {
        $script:objSample = [pscustomobject]@{
            ActionId = 'a1b2c3d4'; Action = 'Client policy update'; ComputerName = 'WS01'; DryRun = $true; Mode = 'DRY RUN'
            StartedAt = '2026-11-10T20:00:00Z'; Account = 'EXAMPLE\admin'; Succeeded = $true
            Summary = 'Dry run: the client answers. Nothing changed.'; Steps = @('Client version 5.00 answers.', 'Dry run: would trigger x.')
        }
    }

    It 'formats one header line and one line for each step' {
        $arrLine = @(ConvertTo-DeviceInspectorActionText -Result $script:objSample)
        $arrLine.Count | Should -Be 3
        $arrLine[0] | Should -Be '2026-11-10T20:00:00Z | a1b2c3d4 | EXAMPLE\admin | WS01 | Client policy update | DRY RUN | OK | Dry run: the client answers. Nothing changed.'
        $arrLine[1] | Should -Be '    Client version 5.00 answers.'
    }

    It 'shows a hyphen in the ID field for a result that has no ID' {
        $objOld = [pscustomobject]@{
            Action = 'Client policy update'; ComputerName = 'WS01'; DryRun = $false; Mode = 'RUN'
            StartedAt = '2026-11-10T20:00:00Z'; Account = 'EXAMPLE\admin'; Succeeded = $true; Summary = 'Done.'; Steps = @()
        }
        @(ConvertTo-DeviceInspectorActionText -Result $objOld)[0] | Should -Be '2026-11-10T20:00:00Z | - | EXAMPLE\admin | WS01 | Client policy update | RUN | OK | Done.'
    }

    It 'writes each field on one line, so device text cannot add a log line' {
        $objBad = $script:objSample.PSObject.Copy()
        $objBad.Summary = "first`r`n2026-01-01T00:00:00Z | X | Y | Z | RUN | OK | forged"
        $objBad.Steps = @("step`nnext", "tab`there")
        $arrLine = @(ConvertTo-DeviceInspectorActionText -Result $objBad)
        $arrLine.Count | Should -Be 3
        $arrLine[0] | Should -Match '\| first 2026-01-01T00:00:00Z \| X'
        $arrLine[1] | Should -Be '    step next'
        $arrLine[2] | Should -Be '    tab here'
    }

    It 'writes a start record with the outcome STARTED' {
        $objStart = New-DeviceInspectorActionRecord -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false -Succeeded $false -Outcome 'STARTED' -Summary 'The run started.' -Steps @()
        $objStart.Mode | Should -Be 'RUN'
        @(ConvertTo-DeviceInspectorActionText -Result $objStart)[0] | Should -Match '\| - \| \S+ \| WS01 \| Client policy update \| RUN \| STARTED \| The run started\.$'
    }

    It 'marks a failed action' {
        $objFailed = $script:objSample.PSObject.Copy()
        $objFailed.Succeeded = $false
        @(ConvertTo-DeviceInspectorActionText -Result $objFailed)[0] | Should -Match '\| FAILED \|'
    }

    It 'appends to the log file, creates the folder, and writes no byte order mark' {
        $strPath = Join-Path -Path $TestDrive -ChildPath 'Logs\DeviceInspector-actions.log'
        $strWritten = Write-DeviceInspectorActionLog -Path $strPath -Result $script:objSample
        $null = Write-DeviceInspectorActionLog -Path $strPath -Result $script:objSample
        $strWritten | Should -Be $strPath
        $arrByte = [System.IO.File]::ReadAllBytes($strPath)
        $arrByte[0] | Should -Be ([byte][char]'2')
        @([System.IO.File]::ReadAllLines($strPath)).Count | Should -Be 6
    }
}

Describe 'Action gate in the window' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
    }

    It 'starts with Enable Actions off and does not save the switch' {
        $script:strXaml | Should -Match '(?s)x:Name="toggleActions".*?IsOn="False"'
        $script:strStart | Should -Match '\$script:ActionsEnabled = \$false'
        $script:strStart | Should -Not -Match "Prefs\[.?ActionsEnabled"
    }

    It 'checks the switch before it shows the confirmation' {
        $intGate = $script:strStart.IndexOf('if (-not (Test-DeviceActionReady)) {')
        $intDialog = $script:strStart.IndexOf('$choice = Show-ActionConfirmDialog')
        $intGate | Should -BeGreaterThan 0
        $intGate | Should -BeLessThan $intDialog
        $script:strStart | Should -Match 'function Test-DeviceActionReady \{[^}]*-ActionsEnabled \$script:ActionsEnabled[^}]*-Kind Device'
    }

    It 'writes every run and every dry run to the action log' {
        $script:strStart | Should -Match '(?s)function Write-ActionResult \{.*?Write-DeviceInspectorActionLog -Path \$script:ActionLogPath'
        $script:strStart | Should -Match '(?s)-OnDone \{.*?Write-ActionResult -Result \$r'
        $script:strStart | Should -Match '(?s)function Complete-DeviceActionRun \{.*?Resolve-DeviceInspectorRunResult -Run \$run.*?Write-ActionResult -Result \$record'
        $script:strStart | Should -Match '(?s)if \(\$State\.ErrorMsg\) \{\s*\$failed = New-DeviceInspectorActionRecord.*?Write-ActionResult -Result \$failed'
    }

    It 'writes a start record before a run and stops when it cannot write it' {
        $intStart = $script:strStart.IndexOf("-Outcome 'STARTED'")
        $intWork = $script:strStart.IndexOf('Start-ActionWork -Title $title')
        $intRun = $script:strStart.IndexOf('Start-DeviceActionRun -Run $run')
        $intStart | Should -BeGreaterThan 0
        $intStart | Should -BeLessThan $intWork
        $intStart | Should -BeLessThan $intRun
        $script:strStart | Should -Match "(?s)-Outcome 'STARTED'.*?catch \{.*?the run does not start.*?return\s*\}"
    }

    It 'shows the device count in the confirmation and makes Cancel the default button' {
        $script:strStart | Should -Match 'This action targets 1 device'
        $script:strStart | Should -Match 'x:Name="btnActionCancel"[^>]*IsCancel="True" IsDefault="True"'
        $script:strStart | Should -Not -Match 'x:Name="btnActionRun"[^>]*IsDefault'
    }
}

Describe 'Full output log file' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
        $script:objLargeInspection = [pscustomobject]@{
            ComputerName = 'WS01'; InspectedAt = '2026-11-10T00:00:00Z'; SiteServer = $null; SiteCode = $null; Site = $null
            Device = [pscustomobject]@{ OperatingSystem = $null; Client = $null; ClientApplications = @(); PendingUpdates = @()
                InstalledApplications = @(1..60 | ForEach-Object { [pscustomobject]@{ Name = ('App {0:d2}' -f $_); Version = '1.0'; Publisher = '' } }) }
            Problems = @()
        }
    }

    AfterEach {
        Initialize-Logging -LogPath ''
    }

    It 'writes the full report, blank lines included, to the log file and returns $true' {
        $strLog = Join-Path -Path $TestDrive -ChildPath 'session.log'
        Initialize-Logging -LogPath $strLog
        Write-DeviceInspectionFullLog -Inspection $script:objLargeInspection -LogPath $strLog | Should -BeTrue
        $strText = Get-Content -LiteralPath $strLog -Raw
        $strText | Should -Match '----- Full report: WS01 -----'
        $strText | Should -Match '----- end of Full report: WS01 -----'
        $strText | Should -Match 'App 01 1\.0'
        $strText | Should -Match 'App 60 1\.0'
        $strText | Should -Match '== Problems \(0\) =='
        $strText | Should -Not -Match 'more \(see the JSON output\)'
    }

    It 'returns $false and does not throw when the report cannot be built' {
        $strLog = Join-Path -Path $TestDrive -ChildPath 'broken.log'
        Initialize-Logging -LogPath $strLog
        Write-DeviceInspectionFullLog -Inspection ([pscustomobject]@{ ComputerName = 'WS01' }) -LogPath $strLog | Should -BeFalse
    }

    It 'returns $false when nothing reaches the log file' {
        Initialize-Logging -LogPath ''
        Write-DeviceInspectionFullLog -Inspection $script:objLargeInspection -LogPath (Join-Path -Path $TestDrive -ChildPath 'never.log') | Should -BeFalse
    }

    It 'writes the full report after each inspection and says so when it cannot' {
        $script:strStart | Should -Match "(?s)Inspection of \{0\} finished.*?if \(-not \(Write-DeviceInspectionFullLog -Inspection \`$r -LogPath \`$script:ToolLogPath\)\) \{ Add-LogLine"
    }

    It 'writes each window log line to the log file' {
        $script:strStart | Should -Match '(?s)function Add-LogLine \{.*?Write-Log -Message \$Message -Quiet'
    }

    It 'has an Open log file button that opens the log of this session' {
        $script:strXaml | Should -Match 'x:Name="btnOpenLog"[^>]*Content="Open Log File"'
        $script:strStart | Should -Match '(?s)\$btnOpenLog\.Add_Click\(\{.*?Invoke-Item -LiteralPath \$script:ToolLogPath -ErrorAction Stop'
    }
}

Describe 'Full hardware inventory' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
    }

    It 'passes DryRun <DryRun> to the device script' -ForEach @(@{ DryRun = $true }, @{ DryRun = $false }) {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @() } }
        $objResult = Invoke-DeviceInspectorFullInventory -ComputerName 'WS01' -DryRun:$DryRun
        $objResult.Action | Should -Be 'Full hardware inventory'
        $objResult.DryRun | Should -Be $DryRun
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq $DryRun }
    }

    It 'shows the status record and changes nothing in a dry run' {
        InModuleScope DeviceInspectorCommon {
            $objStatus = New-CimInstance -ClassName 'InventoryActionStatus' -Namespace 'root/ccm/invagt' -ClientOnly -Property @{
                InventoryActionID = '{00000000-0000-0000-0000-000000000001}'; LastCycleStartedDate = [datetime]'2026-11-10T10:00:00Z'
                LastReportDate = [datetime]'2026-11-10T10:01:00Z'; LastMajorReportVersion = [uint32]4; LastMinorReportVersion = [uint32]2
            }
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance { $objStatus } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
            Mock Remove-CimInstance { }
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockFullInventory $true
            $objRaw.Succeeded | Should -BeTrue
            ($objRaw.Steps -join "`n") | Should -Match 'report version 4\.2'
            ($objRaw.Steps -join "`n") | Should -Match 'Dry run: would delete the InventoryActionStatus record'
            ($objRaw.Steps -join "`n") | Should -Match 'Dry run: would trigger Hardware Inventory \{00000000-0000-0000-0000-000000000001\}'
            Should -Invoke Remove-CimInstance -Times 0 -Exactly
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
            Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $Namespace -eq 'root\ccm\invagt' -and $Filter -eq "InventoryActionID = '{00000000-0000-0000-0000-000000000001}'" }
        }
    }

    It 'deletes the status record first, then triggers hardware inventory' {
        InModuleScope DeviceInspectorCommon {
            $script:listCall = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objStatus = New-CimInstance -ClassName 'InventoryActionStatus' -Namespace 'root/ccm/invagt' -ClientOnly -Property @{ InventoryActionID = '{00000000-0000-0000-0000-000000000001}'; LastCycleStartedDate = [datetime]'2026-11-10T10:00:00Z'; LastReportDate = [datetime]'2026-11-10T10:01:00Z'; LastMajorReportVersion = [uint32]1; LastMinorReportVersion = [uint32]0 }
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance { $objStatus } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
            Mock Remove-CimInstance { $script:listCall.Add('remove') }
            Mock Invoke-CimMethod { $script:listCall.Add($Arguments.sScheduleID); [pscustomobject]@{ ReturnValue = $null } }
            $objRaw = & $script:scriptBlockFullInventory $false
            $objRaw.Succeeded | Should -BeTrue
            @($script:listCall) | Should -Be @('remove', '{00000000-0000-0000-0000-000000000001}')
        }
    }

    It 'only triggers hardware inventory when no status record exists' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
            Mock Remove-CimInstance { }
            Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0 } }
            $objRaw = & $script:scriptBlockFullInventory $false
            $objRaw.Succeeded | Should -BeTrue
            ($objRaw.Steps -join "`n") | Should -Match 'No hardware inventory status record exists'
            Should -Invoke Remove-CimInstance -Times 0 -Exactly
            Should -Invoke Invoke-CimMethod -Times 1 -Exactly
        }
    }

    It 'does not trigger when the delete fails' {
        InModuleScope DeviceInspectorCommon {
            $objStatus = New-CimInstance -ClassName 'InventoryActionStatus' -Namespace 'root/ccm/invagt' -ClientOnly -Property @{ InventoryActionID = '{00000000-0000-0000-0000-000000000001}'; LastCycleStartedDate = [datetime]'2026-11-10T10:00:00Z'; LastReportDate = [datetime]'2026-11-10T10:01:00Z'; LastMajorReportVersion = [uint32]1; LastMinorReportVersion = [uint32]0 }
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance { $objStatus } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
            Mock Remove-CimInstance { throw 'Access denied' }
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockFullInventory $false
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'cannot be deleted\. The schedule was not triggered'
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'says that the record is deleted when the trigger fails' {
        InModuleScope DeviceInspectorCommon {
            $objStatus = New-CimInstance -ClassName 'InventoryActionStatus' -Namespace 'root/ccm/invagt' -ClientOnly -Property @{ InventoryActionID = '{00000000-0000-0000-0000-000000000001}'; LastCycleStartedDate = [datetime]'2026-11-10T10:00:00Z'; LastReportDate = [datetime]'2026-11-10T10:01:00Z'; LastMajorReportVersion = [uint32]1; LastMinorReportVersion = [uint32]0 }
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance { $objStatus } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
            Mock Remove-CimInstance { }
            Mock Invoke-CimMethod { throw 'Generic failure' }
            $objRaw = & $script:scriptBlockFullInventory $false
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'The status record is deleted, but the cycle did not start'
        }
    }

    It 'reports a refused trigger after the delete' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
            Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 2 } }
            $objRaw = & $script:scriptBlockFullInventory $false
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'return value 2'
        }
    }

    It 'stops before any change when <Case>' -ForEach @(
        @{ Case = 'the client read throws'; Client = { throw 'Invalid namespace' }; Status = { }; Expected = 'does not answer' }
        @{ Case = 'the client is missing'; Client = { }; Status = { }; Expected = 'not installed' }
        @{ Case = 'the status read throws'; Client = { [pscustomobject]@{ ClientVersion = '5.00' } }; Status = { throw 'Access denied' }; Expected = 'status cannot be read' }
    ) {
        InModuleScope DeviceInspectorCommon -Parameters @{ Client = $Client; Status = $Status; Expected = $Expected } {
            param($Client, $Status, $Expected)
            Mock Get-CimInstance $Client -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance $Status -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
            Mock Remove-CimInstance { }
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockFullInventory $false
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match $Expected
            Should -Invoke Remove-CimInstance -Times 0 -Exactly
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'lists only the trigger in a dry run with no record, and accepts a record without dates' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
            $objRaw = & $script:scriptBlockFullInventory $true
            ($objRaw.Steps -join "`n") | Should -Not -Match 'would delete'
            ($objRaw.Steps -join "`n") | Should -Match 'would trigger'
            $objNull = New-CimInstance -ClassName 'InventoryActionStatus' -Namespace 'root/ccm/invagt' -ClientOnly -Property @{ InventoryActionID = '{00000000-0000-0000-0000-000000000001}'; LastMajorReportVersion = [uint32]0; LastMinorReportVersion = [uint32]0 }
            Mock Get-CimInstance { $objNull } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
            (& $script:scriptBlockFullInventory $true).Succeeded | Should -BeTrue
        }
    }

    It 'requires the DryRun argument in every device script' {
        InModuleScope DeviceInspectorCommon {
            foreach ($scriptBlockDevice in @($script:scriptBlockPolicyUpdate, $script:scriptBlockFullInventory)) {
                $objParameter = $scriptBlockDevice.Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DryRun' }
                ($objParameter.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' }).Extent.Text | Should -Match 'Mandatory = \$true'
            }
        }
    }

    It 'has a Device panel button that runs the action through the gate' {
        $script:strXaml | Should -Match 'x:Name="btnFullInventory"'
        $script:strStart | Should -Match "(?s)\`$btnFullInventory\.Add_Click\(\{\s*Invoke-DeviceAction -Name 'Full hardware inventory' -Function 'Invoke-DeviceInspectorFullInventory'"
        $script:strStart | Should -Match '\$btnFullInventory\.IsEnabled = Test-DeviceActionReady'
    }
}

Describe 'Corrupt-inventory check and repair' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
        function New-CheckInspection {
            param([string]$SiteDate = '2026-11-10T10:01:00', [string]$Cycle = '2026-11-10T10:00:00', [object[]]$DeviceApp, [object[]]$SiteApp)
            [pscustomobject]@{
                ComputerName = 'WS01'; InspectedAt = '2026-11-11T00:00:00Z'; SiteServer = 's'; SiteCode = 'XYZ'
                Site = [pscustomobject]@{ Found = $true; LastHardwareInventory = '2026-11-05T17:41:51Z'; HardwareScanClientTime = $SiteDate; InstalledApplications = @($SiteApp) }
                Device = [pscustomobject]@{ Client = [pscustomobject]@{ LastHardwareInventoryCycle = '2026-11-10T15:00:00Z'; HardwareCycleLocalTime = $Cycle }; InstalledApplications = @($DeviceApp) }
                Problems = @()
            }
        }
        $script:objAppA = [pscustomobject]@{ Name = 'App A'; Version = '1.0'; Publisher = ''; InstallDate = '20260101' }
        $script:objAppASite = [pscustomobject]@{ Name = 'App A '; Version = '1.0'; Publisher = '' }
    }

    It 'compares the client local times, not the cmdlet date of the device record' {
        $objInspection = New-CheckInspection -SiteDate '2026-11-10T19:22:32' -Cycle '2026-11-10T19:21:32' -DeviceApp @($script:objAppA) -SiteApp @($script:objAppASite)
        $objInspection.Site.LastHardwareInventory = '2026-11-05T17:41:51Z'
        (Test-DeviceInspectionInventory -Inspection $objInspection).State | Should -Be 'Current'
    }

    It 'says Current when the site inventory is current and the applications match, names trimmed' {
        $objCheck = Test-DeviceInspectionInventory -Inspection (New-CheckInspection -DeviceApp @($script:objAppA) -SiteApp @($script:objAppASite))
        $objCheck.State | Should -Be 'Current'
        $objCheck.Differences | Should -Be 0
    }

    It 'says Corrupt when the site inventory is current and an application differs' {
        $objOld = [pscustomobject]@{ Name = 'Old App'; Version = '2.0'; Publisher = ''; InstallDate = '20250101' }
        $objCheck = Test-DeviceInspectionInventory -Inspection (New-CheckInspection -DeviceApp @($script:objAppA, $objOld) -SiteApp @($script:objAppASite))
        $objCheck.State | Should -Be 'Corrupt'
        $objCheck.Differences | Should -Be 1
        $objCheck.Applications | Should -Be @('Device only: Old App')
        $objCheck.Message | Should -Match 'can be corrupt'
    }

    It 'counts an application that only the site lists' {
        $objGone = [pscustomobject]@{ Name = 'Gone App'; Version = '1.0'; Publisher = '' }
        (Test-DeviceInspectionInventory -Inspection (New-CheckInspection -DeviceApp @($script:objAppA) -SiteApp @($script:objAppASite, $objGone))).State | Should -Be 'Corrupt'
    }

    It 'does not count an application installed on or after the day of the last cycle' {
        $objNew = [pscustomobject]@{ Name = 'New App'; Version = '1.0'; Publisher = ''; InstallDate = '20261110' }
        (Test-DeviceInspectionInventory -Inspection (New-CheckInspection -DeviceApp @($script:objAppA, $objNew) -SiteApp @($script:objAppASite))).State | Should -Be 'Current'
    }

    It 'says NotCurrent when the site has not processed the last cycle' {
        $objOld = [pscustomobject]@{ Name = 'Old App'; Version = '2.0'; Publisher = ''; InstallDate = '20250101' }
        $objCheck = Test-DeviceInspectionInventory -Inspection (New-CheckInspection -SiteDate '2026-11-10T19:20:00' -Cycle '2026-11-10T19:21:32' -DeviceApp @($objOld) -SiteApp @())
        $objCheck.State | Should -Be 'NotCurrent'
        $objCheck.Differences | Should -Be 0
    }

    It 'says Unknown without the site record, without the client facts, or without a date' {
        $objNoSite = New-CheckInspection -DeviceApp @() -SiteApp @()
        $objNoSite.Site = $null
        (Test-DeviceInspectionInventory -Inspection $objNoSite).State | Should -Be 'Unknown'
        $objNoClient = New-CheckInspection -DeviceApp @() -SiteApp @()
        $objNoClient.Device.Client = $null
        (Test-DeviceInspectionInventory -Inspection $objNoClient).State | Should -Be 'Unknown'
        (Test-DeviceInspectionInventory -Inspection (New-CheckInspection -SiteDate '' -DeviceApp @() -SiteApp @())).State | Should -Be 'Unknown'
    }

    It 'counts a version that differs, and an install date before the cycle day, in any known format' {
        $objNewer = [pscustomobject]@{ Name = 'App A'; Version = '2.0'; Publisher = ''; InstallDate = '2026-11-09' }
        $objCheck = Test-DeviceInspectionInventory -Inspection (New-CheckInspection -DeviceApp @($objNewer) -SiteApp @($script:objAppASite))
        $objCheck.State | Should -Be 'Corrupt'
        $objCheck.Applications | Should -Be @('Version differs: App A')
    }

    It 'does not count an upgrade on the cycle day, with the date as <Format>' -ForEach @(
        @{ Format = 'yyyyMMdd'; Date = '20261110' }, @{ Format = 'yyyy/MM/dd'; Date = '2026/11/10' }, @{ Format = 'M/d/yyyy'; Date = '11/10/2026' }
    ) {
        $objNewer = [pscustomobject]@{ Name = 'App A'; Version = '2.0'; Publisher = ''; InstallDate = $Date }
        (Test-DeviceInspectionInventory -Inspection (New-CheckInspection -DeviceApp @($objNewer) -SiteApp @($script:objAppASite))).State | Should -Be 'Current'
    }

    It 'counts an application with an install date it cannot read' {
        $objOdd = [pscustomobject]@{ Name = 'Odd App'; Version = '1.0'; Publisher = ''; InstallDate = 'yesterday' }
        (Test-DeviceInspectionInventory -Inspection (New-CheckInspection -DeviceApp @($script:objAppA, $objOdd) -SiteApp @($script:objAppASite))).State | Should -Be 'Corrupt'
    }

    It 'says Unknown when the site application read failed' {
        $objInspection = New-CheckInspection -DeviceApp @($script:objAppA) -SiteApp @()
        $objInspection.Site | Add-Member -NotePropertyName 'ApplicationReadComplete' -NotePropertyValue $false
        $objCheck = Test-DeviceInspectionInventory -Inspection $objInspection
        $objCheck.State | Should -Be 'Unknown'
        $objCheck.Message | Should -Match 'not read completely'
    }

    It 'says Unknown when a site inventory class has no rows' {
        $objInspection = New-CheckInspection -DeviceApp @($script:objAppA) -SiteApp @($script:objAppASite)
        $objInspection.Site | Add-Member -NotePropertyName 'ApplicationReadComplete' -NotePropertyValue $true
        $objInspection.Site | Add-Member -NotePropertyName 'ApplicationRowsByClass' -NotePropertyValue ([pscustomobject]@{ SMS_G_System_ADD_REMOVE_PROGRAMS = 1; SMS_G_System_ADD_REMOVE_PROGRAMS_64 = 0 })
        $objCheck = Test-DeviceInspectionInventory -Inspection $objInspection
        $objCheck.State | Should -Be 'Unknown'
        $objCheck.Message | Should -Match 'no rows in SMS_G_System_ADD_REMOVE_PROGRAMS_64'
    }

    It 'says Unknown when the device application read failed' {
        $objInspection = New-CheckInspection -DeviceApp @() -SiteApp @($script:objAppASite)
        $objInspection.Device | Add-Member -NotePropertyName 'Problems' -NotePropertyValue @('Installed applications: Access denied')
        (Test-DeviceInspectionInventory -Inspection $objInspection).State | Should -Be 'Unknown'
    }

    It 'says Unknown when the cycle record is missing' {
        $objCheck = Test-DeviceInspectionInventory -Inspection (New-CheckInspection -Cycle '' -DeviceApp @() -SiteApp @())
        $objCheck.State | Should -Be 'Unknown'
        $objCheck.Message | Should -Match 'no hardware inventory cycle record'
    }

    It 'compares by name with Compare-DeviceInspectionApplication: Match, Version differs, Device only, Inventory only' {
        InModuleScope DeviceInspectorCommon {
            $objInspection = [pscustomobject]@{
                Site   = [pscustomobject]@{ InstalledApplications = @(
                        [pscustomobject]@{ Name = 'Same'; Version = '1'; Publisher = '' }
                        [pscustomobject]@{ Name = 'Changed '; Version = '1'; Publisher = '' }
                        [pscustomobject]@{ Name = 'Gone'; Version = '1'; Publisher = '' }
                    ) }
                Device = [pscustomobject]@{ InstalledApplications = @(
                        [pscustomobject]@{ Name = 'same'; Version = '1'; Publisher = 'P'; KeyName = 'a'; View = '64-bit' }
                        [pscustomobject]@{ Name = 'Same'; Version = '1'; Publisher = 'P'; KeyName = 'b'; View = '32-bit' }
                        [pscustomobject]@{ Name = 'Changed'; Version = '2'; Publisher = '' }
                        [pscustomobject]@{ Name = 'New'; Version = '1'; Publisher = '' }
                    ) }
            }
            $arrRow = @(Compare-DeviceInspectionApplication -Inspection $objInspection)
            $arrRow.Count | Should -Be 4
            @($arrRow | Where-Object { $_.Name -eq 'same' })[0].Status | Should -Be 'Match'
            @($arrRow | Where-Object { $_.Name -eq 'Changed' })[0].Status | Should -Be 'Version differs'
            @($arrRow | Where-Object { $_.Name -eq 'Changed' })[0].InventoryVersion | Should -Be '1'
            @($arrRow | Where-Object { $_.Name -eq 'New' })[0].Status | Should -Be 'Device only'
            @($arrRow | Where-Object { $_.Name -eq 'Gone' })[0].Status | Should -Be 'Inventory only'
        }
    }

    It 'shows the spelling of the site in the comparison and in the check output, as before' {
        InModuleScope DeviceInspectorCommon {
            $objInspection = [pscustomobject]@{
                Site   = [pscustomobject]@{ InstalledApplications = @([pscustomobject]@{ Name = '7-Zip'; Version = '1'; Publisher = '' }) }
                Device = [pscustomobject]@{ InstalledApplications = @([pscustomobject]@{ Name = '7-zip'; Version = '2'; Publisher = '' }) }
            }
            $arrRow = @(Compare-DeviceInspectionApplication -Inspection $objInspection)
            $arrRow.Count | Should -Be 1
            $arrRow[0].Name | Should -BeExactly '7-Zip'
            $arrRow[0].Status | Should -Be 'Version differs'
            $objCheckInspection = [pscustomobject]@{
                ComputerName = 'WS01'
                Site         = [pscustomobject]@{ Found = $true; HardwareScanClientTime = '2026-11-10T10:01:00'; InstalledApplications = @([pscustomobject]@{ Name = '7-Zip'; Version = '1'; Publisher = '' }) }
                Device       = [pscustomobject]@{ Client = [pscustomobject]@{ HardwareCycleLocalTime = '2026-11-10T10:00:00' }; InstalledApplications = @([pscustomobject]@{ Name = '7-zip'; Version = '2'; Publisher = ''; InstallDate = '20250101' }) }
            }
            (Test-DeviceInspectionInventory -Inspection $objCheckInspection).Applications | Should -Be @('Version differs: 7-Zip')
        }
    }

    It 'adds a Corrupt check to the problems of the inspection' {
        InModuleScope DeviceInspectorCommon {
            Mock Connect-InspectorSite { [pscustomobject]@{ SiteCode = 'XYZ'; SiteServer = 's'; PreviousLocation = 'C:\'; CreatedDrive = $false } }
            Mock Disconnect-InspectorSite { }
            Mock Get-SiteFact { [pscustomobject]@{ Found = $true; LastHardwareInventory = $null; HardwareScanClientTime = '2026-11-10T10:01:00'; ApplicationReadComplete = $true; ApplicationRowsByClass = $null; InstalledApplications = @() } }
            Mock Get-DeviceFact { [pscustomobject]@{ Client = [pscustomobject]@{ HardwareCycleLocalTime = '2026-11-10T10:00:00' }; InstalledApplications = @([pscustomobject]@{ Name = 'Old App'; Version = '1'; Publisher = ''; InstallDate = '20200101' }); Problems = @() } }
            $objInspection = Get-DeviceInspection -ComputerName 'WS01' -SiteServer 's' -SiteCode 'XYZ'
            $objInspection.InventoryCheck.State | Should -Be 'Corrupt'
            @($objInspection.Problems | Where-Object { $_ -like 'Inventory: *can be corrupt*' }).Count | Should -Be 1
        }
    }

    It 'clears the check after a repair or a full inventory, so the button turns off' {
        $script:strStart | Should -Match "(?s)function Clear-InventoryCheck \{.*?State = 'Unknown'.*?-notlike 'Inventory: \*'.*?Show-Inspection -Inspection \`$script:Inspection.*?Update-ControlState"
        $script:strStart | Should -Match "-Function 'Invoke-DeviceInspectorFullInventory' -AfterRun \{ param\(\`$r, \`$ctx\) Clear-InventoryCheck \}"
        $script:strStart | Should -Match '-AfterRun \{ param\(\$r, \$ctx\) Clear-InventoryCheck;'
    }

    It 'adds the check to the facts of the Device panel' {
        $objInspection = New-CheckInspection -DeviceApp @($script:objAppA) -SiteApp @()
        $objInspection | Add-Member -NotePropertyName 'InventoryCheck' -NotePropertyValue (Test-DeviceInspectionInventory -Inspection $objInspection)
        $objInspection.Site | Add-Member -NotePropertyName 'ResourceId' -NotePropertyValue 1
        foreach ($strName in 'ClientInstalled', 'ClientVersion', 'Active', 'OperatingSystem', 'LastLogonUserName') { $objInspection.Site | Add-Member -NotePropertyName $strName -NotePropertyValue '' }
        $objInspection.Device | Add-Member -NotePropertyName 'OperatingSystem' -NotePropertyValue $null
        $objInspection.Device.Client = $null
        $arrRow = @(ConvertTo-DeviceInspectionFactRow -Inspection $objInspection | Where-Object Group -eq 'Inventory check')
        $arrRow.Count | Should -Be 3
        $arrRow[0].Value | Should -Be 'Corrupt'
        $arrRow[2].Value | Should -Be 'Device only: App A'
    }

    It 'repairs with the full hardware inventory script under its own action name' {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @() } }
        $objResult = Invoke-DeviceInspectorInventoryRepair -ComputerName 'WS01' -DryRun
        $objResult.Action | Should -Be 'Corrupt-inventory repair'
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript -Times 1 -Exactly -ParameterFilter { $ScriptBlock.ToString() -match 'InventoryActionStatus' -and $ArgumentList[0] -eq $true }
    }

    It 'turns the Repair inventory button on only for the state Corrupt' {
        $script:strXaml | Should -Match 'x:Name="btnRepairInventory"'
        $script:strStart | Should -Match '\$btnRepairInventory\.IsEnabled = \(Test-DeviceActionReady\) -and \(Test-InventoryCorrupt\)'
        $script:strStart | Should -Match "(?s)function Test-InventoryCorrupt \{.*?State -eq 'Corrupt'"
        $script:strStart | Should -Match "(?s)\`$btnRepairInventory\.Add_Click\(\{\s*if \(-not \(Test-InventoryCorrupt\)\).*?Invoke-DeviceAction -Name 'Corrupt-inventory repair' -Function 'Invoke-DeviceInspectorInventoryRepair'"
    }
}

Describe 'Install pending updates' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
    }

    BeforeEach {
        InModuleScope DeviceInspectorCommon {
            function New-TestUpdate {
                param([string]$Id, [string]$Kb, [uint32]$Compliance, [uint32]$State = 0)
                New-CimInstance -ClassName 'CCM_SoftwareUpdate' -Namespace 'root/ccm/ClientSDK' -ClientOnly -Property @{
                    UpdateID = $Id; ArticleID = $Kb; Name = ('Update KB{0}' -f $Kb); ComplianceState = $Compliance; EvaluationState = $State; PercentComplete = [uint32]0
                }
            }
            $script:arrTestUpdate = @(
                New-TestUpdate -Id 'Site_X/SUM_1' -Kb '5001' -Compliance 0
                New-TestUpdate -Id 'Site_X/SUM_2' -Kb '5002' -Compliance 0
                New-TestUpdate -Id 'Site_X/SUM_3' -Kb '5003' -Compliance 1
            )
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance { $script:arrTestUpdate } -ParameterFilter { $ClassName -eq 'CCM_SoftwareUpdate' }
            Mock Start-Sleep { }
        }
    }

    It 'passes the update IDs and names the action by the scope' {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @() } }
        (Invoke-DeviceInspectorUpdateInstall -ComputerName 'WS01' -UpdateId @('Site_X/SUM_1') -DryRun).Action | Should -Be 'Install selected pending updates'
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq $true -and @($ArgumentList[1]) -contains 'Site_X/SUM_1' }
        (Invoke-DeviceInspectorUpdateInstall -ComputerName 'WS01').Action | Should -Be 'Install all pending updates'
    }

    It 'refuses an update ID with characters outside the pattern' {
        { Invoke-DeviceInspectorUpdateInstall -ComputerName 'WS01' -UpdateId @("a'; Remove-Item") } | Should -Throw
    }

    It 'lists only the missing updates and changes nothing in a dry run' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockUpdateInstall $true @()
            $objRaw.Succeeded | Should -BeTrue
            ($objRaw.Steps -join "`n") | Should -Match 'Missing on the device \(ComplianceState 0\): 2\. To install: 2\.'
            ($objRaw.Steps -join "`n") | Should -Not -Match 'KB5003'
            ($objRaw.Steps -join "`n") | Should -Match 'Dry run: would call CCM_SoftwareUpdatesManager.InstallUpdates for 2 updates'
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'installs only the selected missing updates' {
        InModuleScope DeviceInspectorCommon {
            $script:arrSent = @()
            Mock Invoke-CimMethod { $script:arrSent = @($Arguments.CCMUpdates | ForEach-Object { $_.UpdateID }); [pscustomobject]@{ ReturnValue = 0 } }
            $objRaw = & $script:scriptBlockUpdateInstall $false @('Site_X/SUM_2', 'Site_X/SUM_3')
            $objRaw.Succeeded | Should -BeTrue
            @($script:arrSent) | Should -Be @('Site_X/SUM_2')
            Should -Invoke Invoke-CimMethod -Times 1 -Exactly -ParameterFilter { $Namespace -eq 'root\ccm\ClientSDK' -and $ClassName -eq 'CCM_SoftwareUpdatesManager' -and $MethodName -eq 'InstallUpdates' }
            ($objRaw.Steps -join "`n") | Should -Match 'After the request: KB5002'
        }
    }

    It 'fails and calls no method when no selected update is missing' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockUpdateInstall $false @('Site_X/SUM_3')
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'No update to install'
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'reports a refused or failed install request' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 2147749890 } }
            (& $script:scriptBlockUpdateInstall $false @()).Summary | Should -Match 'refused the install request \(return value 2147749890\)'
            Mock Invoke-CimMethod { throw 'Generic failure' }
            (& $script:scriptBlockUpdateInstall $false @()).Summary | Should -Match 'did not accept the install request'
        }
    }

    It 'skips an update with an install job in progress and says so' {
        InModuleScope DeviceInspectorCommon {
            $script:arrTestUpdate = @(New-CimInstance -ClassName 'CCM_SoftwareUpdate' -Namespace 'root/ccm/ClientSDK' -ClientOnly -Property @{
                    UpdateID = 'Site_X/SUM_9'; ArticleID = '5009'; Name = 'Update KB5009'; ComplianceState = [uint32]0; EvaluationState = [uint32]5; PercentComplete = [uint32]10 })
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockUpdateInstall $false @()
            $objRaw.Succeeded | Should -BeFalse
            ($objRaw.Steps -join "`n") | Should -Match 'Skipped KB5009: an install job is in progress or complete, state Downloading \(5\)'
            $objRaw.Summary | Should -Match 'each matching update has an install job in progress or complete'
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'binds the ID list to the device script for <Case> IDs, as Invoke-ActionOnDevice builds it' -ForEach @(
        @{ Case = 'zero'; Ids = @(); Expected = 2 }, @{ Case = 'one'; Ids = @('Site_X/SUM_1'); Expected = 1 }, @{ Case = 'many'; Ids = @('Site_X/SUM_1', 'Site_X/SUM_2'); Expected = 2 }
    ) {
        InModuleScope DeviceInspectorCommon -Parameters @{ Ids = $Ids; Expected = $Expected } {
            param($Ids, $Expected)
            $script:intSent = -1
            Mock Invoke-CimMethod { $script:intSent = @($Arguments.CCMUpdates).Count; [pscustomobject]@{ ReturnValue = 0 } }
            $arrArgument = @(, $false) + @(@(, [string[]]@($Ids)))
            $objRaw = & $script:scriptBlockUpdateInstall @arrArgument
            $objRaw.Succeeded | Should -BeTrue
            $script:intSent | Should -Be $Expected
        }
    }

    It 'notes a missing return value of the install request' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CimMethod { }
            ((& $script:scriptBlockUpdateInstall $false @()).Steps -join "`n") | Should -Match 'gave no return value'
        }
    }

    It 'sends the confirmed IDs also for all, and selects the row under the pointer' {
        $script:strStart | Should -Match "(?s)function Invoke-UpdateInstall \{.*?UpdateId = \[string\[\]\]@\(\`$Rows \| ForEach-Object"
        $script:strStart | Should -Match '\$gridUpdates\.Add_PreviewMouseRightButtonDown\(\{ param\(\$s, \$e\) try \{ Select-RowUnderPointer -Grid \$gridUpdates'
        $script:strStart | Should -Match "\`$gate = Get-ActionGateText"
    }

    It 'marks only device rows that the client lists as missing as installable' {
        $objInspection = [pscustomobject]@{
            Site = $null
            Device = [pscustomobject]@{ PendingUpdates = @(
                    [pscustomobject]@{ Name = 'A'; ArticleId = '5001'; UpdateId = 'Site_X/SUM_1'; ComplianceState = 0; State = 'None'; Deadline = $null }
                    [pscustomobject]@{ Name = 'B'; ArticleId = '5003'; UpdateId = 'Site_X/SUM_3'; ComplianceState = 1; State = 'None'; Deadline = $null }
                    [pscustomobject]@{ Name = 'C'; ArticleId = '5004'; UpdateId = 'Site_X/SUM_4'; ComplianceState = 0; EvaluationState = 5; State = 'Downloading'; Deadline = $null }
                ) }
        }
        $arrRow = @(ConvertTo-DeviceInspectionUpdateRow -Inspection $objInspection)
        $arrRow[0].Required | Should -BeTrue
        $arrRow[0].UpdateId | Should -Be 'Site_X/SUM_1'
        $arrRow[1].Required | Should -BeFalse
        $arrRow[2].Required | Should -BeFalse
    }

    It 'has two Updates menu entries that open the action through the gate' {
        $script:strXaml | Should -Match 'x:Name="menuInstallSelected"[^>]*ToolTipService.ShowOnDisabled="True"'
        $script:strXaml | Should -Match 'x:Name="menuInstallAll"'
        $script:strStart | Should -Match "(?s)\`$gridUpdates\.ContextMenu\.Add_Opened\(\{.*?\`$gate = Get-ActionGateText"
        $script:strStart | Should -Match "(?s)function Invoke-UpdateInstall \{.*?Invoke-DeviceAction -Name \`$name -Function 'Invoke-DeviceInspectorUpdateInstall'"
        $script:strStart | Should -Match "(?s)function Get-InstallableUpdateRow \{.*?Source -eq 'Device' -and \`$_\.Required"
    }
}

Describe 'Uninstall and repair an application' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
        $script:listTestKey = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $script:strUninstallPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        $script:strUninstallPath32 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        $script:strSystem = Join-Path -Path $env:SystemRoot -ChildPath 'System32'

        # The inner script blocks of the device block hold the rules. They take no outside
        # state, so the tests run them alone, found by name in the syntax tree.
        $script:hashtableBlock = InModuleScope DeviceInspectorCommon {
            $hashtableFound = @{}
            foreach ($strName in 'scriptBlockIsMsi', 'scriptBlockSplitCommand', 'scriptBlockMapExitCode') {
                $strVariable = '$' + $strName
                $objAssignment = $script:scriptBlockApplicationAction.Ast.Find({ param($objNode) $objNode -is [System.Management.Automation.Language.AssignmentStatementAst] -and $objNode.Left.Extent.Text -eq $strVariable }, $true)
                $hashtableFound[$strName] = $objAssignment.Right.Expression.ScriptBlock.GetScriptBlock()
            }
            $hashtableFound
        }

        # A test uninstall key. The key goes away in AfterAll. Dry runs only read it.
        function New-TestUninstallKey {
            param([string]$View, [string]$KeyName, [hashtable]$Value)
            $strParent = $script:strUninstallPath
            if ($View -eq '32-bit') {
                $strParent = $script:strUninstallPath32
            }
            $strPath = '{0}\{1}' -f $strParent, $KeyName
            $null = New-Item -Path $strPath -Force
            foreach ($strName in $Value.Keys) {
                $strType = 'String'
                if ($Value[$strName] -is [int]) {
                    $strType = 'DWord'
                }
                $null = New-ItemProperty -LiteralPath $strPath -Name $strName -Value $Value[$strName] -PropertyType $strType -Force
            }
            $script:listTestKey.Add($strPath)
        }
        function New-TestGuid {
            return ('{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}')
        }
        function Invoke-TestApplicationBlock {
            param([bool]$DryRun, [string]$Operation, [string]$View, [string]$KeyName, [switch]$RealRun)
            InModuleScope DeviceInspectorCommon -Parameters @{ DryRun = $DryRun; Operation = $Operation; View = $View; KeyName = $KeyName; RealRun = $RealRun.IsPresent } {
                param($DryRun, $Operation, $View, $KeyName, $RealRun)
                # A dry run, a refusal and a missing key start nothing. Only a real run in GitHub CI starts the stand-in.
                if (-not $RealRun) {
                    Mock Start-Process { }
                }
                $objRaw = & $script:scriptBlockApplicationAction $DryRun $Operation $View $KeyName
                if (-not $RealRun) {
                    Should -Invoke Start-Process -Times 0 -Exactly
                }
                $objRaw
            }
        }
    }

    AfterAll {
        foreach ($strPath in $script:listTestKey) {
            Remove-Item -LiteralPath $strPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'takes the view and the key name, and no application ID or command line' {
        $hashtableParameter = (Get-Command -Name Invoke-DeviceInspectorApplicationAction -Module DeviceInspectorCommon).Parameters
        foreach ($strName in 'ComputerName', 'Operation', 'View', 'KeyName', 'DryRun', 'Credential') {
            $hashtableParameter.ContainsKey($strName) | Should -BeTrue -Because $strName
        }
        foreach ($strName in 'ApplicationId', 'Command', 'CommandLine', 'UninstallString', 'Arguments') {
            $hashtableParameter.ContainsKey($strName) | Should -BeFalse -Because $strName
        }
    }

    It 'adds the version to the name only when the name does not hold it' {
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool' -Version '1.2.3' | Should -Be 'Contoso Tool 1.2.3'
        Get-DeviceInspectorApplicationLabel -Name 'Microsoft Visual C++ 2022 X86 Minimum Runtime - 14.51.36247' -Version '14.51.36247' | Should -Be 'Microsoft Visual C++ 2022 X86 Minimum Runtime - 14.51.36247'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool 1.2.3 (x64)' -Version '1.2.3' | Should -Be 'Contoso Tool 1.2.3 (x64)'
        Get-DeviceInspectorApplicationLabel -Name 'CONTOSO TOOL V1.2.3' -Version 'v1.2.3' | Should -Be 'CONTOSO TOOL V1.2.3'
        Get-DeviceInspectorApplicationLabel -Name '  Contoso Tool  ' -Version ' 1.2.3 ' | Should -Be 'Contoso Tool 1.2.3'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool' -Version '' | Should -Be 'Contoso Tool'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool' -Version $null | Should -Be 'Contoso Tool'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool, 1.2.3' -Version '1.2.3' | Should -Be 'Contoso Tool, 1.2.3'
    }

    It 'matches the version at token boundaries only' {
        # A version inside a longer number or a longer version is not the version of the name.
        Get-DeviceInspectorApplicationLabel -Name 'Office 2019' -Version '1' | Should -Be 'Office 2019 1'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool 1.2.34' -Version '1.2.3' | Should -Be 'Contoso Tool 1.2.34 1.2.3'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool 11.2.3' -Version '1.2.3' | Should -Be 'Contoso Tool 11.2.3 1.2.3'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool 1.2.3.4' -Version '1.2.3' | Should -Be 'Contoso Tool 1.2.3.4 1.2.3'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool v1.2.3' -Version '1.2.3' | Should -Be 'Contoso Tool v1.2.3 1.2.3'
        # The dots of the version are literal, not regular expression wildcards.
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool 1x2x3' -Version '1.2.3' | Should -Be 'Contoso Tool 1x2x3 1.2.3'
    }

    It 'treats a version with trailing .0 parts as equal to the shorter version' {
        Get-DeviceInspectorApplicationLabel -Name 'Microsoft Visual C++ 2022 X86 Minimum Runtime - 14.51.36247' -Version '14.51.36247.0' | Should -Be 'Microsoft Visual C++ 2022 X86 Minimum Runtime - 14.51.36247'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool 1.2' -Version '1.2.0.0' | Should -Be 'Contoso Tool 1.2'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool 1.0' -Version '1.0' | Should -Be 'Contoso Tool 1.0'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool' -Version '1.0.0' | Should -Be 'Contoso Tool 1.0.0'
        Get-DeviceInspectorApplicationLabel -Name 'Contoso Tool 2' -Version '10.0' | Should -Be 'Contoso Tool 2 10.0'
    }

    It 'builds the confirmation text and the log detail of an application with the label' {
        $strFunction = [regex]::Match($script:strStart, '(?s)function Invoke-ApplicationOperation \{.*?\r?\n\}\r?\n').Value
        $strFunction | Should -Match 'Get-DeviceInspectorApplicationLabel -Name \(\[string\]\$row\.Name\) -Version \(\[string\]\$row\.Version\)'
        $strFunction | Should -Not -Match '\$row\.Name, \$row\.Version'
    }

    It 'names the action and passes operation, view and key name after DryRun' {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @() } }
        (Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -Operation Uninstall -View '64-bit' -KeyName '{23170F69-40C1-2702-2600-000001000000}' -DryRun).Action | Should -Be 'Uninstall application'
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'WS01' -and $ArgumentList[0] -eq $true -and $ArgumentList[1] -eq 'Uninstall' -and $ArgumentList[2] -eq '64-bit' -and $ArgumentList[3] -eq '{23170F69-40C1-2702-2600-000001000000}' }
        (Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -Operation Repair -View '32-bit' -KeyName 'Some App' -DryRun).Action | Should -Be 'Repair application'
    }

    It 'passes a non-dry run to the device script with DryRun false' {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @() } }
        $objResult = Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -Operation Uninstall -View '64-bit' -KeyName 'Some App'
        $objResult.Mode | Should -Be 'RUN'
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq $false }
    }

    It 'refuses a key name with a path character, a quote or a wildcard, and a view or operation outside the set' -ForEach @(
        @{ Key = 'a\b' }, @{ Key = '..\x' }, @{ Key = 'a/b' }, @{ Key = 'a"b' }, @{ Key = 'a*b' }, @{ Key = 'a|b' }, @{ Key = '' }
    ) {
        { Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -Operation Uninstall -View '64-bit' -KeyName $Key } | Should -Throw
    }

    It 'refuses a bad view, a bad operation and a bad computer name' {
        { Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -Operation Uninstall -View 'HKCU' -KeyName 'a' } | Should -Throw
        { Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -Operation Remove -View '64-bit' -KeyName 'a' } | Should -Throw
        { Invoke-DeviceInspectorApplicationAction -ComputerName "WS01'; calc" -Operation Uninstall -View '64-bit' -KeyName 'a' } | Should -Throw
    }

    It 'accepts a product code and a normal key name' -ForEach @(
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}' }, @{ Key = 'Mozilla Firefox 130.0 (x64 en-US)' }, @{ Key = '{ABC}_is1' }, @{ Key = '7-Zip' }
    ) {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @() } }
        { Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -Operation Uninstall -View '64-bit' -KeyName $Key -DryRun } | Should -Not -Throw
    }

    It 'returns a failed result when the device does not answer, and says that a step can have run' {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { throw 'WinRM cannot complete the operation.' }
        $objResult = Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -Operation Uninstall -View '64-bit' -KeyName 'a'
        $objResult.Succeeded | Should -BeFalse
        $objResult.Summary | Should -Match 'Inspect the device to see its state'
    }

    It 'sends no command line, so the device builds it: the action file calls Start-Process only inside the device block' {
        $objAst = [System.Management.Automation.Language.Parser]::ParseFile($script:strActionsFile, [ref]$null, [ref]$null)
        foreach ($objFunction in @($objAst.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            $arrCommand = @($objFunction.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
            $arrCommand | Should -Not -Contain 'Start-Process' -Because $objFunction.Name
        }
        $objBlock = $objAst.Find({ param($objNode) $objNode -is [System.Management.Automation.Language.AssignmentStatementAst] -and $objNode.Left.Extent.Text -eq '$script:scriptBlockApplicationAction' }, $true)
        @($objBlock.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.CommandAst] -and $objNode.GetCommandName() -eq 'Start-Process' }, $true)).Count | Should -Be 1
    }

    It 'detects MSI for the key <Key> with the uninstall string <Uninstall> and WindowsInstaller <Installer>: <Expected>' -ForEach @(
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = 'MsiExec.exe /I{23170F69-40C1-2702-2600-000001000000}'; Installer = 0; Expected = $true }
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = 'msiexec /x {23170F69-40C1-2702-2600-000001000000}'; Installer = 0; Expected = $true }
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = '"C:\Windows\System32\MSIEXEC.EXE" /x {23170F69-40C1-2702-2600-000001000000}'; Installer = 0; Expected = $true }
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = '"msiexec.exe" /x {23170F69-40C1-2702-2600-000001000000}'; Installer = 0; Expected = $true }
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = 'C:\Vendor\setup.exe /remove'; Installer = 1; Expected = $true }
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = ''; Installer = 1; Expected = $true }
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = 'C:\Vendor\setup.exe /remove'; Installer = 0; Expected = $false }
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = 'C:\Vendor\msiexec-helper.exe'; Installer = 0; Expected = $false }
        @{ Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = 'msiexecfoo.exe /x'; Installer = 0; Expected = $false }
        @{ Key = 'SomeProduct_is1'; Uninstall = 'MsiExec.exe /X{23170F69-40C1-2702-2600-000001000000}'; Installer = 1; Expected = $false }
        @{ Key = '23170F69-40C1-2702-2600-000001000000'; Uninstall = 'MsiExec.exe /X{23170F69-40C1-2702-2600-000001000000}'; Installer = 1; Expected = $false }
        @{ Key = '{23170F69-40C1-2702-2600-00000100000}'; Uninstall = 'MsiExec.exe /X{23170F69-40C1-2702-2600-000001000000}'; Installer = 1; Expected = $false }
    ) {
        $scriptBlockIsMsi = $script:hashtableBlock['scriptBlockIsMsi']
        (& $scriptBlockIsMsi $Key $Uninstall $Installer) | Should -Be $Expected
    }

    It 'splits the quiet uninstall string <Command> into the path <Path> and the arguments <Arguments>' -ForEach @(
        @{ Command = '"C:\Program Files\App\unins000.exe" /VERYSILENT /NORESTART'; Path = 'C:\Program Files\App\unins000.exe'; Arguments = '/VERYSILENT /NORESTART' }
        @{ Command = 'C:\Program Files\App\unins000.exe /S'; Path = 'C:\Program Files\App\unins000.exe'; Arguments = '/S' }
        @{ Command = 'C:\Program Files\App\unins000.EXE   /S /v"/qn"'; Path = 'C:\Program Files\App\unins000.EXE'; Arguments = '/S /v"/qn"' }
        @{ Command = '  "C:\App\setup.exe"  '; Path = 'C:\App\setup.exe'; Arguments = '' }
        @{ Command = 'C:\App\setup.exe'; Path = 'C:\App\setup.exe'; Arguments = '' }
        @{ Command = 'MsiExec.exe /X{23170F69-40C1-2702-2600-000001000000} /qn'; Path = 'MsiExec.exe'; Arguments = '/X{23170F69-40C1-2702-2600-000001000000} /qn' }
        @{ Command = 'C:\a.exe.old\b.exe /q'; Path = 'C:\a.exe.old\b.exe'; Arguments = '/q' }
        @{ Command = '"C:\Program Files\App\x.exe" "C:\Program Files\App\y.exe" /s'; Path = 'C:\Program Files\App\x.exe'; Arguments = '"C:\Program Files\App\y.exe" /s' }
        @{ Command = 'cmd.exe /c exit 0'; Path = 'cmd.exe'; Arguments = '/c exit 0' }
        @{ Command = '"\\server\share\u.exe" /S'; Path = '\\server\share\u.exe'; Arguments = '/S' }
        @{ Command = 'D:/App/u.exe /S'; Path = 'D:/App/u.exe'; Arguments = '/S' }
    ) {
        $scriptBlockSplit = $script:hashtableBlock['scriptBlockSplitCommand']
        $objSplit = & $scriptBlockSplit $Command
        $objSplit.FilePath | Should -Be $Path
        $objSplit.Arguments | Should -Be $Arguments
    }

    It 'does not split <Command>, so the device refuses to run it' -ForEach @(
        @{ Command = '' }, @{ Command = '   ' }, @{ Command = '"unterminated C:\app.exe /s' }, @{ Command = 'C:\App\uninstall.bat /s' }, @{ Command = 'rundll32.dll,Uninstall' }, @{ Command = '""' }, @{ Command = '.\x.exe /s' }, @{ Command = 'sub\x.exe /s' }, @{ Command = '"..\x.exe" /s' }, @{ Command = '\x.exe /s' }, @{ Command = '/x.exe /s' }, @{ Command = 'cmd /c del x' }
    ) {
        $scriptBlockSplit = $script:hashtableBlock['scriptBlockSplitCommand']
        $objSplit = & $scriptBlockSplit $Command
        $objSplit | Should -BeNullOrEmpty
    }

    It 'maps the exit code <Code> of <Operation> with the key gone <Gone>: success <Expected>, restart <Restart>' -ForEach @(
        @{ Operation = 'Uninstall'; Code = 0; Gone = $true; Expected = $true; Restart = $false; Text = 'exit code 0' }
        @{ Operation = 'Repair'; Code = 0; Gone = $false; Expected = $true; Restart = $false; Text = 'exit code 0' }
        @{ Operation = 'Uninstall'; Code = 3010; Gone = $true; Expected = $true; Restart = $true; Text = 'restart of the device is needed.*never restarts' }
        @{ Operation = 'Repair'; Code = 3010; Gone = $false; Expected = $true; Restart = $true; Text = 'restart of the device is needed' }
        @{ Operation = 'Uninstall'; Code = 1641; Gone = $true; Expected = $true; Restart = $true; Text = 'restart of the device is needed' }
        @{ Operation = 'Repair'; Code = 1641; Gone = $false; Expected = $true; Restart = $true; Text = 'restart of the device is needed' }
        @{ Operation = 'Uninstall'; Code = 1605; Gone = $true; Expected = $true; Restart = $false; Text = 'already removed' }
        @{ Operation = 'Uninstall'; Code = 1605; Gone = $false; Expected = $false; Restart = $false; Text = 'key is still there' }
        @{ Operation = 'Repair'; Code = 1605; Gone = $true; Expected = $false; Restart = $false; Text = 'exit code 1605' }
        @{ Operation = 'Uninstall'; Code = 1618; Gone = $false; Expected = $false; Restart = $false; Text = 'another installation is in progress.*later' }
        @{ Operation = 'Repair'; Code = 1618; Gone = $false; Expected = $false; Restart = $false; Text = 'another installation is in progress' }
        @{ Operation = 'Uninstall'; Code = 1603; Gone = $false; Expected = $false; Restart = $false; Text = 'exit code 1603' }
        @{ Operation = 'Uninstall'; Code = 1; Gone = $true; Expected = $false; Restart = $false; Text = 'exit code 1' }
        @{ Operation = 'Repair'; Code = -2147024891; Gone = $false; Expected = $false; Restart = $false; Text = 'exit code -2147024891' }
    ) {
        $scriptBlockMap = $script:hashtableBlock['scriptBlockMapExitCode']
        $objMap = & $scriptBlockMap $Operation $Code $Gone
        $objMap.Succeeded | Should -Be $Expected
        $objMap.RestartNeeded | Should -Be $Restart
        $objMap.Text | Should -Match $Text
    }

    It 'fails with a clear summary when the key is not on the device' -ForEach @(@{ View = '64-bit' }, @{ View = '32-bit' }) {
        $objRaw = Invoke-TestApplicationBlock -DryRun $false -Operation 'Uninstall' -View $View -KeyName (New-TestGuid)
        $objRaw.Succeeded | Should -BeFalse
        $objRaw.Summary | Should -Match 'is not on the device now'
        $objRaw.Summary | Should -Match ([regex]::Escape($View))
    }

    It 'lists the msiexec uninstall command in a dry run, and starts nothing' {
        $strKey = New-TestGuid
        New-TestUninstallKey -View '64-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test MSI'; UninstallString = ('MsiExec.exe /I{0}' -f $strKey); WindowsInstaller = 1 }
        $objRaw = Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '64-bit' -KeyName $strKey
        $objRaw.Succeeded | Should -BeTrue
        $objRaw.Summary | Should -Match 'Nothing changed'
        $objRaw.Steps | Should -Contain ('Dry run: would run: msiexec.exe /x {0} /qn /norestart REBOOT=ReallySuppress' -f $strKey)
        ($objRaw.Steps -join "`n") | Should -Match 'type MSI'
    }

    It 'lists the msiexec repair command with REINSTALL=ALL and REINSTALLMODE=omus in a dry run, not /f' {
        $strKey = New-TestGuid
        New-TestUninstallKey -View '32-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test MSI 32'; UninstallString = ('MsiExec.exe /X{0}' -f $strKey) }
        $objRaw = Invoke-TestApplicationBlock -DryRun $true -Operation 'Repair' -View '32-bit' -KeyName $strKey
        $objRaw.Succeeded | Should -BeTrue
        $objRaw.Steps | Should -Contain ('Dry run: would run: msiexec.exe /i {0} REINSTALL=ALL REINSTALLMODE=omus /qn /norestart REBOOT=ReallySuppress' -f $strKey)
        ($objRaw.Steps -join "`n") | Should -Not -Match ' /f'
    }

    It 'finds the key in the view that the caller names and not in the other view' {
        $strKey = New-TestGuid
        New-TestUninstallKey -View '32-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test view'; UninstallString = ('MsiExec.exe /X{0}' -f $strKey) }
        (Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '32-bit' -KeyName $strKey).Succeeded | Should -BeTrue
        (Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '64-bit' -KeyName $strKey).Summary | Should -Match 'is not on the device now'
    }

    It 'lists the quiet uninstall string as written for an EXE entry in a dry run' {
        $strCmd = Join-Path -Path $script:strSystem -ChildPath 'cmd.exe'
        $strQuiet = '"{0}" /c exit 0' -f $strCmd
        $strKey = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test EXE'; UninstallString = 'C:\nothing\unins.exe'; QuietUninstallString = $strQuiet }
        $objRaw = Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '64-bit' -KeyName $strKey
        $objRaw.Succeeded | Should -BeTrue
        $objRaw.Steps | Should -Contain ('Dry run: would run: {0}' -f $strQuiet)
        ($objRaw.Steps -join "`n") | Should -Match 'type EXE'
    }

    It 'refuses a repair of an EXE entry, with no command run' {
        $strKey = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test EXE'; QuietUninstallString = ('"{0}\cmd.exe" /c exit 0' -f $script:strSystem) }
        $objRaw = Invoke-TestApplicationBlock -DryRun $false -Operation 'Repair' -View '64-bit' -KeyName $strKey
        $objRaw.Succeeded | Should -BeFalse
        $objRaw.Summary | Should -Match 'no documented repair command'
    }

    It 'refuses an EXE entry without a quiet uninstall string and guesses no switches' {
        $strKey = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test EXE'; UninstallString = ('"{0}\cmd.exe" /c exit 0' -f $script:strSystem) }
        $objRaw = Invoke-TestApplicationBlock -DryRun $false -Operation 'Uninstall' -View '64-bit' -KeyName $strKey
        $objRaw.Succeeded | Should -BeFalse
        $objRaw.Summary | Should -Match 'no quiet uninstall string'
        $objRaw.Summary | Should -Match 'does not guess silent switches'
    }

    It 'refuses a system component, also for an MSI product' {
        $strKey = New-TestGuid
        New-TestUninstallKey -View '64-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test hidden'; UninstallString = ('MsiExec.exe /X{0}' -f $strKey); SystemComponent = 1 }
        $objRaw = Invoke-TestApplicationBlock -DryRun $false -Operation 'Uninstall' -View '64-bit' -KeyName $strKey
        $objRaw.Succeeded | Should -BeFalse
        $objRaw.Summary | Should -Match 'system component, part of another product'
        (Invoke-TestApplicationBlock -DryRun $true -Operation 'Repair' -View '64-bit' -KeyName $strKey).Succeeded | Should -BeFalse
    }

    It 'refuses an EXE entry whose uninstall program is not on the device, and one with no .exe path' {
        $strKey = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test missing'; QuietUninstallString = '"C:\DiTest-no-such-folder\unins000.exe" /S' }
        $objRaw = Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '64-bit' -KeyName $strKey
        $objRaw.Succeeded | Should -BeFalse
        $objRaw.Summary | Should -Match 'is not on the device'
        $strBat = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strBat -Value @{ DisplayName = 'DI test bat'; QuietUninstallString = 'C:\DiTest\uninstall.bat /s' }
        $objBat = Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '64-bit' -KeyName $strBat
        $objBat.Succeeded | Should -BeFalse
        $objBat.Summary | Should -Match 'no file path that ends in .exe'
    }

    It 'refuses a relative quiet uninstall path with a separator, and looks up a bare file name in System32 only' {
        $strRel = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strRel -Value @{ DisplayName = 'DI test relative'; QuietUninstallString = '.\unins000.exe /S' }
        $objRel = Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '64-bit' -KeyName $strRel
        $objRel.Succeeded | Should -BeFalse
        $objRel.Summary | Should -Match 'path is relative'
        $strSub = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strSub -Value @{ DisplayName = 'DI test sub'; QuietUninstallString = 'sub\unins000.exe /S' }
        (Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '64-bit' -KeyName $strSub).Summary | Should -Match 'path is relative'
        $strBare = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strBare -Value @{ DisplayName = 'DI test bare'; QuietUninstallString = 'cmd.exe /c exit 0' }
        $objBare = Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '64-bit' -KeyName $strBare
        $objBare.Succeeded | Should -BeTrue
        $objBare.Steps | Should -Contain 'Dry run: would run: cmd.exe /c exit 0'
        $strMissing = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strMissing -Value @{ DisplayName = 'DI test bare missing'; QuietUninstallString = 'ditest-no-such-program.exe /S' }
        $objMissing = Invoke-TestApplicationBlock -DryRun $true -Operation 'Uninstall' -View '64-bit' -KeyName $strMissing
        $objMissing.Succeeded | Should -BeFalse
        $objMissing.Summary | Should -Match 'is not on the device'
        $objMissing.Summary | Should -Match 'System32'
    }

    It 'splits a command the same way in the row builder helper and in the device block' -ForEach @(
        @{ Command = '"C:\Program Files\App\unins000.exe" /VERYSILENT' }, @{ Command = 'C:\App\u.exe /S' }, @{ Command = 'cmd.exe /c exit 0' }
        @{ Command = '.\x.exe /s' }, @{ Command = 'sub\x.exe' }, @{ Command = '"..\x.exe" /s' }, @{ Command = 'cmd /c del x' }, @{ Command = '' }
        @{ Command = '"\\server\share\u.exe" /S' }, @{ Command = '\x.exe' }, @{ Command = '"unterminated C:\a.exe' }, @{ Command = 'C:\a.exe.old\b.exe /q' }
    ) {
        $scriptBlockSplit = $script:hashtableBlock['scriptBlockSplitCommand']
        $objDevice = & $scriptBlockSplit $Command
        $objHelper = InModuleScope DeviceInspectorCommon -Parameters @{ Command = $Command } { param($Command) Split-DeviceInspectionCommand -Command $Command }
        if ($null -eq $objDevice) {
            $objHelper | Should -BeNullOrEmpty
        } else {
            $objHelper.FilePath | Should -Be $objDevice.FilePath
            $objHelper.Arguments | Should -Be $objDevice.Arguments
        }
    }

    It 'says that the tool could not read the key after the run, and does not say the key is still there' -ForEach @(
        @{ Code = 0; Expected = $true; Text = 'could not read the uninstall key after the run' }
        @{ Code = 3010; Expected = $true; Text = 'could not read the uninstall key after the run' }
        @{ Code = 1605; Expected = $false; Text = 'could not read the uninstall key after the run' }
    ) {
        $scriptBlockMap = $script:hashtableBlock['scriptBlockMapExitCode']
        $objMap = & $scriptBlockMap 'Uninstall' $Code $false $false
        $objMap.Succeeded | Should -Be $Expected
        $objMap.Text | Should -Match $Text
        $objMap.Text | Should -Not -Match 'still there'
    }

    It 'adds the key still there note to an uninstall that ends with 0 and leaves the key, and not to a repair' {
        $scriptBlockMap = $script:hashtableBlock['scriptBlockMapExitCode']
        (& $scriptBlockMap 'Uninstall' 0 $false $true).Text | Should -Match 'key is still there'
        (& $scriptBlockMap 'Uninstall' 0 $true $true).Text | Should -Not -Match 'still there'
        (& $scriptBlockMap 'Repair' 0 $false $true).Text | Should -Not -Match 'still there'
    }

    # These tests run an installer stand-in (cmd.exe and reg.exe). They run in GitHub CI
    # only. The lab does only dry runs of an uninstall or a repair.
    It 'runs the quiet uninstall string, waits, and reports that the key is gone' -Skip:($env:GITHUB_ACTIONS -ne 'true') {
        $strKey = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        $strRegistry = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0}' -f $strKey
        New-TestUninstallKey -View '64-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test remove'; QuietUninstallString = ('"{0}\reg.exe" delete "{1}" /f' -f $script:strSystem, $strRegistry) }
        $objRaw = Invoke-TestApplicationBlock -DryRun $false -Operation 'Uninstall' -View '64-bit' -KeyName $strKey -RealRun
        $objRaw.Succeeded | Should -BeTrue
        ($objRaw.Steps -join "`n") | Should -Match 'exit code 0'
        ($objRaw.Steps -join "`n") | Should -Match ('the key {0} is gone' -f [regex]::Escape($strKey))
        Test-Path -LiteralPath ('{0}\{1}' -f $script:strUninstallPath, $strKey) | Should -BeFalse
    }

    It 'reports the exit code <Code> of a real run: success <Expected>' -Skip:($env:GITHUB_ACTIONS -ne 'true') -ForEach @(
        @{ Code = 3010; Expected = $true; Text = 'restart of the device is needed' }
        @{ Code = 1641; Expected = $true; Text = 'restart of the device is needed' }
        @{ Code = 1618; Expected = $false; Text = 'another installation is in progress' }
        @{ Code = 1605; Expected = $false; Text = 'key is still there' }
        @{ Code = 7; Expected = $false; Text = 'exit code 7' }
    ) {
        $strKey = 'DiTest-{0}' -f [guid]::NewGuid().ToString('N')
        New-TestUninstallKey -View '64-bit' -KeyName $strKey -Value @{ DisplayName = 'DI test exit'; QuietUninstallString = ('"{0}\cmd.exe" /c exit {1}' -f $script:strSystem, $Code) }
        $objRaw = Invoke-TestApplicationBlock -DryRun $false -Operation 'Uninstall' -View '64-bit' -KeyName $strKey -RealRun
        $objRaw.Succeeded | Should -Be $Expected
        $objRaw.Summary | Should -Match $Text
    }

    It 'turns the rows of an MSI entry, an EXE entry with a quiet string, an EXE entry without one and a system component to the rules' -ForEach @(
        @{ Case = 'MSI'; Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = 'MsiExec.exe /I{23170F69-40C1-2702-2600-000001000000}'; Quiet = ''; Component = 0; Type = 'MSI'; CanUninstall = $true; CanRepair = $true; UninstallReason = ''; RepairReason = '' }
        @{ Case = 'EXE with a quiet uninstall string'; Key = 'App_is1'; Uninstall = '"C:\App\unins000.exe"'; Quiet = '"C:\App\unins000.exe" /VERYSILENT'; Component = 0; Type = 'EXE'; CanUninstall = $true; CanRepair = $false; UninstallReason = ''; RepairReason = 'no documented repair command' }
        @{ Case = 'EXE without a quiet uninstall string'; Key = 'App_is1'; Uninstall = '"C:\App\unins000.exe"'; Quiet = ''; Component = 0; Type = 'EXE'; CanUninstall = $false; CanRepair = $false; UninstallReason = 'does not guess silent switches'; RepairReason = 'does not guess silent switches' }
        @{ Case = 'EXE with a quiet string that has no .exe path'; Key = 'App_is1'; Uninstall = '"C:\App\unins000.exe"'; Quiet = 'cmd /c del x'; Component = 0; Type = 'EXE'; CanUninstall = $false; CanRepair = $false; UninstallReason = 'no file path that ends in .exe'; RepairReason = 'no file path that ends in .exe' }
        @{ Case = 'EXE with a relative quiet path'; Key = 'App_is1'; Uninstall = '"C:\App\unins000.exe"'; Quiet = '.\unins000.exe /S'; Component = 0; Type = 'EXE'; CanUninstall = $false; CanRepair = $false; UninstallReason = 'path is relative'; RepairReason = 'path is relative' }
        @{ Case = 'EXE with a bare file name'; Key = 'App_is1'; Uninstall = 'x'; Quiet = 'cmd.exe /c exit 0'; Component = 0; Type = 'EXE'; CanUninstall = $true; CanRepair = $false; UninstallReason = ''; RepairReason = 'no documented repair command' }
        @{ Case = 'system component, MSI'; Key = '{23170F69-40C1-2702-2600-000001000000}'; Uninstall = 'MsiExec.exe /I{23170F69-40C1-2702-2600-000001000000}'; Quiet = ''; Component = 1; Type = 'MSI'; CanUninstall = $false; CanRepair = $false; UninstallReason = 'system component, part of another product'; RepairReason = 'system component, part of another product' }
        @{ Case = 'system component, EXE with a quiet string'; Key = 'Hidden'; Uninstall = 'C:\x.exe'; Quiet = 'C:\x.exe /S'; Component = 1; Type = 'EXE'; CanUninstall = $false; CanRepair = $false; UninstallReason = 'system component, part of another product'; RepairReason = 'system component, part of another product' }
    ) {
        $objInspection = [pscustomobject]@{
            Site   = $null
            Device = [pscustomobject]@{ InstalledApplications = @([pscustomobject]@{ Name = 'App'; Version = '1.0'; Publisher = 'P'; InstallDate = '20260101'; KeyName = $Key; View = '64-bit'; UninstallString = $Uninstall; QuietUninstallString = $Quiet; SystemComponent = $Component; WindowsInstaller = 0 }) }
        }
        $arrRow = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection)
        $arrRow.Count | Should -Be 1
        $arrRow[0].Type | Should -Be $Type
        $arrRow[0].CanUninstall | Should -Be $CanUninstall
        $arrRow[0].CanRepair | Should -Be $CanRepair
        if ($UninstallReason) { $arrRow[0].UninstallReason | Should -Match $UninstallReason } else { $arrRow[0].UninstallReason | Should -BeNullOrEmpty }
        if ($RepairReason) { $arrRow[0].RepairReason | Should -Match $RepairReason } else { $arrRow[0].RepairReason | Should -BeNullOrEmpty }
        if (-not $CanUninstall -or -not $CanRepair) { $arrRow[0].Reason | Should -Not -BeNullOrEmpty } else { $arrRow[0].Reason | Should -BeNullOrEmpty }
    }

    It 'shows the exact command for display: msiexec for an MSI entry, the quiet string as written for an EXE entry' {
        $strGuid = '{23170F69-40C1-2702-2600-000001000000}'
        $objInspection = [pscustomobject]@{
            Site   = $null
            Device = [pscustomobject]@{ InstalledApplications = @(
                    [pscustomobject]@{ Name = 'M'; Version = '1'; Publisher = ''; InstallDate = ''; KeyName = $strGuid; View = '64-bit'; UninstallString = ('MsiExec.exe /I{0}' -f $strGuid); QuietUninstallString = ''; SystemComponent = 0; WindowsInstaller = 1 }
                    [pscustomobject]@{ Name = 'E'; Version = '1'; Publisher = ''; InstallDate = ''; KeyName = 'E_is1'; View = '32-bit'; UninstallString = '"C:\E\u.exe"'; QuietUninstallString = '  "C:\E\u.exe" /VERYSILENT /NORESTART  '; SystemComponent = 0; WindowsInstaller = 0 }
                ) }
        }
        $arrRow = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection)
        $arrRow[0].UninstallCommand | Should -Be ('msiexec.exe /x {0} /qn /norestart REBOOT=ReallySuppress' -f $strGuid)
        $arrRow[0].RepairCommand | Should -Be ('msiexec.exe /i {0} REINSTALL=ALL REINSTALLMODE=omus /qn /norestart REBOOT=ReallySuppress' -f $strGuid)
        $arrRow[1].UninstallCommand | Should -Be '"C:\E\u.exe" /VERYSILENT /NORESTART'
        $arrRow[1].RepairCommand | Should -BeNullOrEmpty
    }

    It 'makes no row from the client application policy, and keeps two entries that share a name and a version' {
        $objInspection = [pscustomobject]@{
            Site   = $null
            Device = [pscustomobject]@{
                InstalledApplications = @(
                    [pscustomobject]@{ Name = 'Same'; Version = '1.0'; Publisher = ''; InstallDate = ''; KeyName = '{11111111-1111-1111-1111-111111111111}'; View = '64-bit'; UninstallString = 'MsiExec.exe /X{11111111-1111-1111-1111-111111111111}'; QuietUninstallString = ''; SystemComponent = 0; WindowsInstaller = 1 }
                    [pscustomobject]@{ Name = 'Same'; Version = '1.0'; Publisher = ''; InstallDate = ''; KeyName = '{11111111-1111-1111-1111-111111111111}'; View = '32-bit'; UninstallString = 'MsiExec.exe /X{11111111-1111-1111-1111-111111111111}'; QuietUninstallString = ''; SystemComponent = 0; WindowsInstaller = 1 }
                )
                ClientApplications    = @([pscustomobject]@{ Name = 'CM App'; Id = 'S/A1'; Revision = '1'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Uninstall', 'Repair'); SoftwareVersion = '1'; Publisher = '' })
            }
        }
        $arrRow = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection)
        $arrRow.Count | Should -Be 2
        @($arrRow | Where-Object Name -eq 'CM App').Count | Should -Be 0
        @($arrRow.View | Sort-Object) | Should -Be @('32-bit', '64-bit')
    }

    It 'turns both actions off for an entry that has no usable view or key name' {
        $objInspection = [pscustomobject]@{ Site = $null; Device = [pscustomobject]@{ InstalledApplications = @([pscustomobject]@{ Name = 'Old shape'; Version = '1'; Publisher = '' }) } }
        $arrRow = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection)
        $arrRow[0].CanUninstall | Should -BeFalse
        $arrRow[0].CanRepair | Should -BeFalse
        $arrRow[0].Reason | Should -Match 'did not report a usable registry view'
    }

    It 'returns no row when the device was not read' {
        @(ConvertTo-DeviceInspectionApplicationRow -Inspection ([pscustomobject]@{ Site = $null; Device = $null })).Count | Should -Be 0
    }

    It 'puts the application line into a result that has no steps' {
        $script:strStart | Should -Match 'if \(@\(\$r\.Steps\)\.Count -eq 0 -and @\(\$script:ActionPending\.Detail\)\.Count -gt 0\) \{ \$r\.Steps = \[string\[\]\]@\(\$script:ActionPending\.Detail\) \}'
    }

    It 'names the application in the STARTED line, sends the view and the key name and no command line, and turns the row off after an uninstall' {
        $script:strStart | Should -Match "-Detail @\(\('Application: \{0\}, \{1\}, \{2\} view, key \{3\}\.' -f \`$label, "
        $script:strStart | Should -Match "-Outcome 'STARTED' -ActionId \`$actionId -Summary 'The run started\.' -Steps \`$Detail"
        $script:strStart | Should -Match '-Parameters @\{ Operation = \$Operation; View = \[string\]\$row\.View; KeyName = \[string\]\$row\.KeyName \}'
        $script:strStart | Should -Not -Match 'ApplicationId'
        $script:strStart | Should -Match "(?s)\`$r\.Action -like 'Uninstall\*'.*?\`$ctx\.Row\.CanUninstall = \`$false; \`$ctx\.Row\.CanRepair = \`$false.*?Update-AppFilter"
        $script:strStart | Should -Match "(?s)function Select-RowUnderPointer \{.*?if \(-not \`$node\) \{\s*\`$Grid\.SelectedItems\.Clear\(\)"
    }

    It 'shows the exact command in the confirmation text and builds it from the row for display only' {
        $script:strStart | Should -Match "(?s)function Invoke-ApplicationOperation \{.*?\`$commandName = \('\{0\}Command' -f \`$Operation\).*?runs this command and waits up to 10 minutes.*?\`$command"
    }

    It 'uses the reason of the row as the tooltip of a turned-off menu entry' {
        $script:strStart | Should -Match "(?s)\`$gridApps\.ContextMenu\.Add_Opened\(\{\s*\`$gate = Get-ActionGateText.*?Why = 'UninstallReason'.*?Why = 'RepairReason'.*?\`$why = \[string\]\`$row\.\(\`$pair\.Why\).*?Set-MenuItemState -Item \`$pair\.Item -Enabled \`$false -Reason \`$why"
    }

    It 'has Uninstall and Repair entries that open the action through the gate' {
        $script:strXaml | Should -Match 'x:Name="menuUninstallApp"[^>]*ToolTipService.ShowOnDisabled="True"'
        $script:strXaml | Should -Match 'x:Name="menuRepairApp"'
        $script:strStart | Should -Match "(?s)\`$gridApps\.ContextMenu\.Add_Opened\(\{\s*\`$gate = Get-ActionGateText"
        $script:strStart | Should -Match "(?s)function Invoke-ApplicationOperation \{.*?Invoke-DeviceAction -Name \('\{0\} application' -f \`$Operation\) -Function 'Invoke-DeviceInspectorApplicationAction'"
    }

    It 'offers the filter values All, MSI and EXE, and shows no status and no inventory version' {
        $script:strXaml | Should -Match '(?s)x:Name="cboAppType".*?<ComboBoxItem Content="All" IsSelected="True"/>\s*<ComboBoxItem Content="MSI"/>\s*<ComboBoxItem Content="EXE"/>\s*</ComboBox>'
        foreach ($strGone in 'Match', 'Version differs', 'Device only', 'Inventory only', 'Client application') {
            $script:strXaml | Should -Not -Match ('<ComboBoxItem Content="{0}"' -f $strGone) -Because $strGone
        }
        $script:strXaml | Should -Not -Match 'Inventory version'
        $script:strXaml | Should -Not -Match 'Binding="\{Binding (Status|InventoryVersion|DeviceVersion)\}"'
        $script:strXaml | Should -Match 'Binding="\{Binding Type\}"'
        $script:strStart | Should -Match "\`$type -ne 'All'.*?\`$_\.Type -eq \`$type"
    }
}

Describe 'Remove from collection' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
    }

    BeforeEach {
        InModuleScope DeviceInspectorCommon {
            Mock Connect-InspectorSite { [pscustomobject]@{ SiteCode = 'XYZ'; SiteServer = 'sms01'; PreviousLocation = 'C:\'; CreatedDrive = $false } }
            Mock Disconnect-InspectorSite { }
            Mock Get-CMDevice { [pscustomobject]@{ ResourceID = 16777221; Name = 'WS01' } }
            Mock Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'XYZ0001F'; Name = 'Pilot'; LimitToCollectionID = '' } }
            Mock Get-CMDeviceCollectionDirectMembershipRule { [pscustomobject]@{ ResourceID = 16777221; RuleName = 'WS01' } }
            Mock Remove-CMDeviceCollectionDirectMembershipRule { }
            Mock Add-CMDeviceCollectionDirectMembershipRule { }
            Mock Invoke-CMCollectionUpdate { }
            Mock Invoke-CMClientAction { }
            Mock Get-CMCollectionMember { }
            Mock Start-Sleep { }
        }
    }

    It 'changes nothing in a dry run and disconnects' {
        $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01.example.com' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove -DryRun
        $objResult.Succeeded | Should -BeTrue
        $objResult.Action | Should -Be 'Remove from collection'
        ($objResult.Steps -join "`n") | Should -Match 'Dry run: would remove the direct rule of resource 16777221 from XYZ0001F'
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-CMDeviceCollectionDirectMembershipRule -Times 0 -Exactly
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-CMCollectionUpdate -Times 0 -Exactly
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-CMClientAction -Times 0 -Exactly
        Should -Invoke -ModuleName DeviceInspectorCommon Disconnect-InspectorSite -Times 1 -Exactly
        Should -Invoke -ModuleName DeviceInspectorCommon Get-CMDevice -Times 1 -Exactly -ParameterFilter { $Name -eq 'WS01' }
    }

    It 'removes the direct rule, updates the collection and requests machine policy' {
        $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove
        $objResult.Succeeded | Should -BeTrue
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-CMDeviceCollectionDirectMembershipRule -Times 1 -Exactly -ParameterFilter { $CollectionId -eq 'XYZ0001F' -and $ResourceId -eq '16777221' -and $Force }
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-CMCollectionUpdate -Times 1 -Exactly -ParameterFilter { $CollectionId -eq 'XYZ0001F' }
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-CMClientAction -Times 1 -Exactly -ParameterFilter { $DeviceName -eq 'WS01' -and $ActionType -eq 'ClientNotificationRequestMachinePolicyNow' }
    }

    It 'refuses a removal when the device has no direct rule' {
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollectionDirectMembershipRule { }
        $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove
        $objResult.Succeeded | Should -BeFalse
        $objResult.Summary | Should -Match 'member through a query, include or other rule'
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-CMDeviceCollectionDirectMembershipRule -Times 0 -Exactly
    }

    It 'refuses a built-in collection without a site connection' {
        $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'SMS00001' -Operation Remove
        $objResult.Succeeded | Should -BeFalse
        $objResult.Summary | Should -Match 'built-in collection'
        Should -Invoke -ModuleName DeviceInspectorCommon Connect-InspectorSite -Times 0 -Exactly
    }

    It 'refuses when the site has no device record or two records with the name' {
        Mock -ModuleName DeviceInspectorCommon Get-CMDevice { }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Summary | Should -Match 'has 0 device records'
        Mock -ModuleName DeviceInspectorCommon Get-CMDevice { [pscustomobject]@{ ResourceID = 1 }; [pscustomobject]@{ ResourceID = 2 } }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Summary | Should -Match 'has 2 device records'
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-CMDeviceCollectionDirectMembershipRule -Times 0 -Exactly
    }

    It 'reports a refused change and a failed connection, and always disconnects' {
        Mock -ModuleName DeviceInspectorCommon Remove-CMDeviceCollectionDirectMembershipRule { throw 'Access denied' }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Summary | Should -Match 'did not change the rule'
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-CMCollectionUpdate -Times 0 -Exactly
        Mock -ModuleName DeviceInspectorCommon Connect-InspectorSite { throw 'Cannot open site' }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Summary | Should -Match 'Cannot run the action on site XYZ'
    }

    It 'keeps the change when the membership update or the notification fails, and says so' {
        Mock -ModuleName DeviceInspectorCommon Invoke-CMCollectionUpdate { throw 'busy' }
        Mock -ModuleName DeviceInspectorCommon Invoke-CMClientAction { throw 'offline' }
        $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove
        $objResult.Succeeded | Should -BeTrue
        ($objResult.Steps -join "`n") | Should -Match 'membership update did not start'
        ($objResult.Steps -join "`n") | Should -Match 'client notification failed'
    }

    It 'refuses a collection ID with a quote' {
        { Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId "XYZ'0001" -Operation Remove } | Should -Throw
    }

    It 'calls the site write cmdlets only in the collection change function' {
        $objAst = [System.Management.Automation.Language.Parser]::ParseFile($script:strActionsFile, [ref]$null, [ref]$null)
        $arrWrite = @('Add-CMDeviceCollectionDirectMembershipRule', 'Remove-CMDeviceCollectionDirectMembershipRule', 'Invoke-CMCollectionUpdate', 'Invoke-CMClientAction')
        foreach ($objFunction in @($objAst.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            if ($objFunction.Name -eq 'Invoke-DeviceInspectorCollectionChange') {
                continue
            }
            $arrCommand = @($objFunction.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
            @($arrCommand | Where-Object { $arrWrite -contains $_ }) | Should -BeNullOrEmpty -Because $objFunction.Name
        }
    }

    It 'adds a direct rule, and refuses an add when a direct rule exists' {
        $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Add
        $objResult.Succeeded | Should -BeFalse
        $objResult.Summary | Should -Match 'already has a direct rule'
        Should -Invoke -ModuleName DeviceInspectorCommon Add-CMDeviceCollectionDirectMembershipRule -Times 0 -Exactly
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollectionDirectMembershipRule { }
        Mock -ModuleName DeviceInspectorCommon Get-CMCollectionMember { [pscustomobject]@{ ResourceID = 16777221; IsDirect = $true } }
        $objAdded = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Add
        $objAdded.Succeeded | Should -BeTrue
        $objAdded.Action | Should -Be 'Add to collection'
        Should -Invoke -ModuleName DeviceInspectorCommon Add-CMDeviceCollectionDirectMembershipRule -Times 1 -Exactly -ParameterFilter { $CollectionId -eq 'XYZ0001F' -and $ResourceId -eq '16777221' }
        ($objAdded.Steps -join "`n") | Should -Match 'The site shows the new membership after'
    }

    It 'waits up to 60 seconds for the new membership and says when it does not show' {
        Mock -ModuleName DeviceInspectorCommon Get-CMCollectionMember { [pscustomobject]@{ ResourceID = 16777221; IsDirect = $true } }
        InModuleScope DeviceInspectorCommon {
            $script:intSleep = 0
            Mock Start-Sleep { $script:intSleep++ }
        }
        $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove
        $objResult.Succeeded | Should -BeTrue
        ($objResult.Steps -join "`n") | Should -Match 'did not show the new membership within 60 seconds'
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-CMClientAction -Times 1 -Exactly
        Should -Invoke -ModuleName DeviceInspectorCommon Get-CMCollectionMember -Times 12 -Exactly
        Mock -ModuleName DeviceInspectorCommon Get-CMCollectionMember { throw 'query failed' }
        ((Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Steps -join "`n") | Should -Match 'The last read failed\. The action log has the reason\.'
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Detail | Should -Contain 'Membership read: query failed'
    }

    It 'refuses a missing collection, a failed rule read and a new resource ID, and disconnects each time' {
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollection { }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Summary | Should -Match 'no device collection XYZ0001F'
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'XYZ0001F'; Name = 'Pilot' } }
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollectionDirectMembershipRule { throw 'provider error' }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Summary | Should -Be 'Cannot run the action on site XYZ. The action log has the reason.'
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove -ExpectedResourceId 16777999).Summary | Should -Match 'has resource ID 16777221, not 16777999'
        Should -Invoke -ModuleName DeviceInspectorCommon Disconnect-InspectorSite -Times 3 -Exactly
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-CMDeviceCollectionDirectMembershipRule -Times 0 -Exactly
    }

    It 'gives the reason why an action cannot start, for <Case>' -ForEach @(
        @{ Case = 'switch off'; Enabled = $false; Busy = $false; Kind = 'Site'; Inspection = $null; Expected = 'Turn on Enable Actions first.' }
        @{ Case = 'busy'; Enabled = $true; Busy = $true; Kind = 'Site'; Inspection = $null; Expected = 'Wait for the running task to end.' }
        @{ Case = 'no inspection'; Enabled = $true; Busy = $false; Kind = 'Site'; Inspection = $null; Expected = 'Inspect a device that the site knows first.' }
        @{ Case = 'site not found'; Enabled = $true; Busy = $false; Kind = 'Site'; Inspection = [pscustomobject]@{ SiteServer = 's'; Site = [pscustomobject]@{ Found = $false }; Device = $null }; Expected = 'Inspect a device that the site knows first.' }
        @{ Case = 'no site server'; Enabled = $true; Busy = $false; Kind = 'Site'; Inspection = [pscustomobject]@{ SiteServer = $null; Site = $null; Device = [pscustomobject]@{} }; Expected = 'Inspect a device that the site knows first.' }
        @{ Case = 'site action ready on a site-only inspection'; Enabled = $true; Busy = $false; Kind = 'Site'; Inspection = [pscustomobject]@{ SiteServer = 's'; Site = [pscustomobject]@{ Found = $true }; Device = $null }; Expected = '' }
        @{ Case = 'device action on a site-only inspection'; Enabled = $true; Busy = $false; Kind = 'Device'; Inspection = [pscustomobject]@{ SiteServer = 's'; Site = [pscustomobject]@{ Found = $true }; Device = $null }; Expected = 'Inspect a device that answers first.' }
        @{ Case = 'device action ready'; Enabled = $true; Busy = $false; Kind = 'Device'; Inspection = [pscustomobject]@{ SiteServer = $null; Site = $null; Device = [pscustomobject]@{} }; Expected = '' }
    ) {
        Get-DeviceInspectorActionBlock -Inspection $Inspection -ActionsEnabled $Enabled -Busy $Busy -Kind $Kind | Should -Be $Expected
    }

    It 'shows Unknown for a membership without a value, and gives a removed row its own reason' {
        $arrRow = @(ConvertTo-DeviceInspectionCollectionRow -Inspection ([pscustomobject]@{ Site = [pscustomobject]@{ Collections = @([pscustomobject]@{ CollectionId = 'XYZ00020'; Name = 'X'; IsDirect = $null }) } }))
        $arrRow[0].Membership | Should -Be 'Unknown'
        $arrRow[0].IsRemoved | Should -BeFalse
        $script:strStart | Should -Match 'The direct rule was removed\. Inspect the device again\.'
        $script:strStart | Should -Match 'ExpectedResourceId = \[int\]\$script:Inspection\.Site\.ResourceId'
    }

    It 'marks direct and built-in memberships in the collection rows' {
        $objInspection = [pscustomobject]@{ Site = [pscustomobject]@{ Collections = @(
                    [pscustomobject]@{ CollectionId = 'SMS00001'; Name = 'All Systems'; IsDirect = $false }
                    [pscustomobject]@{ CollectionId = 'XYZ0001F'; Name = 'Pilot'; IsDirect = $true }
                ) } }
        $arrRow = @(ConvertTo-DeviceInspectionCollectionRow -Inspection $objInspection)
        $arrRow[0].IsBuiltIn | Should -BeTrue
        $arrRow[0].Membership | Should -Be 'Query or other rule'
        $arrRow[1].IsDirect | Should -BeTrue
        $arrRow[1].Membership | Should -Be 'Direct rule'
    }

    It 'has a Remove entry with reasons, through the site gate' {
        $script:strXaml | Should -Match 'x:Name="menuRemoveCollection"[^>]*ToolTipService.ShowOnDisabled="True"'
        $script:strXaml | Should -Match 'Header="Membership"'
        $script:strStart | Should -Match "Only a direct rule can be removed here"
        $script:strStart | Should -Match "(?s)\`$menuRemoveCollection\.Add_Click\(\{.*?Invoke-DeviceAction -SiteAction -Name 'Remove from collection' -Function 'Invoke-DeviceInspectorCollectionChange'"
        $script:strStart | Should -Match 'function Test-SiteActionReady \{[^}]*Get-DeviceInspectorActionBlock[^}]*-Kind Site'
        $script:strStart | Should -Match 'function Test-DeviceActionReady \{[^}]*Get-DeviceInspectorActionBlock[^}]*-Kind Device'
    }
}

Describe 'Add to collection' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
    }

    BeforeEach {
        InModuleScope DeviceInspectorCommon {
            Mock Connect-InspectorSite { [pscustomobject]@{ SiteCode = 'XYZ'; SiteServer = 'sms01'; PreviousLocation = 'C:\'; CreatedDrive = $false } }
            Mock Disconnect-InspectorSite { }
            Mock Get-CMDevice { [pscustomobject]@{ ResourceID = 16777221; Name = 'WS01' } }
            Mock Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'XYZ00030'; Name = 'Pilot 2'; MemberCount = 3; LimitToCollectionID = 'SMS00001' } }
            Mock Get-CMDeviceCollectionDirectMembershipRule { }
            Mock Add-CMDeviceCollectionDirectMembershipRule { }
            Mock Invoke-CMCollectionUpdate { }
            Mock Invoke-CMClientAction { }
            Mock Get-CMCollectionMember { [pscustomobject]@{ ResourceID = 16777221; IsDirect = $true } }
            Mock Start-Sleep { }
        }
    }

    It 'checks the limiting collection, and adds the rule when the device is a member of it' {
        $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ00030' -Operation Add
        $objResult.Succeeded | Should -BeTrue
        ($objResult.Steps -join "`n") | Should -Match 'member of the limiting collection SMS00001'
        Should -Invoke -ModuleName DeviceInspectorCommon Get-CMCollectionMember -ParameterFilter { $CollectionId -eq 'SMS00001' -and $ResourceId -eq 16777221 }
        Should -Invoke -ModuleName DeviceInspectorCommon Add-CMDeviceCollectionDirectMembershipRule -Times 1 -Exactly
    }

    It 'refuses the add when the device is not a member of the limiting collection, also in a dry run' {
        Mock -ModuleName DeviceInspectorCommon Get-CMCollectionMember { }
        $objDry = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ00030' -Operation Add -DryRun
        $objDry.Succeeded | Should -BeFalse
        $objDry.Summary | Should -Match 'not a member of the limiting collection SMS00001'
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ00030' -Operation Add).Succeeded | Should -BeFalse
        Should -Invoke -ModuleName DeviceInspectorCommon Add-CMDeviceCollectionDirectMembershipRule -Times 0 -Exactly
    }

    It 'refuses when the limiting collection cannot be read, skips the check for an empty limit, and reports a member read error' {
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'XYZ00030'; Name = 'Pilot 2'; MemberCount = 3 } }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ00030' -Operation Add -DryRun).Summary | Should -Match 'limiting collection of XYZ00030 cannot be read'
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'XYZ00030'; Name = 'Pilot 2'; MemberCount = 3; LimitToCollectionID = '' } }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ00030' -Operation Add -DryRun).Succeeded | Should -BeTrue
        Should -Invoke -ModuleName DeviceInspectorCommon Get-CMCollectionMember -Times 0 -Exactly
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'XYZ00030'; Name = 'Pilot 2'; MemberCount = 3; LimitToCollectionID = 'SMS00001' } }
        Mock -ModuleName DeviceInspectorCommon Get-CMCollectionMember { throw 'access denied' }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ00030' -Operation Add -DryRun).Summary | Should -Be 'Cannot run the action on site XYZ. The action log has the reason.'
        Should -Invoke -ModuleName DeviceInspectorCommon Add-CMDeviceCollectionDirectMembershipRule -Times 0 -Exactly
    }

    It 'offers neither built-in collections nor collections with a direct rule that is not removed' {
        $arrList = @(
            [pscustomobject]@{ CollectionID = 'SMS00001'; Name = 'All Systems'; IsBuiltIn = $true }
            [pscustomobject]@{ CollectionID = 'XYZ00010'; Name = 'Direct'; IsBuiltIn = $false }
            [pscustomobject]@{ CollectionID = 'XYZ00011'; Name = 'Removed'; IsBuiltIn = $false }
            [pscustomobject]@{ CollectionID = 'XYZ00012'; Name = 'Unknown'; IsBuiltIn = $false }
            [pscustomobject]@{ CollectionID = 'XYZ00013'; Name = 'Query'; IsBuiltIn = $false }
            [pscustomobject]@{ CollectionID = 'XYZ00014'; Name = 'Not a member'; IsBuiltIn = $false }
        )
        $arrRow = @(
            [pscustomobject]@{ CollectionId = 'XYZ00010'; IsDirect = $true; IsRemoved = $false }
            [pscustomobject]@{ CollectionId = 'XYZ00011'; IsDirect = $true; IsRemoved = $true }
            [pscustomobject]@{ CollectionId = 'XYZ00012'; IsDirect = $null; IsRemoved = $false }
            [pscustomobject]@{ CollectionId = 'XYZ00013'; IsDirect = $false; IsRemoved = $false }
        )
        @(Select-DeviceInspectorAddableCollection -Collections $arrList -Rows $arrRow | ForEach-Object { $_.CollectionID }) | Should -Be @('XYZ00011', 'XYZ00012', 'XYZ00013', 'XYZ00014')
        @(Select-DeviceInspectorAddableCollection -Collections $arrList -Rows @()).Count | Should -Be 5
    }

    It 'lists the device collections for the browser and closes the site drive' {
        $arrList = @(Get-DeviceInspectorCollectionList -SiteServer 'sms01' -SiteCode 'XYZ')
        $arrList.Count | Should -Be 1
        $arrList[0].CollectionID | Should -Be 'XYZ00030'
        $arrList[0].IsBuiltIn | Should -BeFalse
        $arrList[0].FolderID | Should -Be 0
        $arrList[0].LimitToCollectionID | Should -Be 'SMS00001'
        Should -Invoke -ModuleName DeviceInspectorCommon Disconnect-InspectorSite -Times 1 -Exactly
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollection { throw 'provider error' }
        { Get-DeviceInspectorCollectionList -SiteServer 'sms01' -SiteCode 'XYZ' } | Should -Throw '*provider error*'
        Should -Invoke -ModuleName DeviceInspectorCommon Disconnect-InspectorSite -Times 2 -Exactly
    }

    It 'marks built-in collections in the list' {
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'SMS00001'; Name = 'All Systems'; MemberCount = 5; LimitToCollectionID = '' } }
        @(Get-DeviceInspectorCollectionList -SiteServer 'sms01' -SiteCode 'XYZ')[0].IsBuiltIn | Should -BeTrue
    }

    It 'has a button and a menu entry that open the browser through the site gate' {
        $script:strXaml | Should -Match 'x:Name="btnAddCollection"'
        $script:strXaml | Should -Match 'x:Name="menuAddCollection"[^>]*ToolTipService.ShowOnDisabled="True"'
        $script:strStart | Should -Match '\$btnAddCollection\.IsEnabled = Test-SiteActionReady'
        $script:strStart | Should -Match "(?s)function Invoke-AddToCollection \{\s*\`$gate = Get-ActionBlockText -Kind Site"
        $script:strStart | Should -Match "(?s)function Invoke-AddToCollection \{.*?Show-CollectionPickerDialog -Owner \`$window -Collections \`$choices.*?Invoke-DeviceAction -SiteAction -Name 'Add to collection' -Function 'Invoke-DeviceInspectorCollectionChange'"
        $script:strStart | Should -Match 'Select-DeviceInspectorAddableCollection -Collections @\(\$State\.Result\) -Rows @\(\$gridCollections\.ItemsSource\)'
        $script:strStart | Should -Match "(?s)function Invoke-AddToCollection \{.*?-OnDone \{\s*param\(\`$State\)\s*Update-StatusBarSummary"
    }
}

Describe 'Device list' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
    }

    BeforeEach {
        InModuleScope DeviceInspectorCommon {
            Mock Connect-InspectorSite { [pscustomobject]@{ SiteCode = 'XYZ'; SiteServer = 'sms01'; PreviousLocation = 'C:\'; CreatedDrive = $false } }
            Mock Disconnect-InspectorSite { }
            Mock Get-CMDevice {
                [pscustomobject]@{ Name = 'WS02'; ResourceID = 2; IsClient = $true; IsActive = $false; ClientVersion = '5.00'; DeviceOS = 'Windows'; LastLogonUser = 'b'; LastActiveTime = [datetime]'2026-11-10T08:00:00' }
                [pscustomobject]@{ Name = 'WS01'; ResourceID = 1; IsClient = $true; IsActive = $true; ClientVersion = '5.00'; DeviceOS = 'Windows'; LastLogonUser = 'a'; LastActiveTime = $null }
            }
            Mock Get-CMCollectionMember {
                [pscustomobject]@{ Name = 'WS03'; ResourceID = 3; ResourceType = 5; IsClient = $true; IsActive = $true; DeviceOS = 'Windows' }
                [pscustomobject]@{ Name = 'user1'; ResourceID = 9; ResourceType = 4 }
            }
        }
    }

    It 'lists devices by name pattern, sorted by name, and closes the site drive' {
        $objList = Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -NamePattern 'WS*'
        $objList.Total | Should -Be 2
        $objList.Truncated | Should -BeFalse
        @($objList.Devices | ForEach-Object { $_.Name }) | Should -Be @('WS01', 'WS02')
        $objList.Devices[1].LastActive | Should -Be '2026-11-10T08:00:00Z'
        $objList.Devices[0].LastActive | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DeviceInspectorCommon Get-CMDevice -Times 1 -Exactly -ParameterFilter { $Name -eq 'WS*' -and $Fast }
        Should -Invoke -ModuleName DeviceInspectorCommon Disconnect-InspectorSite -Times 1 -Exactly
    }

    It 'lists the system members of a collection, with the name pattern as a filter, and leaves out users' {
        $objList = Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'SMS00001' -NamePattern 'WS*'
        $objList.Total | Should -Be 1
        $objList.Devices[0].Name | Should -Be 'WS03'
        $objList.Devices[0].LastLogonUser | Should -Be ''
        Should -Invoke -ModuleName DeviceInspectorCommon Get-CMCollectionMember -Times 1 -Exactly -ParameterFilter { $CollectionId -eq 'SMS00001' -and $Name -eq 'WS*' }
        Should -Invoke -ModuleName DeviceInspectorCommon Get-CMDevice -Times 0 -Exactly
    }

    It 'returns at most Maximum devices and says that the list is cut' {
        $objList = Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -NamePattern 'WS*' -Maximum 1
        @($objList.Devices).Count | Should -Be 1
        $objList.Total | Should -Be 2
        $objList.Truncated | Should -BeTrue
    }

    It 'refuses an empty search and a pattern or a collection ID outside the rules' {
        { Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' } | Should -Throw '*name pattern, a collection ID, or both*'
        { Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -NamePattern "WS'; x" } | Should -Throw
        { Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'SMS0001' } | Should -Throw
        Should -Invoke -ModuleName DeviceInspectorCommon Connect-InspectorSite -Times 0 -Exactly
    }

    It 'refuses a pattern of wildcards only without a collection, and accepts it with a collection' {
        { Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -NamePattern '*' } | Should -Throw '*at least one letter or digit*'
        (Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -NamePattern '*' -CollectionId 'SMS00001').Total | Should -Be 1
    }

    It 'returns 500 rows by default and a numeric resource ID' {
        Mock -ModuleName DeviceInspectorCommon Get-CMDevice { 1..501 | ForEach-Object { [pscustomobject]@{ Name = ('WS{0:d4}' -f $_); ResourceID = $_; IsClient = $true; IsActive = $true } } }
        $objList = Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -NamePattern 'WS*'
        @($objList.Devices).Count | Should -Be 500
        $objList.Total | Should -Be 501
        $objList.Truncated | Should -BeTrue
        $objList.Devices[0].ResourceId | Should -BeOfType [long]
    }

    It 'ignores a search while work runs, and inspects only on a double-click on a row' {
        $script:strStart | Should -Match "(?s)function Invoke-DeviceListSearch \{\s*if \(\`$script:IsBusy\) \{ return \}"
        $script:strStart | Should -Match '\$txtListName\.IsEnabled = \$idle'
        $script:strStart | Should -Match '\$txtListCollection\.IsEnabled = \$idle'
        $script:strStart | Should -Match "(?s)\`$gridDeviceList\.Add_MouseDoubleClick\(\{.*?if \(\`$node -is \[System\.Windows\.Controls\.DataGridRow\]\) \{ Invoke-ListInspect \}"
    }

    It 'closes the site drive when the read fails' {
        Mock -ModuleName DeviceInspectorCommon Get-CMDevice { throw 'provider error' }
        { Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -NamePattern 'WS*' } | Should -Throw '*provider error*'
        Should -Invoke -ModuleName DeviceInspectorCommon Disconnect-InspectorSite -Times 1 -Exactly
    }

    It 'has a Device list panel that searches the site and inspects the selected device' {
        $script:strXaml | Should -Match 'x:Name="btnViewDeviceList"[^>]*Content="Device List"'
        $script:strXaml | Should -Match 'x:Name="viewDeviceList"'
        $script:strXaml | Should -Match 'x:Name="gridDeviceList"'
        $script:strStart | Should -Match "(?s)function Invoke-DeviceListSearch \{.*?Get-DeviceInspectorDeviceList -SiteServer \`$A\.Server -SiteCode \`$A\.Code -NamePattern \`$A\.Pattern -CollectionId \`$A\.Collection"
        $script:strStart | Should -Match "(?s)function Invoke-ListInspect \{.*?\`$txtDevice\.Text = \[string\]\`$row\.Name.*?Set-ActiveView -View 'Device'.*?Invoke-Inspect"
    }
}

Describe 'Background device actions' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
        $script:objStartAst = [System.Management.Automation.Language.Parser]::ParseFile($script:strStartPath, [ref]$null, [ref]$null)
        function Get-TestFunctionText {
            param([string]$Name)
            $objFound = $script:objStartAst.Find({ param($objNode) $objNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $objNode.Name -eq $Name }, $true)
            return $objFound.Extent.Text
        }
        function New-TestRun {
            param([string]$ComputerName, [string]$Action = 'Client policy update', [bool]$DryRun = $false)
            return (New-DeviceInspectorActionRun -ActionId (New-DeviceInspectorActionId) -Action $Action -ComputerName $ComputerName -DryRun $DryRun)
        }
        function New-TestList {
            # The comma keeps an empty collection from becoming nothing on the way out of the function.
            return , (New-Object -TypeName 'System.Collections.ObjectModel.ObservableCollection[object]')
        }
        $script:objDeviceInspection = [pscustomobject]@{ SiteServer = $null; Site = $null; Device = [pscustomobject]@{} }
    }

    Context 'Action ID' {
        It 'makes an ID of eight hexadecimal characters, and every ID is different' {
            $arrId = @(1..200 | ForEach-Object { New-DeviceInspectorActionId })
            $arrId | ForEach-Object { $_ | Should -Match '^[0-9a-f]{8}$' }
            @($arrId | Select-Object -Unique).Count | Should -Be 200
        }

        It 'writes the same ID on the STARTED line and on the result line, with the outcome and the exit code' {
            Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $false; Summary = 'The installer failed with exit code 1603.'; Steps = @('Command ran.') } }
            $strId = New-DeviceInspectorActionId
            $strPath = Join-Path -Path $TestDrive -ChildPath 'Logs\ids.log'
            $objStart = New-DeviceInspectorActionRecord -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false -Succeeded $false -Outcome 'STARTED' -ActionId $strId -Summary 'The run started.' -Steps @()
            $null = Write-DeviceInspectorActionLog -Path $strPath -Result $objStart
            $objResult = Add-DeviceInspectorActionId -Result (Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01') -ActionId $strId
            $null = Write-DeviceInspectorActionLog -Path $strPath -Result $objResult
            $arrHeader = @([System.IO.File]::ReadAllLines($strPath) | Where-Object { $_ -notmatch '^\s' })
            $arrHeader.Count | Should -Be 2
            $arrHeader[0] | Should -Match ('^\S+ \| {0} \| \S+ \| WS01 \| Client policy update \| RUN \| STARTED \| The run started\.$' -f $strId)
            $arrHeader[1] | Should -Match ('^\S+ \| {0} \| \S+ \| WS01 \| Client policy update \| RUN \| FAILED \| The installer failed with exit code 1603\.$' -f $strId)
        }

        It 'writes an ID on the result line of a dry run' {
            Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'Dry run: nothing changed.'; Steps = @() } }
            $strId = New-DeviceInspectorActionId
            $objResult = Add-DeviceInspectorActionId -Result (Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01' -DryRun) -ActionId $strId
            $objResult.ActionId | Should -Be $strId
            @(ConvertTo-DeviceInspectorActionText -Result $objResult)[0] | Should -Match ('\| {0} \| \S+ \| WS01 \| Client policy update \| DRY RUN \| OK \|' -f $strId)
        }

        It 'gives the record of an action function an empty ID until the window sets it' {
            Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @() } }
            (Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01').ActionId | Should -BeNullOrEmpty
        }

        It 'makes the window write an ID on the start line, on the result line and on the failure lines' {
            $script:strStart | Should -Match "(?s)function Invoke-DeviceAction \{.*?\`$actionId = New-DeviceInspectorActionId.*?-Outcome 'STARTED' -ActionId \`$actionId"
            $script:strStart | Should -Match '(?s)function Complete-DeviceActionRun \{.*?Resolve-DeviceInspectorRunResult -Run \$run'
        }
    }

    Context 'One running action for each device' {
        It 'adds a run to the list and removes it when the run ends' {
            $listRun = New-TestList
            $objRun = New-TestRun -ComputerName 'WS01'
            Register-DeviceInspectorActionRun -Runs $listRun -Run $objRun
            $listRun.Count | Should -Be 1
            $listRun[0].ActionId | Should -Be $objRun.ActionId
            (Unregister-DeviceInspectorActionRun -Runs $listRun -ActionId $objRun.ActionId).ActionId | Should -Be $objRun.ActionId
            $listRun.Count | Should -Be 0
            Unregister-DeviceInspectorActionRun -Runs $listRun -ActionId $objRun.ActionId | Should -BeNullOrEmpty
        }

        It 'refuses a second action on a device that has a running action, without regard to case' {
            $listRun = New-TestList
            $objFirst = New-TestRun -ComputerName 'WS01' -Action 'Full hardware inventory'
            Register-DeviceInspectorActionRun -Runs $listRun -Run $objFirst
            { Register-DeviceInspectorActionRun -Runs $listRun -Run (New-TestRun -ComputerName 'ws01') } | Should -Throw -ExpectedMessage ('Full hardware inventory (ID {0}) is running on WS01. A device runs one action at a time.' -f $objFirst.ActionId)
            $listRun.Count | Should -Be 1
        }

        It 'refuses a dry run on a device that has a running action, and allows a new run after the first one ends' {
            $listRun = New-TestList
            $objFirst = New-TestRun -ComputerName 'WS01'
            Register-DeviceInspectorActionRun -Runs $listRun -Run $objFirst
            { Register-DeviceInspectorActionRun -Runs $listRun -Run (New-TestRun -ComputerName 'WS01' -DryRun $true) } | Should -Throw
            $null = Unregister-DeviceInspectorActionRun -Runs $listRun -ActionId $objFirst.ActionId
            { Register-DeviceInspectorActionRun -Runs $listRun -Run (New-TestRun -ComputerName 'WS01') } | Should -Not -Throw
            $listRun.Count | Should -Be 1
        }

        It 'gives the reason, with the action, the ID and the start time, for a device action and for a site action on that device' -ForEach @(@{ Kind = 'Device' }, @{ Kind = 'Site' }) {
            $objInspection = [pscustomobject]@{ SiteServer = 's'; Site = [pscustomobject]@{ Found = $true }; Device = [pscustomobject]@{} }
            $objRun = New-TestRun -ComputerName 'WS01' -Action 'Uninstall application'
            $strReason = Get-DeviceInspectorActionBlock -Inspection $objInspection -ActionsEnabled $true -Busy $false -Kind $Kind -Run @($objRun) -ComputerName 'ws01'
            $strReason | Should -Be ('Uninstall application (ID {0}) is running on WS01 since {1}. A device runs one action at a time. Wait until it ends.' -f $objRun.ActionId, $objRun.StartedAt)
        }

        It 'does not block an action on another device, and does not block the window as busy' {
            $objInspection = [pscustomobject]@{ SiteServer = 's'; Site = [pscustomobject]@{ Found = $true }; Device = [pscustomobject]@{} }
            $arrRun = @((New-TestRun -ComputerName 'WS01'), (New-TestRun -ComputerName 'WS03'))
            foreach ($strKind in 'Device', 'Site') {
                Get-DeviceInspectorActionBlock -Inspection $objInspection -ActionsEnabled $true -Busy $false -Kind $strKind -Run $arrRun -ComputerName 'WS02' | Should -Be ''
            }
            Get-DeviceInspectorRunBlock -Run $arrRun -ComputerName 'WS02' | Should -Be ''
            Get-DeviceInspectorRunningAction -Run $arrRun -ComputerName 'WS02' | Should -BeNullOrEmpty
            Get-DeviceInspectorRunningAction -Run $arrRun -ComputerName 'ws03' | Should -Not -BeNullOrEmpty
        }

        It 'keeps the old results of the gate when no run is given' {
            Get-DeviceInspectorActionBlock -Inspection $script:objDeviceInspection -ActionsEnabled $true -Busy $false -Kind Device | Should -Be ''
            Get-DeviceInspectorActionBlock -Inspection $script:objDeviceInspection -ActionsEnabled $true -Busy $true -Kind Device | Should -Be 'Wait for the running task to end.'
        }

        It 'passes the running list and the device of the inspection to the gate in the window' {
            Get-TestFunctionText -Name 'Test-DeviceActionReady' | Should -Match '-Run @\(\$script:RunList\) -ComputerName \(Get-ActionTargetName\)'
            Get-TestFunctionText -Name 'Test-SiteActionReady' | Should -Match '-Run @\(\$script:RunList\) -ComputerName \(Get-ActionTargetName\)'
            Get-TestFunctionText -Name 'Get-ActionGateText' | Should -Match 'Get-ActionBlockText -Kind Device'
        }

        It 'registers the run before it writes the start line, and takes it off the list when the start fails' {
            $strText = Get-TestFunctionText -Name 'Invoke-DeviceAction'
            $strText.IndexOf('Register-DeviceInspectorActionRun') | Should -BeGreaterThan 0
            $strText.IndexOf('Register-DeviceInspectorActionRun') | Should -BeLessThan $strText.IndexOf("-Outcome 'STARTED'")
            $strText | Should -Match "(?s)catch \{\s*\`$logProblem.*?Unregister-DeviceInspectorActionRun.*?the run does not start"
            $strText | Should -Match "(?s)Start-DeviceActionRun -Run \`$run.*?catch \{.*?Unregister-DeviceInspectorActionRun.*?return\s*\}\s*# From here the work executes"
        }
    }

    Context 'The window stays free while a device action runs' {
        It 'does not set the busy state for a device action, and runs it in its own runspace' {
            foreach ($strName in 'Start-DeviceActionRun', 'Complete-DeviceActionRun', 'Update-DeviceActionRun', 'Get-ActionRunspace') {
                Get-TestFunctionText -Name $strName | Should -Not -Match 'IsBusy' -Because $strName
                Get-TestFunctionText -Name $strName | Should -Not -Match 'Start-BackgroundWork' -Because $strName
            }
            Get-TestFunctionText -Name 'Start-DeviceActionRun' | Should -Match '\$ps\.BeginInvoke\(\)'
            Get-TestFunctionText -Name 'Get-ActionRunspace' | Should -Match 'New-SuiteBgRunspace'
        }

        It 'keeps Inspect, the device list search and the list controls on while only a device action runs' {
            $strText = Get-TestFunctionText -Name 'Update-ControlState'
            $strText | Should -Match '\$idle = -not \$script:IsBusy'
            $strText | Should -Not -Match 'RunList.*btnInspect|btnInspect.*RunList'
            $strText | Should -Match '\$btnInspect\.IsEnabled\s+= \$idle'
            $strText | Should -Match '\$btnListSearch\.IsEnabled = \$idle'
            Get-TestFunctionText -Name 'Invoke-DeviceListSearch' | Should -Match 'if \(\$script:IsBusy\) \{ return \}'
        }

        It 'has no wait-for-the-running-task gate in the start script, so a run on one device does not block another' {
            $script:strStart | Should -Not -Match 'Wait for the running task to end'
        }

        It 'keeps the exclusive busy path for a site action and for the inspection' {
            Get-TestFunctionText -Name 'Invoke-DeviceAction' | Should -Match '(?s)Start-ActionWork -Title \$title'
            Get-TestFunctionText -Name 'Start-ActionWork' | Should -Match 'Start-BackgroundWork'
            Get-TestFunctionText -Name 'Invoke-Inspect' | Should -Match 'Start-BackgroundWork'
        }

        It 'polls the runs on a DispatcherTimer, so every change of the window runs on the Dispatcher thread' {
            Get-TestFunctionText -Name 'Start-DeviceActionRun' | Should -Match 'System\.Windows\.Threading\.DispatcherTimer'
            Get-TestFunctionText -Name 'Start-DeviceActionRun' | Should -Match 'Add_Tick\(\{ Update-DeviceActionRun \}\)'
            Get-TestFunctionText -Name 'Update-DeviceActionRun' | Should -Match 'Complete-DeviceActionRun -Job \$job'
        }

        It 'takes the run off the list, writes the result and refreshes the view only when it shows the device of the run' {
            $strText = Get-TestFunctionText -Name 'Complete-DeviceActionRun'
            $strText | Should -Match 'Unregister-DeviceInspectorActionRun -Runs \$script:RunList'
            $strText | Should -Match '\$onScreen = .*?Get-DeviceInspectorRunningAction -Run @\(\$run\) -ComputerName \(Get-ActionTargetName\) -ResourceId \(Get-ActionTargetResourceId\)'
            $strText.IndexOf('$onScreen') | Should -BeLessThan $strText.IndexOf('& $Job.AfterRun')
            $strText | Should -Match 'is not the device on screen'
        }

        It 'shows the result in a window that does not take the focus' {
            $strText = Get-TestFunctionText -Name 'Show-ActionResultNotice'
            $strText | Should -Match 'ShowActivated="False"'
            $strText | Should -Match '\$dlg\.Show\(\)'
            $strText | Should -Not -Match 'Show(Dialog)'
            Get-TestFunctionText -Name 'Complete-DeviceActionRun' | Should -Match 'Show-ActionResultNotice'
            Get-TestFunctionText -Name 'Complete-DeviceActionRun' | Should -Not -Match 'Show-ThemedMessage'
        }

        It 'shows the running actions in a list with the device, the action, the start time and the ID' {
            $script:strXaml | Should -Match '(?s)x:Name="panelRuns"[^>]*Visibility="Collapsed".*?x:Name="gridRuns"'
            foreach ($strBinding in 'ComputerName', 'Action', 'Mode', 'StartedAt', 'ActionId') {
                $script:strXaml | Should -Match ('(?s)x:Name="gridRuns".*?Binding="\{{Binding {0}\}}"' -f $strBinding)
            }
            $script:strStart | Should -Match '\$gridRuns\.ItemsSource = \$script:RunList'
            Get-TestFunctionText -Name 'Update-RunPanel' | Should -Match 'RunList\.Count'
            Get-TestFunctionText -Name 'Update-ControlState' | Should -Match 'Update-RunPanel'
        }

        It 'puts the running list above the views, and keeps the log splitter between the views and the log' {
            $script:strXaml | Should -Match '(?s)x:Name="panelRuns" Grid\.Row="2".*?<Grid Grid\.Row="3" Margin="8,0,8,0">.*?<GridSplitter Grid\.Row="4".*?<Border Grid\.Row="5">.*?<Border Grid\.Row="6"'
        }

        It 'gives a button that is off for a running device the reason as its tooltip' {
            Get-TestFunctionText -Name 'Update-ControlState' | Should -Match 'Get-DeviceInspectorRunBlock -Run @\(\$script:RunList\)'
            Get-TestFunctionText -Name 'Set-RunTooltip' | Should -Match 'SetShowOnDisabled'
        }

        It 'uses the reason of the gate as the tooltip of a menu entry that is off' {
            $script:strStart | Should -Match "(?s)\`$gridApps\.ContextMenu\.Add_Opened\(\{\s*\`$gate = Get-ActionGateText.*?Set-MenuItemState -Item \`$pair\.Item -Enabled \`$false -Reason \`$gate"
        }
    }

    Context 'Closing the window while a run is open' {
        It 'writes one CLOSED line with the ID for each run that is still open' {
            $strPath = Join-Path -Path $TestDrive -ChildPath 'Logs\close.log'
            $arrRun = @((New-TestRun -ComputerName 'WS01' -Action 'Application uninstall'), (New-TestRun -ComputerName 'WS02' -Action 'Full hardware inventory' -DryRun $true))
            (Write-DeviceInspectorCloseLog -Path $strPath -Run $arrRun) | Should -Be 2
            $arrHeader = @([System.IO.File]::ReadAllLines($strPath) | Where-Object { $_ -notmatch '^\s' })
            $arrHeader.Count | Should -Be 2
            $arrHeader[0] | Should -Match ('^\S+ \| {0} \| \S+ \| WS01 \| Application uninstall \| RUN \| CLOSED \| ' -f $arrRun[0].ActionId)
            $arrHeader[1] | Should -Match ('^\S+ \| {0} \| \S+ \| WS02 \| Full hardware inventory \| DRY RUN \| CLOSED \| ' -f $arrRun[1].ActionId)
            $arrHeader[0] | Should -Match 'The tool stopped waiting for it\. The run can stop before it is complete\. The result is not known\.$'
            $arrHeader[0] | Should -Not -Match 'continues'
        }

        It 'writes no line and no file when no run is open' {
            $strPath = Join-Path -Path $TestDrive -ChildPath 'Logs\none.log'
            (Write-DeviceInspectorCloseLog -Path $strPath -Run @()) | Should -Be 0
            Test-Path -LiteralPath $strPath | Should -BeFalse
        }

        It 'asks for a confirmation that names the runs, cancels the close on No, and writes the close lines on Yes' {
            $strClosing = [regex]::Match($script:strStart, '(?s)\$window\.Add_Closing\(\{.*?\r?\n\}\)').Value
            $strClosing | Should -Match 'if \(\$script:RunList\.Count -gt 0\)'
            $strClosing | Should -Match 'Show-CloseWarningDialog -Runs @\(\$script:RunList\)'
            $strClosing | Should -Match "if \(\`$answer -ne 'Close'\) \{ \`$e\.Cancel = \`$true; return \}"
            $strClosing | Should -Match 'Write-DeviceInspectorCloseLog -Path \$script:ActionLogPath -Run \$open'
            $strClosing.IndexOf('Write-DeviceInspectorCloseLog') | Should -BeLessThan $strClosing.IndexOf('Stop-DeviceActionRun')
            # One pass over the runs after the confirmation and before the snapshot of the open runs.
            $strClosing.IndexOf('Update-DeviceActionRun') | Should -BeGreaterThan $strClosing.IndexOf('Show-CloseWarningDialog')
            $strClosing.IndexOf('Update-DeviceActionRun') | Should -BeLessThan $strClosing.IndexOf('$open = ')
        }

        It 'writes the warning text in the singular for one run and in the plural for more runs' {
            $strNl = "`n"
            $strOne = Get-DeviceInspectorCloseWarningText -Run @(New-TestRun -ComputerName 'WS01') -NewLine $strNl
            $strOne | Should -Match '^1 action is still running\. If you close the tool, it stops waiting for it, and the run on the device can stop before it is complete\. Wait for the running action to end before you close\.'
            $strOne | Should -Not -Match 'actions are'
            $strOne | Should -Not -Match '1 actions'
            @($strOne -split "`n" | Where-Object { $_ -match '^Client policy update on WS01 \(ID \S+\)$' }).Count | Should -Be 1
            $strTwo = Get-DeviceInspectorCloseWarningText -Run @((New-TestRun -ComputerName 'WS01'), (New-TestRun -ComputerName 'WS02')) -NewLine $strNl
            $strTwo | Should -Match '^2 actions are still running\. If you close the tool, it stops waiting for them, and a run on a device can stop before it is complete\. Wait for the running actions to end before you close\.'
            @($strTwo -split "`n" | Where-Object { $_ -match ' on WS0[12] \(ID ' }).Count | Should -Be 2
        }

        It 'ends the process only when a run was open and the script owns the process' {
            Test-DeviceInspectorExitNeeded -OpenRunClosed $true -OwnsProcess $true | Should -BeTrue
            Test-DeviceInspectorExitNeeded -OpenRunClosed $true -OwnsProcess $false | Should -BeFalse
            Test-DeviceInspectorExitNeeded -OpenRunClosed $false -OwnsProcess $true | Should -BeFalse
            Test-DeviceInspectorExitNeeded -OpenRunClosed $false -OwnsProcess $false | Should -BeFalse
        }

        It 'owns the process when the command line runs the script with -File, as the suite launcher and powershell -File do' {
            $strScript = Join-Path -Path $TestDrive -ChildPath 'Tool Folder\start-deviceinspector.ps1'
            # The suite launcher: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "<entry>"
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs @('C:\Windows\powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $strScript) | Should -BeTrue
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs @('powershell.exe', '-File', $strScript.ToUpperInvariant()) | Should -BeTrue
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs @('powershell.exe', '-f', $strScript) | Should -BeTrue
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs @('powershell.exe', ('-File:' + $strScript)) | Should -BeTrue
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs @('powershell.exe', '-File', 'start-deviceinspector.ps1') -BaseDirectory (Split-Path -Path $strScript -Parent) | Should -BeTrue
        }

        It 'does not own the process when an admin runs the script inside a console or runs another script' {
            $strScript = Join-Path -Path $TestDrive -ChildPath 'Tool Folder\start-deviceinspector.ps1'
            # A console: the command line holds no script. The tool runs by call operator or dot source.
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs @('C:\Windows\powershell.exe') | Should -BeFalse
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs @('C:\Windows\powershell.exe', '-NoProfile', '-STA') | Should -BeFalse
            # Another script owns the process, and this script runs inside it.
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs @('powershell.exe', '-File', (Join-Path -Path $TestDrive -ChildPath 'other.ps1'), $strScript) | Should -BeFalse
            # -Command is not -File.
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs @('powershell.exe', '-Command', ('& ''{0}''' -f $strScript)) | Should -BeFalse
            Test-DeviceInspectorProcessOwner -ScriptPath '' -CommandLineArgs @('powershell.exe', '-File', $strScript) | Should -BeFalse
            Test-DeviceInspectorProcessOwner -ScriptPath $strScript -CommandLineArgs $null | Should -BeFalse
        }

        It 'sets the close flag where open runs get a CLOSED line and asks the decision function before the exit' {
            $strClosing = [regex]::Match($script:strStart, '(?s)\$window\.Add_Closing\(\{.*?\r?\n\}\)').Value
            $strClosing | Should -Match '(?s)if \(\$open\.Count -gt 0\) \{.*?\$script:ClosedWithOpenRuns = \$true.*?Write-DeviceInspectorCloseLog'
            $script:strStart | Should -Match '\$script:OwnsProcess = Test-DeviceInspectorProcessOwner -ScriptPath \$PSCommandPath -CommandLineArgs @\(\[Environment\]::GetCommandLineArgs\(\)\)'
            $script:strStart | Should -Match 'if \(Test-DeviceInspectorExitNeeded -OpenRunClosed \$script:ClosedWithOpenRuns -OwnsProcess \$script:OwnsProcess\) \{ \[Environment\]::Exit\(0\) \}'
            # The exit comes after the transcript stops, so every log line is written first.
            $script:strStart.IndexOf('Test-DeviceInspectorExitNeeded') | Should -BeGreaterThan $script:strStart.LastIndexOf('Stop-Transcript')
            # Nothing else in the script ends the process by an explicit exit.
            @([regex]::Matches($script:strStart, '\[Environment\]::Exit')).Count | Should -Be 1
            Get-TestFunctionText -Name 'Stop-DeviceActionRun' | Should -Not -Match 'Exit'
        }

        It 'uses the owner text in the close dialog, with Wait as the default button, and never stops an open run' {
            $strDialog = Get-TestFunctionText -Name 'Show-CloseWarningDialog'
            $strDialog | Should -Match 'Get-DeviceInspectorCloseWarningText -Run @\(\$Runs\)'
            $strDialog | Should -Match 'x:Name="btnWait"[^>]*IsDefault="True" IsCancel="True"'
            $strDialog | Should -Not -Match 'x:Name="btnCloseAnyway"[^>]*IsDefault'
            $strStop = Get-TestFunctionText -Name 'Stop-DeviceActionRun'
            $strStop | Should -Not -Match 'BeginStop|\$job'
            $script:strStart | Should -Not -Match 'runs on the devices continue'
        }
    }
}

Describe 'Device key for the one-action-for-each-device check' {
    It 'gives the key <Key> for the name <Name>' -ForEach @(
        @{ Name = 'WS01'; Key = 'ws01' }
        @{ Name = 'ws01'; Key = 'ws01' }
        @{ Name = 'ws01.corp.local'; Key = 'ws01' }
        @{ Name = 'WS01.CORP.LOCAL'; Key = 'ws01' }
        @{ Name = '  Ws01.Corp  '; Key = 'ws01' }
        @{ Name = '10.0.0.5'; Key = '10.0.0.5' }
        @{ Name = '2001:DB8::1'; Key = '2001:db8::1' }
        @{ Name = ''; Key = '' }
    ) {
        Get-DeviceInspectorDeviceKey -ComputerName $Name | Should -Be $Key
    }

    It 'treats WS01, ws01.corp.local and WS01.CORP.LOCAL as one device, for a run and for a dry run' {
        $listRun = New-Object -TypeName 'System.Collections.ObjectModel.ObservableCollection[object]'
        $objFirst = New-DeviceInspectorActionRun -ActionId 'aaaaaaaa' -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false
        Register-DeviceInspectorActionRun -Runs $listRun -Run $objFirst
        foreach ($strName in 'ws01.corp.local', 'WS01.CORP.LOCAL', 'Ws01') {
            { Register-DeviceInspectorActionRun -Runs $listRun -Run (New-DeviceInspectorActionRun -ActionId 'bbbbbbbb' -Action 'Full hardware inventory' -ComputerName $strName -DryRun $true) } | Should -Throw -Because $strName
        }
        $listRun.Count | Should -Be 1
        { Register-DeviceInspectorActionRun -Runs $listRun -Run (New-DeviceInspectorActionRun -ActionId 'cccccccc' -Action 'Full hardware inventory' -ComputerName 'WS02.corp.local' -DryRun $false) } | Should -Not -Throw
    }

    It 'gives the same reason to the gate of a device action and of a site action for each spelling of the name' -ForEach @(@{ Kind = 'Device' }, @{ Kind = 'Site' }) {
        $objInspection = [pscustomobject]@{ SiteServer = 's'; Site = [pscustomobject]@{ Found = $true }; Device = [pscustomobject]@{} }
        $objRun = New-DeviceInspectorActionRun -ActionId 'aaaaaaaa' -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false
        foreach ($strName in 'WS01', 'ws01.corp.local', 'WS01.CORP.LOCAL') {
            Get-DeviceInspectorActionBlock -Inspection $objInspection -ActionsEnabled $true -Busy $false -Kind $Kind -Run @($objRun) -ComputerName $strName | Should -Match '^Client policy update \(ID aaaaaaaa\) is running on WS01 since ' -Because $strName
        }
        Get-DeviceInspectorActionBlock -Inspection $objInspection -ActionsEnabled $true -Busy $false -Kind $Kind -Run @($objRun) -ComputerName 'WS02.corp.local' | Should -Be ''
    }

    It 'treats two names with the same site resource ID as one device, and an IP address without a resource ID as another' {
        $objRun = New-DeviceInspectorActionRun -ActionId 'aaaaaaaa' -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false -ResourceId 16777300
        Get-DeviceInspectorRunningAction -Run @($objRun) -ComputerName '10.0.0.5' | Should -BeNullOrEmpty
        Get-DeviceInspectorRunningAction -Run @($objRun) -ComputerName '10.0.0.5' -ResourceId 16777300 | Should -Not -BeNullOrEmpty
        Get-DeviceInspectorRunningAction -Run @($objRun) -ComputerName '10.0.0.5' -ResourceId 16777301 | Should -BeNullOrEmpty
        Get-DeviceInspectorRunBlock -Run @($objRun) -ComputerName 'ws01.corp.local' -ResourceId 0 | Should -Match 'is running on WS01'
        $listRun = New-Object -TypeName 'System.Collections.ObjectModel.ObservableCollection[object]'
        Register-DeviceInspectorActionRun -Runs $listRun -Run $objRun
        { Register-DeviceInspectorActionRun -Runs $listRun -Run (New-DeviceInspectorActionRun -ActionId 'bbbbbbbb' -Action 'Full hardware inventory' -ComputerName '10.0.0.5' -DryRun $false -ResourceId 16777300) } | Should -Throw
    }
}

Describe 'End of a run' {
    BeforeAll {
        $script:objRun = New-DeviceInspectorActionRun -ActionId 'a1b2c3d4' -Action 'Corrupt-inventory repair' -ComputerName 'WS01' -DryRun $false
        function Get-TestHeaderLine {
            param([object]$Record)
            $strPath = Join-Path -Path $TestDrive -ChildPath ('Logs\{0}.log' -f [guid]::NewGuid().ToString('N'))
            $null = Write-DeviceInspectorActionLog -Path $strPath -Result $Record
            return , @([System.IO.File]::ReadAllLines($strPath) | Where-Object { $_ -notmatch '^\s' })
        }
    }

    It 'says that a run has ended when Done is set, or when the asynchronous call is completed, and not before' {
        Test-DeviceInspectorRunFinished -State @{ Done = $true } -Handle $null | Should -BeTrue
        Test-DeviceInspectorRunFinished -State ([hashtable]::Synchronized(@{ Done = $false })) -Handle ([pscustomobject]@{ IsCompleted = $true }) | Should -BeTrue
        Test-DeviceInspectorRunFinished -State ([pscustomobject]@{ Done = $false }) -Handle ([pscustomobject]@{ IsCompleted = $false }) | Should -BeFalse
        Test-DeviceInspectorRunFinished -State @{ Done = $false } -Handle $null | Should -BeFalse
        Test-DeviceInspectorRunFinished -State $null -Handle ([pscustomobject]@{ IsCompleted = $true }) | Should -BeTrue
    }

    It 'sees a pipeline that ends without the Done flag as ended, and the failure path gives a FAILED record' {
        $objPs = [powershell]::Create()
        try {
            [void]$objPs.AddScript({ throw 'The pipeline stopped.' })
            $objHandle = $objPs.BeginInvoke()
            $null = $objHandle.AsyncWaitHandle.WaitOne(30000)
            $hashtableState = [hashtable]::Synchronized(@{ Done = $false; Result = $null; ErrorMsg = $null })
            Test-DeviceInspectorRunFinished -State $hashtableState -Handle $objHandle | Should -BeTrue
            $strProblem = ''
            try { [void]$objPs.EndInvoke($objHandle) } catch { $strProblem = $_.Exception.Message }
            $strProblem | Should -Match 'The pipeline stopped\.'
            $objRecord = Resolve-DeviceInspectorRunResult -Run $script:objRun -Result $hashtableState.Result -ErrorMessage $strProblem -Detail @()
            $objRecord.Outcome | Should -Be 'FAILED'
            $objRecord.Summary | Should -Be 'The action stopped with an error. The action log has the reason.'
            @($objRecord.Detail) | Should -Be @($strProblem)
        } finally {
            $objPs.Dispose()
        }
    }

    It 'returns the result with the ID and the detail lines when the work returned exactly one result' {
        $objResult = [pscustomobject]@{ Action = 'Corrupt-inventory repair'; ComputerName = 'WS01'; DryRun = $false; Mode = 'RUN'; StartedAt = '2026-11-11T08:00:00Z'; Account = 'EXAMPLE\admin'; Succeeded = $true; Outcome = 'OK'; Summary = 'Done.'; Steps = @() }
        $objRecord = Resolve-DeviceInspectorRunResult -Run $script:objRun -Result @($objResult) -ErrorMessage '' -Detail @('Application: X.')
        $objRecord.ActionId | Should -Be 'a1b2c3d4'
        $objRecord.Steps | Should -Be @('Application: X.')
        $arrLine = @(Get-TestHeaderLine -Record $objRecord)
        $arrLine.Count | Should -Be 1
        $arrLine[0] | Should -Match '\| a1b2c3d4 \| \S+ \| WS01 \| Corrupt-inventory repair \| RUN \| OK \| Done\.$'
    }

    It 'writes exactly one FAILED line that says so for <Case>' -ForEach @(
        @{ Case = 'no result'; Result = $null; Message = ''; Expected = 'The action returned no result.' }
        @{ Case = 'an empty array'; Result = @(); Message = ''; Expected = 'The action returned no result.' }
        @{ Case = 'two results'; Result = @([pscustomobject]@{ Succeeded = $true }, [pscustomobject]@{ Succeeded = $true }); Message = ''; Expected = 'The action returned 2 results instead of one.' }
        @{ Case = 'an object that is not an action result'; Result = 'text'; Message = ''; Expected = 'The action returned an object that is not an action result.' }
        @{ Case = 'an error'; Result = $null; Message = 'WinRM cannot complete the operation.'; Expected = 'The action stopped with an error. The action log has the reason.' }
    ) {
        $objRecord = Resolve-DeviceInspectorRunResult -Run $script:objRun -Result $Result -ErrorMessage $Message -Detail @('Application: X.')
        @($objRecord).Count | Should -Be 1
        $objRecord.Outcome | Should -Be 'FAILED'
        $objRecord.Summary | Should -Be $Expected
        $arrLine = @(Get-TestHeaderLine -Record $objRecord)
        $arrLine.Count | Should -Be 1
        $arrLine[0] | Should -Match ('\| a1b2c3d4 \| \S+ \| WS01 \| Corrupt-inventory repair \| RUN \| FAILED \| {0}$' -f [regex]::Escape($Expected))
    }

    It 'writes the result line first and runs the window updates after it, each in its own try' {
        $strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $objAst = [System.Management.Automation.Language.Parser]::ParseFile($script:strStartPath, [ref]$null, [ref]$null)
        $strText = $objAst.Find({ param($objNode) $objNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $objNode.Name -eq 'Complete-DeviceActionRun' }, $true).Extent.Text
        $intWrite = $strText.IndexOf('Write-ActionResult -Result $record')
        $intWrite | Should -BeGreaterThan 0
        foreach ($strLater in 'Update-ControlState', 'Update-StatusBarSummary', 'Show-ActionResultNotice', '& $Job.AfterRun') {
            $strText.IndexOf($strLater) | Should -BeGreaterThan $intWrite -Because $strLater
        }
        $strText | Should -Match '(?s)try \{ Update-ControlState \} catch.*?try \{ Update-StatusBarSummary \} catch'
        $strStart | Should -Match '(?s)function Write-ActionResult \{.*?Write-DeviceInspectorActionLog.*?foreach \(\$line in .*?Add-LogLine'
        $strStart | Should -Match '(?s)function Update-DeviceActionRun \{.*?Test-DeviceInspectorRunFinished -State \$job\.State -Handle \$job\.Handle'
    }
}

Describe 'Action record Detail property' {
    It 'gives every record an empty Detail list by default and keeps the Detail that the caller passes' {
        $objPlain = New-DeviceInspectorActionRecord -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false -Succeeded $true -Summary 'Done.' -Steps @()
        $objPlain.PSObject.Properties['Detail'] | Should -Not -BeNullOrEmpty
        @($objPlain.Detail).Count | Should -Be 0
        $objDetail = New-DeviceInspectorActionRecord -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false -Succeeded $false -Summary 'Failed.' -Steps @() -Detail @('reason one', 'reason two')
        @($objDetail.Detail) | Should -Be @('reason one', 'reason two')
    }

    It 'keeps Detail when the window sets the action ID' {
        $objDetail = New-DeviceInspectorActionRecord -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false -Succeeded $false -Summary 'Failed.' -Steps @() -Detail @('reason one')
        $objWithId = Add-DeviceInspectorActionId -Result $objDetail -ActionId 'a1b2c3d4'
        $objWithId.ActionId | Should -Be 'a1b2c3d4'
        @($objWithId.Detail) | Should -Be @('reason one')
    }

    It 'prints Detail lines only with IncludeDetail, after the step lines' {
        $objDetail = New-DeviceInspectorActionRecord -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false -Succeeded $false -Summary 'Failed.' -Steps @('step one') -Detail @('reason one', "reason`ntwo")
        $arrWindow = @(ConvertTo-DeviceInspectorActionText -Result $objDetail)
        $arrWindow.Count | Should -Be 2
        ($arrWindow -join "`n") | Should -Not -Match 'reason'
        $arrFile = @(ConvertTo-DeviceInspectorActionText -Result $objDetail -IncludeDetail)
        $arrFile.Count | Should -Be 4
        $arrFile[1] | Should -Be '    step one'
        $arrFile[2] | Should -Be '    Detail: reason one'
        $arrFile[3] | Should -Be '    Detail: reason two'
    }

    It 'accepts a result without a Detail property' {
        $objOld = [pscustomobject]@{
            Action = 'Client policy update'; ComputerName = 'WS01'; DryRun = $false; Mode = 'RUN'
            StartedAt = '2026-11-10T20:00:00Z'; Account = 'EXAMPLE\admin'; Succeeded = $true; Summary = 'Done.'; Steps = @()
        }
        @(ConvertTo-DeviceInspectorActionText -Result $objOld -IncludeDetail).Count | Should -Be 1
    }
}

Describe 'Raw exception text stays out of the window' {
    BeforeAll {
        # Builds an action record from the raw object that a device script block returns.
        function ConvertTo-TestRecord {
            param([Parameter(Mandatory = $true)][object]$Raw)
            $arrDetail = @()
            if ($null -ne $Raw.PSObject.Properties['Detail']) {
                $arrDetail = @($Raw.Detail | ForEach-Object { [string]$_ })
            }
            New-DeviceInspectorActionRecord -Action 'Test action' -ComputerName 'WS01' -DryRun $false -Succeeded ([bool]$Raw.Succeeded) -Summary ([string]$Raw.Summary) -Steps ([string[]]@($Raw.Steps)) -Detail ([string[]]$arrDetail)
        }

        # The raw text must be absent from Summary, Steps and the window text. It must be present
        # in Detail, in the text with IncludeDetail, and in the action log file.
        function Assert-RawTextHidden {
            param([Parameter(Mandatory = $true)][object]$Record, [Parameter(Mandatory = $true)][string]$Text)
            ([string]$Record.Summary).Contains($Text) | Should -BeFalse -Because ('the Summary must not hold {0}' -f $Text)
            (@($Record.Steps) -join "`n").Contains($Text) | Should -BeFalse -Because ('the Steps must not hold {0}' -f $Text)
            (@(ConvertTo-DeviceInspectorActionText -Result $Record) -join "`n").Contains($Text) | Should -BeFalse -Because ('the window text must not hold {0}' -f $Text)
            (@($Record.Detail) -join "`n").Contains($Text) | Should -BeTrue -Because ('the Detail must hold {0}' -f $Text)
            (@(ConvertTo-DeviceInspectorActionText -Result $Record -IncludeDetail) -join "`n").Contains($Text) | Should -BeTrue -Because ('the text with IncludeDetail must hold {0}' -f $Text)
            $strPath = Join-Path -Path $TestDrive -ChildPath ('Logs\{0}.log' -f [guid]::NewGuid().ToString('N'))
            $null = Write-DeviceInspectorActionLog -Path $strPath -Result $Record
            [System.IO.File]::ReadAllText($strPath).Contains($Text) | Should -BeTrue -Because ('the action log file must hold {0}' -f $Text)
        }
    }

    Context 'Policy update script' {
        It 'hides the text of a failed client read' {
            $objRaw = InModuleScope DeviceInspectorCommon {
                Mock Get-CimInstance { throw 'secret-boom-1' }
                & $script:scriptBlockPolicyUpdate $false
            }
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Be 'The Configuration Manager client does not answer. The action log has the reason.'
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-1'
        }

        It 'hides the text of a failed schedule trigger' {
            $objRaw = InModuleScope DeviceInspectorCommon {
                Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } }
                Mock Invoke-CimMethod { throw 'secret-boom-2' }
                & $script:scriptBlockPolicyUpdate $false
            }
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'The action log has the reason\.$'
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-2'
        }
    }

    Context 'Full inventory script' {
        It 'hides the text of a failed client read' {
            $objRaw = InModuleScope DeviceInspectorCommon {
                Mock Get-CimInstance { throw 'secret-boom-3' }
                & $script:scriptBlockFullInventory $false
            }
            $objRaw.Succeeded | Should -BeFalse
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-3'
        }

        It 'hides the text of a failed status read' {
            $objRaw = InModuleScope DeviceInspectorCommon {
                Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
                Mock Get-CimInstance { throw 'secret-boom-4' } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
                & $script:scriptBlockFullInventory $false
            }
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Be 'The hardware inventory status cannot be read. The action log has the reason.'
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-4'
        }

        It 'hides the text of a failed delete of the status record' {
            $objRaw = InModuleScope DeviceInspectorCommon {
                $objStatus = New-CimInstance -ClassName 'InventoryActionStatus' -Namespace 'root/ccm/invagt' -ClientOnly -Property @{ InventoryActionID = '{00000000-0000-0000-0000-000000000001}'; LastMajorReportVersion = [uint32]1; LastMinorReportVersion = [uint32]0 }
                Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
                Mock Get-CimInstance { $objStatus } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
                Mock Remove-CimInstance { throw 'secret-boom-5' }
                Mock Invoke-CimMethod { }
                & $script:scriptBlockFullInventory $false
            }
            $objRaw.Succeeded | Should -BeFalse
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-5'
        }

        It 'hides the text of a failed trigger' {
            $objRaw = InModuleScope DeviceInspectorCommon {
                Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
                Mock Get-CimInstance { } -ParameterFilter { $ClassName -eq 'InventoryActionStatus' }
                Mock Invoke-CimMethod { throw 'secret-boom-6' }
                & $script:scriptBlockFullInventory $false
            }
            $objRaw.Succeeded | Should -BeFalse
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-6'
        }
    }

    Context 'Update install script' {
        It 'hides the text of a failed client read' {
            $objRaw = InModuleScope DeviceInspectorCommon {
                Mock Get-CimInstance { throw 'secret-boom-7' }
                & $script:scriptBlockUpdateInstall $false @()
            }
            $objRaw.Succeeded | Should -BeFalse
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-7'
        }

        It 'hides the text of a failed read of the updates' {
            $objRaw = InModuleScope DeviceInspectorCommon {
                Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
                Mock Get-CimInstance { throw 'secret-boom-8' } -ParameterFilter { $ClassName -eq 'CCM_SoftwareUpdate' }
                & $script:scriptBlockUpdateInstall $false @()
            }
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Be 'The updates of the client policy cannot be read. The action log has the reason.'
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-8'
        }

        It 'hides the text of a failed install request, and of a failed read after a good request' {
            $objRaw = InModuleScope DeviceInspectorCommon {
                $script:arrTestUpdate = @(New-CimInstance -ClassName 'CCM_SoftwareUpdate' -Namespace 'root/ccm/ClientSDK' -ClientOnly -Property @{
                        UpdateID = 'Site_X/SUM_1'; ArticleID = '5001'; Name = 'Update KB5001'; ComplianceState = [uint32]0; EvaluationState = [uint32]0; PercentComplete = [uint32]0 })
                Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
                Mock Get-CimInstance { $script:arrTestUpdate } -ParameterFilter { $ClassName -eq 'CCM_SoftwareUpdate' }
                Mock Start-Sleep { }
                Mock Invoke-CimMethod { throw 'secret-boom-9' }
                & $script:scriptBlockUpdateInstall $false @()
            }
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Be 'The client did not accept the install request. The action log has the reason.'
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-9'

            $objAfter = InModuleScope DeviceInspectorCommon {
                $script:intUpdateRead = 0
                Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
                Mock Get-CimInstance { $script:intUpdateRead++; if ($script:intUpdateRead -ge 2) { throw 'secret-boom-10' }; $script:arrTestUpdate } -ParameterFilter { $ClassName -eq 'CCM_SoftwareUpdate' }
                Mock Start-Sleep { }
                Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0 } }
                & $script:scriptBlockUpdateInstall $false @()
            }
            $objAfter.Succeeded | Should -BeTrue
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objAfter) -Text 'secret-boom-10'
        }
    }

    Context 'Application action script' {
        BeforeAll {
            $script:strTestKeyName = 'DeviceInspectorTest-{0}' -f [guid]::NewGuid().ToString('N')
            $script:strTestKeyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0}' -f $script:strTestKeyName
            $null = New-Item -Path $script:strTestKeyPath -Force
            $null = New-ItemProperty -LiteralPath $script:strTestKeyPath -Name 'DisplayName' -Value 'Device Inspector test entry' -PropertyType 'String' -Force
            $null = New-ItemProperty -LiteralPath $script:strTestKeyPath -Name 'QuietUninstallString' -Value 'cmd.exe /c exit 0' -PropertyType 'String' -Force
        }

        AfterAll {
            Remove-Item -LiteralPath $script:strTestKeyPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'hides the text of a command that does not start' {
            $objRaw = InModuleScope DeviceInspectorCommon -Parameters @{ KeyName = $script:strTestKeyName } {
                param($KeyName)
                Mock Start-Process { throw 'secret-boom-11' }
                & $script:scriptBlockApplicationAction $false 'Uninstall' '64-bit' $KeyName
            }
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Be 'The uninstall did not start. The action log has the reason.'
            Assert-RawTextHidden -Record (ConvertTo-TestRecord -Raw $objRaw) -Text 'secret-boom-11'
        }
    }

    Context 'Invoke-ActionOnDevice' {
        It 'hides the text of a connection failure, for a run and for a dry run' {
            Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { throw 'secret-boom-12' }
            $objRun = Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01'
            $objRun.Summary | Should -Be 'Cannot run the action on WS01. The action log has the reason. The connection can fail after a step ran. Inspect the device to see its state.'
            Assert-RawTextHidden -Record $objRun -Text 'secret-boom-12'
            $objDry = Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01' -DryRun
            $objDry.Summary | Should -Be 'Cannot run the action on WS01. The action log has the reason.'
            Assert-RawTextHidden -Record $objDry -Text 'secret-boom-12'
        }

        It 'copies the Detail that the device returns, and gives an empty Detail when it returns none' {
            Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $false; Summary = 'The client did not accept the install request. The action log has the reason.'; Steps = @('step one'); Detail = @('secret-boom-13') } }
            $objFailed = Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01'
            Assert-RawTextHidden -Record $objFailed -Text 'secret-boom-13'
            Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @() } }
            $objPlain = Invoke-DeviceInspectorPolicyUpdate -ComputerName 'WS01'
            @($objPlain.Detail).Count | Should -Be 0
        }
    }

    Context 'Resolve-DeviceInspectorRunResult' {
        It 'puts the error text in Detail and keeps it out of the Summary' {
            $objRun = New-DeviceInspectorActionRun -ActionId 'a1b2c3d4' -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false
            $objRecord = Resolve-DeviceInspectorRunResult -Run $objRun -Result $null -ErrorMessage 'secret-boom-14' -Detail @('Application: X.')
            $objRecord.Outcome | Should -Be 'FAILED'
            $objRecord.Summary | Should -Be 'The action stopped with an error. The action log has the reason.'
            @($objRecord.Steps) | Should -Be @('Application: X.')
            Assert-RawTextHidden -Record $objRecord -Text 'secret-boom-14'
        }

        It 'keeps the Detail of a device result' {
            $objRun = New-DeviceInspectorActionRun -ActionId 'a1b2c3d4' -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false
            $objResult = New-DeviceInspectorActionRecord -Action 'Client policy update' -ComputerName 'WS01' -DryRun $false -Succeeded $false -Summary 'Failed.' -Steps @() -Detail @('secret-boom-15')
            $objRecord = Resolve-DeviceInspectorRunResult -Run $objRun -Result @($objResult) -ErrorMessage '' -Detail @()
            Assert-RawTextHidden -Record $objRecord -Text 'secret-boom-15'
        }
    }

    Context 'Collection change' {
        BeforeEach {
            InModuleScope DeviceInspectorCommon {
                Mock Connect-InspectorSite { [pscustomobject]@{ SiteCode = 'XYZ'; SiteServer = 'sms01'; PreviousLocation = 'C:\'; CreatedDrive = $false } }
                Mock Disconnect-InspectorSite { }
                Mock Get-CMDevice { [pscustomobject]@{ ResourceID = 16777221; Name = 'WS01' } }
                Mock Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'XYZ0001F'; Name = 'Pilot'; LimitToCollectionID = '' } }
                Mock Get-CMDeviceCollectionDirectMembershipRule { [pscustomobject]@{ ResourceID = 16777221; RuleName = 'WS01' } }
                Mock Remove-CMDeviceCollectionDirectMembershipRule { }
                Mock Add-CMDeviceCollectionDirectMembershipRule { }
                Mock Invoke-CMCollectionUpdate { }
                Mock Invoke-CMClientAction { }
                Mock Get-CMCollectionMember { }
                Mock Start-Sleep { }
            }
        }

        It 'hides the text of a failed rule change' {
            Mock -ModuleName DeviceInspectorCommon Remove-CMDeviceCollectionDirectMembershipRule { throw 'secret-boom-16' }
            $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove
            $objResult.Succeeded | Should -BeFalse
            $objResult.Summary | Should -Be 'The site did not change the rule. The action log has the reason.'
            Assert-RawTextHidden -Record $objResult -Text 'secret-boom-16'
        }

        It 'hides the text of a failed membership update' {
            Mock -ModuleName DeviceInspectorCommon Invoke-CMCollectionUpdate { throw 'secret-boom-17' }
            $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove
            $objResult.Succeeded | Should -BeTrue
            Assert-RawTextHidden -Record $objResult -Text 'secret-boom-17'
        }

        It 'hides the text of a failed client notification' {
            Mock -ModuleName DeviceInspectorCommon Invoke-CMClientAction { throw 'secret-boom-18' }
            $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove
            $objResult.Succeeded | Should -BeTrue
            Assert-RawTextHidden -Record $objResult -Text 'secret-boom-18'
        }

        It 'hides the text of a failed membership read' {
            Mock -ModuleName DeviceInspectorCommon Get-CMCollectionMember { throw 'secret-boom-19' }
            $objResult = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove
            $objResult.Succeeded | Should -BeTrue
            (@($objResult.Steps) -join "`n") | Should -Match 'The last read failed\. The action log has the reason\.'
            Assert-RawTextHidden -Record $objResult -Text 'secret-boom-19'
        }

        It 'hides the text of a failed connection and of a failed read of the rules' {
            Mock -ModuleName DeviceInspectorCommon Connect-InspectorSite { throw 'secret-boom-20' }
            $objConnect = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove
            $objConnect.Succeeded | Should -BeFalse
            $objConnect.Summary | Should -Be 'Cannot run the action on site XYZ. The action log has the reason.'
            Assert-RawTextHidden -Record $objConnect -Text 'secret-boom-20'
            Mock -ModuleName DeviceInspectorCommon Connect-InspectorSite { [pscustomobject]@{ SiteCode = 'XYZ'; SiteServer = 'sms01'; PreviousLocation = 'C:\'; CreatedDrive = $false } }
            Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollectionDirectMembershipRule { throw 'secret-boom-21' }
            $objRule = Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Add
            $objRule.Succeeded | Should -BeFalse
            Assert-RawTextHidden -Record $objRule -Text 'secret-boom-21'
        }
    }
}

Describe 'No exception text in Summary or Steps (static check)' {
    BeforeAll {
        # Returns one text line for each place in a catch block that builds Summary, Steps or a
        # step line from the error. Detail and Write-Debug may use the error.
        function Find-ExceptionTextLeak {
            param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast)
            $strRaw = '\$_(?![A-Za-z0-9_])|Exception|\$PSItem|\$Error\b'
            $listLeak = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $arrCatch = @($Ast.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
            foreach ($objCatch in $arrCatch) {
                foreach ($objNode in @($objCatch.Body.FindAll({ param($objAny) $true }, $true))) {
                    $strText = $objNode.Extent.Text
                    if ($strText -notmatch $strRaw) {
                        continue
                    }
                    $boolLeak = $false
                    if ($objNode -is [System.Management.Automation.Language.CommandAst]) {
                        $boolLeak = ($objNode.GetCommandName() -ne 'Write-Debug')
                    } elseif ($objNode -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                        $boolLeak = ($objNode.Member.Extent.Text -eq 'Add' -and $objNode.Expression.Extent.Text -ne '$listDetail')
                    } elseif ($objNode -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                        $boolLeak = ($objNode.Left.Extent.Text -match '(?i)summary|steps|liststep' -and $objNode.Right.Extent.Text -match $strRaw)
                    } elseif ($objNode -is [System.Management.Automation.Language.HashtableAst]) {
                        foreach ($objPair in $objNode.KeyValuePairs) {
                            if ($objPair.Item1.Extent.Text -match '^(?i)(Summary|Steps)$' -and $objPair.Item2.Extent.Text -match $strRaw) {
                                $boolLeak = $true
                            }
                        }
                    }
                    if ($boolLeak) {
                        $listLeak.Add(('line {0}: {1}' -f $objNode.Extent.StartLineNumber, $strText))
                    }
                }
            }
            $listLeak.ToArray()
        }
    }

    It 'finds a leak in a catch block of a test snippet, so the check is not empty' {
        $objSnippet = [System.Management.Automation.Language.Parser]::ParseInput('try { 1 } catch { $listStep.Add(("failed: {0}" -f $_.Exception.Message)); return [pscustomobject]@{ Summary = ("x {0}" -f $_); Steps = @() } }', [ref]$null, [ref]$null)
        @(Find-ExceptionTextLeak -Ast $objSnippet).Count | Should -BeGreaterThan 1
        $objGood = [System.Management.Automation.Language.Parser]::ParseInput('try { 1 } catch { $listDetail.Add(("x: {0}" -f $_.Exception.Message)); Write-Debug -Message $_.Exception.Message; return [pscustomobject]@{ Summary = "Fixed."; Steps = @($listStep) } }', [ref]$null, [ref]$null)
        @(Find-ExceptionTextLeak -Ast $objGood).Count | Should -Be 0
    }

    It 'builds no Summary, Steps or step line from an error inside a catch block of the action module' {
        $objAst = [System.Management.Automation.Language.Parser]::ParseFile($script:strActionsFile, [ref]$null, [ref]$null)
        @($objAst.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.CatchClauseAst] }, $true)).Count | Should -BeGreaterThan 15
        $arrLeak = @(Find-ExceptionTextLeak -Ast $objAst)
        $arrLeak | Should -BeNullOrEmpty -Because ($arrLeak -join [Environment]::NewLine)
    }
}
