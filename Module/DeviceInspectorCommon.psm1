# Logging and settings come from the vendored SuiteCommon copy. The guard keeps a
# -Force import of this module (the background runspace does one) from resetting
# SuiteCommon state during a session.
if (-not (Get-Module -Name SuiteCommon)) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Lib\SuiteCommon\SuiteCommon.psd1') -Global -DisableNameChecking
}

Set-StrictMode -Version Latest

#region Private helpers

function ConvertTo-InspectionTimestamp {
    # .SYNOPSIS
    # Converts a date value to an ISO 8601 UTC string, or returns $null.
    #
    # .DESCRIPTION
    # Gives the same text in Windows PowerShell 5.1 and PowerShell 7, because
    # ConvertTo-Json formats [datetime] values differently in the two versions.
    #
    # .PARAMETER Value
    # A [datetime] value, or $null.
    #
    # .EXAMPLE
    # $strText = ConvertTo-InspectionTimestamp -Value ([datetime]'2026-11-05T10:00:00Z')
    #
    # # $strText = '2026-11-05T10:00:00Z'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The timestamp, or $null when Value is $null.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: internal-caller contract only. Position 0 is Value.
    #
    # Version: 1.0.20261105.0
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [object]$Value
    )

    process {
        if ($null -eq $Value) {
            return $null
        }
        return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function ConvertTo-UpdateSeverityName {
    # .SYNOPSIS
    # Converts a ConfigMgr update severity number to its name.
    #
    # .PARAMETER Severity
    # The severity number: 2 Low, 6 Moderate, 8 Important, 10 Critical. Other values map to None.
    #
    # .EXAMPLE
    # $strName = ConvertTo-UpdateSeverityName -Severity 10
    #
    # # $strName = 'Critical'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The severity name.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. This function is not part of the public API surface.
    # Its parameters, return shape, and positional contract may change without notice.
    #
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [int]$Severity
    )

    process {
        switch ($Severity) {
            10 { 'Critical' }
            8 { 'Important' }
            6 { 'Moderate' }
            2 { 'Low' }
            default { 'None' }
        }
    }
}

function ConvertTo-UpdateStateName {
    # .SYNOPSIS
    # Converts a client update evaluation state number to its name.
    #
    # .PARAMETER EvaluationState
    # The EvaluationState of a CCM_SoftwareUpdate instance.
    #
    # .EXAMPLE
    # $strName = ConvertTo-UpdateStateName -EvaluationState 1
    #
    # # $strName = 'Available'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The state name, or State <number> for an unknown number.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. This function is not part of the public API surface.
    # Its parameters, return shape, and positional contract may change without notice.
    #
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [int]$EvaluationState
    )

    process {
        $arrName = @(
            'None', 'Available', 'Submitted', 'Detecting', 'Pre-download', 'Downloading', 'Waiting to install', 'Installing',
            'Pending soft reboot', 'Pending hard reboot', 'Waiting for reboot', 'Verifying', 'Install complete', 'Error',
            'Waiting for service window', 'Waiting for user logon', 'Waiting for user logoff', 'Waiting for job user logon',
            'Waiting for user reconnect', 'Pending user logoff', 'Pending update', 'Waiting retry', 'Waiting for presentation mode off',
            'Waiting for orchestration'
        )
        if ($EvaluationState -ge 0 -and $EvaluationState -lt $arrName.Count) {
            $arrName[$EvaluationState]
        } else {
            'State {0}' -f $EvaluationState
        }
    }
}
function ConvertTo-DeploymentTypeName {
    # .SYNOPSIS
    # Maps a ConfigMgr deployment FeatureType number to a name.
    #
    # .DESCRIPTION
    # Returns a text name for the known types. Unknown numbers give 'Other (n)'.
    #
    # .PARAMETER FeatureType
    # The FeatureType value of SMS_DeploymentSummary.
    #
    # .EXAMPLE
    # $strName = ConvertTo-DeploymentTypeName -FeatureType 1
    #
    # # $strName = 'Application'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The type name.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: internal-caller contract only. Position 0 is FeatureType.
    #
    # Version: 1.0.20261105.0
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [int]$FeatureType
    )

    process {
        $hashtableName = @{
            1 = 'Application'
            2 = 'Program'
            3 = 'Mobile program'
            4 = 'Script'
            5 = 'Software update'
            6 = 'Configuration baseline'
            7 = 'Task sequence'
            8 = 'Content distribution'
        }
        if ($hashtableName.ContainsKey($FeatureType)) {
            return [string]$hashtableName[$FeatureType]
        }
        return ('Other ({0})' -f $FeatureType)
    }
}

function ConvertTo-DeploymentIntentName {
    # .SYNOPSIS
    # Maps a ConfigMgr DeploymentIntent number to a name.
    #
    # .DESCRIPTION
    # Returns Required, Available or Simulate. Unknown numbers give 'Other (n)'.
    #
    # .PARAMETER DeploymentIntent
    # The DeploymentIntent value of SMS_DeploymentSummary.
    #
    # .EXAMPLE
    # $strName = ConvertTo-DeploymentIntentName -DeploymentIntent 2
    #
    # # $strName = 'Available'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The intent name.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: internal-caller contract only. Position 0 is DeploymentIntent.
    #
    # Version: 1.0.20261105.0
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [int]$DeploymentIntent
    )

    process {
        $hashtableName = @{
            1 = 'Required'
            2 = 'Available'
            3 = 'Simulate'
        }
        if ($hashtableName.ContainsKey($DeploymentIntent)) {
            return [string]$hashtableName[$DeploymentIntent]
        }
        return ('Other ({0})' -f $DeploymentIntent)
    }
}

function Select-ListedEntry {
    # .SYNOPSIS
    # Returns at most Maximum entries and a line that counts the rest.
    #
    # .DESCRIPTION
    # Gives a list a fixed size in the report. When the list is empty it
    # returns one line that says (none).
    #
    # .PARAMETER Entry
    # The text entries.
    #
    # .PARAMETER Maximum
    # The most entries to return.
    #
    # .EXAMPLE
    # $arrShown = @(Select-ListedEntry -Entry @('a', 'b', 'c') -Maximum 2)
    #
    # # $arrShown = 'a', 'b', '  ... 1 more (see the JSON output)'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The shown entries, one object per line.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261105.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Entry,

        [Parameter(Mandatory = $true)]
        [int]$Maximum
    )

    process {
        if ($Entry.Count -eq 0) {
            '  (none)'
            return
        }
        $Entry | Select-Object -First $Maximum
        if ($Entry.Count -gt $Maximum) {
            '  ... {0} more (see the JSON output)' -f ($Entry.Count - $Maximum)
        }
    }
}

