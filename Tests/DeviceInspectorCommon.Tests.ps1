[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Test inputs are fake device names.')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The test builds a dummy credential.')]
param ()

BeforeAll {
    $strRepositoryPath = Split-Path -Path $PSScriptRoot -Parent
    $strModuleFolder = Join-Path -Path $strRepositoryPath -ChildPath 'Module'
    $script:strModuleFile = Join-Path -Path $strModuleFolder -ChildPath 'DeviceInspectorCommon.psm1'
    $script:strScriptFile = Join-Path -Path $strRepositoryPath -ChildPath 'Invoke-DeviceInspector.ps1'
    Import-Module -Name (Join-Path -Path $strModuleFolder -ChildPath 'DeviceInspectorCommon.psd1') -Force
}

AfterAll {
    Remove-Module -Name DeviceInspectorCommon -Force -ErrorAction SilentlyContinue
}

Describe 'Read-only guarantee' {
    It 'calls no command that changes state' {
        # Arrange
        $arrForbidden = @(
            'Set-CimInstance', 'New-CimInstance', 'Remove-CimInstance', 'Invoke-CimMethod',
            'Invoke-WmiMethod', 'Set-WmiInstance', 'Remove-WmiObject',
            'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Remove-Item',
            'Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Copy-Item', 'Move-Item',
            'Set-Service', 'Start-Service', 'Stop-Service', 'Restart-Service',
            'Start-Process', 'Stop-Process', 'Restart-Computer', 'Stop-Computer',
            'Enable-PSRemoting', 'Set-Item', 'Clear-Content'
        )
        # Act
        $objAst = [System.Management.Automation.Language.Parser]::ParseFile($script:strModuleFile, [ref]$null, [ref]$null)
        $arrCommand = @($objAst.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
        # Assert
        $arrCommand.Count | Should -BeGreaterThan 0
        @($arrCommand | Where-Object { $arrForbidden -contains $_ }) | Should -BeNullOrEmpty
    }

    It 'sends only SELECT queries through the site query function' {
        InModuleScope DeviceInspectorCommon {
            { Invoke-SiteQuery -CimSession 'x' -SiteCode 'MCM' -Query 'DELETE FROM SMS_R_System' } | Should -Throw '*only SELECT*'
            { Invoke-SiteQuery -CimSession 'x' -SiteCode 'MCM' -Query "UPDATE SMS_R_System SET Name='a'" } | Should -Throw '*only SELECT*'
        }
    }

    It 'sends a SELECT query to the site namespace' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CimInstance { 'row' }
            $arrRow = @(Invoke-SiteQuery -CimSession 'x' -SiteCode 'MCM' -Query 'SELECT Name FROM SMS_R_System')
            $arrRow | Should -Be @('row')
            Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $Namespace -eq 'root\SMS\site_MCM' }
        }
    }
}

Describe 'ConvertTo-InspectionTimestamp' {
    It 'returns an ISO 8601 UTC string' {
        InModuleScope DeviceInspectorCommon {
            ConvertTo-InspectionTimestamp -Value ([datetime]::SpecifyKind([datetime]'2026-11-05T10:00:00', 'Utc')) | Should -Be '2026-11-05T10:00:00Z'
        }
    }

    It 'returns $null for $null' {
        InModuleScope DeviceInspectorCommon {
            ConvertTo-InspectionTimestamp -Value $null | Should -BeNullOrEmpty
        }
    }
}

Describe 'Deployment name mapping' {
    It 'maps known feature types' {
        InModuleScope DeviceInspectorCommon {
            ConvertTo-DeploymentTypeName -FeatureType 1 | Should -Be 'Application'
            ConvertTo-DeploymentTypeName -FeatureType 5 | Should -Be 'Software update'
            ConvertTo-DeploymentTypeName -FeatureType 7 | Should -Be 'Task sequence'
        }
    }

    It 'maps an unknown feature type' {
        InModuleScope DeviceInspectorCommon {
            ConvertTo-DeploymentTypeName -FeatureType 99 | Should -Be 'Other (99)'
        }
    }

    It 'maps known and unknown intents' {
        InModuleScope DeviceInspectorCommon {
            ConvertTo-DeploymentIntentName -DeploymentIntent 1 | Should -Be 'Required'
            ConvertTo-DeploymentIntentName -DeploymentIntent 2 | Should -Be 'Available'
            ConvertTo-DeploymentIntentName -DeploymentIntent 9 | Should -Be 'Other (9)'
        }
    }
}

