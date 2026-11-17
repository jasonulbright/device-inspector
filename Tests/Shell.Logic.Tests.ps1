#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The extracted start script functions read the global preferences path.')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Plain objects stand in for window controls that the extracted functions read by scope.')]
param ()

# Logic of start-deviceinspector.ps1. The script cannot be dot-sourced (it opens
# the window), so each function is cut out of its syntax tree and defined here,
# with plain objects in place of the window controls.

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $script:ShellPath = Join-Path $script:AppRoot 'start-deviceinspector.ps1'
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ShellPath, [ref]$null, [ref]$null)
    $wanted = 'Get-DiPreferences', 'Save-DiPreferences', 'ConvertTo-TitleCaseText', 'Set-StatusText',
        'Get-ActionTargetName', 'Get-ActionTargetResourceId', 'Test-SiteActionReady', 'Test-DeviceActionReady',
        'Get-ActionBlockText', 'Get-ActionGateText', 'Update-RunPanel', 'Test-InventoryCorrupt', 'Clear-InventoryCheck',
        'Set-ActiveView', 'Update-StatusBarSummary', 'Get-AppTypeFilter', 'Update-AppFilter', 'Get-InstallableUpdateRow',
        'Set-MenuItemState'
    foreach ($n in $wanted) {
        $def = $script:Ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
        if (-not $def) { throw "function $n not found in the script" }
        . ([scriptblock]::Create($def.Extent.Text))
    }
    # The view table is a statement of the script, not a function: evaluate the real text.
    $meta = $script:Ast.Find({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -eq '$script:ViewMeta' }, $true)
    if (-not $meta) { throw 'the view table was not found in the script' }
    $script:RealViewMeta = & ([scriptblock]::Create($meta.Right.Extent.Text))
}

Describe 'ConvertTo-TitleCaseText' {
    It 'turns "<Text>" into "<Expected>"' -ForEach @(
        @{ Text = 'device list'; Expected = 'Device List' }
        @{ Text = 'add to collection'; Expected = 'Add to Collection' }
        @{ Text = 'the end of the line'; Expected = 'The End of the Line' }
        @{ Text = 'corrupt-inventory report'; Expected = 'Corrupt-Inventory Report' }
        @{ Text = '32-bit mode'; Expected = '32-bit Mode' }
        @{ Text = 'SCCM client'; Expected = 'SCCM Client' }
        @{ Text = 'Already Fine'; Expected = 'Already Fine' }
        @{ Text = 'a  b'; Expected = 'A  B' }
        @{ Text = ''; Expected = '' }
    ) {
        ConvertTo-TitleCaseText -Text $Text | Should -Be $Expected
    }
}