function Invoke-SiteQuery {
    # .SYNOPSIS
    # Runs one read-only WQL SELECT query against the ConfigMgr provider.
    #
    # .DESCRIPTION
    # The only path from this module to the site. It refuses every query that
    # does not start with SELECT, so the module cannot change the site.
    #
    # .PARAMETER CimSession
    # An open CIM session to the site server.
    #
    # .PARAMETER SiteCode
    # The three-character site code. The query runs in root\SMS\site_<SiteCode>.
    #
    # .PARAMETER Query
    # The WQL query. It must start with SELECT.
    #
    # .EXAMPLE
    # $arrRows = @(Invoke-SiteQuery -CimSession $objSession -SiteCode 'MCM' -Query 'SELECT Name FROM SMS_R_System')
    #
    # # $arrRows holds one CIM instance per device.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [object] One CIM instance for each row.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261105.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([object])]
    param (
        [Parameter(Mandatory = $true)]
        [object]$CimSession,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9]{3}$')]
        [string]$SiteCode,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Query
    )

    process {
        if ($Query -notmatch '^\s*SELECT\s') {
            throw ('Refused: only SELECT queries are allowed. Query: {0}' -f $Query)
        }
        $strNamespace = 'root\SMS\site_{0}' -f $SiteCode
        Write-Debug -Message ('Site query in {0}: {1}' -f $strNamespace, $Query)
        Get-CimInstance -CimSession $CimSession -Namespace $strNamespace -Query $Query -ErrorAction Stop
    }
}

function Get-SiteFact {
    # .SYNOPSIS
    # Collects the facts that the ConfigMgr site holds about one device.
    #
    # .DESCRIPTION
    # Runs SELECT queries only. A failure in one part (inventory, collections,
    # deployments) is added to the Problems list and the other parts continue.
    # A failure of the device resource lookup throws.
    #
    # .PARAMETER CimSession
    # An open CIM session to the site server.
    #
    # .PARAMETER SiteCode
    # The three-character site code.
    #
    # .PARAMETER ComputerName
    # The device name, without a domain suffix.
    #
    # .PARAMETER Problems
    # A list that receives one text line for each part that failed.
    #
    # .EXAMPLE
    # $objSite = Get-SiteFact -CimSession $objSession -SiteCode 'MCM' -ComputerName 'CLIENT01' -Problems $listProblem
    #
    # # $objSite.Found is $true when the site knows the device.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] The site facts. Found is $false when the site has no such device.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Non-throwing contract: a failure in one part is recorded in Problems and
    # the part gets an empty value. Only the resource lookup throws.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261105.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [object]$CimSession,

        [Parameter(Mandatory = $true)]
        [string]$SiteCode,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_-]{1,63}$')]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Problems
    )

    process {
        $strResourceQuery = "SELECT ResourceId, Name, Client, ClientVersion, Active, OperatingSystemNameandVersion, LastLogonUserName FROM SMS_R_System WHERE Name = '{0}'" -f $ComputerName
        $arrResource = @(Invoke-SiteQuery -CimSession $CimSession -SiteCode $SiteCode -Query $strResourceQuery)
        if ($arrResource.Count -eq 0) {
            return [pscustomobject]@{
                Found                 = $false
                ResourceId            = $null
                ClientInstalled       = $null
                ClientVersion         = $null
                Active                = $null
                OperatingSystem       = $null
                LastLogonUserName     = $null
                LastHardwareInventory = $null
                InstalledApplications = @()
                Collections           = @()
                Deployments           = @()
                RequiredUpdates       = @()
            }
        }
        if ($arrResource.Count -gt 1) {
            $Problems.Add(('Site: {0} resource records share the name {1}. The first one is used.' -f $arrResource.Count, $ComputerName))
        }
        $objResource = $arrResource[0]
        $intResourceId = [int]$objResource.ResourceId

        $strLastHardwareInventory = $null
        try {
            $strStatusQuery = 'SELECT LastHardwareScan FROM SMS_G_System_WORKSTATION_STATUS WHERE ResourceID = {0}' -f $intResourceId
            $arrStatus = @(Invoke-SiteQuery -CimSession $CimSession -SiteCode $SiteCode -Query $strStatusQuery)
            if ($arrStatus.Count -gt 0) {
                $strLastHardwareInventory = ConvertTo-InspectionTimestamp -Value $arrStatus[0].LastHardwareScan
            }
        } catch {
            Write-Debug -Message $_.Exception.Message
            $Problems.Add(('Site hardware inventory date: {0}' -f $_.Exception.Message))
        }

        $listApplication = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
        foreach ($strClass in @('SMS_G_System_ADD_REMOVE_PROGRAMS', 'SMS_G_System_ADD_REMOVE_PROGRAMS_64')) {
            try {
                $strApplicationQuery = 'SELECT DisplayName, Version, Publisher FROM {0} WHERE ResourceID = {1}' -f $strClass, $intResourceId
                foreach ($objRow in @(Invoke-SiteQuery -CimSession $CimSession -SiteCode $SiteCode -Query $strApplicationQuery)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$objRow.DisplayName)) {
                        $listApplication.Add([pscustomobject]@{
                                Name      = [string]$objRow.DisplayName
                                Version   = [string]$objRow.Version
                                Publisher = [string]$objRow.Publisher
                            })
                    }
                }
            } catch {
                Write-Debug -Message $_.Exception.Message
                $Problems.Add(('Site installed applications ({0}): {1}' -f $strClass, $_.Exception.Message))
            }
        }

        $listCollectionId = New-Object -TypeName 'System.Collections.Generic.List[string]'
        try {
            $strMembershipQuery = 'SELECT CollectionID FROM SMS_FullCollectionMembership WHERE ResourceID = {0}' -f $intResourceId
            foreach ($objRow in @(Invoke-SiteQuery -CimSession $CimSession -SiteCode $SiteCode -Query $strMembershipQuery)) {
                if (([string]$objRow.CollectionID) -match '^[A-Za-z0-9]{8}$') {
                    $listCollectionId.Add([string]$objRow.CollectionID)
                }
            }
        } catch {
            Write-Debug -Message $_.Exception.Message
            $Problems.Add(('Site collection membership: {0}' -f $_.Exception.Message))
        }

        $hashtableCollectionName = @{}
        $listCollection = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
        $listDeployment = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
        if ($listCollectionId.Count -gt 0) {
            $strCollectionFilter = (($listCollectionId | ForEach-Object { "CollectionID = '{0}'" -f $_ }) -join ' OR ')
            try {
                for ($intNameOffset = 0; $intNameOffset -lt $listCollectionId.Count; $intNameOffset += 50) {
                    $strNameFilter = ((@($listCollectionId | Select-Object -Skip $intNameOffset -First 50) | ForEach-Object { "CollectionID = '{0}'" -f $_ }) -join ' OR ')
                    $strNameQuery = 'SELECT CollectionID, Name FROM SMS_Collection WHERE {0}' -f $strNameFilter
                    foreach ($objRow in @(Invoke-SiteQuery -CimSession $CimSession -SiteCode $SiteCode -Query $strNameQuery)) {
                        $hashtableCollectionName[[string]$objRow.CollectionID] = [string]$objRow.Name
                    }
                }
            } catch {
                Write-Debug -Message $_.Exception.Message
                $Problems.Add(('Site collection names: {0}' -f $_.Exception.Message))
            }
            foreach ($strCollectionId in $listCollectionId) {
                $strCollectionName = $null
                if ($hashtableCollectionName.ContainsKey($strCollectionId)) {
                    $strCollectionName = $hashtableCollectionName[$strCollectionId]
                }
                $listCollection.Add([pscustomobject]@{
                        CollectionId = $strCollectionId
                        Name         = $strCollectionName
                    })
            }

            try {
                $strDeploymentQuery = 'SELECT DeploymentID, CollectionID, CollectionName, SoftwareName, FeatureType, DeploymentIntent, EnforcementDeadline FROM SMS_DeploymentSummary WHERE {0}' -f $strCollectionFilter
                foreach ($objRow in @(Invoke-SiteQuery -CimSession $CimSession -SiteCode $SiteCode -Query $strDeploymentQuery)) {
                    $listDeployment.Add([pscustomobject]@{
                            DeploymentId        = [string]$objRow.DeploymentID
                            CollectionId        = [string]$objRow.CollectionID
                            CollectionName      = [string]$objRow.CollectionName
                            Name                = [string]$objRow.SoftwareName
                            Type                = ConvertTo-DeploymentTypeName -FeatureType ([int]$objRow.FeatureType)
                            Intent              = ConvertTo-DeploymentIntentName -DeploymentIntent ([int]$objRow.DeploymentIntent)
                            EnforcementDeadline = ConvertTo-InspectionTimestamp -Value $objRow.EnforcementDeadline
                        })
                }
            } catch {
                Write-Debug -Message $_.Exception.Message
                $Problems.Add(('Site deployments: {0}' -f $_.Exception.Message))
            }
        }

        $listRequiredUpdate = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
        try {
            $listUpdateId = New-Object -TypeName 'System.Collections.Generic.List[int]'
            $strRequiredQuery = 'SELECT CI_ID FROM SMS_UpdateComplianceStatus WHERE MachineID = {0} AND Status = 2' -f $intResourceId
            foreach ($objRow in @(Invoke-SiteQuery -CimSession $CimSession -SiteCode $SiteCode -Query $strRequiredQuery)) {
                $listUpdateId.Add([int]$objRow.CI_ID)
            }
            for ($intOffset = 0; $intOffset -lt $listUpdateId.Count; $intOffset += 50) {
                $strUpdateFilter = ((@($listUpdateId | Select-Object -Skip $intOffset -First 50) | ForEach-Object { 'CI_ID = {0}' -f $_ }) -join ' OR ')
                $strUpdateQuery = 'SELECT CI_ID, ArticleID, LocalizedDisplayName, Severity, IsExpired, IsSuperseded FROM SMS_SoftwareUpdate WHERE {0}' -f $strUpdateFilter
                foreach ($objRow in @(Invoke-SiteQuery -CimSession $CimSession -SiteCode $SiteCode -Query $strUpdateQuery)) {
                    if (-not [bool]$objRow.IsExpired) {
                        $listRequiredUpdate.Add([pscustomobject]@{
                                CIId         = [int]$objRow.CI_ID
                                ArticleId    = [string]$objRow.ArticleID
                                Title        = [string]$objRow.LocalizedDisplayName
                                Severity     = ConvertTo-UpdateSeverityName -Severity ([int]$objRow.Severity)
                                IsSuperseded = [bool]$objRow.IsSuperseded
                            })
                    }
                }
            }
        } catch {
            Write-Debug -Message $_.Exception.Message
            $Problems.Add(('Site required updates: {0}' -f $_.Exception.Message))
        }
        [pscustomobject]@{
            Found                 = $true
            ResourceId            = $intResourceId
            ClientInstalled       = ([int]$objResource.Client -eq 1)
            ClientVersion         = [string]$objResource.ClientVersion
            Active                = ([int]$objResource.Active -eq 1)
            OperatingSystem       = [string]$objResource.OperatingSystemNameandVersion
            LastLogonUserName     = [string]$objResource.LastLogonUserName
            LastHardwareInventory = $strLastHardwareInventory
            InstalledApplications = @($listApplication | Sort-Object -Property Name, Version -Unique)
            Collections           = @($listCollection | Sort-Object -Property Name, CollectionId)
            Deployments           = @($listDeployment | Sort-Object -Property Name, CollectionId)
            RequiredUpdates       = @($listRequiredUpdate | Sort-Object -Property Title, CIId)
        }
    }
}

