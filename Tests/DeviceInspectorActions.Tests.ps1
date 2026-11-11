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
        $objResult.Summary | Should -Match 'WinRM cannot complete'
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
            $objRaw.Steps[2] | Should -Match 'failed: Generic failure'
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
            Action = 'Client policy update'; ComputerName = 'WS01'; DryRun = $true; Mode = 'DRY RUN'
            StartedAt = '2026-11-10T20:00:00Z'; Account = 'EXAMPLE\admin'; Succeeded = $true
            Summary = 'Dry run: the client answers. Nothing changed.'; Steps = @('Client version 5.00 answers.', 'Dry run: would trigger x.')
        }
    }

    It 'formats one header line and one line for each step' {
        $arrLine = @(ConvertTo-DeviceInspectorActionText -Result $script:objSample)
        $arrLine.Count | Should -Be 3
        $arrLine[0] | Should -Be '2026-11-10T20:00:00Z | EXAMPLE\admin | WS01 | Client policy update | DRY RUN | OK | Dry run: the client answers. Nothing changed.'
        $arrLine[1] | Should -Be '    Client version 5.00 answers.'
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
        @(ConvertTo-DeviceInspectorActionText -Result $objStart)[0] | Should -Match '\| WS01 \| Client policy update \| RUN \| STARTED \| The run started\.$'
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

    It 'starts with Enable actions off and does not save the switch' {
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
        $script:strStart | Should -Match '(?s)if \(\$State\.ErrorMsg\) \{\s*\$failed = New-DeviceInspectorActionRecord.*?Write-ActionResult -Result \$failed'
    }

    It 'writes a start record before a run and stops when it cannot write it' {
        $intStart = $script:strStart.IndexOf("-Outcome 'STARTED'")
        $intWork = $script:strStart.IndexOf('Start-ActionWork -Title $title')
        $intStart | Should -BeGreaterThan 0
        $intStart | Should -BeLessThan $intWork
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
        $script:strXaml | Should -Match 'x:Name="btnOpenLog"[^>]*Content="Open log file"'
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
        $script:strStart | Should -Match "-Function 'Invoke-DeviceInspectorFullInventory' -AfterRun \{ param\(\`$r\) Clear-InventoryCheck \}"
        $script:strStart | Should -Match '-AfterRun \{ param\(\$r\) Clear-InventoryCheck;'
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
        $script:strStart | Should -Match "Wait for the running task to end"
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
        $script:strStart | Should -Match "(?s)\`$gridUpdates\.ContextMenu\.Add_Opened\(\{.*?Turn on Enable actions first"
        $script:strStart | Should -Match "(?s)function Invoke-UpdateInstall \{.*?Invoke-DeviceAction -Name \`$name -Function 'Invoke-DeviceInspectorUpdateInstall'"
        $script:strStart | Should -Match "(?s)function Get-InstallableUpdateRow \{.*?Source -eq 'Device' -and \`$_\.Required"
    }
}

