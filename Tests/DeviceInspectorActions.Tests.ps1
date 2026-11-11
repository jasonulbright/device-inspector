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
        $script:strStart | Should -Match "(?s)function Test-DeviceActionReady \{.*?\`$script:ActionsEnabled -and"
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
            $objRaw.Summary | Should -Match 'cannot be deleted\. Nothing changed'
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

    It 'has a Device panel button that runs the action through the gate' {
        $script:strXaml | Should -Match 'x:Name="btnFullInventory"'
        $script:strStart | Should -Match "(?s)\`$btnFullInventory\.Add_Click\(\{\s*Invoke-DeviceAction -Name 'Full hardware inventory' -Function 'Invoke-DeviceInspectorFullInventory'"
        $script:strStart | Should -Match '\$btnFullInventory\.IsEnabled = Test-DeviceActionReady'
    }
}