function Get-DeviceFact {
    # .SYNOPSIS
    # Collects facts from the device itself over WinRM.
    #
    # .DESCRIPTION
    # Runs one fixed script block on the device with Invoke-Command. The block
    # only reads: CIM classes, the uninstall registry keys, and one service state.
    # The block returns ISO 8601 text for every date.
    #
    # .PARAMETER ComputerName
    # The device name.
    #
    # .PARAMETER Credential
    # An optional credential for the WinRM connection.
    #
    # .EXAMPLE
    # $objDevice = Get-DeviceFact -ComputerName 'CLIENT01'
    #
    # # $objDevice.OperatingSystem.Caption = 'Microsoft Windows 11 Enterprise Evaluation'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] The device facts. The Problems property lists the parts that failed.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Non-throwing contract inside the remote block: a failure in one part is
    # recorded in the Problems property and the part gets an empty value.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261105.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $scriptBlockRead = {
            $ErrorActionPreference = 'Stop'
            $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $strFormat = 'yyyy-MM-ddTHH:mm:ssZ'
            $objCulture = [System.Globalization.CultureInfo]::InvariantCulture

            $objOperatingSystem = $null
            try {
                $objRawOperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
                $objOperatingSystem = [pscustomobject]@{
                    Caption      = [string]$objRawOperatingSystem.Caption
                    Version      = [string]$objRawOperatingSystem.Version
                    BuildNumber  = [string]$objRawOperatingSystem.BuildNumber
                    Architecture = [string]$objRawOperatingSystem.OSArchitecture
                    LastBootUp   = ([datetime]$objRawOperatingSystem.LastBootUpTime).ToUniversalTime().ToString($strFormat, $objCulture)
                }
            } catch {
                $listProblem.Add(('Operating system: {0}' -f $_.Exception.Message))
            }

            $objClient = $null
            try {
                $objService = Get-CimInstance -ClassName Win32_Service -Filter "Name = 'CcmExec'"
                if ($null -eq $objService) {
                    $listProblem.Add('Client health: the CcmExec service does not exist.')
                } else {
                    $strClientVersion = $null
                    $strManagementPoint = $null
                    $strSiteCode = $null
                    $strHardwareCycle = $null
                    $strDiscoveryCycle = $null
                    try {
                        $strClientVersion = [string](Get-CimInstance -Namespace 'root\ccm' -ClassName SMS_Client).ClientVersion
                        foreach ($objAuthority in @(Get-CimInstance -Namespace 'root\ccm' -ClassName CCM_Authority)) {
                            if (([string]$objAuthority.Name) -like 'SMS:*' -and -not [string]::IsNullOrEmpty([string]$objAuthority.CurrentManagementPoint)) {
                                $strManagementPoint = [string]$objAuthority.CurrentManagementPoint
                                $strSiteCode = ([string]$objAuthority.Name).Substring(4)
                            }
                        }
                        foreach ($objCycle in @(Get-CimInstance -Namespace 'root\ccm\invagt' -ClassName InventoryActionStatus)) {
                            $strStamp = ([datetime]$objCycle.LastCycleStartedDate).ToUniversalTime().ToString($strFormat, $objCulture)
                            if ($objCycle.InventoryActionID -eq '{00000000-0000-0000-0000-000000000001}') {
                                $strHardwareCycle = $strStamp
                            } elseif ($objCycle.InventoryActionID -eq '{00000000-0000-0000-0000-000000000003}') {
                                $strDiscoveryCycle = $strStamp
                            }
                        }
                    } catch {
                        $listProblem.Add(('Client details: {0}' -f $_.Exception.Message))
                    }
                    $objClient = [pscustomobject]@{
                        ServiceState               = [string]$objService.State
                        ServiceStartMode           = [string]$objService.StartMode
                        Version                    = $strClientVersion
                        AssignedSiteCode           = $strSiteCode
                        CurrentManagementPoint     = $strManagementPoint
                        LastHardwareInventoryCycle = $strHardwareCycle
                        LastDiscoveryDataCycle     = $strDiscoveryCycle
                    }
                }
            } catch {
                $listProblem.Add(('Client health: {0}' -f $_.Exception.Message))
            }

            $listInstalled = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
            try {
                $arrKeyPath = @(
                    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                )
                foreach ($strKeyPath in $arrKeyPath) {
                    foreach ($objEntry in @(Get-ItemProperty -Path $strKeyPath -ErrorAction SilentlyContinue)) {
                        $objName = $objEntry.PSObject.Properties['DisplayName']
                        $objSystemComponent = $objEntry.PSObject.Properties['SystemComponent']
                        if ($null -eq $objName -or [string]::IsNullOrWhiteSpace([string]$objName.Value)) {
                            continue
                        }
                        if ($null -ne $objSystemComponent -and [int]$objSystemComponent.Value -eq 1) {
                            continue
                        }
                        $objVersion = $objEntry.PSObject.Properties['DisplayVersion']
                        $objPublisher = $objEntry.PSObject.Properties['Publisher']
                        $strVersion = ''
                        if ($null -ne $objVersion) {
                            $strVersion = [string]$objVersion.Value
                        }
                        $strPublisher = ''
                        if ($null -ne $objPublisher) {
                            $strPublisher = [string]$objPublisher.Value
                        }
                        $listInstalled.Add([pscustomobject]@{
                                Name      = [string]$objName.Value
                                Version   = $strVersion
                                Publisher = $strPublisher
                            })
                    }
                }
            } catch {
                $listProblem.Add(('Installed applications: {0}' -f $_.Exception.Message))
            }

            $listClientApplication = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
            try {
                foreach ($objApplication in @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName CCM_Application)) {
                    $strLastEvaluation = $null
                    if ($null -ne $objApplication.LastEvalTime) {
                        $strLastEvaluation = ([datetime]$objApplication.LastEvalTime).ToUniversalTime().ToString($strFormat, $objCulture)
                    }
                    $listClientApplication.Add([pscustomobject]@{
                            Name            = [string]$objApplication.Name
                            InstallState    = [string]$objApplication.InstallState
                            EvaluationState = [int]$objApplication.EvaluationState
                            LastEvaluation  = $strLastEvaluation
                        })
                }
            } catch {
                $listProblem.Add(('Client application policy: {0}' -f $_.Exception.Message))
            }

            $listPendingUpdate = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
            try {
                foreach ($objUpdate in @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName CCM_SoftwareUpdate)) {
                    $strDeadline = $null
                    if ($null -ne $objUpdate.Deadline) {
                        $strDeadline = ([datetime]$objUpdate.Deadline).ToUniversalTime().ToString($strFormat, $objCulture)
                    }
                    $listPendingUpdate.Add([pscustomobject]@{
                            Name            = [string]$objUpdate.Name
                            ArticleId       = [string]$objUpdate.ArticleID
                            EvaluationState = [int]$objUpdate.EvaluationState
                            Deadline        = $strDeadline
                        })
                }
            } catch {
                $listProblem.Add(('Pending updates: {0}' -f $_.Exception.Message))
            }
            [pscustomobject]@{
                OperatingSystem       = $objOperatingSystem
                Client                = $objClient
                InstalledApplications = @($listInstalled | Sort-Object -Property Name, Version -Unique)
                ClientApplications    = @($listClientApplication | Sort-Object -Property Name)
                PendingUpdates        = @($listPendingUpdate | Sort-Object -Property Name)
                Problems              = @($listProblem)
            }
        }

        $hashtableArgument = @{
            ComputerName = $ComputerName
            ScriptBlock  = $scriptBlockRead
            ErrorAction  = 'Stop'
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableArgument['Credential'] = $Credential
        }
        $objRaw = Invoke-Command @hashtableArgument

        $arrPendingUpdate = @()
        if ($null -ne $objRaw.PSObject.Properties['PendingUpdates']) {
            $arrPendingUpdate = @($objRaw.PendingUpdates | ForEach-Object {
                    [pscustomobject]@{
                        Name            = [string]$_.Name
                        ArticleId       = [string]$_.ArticleId
                        EvaluationState = [int]$_.EvaluationState
                        State           = ConvertTo-UpdateStateName -EvaluationState ([int]$_.EvaluationState)
                        Deadline        = $_.Deadline
                    }
                })
        }

        [pscustomobject]@{
            Reachable             = $true
            OperatingSystem       = $objRaw.OperatingSystem
            Client                = $objRaw.Client
            InstalledApplications = @($objRaw.InstalledApplications)
            ClientApplications    = @($objRaw.ClientApplications)
            PendingUpdates        = $arrPendingUpdate
            Problems              = @($objRaw.Problems)
        }
    }
}