Describe 'Select-ListedEntry' {
    It 'limits the list and counts the rest' {
        InModuleScope DeviceInspectorCommon {
            $arrShown = @(Select-ListedEntry -Entry @('a', 'b', 'c') -Maximum 2)
            $arrShown.Count | Should -Be 3
            $arrShown[0] | Should -Be 'a'
            $arrShown[2] | Should -BeLike '*1 more*'
        }
    }

    It 'shows (none) for an empty list' {
        InModuleScope DeviceInspectorCommon {
            $arrShown = @(Select-ListedEntry -Entry @() -Maximum 5)
            $arrShown.Count | Should -Be 1
            $arrShown[0] | Should -Be '  (none)'
        }
    }
}

Describe 'Get-SiteFact' {
    BeforeEach {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-SiteQuery {
                switch -Wildcard ($Query) {
                    '*FROM SMS_R_System*' {
                        [pscustomobject]@{ ResourceId = 16777221; Name = 'CLIENT01'; Client = 1; ClientVersion = '5.00.9146.1009'; Active = 1; OperatingSystemNameandVersion = 'Microsoft Windows NT Workstation 10.0'; LastLogonUserName = 'user' }
                    }
                    '*SMS_G_System_WORKSTATION_STATUS*' {
                        [pscustomobject]@{ LastHardwareScan = [datetime]::SpecifyKind([datetime]'2026-11-02T19:50:00', 'Utc') }
                    }
                    '*FROM SMS_G_System_ADD_REMOVE_PROGRAMS_64*' {
                        [pscustomobject]@{ DisplayName = '7-Zip'; Version = '26.03'; Publisher = 'Igor Pavlov' }
                    }
                    '*FROM SMS_G_System_ADD_REMOVE_PROGRAMS *' {
                        [pscustomobject]@{ DisplayName = 'Edge'; Version = '1'; Publisher = 'MS' }
                        [pscustomobject]@{ DisplayName = ''; Version = '1'; Publisher = 'MS' }
                    }
                    '*SMS_FullCollectionMembership*' {
                        [pscustomobject]@{ CollectionID = 'SMS00001' }
                        [pscustomobject]@{ CollectionID = 'MCM0001F' }
                        [pscustomobject]@{ CollectionID = "bad'id" }
                    }
                    '*FROM SMS_Collection*' {
                        [pscustomobject]@{ CollectionID = 'SMS00001'; Name = 'All Systems' }
                    }
                    '*SMS_DeploymentSummary*' {
                        [pscustomobject]@{ DeploymentID = 'D1'; CollectionID = 'MCM0001F'; CollectionName = 'Pilot'; SoftwareName = 'Contoso App'; FeatureType = 1; DeploymentIntent = 2; EnforcementDeadline = $null }
                    }
                }
            }
        }
    }

    It 'builds the site facts' {
        InModuleScope DeviceInspectorCommon {
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -CimSession 'x' -SiteCode 'MCM' -ComputerName 'CLIENT01' -Problems $listProblem
            $objSite.Found | Should -BeTrue
            $objSite.ResourceId | Should -Be 16777221
            $objSite.ClientInstalled | Should -BeTrue
            $objSite.LastHardwareInventory | Should -Be '2026-11-02T19:50:00Z'
            @($objSite.InstalledApplications).Count | Should -Be 2
            @($objSite.Collections).Count | Should -Be 2
            $objSite.Collections[0].Name | Should -BeNullOrEmpty
            @($objSite.Collections | Where-Object { $_.CollectionId -eq 'SMS00001' })[0].Name | Should -Be 'All Systems'
            @($objSite.Deployments).Count | Should -Be 1
            $objSite.Deployments[0].Type | Should -Be 'Application'
            $objSite.Deployments[0].Intent | Should -Be 'Available'
            $listProblem.Count | Should -Be 0
        }
    }

    It 'drops collection ids that are not 8 letters or digits' {
        InModuleScope DeviceInspectorCommon {
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $null = Get-SiteFact -CimSession 'x' -SiteCode 'MCM' -ComputerName 'CLIENT01' -Problems $listProblem
            Should -Invoke Invoke-SiteQuery -ParameterFilter { $Query -like '*bad*' } -Times 0 -Exactly
        }
    }

    It 'returns Found false when the site has no such device' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-SiteQuery { }
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -CimSession 'x' -SiteCode 'MCM' -ComputerName 'NOPE' -Problems $listProblem
            $objSite.Found | Should -BeFalse
            @($objSite.Collections).Count | Should -Be 0
        }
    }

    It 'records a failed part and continues with the other parts' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-SiteQuery {
                if ($Query -like '*SMS_FullCollectionMembership*') {
                    throw 'membership failed'
                }
                if ($Query -like '*FROM SMS_R_System*') {
                    [pscustomobject]@{ ResourceId = 1; Name = 'A'; Client = 0; ClientVersion = ''; Active = 0; OperatingSystemNameandVersion = ''; LastLogonUserName = '' }
                }
            }
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -CimSession 'x' -SiteCode 'MCM' -ComputerName 'A' -Problems $listProblem
            $objSite.Found | Should -BeTrue
            $objSite.ClientInstalled | Should -BeFalse
            @($listProblem | Where-Object { $_ -like '*membership failed*' }).Count | Should -Be 1
        }
    }

    It 'rejects a computer name with a quote' {
        InModuleScope DeviceInspectorCommon {
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            { Get-SiteFact -CimSession 'x' -SiteCode 'MCM' -ComputerName "a' OR 1=1 --" -Problems $listProblem } | Should -Throw
        }
    }
}