Describe 'Action gate' {
    BeforeEach {
        $script:ActionsEnabled = $true
        $script:IsBusy = $false
        $script:RunList = New-Object -TypeName 'System.Collections.ObjectModel.ObservableCollection[object]'
        $script:Inspection = [pscustomobject]@{
            ComputerName = 'WS01'
            SiteServer   = 'sms01.contoso.com'
            Device       = [pscustomobject]@{ Name = 'WS01' }
            Site         = [pscustomobject]@{ Found = $true; ResourceId = 16777220 }
        }
    }

    It 'names the device of the inspection on screen and gives an empty name without one' {
        Get-ActionTargetName | Should -Be 'WS01'
        $script:Inspection = $null
        Get-ActionTargetName | Should -Be ''
    }

    It 'gives the resource ID when the site found the device and 0 in every other case' -ForEach @(
        @{ Case = 'found'; Site = [pscustomobject]@{ Found = $true; ResourceId = 16777220 }; Expected = 16777220 }
        @{ Case = 'not found'; Site = [pscustomobject]@{ Found = $false; ResourceId = 16777220 }; Expected = 0 }
        @{ Case = 'no resource ID'; Site = [pscustomobject]@{ Found = $true; ResourceId = $null }; Expected = 0 }
        @{ Case = 'no site'; Site = $null; Expected = 0 }
    ) {
        $script:Inspection.Site = $Site
        $id = Get-ActionTargetResourceId
        $id | Should -Be $Expected
        $id | Should -BeOfType ([long])
    }

    It 'gives 0 without an inspection' {
        $script:Inspection = $null
        Get-ActionTargetResourceId | Should -Be 0
    }

    It 'allows a device action and a site action on an inspected device' {
        Test-DeviceActionReady | Should -BeTrue
        Test-SiteActionReady | Should -BeTrue
        Get-ActionBlockText -Kind Device | Should -Be ''
        Get-ActionGateText | Should -Be ''
    }

    It 'blocks both kinds when actions are off, with the reason' {
        $script:ActionsEnabled = $false
        Test-DeviceActionReady | Should -BeFalse
        Test-SiteActionReady | Should -BeFalse
        Get-ActionBlockText -Kind Site | Should -Be 'Turn on Enable Actions first.'
        Get-ActionGateText | Should -Be 'Turn on Enable Actions first.'
    }

    It 'blocks both kinds while exclusive work runs' {
        $script:IsBusy = $true
        Get-ActionBlockText -Kind Device | Should -Be 'Wait for the running task to end.'
        Test-SiteActionReady | Should -BeFalse
    }

    It 'blocks a site action when the site does not know the device, and still allows a device action' {
        $script:Inspection.Site = [pscustomobject]@{ Found = $false; ResourceId = 0 }
        Test-SiteActionReady | Should -BeFalse
        Test-DeviceActionReady | Should -BeTrue
        Get-ActionBlockText -Kind Site | Should -Be 'Inspect a device that the site knows first.'
    }

    It 'blocks both kinds without an inspection' {
        $script:Inspection = $null
        Get-ActionBlockText -Kind Device | Should -Be 'Inspect a device that answers first.'
        Get-ActionBlockText -Kind Site | Should -Be 'Inspect a device that the site knows first.'
    }
}

Describe 'Update-RunPanel' {
    BeforeEach {
        $panelRuns = [pscustomobject]@{ Visibility = $null }
        $lblRuns = [pscustomobject]@{ Text = '' }
        $script:RunList = New-Object -TypeName 'System.Collections.ObjectModel.ObservableCollection[object]'
    }

    It 'hides the panel and shows the plain title when no action runs' {
        Update-RunPanel
        [string]$panelRuns.Visibility | Should -Be 'Collapsed'
        $lblRuns.Text | Should -Be 'Running Actions'
    }

    It 'shows the panel with the number of running actions' {
        $script:RunList.Add([pscustomobject]@{ Name = 'a' })
        $script:RunList.Add([pscustomobject]@{ Name = 'b' })
        Update-RunPanel
        [string]$panelRuns.Visibility | Should -Be 'Visible'
        $lblRuns.Text | Should -Be 'Running Actions (2)'
    }
}

Describe 'Inventory check' {
    It 'finds a corrupt inventory check <Case>' -ForEach @(
        @{ Case = 'corrupt'; Inspection = [pscustomobject]@{ InventoryCheck = [pscustomobject]@{ State = 'Corrupt' } }; Expected = $true }
        @{ Case = 'healthy'; Inspection = [pscustomobject]@{ InventoryCheck = [pscustomobject]@{ State = 'Healthy' } }; Expected = $false }
        @{ Case = 'null'; Inspection = [pscustomobject]@{ InventoryCheck = $null }; Expected = $false }
        @{ Case = 'missing'; Inspection = [pscustomobject]@{ ComputerName = 'WS01' }; Expected = $false }
        @{ Case = 'no inspection'; Inspection = $null; Expected = $false }
    ) {
        $script:Inspection = $Inspection
        Test-InventoryCorrupt | Should -Be $Expected
    }

    Context 'Clear-InventoryCheck' {
        BeforeEach {
            $script:Shown = 0
            $script:ControlStateUpdates = 0
            function Show-Inspection { param($Inspection) $script:Shown++ }
            function Update-ControlState { $script:ControlStateUpdates++ }
        }

        It 'sets the check to Unknown and drops the inventory problems' {
            $script:Inspection = [pscustomobject]@{
                InventoryCheck = [pscustomobject]@{ State = 'Corrupt'; Differences = 3 }
                Problems       = @('Inventory: 3 differences', 'Updates: timeout')
            }
            Clear-InventoryCheck
            $script:Inspection.InventoryCheck.State | Should -Be 'Unknown'
            $script:Inspection.InventoryCheck.Differences | Should -Be 0
            $script:Inspection.InventoryCheck.Message | Should -Match '^A full hardware inventory ran after this inspection'
            @($script:Inspection.Problems) | Should -Be @('Updates: timeout')
            $script:Shown | Should -Be 1
            $script:ControlStateUpdates | Should -Be 1
        }

        It 'only refreshes the controls when the inspection has no check or there is no inspection' {
            $script:Inspection = [pscustomobject]@{ ComputerName = 'WS01' }
            Clear-InventoryCheck
            $script:Inspection.PSObject.Properties['InventoryCheck'] | Should -BeNullOrEmpty
            $script:Inspection = $null
            Clear-InventoryCheck
            $script:Shown | Should -Be 0
            $script:ControlStateUpdates | Should -Be 2
        }
    }
}