#endregion Private helpers

#region Public functions

function Get-DeviceInspection {
    # .SYNOPSIS
    # Collects the facts of one device from a ConfigMgr site and from the device.
    #
    # .DESCRIPTION
    # Read-only. Queries the site provider with SELECT statements through a CIM
    # session and reads the device through one WinRM script block. It never
    # changes the site or the device. A part that fails is listed in Problems
    # and the other parts still run.
    #
    # Site facts: resource record, last hardware inventory, installed
    # applications, collection memberships, deployments targeted at those
    # collections. Device facts: operating system, installed applications,
    # client health (service, version, management point, inventory cycles),
    # and the client application policy.
    #
    # .PARAMETER ComputerName
    # The device name. Letters, digits, hyphen, underscore and dot only.
    #
    # .PARAMETER SiteServer
    # The site server (SMS Provider) name. Omit it to skip the site facts.
    #
    # .PARAMETER SiteCode
    # The three-character site code. Omit it to read it from the provider.
    #
    # .PARAMETER Credential
    # An optional credential for the site server and the device.
    #
    # .PARAMETER SkipDevice
    # Skip the facts from the device itself.
    #
    # .EXAMPLE
    # $objInspection = Get-DeviceInspection -ComputerName 'CLIENT01' -SiteServer 'cm01.contoso.com' -Credential $objCredential
    #
    # # $objInspection.Site.Collections lists the collections of CLIENT01.
    #
    # .EXAMPLE
    # Get-DeviceInspection -ComputerName 'CLIENT01' -SkipDevice -SiteServer 'cm01.contoso.com' | ConvertTo-Json -Depth 6
    #
    # # Prints the site facts as JSON. The device is not contacted.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] One object with ComputerName, InspectedAt, SiteServer,
    # SiteCode, Site, Device and Problems. Site and Device are $null when
    # skipped or when the connection failed.
    #
    # .NOTES
    # Non-throwing contract: a connection or query failure is recorded in
    # Problems. The function throws only for invalid parameters, or when
    # SiteServer is omitted and SkipDevice is set.
    #
    # Positional parameters: position 0 is ComputerName. Other parameters are named.
    #
    # Version: 1.0.20261105.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidatePattern('^[A-Za-z0-9_.-]{1,255}$')]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteServer,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9]{3}$')]
        [string]$SiteCode,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory = $false)]
        [switch]$SkipDevice
    )

    process {
        if ($SkipDevice.IsPresent -and -not $PSBoundParameters.ContainsKey('SiteServer')) {
            throw 'Nothing to inspect: SiteServer is omitted and SkipDevice is set.'
        }

        $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $strShortName = $ComputerName.Split('.')[0]
        $strResolvedSiteCode = $null
        $objSite = $null
        $objDevice = $null

        if ($PSBoundParameters.ContainsKey('SiteServer')) {
            $objSession = $null
            try {
                $hashtableSession = @{
                    ComputerName = $SiteServer
                    ErrorAction  = 'Stop'
                }
                if ($PSBoundParameters.ContainsKey('Credential')) {
                    $hashtableSession['Credential'] = $Credential
                }
                $objSession = New-CimSession @hashtableSession
                if ($PSBoundParameters.ContainsKey('SiteCode')) {
                    $strResolvedSiteCode = $SiteCode
                } else {
                    $arrLocation = @(Get-CimInstance -CimSession $objSession -Namespace 'root\SMS' -ClassName SMS_ProviderLocation -ErrorAction Stop)
                    if ($arrLocation.Count -eq 0) {
                        throw 'The provider reports no site code.'
                    }
                    $strResolvedSiteCode = [string]$arrLocation[0].SiteCode
                }
                Write-Verbose -Message ('Site code: {0}' -f $strResolvedSiteCode)
                $objSite = Get-SiteFact -CimSession $objSession -SiteCode $strResolvedSiteCode -ComputerName $strShortName -Problems $listProblem
                if (-not $objSite.Found) {
                    $listProblem.Add(('Site: no device named {0} exists in site {1}.' -f $strShortName, $strResolvedSiteCode))
                }
            } catch {
                Write-Debug -Message $_.Exception.Message
                $listProblem.Add(('Site: {0}' -f $_.Exception.Message))
            } finally {
                if ($null -ne $objSession) {
                    Remove-CimSession -CimSession $objSession
                }
            }
        }

        if (-not $SkipDevice.IsPresent) {
            try {
                $hashtableDevice = @{ ComputerName = $ComputerName }
                if ($PSBoundParameters.ContainsKey('Credential')) {
                    $hashtableDevice['Credential'] = $Credential
                }
                $objDevice = Get-DeviceFact @hashtableDevice
                foreach ($strDeviceProblem in $objDevice.Problems) {
                    $listProblem.Add(('Device: {0}' -f $strDeviceProblem))
                }
            } catch {
                Write-Debug -Message $_.Exception.Message
                $listProblem.Add(('Device: {0}' -f $_.Exception.Message))
            }
        }

        $strSiteServerText = $null
        if ($PSBoundParameters.ContainsKey('SiteServer')) {
            $strSiteServerText = $SiteServer
        }
        [pscustomobject]@{
            ComputerName = $ComputerName
            InspectedAt  = ConvertTo-InspectionTimestamp -Value ([datetime]::UtcNow)
            SiteServer   = $strSiteServerText
            SiteCode     = $strResolvedSiteCode
            Site         = $objSite
            Device       = $objDevice
            Problems     = @($listProblem)
        }
    }
}