Describe 'Get-DeviceInspection' {
    BeforeEach {
        InModuleScope DeviceInspectorCommon {
            Mock New-CimSession { 'session' }
            Mock Remove-CimSession { }
            Mock Get-CimInstance { [pscustomobject]@{ SiteCode = 'MCM' } }
            Mock Get-SiteFact { [pscustomobject]@{ Found = $true; ResourceId = 1; ClientInstalled = $true; ClientVersion = '1'; Active = $true; OperatingSystem = 'os'; LastLogonUserName = ''; LastHardwareInventory = $null; InstalledApplications = @(); Collections = @(); Deployments = @() } }
            Mock Get-DeviceFact { [pscustomobject]@{ Reachable = $true; OperatingSystem = $null; Client = $null; InstalledApplications = @(); ClientApplications = @(); Problems = @('Operating system: boom') } }
        }
    }

    It 'combines site and device facts and prefixes device problems' {
        InModuleScope DeviceInspectorCommon {
            $objInspection = Get-DeviceInspection -ComputerName 'client01.contoso.com' -SiteServer 'cm01'
            $objInspection.SiteCode | Should -Be 'MCM'
            $objInspection.Site.Found | Should -BeTrue
            $objInspection.Device.Reachable | Should -BeTrue
            $objInspection.Problems | Should -Contain 'Device: Operating system: boom'
            Should -Invoke Get-SiteFact -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'client01' }
            Should -Invoke Remove-CimSession -Times 1 -Exactly
        }
    }

    It 'skips the device with SkipDevice' {
        InModuleScope DeviceInspectorCommon {
            $objInspection = Get-DeviceInspection -ComputerName 'CLIENT01' -SiteServer 'cm01' -SkipDevice
            $objInspection.Device | Should -BeNullOrEmpty
            Should -Invoke Get-DeviceFact -Times 0 -Exactly
        }
    }

    It 'skips the site without SiteServer' {
        InModuleScope DeviceInspectorCommon {
            $objInspection = Get-DeviceInspection -ComputerName 'CLIENT01'
            $objInspection.Site | Should -BeNullOrEmpty
            $objInspection.SiteServer | Should -BeNullOrEmpty
            Should -Invoke New-CimSession -Times 0 -Exactly
        }
    }

    It 'throws when there is nothing to inspect' {
        InModuleScope DeviceInspectorCommon {
            { Get-DeviceInspection -ComputerName 'CLIENT01' -SkipDevice } | Should -Throw '*Nothing to inspect*'
        }
    }

    It 'records a site connection failure and still inspects the device' {
        InModuleScope DeviceInspectorCommon {
            Mock New-CimSession { throw 'no route' }
            $objInspection = Get-DeviceInspection -ComputerName 'CLIENT01' -SiteServer 'cm01'
            $objInspection.Site | Should -BeNullOrEmpty
            $objInspection.Problems | Should -Contain 'Site: no route'
            $objInspection.Device.Reachable | Should -BeTrue
        }
    }

    It 'records a device failure and keeps the site facts' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-DeviceFact { throw 'WinRM failed' }
            $objInspection = Get-DeviceInspection -ComputerName 'CLIENT01' -SiteServer 'cm01'
            $objInspection.Device | Should -BeNullOrEmpty
            $objInspection.Site.Found | Should -BeTrue
            $objInspection.Problems | Should -Contain 'Device: WinRM failed'
        }
    }

    It 'uses the SiteCode parameter and skips the provider lookup' {
        InModuleScope DeviceInspectorCommon {
            $null = Get-DeviceInspection -ComputerName 'CLIENT01' -SiteServer 'cm01' -SiteCode 'ABC' -SkipDevice
            Should -Invoke Get-CimInstance -Times 0 -Exactly
            Should -Invoke Get-SiteFact -Times 1 -Exactly -ParameterFilter { $SiteCode -eq 'ABC' }
        }
    }

    It 'reports a missing device record as a problem' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-SiteFact { [pscustomobject]@{ Found = $false } }
            $objInspection = Get-DeviceInspection -ComputerName 'NOPE' -SiteServer 'cm01' -SkipDevice
            $objInspection.Problems | Should -Contain 'Site: no device named NOPE exists in site MCM.'
        }
    }

    It 'rejects an invalid computer name' {
        { Get-DeviceInspection -ComputerName "bad name'" -SiteServer 'cm01' } | Should -Throw
    }
}

