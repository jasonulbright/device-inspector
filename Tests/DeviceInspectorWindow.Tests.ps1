#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Test inputs are fake computer names.')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'The cut-out shell functions read these stand-in controls through scope.')]
param ()

BeforeAll {
    $strTestsFolder = Split-Path -Path $PSCommandPath -Parent
    $script:strRepositoryRoot = Split-Path -Path $strTestsFolder -Parent
    $script:strManifestPath = Join-Path -Path (Join-Path -Path $script:strRepositoryRoot -ChildPath 'Module') -ChildPath 'DeviceInspectorCommon.psd1'
    Import-Module -Name $script:strManifestPath -Force
    . (Join-Path -Path $strTestsFolder -ChildPath 'CMStubs.ps1')

    function New-WindowTestInspection {
        [pscustomobject]@{
            ComputerName = 'WS01'
            InspectedAt  = '2026-11-06T09:00:00Z'
            SiteServer   = 'sms01.example.com'
            SiteCode     = 'ABC'
            Site         = [pscustomobject]@{
                Found                 = $true
                ResourceId            = 16777221
                ClientInstalled       = $true
                ClientVersion         = '5.00.9146.1009'
                Active                = $true
                OperatingSystem       = 'Microsoft Windows NT Workstation 10.0'
                LastLogonUserName     = 'user'
                LastHardwareInventory = '2026-11-02T19:50:00Z'
                InstalledApplications = @(
                    [pscustomobject]@{ Name = '7-Zip'; Version = '26.03'; Publisher = 'Igor Pavlov' }
                    [pscustomobject]@{ Name = 'Edge'; Version = '1.0'; Publisher = 'Microsoft' }
                    [pscustomobject]@{ Name = 'Inventory Only App'; Version = '2.0'; Publisher = '' }
                )
                Collections           = @([pscustomobject]@{ CollectionId = 'SMS00001'; Name = 'All Systems' })
                Deployments           = @([pscustomobject]@{ DeploymentId = 'D1'; CollectionId = 'SMS00001'; CollectionName = 'All Systems'; Name = 'Example <App>'; Type = 'Application'; Intent = 'Available'; EnforcementDeadline = $null })
                RequiredUpdates       = @(
                    [pscustomobject]@{ CIId = 1; ArticleId = '5001'; Title = 'Cumulative update'; Severity = 'Critical'; IsSuperseded = $false }
                    [pscustomobject]@{ CIId = 2; ArticleId = ''; Title = 'Old update'; Severity = 'Low'; IsSuperseded = $true }
                )
            }
            Device       = [pscustomobject]@{
                Reachable             = $true
                OperatingSystem       = [pscustomobject]@{ Caption = 'Windows 11'; Version = '10.0.26200'; BuildNumber = '26200'; Architecture = '64-bit'; LastBootUp = '2026-11-05T02:50:41Z' }
                Client                = [pscustomobject]@{ ServiceState = 'Running'; ServiceStartMode = 'Auto'; Version = '5.00.9146.1009'; AssignedSiteCode = 'ABC'; CurrentManagementPoint = 'sms01.example.com'; LastHardwareInventoryCycle = '2026-11-03T00:50:53Z'; LastDiscoveryDataCycle = '2026-11-05T04:02:36Z' }
                InstalledApplications = @(
                    [pscustomobject]@{ Name = '7-zip'; Version = '26.03'; Publisher = 'Igor Pavlov'; InstallDate = '20261101'; KeyName = '{23170F69-40C1-2702-2600-000001000000}'; View = '64-bit'; UninstallString = 'MsiExec.exe /I{23170F69-40C1-2702-2600-000001000000}'; QuietUninstallString = ''; SystemComponent = 0; WindowsInstaller = 1 }
                    [pscustomobject]@{ Name = 'Edge'; Version = '2.0'; Publisher = 'Microsoft'; InstallDate = ''; KeyName = 'Edge'; View = '32-bit'; UninstallString = '"C:\Program Files\Edge\setup.exe" --uninstall'; QuietUninstallString = '"C:\Program Files\Edge\setup.exe" --uninstall --force'; SystemComponent = 0; WindowsInstaller = 0 }
                    [pscustomobject]@{ Name = 'Device Only App'; Version = '3.0'; Publisher = 'Vendor'; InstallDate = ''; KeyName = 'DeviceOnlyApp'; View = '64-bit'; UninstallString = 'C:\Vendor\unins000.exe'; QuietUninstallString = ''; SystemComponent = 0; WindowsInstaller = 0 }
                    [pscustomobject]@{ Name = 'Hidden Component'; Version = '1.0'; Publisher = 'Vendor'; InstallDate = ''; KeyName = '{11111111-2222-3333-4444-555555555555}'; View = '64-bit'; UninstallString = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}'; QuietUninstallString = ''; SystemComponent = 1; WindowsInstaller = 1 }
                )
                ClientApplications    = @()
                PendingUpdates        = @([pscustomobject]@{ Name = 'Cumulative update'; ArticleId = '5001'; EvaluationState = 1; State = 'Available'; Deadline = '2026-11-09T00:00:00Z' })
                Problems              = @()
            }
            Problems     = @('Device: example problem <b>')
        }
    }
}