function ConvertTo-DeviceInspectionReport {
    # .SYNOPSIS
    # Formats the result of Get-DeviceInspection as one plain-text report.
    #
    # .DESCRIPTION
    # Builds the report as one string with sections: operating system, client
    # health, site record, collections, deployments, installed applications
    # (device and site), client application policy, problems. Long lists stop
    # after MaximumListedItems entries and show how many entries were left out.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .PARAMETER MaximumListedItems
    # The most entries to print in each list. The default is 25.
    #
    # .EXAMPLE
    # Get-DeviceInspection -ComputerName 'CLIENT01' -SiteServer 'cm01.contoso.com' | ConvertTo-DeviceInspectionReport
    #
    # # Prints the report.
    #
    # .INPUTS
    # [pscustomobject] The inspection object, from the pipeline.
    #
    # .OUTPUTS
    # [string] The report, with lines joined by a line feed.
    #
    # .NOTES
    # Positional parameters: position 0 is Inspection.
    #
    # Version: 1.0.20261105.0
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [pscustomobject]$Inspection,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100000)]
        [int]$MaximumListedItems = 25
    )

    process {
        $listLine = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $listLine.Add(('Device Inspector report: {0}' -f $Inspection.ComputerName))
        $listLine.Add(('Inspected at (UTC): {0}' -f $Inspection.InspectedAt))
        $strSiteText = 'not queried'
        if ($null -ne $Inspection.SiteServer) {
            $strSiteText = '{0} (site code {1})' -f $Inspection.SiteServer, $Inspection.SiteCode
        }
        $listLine.Add(('Site server: {0}' -f $strSiteText))
        $listLine.Add('')

        $arrCollection = @()
        $arrDeployment = @()
        $arrSiteApplication = @()
        $arrDeviceApplication = @()
        $arrClientApplication = @()

        $listLine.Add('== Operating system (device) ==')
        if ($null -eq $Inspection.Device -or $null -eq $Inspection.Device.OperatingSystem) {
            $listLine.Add('  No data.')
        } else {
            $objOperatingSystem = $Inspection.Device.OperatingSystem
            $listLine.Add(('  Caption:      {0}' -f $objOperatingSystem.Caption))
            $listLine.Add(('  Version:      {0} (build {1}, {2})' -f $objOperatingSystem.Version, $objOperatingSystem.BuildNumber, $objOperatingSystem.Architecture))
            $listLine.Add(('  Last boot:    {0}' -f $objOperatingSystem.LastBootUp))
        }
        $listLine.Add('')

        $listLine.Add('== Client health (device) ==')
        if ($null -eq $Inspection.Device -or $null -eq $Inspection.Device.Client) {
            $listLine.Add('  No data.')
        } else {
            $objClient = $Inspection.Device.Client
            $listLine.Add(('  Service CcmExec:           {0} (start mode {1})' -f $objClient.ServiceState, $objClient.ServiceStartMode))
            $listLine.Add(('  Client version:            {0}' -f $objClient.Version))
            $listLine.Add(('  Assigned site code:        {0}' -f $objClient.AssignedSiteCode))
            $listLine.Add(('  Current management point:  {0}' -f $objClient.CurrentManagementPoint))
            $listLine.Add(('  Last hardware inventory:   {0}' -f $objClient.LastHardwareInventoryCycle))
            $listLine.Add(('  Last discovery data cycle: {0}' -f $objClient.LastDiscoveryDataCycle))
        }
        $listLine.Add('')

        $listLine.Add('== Site record ==')
        if ($null -eq $Inspection.Site) {
            $listLine.Add('  No data.')
        } elseif (-not $Inspection.Site.Found) {
            $listLine.Add('  The site has no record of this device.')
        } else {
            $objSite = $Inspection.Site
            $listLine.Add(('  Resource ID:               {0}' -f $objSite.ResourceId))
            $listLine.Add(('  Client installed:          {0}' -f $objSite.ClientInstalled))
            $listLine.Add(('  Client version:            {0}' -f $objSite.ClientVersion))
            $listLine.Add(('  Active:                    {0}' -f $objSite.Active))
            $listLine.Add(('  Operating system:          {0}' -f $objSite.OperatingSystem))
            $listLine.Add(('  Last hardware inventory:   {0}' -f $objSite.LastHardwareInventory))
            $arrCollection = @($objSite.Collections | ForEach-Object { '  {0}  {1}' -f $_.CollectionId, $_.Name })
            $arrDeployment = @($objSite.Deployments | ForEach-Object { '  {0} | {1} | {2} | via {3}' -f $_.Name, $_.Type, $_.Intent, $_.CollectionName })
            $arrSiteApplication = @($objSite.InstalledApplications | ForEach-Object { '  {0} {1}' -f $_.Name, $_.Version })
        }
        $listLine.Add('')

        if ($null -ne $Inspection.Device) {
            $arrDeviceApplication = @($Inspection.Device.InstalledApplications | ForEach-Object { '  {0} {1}' -f $_.Name, $_.Version })
            $arrClientApplication = @($Inspection.Device.ClientApplications | ForEach-Object { '  {0} | {1} | evaluation state {2}' -f $_.Name, $_.InstallState, $_.EvaluationState })
        }

        $arrSiteUpdate = @()
        $arrDeviceUpdate = @()
        foreach ($objUpdateRow in @(ConvertTo-DeviceInspectionUpdateRow -Inspection $Inspection)) {
            if ($objUpdateRow.Source -eq 'Site') {
                $arrSiteUpdate += ('  {0} | {1} | {2}' -f $objUpdateRow.Article, $objUpdateRow.Severity, $objUpdateRow.Title)
            } else {
                $arrDeviceUpdate += ('  {0} | {1} | {2}' -f $objUpdateRow.Article, $objUpdateRow.State, $objUpdateRow.Title)
            }
        }
        $arrSection = @(
            @{ Title = 'Collections'; Entry = $arrCollection }
            @{ Title = 'Deployments targeted at this device'; Entry = $arrDeployment }
            @{ Title = 'Updates required, site'; Entry = $arrSiteUpdate }
            @{ Title = 'Updates pending, device'; Entry = $arrDeviceUpdate }
            @{ Title = 'Installed applications, device'; Entry = $arrDeviceApplication }
            @{ Title = 'Installed applications, site inventory'; Entry = $arrSiteApplication }
            @{ Title = 'Client application policy, device'; Entry = $arrClientApplication }
        )
        foreach ($hashtableSection in $arrSection) {
            $arrEntry = [string[]]@($hashtableSection.Entry)
            $listLine.Add(('== {0} ({1}) ==' -f $hashtableSection.Title, $arrEntry.Count))
            foreach ($strEntry in @(Select-ListedEntry -Entry $arrEntry -Maximum $MaximumListedItems)) {
                $listLine.Add($strEntry)
            }
            $listLine.Add('')
        }

        $listLine.Add(('== Problems ({0}) ==' -f @($Inspection.Problems).Count))
        foreach ($strProblem in @($Inspection.Problems)) {
            $listLine.Add(('  {0}' -f $strProblem))
        }

        return ($listLine -join "`n")
    }
}

