[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Test inputs are fake device names.')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The test builds a dummy credential.')]
param ()

BeforeAll {
    $strRepositoryPath = Split-Path -Path $PSScriptRoot -Parent
    $strModuleFolder = Join-Path -Path $strRepositoryPath -ChildPath 'Module'
    $script:strModuleFile = Join-Path -Path $strModuleFolder -ChildPath 'DeviceInspectorCommon.psm1'
    $script:strScriptFile = Join-Path -Path $strRepositoryPath -ChildPath 'Invoke-DeviceInspector.ps1'
    Import-Module -Name (Join-Path -Path $strModuleFolder -ChildPath 'DeviceInspectorCommon.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'CMStubs.ps1')
}

AfterAll {
    Remove-Module -Name DeviceInspectorCommon -Force -ErrorAction SilentlyContinue
    Remove-CMTestStub
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
            { Invoke-SiteQuery -Query 'DELETE FROM SMS_R_System' } | Should -Throw
            { Invoke-SiteQuery -Query "UPDATE SMS_R_System SET Name='a'" } | Should -Throw
        }
    }

    It 'sends a SELECT query with Invoke-CMWmiQuery' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-CMWmiQuery { 'row' }
            $arrRow = @(Invoke-SiteQuery -Query 'SELECT Name FROM SMS_R_System')
            $arrRow | Should -Be @('row')
            Should -Invoke Invoke-CMWmiQuery -Times 1 -Exactly -ParameterFilter { $Query -eq 'SELECT Name FROM SMS_R_System' }
        }
    }

    It 'reads the site with no CIM command' {
        $objAst = [System.Management.Automation.Language.Parser]::ParseFile($script:strModuleFile, [ref]$null, [ref]$null)
        $arrFunction = @($objAst.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $objNode.Name -in @('Get-SiteFact', 'Invoke-SiteQuery', 'Connect-InspectorSite', 'Get-DeviceInspection') }, $true))
        $arrFunction.Count | Should -Be 4
        foreach ($objFunction in $arrFunction) {
            $arrCommand = @($objFunction.FindAll({ param($objNode) $objNode -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $null -ne $_ })
            @($arrCommand | Where-Object { $_ -match 'Cim|Wmi' -and $_ -ne 'Invoke-CMWmiQuery' }) | Should -BeNullOrEmpty -Because $objFunction.Name
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

    It 'reads a value without a zone as UTC, as the site cmdlets return the inventory dates' {
        InModuleScope DeviceInspectorCommon {
            ConvertTo-InspectionTimestamp -Value ([datetime]::SpecifyKind([datetime]'2026-11-05T17:41:51', 'Unspecified')) | Should -Be '2026-11-05T17:41:51Z'
        }
    }
}

Describe 'ConvertTo-InspectionDeploymentTime' {
    It 'writes a deadline without a zone as the local time that the site stores' {
        InModuleScope DeviceInspectorCommon {
            ConvertTo-InspectionDeploymentTime -Value ([datetime]::SpecifyKind([datetime]'2026-12-04T17:00:00', 'Unspecified')) | Should -Be '2026-12-04T17:00:00'
        }
    }

    It 'writes a value with a zone as UTC' {
        InModuleScope DeviceInspectorCommon {
            ConvertTo-InspectionDeploymentTime -Value ([datetime]::SpecifyKind([datetime]'2026-12-04T17:00:00', 'Utc')) | Should -Be '2026-12-04T17:00:00Z'
            ConvertTo-InspectionDeploymentTime -Value $null | Should -BeNullOrEmpty
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
            Mock Get-CMDevice {
                [pscustomobject]@{ ResourceID = 16777221; Name = 'WS01'; IsClient = $true; ClientVersion = '5.00.9146.1009'; IsActive = $true; DeviceOS = 'Microsoft Windows NT Workstation 10.0'; LastLogonUser = 'user'; LastHardwareScan = [datetime]::SpecifyKind([datetime]'2026-11-02T19:50:00', 'Utc') }
            }
            Mock Invoke-SiteQuery {
                switch -Wildcard ($Query) {
                    '*FROM SMS_G_System_ADD_REMOVE_PROGRAMS_64*' {
                        [pscustomobject]@{ DisplayName = '7-Zip'; Version = '26.03'; Publisher = 'Igor Pavlov' }
                    }
                    '*FROM SMS_G_System_ADD_REMOVE_PROGRAMS *' {
                        [pscustomobject]@{ DisplayName = 'Edge'; Version = '1'; Publisher = 'MS' }
                        [pscustomobject]@{ DisplayName = ''; Version = '1'; Publisher = 'MS' }
                    }
                    '*SMS_FullCollectionMembership*' {
                        [pscustomobject]@{ CollectionID = 'SMS00001' }
                        [pscustomobject]@{ CollectionID = 'XYZ0001F' }
                        [pscustomobject]@{ CollectionID = "bad'id" }
                    }
                    '*SMS_UpdateComplianceStatus*' {
                        [pscustomobject]@{ CI_ID = 101 }
                        [pscustomobject]@{ CI_ID = 102 }
                    }
                }
            }
            Mock Get-CMDeviceCollection {
                [pscustomobject]@{ CollectionID = 'SMS00001'; Name = 'All Systems' }
                [pscustomobject]@{ CollectionID = 'XYZ0001F'; Name = 'Pilot' }
                [pscustomobject]@{ CollectionID = 'ZZZ00000'; Name = 'Not a collection of the device' }
            }
            Mock Get-CMDeployment {
                [pscustomobject]@{ DeploymentID = 'D1'; CollectionID = 'XYZ0001F'; CollectionName = 'Pilot'; SoftwareName = 'Example App'; FeatureType = 1; DeploymentIntent = 2; EnforcementDeadline = [datetime]::SpecifyKind([datetime]'2026-12-04T17:00:00', 'Unspecified') }
                [pscustomobject]@{ DeploymentID = 'D2'; CollectionID = 'OTHER001'; CollectionName = 'Other'; SoftwareName = 'Deployment to another collection'; FeatureType = 1; DeploymentIntent = 2; EnforcementDeadline = $null }
            }
            Mock Get-CMSoftwareUpdate {
                [pscustomobject]@{ CI_ID = 101; ArticleID = '5001'; LocalizedDisplayName = 'Update B'; Severity = 8; IsExpired = $false; IsSuperseded = $true }
                [pscustomobject]@{ CI_ID = 102; ArticleID = '5002'; LocalizedDisplayName = 'Update A expired'; Severity = 10; IsExpired = $true; IsSuperseded = $false }
                [pscustomobject]@{ CI_ID = 999; ArticleID = '5999'; LocalizedDisplayName = 'Not needed by the device'; Severity = 10; IsExpired = $false; IsSuperseded = $false }
            }
        }
    }

    It 'builds the site facts' {
        InModuleScope DeviceInspectorCommon {
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -ComputerName 'WS01' -Problems $listProblem
            $objSite.Found | Should -BeTrue
            $objSite.ResourceId | Should -Be 16777221
            $objSite.ClientInstalled | Should -BeTrue
            $objSite.ClientVersion | Should -Be '5.00.9146.1009'
            $objSite.Active | Should -BeTrue
            $objSite.OperatingSystem | Should -Be 'Microsoft Windows NT Workstation 10.0'
            $objSite.LastLogonUserName | Should -Be 'user'
            $objSite.LastHardwareInventory | Should -Be '2026-11-02T19:50:00Z'
            @($objSite.InstalledApplications).Count | Should -Be 2
            @($objSite.Collections).Count | Should -Be 2
            @($objSite.Collections | Where-Object { $_.CollectionId -eq 'SMS00001' })[0].Name | Should -Be 'All Systems'
            @($objSite.Deployments).Count | Should -Be 1
            $objSite.Deployments[0].Type | Should -Be 'Application'
            $objSite.Deployments[0].Intent | Should -Be 'Available'
            $objSite.Deployments[0].EnforcementDeadline | Should -Be '2026-12-04T17:00:00'
            @($objSite.RequiredUpdates).Count | Should -Be 1
            $objSite.RequiredUpdates[0].Title | Should -Be 'Update B'
            $objSite.RequiredUpdates[0].Severity | Should -Be 'Important'
            $objSite.RequiredUpdates[0].IsSuperseded | Should -BeTrue
            $listProblem.Count | Should -Be 0
        }
    }

    It 'reads the device record with Get-CMDevice by exact name' {
        InModuleScope DeviceInspectorCommon {
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $null = Get-SiteFact -ComputerName 'WS01' -Problems $listProblem
            Should -Invoke Get-CMDevice -Times 1 -Exactly -ParameterFilter { $Name -eq 'WS01' -and $DisableWildcardHandling }
        }
    }

    It 'reads collections, deployments and updates with one cmdlet call each' {
        InModuleScope DeviceInspectorCommon {
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $null = Get-SiteFact -ComputerName 'WS01' -Problems $listProblem
            Should -Invoke Get-CMDeviceCollection -Times 1 -Exactly
            Should -Invoke Get-CMDeployment -Times 1 -Exactly
            Should -Invoke Get-CMSoftwareUpdate -Times 1 -Exactly
        }
    }

    It 'uses a query only for the three reads that have no cmdlet' {        InModuleScope DeviceInspectorCommon {
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $null = Get-SiteFact -ComputerName 'WS01' -Problems $listProblem
            Should -Invoke Invoke-SiteQuery -Times 4 -Exactly
            Should -Invoke Invoke-SiteQuery -Times 0 -Exactly -ParameterFilter { $Query -like '*SMS_R_System*' -or $Query -like '*SMS_DeploymentSummary*' -or $Query -like '*FROM SMS_SoftwareUpdate*' -or $Query -like '*FROM SMS_Collection *' }
        }
    }

    It 'reports collection names that cannot be read as a problem and still lists the IDs' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CMDeviceCollection { throw 'name lookup failed' }
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -ComputerName 'WS01' -Problems $listProblem
            @($objSite.Collections).Count | Should -Be 2
            $objSite.Collections[0].Name | Should -BeNullOrEmpty
            @($listProblem | Where-Object { $_ -like 'Site collection names:*name lookup failed*' }).Count | Should -Be 1
        }
    }

    It 'drops collection ids that are not 8 letters or digits' {
        InModuleScope DeviceInspectorCommon {
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $null = Get-SiteFact -ComputerName 'WS01' -Problems $listProblem
            $objSite = Get-SiteFact -ComputerName 'WS01' -Problems $listProblem
            @($objSite.Collections | Where-Object { $_.CollectionId -like '*bad*' }).Count | Should -Be 0
        }
    }

    It 'returns Found false when the site has no such device' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CMDevice { }
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -ComputerName 'NOPE' -Problems $listProblem
            $objSite.Found | Should -BeFalse
            @($objSite.Collections).Count | Should -Be 0
        }
    }

    It 'uses the first record when several share the name, and says so' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-CMDevice {
                [pscustomobject]@{ ResourceID = 1; IsClient = $false; ClientVersion = ''; IsActive = $false; DeviceOS = ''; LastLogonUser = ''; LastHardwareScan = $null }
                [pscustomobject]@{ ResourceID = 2; IsClient = $false; ClientVersion = ''; IsActive = $false; DeviceOS = ''; LastLogonUser = ''; LastHardwareScan = $null }
            }
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -ComputerName 'DUP' -Problems $listProblem
            $objSite.ResourceId | Should -Be 1
            @($listProblem | Where-Object { $_ -like 'Site: 2 resource records share the name DUP*' }).Count | Should -Be 1
        }
    }

    It 'records a failed part and continues with the other parts' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-SiteQuery {
                if ($Query -like '*SMS_FullCollectionMembership*') {
                    throw 'membership failed'
                }
            }
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $objSite = Get-SiteFact -ComputerName 'A' -Problems $listProblem
            $objSite.Found | Should -BeTrue
            $objSite.ClientInstalled | Should -BeTrue
            @($listProblem | Where-Object { $_ -like '*membership failed*' }).Count | Should -Be 1
        }
    }

    It 'rejects a computer name with a quote' {
        InModuleScope DeviceInspectorCommon {
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            { Get-SiteFact -ComputerName "a' OR 1=1 --" -Problems $listProblem } | Should -Throw
        }
    }
}