AfterAll {
    Remove-Module -Name DeviceInspectorCommon -Force -ErrorAction SilentlyContinue
    Remove-CMTestStub
}

Describe 'Test-DeviceInspectorInput' {
    It 'accepts a device name with a site server and trims the text' {
        $objInput = Test-DeviceInspectorInput -ComputerName ' ws01 ' -SiteServer ' sms01.example.com ' -SiteCode ' ABC '
        $objInput.IsValid | Should -BeTrue
        $objInput.ComputerName | Should -Be 'ws01'
        $objInput.SiteServer | Should -Be 'sms01.example.com'
        $objInput.SiteCode | Should -Be 'ABC'
    }

    It 'accepts a device name alone, which means the device is read without the site' {
        (Test-DeviceInspectorInput -ComputerName 'ws01').IsValid | Should -BeTrue
    }

    It 'refuses an empty name and a name that carries a query or a path' {
        (Test-DeviceInspectorInput -ComputerName '').IsValid | Should -BeFalse
        (Test-DeviceInspectorInput -ComputerName "a' OR 1=1 --").IsValid | Should -BeFalse
        (Test-DeviceInspectorInput -ComputerName 'a\b').IsValid | Should -BeFalse
        (Test-DeviceInspectorInput -ComputerName '..').IsValid | Should -BeFalse
        (Test-DeviceInspectorInput -ComputerName '.hidden').IsValid | Should -BeFalse
    }

    It 'refuses a site server without a site code' {
        $objInput = Test-DeviceInspectorInput -ComputerName 'a' -SiteServer 'sms01'
        $objInput.IsValid | Should -BeFalse
        $objInput.Errors | Should -Contain 'An SMS Provider needs a site code. Enter it in Options.'
    }

    It 'refuses a bad site server, a bad site code and a site code without a site server' {
        (Test-DeviceInspectorInput -ComputerName 'a' -SiteServer 'sms01;calc' -SiteCode 'ABC').IsValid | Should -BeFalse
        (Test-DeviceInspectorInput -ComputerName 'a' -SiteServer 'sms01' -SiteCode 'ABCD').IsValid | Should -BeFalse
        $objInput = Test-DeviceInspectorInput -ComputerName 'a' -SiteCode 'ABC'
        $objInput.IsValid | Should -BeFalse
        $objInput.Errors | Should -Contain 'A site code needs an SMS Provider.'
    }
}