#endregion Public functions

#region Window support

function Test-DeviceInspectorInput {
    # .SYNOPSIS
    # Checks the device name and the site server that a person typed in the window.
    #
    # .DESCRIPTION
    # Collects one message for each wrong value. The function reads nothing and
    # changes nothing. An empty site server is allowed and means: read the device only.
    #
    # .PARAMETER ComputerName
    # The device name as typed.
    #
    # .PARAMETER SiteServer
    # The site server (SMS Provider computer) as typed. May be empty.
    #
    # .PARAMETER SiteCode
    # The site code as typed. May be empty.
    #
    # .EXAMPLE
    # $objInput = Test-DeviceInspectorInput -ComputerName 'client01' -SiteServer 'cm01.contoso.com'
    #
    # # $objInput.IsValid = $true
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties IsValid, Errors, ComputerName, SiteServer, SiteCode.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ComputerName = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$SiteServer = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$SiteCode = ''
    )

    process {
        $listError = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $strComputer = $ComputerName.Trim()
        $strServer = $SiteServer.Trim()
        $strCode = $SiteCode.Trim()
        if ($strComputer -notmatch '^[A-Za-z0-9_.-]{1,255}$' -or $strComputer.StartsWith('.')) {
            $listError.Add('Enter the device name. Use letters, digits, dots, hyphens and underscores.')
        }
        if (-not [string]::IsNullOrEmpty($strServer) -and $strServer -notmatch '^[A-Za-z0-9_.-]{1,255}$') {
            $listError.Add('The site server is a computer name or an FQDN.')
        }
        if (-not [string]::IsNullOrEmpty($strCode) -and $strCode -notmatch '^[A-Za-z0-9]{3}$') {
            $listError.Add('The site code is three letters or digits.')
        }
        if ([string]::IsNullOrEmpty($strServer) -and -not [string]::IsNullOrEmpty($strCode)) {
            $listError.Add('A site code needs a site server.')
        }
        [pscustomobject]@{
            IsValid = ($listError.Count -eq 0)
            Errors = $listError.ToArray()
            ComputerName = $strComputer
            SiteServer = $strServer
            SiteCode = $strCode
        }
    }
}

function ConvertTo-DeviceInspectionFactRow {
    # .SYNOPSIS
    # Turns the facts of an inspection into rows of group, name and value.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # $arrRow = ConvertTo-DeviceInspectionFactRow -Inspection $objInspection
    #
    # # Rows for the operating system, the client health and the site record.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties Group, Name, Value.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection
    )

    process {
        $scriptBlockRow = { param($strGroup, $strName, $objValue) [pscustomobject]@{ Group = $strGroup; Name = $strName; Value = [string]$objValue } }
        & $scriptBlockRow 'Inspection' 'Device' $Inspection.ComputerName
        & $scriptBlockRow 'Inspection' 'Inspected at (UTC)' $Inspection.InspectedAt
        $strSiteText = 'not queried'
        if ($null -ne $Inspection.SiteServer) {
            $strSiteText = '{0} (site code {1})' -f $Inspection.SiteServer, $Inspection.SiteCode
        }
        & $scriptBlockRow 'Inspection' 'Site server' $strSiteText
        if ($null -ne $Inspection.Device) {
            $objOperatingSystem = $Inspection.Device.OperatingSystem
            if ($null -ne $objOperatingSystem) {
                & $scriptBlockRow 'Operating system (device)' 'Caption' $objOperatingSystem.Caption
                & $scriptBlockRow 'Operating system (device)' 'Version' ('{0} (build {1}, {2})' -f $objOperatingSystem.Version, $objOperatingSystem.BuildNumber, $objOperatingSystem.Architecture)
                & $scriptBlockRow 'Operating system (device)' 'Last boot (UTC)' $objOperatingSystem.LastBootUp
            }
            $objClient = $Inspection.Device.Client
            if ($null -ne $objClient) {
                & $scriptBlockRow 'Client health (device)' 'Service CcmExec' ('{0} (start mode {1})' -f $objClient.ServiceState, $objClient.ServiceStartMode)
                & $scriptBlockRow 'Client health (device)' 'Client version' $objClient.Version
                & $scriptBlockRow 'Client health (device)' 'Assigned site code' $objClient.AssignedSiteCode
                & $scriptBlockRow 'Client health (device)' 'Current management point' $objClient.CurrentManagementPoint
                & $scriptBlockRow 'Client health (device)' 'Last hardware inventory cycle (UTC)' $objClient.LastHardwareInventoryCycle
                & $scriptBlockRow 'Client health (device)' 'Last discovery data cycle (UTC)' $objClient.LastDiscoveryDataCycle
            }
        }
        if ($null -ne $Inspection.Site) {
            if ($Inspection.Site.Found) {
                & $scriptBlockRow 'Site record' 'Resource ID' $Inspection.Site.ResourceId
                & $scriptBlockRow 'Site record' 'Client installed' $Inspection.Site.ClientInstalled
                & $scriptBlockRow 'Site record' 'Client version' $Inspection.Site.ClientVersion
                & $scriptBlockRow 'Site record' 'Active' $Inspection.Site.Active
                & $scriptBlockRow 'Site record' 'Operating system' $Inspection.Site.OperatingSystem
                & $scriptBlockRow 'Site record' 'Last logon user' $Inspection.Site.LastLogonUserName
                & $scriptBlockRow 'Site record' 'Last hardware inventory (UTC)' $Inspection.Site.LastHardwareInventory
            } else {
                & $scriptBlockRow 'Site record' 'Status' 'The site has no record of this device.'
            }
        }
    }
}