Describe 'Test-DeviceInspectorConsole' {
    It 'reports a missing console with a plain message' {
        Mock -ModuleName DeviceInspectorCommon Resolve-ConfigurationManagerModulePath { $null }
        $objCheck = Test-DeviceInspectorConsole
        $objCheck.Available | Should -BeFalse
        $objCheck.Message | Should -BeLike 'The Configuration Manager console is not installed on this computer.*'
        $objCheck.Message | Should -Not -Match 'Exception|Cannot|Import-Module'
    }

    It 'reports the module path when the console is installed' {
        Mock -ModuleName DeviceInspectorCommon Resolve-ConfigurationManagerModulePath { 'C:\Console\bin\ConfigurationManager.psd1' }
        $objCheck = Test-DeviceInspectorConsole
        $objCheck.Available | Should -BeTrue
        $objCheck.Path | Should -Be 'C:\Console\bin\ConfigurationManager.psd1'
    }
}

Describe 'Connect-InspectorSite and Disconnect-InspectorSite' {
    It 'stops with the plain console message when the module is missing' {
        Mock -ModuleName DeviceInspectorCommon Resolve-ConfigurationManagerModulePath { $null }
        Mock -ModuleName DeviceInspectorCommon New-PSDrive { }
        { InModuleScope DeviceInspectorCommon { Connect-InspectorSite -SiteServer 'sms01' -SiteCode 'XYZ' } } | Should -Throw 'The Configuration Manager console is not installed on this computer.*'
        Should -Invoke -ModuleName DeviceInspectorCommon New-PSDrive -Times 0 -Scope It
    }

    It 'creates the site drive, enters it and verifies the site' {
        Mock -ModuleName DeviceInspectorCommon Resolve-ConfigurationManagerModulePath { 'C:\Console\bin\ConfigurationManager.psd1' }
        Mock -ModuleName DeviceInspectorCommon Get-Module { [pscustomobject]@{ Name = 'ConfigurationManager' } }
        Mock -ModuleName DeviceInspectorCommon Get-PSDrive { }
        Mock -ModuleName DeviceInspectorCommon New-PSDrive { }
        Mock -ModuleName DeviceInspectorCommon Set-Location { }
        Mock -ModuleName DeviceInspectorCommon Get-CMSite { [pscustomobject]@{ SiteCode = 'XYZ' } }
        $objConnection = InModuleScope DeviceInspectorCommon { Connect-InspectorSite -SiteServer 'sms01' -SiteCode 'XYZ' }
        $objConnection.CreatedDrive | Should -BeTrue
        Should -Invoke -ModuleName DeviceInspectorCommon New-PSDrive -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'XYZ' -and $PSProvider -eq 'CMSite' -and $Root -eq 'sms01' }
        Should -Invoke -ModuleName DeviceInspectorCommon Set-Location -Times 1 -Exactly -Scope It -ParameterFilter { $LiteralPath -eq 'XYZ:' }
    }

    It 'reports a plain message when the site cannot be opened' {
        Mock -ModuleName DeviceInspectorCommon Resolve-ConfigurationManagerModulePath { 'C:\Console\bin\ConfigurationManager.psd1' }
        Mock -ModuleName DeviceInspectorCommon Get-Module { [pscustomobject]@{ Name = 'ConfigurationManager' } }
        Mock -ModuleName DeviceInspectorCommon Get-PSDrive { }
        Mock -ModuleName DeviceInspectorCommon New-PSDrive { throw 'RPC server is unavailable' }
        Mock -ModuleName DeviceInspectorCommon Set-Location { }
        { InModuleScope DeviceInspectorCommon { Connect-InspectorSite -SiteServer 'sms01' -SiteCode 'XYZ' } } | Should -Throw 'Cannot open site XYZ on sms01.*RPC server is unavailable*'
    }

    It 'removes the drive that it created when the site check fails, and keeps one that it did not create' {
        Mock -ModuleName DeviceInspectorCommon Resolve-ConfigurationManagerModulePath { 'C:\Console\bin\ConfigurationManager.psd1' }
        Mock -ModuleName DeviceInspectorCommon Get-Module { [pscustomobject]@{ Name = 'ConfigurationManager' } }
        Mock -ModuleName DeviceInspectorCommon Get-PSDrive { }
        Mock -ModuleName DeviceInspectorCommon New-PSDrive { }
        Mock -ModuleName DeviceInspectorCommon Set-Location { }
        Mock -ModuleName DeviceInspectorCommon Remove-PSDrive { }
        Mock -ModuleName DeviceInspectorCommon Get-CMSite { throw 'site not found' }
        { InModuleScope DeviceInspectorCommon { Connect-InspectorSite -SiteServer 'sms01' -SiteCode 'XYZ' } } | Should -Throw '*site not found*'
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-PSDrive -Times 1 -Exactly -Scope It
        Mock -ModuleName DeviceInspectorCommon Get-PSDrive { [pscustomobject]@{ Name = 'XYZ'; Root = 'sms01' } }
        { InModuleScope DeviceInspectorCommon { Connect-InspectorSite -SiteServer 'sms01' -SiteCode 'XYZ' } } | Should -Throw '*site not found*'
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-PSDrive -Times 1 -Exactly -Scope It
    }
    It 'goes back to the earlier folder and removes a drive that it created' {
        Mock -ModuleName DeviceInspectorCommon Set-Location { }
        Mock -ModuleName DeviceInspectorCommon Remove-PSDrive { }
        InModuleScope DeviceInspectorCommon {
            Disconnect-InspectorSite -Connection ([pscustomobject]@{ SiteCode = 'XYZ'; SiteServer = 'sms01'; PreviousLocation = 'C:\Work'; CreatedDrive = $true })
        }
        Should -Invoke -ModuleName DeviceInspectorCommon Set-Location -Times 1 -Exactly -Scope It -ParameterFilter { $LiteralPath -eq 'C:\Work' }
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-PSDrive -Times 1 -Exactly -Scope It
    }

    It 'keeps a drive that it did not create, and ignores a null connection' {
        Mock -ModuleName DeviceInspectorCommon Set-Location { }
        Mock -ModuleName DeviceInspectorCommon Remove-PSDrive { }
        InModuleScope DeviceInspectorCommon {
            Disconnect-InspectorSite -Connection ([pscustomobject]@{ SiteCode = 'XYZ'; SiteServer = 'sms01'; PreviousLocation = 'C:\Work'; CreatedDrive = $false })
            Disconnect-InspectorSite -Connection $null
        }
        Should -Invoke -ModuleName DeviceInspectorCommon Remove-PSDrive -Times 0 -Scope It
    }
}