Describe 'Panel rows' {
    BeforeAll {
        $script:objInspection = New-WindowTestInspection
    }

    It 'makes rows for the device, the client health, the discovery data and the hardware inventory' {
        $arrRow = @(ConvertTo-DeviceInspectionFactRow -Inspection $script:objInspection)
        @($arrRow | Where-Object { $_.Group -eq 'Operating system (device)' }).Count | Should -Be 3
        @($arrRow | Where-Object { $_.Group -eq 'Client health (device)' }).Count | Should -Be 6
        @($arrRow | Where-Object { $_.Group -eq 'Discovery data and hardware inventory' }).Count | Should -Be 7
        @($arrRow | Where-Object { $_.Name -eq 'Service CcmExec' })[0].Value | Should -Be 'Running (start mode Auto)'
    }

    It 'says so in a fact row when the site does not know the device' {
        $objNone = New-WindowTestInspection
        $objNone.Site = [pscustomobject]@{ Found = $false }
        $arrRow = @(ConvertTo-DeviceInspectionFactRow -Inspection $objNone)
        @($arrRow | Where-Object { $_.Group -eq 'Discovery data and hardware inventory' })[0].Value | Should -Be 'The site does not know this device.'
    }

    It 'makes one application row for each uninstall key of the device, with no status and no inventory version' {
        $arrRow = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $script:objInspection)
        $arrRow.Count | Should -Be 4
        $arrRow[0].PSObject.Properties.Name | Should -Be @('Name', 'Version', 'Publisher', 'InstallDate', 'Type', 'View', 'KeyName', 'CanUninstall', 'CanRepair', 'Reason', 'UninstallReason', 'RepairReason', 'UninstallCommand', 'RepairCommand')
        @($arrRow | Where-Object { $_.Name -eq 'Inventory Only App' }).Count | Should -Be 0
        $objZip = @($arrRow | Where-Object { $_.Name -eq '7-zip' })[0]
        $objZip.Type | Should -Be 'MSI'
        $objZip.View | Should -Be '64-bit'
        $objZip.KeyName | Should -Be '{23170F69-40C1-2702-2600-000001000000}'
        $objZip.InstallDate | Should -Be '20261101'
    }

    It 'lists the site required updates and the device pending updates' {
        $arrRow = @(ConvertTo-DeviceInspectionUpdateRow -Inspection $script:objInspection)
        $arrRow.Count | Should -Be 3
        @($arrRow | Where-Object { $_.Source -eq 'Site' }).Count | Should -Be 2
        @($arrRow | Where-Object { $_.State -eq 'Required (superseded)' }).Count | Should -Be 1
        $objDevice = @($arrRow | Where-Object { $_.Source -eq 'Device' })[0]
        $objDevice.Article | Should -Be 'KB5001'
        $objDevice.State | Should -Be 'Available'
        $objDevice.Deadline | Should -Be '2026-11-09T00:00:00Z'
    }

    It 'returns no update row for an inspection that has no update facts' {
        $objOld = New-WindowTestInspection
        $objOld.Site.PSObject.Properties.Remove('RequiredUpdates')
        $objOld.Device.PSObject.Properties.Remove('PendingUpdates')
        @(ConvertTo-DeviceInspectionUpdateRow -Inspection $objOld).Count | Should -Be 0
    }

    It 'makes collection and deployment rows' {
        @(ConvertTo-DeviceInspectionCollectionRow -Inspection $script:objInspection)[0].Name | Should -Be 'All Systems'
        $objDeployment = @(ConvertTo-DeviceInspectionDeploymentRow -Inspection $script:objInspection)[0]
        $objDeployment.Intent | Should -Be 'Available'
        $objDeployment.Collection | Should -Be 'All Systems'
    }

    It 'returns no collection row when the site was not queried' {
        $objNoSite = New-WindowTestInspection
        $objNoSite.Site = $null
        @(ConvertTo-DeviceInspectionCollectionRow -Inspection $objNoSite).Count | Should -Be 0
        @(ConvertTo-DeviceInspectionDeploymentRow -Inspection $objNoSite).Count | Should -Be 0
    }
}