Describe 'Set-ActiveView and Update-StatusBarSummary' {
    BeforeEach {
        $script:ViewMeta = $script:RealViewMeta
        $script:SidebarUpdates = 0
        function Update-SidebarButtonTheme { $script:SidebarUpdates++ }
        $viewDeviceList = [pscustomobject]@{ Visibility = $null }
        $viewDevice = [pscustomobject]@{ Visibility = $null }
        $viewApps = [pscustomobject]@{ Visibility = $null }
        $viewUpdates = [pscustomobject]@{ Visibility = $null }
        $viewCollections = [pscustomobject]@{ Visibility = $null }
        $viewProblems = [pscustomobject]@{ Visibility = $null }
        $txtModuleTitle = [pscustomobject]@{ Text = '' }
        $txtModuleSubtitle = [pscustomobject]@{ Text = '' }
        $txtStatus = [pscustomobject]@{ Text = '' }
        $script:Inspection = $null
        $script:ActionsEnabled = $false
        $script:RunList = New-Object -TypeName 'System.Collections.ObjectModel.ObservableCollection[object]'
    }

    It 'has a title and a subtitle for each of the six views' {
        @($script:ViewMeta.Keys).Count | Should -Be 6
        foreach ($k in $script:ViewMeta.Keys) {
            $script:ViewMeta[$k].Title | Should -Not -BeNullOrEmpty
            $script:ViewMeta[$k].Subtitle | Should -Not -BeNullOrEmpty
        }
    }

    It 'shows only the <View> view and sets its title' -ForEach @(
        @{ View = 'Device list'; Name = 'viewDeviceList' }
        @{ View = 'Device'; Name = 'viewDevice' }
        @{ View = 'Applications'; Name = 'viewApps' }
        @{ View = 'Updates'; Name = 'viewUpdates' }
        @{ View = 'Collections'; Name = 'viewCollections' }
        @{ View = 'Problems'; Name = 'viewProblems' }
    ) {
        Set-ActiveView -View $View
        $script:ActiveView | Should -Be $View
        foreach ($n in 'viewDeviceList', 'viewDevice', 'viewApps', 'viewUpdates', 'viewCollections', 'viewProblems') {
            $v = Get-Variable -Name $n -ValueOnly
            [string]$v.Visibility | Should -Be $(if ($n -eq $Name) { 'Visible' } else { 'Collapsed' })
        }
        $txtModuleTitle.Text | Should -Be $script:ViewMeta[$View].Title
        $txtModuleSubtitle.Text | Should -Be $script:ViewMeta[$View].Subtitle
        $script:SidebarUpdates | Should -Be 1
    }

    It 'rejects a view that does not exist' {
        { Set-ActiveView -View 'Nowhere' } | Should -Throw
    }

    It 'tells the person to inspect a device when there is no inspection' {
        Update-StatusBarSummary
        $txtStatus.Text | Should -Be 'Enter a device name and click Inspect   |   read only'
    }

    It 'shows the device, the time, the problem count, the mode and the running actions' {
        $script:Inspection = [pscustomobject]@{ ComputerName = 'WS01'; InspectedAt = '2026-11-06 09:08:07'; Problems = @('a', 'b') }
        $script:ActionsEnabled = $true
        $script:RunList.Add([pscustomobject]@{ Name = 'x' })
        Update-StatusBarSummary
        $txtStatus.Text | Should -Be 'WS01 inspected 2026-11-06 09:08:07   |   2 problems   |   actions on   |   1 running'
    }

    It 'counts no problems for an inspection with an empty problem list' {
        $script:Inspection = [pscustomobject]@{ ComputerName = 'WS01'; InspectedAt = 't'; Problems = @() }
        Update-StatusBarSummary
        $txtStatus.Text | Should -Match '0 problems'
    }
}