Describe 'Get-DeviceInspection' {
    BeforeEach {
        InModuleScope DeviceInspectorCommon {
            Mock Connect-InspectorSite { [pscustomobject]@{ SiteCode = 'XYZ'; SiteServer = 'sms01'; PreviousLocation = 'C:\'; CreatedDrive = $true } }
            Mock Disconnect-InspectorSite { }
            Mock Get-SiteFact { [pscustomobject]@{ Found = $true; ResourceId = 1; ClientInstalled = $true; ClientVersion = '1'; Active = $true; OperatingSystem = 'os'; LastLogonUserName = ''; LastHardwareInventory = $null; InstalledApplications = @(); Collections = @(); Deployments = @() } }
            Mock Get-DeviceFact { [pscustomobject]@{ Reachable = $true; OperatingSystem = $null; Client = $null; InstalledApplications = @(); ClientApplications = @(); Problems = @('Operating system: boom') } }
        }
    }

    It 'combines site and device facts and prefixes device problems' {
        InModuleScope DeviceInspectorCommon {
            $objInspection = Get-DeviceInspection -ComputerName 'ws01.example.com' -SiteServer 'sms01' -SiteCode 'XYZ'
            $objInspection.SiteCode | Should -Be 'XYZ'
            $objInspection.Site.Found | Should -BeTrue
            $objInspection.Device.Reachable | Should -BeTrue
            $objInspection.Problems | Should -Contain 'Device: Operating system: boom'
            Should -Invoke Get-SiteFact -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'ws01' }
            Should -Invoke Connect-InspectorSite -Times 1 -Exactly -ParameterFilter { $SiteServer -eq 'sms01' -and $SiteCode -eq 'XYZ' }
            Should -Invoke Disconnect-InspectorSite -Times 1 -Exactly
        }
    }

    It 'skips the device with SkipDevice' {
        InModuleScope DeviceInspectorCommon {
            $objInspection = Get-DeviceInspection -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ' -SkipDevice
            $objInspection.Device | Should -BeNullOrEmpty
            Should -Invoke Get-DeviceFact -Times 0 -Exactly
        }
    }

    It 'skips the site without SiteServer' {
        InModuleScope DeviceInspectorCommon {
            $objInspection = Get-DeviceInspection -ComputerName 'WS01'
            $objInspection.Site | Should -BeNullOrEmpty
            $objInspection.SiteServer | Should -BeNullOrEmpty
            Should -Invoke Connect-InspectorSite -Times 0 -Exactly
        }
    }

    It 'throws when there is nothing to inspect' {
        InModuleScope DeviceInspectorCommon {
            { Get-DeviceInspection -ComputerName 'WS01' -SkipDevice } | Should -Throw '*Nothing to inspect*'
        }
    }

    It 'throws when a site server has no site code' {
        InModuleScope DeviceInspectorCommon {
            { Get-DeviceInspection -ComputerName 'WS01' -SiteServer 'sms01' } | Should -Throw '*SiteCode is required with SiteServer*'
            Should -Invoke Connect-InspectorSite -Times 0 -Exactly
        }
    }

    It 'records a site connection failure and still inspects the device' {
        InModuleScope DeviceInspectorCommon {
            Mock Connect-InspectorSite { throw 'no route' }
            $objInspection = Get-DeviceInspection -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ'
            $objInspection.Site | Should -BeNullOrEmpty
            $objInspection.Problems | Should -Contain 'Site: no route'
            $objInspection.Device.Reachable | Should -BeTrue
            Should -Invoke Disconnect-InspectorSite -Times 1 -Exactly
        }
    }

    It 'records a device failure and keeps the site facts' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-DeviceFact { throw 'WinRM failed' }
            $objInspection = Get-DeviceInspection -ComputerName 'WS01' -SiteServer 'sms01' -SiteCode 'XYZ'
            $objInspection.Device | Should -BeNullOrEmpty
            $objInspection.Site.Found | Should -BeTrue
            $objInspection.Problems | Should -Contain 'Device: WinRM failed'
        }
    }

    It 'reports a missing device record as a problem' {
        InModuleScope DeviceInspectorCommon {
            Mock Get-SiteFact { [pscustomobject]@{ Found = $false } }
            $objInspection = Get-DeviceInspection -ComputerName 'NOPE' -SiteServer 'sms01' -SiteCode 'XYZ' -SkipDevice
            $objInspection.Problems | Should -Contain 'Site: no device named NOPE exists in site XYZ.'
        }
    }

    It 'rejects an invalid computer name' {
        { Get-DeviceInspection -ComputerName "bad name'" -SiteServer 'sms01' -SiteCode 'XYZ' } | Should -Throw
    }
}