Describe 'Reports' {
    BeforeAll {
        $script:objInspection = New-WindowTestInspection
    }

    It 'adds the update sections to the text report' {
        $strReport = ConvertTo-DeviceInspectionReport -Inspection $script:objInspection
        $strReport | Should -BeLike '*== Updates required, site (2) ==*'
        $strReport | Should -BeLike '*== Updates pending, device (1) ==*'
        $strReport | Should -BeLike '*KB5001 | Available | Cumulative update*'
    }

    It 'returns JSON with LF line breaks that reads back to the same inspection' {
        $strJson = ConvertTo-DeviceInspectionJson -Inspection $script:objInspection
        $strJson | Should -Not -BeLike "*`r*"
        $strJson.EndsWith("`n") | Should -BeTrue
        ($strJson | ConvertFrom-Json).ComputerName | Should -Be 'WS01'
    }

    It 'returns an HTML page with encoded values, no script and no external resource' {
        $strHtml = ConvertTo-DeviceInspectionHtml -Inspection $script:objInspection
        $strHtml | Should -BeLike '<!DOCTYPE html>*'
        $strHtml | Should -BeLike '*Example &lt;App&gt;*'
        $strHtml | Should -BeLike '*Device: example problem &lt;b&gt;*'
        $strHtml | Should -Not -BeLike '*<b>*'
        $strHtml | Should -Not -BeLike '*<script*'
        $strHtml | Should -Not -BeLike '*http://*'
        $strHtml | Should -Not -BeLike '*https://*'
        $strHtml | Should -BeLike '*Installed applications (4)*'
        $strHtml | Should -BeLike '*Problems (1)*'
    }

    It 'writes a file as UTF-8 without a byte order mark and creates the folder' {
        $strPath = Join-Path -Path $TestDrive -ChildPath 'new\report.html'
        Write-DeviceInspectionFile -Path $strPath -Text 'abc' | Should -Be $strPath
        $arrByte = [System.IO.File]::ReadAllBytes($strPath)
        $arrByte[0] | Should -Be 97
        $arrByte.Count | Should -Be 3
    }
}