Describe 'Uninstall and repair an application' {
    BeforeAll {
        $script:strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $script:strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
    }

    BeforeEach {
        InModuleScope DeviceInspectorCommon {
            $script:arrTestApp = @(
                [pscustomobject]@{ Id = 'ScopeId_1/Application_7'; Revision = '13'; Name = '7-Zip (x64 edition) - 26.03'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Install'); SupersessionState = 'None'; EvaluationState = 1 }
            )
            Mock Get-CimInstance { [pscustomobject]@{ ClientVersion = '5.00.9146.1009' } } -ParameterFilter { $ClassName -eq 'SMS_Client' }
            Mock Get-CimInstance { $script:arrTestApp } -ParameterFilter { $ClassName -eq 'CCM_Application' }
            Mock Start-Sleep { }
        }
    }

    It 'names the action and passes ID and operation after DryRun' {
        Mock -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript { [pscustomobject]@{ Succeeded = $true; Summary = 'ok'; Steps = @() } }
        (Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -ApplicationId 'ScopeId_1/Application_7' -Operation Uninstall -DryRun).Action | Should -Be 'Uninstall application'
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-ActionDeviceScript -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq $true -and $ArgumentList[1] -eq 'ScopeId_1/Application_7' -and $ArgumentList[2] -eq 'Uninstall' }
    }

    It 'refuses an application ID with a quote' {
        { Invoke-DeviceInspectorApplicationAction -ComputerName 'WS01' -ApplicationId "x' OR 1=1" -Operation Uninstall } | Should -Throw
    }

    It 'changes nothing in a dry run' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockApplicationAction $true 'ScopeId_1/Application_7' 'Uninstall'
            $objRaw.Succeeded | Should -BeTrue
            ($objRaw.Steps -join "`n") | Should -Match 'Dry run: would call CCM_Application.Uninstall for 7-Zip'
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'uninstalls an installed application with the immediate enforce preference' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; JobId = '{JOB}' } }
            $objRaw = & $script:scriptBlockApplicationAction $false 'ScopeId_1/Application_7' 'Uninstall'
            $objRaw.Succeeded | Should -BeTrue
            ($objRaw.Steps -join "`n") | Should -Match 'Uninstall accepted\. Job \{JOB\}'
            Should -Invoke Invoke-CimMethod -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'CCM_Application' -and $MethodName -eq 'Uninstall' -and $Arguments.Id -eq 'ScopeId_1/Application_7' -and $Arguments.Revision -eq '13' -and $Arguments.EnforcePreference -eq 0 -and $Arguments.IsMachineTarget -eq $true }
        }
    }

    It 'refuses a repair that the client does not allow, and calls no method' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockApplicationAction $false 'ScopeId_1/Application_7' 'Repair'
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'does not allow Repair'
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'picks the highest revision, also with a revision that is not a number' {
        InModuleScope DeviceInspectorCommon {
            $script:arrTestApp = @(
                [pscustomobject]@{ Id = 'A/1'; Revision = '9'; Name = 'App'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Uninstall'); SupersessionState = 'Superseding'; EvaluationState = 1 }
                [pscustomobject]@{ Id = 'A/1'; Revision = '12'; Name = 'App'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Uninstall'); SupersessionState = 'None'; EvaluationState = 1 }
                [pscustomobject]@{ Id = 'A/1'; Revision = 'x'; Name = 'App'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Uninstall'); SupersessionState = 'None'; EvaluationState = 1 }
            )
            Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0 } }
            $objRaw = & $script:scriptBlockApplicationAction $false 'A/1' 'Uninstall'
            $objRaw.Succeeded | Should -BeTrue
            Should -Invoke Invoke-CimMethod -Times 1 -Exactly -ParameterFilter { $Arguments.Revision -eq '12' }
        }
    }

    It 'refuses a user-targeted application, an application that is not installed, and a simulation' -ForEach @(
        @{ Case = 'user-targeted'; Machine = $false; State = 'Installed'; Preflight = $false; Expected = 'deployed to a user' }
        @{ Case = 'not installed'; Machine = $true; State = 'NotInstalled'; Preflight = $false; Expected = 'not installed, or the deployment is a simulation' }
        @{ Case = 'simulation'; Machine = $true; State = 'Installed'; Preflight = $true; Expected = 'not installed, or the deployment is a simulation' }
    ) {
        InModuleScope DeviceInspectorCommon -Parameters @{ Machine = $Machine; State = $State; Preflight = $Preflight; Expected = $Expected } {
            param($Machine, $State, $Preflight, $Expected)
            $script:arrTestApp = @([pscustomobject]@{ Id = 'A/1'; Revision = '1'; Name = 'App'; InstallState = $State; IsMachineTarget = $Machine; IsPreflightOnly = $Preflight; AllowedActions = @('Install'); SupersessionState = 'None'; EvaluationState = 1 })
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockApplicationAction $false 'A/1' 'Uninstall'
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match $Expected
            Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        }
    }

    It 'says in the log when it sends Uninstall that the allowed actions do not list, and fails without a return value' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CimMethod { }
            $objRaw = & $script:scriptBlockApplicationAction $false 'ScopeId_1/Application_7' 'Uninstall'
            ($objRaw.Steps -join "`n") | Should -Match 'allowed actions of the client do not list Uninstall'
            $objRaw.Succeeded | Should -BeFalse
            $objRaw.Summary | Should -Match 'gave no return value'
        }
    }

    It 'leaves out an ID whose highest revision is not installed, as the device acts on that revision' {
        $objInspection = [pscustomobject]@{
            Site = $null
            Device = [pscustomobject]@{
                InstalledApplications = @()
                ClientApplications = @(
                    [pscustomobject]@{ Name = 'App'; Id = 'S/A'; Revision = '9'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Uninstall'); SoftwareVersion = '9'; Publisher = '' }
                    [pscustomobject]@{ Name = 'App'; Id = 'S/A'; Revision = '12'; InstallState = 'NotInstalled'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Install'); SoftwareVersion = '12'; Publisher = '' }
                )
            }
        }
        @(ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection).Count | Should -Be 0
    }

    It 'puts the application line into a result that has no steps' {
        $script:strStart | Should -Match 'if \(@\(\$r\.Steps\)\.Count -eq 0 -and @\(\$script:ActionPending\.Detail\)\.Count -gt 0\) \{ \$r\.Steps = \[string\[\]\]@\(\$script:ActionPending\.Detail\) \}'
    }

    It 'turns both entries off for a user-targeted application, and gives each application ID one row' {
        $objInspection = [pscustomobject]@{
            Site = $null
            Device = [pscustomobject]@{
                InstalledApplications = @()
                ClientApplications = @(
                    [pscustomobject]@{ Name = 'Dup'; Id = 'S/B'; Revision = '1'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Uninstall', 'Repair'); SoftwareVersion = '1'; Publisher = '' }
                    [pscustomobject]@{ Name = 'Dup'; Id = 'S/A'; Revision = '3'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Uninstall'); SoftwareVersion = '3'; Publisher = '' }
                    [pscustomobject]@{ Name = 'Dup'; Id = 'S/A'; Revision = '7'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Uninstall'); SoftwareVersion = '7'; Publisher = '' }
                    [pscustomobject]@{ Name = 'User App'; Id = 'S/U'; Revision = '1'; InstallState = 'Installed'; IsMachineTarget = $false; IsPreflightOnly = $false; AllowedActions = @('Uninstall', 'Repair'); SoftwareVersion = '1'; Publisher = '' }
                )
            }
        }
        $arrRow = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection)
        $arrDup = @($arrRow | Where-Object Name -eq 'Dup')
        $arrDup.Count | Should -Be 2
        @($arrDup | ForEach-Object { $_.ClientApplicationId } | Sort-Object) | Should -Be @('S/A', 'S/B')
        @($arrDup | Where-Object ClientApplicationId -eq 'S/A')[0].ClientRevision | Should -Be '7'
        $objUser = @($arrRow | Where-Object Name -eq 'User App')[0]
        $objUser.CanUninstall | Should -BeFalse
        $objUser.CanRepair | Should -BeFalse
    }

    It 'names the application in the STARTED line and turns the row off after a run' {
        $script:strStart | Should -Match "-Detail @\(\('Application: \{0\}, ID \{1\}, revision \{2\}\.'"
        $script:strStart | Should -Match "-Outcome 'STARTED' -Summary 'The run started\.' -Steps \`$Detail"
        $script:strStart | Should -Match '\$script:ApplicationRowDone\.CanUninstall = \$false; \$script:ApplicationRowDone\.CanRepair = \$false; Update-AppFilter'
        $script:strStart | Should -Match "(?s)function Select-RowUnderPointer \{.*?if \(-not \`$node\) \{\s*\`$Grid\.SelectedItems\.Clear\(\)"
    }

    It 'fails when the application is gone, and when the client refuses' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 2147749890 } }
            (& $script:scriptBlockApplicationAction $false 'ScopeId_1/Application_7' 'Uninstall').Summary | Should -Match 'refused the Uninstall request'
            (& $script:scriptBlockApplicationAction $false 'ScopeId_1/Application_0' 'Uninstall').Summary | Should -Match 'no application with this ID'
        }
    }

    It 'lists an installed client application as its own row, and links it to an uninstall entry of the same name' {
        $objInspection = [pscustomobject]@{
            Site = $null
            Device = [pscustomobject]@{
                InstalledApplications = @([pscustomobject]@{ Name = '7-Zip 26.03 (x64 edition)'; Version = '26.03'; Publisher = 'Igor Pavlov'; InstallDate = '20261110' }, [pscustomobject]@{ Name = 'Same Name App'; Version = '1.0'; Publisher = 'P'; InstallDate = '' })
                ClientApplications = @(
                    [pscustomobject]@{ Name = '7-Zip (x64 edition) - 26.03'; Id = 'S/A1'; Revision = '13'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Install'); SoftwareVersion = '26.03'; Publisher = 'Igor Pavlov' }
                    [pscustomobject]@{ Name = 'Same Name App'; Id = 'S/A2'; Revision = '2'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Uninstall', 'Repair'); SoftwareVersion = '1.0'; Publisher = 'P' }
                    [pscustomobject]@{ Name = 'Not Installed App'; Id = 'S/A3'; Revision = '1'; InstallState = 'NotInstalled'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @('Install'); SoftwareVersion = '1.0'; Publisher = 'P' }
                )
            }
        }
        $arrRow = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection)
        $arrRow.Count | Should -Be 3
        $objClientRow = @($arrRow | Where-Object Status -eq 'Client application')
        $objClientRow.Count | Should -Be 1
        $objClientRow[0].ClientApplicationId | Should -Be 'S/A1'
        $objClientRow[0].CanUninstall | Should -BeTrue
        $objClientRow[0].CanRepair | Should -BeFalse
        $objLinked = @($arrRow | Where-Object Name -eq 'Same Name App')[0]
        $objLinked.ClientApplicationId | Should -Be 'S/A2'
        $objLinked.CanRepair | Should -BeTrue
        @($arrRow | Where-Object Name -eq '7-Zip 26.03 (x64 edition)')[0].ClientApplicationId | Should -Be ''
    }

    It 'does not count a client application row as an inventory difference' {
        $objInspection = [pscustomobject]@{
            ComputerName = 'WS01'
            Site = [pscustomobject]@{ Found = $true; HardwareScanClientTime = '2026-11-10T10:01:00'; InstalledApplications = @() }
            Device = [pscustomobject]@{ Client = [pscustomobject]@{ HardwareCycleLocalTime = '2026-11-10T10:00:00' }; InstalledApplications = @()
                ClientApplications = @([pscustomobject]@{ Name = 'CM App'; Id = 'S/A1'; Revision = '1'; InstallState = 'Installed'; IsMachineTarget = $true; IsPreflightOnly = $false; AllowedActions = @(); SoftwareVersion = '1'; Publisher = '' }) }
        }
        (Test-DeviceInspectionInventory -Inspection $objInspection).State | Should -Be 'Current'
    }

    It 'has Uninstall and Repair entries that open the action through the gate' {
        $script:strXaml | Should -Match 'x:Name="menuUninstallApp"[^>]*ToolTipService.ShowOnDisabled="True"'
        $script:strXaml | Should -Match 'x:Name="menuRepairApp"'
        $script:strXaml | Should -Match '<ComboBoxItem Content="Client application"/>'
        $script:strStart | Should -Match "(?s)\`$gridApps\.ContextMenu\.Add_Opened\(\{\s*\`$gate = Get-ActionGateText"
        $script:strStart | Should -Match "(?s)function Invoke-ApplicationOperation \{.*?Invoke-DeviceAction -Name \('\{0\} application' -f \`$Operation\) -Function 'Invoke-DeviceInspectorApplicationAction'"
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
            Mock Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'XYZ0001F'; Name = 'Pilot' } }
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
        Mock -ModuleName DeviceInspectorCommon Get-CMCollectionMember { throw 'query failed' }
        ((Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Steps -join "`n") | Should -Match 'Last read error: query failed'
        Should -Invoke -ModuleName DeviceInspectorCommon Invoke-CMClientAction -Times 1 -Exactly
        Should -Invoke -ModuleName DeviceInspectorCommon Get-CMCollectionMember -Times 12 -Exactly
    }

    It 'refuses a missing collection, a failed rule read and a new resource ID, and disconnects each time' {
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollection { }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Summary | Should -Match 'no device collection XYZ0001F'
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollection { [pscustomobject]@{ CollectionID = 'XYZ0001F'; Name = 'Pilot' } }
        Mock -ModuleName DeviceInspectorCommon Get-CMDeviceCollectionDirectMembershipRule { throw 'provider error' }
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove).Summary | Should -Match 'Cannot run the action on site XYZ: provider error'
        (Invoke-DeviceInspectorCollectionChange -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -CollectionId 'XYZ0001F' -Operation Remove -ExpectedResourceId 16777999).Summary | Should -Match 'has resource ID 16777221, not 16777999'
        Should -Invoke -ModuleName DeviceInspectorCommon Disconnect-InspectorSite -Times 3 -Exactly
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-CMDeviceCollectionDirectMembershipRule -Times 0 -Exactly
    }

    It 'gives the reason why an action cannot start, for <Case>' -ForEach @(
        @{ Case = 'switch off'; Enabled = $false; Busy = $false; Kind = 'Site'; Inspection = $null; Expected = 'Turn on Enable actions first.' }
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