Describe 'Get-DeviceFact' {
    It 'returns the remote result and passes the credential' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-Command {
                [pscustomobject]@{ OperatingSystem = 'os'; Client = 'client'; InstalledApplications = @('a'); ClientApplications = @(); Problems = @() }
            }
            $objCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'u', (ConvertTo-SecureString -String 'p' -AsPlainText -Force)
            $objDevice = Get-DeviceFact -ComputerName 'WS01' -Credential $objCredential
            $objDevice.Reachable | Should -BeTrue
            $objDevice.OperatingSystem | Should -Be 'os'
            Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { $ComputerName -eq 'WS01' -and $null -ne $Credential }
        }
    }

    It 'passes no credential when none is given' {
        InModuleScope DeviceInspectorCommon {
            Mock Invoke-Command {
                [pscustomobject]@{ OperatingSystem = $null; Client = $null; InstalledApplications = @(); ClientApplications = @(); Problems = @() }
            }
            $null = Get-DeviceFact -ComputerName 'WS01'
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
            $null = Get-DeviceFact -ComputerName 'WS01'
            $script:scriptBlockSeen | Should -BeOfType [scriptblock]
            $script:scriptBlockSeen.ToString() | Should -Not -Match '(Set|Remove|New|Start|Stop|Restart)-(Item|CimInstance|Service|ItemProperty)'
        }
    }
}