Describe 'Get-DeviceFact' {
    It 'returns the remote result and passes the credential' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-Command {
                [pscustomobject]@{ OperatingSystem = 'os'; Client = 'client'; InstalledApplications = @('a'); ClientApplications = @(); Problems = @() }
            }
            $objCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'u', (ConvertTo-SecureString -String 'p' -AsPlainText -Force)
            $objDevice = Get-DeviceFact -ComputerName 'CLIENT01' -Credential $objCredential
            $objDevice.Reachable | Should -BeTrue
            $objDevice.OperatingSystem | Should -Be 'os'
            Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'CLIENT01' -and $null -ne $Credential }
        }
    }

    It 'passes no credential when none is given' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-Command {
                [pscustomobject]@{ OperatingSystem = $null; Client = $null; InstalledApplications = @(); ClientApplications = @(); Problems = @() }
            }
            $null = Get-DeviceFact -ComputerName 'CLIENT01'
            Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { $null -eq $Credential }
        }
    }

    It 'runs a remote block that parses and holds no write verbs' {
        InModuleScope DeviceInspectorCommon {
            $script:scriptBlockSeen = $null
            Mock Invoke-Command {
                $script:scriptBlockSeen = $ScriptBlock
                [pscustomobject]@{ OperatingSystem = $null; Client = $null; InstalledApplications = @(); ClientApplications = @(); Problems = @() }
            }
            $null = Get-DeviceFact -ComputerName 'CLIENT01'
            $script:scriptBlockSeen | Should -BeOfType [scriptblock]
            $script:scriptBlockSeen.ToString() | Should -Not -Match '(Set|Remove|New|Start|Stop|Restart)-(Item|CimInstance|Service|ItemProperty)'
        }
    }
}