Describe 'Update facts' {
    It 'reads the updates that the site lists as required, without expired ones' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CMDevice { [pscustomobject]@{ ResourceID = 5; IsClient = $true; ClientVersion = '1'; IsActive = $true; DeviceOS = 'x'; LastLogonUser = 'u'; LastHardwareScan = $null } }
            Mock Invoke-SiteQuery {
                if ($Query -like '*SMS_UpdateComplianceStatus*') { [pscustomobject]@{ CI_ID = 11 }; [pscustomobject]@{ CI_ID = 12 } }
                if ($Query -like '*FROM SMS_SoftwareUpdate*') {
                    [pscustomobject]@{ CI_ID = 11; ArticleID = '5001'; LocalizedDisplayName = 'Live'; Severity = 10; IsExpired = $false; IsSuperseded = $false }
                    [pscustomobject]@{ CI_ID = 12; ArticleID = '5002'; LocalizedDisplayName = 'Expired'; Severity = 8; IsExpired = $true; IsSuperseded = $true }
                }
            }
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -ComputerName 'A' -Problems $listProblem
            @($objSite.RequiredUpdates).Count | Should -Be 1
            $objSite.RequiredUpdates[0].Title | Should -Be 'Live'
            $objSite.RequiredUpdates[0].Severity | Should -Be 'Critical'
            Should -Invoke Invoke-SiteQuery -ParameterFilter { $Query -like '*SMS_UpdateComplianceStatus*' -and $Query -like '*MachineID = 5*' } -Times 1 -Exactly
            $listProblem.Count | Should -Be 0
        }
    }

    It 'records a failed update query as a problem and keeps the other site facts' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CMDevice { [pscustomobject]@{ ResourceID = 5; IsClient = $true; ClientVersion = '1'; IsActive = $true; DeviceOS = 'x'; LastLogonUser = 'u'; LastHardwareScan = $null } }
            Mock Invoke-SiteQuery {
                if ($Query -like '*SMS_UpdateComplianceStatus*') { throw 'compliance failed' }
            }
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $listDetail = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -ComputerName 'A' -Problems $listProblem -ProblemDetail $listDetail
            $objSite.Found | Should -BeTrue
            @($objSite.RequiredUpdates).Count | Should -Be 0
            @($listProblem | Where-Object { $_ -eq 'Site required updates: the read failed. The log file has the reason.' }).Count | Should -Be 1
            @($listProblem | Where-Object { $_ -like '*compliance failed*' }).Count | Should -Be 0
            @($listDetail | Where-Object { $_ -like 'Site required updates:*compliance failed*' }).Count | Should -Be 1
        }
    }

    It 'maps the pending update states of the device to names' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-Command {
                [pscustomobject]@{
                    OperatingSystem       = $null
                    Client                = $null
                    InstalledApplications = @()
                    ClientApplications    = @()
                    PendingUpdates        = @(
                        [pscustomobject]@{ Name = 'U1'; ArticleId = '1'; EvaluationState = 7; Deadline = $null }
                        [pscustomobject]@{ Name = 'U2'; ArticleId = '2'; EvaluationState = 99; Deadline = '2026-11-09T00:00:00Z' }
                    )
                    Problems              = @()
                }
            }
            $objDevice = Get-DeviceFact -ComputerName 'WS01'
            $objDevice.PendingUpdates[0].State | Should -Be 'Installing'
            $objDevice.PendingUpdates[1].State | Should -Be 'State 99'
            $objDevice.PendingUpdates[1].Deadline | Should -Be '2026-11-09T00:00:00Z'
        }
    }

    It 'keeps an application whose evaluation time is missing' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-Command { [pscustomobject]@{ OperatingSystem = $null; Client = $null; InstalledApplications = @(); ClientApplications = @([pscustomobject]@{ Name = 'App'; InstallState = 'Installed'; EvaluationState = 1; LastEvaluation = $null }); Problems = @() } }
            @((Get-DeviceFact -ComputerName 'WS01').ClientApplications).Count | Should -Be 1
        }
    }

    It 'keeps working when the device returns no pending update list' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-Command { [pscustomobject]@{ OperatingSystem = $null; Client = $null; InstalledApplications = @(); ClientApplications = @(); Problems = @() } }
            @((Get-DeviceFact -ComputerName 'WS01').PendingUpdates).Count | Should -Be 0
        }
    }
}