function ConvertTo-DeviceInspectionApplicationRow {
    # .SYNOPSIS
    # Merges the installed applications of the device and of the site inventory.
    #
    # .DESCRIPTION
    # Joins the two lists by application name, ignoring case. Status is Match when
    # the name and the version are equal, Version differs when only the name is equal,
    # Device only or Inventory only when one list lacks the application.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # $arrRow = ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection
    #
    # # One row for each application name in either list.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties Name, DeviceVersion, InventoryVersion, Publisher, Status.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection
    )

    process {
        $hashtableDevice = @{}
        $hashtableSite = @{}
        $hashtablePublisher = @{}
        if ($null -ne $Inspection.Device) {
            foreach ($objApplication in @($Inspection.Device.InstalledApplications)) {
                $strKey = ([string]$objApplication.Name).ToLowerInvariant()
                if (-not $hashtableDevice.ContainsKey($strKey)) {
                    $hashtableDevice[$strKey] = New-Object -TypeName 'System.Collections.Generic.List[string]'
                }
                $hashtableDevice[$strKey].Add([string]$objApplication.Version)
                $hashtablePublisher[$strKey] = [string]$objApplication.Publisher
            }
        }
        if ($null -ne $Inspection.Site) {
            foreach ($objApplication in @($Inspection.Site.InstalledApplications)) {
                $strKey = ([string]$objApplication.Name).ToLowerInvariant()
                if (-not $hashtableSite.ContainsKey($strKey)) {
                    $hashtableSite[$strKey] = New-Object -TypeName 'System.Collections.Generic.List[string]'
                }
                $hashtableSite[$strKey].Add([string]$objApplication.Version)
                if (-not $hashtablePublisher.ContainsKey($strKey)) {
                    $hashtablePublisher[$strKey] = [string]$objApplication.Publisher
                }
            }
        }
        $hashtableDisplay = @{}
        foreach ($objSource in @($Inspection.Device, $Inspection.Site)) {
            if ($null -eq $objSource) {
                continue
            }
            foreach ($objApplication in @($objSource.InstalledApplications)) {
                $hashtableDisplay[([string]$objApplication.Name).ToLowerInvariant()] = [string]$objApplication.Name
            }
        }
        foreach ($strKey in @($hashtableDisplay.Keys | Sort-Object)) {
            $strDeviceVersion = ''
            $strSiteVersion = ''
            $strStatus = 'Match'
            if ($hashtableDevice.ContainsKey($strKey)) {
                $strDeviceVersion = (@($hashtableDevice[$strKey] | Sort-Object -Unique) -join ', ')
            }
            if ($hashtableSite.ContainsKey($strKey)) {
                $strSiteVersion = (@($hashtableSite[$strKey] | Sort-Object -Unique) -join ', ')
            }
            if (-not $hashtableSite.ContainsKey($strKey)) {
                $strStatus = 'Device only'
            } elseif (-not $hashtableDevice.ContainsKey($strKey)) {
                $strStatus = 'Inventory only'
            } elseif ($strDeviceVersion -ne $strSiteVersion) {
                $strStatus = 'Version differs'
            }
            [pscustomobject]@{
                Name = $hashtableDisplay[$strKey]
                DeviceVersion = $strDeviceVersion
                InventoryVersion = $strSiteVersion
                Publisher = [string]$hashtablePublisher[$strKey]
                Status = $strStatus
            }
        }
    }
}

function ConvertTo-DeviceInspectionUpdateRow {
    # .SYNOPSIS
    # Turns the update facts of an inspection into rows.
    #
    # .DESCRIPTION
    # One row for each update that the site lists as required for the device, and one
    # row for each update that is pending in the client policy on the device.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # $arrRow = ConvertTo-DeviceInspectionUpdateRow -Inspection $objInspection
    #
    # # Rows with Source Site or Device.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties Source, Article, Severity, State, Deadline, Title.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection
    )

    process {
        if ($null -ne $Inspection.Site -and $null -ne $Inspection.Site.PSObject.Properties['RequiredUpdates']) {
            foreach ($objUpdate in @($Inspection.Site.RequiredUpdates)) {
                $strState = 'Required'
                if ($objUpdate.IsSuperseded) {
                    $strState = 'Required (superseded)'
                }
                [pscustomobject]@{
                    Source = 'Site'
                    Article = $(if ([string]::IsNullOrEmpty($objUpdate.ArticleId)) { '' } else { 'KB{0}' -f $objUpdate.ArticleId })
                    Severity = [string]$objUpdate.Severity
                    State = $strState
                    Deadline = ''
                    Title = [string]$objUpdate.Title
                }
            }
        }
        if ($null -ne $Inspection.Device -and $null -ne $Inspection.Device.PSObject.Properties['PendingUpdates']) {
            foreach ($objUpdate in @($Inspection.Device.PendingUpdates)) {
                [pscustomobject]@{
                    Source = 'Device'
                    Article = $(if ([string]::IsNullOrEmpty($objUpdate.ArticleId)) { '' } else { 'KB{0}' -f $objUpdate.ArticleId })
                    Severity = ''
                    State = [string]$objUpdate.State
                    Deadline = [string]$objUpdate.Deadline
                    Title = [string]$objUpdate.Name
                }
            }
        }
    }
}

function ConvertTo-DeviceInspectionCollectionRow {
    # .SYNOPSIS
    # Turns the collection memberships of an inspection into rows.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # $arrRow = ConvertTo-DeviceInspectionCollectionRow -Inspection $objInspection
    #
    # # One row for each collection of the device.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties CollectionId, Name.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection
    )

    process {
        if ($null -eq $Inspection.Site) {
            return
        }
        foreach ($objCollection in @($Inspection.Site.Collections)) {
            [pscustomobject]@{
                CollectionId = [string]$objCollection.CollectionId
                Name = [string]$objCollection.Name
            }
        }
    }
}

