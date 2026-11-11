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
    # A value with Kind Unspecified is read as UTC. The ConfigurationManager cmdlets
    # return the inventory dates of the site this way. The last hardware scan of
    # Get-CMDevice can lag a processed report. The Last hardware inventory fact shows
    # it only when SMS_G_System_WORKSTATION_STATUS has no row.
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
    # Version: 1.0.20261111.0
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
        $datetimeValue = [datetime]$Value
        if ($datetimeValue.Kind -eq [System.DateTimeKind]::Unspecified) {
            $datetimeValue = [datetime]::SpecifyKind($datetimeValue, [System.DateTimeKind]::Utc)
        }
        return $datetimeValue.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function ConvertTo-InspectionDeploymentTime {
    # .SYNOPSIS
    # Converts a deployment deadline to text, or returns $null.
    #
    # .DESCRIPTION
    # The site stores a deployment time as the local time that the administrator
    # entered, with no zone (checked on the lab with a test deployment). A value with
    # Kind Unspecified is therefore written without a zone: yyyy-MM-ddTHH:mm:ss. A
    # value with a zone goes through ConvertTo-InspectionTimestamp.
    #
    # .PARAMETER Value
    # A [datetime] value, or $null.
    #
    # .EXAMPLE
    # $strText = ConvertTo-InspectionDeploymentTime -Value ([datetime]'2026-12-04T17:00:00')
    #
    # # $strText = '2026-12-04T17:00:00'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The text, or $null when Value is $null.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: internal-caller contract only. Position 0 is Value.
    #
    # Version: 1.0.20261106.0
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
        $datetimeValue = [datetime]$Value
        if ($datetimeValue.Kind -eq [System.DateTimeKind]::Unspecified) {
            return $datetimeValue.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        return ConvertTo-InspectionTimestamp -Value $datetimeValue
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

function Test-DeviceInspectorConsole {
    # .SYNOPSIS
    # Checks that the ConfigurationManager PowerShell module is installed on this computer.
    #
    # .DESCRIPTION
    # The module comes only with the Configuration Manager console. The function finds
    # ConfigurationManager.psd1 with Resolve-ConfigurationManagerModulePath (SuiteCommon)
    # and returns a plain message when the console is not installed. It changes nothing.
    #
    # .EXAMPLE
    # $objCheck = Test-DeviceInspectorConsole
    #
    # # $objCheck.Available = $true when the console is installed.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties: Available, Path, Message.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param ()

    process {
        $strPath = Resolve-ConfigurationManagerModulePath
        if ([string]::IsNullOrEmpty($strPath)) {
            return [pscustomobject]@{
                Available = $false
                Path      = ''
                Message   = 'The Configuration Manager console is not installed on this computer. Device Inspector reads the site with the ConfigurationManager PowerShell module, which comes only with the console. Install the console, then start Device Inspector again.'
            }
        }
        [pscustomobject]@{
            Available = $true
            Path      = $strPath
            Message   = ''
        }
    }
}

function Get-InspectorLocalIdentity {
    # .SYNOPSIS
    # Returns the names and the IP addresses of this computer.
    #
    # .DESCRIPTION
    # Reads the NetBIOS name, the DNS host name, the full DNS name and the unicast
    # addresses of all network interfaces. It sends no DNS query. A part that cannot
    # be read is left out.
    #
    # .EXAMPLE
    # $objIdentity = Get-InspectorLocalIdentity
    #
    # # $objIdentity.Name holds the short name and the full name of this computer.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties: Name (string[]), Address (System.Net.IPAddress[]).
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
    param ()

    process {
        $listName = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $listAddress = New-Object -TypeName 'System.Collections.Generic.List[System.Net.IPAddress]'
        if (-not [string]::IsNullOrEmpty($env:COMPUTERNAME)) {
            $listName.Add($env:COMPUTERNAME)
        }
        try {
            $objProperty = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
            if (-not [string]::IsNullOrEmpty($objProperty.HostName)) {
                $listName.Add($objProperty.HostName)
                if (-not [string]::IsNullOrEmpty($objProperty.DomainName)) {
                    $listName.Add(('{0}.{1}' -f $objProperty.HostName, $objProperty.DomainName))
                }
            }
        } catch {
            Write-Debug -Message ('Get-InspectorLocalIdentity names: {0}' -f $_.Exception.Message)
        }
        try {
            foreach ($objInterface in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                foreach ($objUnicast in $objInterface.GetIPProperties().UnicastAddresses) {
                    $listAddress.Add($objUnicast.Address)
                }
            }
        } catch {
            Write-Debug -Message ('Get-InspectorLocalIdentity addresses: {0}' -f $_.Exception.Message)
        }
        [pscustomobject]@{
            Name    = $listName.ToArray()
            Address = $listAddress.ToArray()
        }
    }
}

function Test-InspectorLocalComputer {
    # .SYNOPSIS
    # Tells if a computer name or an IP address is this computer.
    #
    # .DESCRIPTION
    # Returns $true for the short name, the full DNS name, localhost, '.', a loopback
    # address and an IP address of this computer. The test ignores case, spaces at
    # the ends and a trailing dot. An empty value returns $false. It sends no DNS
    # query, so an alias name of this computer returns $false.
    #
    # .PARAMETER ComputerName
    # The name or the IP address to test.
    #
    # .EXAMPLE
    # Test-InspectorLocalComputer -ComputerName 'localhost'
    #
    # # Returns $true.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [bool]
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ComputerName
    )

    process {
        if ([string]::IsNullOrWhiteSpace($ComputerName)) {
            return $false
        }
        $strName = $ComputerName.Trim()
        if ($strName -eq '.' -or $strName -eq 'localhost') {
            return $true
        }
        $strName = $strName.TrimEnd('.')
        $objIdentity = Get-InspectorLocalIdentity
        $objAddress = $null
        if ([System.Net.IPAddress]::TryParse($strName, [ref]$objAddress)) {
            if ([System.Net.IPAddress]::IsLoopback($objAddress)) {
                return $true
            }
            foreach ($objLocalAddress in @($objIdentity.Address)) {
                if ($null -ne $objLocalAddress -and $objLocalAddress.Equals($objAddress)) {
                    return $true
                }
            }
            return $false
        }
        foreach ($strLocalName in @($objIdentity.Name)) {
            if ($strLocalName -eq $strName) {
                return $true
            }
        }
        $false
    }
}

function Connect-InspectorSite {
    # .SYNOPSIS
    # Imports the ConfigurationManager module and opens the site drive.
    #
    # .DESCRIPTION
    # Imports ConfigurationManager.psd1, creates a CMSite PSDrive named after the site
    # code with the site server as root, and sets the location to the drive. The
    # ConfigurationManager cmdlets work only from the site drive. The function throws
    # a plain message when the module is missing or the site is not reachable. Pass
    # the returned object to Disconnect-InspectorSite.
    #
    # .PARAMETER SiteServer
    # The computer that runs the SMS Provider.
    #
    # .PARAMETER SiteCode
    # The three-character site code.
    #
    # .PARAMETER Credential
    # An optional credential for the site drive. When the site server is this
    # computer, the function does not use it, because Windows does not allow
    # credentials for a local connection. The signed-in account is used.
    #
    # .EXAMPLE
    # $objConnection = Connect-InspectorSite -SiteServer 'sms01' -SiteCode 'XYZ'
    #
    # # The current location is now XYZ:
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties: SiteCode, SiteServer, PreviousLocation, CreatedDrive.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteServer,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9]{3}$')]
        [string]$SiteCode,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $objCheck = Test-DeviceInspectorConsole
        if (-not $objCheck.Available) {
            throw $objCheck.Message
        }
        $objPrevious = Get-Location
        $strSiteDrive = '{0}:' -f $SiteCode
        $boolCreated = $false
        try {
            if (-not (Get-Module -Name 'ConfigurationManager')) {
                Import-Module -Name $objCheck.Path -DisableNameChecking -ErrorAction Stop
            }
            # Windows refuses a credential for a connection to this computer, so the
            # site drive of a local site server opens with the signed-in account.
            $boolUseCredential = $PSBoundParameters.ContainsKey('Credential') -and ($null -ne $Credential)
            if ($boolUseCredential -and (Test-InspectorLocalComputer -ComputerName $SiteServer)) {
                Write-Verbose -Message 'The site server is this computer. Windows does not allow credentials for a local connection, so the signed-in account is used.'
                $boolUseCredential = $false
            }
            $objDrive = Get-PSDrive -Name $SiteCode -PSProvider 'CMSite' -ErrorAction SilentlyContinue
            if ($null -ne $objDrive -and (($objDrive.Root -ne $SiteServer) -or $boolUseCredential)) {
                Set-Location -LiteralPath $env:SystemDrive
                Remove-PSDrive -Name $SiteCode -PSProvider 'CMSite' -Force -ErrorAction SilentlyContinue
                $objDrive = $null
            }
            if ($null -eq $objDrive) {
                $hashtableDrive = @{ Name = $SiteCode; PSProvider = 'CMSite'; Root = $SiteServer; Scope = 'Global'; ErrorAction = 'Stop' }
                if ($boolUseCredential) {
                    $hashtableDrive['Credential'] = $Credential
                }
                [void](New-PSDrive @hashtableDrive)
                $boolCreated = $true
            }
            Set-Location -LiteralPath $strSiteDrive -ErrorAction Stop
            [void](Get-CMSite -SiteCode $SiteCode -ErrorAction Stop)
        } catch {
            Write-Debug -Message ('Connect-InspectorSite failed: {0}' -f $_.Exception.Message)
            Set-Location -LiteralPath $objPrevious.Path -ErrorAction SilentlyContinue
            if ($boolCreated) {
                Remove-PSDrive -Name $SiteCode -PSProvider 'CMSite' -Force -ErrorAction SilentlyContinue
            }
            if ($_.Exception.Message -like '*credentials cannot be used for local connections*') {
                throw ('Cannot open site {0} on {1}. The site server is this computer, and Windows does not allow credentials for a local connection. Enter the name of this computer as the site server, or run without a credential. {2}' -f $SiteCode, $SiteServer, $_.Exception.Message)
            }
            throw ('Cannot open site {0} on {1}. Check the site code and the site server name, and the account rights. {2}' -f $SiteCode, $SiteServer, $_.Exception.Message)
        }
        [pscustomobject]@{
            SiteCode         = $SiteCode
            SiteServer       = $SiteServer
            PreviousLocation = $objPrevious.Path
            CreatedDrive     = $boolCreated
        }
    }
}