Describe 'Window files' {
    BeforeAll {
        $script:strXamlPath = Join-Path -Path $script:strRepositoryRoot -ChildPath 'MainWindow.xaml'
        $script:strStartPath = Join-Path -Path $script:strRepositoryRoot -ChildPath 'start-deviceinspector.ps1'
    }

    It 'parses the window markup as XML' {
        { [xml](Get-Content -LiteralPath $script:strXamlPath -Raw) } | Should -Not -Throw
    }

    It 'has a control in the markup for every name the start script looks up' {
        $strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
        $arrDeclared = @([regex]::Matches($strXaml, 'x:Name="([A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
        $strStart = Get-Content -LiteralPath $script:strStartPath -Raw
        $arrLookup = @([regex]::Matches($strStart, "\`$window\.FindName\('([A-Za-z0-9_]+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $arrLookup.Count | Should -BeGreaterThan 20
        @($arrLookup | Where-Object { $arrDeclared -notcontains $_ }) | Should -BeNullOrEmpty
    }

    It 'declares every markup name only once' {
        $strXaml = Get-Content -LiteralPath $script:strXamlPath -Raw
        $arrDeclared = @([regex]::Matches($strXaml, 'x:Name="([A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
        @($arrDeclared | Group-Object | Where-Object { $_.Count -gt 1 }) | Should -BeNullOrEmpty
    }

    It 'parses the start script without error' {
        $arrError = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:strStartPath, [ref]$null, [ref]$arrError)
        $arrError.Count | Should -Be 0
    }

    It 'calls no command that changes the site or the device from the start script' {
        $arrForbidden = @(
            'Set-CimInstance', 'New-CimInstance', 'Remove-CimInstance', 'Invoke-CimMethod', 'Invoke-WmiMethod', 'Set-WmiInstance',
            'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Set-Service', 'Start-Service', 'Stop-Service',
            'Restart-Service', 'Stop-Process', 'Restart-Computer', 'Stop-Computer', 'Invoke-Command', 'Enter-PSSession'
        )
        $objAst = [System.Management.Automation.Language.Parser]::ParseFile($script:strStartPath, [ref]$null, [ref]$null)
        $arrCommand = @($objAst.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
        $arrCommand.Count | Should -BeGreaterThan 0
        @($arrCommand | Where-Object { $arrForbidden -contains $_ }) | Should -BeNullOrEmpty
    }

    It 'checks for the console module before it builds the window, and stops with a message' {
        $strText = Get-Content -LiteralPath $script:strStartPath -Raw
        $intCheck = $strText.IndexOf('Test-DeviceInspectorConsole')
        $intWindow = $strText.IndexOf('XamlReader]::Load')
        $intCheck | Should -BeGreaterThan 0
        $intCheck | Should -BeLessThan $intWindow
        $strText | Should -Match '(?s)if \(-not \$__console\.Available\) \{.*?MessageBox.*?exit 2'
    }

    It 'keeps the version equal in the manifest, the start script, the command line note and the top changelog heading' {
        $strManifestVersion = (Import-PowerShellDataFile -LiteralPath $script:strManifestPath).ModuleVersion
        (Get-Content -LiteralPath $script:strStartPath -Raw) | Should -Match ('(?m)^\s*Version\s*:\s*{0}\s*$' -f [regex]::Escape($strManifestVersion))
        (Get-Content -LiteralPath (Join-Path -Path $script:strRepositoryRoot -ChildPath 'Invoke-DeviceInspector.ps1') -Raw) | Should -Match ('(?m)^#\s*Version:\s*{0}\s*$' -f [regex]::Escape($strManifestVersion))
        $strTopHeading = (Select-String -LiteralPath (Join-Path -Path $script:strRepositoryRoot -ChildPath 'CHANGELOG.md') -Pattern '^## \[([^\]]+)\]' | Where-Object { $_.Matches[0].Groups[1].Value -ne 'Unreleased' } | Select-Object -First 1).Matches[0].Groups[1].Value
        $strTopHeading | Should -Be $strManifestVersion
    }
}

Describe 'Show-Inspection puts the inspection on the screen' {
    # Show-Inspection of the start script runs with real WPF controls that are not shown. The test reads the
    # rows that each grid holds and the text that the user sees. The script cannot be dot-sourced (it opens
    # the window), so each function is cut out of its syntax tree and defined here.
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework
        # WPF controls need an STA thread. Windows PowerShell and PowerShell 7 start in STA; a harness that starts MTA must add -STA.
        if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'These tests create WPF controls and need an STA thread. Start the host with -STA.' }
        # A column binds to a property by name. A renamed or missing property leaves the column blank, with no error.
        # The check reads the column bindings of the grid from MainWindow.xaml and looks for each name on the first row.
        [xml]$script:MainXaml = Get-Content -LiteralPath (Join-Path $script:strRepositoryRoot 'MainWindow.xaml') -Raw
        $script:MainXamlNs = New-Object System.Xml.XmlNamespaceManager($script:MainXaml.NameTable)
        $script:MainXamlNs.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
        $script:MainXamlNs.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        function Assert-GridBinding {
            param($Grid, [string]$GridName)
            $node = $script:MainXaml.SelectSingleNode(('//w:DataGrid[@x:Name=''{0}'']' -f $GridName), $script:MainXamlNs)
            if (-not $node) { throw "grid $GridName not found in MainWindow.xaml" }
            $columns = $node.SelectSingleNode('*[contains(local-name(), ''Columns'')]')
            $text = if ($columns) { $columns.OuterXml } else { '' }
            # One {Binding ...} body at a time (one level of nested braces). A binding to the item of another element is not a row property.
            $paths = @($(foreach ($m in [regex]::Matches($text, '\{Binding((?:[^{}]|\{[^{}]*\})*)\}')) {
                    $body = $m.Groups[1].Value
                    if ($body -match 'RelativeSource|ElementName|Source=') { continue }
                    if ($body -match '^\s*(?:Path=)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:[,}]|$)') { $Matches[1] }
                    elseif ($body -match 'Path=([A-Za-z_][A-Za-z0-9_]*)') { $Matches[1] }
                }) | Sort-Object -Unique)
            $paths.Count | Should -BeGreaterThan 0 -Because "the grid $GridName has bound columns"
            $Grid.Items.Count | Should -BeGreaterThan 0 -Because "the grid $GridName needs a row to check"
            # WPF binds by exact name, so the match is case-sensitive.
            $names = @($Grid.Items[0].PSObject.Properties.Name)
            foreach ($path in $paths) { ($names -ccontains $path) | Should -BeTrue -Because "a column of $GridName binds to $path" }
        }

        $objShowAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path -Path $script:strRepositoryRoot -ChildPath 'start-deviceinspector.ps1'), [ref]$null, [ref]$null)
        foreach ($strName in 'Show-Inspection', 'Update-AppFilter', 'Get-AppTypeFilter') {
            $objDef = $objShowAst.Find({ param($objNode) $objNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $objNode.Name -eq $strName }, $true)
            if (-not $objDef) { throw "function $strName not found in the script" }
            . ([scriptblock]::Create($objDef.Extent.Text))
        }
        function Update-ControlState { }
        function Update-StatusBarSummary { }
    }

    BeforeEach {
        $gridFacts = New-Object System.Windows.Controls.DataGrid
        $gridApps = New-Object System.Windows.Controls.DataGrid
        $gridUpdates = New-Object System.Windows.Controls.DataGrid
        $gridCollections = New-Object System.Windows.Controls.DataGrid
        $gridDeployments = New-Object System.Windows.Controls.DataGrid
        $txtProblems = New-Object System.Windows.Controls.TextBox
        $txtSummary = New-Object System.Windows.Controls.TextBlock
        $txtAppFilter = New-Object System.Windows.Controls.TextBox
        $cboAppType = New-Object System.Windows.Controls.ComboBox
        $btnViewProblems = New-Object System.Windows.Controls.Button
    }

    It 'fills every panel grid with the rows of the inspection' {
        $objInspection = New-WindowTestInspection
        Show-Inspection -Inspection $objInspection
        $gridFacts.Items.Count | Should -Be @(ConvertTo-DeviceInspectionFactRow -Inspection $objInspection).Count
        $gridFacts.Items.Count | Should -BeGreaterThan 10
        $gridApps.Items.Count | Should -Be 4
        $gridUpdates.Items.Count | Should -Be 3
        $gridCollections.Items.Count | Should -Be 1
        $gridDeployments.Items.Count | Should -Be 1
        $gridCollections.Items[0].Name | Should -Be 'All Systems'
        @($gridApps.Items | ForEach-Object Name) | Should -Contain '7-zip'
        Assert-GridBinding -Grid $gridFacts -GridName 'gridFacts'
        Assert-GridBinding -Grid $gridApps -GridName 'gridApps'
        Assert-GridBinding -Grid $gridUpdates -GridName 'gridUpdates'
        Assert-GridBinding -Grid $gridCollections -GridName 'gridCollections'
        Assert-GridBinding -Grid $gridDeployments -GridName 'gridDeployments'
    }

    It 'says what was found in the summary line, and lists the problems with the count on the button' {
        Show-Inspection -Inspection (New-WindowTestInspection)
        $txtSummary.Text | Should -Match 'Device WS01'
        $txtSummary.Text | Should -Match '4 applications'
        $txtSummary.Text | Should -Match '3 update rows'
        $txtSummary.Text | Should -Match '1 problems'
        $txtProblems.Text | Should -Be '- Device: example problem <b>'
        $btnViewProblems.Content | Should -Be 'Problems (1)'
    }

    It 'shows no problem line when every part of the inspection ran' {
        $objClean = New-WindowTestInspection
        $objClean.Problems = @()
        Show-Inspection -Inspection $objClean
        $txtProblems.Text | Should -Be 'No problems. Every part of the inspection ran.'
        $btnViewProblems.Content | Should -Be 'Problems'
    }

    It 'shows empty grids for a device that the site does not know and that has no update or application facts' {
        $objBare = New-WindowTestInspection
        # The site object of a device that the site does not know: Found is false and every other property is empty.
        foreach ($objProperty in @($objBare.Site.PSObject.Properties)) { $objProperty.Value = $null }
        $objBare.Site.Found = $false
        $objBare.Site.Collections = @()
        $objBare.Site.Deployments = @()
        $objBare.Site.RequiredUpdates = @()
        $objBare.Site.InstalledApplications = @()
        $objBare.Device.InstalledApplications = @()
        $objBare.Device.PendingUpdates = @()
        Show-Inspection -Inspection $objBare
        $gridApps.Items.Count | Should -Be 0
        $gridUpdates.Items.Count | Should -Be 0
        $gridCollections.Items.Count | Should -Be 0
        $gridDeployments.Items.Count | Should -Be 0
        $gridFacts.Items.Count | Should -BeGreaterThan 0
        $txtSummary.Text | Should -Match 'the site does not know the device'
    }

    It 'shows the one application row of a device that has exactly one (a single object is not a list)' {
        $objOne = New-WindowTestInspection
        $objOne.Device.InstalledApplications = @($objOne.Device.InstalledApplications[0])
        $objOne.Site.Collections = @($objOne.Site.Collections[0])
        { Show-Inspection -Inspection $objOne } | Should -Not -Throw
        $gridApps.Items.Count | Should -Be 1
        $gridCollections.Items.Count | Should -Be 1
    }

    It 'narrows the application grid with the filter text and shows all rows again when the text is cleared' {
        Show-Inspection -Inspection (New-WindowTestInspection)
        $txtAppFilter.Text = 'zip'
        Update-AppFilter
        $gridApps.Items.Count | Should -Be 1
        $gridApps.Items[0].Name | Should -Be '7-zip'
        $txtAppFilter.Text = ''
        Update-AppFilter
        $gridApps.Items.Count | Should -Be 4
    }

    It 'narrows the application grid with the type filter' {
        $objInspection = New-WindowTestInspection
        Show-Inspection -Inspection $objInspection
        $intMsi = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection | Where-Object { $_.Type -eq 'MSI' }).Count
        $intMsi | Should -BeGreaterThan 0
        $intMsi | Should -BeLessThan 4
        $objItem = New-Object System.Windows.Controls.ComboBoxItem
        $objItem.Content = 'MSI'
        [void]$cboAppType.Items.Add($objItem)
        $cboAppType.SelectedItem = $objItem
        Update-AppFilter
        $gridApps.Items.Count | Should -Be $intMsi
        @($gridApps.Items | Where-Object { $_.Type -ne 'MSI' }).Count | Should -Be 0
    }
}