Describe 'Applications filter' {
    BeforeEach {
        $txtAppFilter = [pscustomobject]@{ Text = '' }
        $cboAppType = [pscustomobject]@{ SelectedItem = $null }
        $gridApps = [pscustomobject]@{ ItemsSource = $null }
        $script:AppRows = @(
            [pscustomobject]@{ Name = 'Contoso Reader'; Type = 'Win32' },
            [pscustomobject]@{ Name = 'Fabrikam Editor'; Type = 'MSI' },
            [pscustomobject]@{ Name = 'contoso Agent'; Type = 'MSI' },
            [pscustomobject]@{ Name = $null; Type = 'Win32' })
    }

    It 'gives All when nothing is selected and the content of the selected item otherwise' {
        Get-AppTypeFilter | Should -Be 'All'
        $cboAppType.SelectedItem = [pscustomobject]@{ Content = 'MSI' }
        Get-AppTypeFilter | Should -Be 'MSI'
    }

    It 'with text "<Text>" and type "<Type>" shows <Expected>' -ForEach @(
        @{ Text = ''; Type = 'All'; Expected = 'Contoso Reader,Fabrikam Editor,contoso Agent,' }
        @{ Text = 'CONTOSO'; Type = 'All'; Expected = 'Contoso Reader,contoso Agent' }
        @{ Text = '  editor '; Type = 'All'; Expected = 'Fabrikam Editor' }
        @{ Text = ''; Type = 'MSI'; Expected = 'Fabrikam Editor,contoso Agent' }
        @{ Text = 'contoso'; Type = 'MSI'; Expected = 'contoso Agent' }
        @{ Text = 'zzz'; Type = 'All'; Expected = '' }
    ) {
        $txtAppFilter.Text = $Text
        $cboAppType.SelectedItem = [pscustomobject]@{ Content = $Type }
        Update-AppFilter
        (@($gridApps.ItemsSource) | ForEach-Object { $_.Name }) -join ',' | Should -Be $Expected
    }

    It 'treats the filter text <Text> as plain text' -ForEach @(@{ Text = '.*' }, @{ Text = '[' }, @{ Text = '(' }, @{ Text = '%' }, @{ Text = "'" }) {
        $txtAppFilter.Text = $Text
        { Update-AppFilter } | Should -Not -Throw
        @($gridApps.ItemsSource).Count | Should -Be 0
    }
}

Describe 'Get-InstallableUpdateRow' {
    It 'keeps only the required device updates that have an update ID' {
        $rows = @(
            [pscustomobject]@{ Source = 'Device'; Required = $true; UpdateId = 'u1' },
            [pscustomobject]@{ Source = 'Device'; Required = $false; UpdateId = 'u2' },
            [pscustomobject]@{ Source = 'Site'; Required = $true; UpdateId = 'u3' },
            [pscustomobject]@{ Source = 'Device'; Required = $true; UpdateId = '' },
            [pscustomobject]@{ Source = 'Device'; Required = $true; UpdateId = $null },
            $null,
            [pscustomobject]@{ Source = 'Device'; Required = $true; UpdateId = 'u6' })
        (Get-InstallableUpdateRow -Rows $rows | ForEach-Object UpdateId) -join ',' | Should -Be 'u1,u6'
    }

    It 'gives nothing for no rows' {
        @(Get-InstallableUpdateRow -Rows @()).Count | Should -Be 0
        @(Get-InstallableUpdateRow -Rows $null).Count | Should -Be 0
    }
}