function Disconnect-InspectorSite {
    # .SYNOPSIS
    # Leaves the site drive that Connect-InspectorSite opened.
    #
    # .DESCRIPTION
    # Sets the location back to the folder it had before Connect-InspectorSite and
    # removes the site drive when Connect-InspectorSite created it. It never throws.
    #
    # .PARAMETER Connection
    # The object that Connect-InspectorSite returns. A null value is ignored.
    #
    # .EXAMPLE
    # Disconnect-InspectorSite -Connection $objConnection
    #
    # # The location is the folder from before.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # None.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([void])]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [pscustomobject]$Connection
    )

    process {
        if ($null -eq $Connection) {
            return
        }
        Set-Location -LiteralPath $Connection.PreviousLocation -ErrorAction SilentlyContinue
        if ($Connection.CreatedDrive) {
            Remove-PSDrive -Name $Connection.SiteCode -PSProvider 'CMSite' -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SiteQuery {
    # .SYNOPSIS
    # Runs one WQL query on the site with Invoke-CMWmiQuery. Read only.
    #
    # .DESCRIPTION
    # Used only where no ConfigurationManager cmdlet returns the data: the hardware
    # inventory classes, the collection memberships of one device and the update
    # status of one device. Invoke-CMWmiQuery is a ConfigurationManager cmdlet. It
    # uses the open site drive and the role based access of the account. It exists
    # as a function so that tests can replace the only point of this kind.
    #
    # .PARAMETER Query
    # The WQL query. It must be a SELECT.
    #
    # .EXAMPLE
    # $arrRow = @(Invoke-SiteQuery -Query 'SELECT CollectionID FROM SMS_FullCollectionMembership WHERE ResourceID = 16777221')
    #
    # # One object for each row.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [object] One object for each row.
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface. Parameters,
    # return shape, and positional contract may change without notice.
    #
    # Positional parameters: none.
    #
    # Version: 2.0.20261106.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([object])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^\s*SELECT\s')]
        [string]$Query
    )

    process {
        Invoke-CMWmiQuery -Query $Query -Option 'Lazy' -ErrorAction Stop
    }
}

function Get-SiteFact {
    # .SYNOPSIS
    # Collects the facts that the ConfigMgr site holds about one device.
    #
    # .DESCRIPTION
    # Read only. The site drive must be open (Connect-InspectorSite). A failure in one
    # part (inventory, collections, deployments) is added to the Problems list and the
    # other parts continue. A failure of the device lookup throws.
    #
    # Cmdlets: Get-CMDevice (device record; its last hardware scan is the fallback),
    # Get-CMDeviceCollection (collection names), Get-CMDeployment (deployments),
    # Get-CMSoftwareUpdate (update details). Four reads have no cmdlet
    # and use Invoke-CMWmiQuery: the installed applications from hardware inventory,
    # the collection memberships of the device, the required updates of the device
    # and the hardware scan time of the device.
    #
    # .PARAMETER ComputerName
    # The device name, without a domain suffix.
    #
    # .PARAMETER Problems
    # A list that receives one text line for each part that failed.
    #
    # .EXAMPLE
    # $objSite = Get-SiteFact -ComputerName 'WS01' -Problems $listProblem
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
    # the part gets an empty value. Only the device lookup throws.
    #
    # Positional parameters: none.
    #
    # Version: 2.1.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_-]{1,63}$')]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Problems
    )

    process {
        # The cmdlet warns about a wildcard in Name even with DisableWildcardHandling.
        $arrResource = @(Get-CMDevice -Name $ComputerName -Fast -DisableWildcardHandling -ErrorAction Stop -WarningAction SilentlyContinue)
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
                HardwareScanClientTime = $null
                LastHardwareInventorySource = 'None'
                ApplicationReadComplete = $false
                ApplicationRowsByClass = $null
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
        $intResourceId = [int]$objResource.ResourceID

        $strLastHardwareInventory = ConvertTo-InspectionTimestamp -Value $objResource.LastHardwareScan

        # The site stores the hardware scan time as the local clock time of the client,
        # with no zone. The inventory check compares it with the cycle start in the
        # local time of the device, so the value stays unconverted.
        $strHardwareScanClientTime = $null
        try {
            $strScanQuery = 'SELECT LastHardwareScan FROM SMS_G_System_WORKSTATION_STATUS WHERE ResourceID = {0}' -f $intResourceId
            foreach ($objRow in @(Invoke-SiteQuery -Query $strScanQuery)) {
                $objScan = $objRow.LastHardwareScan
                if ($objScan -is [datetime]) {
                    $strHardwareScanClientTime = $objScan.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                } elseif (([string]$objScan) -match '^(\d{14})') {
                    $strHardwareScanClientTime = [datetime]::ParseExact($Matches[1], 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                }
            }
        } catch {
            Write-Debug -Message $_.Exception.Message
            $Problems.Add(('Site hardware scan time: {0}' -f $_.Exception.Message))
        }

        # One read serves the fact and the inventory check. With no row, the fact falls
        # back to the Get-CMDevice value.
        $strLastHardwareInventorySource = 'None'
        if (-not [string]::IsNullOrEmpty($strHardwareScanClientTime)) {
            $strLastHardwareInventorySource = 'SMS_G_System_WORKSTATION_STATUS'
        } elseif (-not [string]::IsNullOrEmpty($strLastHardwareInventory)) {
            $strLastHardwareInventorySource = 'Get-CMDevice'
        }

        $listApplication = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
        $boolApplicationReadComplete = $true
        $hashtableClassRows = [ordered]@{}
        foreach ($strClass in @('SMS_G_System_ADD_REMOVE_PROGRAMS', 'SMS_G_System_ADD_REMOVE_PROGRAMS_64')) {
            $hashtableClassRows[$strClass] = 0
            try {
                $strApplicationQuery = 'SELECT DisplayName, Version, Publisher FROM {0} WHERE ResourceID = {1}' -f $strClass, $intResourceId
                foreach ($objRow in @(Invoke-SiteQuery -Query $strApplicationQuery)) {
                    $hashtableClassRows[$strClass]++
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
                $boolApplicationReadComplete = $false
                $Problems.Add(('Site installed applications ({0}): {1}' -f $strClass, $_.Exception.Message))
            }
        }

        $listCollectionId = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $hashtableDirect = @{}
        try {
            $strMembershipQuery = 'SELECT CollectionID, IsDirect FROM SMS_FullCollectionMembership WHERE ResourceID = {0}' -f $intResourceId
            foreach ($objRow in @(Invoke-SiteQuery -Query $strMembershipQuery)) {
                if (([string]$objRow.CollectionID) -match '^[A-Za-z0-9]{8}$') {
                    $listCollectionId.Add([string]$objRow.CollectionID)
                    $objDirect = $objRow.PSObject.Properties['IsDirect']
                    $objDirectValue = $null
                    if ($null -ne $objDirect -and $null -ne $objDirect.Value) {
                        $objDirectValue = [bool]$objDirect.Value
                    }
                    $hashtableDirect[[string]$objRow.CollectionID] = $objDirectValue
                }
            }
        } catch {
            Write-Debug -Message $_.Exception.Message
            $Problems.Add(('Site collection membership: {0}' -f $_.Exception.Message))
        }

        # Each of the next three reads is one call for the whole site, then a filter.
        # One call for each collection or update took about ten times longer on the lab.
        $hashtableCollectionName = @{}
        if ($listCollectionId.Count -gt 0) {
            try {
                foreach ($objCollection in @(Get-CMDeviceCollection -ErrorAction Stop)) {
                    $hashtableCollectionName[[string]$objCollection.CollectionID] = [string]$objCollection.Name
                }
            } catch {
                Write-Debug -Message $_.Exception.Message
                $Problems.Add(('Site collection names: {0}' -f $_.Exception.Message))
            }
        }
        $listCollection = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
        foreach ($strCollectionId in $listCollectionId) {
            $strCollectionName = $null
            if ($hashtableCollectionName.ContainsKey($strCollectionId)) {
                $strCollectionName = $hashtableCollectionName[$strCollectionId]
            }
            $listCollection.Add([pscustomobject]@{
                    CollectionId = $strCollectionId
                    Name         = $strCollectionName
                    IsDirect     = $hashtableDirect[$strCollectionId]
                })
        }

        $listDeployment = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
        if ($listCollectionId.Count -gt 0) {
            try {
                foreach ($objRow in @(Get-CMDeployment -WarningAction SilentlyContinue -ErrorAction Stop)) {
                    if ($listCollectionId -notcontains [string]$objRow.CollectionID) {
                        continue
                    }
                    $listDeployment.Add([pscustomobject]@{
                            DeploymentId        = [string]$objRow.DeploymentID
                            CollectionId        = [string]$objRow.CollectionID
                            CollectionName      = [string]$objRow.CollectionName
                            Name                = [string]$objRow.SoftwareName
                            Type                = ConvertTo-DeploymentTypeName -FeatureType ([int]$objRow.FeatureType)
                            Intent              = ConvertTo-DeploymentIntentName -DeploymentIntent ([int]$objRow.DeploymentIntent)
                            EnforcementDeadline = ConvertTo-InspectionDeploymentTime -Value $objRow.EnforcementDeadline
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
            foreach ($objRow in @(Invoke-SiteQuery -Query $strRequiredQuery)) {
                $listUpdateId.Add([int]$objRow.CI_ID)
            }
            if ($listUpdateId.Count -gt 0) {
                foreach ($objUpdate in @(Get-CMSoftwareUpdate -Fast -IncludeUpgrade -ErrorAction Stop)) {
                    if ($listUpdateId -contains [int]$objUpdate.CI_ID -and -not [bool]$objUpdate.IsExpired) {
                        $listRequiredUpdate.Add([pscustomobject]@{
                                CIId         = [int]$objUpdate.CI_ID
                                ArticleId    = [string]$objUpdate.ArticleID
                                Title        = [string]$objUpdate.LocalizedDisplayName
                                Severity     = ConvertTo-UpdateSeverityName -Severity ([int]$objUpdate.Severity)
                                IsSuperseded = [bool]$objUpdate.IsSuperseded
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
            ClientInstalled       = [bool]$objResource.IsClient
            ClientVersion         = [string]$objResource.ClientVersion
            Active                = [bool]$objResource.IsActive
            OperatingSystem       = [string]$objResource.DeviceOS
            LastLogonUserName     = [string]$objResource.LastLogonUser
            LastHardwareInventory = $strLastHardwareInventory
            HardwareScanClientTime = $strHardwareScanClientTime
            LastHardwareInventorySource = $strLastHardwareInventorySource
            ApplicationReadComplete = $boolApplicationReadComplete
            ApplicationRowsByClass = [pscustomobject]$hashtableClassRows
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
    # $objDevice = Get-DeviceFact -ComputerName 'WS01'
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
    # Version: 1.1.20261110.0
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
                    $strHardwareCycleLocal = $null
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
                                $strHardwareCycleLocal = ([datetime]$objCycle.LastCycleStartedDate).ToString('yyyy-MM-ddTHH:mm:ss', $objCulture)
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
                        HardwareCycleLocalTime     = $strHardwareCycleLocal
                        LastDiscoveryDataCycle     = $strDiscoveryCycle
                    }
                }
            } catch {
                $listProblem.Add(('Client health: {0}' -f $_.Exception.Message))
            }

            $listInstalled = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
            try {
                # HKLM only: the 64-bit view and the 32-bit (WOW6432Node) view. Each entry
                # keeps its view and its key name, so two entries with the same name and
                # version stay two entries and Uninstall can find each key again.
                $arrKeyPath = @(
                    @{ View = '64-bit'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' }
                    @{ View = '32-bit'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' }
                )
                $scriptBlockText = {
                    param($objEntry, [string]$strProperty)
                    $objProperty = $objEntry.PSObject.Properties[$strProperty]
                    if ($null -eq $objProperty -or $null -eq $objProperty.Value) {
                        return ''
                    }
                    return [string]$objProperty.Value
                }
                $scriptBlockFlag = {
                    param($objEntry, [string]$strProperty)
                    $objProperty = $objEntry.PSObject.Properties[$strProperty]
                    $intFlag = 0
                    if ($null -ne $objProperty -and $null -ne $objProperty.Value -and [int]::TryParse([string]$objProperty.Value, [ref]$intFlag)) {
                        return $intFlag
                    }
                    return 0
                }
                foreach ($hashtableKeyPath in $arrKeyPath) {
                    foreach ($objEntry in @(Get-ItemProperty -Path $hashtableKeyPath.Path -ErrorAction SilentlyContinue)) {
                        $strName = & $scriptBlockText $objEntry 'DisplayName'
                        if ([string]::IsNullOrWhiteSpace($strName)) {
                            continue
                        }
                        $listInstalled.Add([pscustomobject]@{
                                Name                = $strName.Trim()
                                Version             = (& $scriptBlockText $objEntry 'DisplayVersion')
                                Publisher           = (& $scriptBlockText $objEntry 'Publisher')
                                InstallDate         = (& $scriptBlockText $objEntry 'InstallDate')
                                KeyName             = [string]$objEntry.PSChildName
                                View                = $hashtableKeyPath.View
                                UninstallString     = (& $scriptBlockText $objEntry 'UninstallString')
                                QuietUninstallString = (& $scriptBlockText $objEntry 'QuietUninstallString')
                                SystemComponent     = (& $scriptBlockFlag $objEntry 'SystemComponent')
                                WindowsInstaller    = (& $scriptBlockFlag $objEntry 'WindowsInstaller')
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
                            Id              = [string]$objApplication.Id
                            Revision        = [string]$objApplication.Revision
                            IsMachineTarget = [bool]$objApplication.IsMachineTarget
                            IsPreflightOnly = [bool]$objApplication.IsPreflightOnly
                            AllowedActions  = @($objApplication.AllowedActions | ForEach-Object { [string]$_ })
                            SoftwareVersion = [string]$objApplication.SoftwareVersion
                            Publisher       = [string]$objApplication.Publisher
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
                            UpdateId        = [string]$objUpdate.UpdateID
                            ComplianceState = [int]$objUpdate.ComplianceState
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
                InstalledApplications = @($listInstalled | Sort-Object -Property Name, Version, View, KeyName)
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
                    $intCompliance = -1
                    if ($null -ne $_.PSObject.Properties['ComplianceState']) {
                        $intCompliance = [int]$_.ComplianceState
                    }
                    $strUpdateId = ''
                    if ($null -ne $_.PSObject.Properties['UpdateId']) {
                        $strUpdateId = [string]$_.UpdateId
                    }
                    [pscustomobject]@{
                        Name            = [string]$_.Name
                        ArticleId       = [string]$_.ArticleId
                        UpdateId        = $strUpdateId
                        ComplianceState = $intCompliance
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

function Compare-DeviceInspectionApplication {
    # .SYNOPSIS
    # Compares the installed applications of the device with the site inventory.
    #
    # .DESCRIPTION
    # Joins the two lists by application name, ignoring case and spaces at the ends.
    # Status is Match when the name and the version are equal, Version differs when
    # only the name is equal, Device only or Inventory only when one list lacks the
    # application. Test-DeviceInspectionInventory uses this comparison. The
    # Applications panel does not show it.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # $arrDifference = Compare-DeviceInspectionApplication -Inspection $objInspection | Where-Object Status -ne 'Match'
    #
    # # One row for each application name that differs.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties Name, DeviceVersion, InventoryVersion, Publisher, Status.
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
        [pscustomobject]$Inspection
    )

    process {
        $hashtableDevice = @{}
        $hashtableSite = @{}
        $hashtablePublisher = @{}
        $hashtableDisplay = @{}
        if ($null -ne $Inspection.Device) {
            foreach ($objApplication in @($Inspection.Device.InstalledApplications)) {
                $strKey = ([string]$objApplication.Name).Trim().ToLowerInvariant()
                if (-not $hashtableDevice.ContainsKey($strKey)) {
                    $hashtableDevice[$strKey] = New-Object -TypeName 'System.Collections.Generic.List[string]'
                }
                $hashtableDevice[$strKey].Add([string]$objApplication.Version)
                $hashtablePublisher[$strKey] = [string]$objApplication.Publisher
                $hashtableDisplay[$strKey] = ([string]$objApplication.Name).Trim()
            }
        }
        if ($null -ne $Inspection.Site) {
            foreach ($objApplication in @($Inspection.Site.InstalledApplications)) {
                $strKey = ([string]$objApplication.Name).Trim().ToLowerInvariant()
                if (-not $hashtableSite.ContainsKey($strKey)) {
                    $hashtableSite[$strKey] = New-Object -TypeName 'System.Collections.Generic.List[string]'
                }
                $hashtableSite[$strKey].Add([string]$objApplication.Version)
                if (-not $hashtablePublisher.ContainsKey($strKey)) {
                    $hashtablePublisher[$strKey] = [string]$objApplication.Publisher
                }
                # The spelling of the site wins, as it did before the panel change.
                $hashtableDisplay[$strKey] = ([string]$objApplication.Name).Trim()
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
                Name             = $hashtableDisplay[$strKey]
                DeviceVersion    = $strDeviceVersion
                InventoryVersion = $strSiteVersion
                Publisher        = [string]$hashtablePublisher[$strKey]
                Status           = $strStatus
            }
        }
    }
}

function Split-DeviceInspectionCommand {
    # .SYNOPSIS
    # Splits a command line into a file path and arguments, as the device does.
    #
    # .DESCRIPTION
    # A quoted path ends at the closing quote. Without quotes the path is the text up
    # to and including the first .exe that ends a word. Returns $null when no path is
    # found, and when the path is relative with a separator. A full path (drive or
    # UNC) and a bare file name are accepted. The remote script block of the
    # application action holds its own copy of this rule, because a remote block
    # cannot call module functions. A test keeps the two equal.
    #
    # .PARAMETER Command
    # The command line, for example a QuietUninstallString.
    #
    # .EXAMPLE
    # (Split-DeviceInspectionCommand -Command '"C:\App\unins000.exe" /S').FilePath
    #
    # # C:\App\unins000.exe
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties FilePath, Arguments. $null when the command cannot be split.
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
        [AllowEmptyString()]
        [string]$Command
    )

    process {
        $strText = $Command.Trim()
        if ($strText.Length -eq 0) {
            return $null
        }
        $strPath = ''
        $strRest = ''
        if ($strText.StartsWith('"')) {
            $intEnd = $strText.IndexOf('"', 1)
            if ($intEnd -lt 2) {
                return $null
            }
            $strPath = $strText.Substring(1, $intEnd - 1)
            $strRest = $strText.Substring($intEnd + 1).Trim()
        } else {
            $objMatch = [regex]::Match($strText, '^(?<path>.+?\.exe)(?=\s|\z)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $objMatch.Success) {
                return $null
            }
            $strPath = $objMatch.Groups['path'].Value
            $strRest = $strText.Substring($strPath.Length).Trim()
        }
        $boolFull = $strPath -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/])'
        $boolBare = $strPath.IndexOfAny([char[]]@('\', '/')) -lt 0
        if (-not ($boolFull -or $boolBare)) {
            return $null
        }
        [pscustomobject]@{ FilePath = $strPath; Arguments = $strRest }
    }
}

#endregion Private helpers

#region Public functions

function Get-DeviceInspection {
    # .SYNOPSIS
    # Collects the facts of one device from a ConfigMgr site and from the device.
    #
    # .DESCRIPTION
    # Read-only. Reads the site with the ConfigurationManager cmdlets (the console
    # module) and reads the device live through one WinRM script block. It never
    # changes the site or the device. A part that fails is listed in Problems
    # and the other parts still run.
    #
    # Site facts: resource record, last hardware inventory, installed
    # applications, collection memberships, deployments targeted at those
    # collections. Device facts: operating system, installed applications (one
    # entry for each uninstall registry key under HKLM, with the view, the key name
    # and the uninstall strings), client health (service, version, management
    # point, inventory cycles), and the client application policy.
    #
    # .PARAMETER ComputerName
    # The device name. Letters, digits, hyphen, underscore and dot only.
    #
    # .PARAMETER SiteServer
    # The site server (SMS Provider) name. Omit it to skip the site facts.
    #
    # .PARAMETER SiteCode
    # The three-character site code. It is required with SiteServer.
    #
    # .PARAMETER Credential
    # An optional credential for the site server and the device.
    #
    # .PARAMETER SkipDevice
    # Skip the facts from the device itself.
    #
    # .EXAMPLE
    # $objInspection = Get-DeviceInspection -ComputerName 'WS01' -SiteServer 'sms01.example.com' -SiteCode 'XYZ' -Credential $objCredential
    #
    # # $objInspection.Site.Collections lists the collections of WS01.
    #
    # .EXAMPLE
    # Get-DeviceInspection -ComputerName 'WS01' -SkipDevice -SiteServer 'sms01.example.com' -SiteCode 'XYZ' | ConvertTo-Json -Depth 6
    #
    # # Prints the site facts as JSON. The device is not contacted.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] One object with ComputerName, InspectedAt, SiteServer,
    # SiteCode, Site, Device, InventoryCheck and Problems. Site and Device are
    # $null when skipped or when the connection failed. InventoryCheck is the
    # result of Test-DeviceInspectionInventory.
    #
    # .NOTES
    # Non-throwing contract: a connection or query failure is recorded in
    # Problems. The function throws only for invalid parameters, or when
    # SiteServer is omitted and SkipDevice is set.
    #
    # Positional parameters: position 0 is ComputerName. Other parameters are named.
    #
    # Version: 1.1.20261110.0
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
        if ($PSBoundParameters.ContainsKey('SiteServer') -and -not $PSBoundParameters.ContainsKey('SiteCode')) {
            throw 'SiteCode is required with SiteServer.'
        }

        $listProblem = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $strShortName = $ComputerName.Split('.')[0]
        $strResolvedSiteCode = $null
        $objSite = $null
        $objDevice = $null

        if ($PSBoundParameters.ContainsKey('SiteServer')) {
            $objConnection = $null
            try {
                $strResolvedSiteCode = $SiteCode
                $hashtableConnect = @{
                    SiteServer = $SiteServer
                    SiteCode   = $SiteCode
                }
                if ($PSBoundParameters.ContainsKey('Credential')) {
                    $hashtableConnect['Credential'] = $Credential
                }
                $objConnection = Connect-InspectorSite @hashtableConnect
                $objSite = Get-SiteFact -ComputerName $strShortName -Problems $listProblem
                if (-not $objSite.Found) {
                    $listProblem.Add(('Site: no device named {0} exists in site {1}.' -f $strShortName, $strResolvedSiteCode))
                }
            } catch {
                Write-Debug -Message $_.Exception.Message
                $listProblem.Add(('Site: {0}' -f $_.Exception.Message))
            } finally {
                Disconnect-InspectorSite -Connection $objConnection
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
        $objInspection = [pscustomobject]@{
            ComputerName   = $ComputerName
            InspectedAt    = ConvertTo-InspectionTimestamp -Value ([datetime]::UtcNow)
            SiteServer     = $strSiteServerText
            SiteCode       = $strResolvedSiteCode
            Site           = $objSite
            Device         = $objDevice
            InventoryCheck = $null
            Problems       = @()
        }
        try {
            $objInspection.InventoryCheck = Test-DeviceInspectionInventory -Inspection $objInspection
            if ($objInspection.InventoryCheck.State -eq 'Corrupt') {
                $listProblem.Add(('Inventory: {0}' -f $objInspection.InventoryCheck.Message))
            }
        } catch {
            Write-Debug -Message $_.Exception.Message
            $listProblem.Add(('Inventory check: {0}' -f $_.Exception.Message))
        }
        $objInspection.Problems = @($listProblem)
        $objInspection
    }
}

function Test-DeviceInspectionInventory {
    # .SYNOPSIS
    # Flags a device whose site inventory is current but whose installed applications differ.
    #
    # .DESCRIPTION
    # Read only. The site inventory is current when its hardware scan time is not
    # older than the start of the last hardware inventory cycle on the device, so the
    # site holds the last report. Both times are local clock times of the device: the
    # site stores the scan time that way, with no zone, and the cmdlet value of the
    # device record can lag the processed report by hours. Then the installed applications of the site inventory and of the
    # device must match. A difference means that the inventory on the site is
    # corrupt. A device application whose install date is on or after the day of the
    # last cycle does not count, because the next cycle reports it.
    #
    # States: Corrupt (current, applications differ), Current (current, no
    # difference), NotCurrent (the site has not processed the last cycle yet),
    # Unknown (the site or the device part is missing, or a date is missing).
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # (Test-DeviceInspectionInventory -Inspection $objInspection).State
    #
    # # Corrupt, Current, NotCurrent or Unknown.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties: State, SiteInventory, DeviceCycle, Differences,
    # Applications, Message.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.1.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection
    )

    process {
        $scriptBlockResult = {
            param($strState, $strSite, $strCycle, $arrApplication, $strMessage)
            [pscustomobject]@{
                State         = $strState
                SiteInventory = $strSite
                DeviceCycle   = $strCycle
                Differences   = @($arrApplication).Count
                Applications  = @($arrApplication)
                Message       = $strMessage
            }
        }
        $objSite = $Inspection.Site
        $objDevice = $Inspection.Device
        if ($null -eq $objSite -or -not $objSite.Found -or $null -eq $objDevice -or $null -eq $objDevice.Client) {
            return (& $scriptBlockResult 'Unknown' $null $null @() 'The check needs the site record and the client facts of the device.')
        }
        $strSite = $null
        $strCycle = $null
        if ($null -ne $objSite.PSObject.Properties['HardwareScanClientTime']) {
            $strSite = [string]$objSite.HardwareScanClientTime
        }
        if ($null -ne $objDevice.Client.PSObject.Properties['HardwareCycleLocalTime']) {
            $strCycle = [string]$objDevice.Client.HardwareCycleLocalTime
        }
        $objCulture = [System.Globalization.CultureInfo]::InvariantCulture
        $enumStyle = [System.Globalization.DateTimeStyles]::None
        $datetimeSite = [datetime]::MinValue
        $datetimeCycle = [datetime]::MinValue
        if ([string]::IsNullOrEmpty($strCycle)) {
            return (& $scriptBlockResult 'Unknown' $strSite $strCycle @() 'The device has no hardware inventory cycle record. A cycle runs now, or none ran since the record was deleted.')
        }
        if (-not [datetime]::TryParseExact($strSite, 'yyyy-MM-ddTHH:mm:ss', $objCulture, $enumStyle, [ref]$datetimeSite) -or -not [datetime]::TryParseExact($strCycle, 'yyyy-MM-ddTHH:mm:ss', $objCulture, $enumStyle, [ref]$datetimeCycle)) {
            return (& $scriptBlockResult 'Unknown' $strSite $strCycle @() 'The site inventory date or the last hardware inventory cycle of the device is missing.')
        }
        if ($datetimeSite -lt $datetimeCycle) {
            return (& $scriptBlockResult 'NotCurrent' $strSite $strCycle @() ('The site inventory scan ({0}, device local time) is older than the last hardware inventory cycle of the device ({1}). The site has not processed that report yet.' -f $strSite, $strCycle))
        }
        $objReadComplete = $objSite.PSObject.Properties['ApplicationReadComplete']
        if ($null -ne $objReadComplete -and -not [bool]$objReadComplete.Value) {
            return (& $scriptBlockResult 'Unknown' $strSite $strCycle @() 'The site application inventory was not read completely. See the Problems panel.')
        }
        $objDeviceProblems = $objDevice.PSObject.Properties['Problems']
        if ($null -ne $objDeviceProblems -and @($objDeviceProblems.Value | Where-Object { ([string]$_) -like 'Installed applications:*' }).Count -gt 0) {
            return (& $scriptBlockResult 'Unknown' $strSite $strCycle @() 'The installed applications of the device were not read. See the Problems panel.')
        }
        $objClassRows = $objSite.PSObject.Properties['ApplicationRowsByClass']
        if ($null -ne $objClassRows -and $null -ne $objClassRows.Value -and @($objDevice.InstalledApplications).Count -gt 0) {
            foreach ($objClass in $objClassRows.Value.PSObject.Properties) {
                if ([int]$objClass.Value -eq 0) {
                    return (& $scriptBlockResult 'Unknown' $strSite $strCycle @() ('The site inventory has no rows in {0}. The hardware inventory class can be off in the client settings, or the device has no entries of that kind (for example no 64-bit entries on 32-bit Windows).' -f $objClass.Name))
                }
            }
        }
        $strCycleDay = $datetimeCycle.ToString('yyyyMMdd', $objCulture)
        $arrDateFormat = [string[]]@('yyyyMMdd', 'yyyy-MM-dd', 'yyyy/MM/dd', 'M/d/yyyy', 'MM/dd/yyyy')
        $hashtableInstallDate = @{}
        foreach ($objApplication in @($objDevice.InstalledApplications)) {
            $objDate = $objApplication.PSObject.Properties['InstallDate']
            $datetimeInstall = [datetime]::MinValue
            if ($null -ne $objDate -and [datetime]::TryParseExact(([string]$objDate.Value).Trim(), $arrDateFormat, $objCulture, $enumStyle, [ref]$datetimeInstall)) {
                $strInstallDay = $datetimeInstall.ToString('yyyyMMdd', $objCulture)
                $strKey = ([string]$objApplication.Name).Trim().ToLowerInvariant()
                if (-not $hashtableInstallDate.ContainsKey($strKey) -or $strInstallDay -gt $hashtableInstallDate[$strKey]) {
                    $hashtableInstallDate[$strKey] = $strInstallDay
                }
            }
        }
        $listApplication = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($objRow in @(Compare-DeviceInspectionApplication -Inspection $Inspection)) {
            if ($objRow.Status -eq 'Match') {
                continue
            }
            $strKey = ([string]$objRow.Name).Trim().ToLowerInvariant()
            if ($objRow.Status -ne 'Inventory only' -and $hashtableInstallDate.ContainsKey($strKey) -and $hashtableInstallDate[$strKey] -ge $strCycleDay) {
                continue
            }
            $listApplication.Add(('{0}: {1}' -f $objRow.Status, $objRow.Name))
        }
        if ($listApplication.Count -eq 0) {
            return (& $scriptBlockResult 'Current' $strSite $strCycle @() 'The site inventory is current and its applications match the device.')
        }
        & $scriptBlockResult 'Corrupt' $strSite $strCycle $listApplication.ToArray() ('The site inventory is current (scan {0}, device local time), but {1} applications differ from the device. The inventory on the site can be corrupt. An application removed or changed after the last cycle also shows as a difference. Repair inventory runs a full hardware inventory.' -f $strSite, $listApplication.Count)
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
    # Get-DeviceInspection -ComputerName 'WS01' -SiteServer 'sms01.example.com' -SiteCode 'XYZ' | ConvertTo-DeviceInspectionReport
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
    # Version: 1.1.20261110.0
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [pscustomobject]$Inspection,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 2147483647)]
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
            $listLine.Add(('  Last hardware inventory:   {0}' -f (Get-SiteHardwareInventoryFact -Site $objSite).Value))
            $arrCollection = @($objSite.Collections | ForEach-Object { '  {0}  {1}' -f $_.CollectionId, $_.Name })
            $arrDeployment = @($objSite.Deployments | ForEach-Object { '  {0} | {1} | {2} | via {3}' -f $_.Name, $_.Type, $_.Intent, $_.CollectionName })
            $arrSiteApplication = @($objSite.InstalledApplications | ForEach-Object { '  {0} {1}' -f $_.Name, $_.Version })
        }
        $listLine.Add('')

        if ($null -ne $Inspection.Device) {
            $arrDeviceApplication = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $Inspection | ForEach-Object { '  {0} {1} | {2} | {3} | {4}' -f $_.Name, $_.Version, $_.Type, $_.View, $_.KeyName })
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
    # $objInput = Test-DeviceInspectorInput -ComputerName 'ws01' -SiteServer 'sms01.example.com' -SiteCode 'XYZ'
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
        if (-not [string]::IsNullOrEmpty($strServer) -and [string]::IsNullOrEmpty($strCode)) {
            $listError.Add('A site server needs a site code. Enter it in Options.')
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

function Get-SiteHardwareInventoryFact {
    # .SYNOPSIS
    # Chooses the text of the Last hardware inventory fact of the site record.
    #
    # .DESCRIPTION
    # The panel, the text report and the HTML export use this one function. The JSON
    # export holds the same choice in LastHardwareInventorySource.
    #
    # When the site has a row in SMS_G_System_WORKSTATION_STATUS, the fact is that scan
    # time. The site stores it as the local clock time of the client, with no zone, so
    # the tool does not convert it. The label says so.
    #
    # When the class has no row (or the read failed), the fact is the Get-CMDevice
    # value in UTC. The label says that this value can lag a processed report.
    #
    # .PARAMETER Site
    # The Site object that Get-SiteFact returns, with Found set to $true.
    #
    # .EXAMPLE
    # $objFact = Get-SiteHardwareInventoryFact -Site $objSite
    #
    # # $objFact.Value = '2026-11-10T19:22:32 (device local time)'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties Value (text, empty when the site has no date) and
    # Source ('SMS_G_System_WORKSTATION_STATUS', 'Get-CMDevice' or 'None').
    #
    # .NOTES
    # PRIVATE/INTERNAL HELPER. Not part of the public API surface.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Site
    )

    process {
        $strClientTime = $null
        $objClientTimeProperty = $Site.PSObject.Properties['HardwareScanClientTime']
        if ($null -ne $objClientTimeProperty) {
            $strClientTime = [string]$objClientTimeProperty.Value
        }
        if (-not [string]::IsNullOrEmpty($strClientTime)) {
            return [pscustomobject]@{
                Value  = '{0} (device local time)' -f $strClientTime
                Source = 'SMS_G_System_WORKSTATION_STATUS'
            }
        }
        $strCmdletTime = [string]$Site.LastHardwareInventory
        if (-not [string]::IsNullOrEmpty($strCmdletTime)) {
            return [pscustomobject]@{
                Value  = '{0} (UTC, from Get-CMDevice; can lag a processed report)' -f $strCmdletTime
                Source = 'Get-CMDevice'
            }
        }
        [pscustomobject]@{ Value = ''; Source = 'None' }
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
    # Version: 1.0.20261111.0
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
                & $scriptBlockRow 'Site record' 'Last hardware inventory' (Get-SiteHardwareInventoryFact -Site $Inspection.Site).Value
            } else {
                & $scriptBlockRow 'Site record' 'Status' 'The site has no record of this device.'
            }
        }
        $objCheckProperty = $Inspection.PSObject.Properties['InventoryCheck']
        if ($null -ne $objCheckProperty -and $null -ne $objCheckProperty.Value) {
            & $scriptBlockRow 'Inventory check' 'State' $objCheckProperty.Value.State
            & $scriptBlockRow 'Inventory check' 'Result' $objCheckProperty.Value.Message
            foreach ($strApplication in @($objCheckProperty.Value.Applications)) {
                & $scriptBlockRow 'Inventory check' 'Difference' $strApplication
            }
        }
    }
}

function ConvertTo-DeviceInspectionApplicationRow {
    # .SYNOPSIS
    # Turns the uninstall registry keys that the device reported into panel rows.
    #
    # .DESCRIPTION
    # One row for each entry that the device reported from the uninstall registry keys
    # (HKLM, 64-bit and 32-bit view). The panel is a live view of these keys. It does
    # not compare them with the site inventory.
    #
    # Type is MSI when the key name is a product code in braces and the uninstall
    # string starts with msiexec, or the entry has WindowsInstaller 1. Every other entry
    # is EXE.
    #
    # Uninstall and Repair rules. MSI: both are on. EXE with a quiet uninstall string:
    # Uninstall is on and Repair is off, because the key holds no repair command. EXE
    # without a quiet uninstall string: both are off, because the tool does not guess
    # silent switches. A system component (SystemComponent 1): both are off. A disabled
    # action has its reason in UninstallReason or RepairReason. Reason holds the first
    # of the two that is not empty.
    #
    # The rows keep the order of the device list, which Get-DeviceFact sorts by name,
    # version, view and key name.
    #
    # UninstallCommand and RepairCommand hold the command line for display in the
    # confirmation text. The device builds the real command line from its own registry
    # key. The window never sends a command line.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .EXAMPLE
    # $arrRow = ConvertTo-DeviceInspectionApplicationRow -Inspection $objInspection
    #
    # # One row for each uninstall key of the device.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties Name, Version, Publisher, InstallDate, Type (MSI or
    # EXE), View (64-bit or 32-bit), KeyName, CanUninstall, CanRepair, Reason,
    # UninstallReason, RepairReason, UninstallCommand, RepairCommand.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version 2 replaced the comparison with the site inventory (breaking change):
    # the properties DeviceVersion, InventoryVersion, Status and the Client* properties
    # are gone.
    #
    # Version: 2.0.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection
    )

    process {
        if ($null -eq $Inspection.Device -or $null -eq $Inspection.Device.PSObject.Properties['InstalledApplications']) {
            return
        }
        $strGuidPattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}\z'
        $strMsiexecPattern = '^\s*"?(?:[^"]*[\\/])?msiexec(?:\.exe)?"?(?:\s|\z)'
        $strKeyNamePattern = '^[^\\/:*?"<>|\x00-\x1F]{1,255}\z'
        $scriptBlockText = {
            param($objEntry, [string]$strProperty)
            $objProperty = $objEntry.PSObject.Properties[$strProperty]
            if ($null -eq $objProperty -or $null -eq $objProperty.Value) {
                return ''
            }
            return [string]$objProperty.Value
        }
        $scriptBlockFlag = {
            param($objEntry, [string]$strProperty)
            $objProperty = $objEntry.PSObject.Properties[$strProperty]
            $intFlag = 0
            if ($null -ne $objProperty -and $null -ne $objProperty.Value -and [int]::TryParse([string]$objProperty.Value, [ref]$intFlag)) {
                return $intFlag
            }
            return 0
        }
        foreach ($objEntry in @($Inspection.Device.InstalledApplications)) {
            $strKeyName = & $scriptBlockText $objEntry 'KeyName'
            $strView = & $scriptBlockText $objEntry 'View'
            $strUninstall = & $scriptBlockText $objEntry 'UninstallString'
            $strQuiet = & $scriptBlockText $objEntry 'QuietUninstallString'
            $boolMsi = ($strKeyName -match $strGuidPattern) -and (($strUninstall -match $strMsiexecPattern) -or ((& $scriptBlockFlag $objEntry 'WindowsInstaller') -eq 1))
            $strType = 'EXE'
            if ($boolMsi) {
                $strType = 'MSI'
            }
            $strUninstallReason = ''
            $strRepairReason = ''
            $strUninstallCommand = ''
            $strRepairCommand = ''
            if ((& $scriptBlockFlag $objEntry 'SystemComponent') -eq 1) {
                $strUninstallReason = 'This entry is a system component, part of another product.'
                $strRepairReason = $strUninstallReason
            } elseif (($strView -ne '64-bit' -and $strView -ne '32-bit') -or $strKeyName -notmatch $strKeyNamePattern) {
                $strUninstallReason = 'The device did not report a usable registry view and key name for this entry. Inspect the device again.'
                $strRepairReason = $strUninstallReason
            } elseif ($boolMsi) {
                $strUninstallCommand = 'msiexec.exe /x {0} /qn /norestart REBOOT=ReallySuppress' -f $strKeyName
                $strRepairCommand = 'msiexec.exe /i {0} REINSTALL=ALL REINSTALLMODE=omus /qn /norestart REBOOT=ReallySuppress' -f $strKeyName
            } elseif (-not [string]::IsNullOrWhiteSpace($strQuiet) -and $null -eq (Split-DeviceInspectionCommand -Command ([System.Environment]::ExpandEnvironmentVariables($strQuiet.Trim())))) {
                $strUninstallReason = 'The quiet uninstall string has no file path that ends in .exe, or the path is relative, so the tool cannot run it. The tool does not guess the command.'
                $strRepairReason = $strUninstallReason
            } elseif (-not [string]::IsNullOrWhiteSpace($strQuiet)) {
                $strUninstallCommand = $strQuiet.Trim()
                $strRepairReason = 'There is no documented repair command for this installer.'
            } else {
                $strUninstallReason = 'The entry has no quiet uninstall string. The tool does not guess silent switches.'
                $strRepairReason = $strUninstallReason
            }
            $strReason = $strUninstallReason
            if ([string]::IsNullOrEmpty($strReason)) {
                $strReason = $strRepairReason
            }
            [pscustomobject]@{
                Name             = ([string]$objEntry.Name).Trim()
                Version          = & $scriptBlockText $objEntry 'Version'
                Publisher        = & $scriptBlockText $objEntry 'Publisher'
                InstallDate      = & $scriptBlockText $objEntry 'InstallDate'
                Type             = $strType
                View             = $strView
                KeyName          = $strKeyName
                CanUninstall     = [string]::IsNullOrEmpty($strUninstallReason)
                CanRepair        = [string]::IsNullOrEmpty($strRepairReason)
                Reason           = $strReason
                UninstallReason  = $strUninstallReason
                RepairReason     = $strRepairReason
                UninstallCommand = $strUninstallCommand
                RepairCommand    = $strRepairCommand
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
                    UpdateId = ''
                    Required = $false
                }
            }
        }
        if ($null -ne $Inspection.Device -and $null -ne $Inspection.Device.PSObject.Properties['PendingUpdates']) {
            foreach ($objUpdate in @($Inspection.Device.PendingUpdates)) {
                $strRowUpdateId = ''
                if ($null -ne $objUpdate.PSObject.Properties['UpdateId']) {
                    $strRowUpdateId = [string]$objUpdate.UpdateId
                }
                # Installable: missing on the device, and no install job in progress or complete.
                $boolRequired = $null -ne $objUpdate.PSObject.Properties['ComplianceState'] -and [int]$objUpdate.ComplianceState -eq 0
                if ($boolRequired -and $null -ne $objUpdate.PSObject.Properties['EvaluationState']) {
                    $boolRequired = @(0, 1, 13) -contains [int]$objUpdate.EvaluationState
                }
                [pscustomobject]@{
                    Source = 'Device'
                    Article = $(if ([string]::IsNullOrEmpty($objUpdate.ArticleId)) { '' } else { 'KB{0}' -f $objUpdate.ArticleId })
                    Severity = ''
                    State = [string]$objUpdate.State
                    Deadline = [string]$objUpdate.Deadline
                    Title = [string]$objUpdate.Name
                    UpdateId = $strRowUpdateId
                    Required = $boolRequired
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
    # [pscustomobject] Properties CollectionId, Name, Membership (Direct rule, Query
    # or other rule, or Unknown), IsDirect ($true, $false or $null), IsBuiltIn, IsRemoved.
    #
    # .NOTES
    # This function does not support positional parameters.
    #
    # Version: 1.0.20261111.0
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
            $objDirect = $null
            if ($null -ne $objCollection.PSObject.Properties['IsDirect']) {
                $objDirect = $objCollection.IsDirect
            }
            $strMembership = 'Unknown'
            if ($true -eq $objDirect) {
                $strMembership = 'Direct rule'
            } elseif ($false -eq $objDirect) {
                $strMembership = 'Query or other rule'
            }
            [pscustomobject]@{
                CollectionId = [string]$objCollection.CollectionId
                Name = [string]$objCollection.Name
                Membership = $strMembership
                IsDirect = $objDirect
                IsBuiltIn = ([string]$objCollection.CollectionId).StartsWith('SMS', [System.StringComparison]::OrdinalIgnoreCase)
                IsRemoved = $false
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
    # Version: 1.1.20261110.0
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
        $listLine.Add((& $scriptBlockTable 'Installed applications' $arrApplication @('Name', 'Version', 'Publisher', 'InstallDate', 'Type', 'View', 'KeyName')))
        $arrUpdate = @(ConvertTo-DeviceInspectionUpdateRow -Inspection $Inspection)
        $listLine.Add((& $scriptBlockTable 'Updates' $arrUpdate @('Source', 'Article', 'Severity', 'State', 'Deadline', 'Title')))
        $arrCollection = @(ConvertTo-DeviceInspectionCollectionRow -Inspection $Inspection)
        $listLine.Add((& $scriptBlockTable 'Collections' $arrCollection @('CollectionId', 'Name', 'Membership')))
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

function Write-DeviceInspectionFullLog {
    # .SYNOPSIS
    # Writes the full report of an inspection to the log file of the session.
    #
    # .DESCRIPTION
    # Builds the report with no list limit and writes it with one Write-Log call,
    # between a start line and an end line. One call keeps the log write short on
    # the window thread. The function does not throw. It returns $false when the
    # report cannot be built or the log file did not grow, because Write-Log drops
    # a line without an error after three failed writes.
    #
    # .PARAMETER Inspection
    # The object that Get-DeviceInspection returns.
    #
    # .PARAMETER LogPath
    # The log file that Initialize-Logging set for this session.
    #
    # .EXAMPLE
    # $boolWritten = Write-DeviceInspectionFullLog -Inspection $objInspection -LogPath $strLogPath
    #
    # # $boolWritten is $true when the report is in the log file.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [bool]
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Inspection,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath
    )

    process {
        try {
            $intLengthBefore = 0
            if (Test-Path -LiteralPath $LogPath) {
                $intLengthBefore = (Get-Item -LiteralPath $LogPath).Length
            }
            $strReport = ConvertTo-DeviceInspectionReport -Inspection $Inspection -MaximumListedItems ([int]::MaxValue)
            $strTitle = 'Full report: {0}' -f $Inspection.ComputerName
            $strText = '----- {0} -----{1}{2}{1}----- end of {0} -----' -f $strTitle, [System.Environment]::NewLine, ($strReport -replace "`n", [System.Environment]::NewLine)
            Write-Log -Message $strText -Quiet
            if (-not (Test-Path -LiteralPath $LogPath)) {
                return $false
            }
            return ((Get-Item -LiteralPath $LogPath).Length -gt $intLengthBefore)
        } catch {
            Write-Debug -Message $_.Exception.Message
            return $false
        }
    }
}

function Get-DeviceInspectorCollectionList {
    # .SYNOPSIS
    # Reads the device collections of the site for the collection browser.
    #
    # .DESCRIPTION
    # Read only. Opens the site drive, reads all device collections with one
    # Get-CMDeviceCollection call, and closes the drive. The objects have the
    # property names that the collection browser of the window reads. The browser
    # shows a flat list, so FolderID is 0 for every collection.
    #
    # .PARAMETER SiteServer
    # The SMS Provider computer.
    #
    # .PARAMETER SiteCode
    # The site code.
    #
    # .PARAMETER Credential
    # An optional credential for the site drive.
    #
    # .EXAMPLE
    # $arrCollection = @(Get-DeviceInspectorCollectionList -SiteServer 'sms01' -SiteCode 'XYZ')
    #
    # # One object for each device collection.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties CollectionID, Name, MemberCount, LimitToCollectionID,
    # IsBuiltIn, FolderID.
    #
    # .NOTES
    # Throws when the site cannot be opened or read.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteServer,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9]{3}\z')]
        [string]$SiteCode,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        $hashtableConnect = @{ SiteServer = $SiteServer; SiteCode = $SiteCode }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableConnect['Credential'] = $Credential
        }
        $objConnection = $null
        try {
            $objConnection = Connect-InspectorSite @hashtableConnect
            foreach ($objCollection in @(Get-CMDeviceCollection -ErrorAction Stop)) {
                $strId = [string]$objCollection.CollectionID
                [pscustomobject]@{
                    CollectionID        = $strId
                    Name                = [string]$objCollection.Name
                    MemberCount         = [int]$objCollection.MemberCount
                    LimitToCollectionID = [string]$objCollection.LimitToCollectionID
                    IsBuiltIn           = $strId.StartsWith('SMS', [System.StringComparison]::OrdinalIgnoreCase)
                    FolderID            = 0
                }
            }
        } finally {
            Disconnect-InspectorSite -Connection $objConnection
        }
    }
}

function Select-DeviceInspectorAddableCollection {
    # .SYNOPSIS
    # Keeps the collections that the collection browser offers for an add.
    #
    # .DESCRIPTION
    # Leaves out built-in collections and the collections where the inspection
    # shows a direct rule for the device that is not removed. A row with an unknown
    # rule stays, because the add checks the rule on the site.
    #
    # .PARAMETER Collections
    # The objects that Get-DeviceInspectorCollectionList returns.
    #
    # .PARAMETER Rows
    # The collection rows of the inspection (ConvertTo-DeviceInspectionCollectionRow).
    #
    # .EXAMPLE
    # $arrChoice = @(Select-DeviceInspectorAddableCollection -Collections $arrList -Rows $arrRow)
    #
    # # The collections to show in the browser.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] The kept collections.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Collections,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Rows
    )

    process {
        $arrDirect = @($Rows | Where-Object { $null -ne $_ -and $true -eq $_.IsDirect -and -not ($null -ne $_.PSObject.Properties['IsRemoved'] -and $_.IsRemoved) } | ForEach-Object { [string]$_.CollectionId })
        foreach ($objCollection in $Collections) {
            if ($null -eq $objCollection -or [bool]$objCollection.IsBuiltIn -or $arrDirect -contains [string]$objCollection.CollectionID) {
                continue
            }
            $objCollection
        }
    }
}

function Get-DeviceInspectorDeviceList {
    # .SYNOPSIS
    # Lists the devices of the site by name pattern, by collection, or both.
    #
    # .DESCRIPTION
    # Read only. Opens the site drive, reads the devices with Get-CMDevice (name
    # pattern, * and ? as wildcards) or with Get-CMCollectionMember (members of one
    # collection, optionally filtered by the name pattern), and closes the drive.
    # Collection members that are not systems (ResourceType 5) are left out. At most
    # Maximum devices are returned; Truncated says when the site had more.
    #
    # .PARAMETER SiteServer
    # The SMS Provider computer.
    #
    # .PARAMETER SiteCode
    # The site code.
    #
    # .PARAMETER NamePattern
    # Optional. A device name or a pattern with * and ?.
    #
    # .PARAMETER CollectionId
    # Optional. The eight-character collection ID.
    #
    # .PARAMETER Maximum
    # The most devices to return. The default is 500.
    #
    # .PARAMETER Credential
    # An optional credential for the site drive.
    #
    # .EXAMPLE
    # $objList = Get-DeviceInspectorDeviceList -SiteServer 'sms01' -SiteCode 'XYZ' -NamePattern 'WS*'
    #
    # # $objList.Devices holds one row for each device whose name starts with WS.
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [pscustomobject] Properties Devices (rows with Name, ResourceId, Client, Active,
    # ClientVersion, OperatingSystem, LastLogonUser, LastActive), Total, Truncated.
    #
    # .NOTES
    # Throws when neither NamePattern nor CollectionId is given, or when the site
    # cannot be opened or read.
    #
    # Positional parameters: none.
    #
    # Version: 1.0.20261111.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteServer,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9]{3}\z')]
        [string]$SiteCode,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [ValidatePattern('^([A-Za-z0-9_.*?-]{1,63})?\z')]
        [string]$NamePattern = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [ValidatePattern('^([A-Za-z0-9]{8})?\z')]
        [string]$CollectionId = '',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100000)]
        [int]$Maximum = 500,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential
    )

    process {
        if ([string]::IsNullOrEmpty($NamePattern) -and [string]::IsNullOrEmpty($CollectionId)) {
            throw 'Enter a name pattern, a collection ID, or both.'
        }
        # A pattern of wildcards only would read every device of the site before the limit.
        if ([string]::IsNullOrEmpty($CollectionId) -and $NamePattern -notmatch '[A-Za-z0-9]') {
            throw 'A name pattern without a collection needs at least one letter or digit.'
        }
        $scriptBlockValue = {
            param($objItem, [string]$strName)
            $objProperty = $objItem.PSObject.Properties[$strName]
            if ($null -eq $objProperty) {
                return $null
            }
            $objProperty.Value
        }
        $hashtableConnect = @{ SiteServer = $SiteServer; SiteCode = $SiteCode }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $hashtableConnect['Credential'] = $Credential
        }
        $objConnection = $null
        try {
            $objConnection = Connect-InspectorSite @hashtableConnect
            if ([string]::IsNullOrEmpty($CollectionId)) {
                $arrRaw = @(Get-CMDevice -Name $NamePattern -Fast -ErrorAction Stop)
            } else {
                $hashtableMember = @{ CollectionId = $CollectionId; ErrorAction = 'Stop' }
                if (-not [string]::IsNullOrEmpty($NamePattern)) {
                    $hashtableMember['Name'] = $NamePattern
                }
                $arrRaw = @(Get-CMCollectionMember @hashtableMember | Where-Object {
                        $objType = & $scriptBlockValue $_ 'ResourceType'
                        $null -eq $objType -or [int]$objType -eq 5
                    })
            }
            $arrSorted = @($arrRaw | Sort-Object -Property { [string](& $scriptBlockValue $_ 'Name') })
            $listDevice = New-Object -TypeName 'System.Collections.Generic.List[pscustomobject]'
            foreach ($objItem in @($arrSorted | Select-Object -First $Maximum)) {
                $objLastActive = & $scriptBlockValue $objItem 'LastActiveTime'
                $listDevice.Add([pscustomobject]@{
                        Name            = [string](& $scriptBlockValue $objItem 'Name')
                        ResourceId      = [long](& $scriptBlockValue $objItem 'ResourceID')
                        Client          = [bool](& $scriptBlockValue $objItem 'IsClient')
                        Active          = [bool](& $scriptBlockValue $objItem 'IsActive')
                        ClientVersion   = [string](& $scriptBlockValue $objItem 'ClientVersion')
                        OperatingSystem = [string](& $scriptBlockValue $objItem 'DeviceOS')
                        LastLogonUser   = [string](& $scriptBlockValue $objItem 'LastLogonUser')
                        LastActive      = ConvertTo-InspectionTimestamp -Value $objLastActive
                    })
            }
            [pscustomobject]@{
                Devices   = $listDevice.ToArray()
                Total     = $arrSorted.Count
                Truncated = ($arrSorted.Count -gt $Maximum)
            }
        } finally {
            Disconnect-InspectorSite -Connection $objConnection
        }
    }
}

function Get-DeviceInspectorActionBlock {
    # .SYNOPSIS
    # Returns the reason why an action cannot start now, or an empty string.
    #
    # .DESCRIPTION
    # The window calls it before it opens a confirmation and before it turns a menu
    # entry on. A device action needs an inspection that reached the device. A site
    # action needs an inspection that found the device on the site. A device runs one
    # action at a time: when Run holds a running action of ComputerName, the function
    # returns that reason. A running action of another device does not block.
    #
    # .PARAMETER Inspection
    # The inspection on screen, or $null.
    #
    # .PARAMETER ActionsEnabled
    # The state of the Enable actions switch.
    #
    # .PARAMETER Busy
    # $true while exclusive background work runs: an inspection, a search or a change of
    # the site. A running device action does not set it.
    #
    # .PARAMETER Kind
    # Device or Site.
    #
    # .PARAMETER Run
    # The running device actions, from New-DeviceInspectorActionRun. Optional.
    #
    # .PARAMETER ComputerName
    # The device that the action targets. Optional. Without it the function does not check
    # the running actions.
    #
    # .PARAMETER ResourceId
    # The site resource ID of the device, when the inspection knows it. Optional.
    #
    # .EXAMPLE
    # Get-DeviceInspectorActionBlock -Inspection $null -ActionsEnabled $true -Busy $false -Kind Site
    #
    # # Returns 'Inspect a device that the site knows first.'
    #
    # .INPUTS
    # None. You can't pipe objects to this function.
    #
    # .OUTPUTS
    # [string] The reason, or an empty string when the action can start.
    #
    # .NOTES
    # Positional parameters: none.
    #
    # Version: 1.2.20261110.0
    [CmdletBinding(PositionalBinding = $false)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Inspection,

        [Parameter(Mandatory = $true)]
        [bool]$ActionsEnabled,

        [Parameter(Mandatory = $true)]
        [bool]$Busy,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Device', 'Site')]
        [string]$Kind,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Run = @(),

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ComputerName = '',

        [Parameter(Mandatory = $false)]
        [long]$ResourceId = 0
    )

    process {
        if (-not $ActionsEnabled) {
            return 'Turn on Enable actions first.'
        }
        if ($Busy) {
            return 'Wait for the running task to end.'
        }
        $strRunBlock = Get-DeviceInspectorRunBlock -Run @($Run) -ComputerName $ComputerName -ResourceId $ResourceId
        if (-not [string]::IsNullOrEmpty($strRunBlock)) {
            return $strRunBlock
        }
        if ($Kind -eq 'Device') {
            if ($null -eq $Inspection -or $null -eq $Inspection.PSObject.Properties['Device'] -or $null -eq $Inspection.Device) {
                return 'Inspect a device that answers first.'
            }
            return ''
        }
        if ($null -eq $Inspection -or $null -eq $Inspection.PSObject.Properties['Site'] -or $null -eq $Inspection.Site -or -not $Inspection.Site.Found -or [string]::IsNullOrEmpty([string]$Inspection.SiteServer)) {
            return 'Inspect a device that the site knows first.'
        }
        ''
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
    # $strPath = Write-DeviceInspectionFile -Path 'C:\reports\ws01.html' -Text $strHtml
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

# The actions live in their own file, so the read-only guard test can parse this file alone.
. (Join-Path -Path $PSScriptRoot -ChildPath 'DeviceInspectorActions.ps1')

Export-ModuleMember -Function 'Get-DeviceInspection', 'ConvertTo-DeviceInspectionReport', 'Test-DeviceInspectorInput', 'Test-DeviceInspectorConsole', 'ConvertTo-DeviceInspectionFactRow', 'ConvertTo-DeviceInspectionApplicationRow', 'ConvertTo-DeviceInspectionUpdateRow', 'ConvertTo-DeviceInspectionCollectionRow', 'ConvertTo-DeviceInspectionDeploymentRow', 'ConvertTo-DeviceInspectionJson', 'ConvertTo-DeviceInspectionHtml', 'Write-DeviceInspectionFile', 'Write-DeviceInspectionFullLog', 'Test-DeviceInspectionInventory', 'Get-DeviceInspectorActionBlock', 'Get-DeviceInspectorCollectionList', 'Select-DeviceInspectorAddableCollection', 'Get-DeviceInspectorDeviceList', 'Invoke-DeviceInspectorPolicyUpdate', 'Invoke-DeviceInspectorFullInventory', 'Invoke-DeviceInspectorInventoryRepair', 'Invoke-DeviceInspectorUpdateInstall', 'Invoke-DeviceInspectorApplicationAction', 'Invoke-DeviceInspectorCollectionChange', 'ConvertTo-DeviceInspectorActionText', 'Write-DeviceInspectorActionLog', 'New-DeviceInspectorActionRecord', 'New-DeviceInspectorActionId', 'New-DeviceInspectorActionRun', 'Get-DeviceInspectorRunningAction', 'Get-DeviceInspectorRunBlock', 'Get-DeviceInspectorDeviceKey', 'Test-DeviceInspectorRunFinished', 'Resolve-DeviceInspectorRunResult', 'Register-DeviceInspectorActionRun', 'Unregister-DeviceInspectorActionRun', 'Add-DeviceInspectorActionId', 'Write-DeviceInspectorCloseLog', 'Get-DeviceInspectorCloseWarningText', 'Get-DeviceInspectorApplicationLabel', 'Test-DeviceInspectorProcessOwner', 'Test-DeviceInspectorExitNeeded'