Describe 'ConvertTo-DeviceInspectionReport' {
    BeforeAll {
        $script:objFull = [pscustomobject]@{
            ComputerName = 'CLIENT01'
            InspectedAt  = '2026-11-05T10:00:00Z'
            SiteServer   = 'cm01'
            SiteCode     = 'MCM'
            Site         = [pscustomobject]@{
                Found                 = $true
                ResourceId            = 5
                ClientInstalled       = $true
                ClientVersion         = '5.0'
                Active                = $true
                OperatingSystem       = 'Windows NT'
                LastHardwareInventory = '2026-11-02T19:50:00Z'
                InstalledApplications = @([pscustomobject]@{ Name = 'SiteApp'; Version = '1'; Publisher = 'p' })
                Collections           = @([pscustomobject]@{ CollectionId = 'SMS00001'; Name = 'All Systems' })
                Deployments           = @([pscustomobject]@{ Name = 'Contoso App'; Type = 'Application'; Intent = 'Required'; CollectionName = 'Pilot' })
            }
            Device       = [pscustomobject]@{
                Reachable             = $true
                OperatingSystem       = [pscustomobject]@{ Caption = 'Windows 11'; Version = '10.0.26200'; BuildNumber = '26200'; Architecture = '64-bit'; LastBootUp = '2026-11-05T02:50:41Z' }
                Client                = [pscustomobject]@{ ServiceState = 'Running'; ServiceStartMode = 'Auto'; Version = '5.0'; AssignedSiteCode = 'MCM'; CurrentManagementPoint = 'cm01'; LastHardwareInventoryCycle = '2026-11-02T19:50:53Z'; LastDiscoveryDataCycle = '2026-11-04T23:02:36Z' }
                InstalledApplications = @([pscustomobject]@{ Name = 'DeviceApp'; Version = '2'; Publisher = 'p' })
                ClientApplications    = @([pscustomobject]@{ Name = 'PolicyApp'; InstallState = 'NotInstalled'; EvaluationState = 3; LastEvaluation = '2026-11-04T21:53:26Z' })
            }
            Problems     = @('Site: example problem')
        }
    }

    It 'prints every section' {
        $strReport = ConvertTo-DeviceInspectionReport -Inspection $script:objFull
        $strReport | Should -BeLike '*Device Inspector report: CLIENT01*'
        $strReport | Should -BeLike '*Caption:      Windows 11*'
        $strReport | Should -BeLike '*Service CcmExec:           Running*'
        $strReport | Should -BeLike '*Resource ID:               5*'
        $strReport | Should -BeLike '*SMS00001  All Systems*'
        $strReport | Should -BeLike '*Contoso App | Application | Required | via Pilot*'
        $strReport | Should -BeLike '*DeviceApp 2*'
        $strReport | Should -BeLike '*SiteApp 1*'
        $strReport | Should -BeLike '*PolicyApp | NotInstalled | evaluation state 3*'
        $strReport | Should -BeLike '*Site: example problem*'
    }

    It 'accepts pipeline input' {
        $strReport = $script:objFull | ConvertTo-DeviceInspectionReport
        $strReport | Should -BeLike '*CLIENT01*'
    }

    It 'prints No data for skipped parts' {
        $objSkipped = [pscustomobject]@{ ComputerName = 'X'; InspectedAt = 't'; SiteServer = $null; SiteCode = $null; Site = $null; Device = $null; Problems = @() }
        $strReport = ConvertTo-DeviceInspectionReport -Inspection $objSkipped
        $strReport | Should -BeLike '*Site server: not queried*'
        $strReport | Should -BeLike '*No data.*'
        $strReport | Should -BeLike '*== Problems (0) ==*'
    }

    It 'says when the site has no record' {
        $objMissing = [pscustomobject]@{ ComputerName = 'X'; InspectedAt = 't'; SiteServer = 's'; SiteCode = 'MCM'; Site = [pscustomobject]@{ Found = $false }; Device = $null; Problems = @() }
        ConvertTo-DeviceInspectionReport -Inspection $objMissing | Should -BeLike '*The site has no record of this device.*'
    }

    It 'limits long lists' {
        $objMany = $script:objFull.PSObject.Copy()
        $objMany.Device = [pscustomobject]@{
            Reachable             = $true
            OperatingSystem       = $null
            Client                = $null
            InstalledApplications = @(1..10 | ForEach-Object { [pscustomobject]@{ Name = ('App{0}' -f $_); Version = '1'; Publisher = '' } })
            ClientApplications    = @()
        }
        $strReport = ConvertTo-DeviceInspectionReport -Inspection $objMany -MaximumListedItems 3
        $strReport | Should -BeLike '*... 7 more*'
        $strReport | Should -Not -BeLike '*App10*'
    }
}