function ConvertTo-DeviceInspectionDeploymentRow {
    # .SYNOPSIS
    # Turns the deployments that target the collections of the device into rows.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # $arrRow = ConvertTo-DeviceInspectionDeploymentRow -Inspection $objInspection
    #
    # # One row for each deployment.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties Name, Type, Intent, Collection, Deadline.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection
    )

    process {
        if ($null -eq $Inspection.Site) {
            return
        }
        foreach ($objDeployment in @($Inspection.Site.Deployments)) {
            [pscustomobject]@{
                Name = [string]$objDeployment.Name
                Type = [string]$objDeployment.Type
                Intent = [string]$objDeployment.Intent
                Collection = [string]$objDeployment.CollectionName
                Deadline = [string]$objDeployment.EnforcementDeadline
            }
        }
    }
}

function ConvertTo-DeviceInspectionJson {
    # .SYNOPSIS
    # Returns the JSON text of an inspection, the format of the -JsonPath file.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # $strJson = ConvertTo-DeviceInspectionJson -Inspection $objInspection
    #
    # # JSON text with LF line breaks and a final line break.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The JSON text.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection
    )

    process {
        (($Inspection | ConvertTo-Json -Depth 8) -replace "`r`n", "`n") + "`n"
    }
}

function ConvertTo-DeviceInspectionHtml {
    # .SYNOPSIS
    # Returns a self-contained HTML report of an inspection.
    #
    # .DESCRIPTION
    # The page has no script and no external resource. Every value is HTML encoded.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # $strHtml = ConvertTo-DeviceInspectionHtml -Inspection $objInspection
    #
    # # A complete HTML document.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The HTML text.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection
    )

    process {
        $scriptBlockEncode = { param($objValue) [System.Net.WebUtility]::HtmlEncode([string]$objValue) }
        $scriptBlockTable = {
            param([string]$strTitle, [object[]]$arrRow, [string[]]$arrColumn)
            $listPart = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $listPart.Add(('<h2>{0} ({1})</h2>' -f [System.Net.WebUtility]::HtmlEncode($strTitle), @($arrRow).Count))
            if (@($arrRow).Count -eq 0) {
                $listPart.Add('<p>None.</p>')
            } else {
                $listPart.Add('<table><tr>' + (($arrColumn | ForEach-Object { '<th>{0}</th>' -f [System.Net.WebUtility]::HtmlEncode($_) }) -join '') + '</tr>')
                foreach ($objRow in @($arrRow)) {
                    $listPart.Add('<tr>' + (($arrColumn | ForEach-Object { '<td>{0}</td>' -f [System.Net.WebUtility]::HtmlEncode([string]$objRow.$_) }) -join '') + '</tr>')
                }
                $listPart.Add('</table>')
            }
            $listPart -join [System.Environment]::NewLine
        }
        $listLine = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $listLine.Add('<!DOCTYPE html>')
        $listLine.Add('<html lang="en"><head><meta charset="utf-8">')
        $listLine.Add(('<title>Device Inspector report: {0}</title>' -f (& $scriptBlockEncode $Inspection.ComputerName)))
        $listLine.Add('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b}h1{font-size:22px}h2{font-size:17px;margin-top:28px;border-bottom:1px solid #ccc;padding-bottom:4px}table{border-collapse:collapse;margin:8px 0;font-size:13px}th,td{border:1px solid #c8c8c8;padding:4px 10px;text-align:left;vertical-align:top}th{background:#0078d4;color:#fff}tr:nth-child(even) td{background:#f3f3f3}.meta{color:#555;font-size:13px}.problem{color:#a4262c}</style>')
        $listLine.Add('</head><body>')
        $listLine.Add(('<h1>Device Inspector report: {0}</h1>' -f (& $scriptBlockEncode $Inspection.ComputerName)))
        $strSiteText = 'not queried'
        if ($null -ne $Inspection.SiteServer) {
            $strSiteText = '{0} (site code {1})' -f $Inspection.SiteServer, $Inspection.SiteCode
        }
        $listLine.Add(('<p class="meta">Inspected at (UTC) {0}. Site server: {1}. Read only: this report changes nothing.</p>' -f (& $scriptBlockEncode $Inspection.InspectedAt), (& $scriptBlockEncode $strSiteText)))
        $arrFact = @(ConvertTo-DeviceInspectionFactRow -Inspection $Inspection)
        $listLine.Add((& $scriptBlockTable 'Device facts' $arrFact @('Group', 'Name', 'Value')))
        $arrApplication = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $Inspection)
        $listLine.Add((& $scriptBlockTable 'Installed applications' $arrApplication @('Name', 'DeviceVersion', 'InventoryVersion', 'Publisher', 'Status')))
        $arrUpdate = @(ConvertTo-DeviceInspectionUpdateRow -Inspection $Inspection)
        $listLine.Add((& $scriptBlockTable 'Updates' $arrUpdate @('Source', 'Article', 'Severity', 'State', 'Deadline', 'Title')))
        $arrCollection = @(ConvertTo-DeviceInspectionCollectionRow -Inspection $Inspection)
        $listLine.Add((& $scriptBlockTable 'Collections' $arrCollection @('CollectionId', 'Name')))
        $arrDeployment = @(ConvertTo-DeviceInspectionDeploymentRow -Inspection $Inspection)
        $listLine.Add((& $scriptBlockTable 'Deployments targeted at this device' $arrDeployment @('Name', 'Type', 'Intent', 'Collection', 'Deadline')))
        $listLine.Add(('<h2 class="problem">Problems ({0})</h2>' -f @($Inspection.Problems).Count))
        if (@($Inspection.Problems).Count -eq 0) {
            $listLine.Add('<p>None.</p>')
        } else {
            $listLine.Add('<ul>' + ((@($Inspection.Problems) | ForEach-Object { '<li>{0}</li>' -f (& $scriptBlockEncode $_) }) -join '') + '</ul>')
        }
        $listLine.Add('</body></html>')
        $listLine -join [System.Environment]::NewLine
    }
}

function Write-DeviceInspectionFile {
    # .SYNOPSIS
    # Writes text to a file as UTF-8 without a byte order mark.
    #
    # .PARAMETER Path
    # The file path. The function creates the folder when it is missing.
    #
    # .PARAMETER Text
    # The text to write.
    #
    # .EXAMPLE
    # $strPath = Write-DeviceInspectionFile -Path 'C:\reports\client01.html' -Text $strHtml
    #
    # # Returns the absolute path written.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The absolute path written.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    process {
        $strFullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($strFullPath))
        $objEncoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false
        [System.IO.File]::WriteAllText($strFullPath, $Text, $objEncoding)
        $strFullPath
    }
}

#endregion Window support

Export-ModuleMember -Function 'Get-DeviceInspection', 'ConvertTo-DeviceInspectionReport', 'Test-DeviceInspectorInput', 'ConvertTo-DeviceInspectionFactRow', 'ConvertTo-DeviceInspectionApplicationRow', 'ConvertTo-DeviceInspectionUpdateRow', 'ConvertTo-DeviceInspectionCollectionRow', 'ConvertTo-DeviceInspectionDeploymentRow', 'ConvertTo-DeviceInspectionJson', 'ConvertTo-DeviceInspectionHtml', 'Write-DeviceInspectionFile'
