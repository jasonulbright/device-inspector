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
        foreach ($strName in 'Invoke-DeviceInspectorPolicyUpdate', 'ConvertTo-DeviceInspectorActionText', 'Write-DeviceInspectorActionLog') {
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

    It 'refuses a device name that carries a path or a query' {
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
    }

    It 'shows the device count in the confirmation and makes Cancel the default button' {
        $script:strStart | Should -Match 'This action changes 1 device'
        $script:strStart | Should -Match 'x:Name="btnActionCancel"[^>]*IsCancel="True" IsDefault="True"'
        $script:strStart | Should -Not -Match 'x:Name="btnActionRun"[^>]*IsDefault'
    }
}