Describe 'Invoke-DeviceInspector.ps1' {
    It 'prints the report and writes JSON without a byte order mark' {
        $strJsonPath = Join-Path -Path $TestDrive -ChildPath 'out.json'
        $arrOutput = @(& $script:strScriptFile -ComputerName 'CLIENT01' -SiteServer 'nonexistent.invalid' -SkipDevice -JsonPath $strJsonPath)
        $arrOutput.Count | Should -Be 1
        $arrOutput[0] | Should -BeLike '*Device Inspector report: CLIENT01*'
        $arrByte = [System.IO.File]::ReadAllBytes($strJsonPath)
        $arrByte[0] | Should -Be 123
        $objJson = [System.IO.File]::ReadAllText($strJsonPath) | ConvertFrom-Json
        $objJson.ComputerName | Should -Be 'CLIENT01'
        @($objJson.Problems | Where-Object { $_ -like 'Site:*' }).Count | Should -Be 1
    }

    It 'stops with one error and exit code 1 for a device name that is not valid' {
        $strHost = (Get-Process -Id $PID).Path
        $strErrorFile = Join-Path -Path $TestDrive -ChildPath 'error.txt'
        $strOutFile = Join-Path -Path $TestDrive -ChildPath 'out.txt'
        $arrArgument = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:strScriptFile), '-ComputerName', '"bad name!"')
        $objProcess = Start-Process -FilePath $strHost -ArgumentList $arrArgument -Wait -PassThru -NoNewWindow -RedirectStandardError $strErrorFile -RedirectStandardOutput $strOutFile
        $objProcess.ExitCode | Should -Be 1
        $strError = Get-Content -LiteralPath $strErrorFile -Raw
        $strError | Should -BeLike '*does not match*'
        $strError | Should -Not -BeLike '*ConvertTo-DeviceInspectionReport*'
    }

    It 'parses without error' {
        $arrError = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:strScriptFile, [ref]$null, [ref]$arrError)
        $arrError.Count | Should -Be 0
    }

    It 'declares help for every parameter' {
        $objHelp = Get-Help -Name $script:strScriptFile -Full
        $objHelp.Synopsis | Should -Not -BeNullOrEmpty
        foreach ($objParameter in @($objHelp.parameters.parameter)) {
            $objParameter.description | Should -Not -BeNullOrEmpty -Because $objParameter.name
        }
    }
}

Describe 'Module surface' {
    It 'exports the documented public functions' {
        $arrExported = @((Get-Module -Name DeviceInspectorCommon).ExportedFunctions.Keys | Sort-Object)
        $arrExported | Should -Be @(
            'ConvertTo-DeviceInspectionApplicationRow', 'ConvertTo-DeviceInspectionCollectionRow', 'ConvertTo-DeviceInspectionDeploymentRow',
            'ConvertTo-DeviceInspectionFactRow', 'ConvertTo-DeviceInspectionHtml', 'ConvertTo-DeviceInspectionJson',
            'ConvertTo-DeviceInspectionReport', 'ConvertTo-DeviceInspectionUpdateRow', 'Get-DeviceInspection',
            'Test-DeviceInspectorInput', 'Write-DeviceInspectionFile'
        )
    }

    It 'has comment-based help with an example on every public function' {
        foreach ($strName in (Get-Module -Name DeviceInspectorCommon).ExportedFunctions.Keys) {
            $objHelp = Get-Help -Name $strName -Full
            $objHelp.Synopsis | Should -Not -BeNullOrEmpty -Because $strName
            @($objHelp.examples.example).Count | Should -BeGreaterThan 0 -Because $strName
        }
    }

    It 'has a valid manifest' {
        $strManifest = Join-Path -Path (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Module') -ChildPath 'DeviceInspectorCommon.psd1'
        { Test-ModuleManifest -Path $strManifest } | Should -Not -Throw
    }
}