Describe 'Set-MenuItemState' {
    It 'sets the enabled state and the tooltip' {
        $item = [pscustomobject]@{ IsEnabled = $true; ToolTip = '' }
        Set-MenuItemState -Item $item -Enabled $false -Reason 'Select one row.'
        $item.IsEnabled | Should -BeFalse
        $item.ToolTip | Should -Be 'Select one row.'
    }
}

Describe 'Preferences file' {
    BeforeEach { $global:PrefsPath = Join-Path $TestDrive ('prefs-{0}.json' -f [guid]::NewGuid().ToString('N')) }
    AfterAll { Remove-Variable -Name PrefsPath -Scope Global -ErrorAction SilentlyContinue }

    It 'gives the defaults on first run' {
        $p = Get-DiPreferences
        $p.DarkMode | Should -BeTrue
        $p.SiteCode | Should -Be ''
        $p.SMSProvider | Should -Be ''
        $p.LastDevice | Should -Be ''
        $p.SiteOnly | Should -BeFalse
    }

    It 'gives the defaults for a <Case> file' -ForEach @(
        @{ Case = 'corrupt'; Content = '{ not json' }
        @{ Case = 'empty'; Content = '' }
        @{ Case = 'array'; Content = '[1,2,3]' }
    ) {
        Set-Content -LiteralPath $global:PrefsPath -Value $Content
        (Get-DiPreferences).SiteCode | Should -Be ''
    }

    It 'ignores a key it does not know' {
        Set-Content -LiteralPath $global:PrefsPath -Value '{ "SiteCode": "MCM", "Evil": "x" }'
        $p = Get-DiPreferences
        $p.SiteCode | Should -Be 'MCM'
        $p.ContainsKey('Evil') | Should -BeFalse
    }

    It 'round-trips the value <Name>' -ForEach @(
        @{ Name = 'plain'; Value = 'WS01' }
        @{ Name = 'non-ASCII'; Value = ('U' + [char]0x00FC + 'n' + [char]0x00EF + '-' + [char]0x65E5 + [char]0x672C) }
        @{ Name = 'quote and backslash'; Value = 'a "q" \ b' }
        @{ Name = 'long'; Value = ('x' * 5000) }
    ) {
        Save-DiPreferences -Prefs @{ DarkMode = $false; SiteCode = 'MCM'; SMSProvider = 'cm01'; LastDevice = $Value; SiteOnly = $true }
        $p = Get-DiPreferences
        $p.LastDevice | Should -Be $Value
        $p.DarkMode | Should -BeFalse
        $p.SiteOnly | Should -BeTrue
    }

    It 'does not throw when the file cannot be written' {
        $global:PrefsPath = Join-Path $TestDrive 'dir-in-the-way'
        New-Item -ItemType Directory -Path $global:PrefsPath | Out-Null
        { Save-DiPreferences -Prefs @{ DarkMode = $true; SiteCode = 'X'; SMSProvider = ''; LastDevice = ''; SiteOnly = $false } } | Should -Not -Throw
    }
}

Describe 'Script contract' {
    It 'calls only commands that exist' {
        $own = @($script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
        $called = @($script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        Import-Module (Join-Path $script:AppRoot 'Lib\SuiteCommon\SuiteCommon.psd1') -Global -DisableNameChecking -ErrorAction SilentlyContinue
        $missing = @($called | Where-Object { $_ -notin $own -and -not (Get-Command $_ -ErrorAction SilentlyContinue) })
        $missing | Where-Object { $_ -notmatch '^(Get|Set|New|Remove|Start|Invoke|Add|Copy)-CM' } | Should -BeNullOrEmpty
    }
}
