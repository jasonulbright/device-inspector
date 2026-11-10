[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Test inputs are fake computer names.')]
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
                    [pscustomobject]@{ Name = '7-zip'; Version = '26.03'; Publisher = 'Igor Pavlov' }
                    [pscustomobject]@{ Name = 'Edge'; Version = '2.0'; Publisher = 'Microsoft' }
                    [pscustomobject]@{ Name = 'Device Only App'; Version = '3.0'; Publisher = 'Vendor' }
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
        $objInput.Errors | Should -Contain 'A site server needs a site code. Enter it in Options.'
    }

    It 'refuses a bad site server, a bad site code and a site code without a site server' {
        (Test-DeviceInspectorInput -ComputerName 'a' -SiteServer 'sms01;calc' -SiteCode 'ABC').IsValid | Should -BeFalse
        (Test-DeviceInspectorInput -ComputerName 'a' -SiteServer 'sms01' -SiteCode 'ABCD').IsValid | Should -BeFalse
        $objInput = Test-DeviceInspectorInput -ComputerName 'a' -SiteCode 'ABC'
        $objInput.IsValid | Should -BeFalse
        $objInput.Errors | Should -Contain 'A site code needs a site server.'
    }
}

Describe 'Panel rows' {
    BeforeAll {
        $script:objInspection = New-WindowTestInspection
    }

    It 'makes fact rows for the device, the client health and the site record' {
        $arrRow = @(ConvertTo-DeviceInspectionFactRow -Inspection $script:objInspection)
        @($arrRow | Where-Object { $_.Group -eq 'Operating system (device)' }).Count | Should -Be 3
        @($arrRow | Where-Object { $_.Group -eq 'Client health (device)' }).Count | Should -Be 6
        @($arrRow | Where-Object { $_.Group -eq 'Site record' }).Count | Should -Be 7
        @($arrRow | Where-Object { $_.Name -eq 'Service CcmExec' })[0].Value | Should -Be 'Running (start mode Auto)'
    }

    It 'says so in a fact row when the site has no record of the device' {
        $objNone = New-WindowTestInspection
        $objNone.Site = [pscustomobject]@{ Found = $false }
        $arrRow = @(ConvertTo-DeviceInspectionFactRow -Inspection $objNone)
        @($arrRow | Where-Object { $_.Group -eq 'Site record' })[0].Value | Should -Be 'The site has no record of this device.'
    }

    It 'merges the two application lists by name and sets a status for each' {
        $arrRow = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $script:objInspection)
        $arrRow.Count | Should -Be 4
        @($arrRow | Where-Object { $_.Name -eq '7-zip' -or $_.Name -eq '7-Zip' })[0].Status | Should -Be 'Match'
        @($arrRow | Where-Object { $_.Name -eq 'Edge' })[0].Status | Should -Be 'Version differs'
        @($arrRow | Where-Object { $_.Name -eq 'Device Only App' })[0].Status | Should -Be 'Device only'
        @($arrRow | Where-Object { $_.Name -eq 'Inventory Only App' })[0].Status | Should -Be 'Inventory only'
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
            }
            Mock Get-CMSoftwareUpdate {
                [pscustomobject]@{ CI_ID = 11; ArticleID = '5001'; LocalizedDisplayName = 'Live'; Severity = 10; IsExpired = $false; IsSuperseded = $false }
                [pscustomobject]@{ CI_ID = 12; ArticleID = '5002'; LocalizedDisplayName = 'Expired'; Severity = 8; IsExpired = $true; IsSuperseded = $true }
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
            $objSite = Get-SiteFact -ComputerName 'A' -Problems $listProblem
            $objSite.Found | Should -BeTrue
            @($objSite.RequiredUpdates).Count | Should -Be 0
            @($listProblem | Where-Object { $_ -like 'Site required updates:*compliance failed*' }).Count | Should -Be 1
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
        $strTopHeading = (Select-String -LiteralPath (Join-Path -Path $script:strRepositoryRoot -ChildPath 'CHANGELOG.md') -Pattern '^## \[([^\]]+)\]' | Select-Object -First 1).Matches[0].Groups[1].Value
        $strTopHeading | Should -Be $strManifestVersion
    }
}