Describe 'ConvertTo-DeviceInspectionReport' {
    BeforeAll {
        $script:objFull = [pscustomobject]@{
            ComputerName = 'WS01'
            InspectedAt  = '2026-11-05T10:00:00Z'
            SiteServer   = 'sms01'
            SiteCode     = 'XYZ'
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
                Deployments           = @([pscustomobject]@{ Name = 'Example App'; Type = 'Application'; Intent = 'Required'; CollectionName = 'Pilot' })
            }
            Device       = [pscustomobject]@{
                Reachable             = $true
                OperatingSystem       = [pscustomobject]@{ Caption = 'Windows 11'; Version = '10.0.26200'; BuildNumber = '26200'; Architecture = '64-bit'; LastBootUp = '2026-11-05T02:50:41Z' }
                Client                = [pscustomobject]@{ ServiceState = 'Running'; ServiceStartMode = 'Auto'; Version = '5.0'; AssignedSiteCode = 'XYZ'; CurrentManagementPoint = 'sms01'; LastHardwareInventoryCycle = '2026-11-02T19:50:53Z'; LastDiscoveryDataCycle = '2026-11-04T23:02:36Z' }
                InstalledApplications = @([pscustomobject]@{ Name = 'DeviceApp'; Version = '2'; Publisher = 'p' })
                ClientApplications    = @([pscustomobject]@{ Name = 'PolicyApp'; InstallState = 'NotInstalled'; EvaluationState = 3; LastEvaluation = '2026-11-04T21:53:26Z' })
            }
            Problems     = @('Site: example problem')
        }
    }

    It 'prints every section' {
        $strReport = ConvertTo-DeviceInspectionReport -Inspection $script:objFull
        $strReport | Should -BeLike '*Device Inspector report: WS01*'
        $strReport | Should -BeLike '*Caption:      Windows 11*'
        $strReport | Should -BeLike '*Service CcmExec:           Running*'
        $strReport | Should -BeLike '*Resource ID:               5*'
        $strReport | Should -BeLike '*SMS00001  All Systems*'
        $strReport | Should -BeLike '*Example App | Application | Required | via Pilot*'
        $strReport | Should -BeLike '*DeviceApp 2*'
        $strReport | Should -BeLike '*SiteApp 1*'
        $strReport | Should -BeLike '*PolicyApp | NotInstalled | evaluation state 3*'
        $strReport | Should -BeLike '*Site: example problem*'
    }

    It 'accepts pipeline input' {
        $strReport = $script:objFull | ConvertTo-DeviceInspectionReport
        $strReport | Should -BeLike '*WS01*'
    }

    It 'prints No data for skipped parts' {
        $objSkipped = [pscustomobject]@{ ComputerName = 'X'; InspectedAt = 't'; SiteServer = $null; SiteCode = $null; Site = $null; Device = $null; Problems = @() }
        $strReport = ConvertTo-DeviceInspectionReport -Inspection $objSkipped
        $strReport | Should -BeLike '*Site server: not queried*'
        $strReport | Should -BeLike '*No data.*'
        $strReport | Should -BeLike '*== Problems (0) ==*'
    }

    It 'says when the site has no record' {
        $objMissing = [pscustomobject]@{ ComputerName = 'X'; InspectedAt = 't'; SiteServer = 's'; SiteCode = 'XYZ'; Site = [pscustomobject]@{ Found = $false }; Device = $null; Problems = @() }
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
        $arrOutput = @(& $script:strScriptFile -ComputerName 'WS01' -SiteServer 'nonexistent.invalid' -SiteCode 'ABC' -SkipDevice -JsonPath $strJsonPath)
        $arrOutput.Count | Should -Be 1
        $arrOutput[0] | Should -BeLike '*Device Inspector report: WS01*'
        $arrByte = [System.IO.File]::ReadAllBytes($strJsonPath)
        $arrByte[0] | Should -Be 123
        $objJson = [System.IO.File]::ReadAllText($strJsonPath) | ConvertFrom-Json
        $objJson.ComputerName | Should -Be 'WS01'
        @($objJson.Problems | Where-Object { $_ -like 'Site:*' }).Count | Should -Be 1
    }

    It 'stops with one error and one message and exit code 1 for a device name that is not valid' {
        $strHost = (Get-Process -Id $PID).Path
        $strErrorFile = Join-Path -Path $TestDrive -ChildPath 'error.txt'
        $strOutFile = Join-Path -Path $TestDrive -ChildPath 'out.txt'
        $arrArgument = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:strScriptFile), '-ComputerName', '"bad name!"')
        $objProcess = Start-Process -FilePath $strHost -ArgumentList $arrArgument -Wait -PassThru -NoNewWindow -RedirectStandardError $strErrorFile -RedirectStandardOutput $strOutFile
        $objProcess.ExitCode | Should -Be 1
        $strError = Get-Content -LiteralPath $strErrorFile -Raw
        $strError | Should -BeLike '*Enter the device name*'
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
            'Test-DeviceInspectorConsole', 'Test-DeviceInspectorInput', 'Write-DeviceInspectionFile'
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