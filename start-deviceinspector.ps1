<#
.SYNOPSIS
    Main window of Device Inspector, a tool that shows the facts of one device from a Configuration Manager site and from the device itself, with optional actions.

.DESCRIPTION
    Sidebar navigation across six panels (Device list, Device, Applications, Updates,
    Collections, Problems). The action bar holds the device name, the site
    server, the Inspect button and the JSON and HTML exports.

    The inspection only reads. It reads the site with the ConfigurationManager
    cmdlets and SELECT queries and reads the device with one remote script
    block. Actions change the device or the site. They run only when Enable
    actions is on, after a confirmation, and each run and dry run goes to the
    action log with an action ID. An action on a device runs in its own
    background runspace, so the person can inspect other devices and start
    actions on them while it runs. A device runs one action at a time. The
    tool uses the permissions of the signed-in user and stores no password. The only files it writes are the log files, the action log
    and the exports that the person names.

    Requirements:
      - PowerShell 5.1
      - .NET Framework 4.7.2+
      - MahApps.Metro DLLs in .\Lib\
      - DeviceInspectorCommon module under .\Module\
      - Configuration Manager console on this computer (it provides the
        ConfigurationManager PowerShell module)
      - WinRM access to the device, and access to the site server

.NOTES
    ScriptName : start-deviceinspector.ps1
    Version    : 2026.11.13.0011
    Updated    : 2026-11-10
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification='$global: survives closure scope-strip in WPF event handlers.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='WPF event handler scriptblocks bind positional sender/args ($s, $e).')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$__txDir = Join-Path $PSScriptRoot 'Logs'
try {
    if (-not (Test-Path -LiteralPath $__txDir)) { New-Item -ItemType Directory -Path $__txDir -Force | Out-Null }
    $__tx = Join-Path $__txDir ('DeviceInspector-startup-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Start-Transcript -LiteralPath $__tx -Force | Out-Null
} catch { $null = $_ }

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psExe = (Get-Process -Id $PID).Path
    $fwd   = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath)
    Start-Process -FilePath $psExe -ArgumentList $fwd | Out-Null
    try { Stop-Transcript | Out-Null } catch { $null = $_ }
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$libDir = Join-Path $PSScriptRoot 'Lib'
if (-not (Test-Path -LiteralPath $libDir)) { throw "Lib/ directory not found at: $libDir." }
Get-ChildItem -LiteralPath $libDir -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $libDir 'Microsoft.Xaml.Behaviors.dll'))
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $libDir 'ControlzEx.dll'))
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $libDir 'MahApps.Metro.dll'))

$__modulePath = Join-Path $PSScriptRoot 'Module\DeviceInspectorCommon.psd1'
if (-not (Test-Path -LiteralPath $__modulePath)) { throw "Shared module not found at: $__modulePath" }
Import-Module -Name $__modulePath -Force -DisableNameChecking

# The site is read with the ConfigurationManager module, which comes only with the
# Configuration Manager console. Without it the tool stops here with a plain message.
$__console = Test-DeviceInspectorConsole
if (-not $__console.Available) {
    Write-Warning -Message $__console.Message
    [void][System.Windows.MessageBox]::Show($__console.Message, 'Device Inspector', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    try { Stop-Transcript | Out-Null } catch { $null = $_ }
    exit 2
}

$global:PrefsPath = Join-Path $PSScriptRoot 'DeviceInspector.prefs.json'
function Get-DiPreferences {
    return Read-SuiteSettings -Path $global:PrefsPath -Defaults @{ DarkMode = $true; SiteCode = ''; SMSProvider = ''; LastDevice = ''; SiteOnly = $false }
}
function Save-DiPreferences {
    param([Parameter(Mandatory)][hashtable]$Prefs)
    $null = Save-SuiteSettings -Path $global:PrefsPath -Settings $Prefs
}
$global:Prefs = Get-DiPreferences

# The suite launcher hands its site code and provider to each tool it starts.
# A value saved in this tool wins; the launcher value fills an empty one.
if (-not $global:Prefs.SiteCode    -and $env:SUITE_CM_SITECODE) { $global:Prefs.SiteCode    = [string]$env:SUITE_CM_SITECODE }
if (-not $global:Prefs.SMSProvider -and $env:SUITE_CM_PROVIDER) { $global:Prefs.SMSProvider = [string]$env:SUITE_CM_PROVIDER }

$script:ToolLogPath = Join-Path $__txDir ('DeviceInspector-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Initialize-Logging -LogPath $script:ToolLogPath

$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$txtAppTitle = $window.FindName('txtAppTitle')
$txtVersion  = $window.FindName('txtVersion')
# Installed version: the script header is the single source of truth for the
# sidebar label and the About panel.
$script:AppVersion = '0.0.0'
foreach ($headerLine in (Get-Content -LiteralPath $PSCommandPath -TotalCount 80)) {
    if ($headerLine -match '^\s*Version\s*:\s*([0-9][0-9\.]*[0-9])\s*$') { $script:AppVersion = $Matches[1]; break }
}
if ($txtVersion) { $txtVersion.Text = 'v' + $script:AppVersion }
$txtThemeLabel = $window.FindName('txtThemeLabel')
$toggleTheme   = $window.FindName('toggleTheme')
$toggleActions = $window.FindName('toggleActions')

$btnViewDeviceList  = $window.FindName('btnViewDeviceList')
$btnViewDevice      = $window.FindName('btnViewDevice')
$btnViewApps        = $window.FindName('btnViewApps')
$btnViewUpdates     = $window.FindName('btnViewUpdates')
$btnViewCollections = $window.FindName('btnViewCollections')
$btnViewProblems    = $window.FindName('btnViewProblems')
$btnOptions         = $window.FindName('btnOptions')

$txtModuleTitle    = $window.FindName('txtModuleTitle')
$txtModuleSubtitle = $window.FindName('txtModuleSubtitle')

$btnInspect    = $window.FindName('btnInspect')
$txtDevice     = $window.FindName('txtDevice')
$txtSiteServer = $window.FindName('txtSiteServer')
$chkSiteOnly   = $window.FindName('chkSiteOnly')
$btnExportJson = $window.FindName('btnExportJson')
$btnExportHtml = $window.FindName('btnExportHtml')

$viewDeviceList  = $window.FindName('viewDeviceList')
$viewDevice      = $window.FindName('viewDevice')
$txtListName       = $window.FindName('txtListName')
$txtListCollection = $window.FindName('txtListCollection')
$btnListSearch     = $window.FindName('btnListSearch')
$btnListInspect    = $window.FindName('btnListInspect')
$txtListSummary    = $window.FindName('txtListSummary')
$gridDeviceList    = $window.FindName('gridDeviceList')
$viewApps        = $window.FindName('viewApps')
$viewUpdates     = $window.FindName('viewUpdates')
$viewCollections = $window.FindName('viewCollections')
$viewProblems    = $window.FindName('viewProblems')

$txtSummary      = $window.FindName('txtSummary')
$btnPolicyUpdate = $window.FindName('btnPolicyUpdate')
$btnFullInventory = $window.FindName('btnFullInventory')
$btnRepairInventory = $window.FindName('btnRepairInventory')
$gridFacts       = $window.FindName('gridFacts')
$txtAppFilter    = $window.FindName('txtAppFilter')
$cboAppType      = $window.FindName('cboAppType')
$gridApps        = $window.FindName('gridApps')
$menuUninstallApp = @($gridApps.ContextMenu.Items | Where-Object { $_.Name -eq 'menuUninstallApp' })[0]
$menuRepairApp    = @($gridApps.ContextMenu.Items | Where-Object { $_.Name -eq 'menuRepairApp' })[0]
$gridUpdates     = $window.FindName('gridUpdates')
# Context menu items are outside the name scope of the window.
$menuInstallSelected = @($gridUpdates.ContextMenu.Items | Where-Object { $_.Name -eq 'menuInstallSelected' })[0]
$menuInstallAll      = @($gridUpdates.ContextMenu.Items | Where-Object { $_.Name -eq 'menuInstallAll' })[0]
$gridCollections = $window.FindName('gridCollections')
$menuRemoveCollection = @($gridCollections.ContextMenu.Items | Where-Object { $_.Name -eq 'menuRemoveCollection' })[0]
$menuAddCollection    = @($gridCollections.ContextMenu.Items | Where-Object { $_.Name -eq 'menuAddCollection' })[0]
$btnAddCollection     = $window.FindName('btnAddCollection')
$gridDeployments = $window.FindName('gridDeployments')
$txtProblems     = $window.FindName('txtProblems')

$panelRuns = $window.FindName('panelRuns')
$lblRuns   = $window.FindName('lblRuns')
$gridRuns  = $window.FindName('gridRuns')

$progressOverlay  = $window.FindName('progressOverlay')
$txtProgressTitle = $window.FindName('txtProgressTitle')
$txtProgressStep  = $window.FindName('txtProgressStep')

$lblLogOutput = $window.FindName('lblLogOutput')
$btnOpenLog   = $window.FindName('btnOpenLog')
$txtLog       = $window.FindName('txtLog')
$txtStatus    = $window.FindName('txtStatus')

$null = $txtAppTitle

function Add-LogLine {
    param([Parameter(Mandatory)][string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $line = '{0}  {1}' -f $ts, $Message
    if ([string]::IsNullOrWhiteSpace($txtLog.Text)) { $txtLog.Text = $line }
    else { $txtLog.AppendText([Environment]::NewLine + $line) }
    $txtLog.ScrollToEnd()
    try { Write-Log -Message $Message -Quiet } catch { $null = $_ }
}

function Set-StatusText {
    param([Parameter(Mandatory)][string]$Text)
    $txtStatus.Text = $Text
}

# The window shows a fixed text. The reason of a failure (the text of an exception) goes to the log file only.
function Write-ErrorLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    try { Write-Log -Message $Message -Level ERROR -Quiet } catch { $null = $_ }
}

# A window title in Title Case. The small words in the middle stay in lower case.
function ConvertTo-TitleCaseText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $small = @('a', 'an', 'the', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'per', 'by', 'at', 'as', 'but', 'nor', 'with', 'from')
    $words = @($Text -split ' ')
    for ($i = 0; $i -lt $words.Count; $i++) {
        $word = $words[$i]
        if (-not $word -or ($i -gt 0 -and $small -contains $word)) { continue }
        # Each part of a word with a hyphen starts with a capital, as in Corrupt-Inventory. A part after a digit (32-bit) stays.
        $parts = @($word -split '-')
        for ($p = 0; $p -lt $parts.Count; $p++) {
            if (-not $parts[$p] -or ($p -gt 0 -and $word -notmatch '^[A-Za-z]')) { continue }
            $parts[$p] = $parts[$p].Substring(0, 1).ToUpperInvariant() + $parts[$p].Substring(1)
        }
        $words[$i] = $parts -join '-'
    }
    return ($words -join ' ')
}

# === Title-bar drag fallback: SuiteCommon owns the hook ===
Install-TitleBarDragFallback -Window $window

# === Theme (palette, sidebar, title bar, dialogs: SuiteCommon) ===
[void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Dark.Steel')

$script:ViewButtons = @(
    @{ Name = 'Device list'; Button = $btnViewDeviceList }
    @{ Name = 'Device';      Button = $btnViewDevice }
    @{ Name = 'Applications'; Button = $btnViewApps }
    @{ Name = 'Updates';     Button = $btnViewUpdates }
    @{ Name = 'Collections'; Button = $btnViewCollections }
    @{ Name = 'Problems';    Button = $btnViewProblems }
)
$script:ActiveView = 'Device'

# Palette overrides for SuiteCommon: every window resource whose key starts with 'SuiteTheme.'
# (MainWindow.xaml). They keep the sidebar border and the inactive title bar at the contrast minimum.
$suiteBrushes = @{}
foreach ($key in @($window.Resources.Keys)) {
    if ($key -is [string] -and $key.StartsWith('SuiteTheme.')) { $suiteBrushes[$key.Substring(11)] = $window.Resources[$key] }
}

Initialize-SuiteTheme -Window $window `
    -IsDarkGetter { [bool]$global:Prefs['DarkMode'] } `
    -ActiveViewGetter { $script:ActiveView } `
    -ViewButtons $script:ViewButtons `
    -OptionsButton $btnOptions `
    -LogLabel $lblLogOutput `
    -Brushes $suiteBrushes

$__startIsDark = [bool]$global:Prefs['DarkMode']
$toggleTheme.IsOn = $__startIsDark
$txtThemeLabel.Text = if ($__startIsDark) { 'Dark Theme' } else { 'Light Theme' }
Update-SidebarButtonTheme

$toggleTheme.Add_Toggled({
    $isDark = [bool]$toggleTheme.IsOn
    if ($isDark) { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Dark.Steel'); $txtThemeLabel.Text = 'Dark Theme' }
    else         { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Light.Blue'); $txtThemeLabel.Text = 'Light Theme' }
    $global:Prefs['DarkMode'] = $isDark
    Save-DiPreferences -Prefs $global:Prefs
    Update-SidebarButtonTheme
    Update-TitleBarBrushes
    Add-LogLine ('Theme: {0}' -f $(if ($isDark) { 'dark' } else { 'light' }))
})

# === Crash handlers ===
$global:__crashLog = Join-Path $__txDir ('DeviceInspector-crash-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$global:__writeCrash = {
    param($Source, $Exception)
    try {
        $lines = @(('=== ' + $Source + ' @ ' + (Get-Date -Format 'o') + ' ==='))
        $lines += ('Type   : ' + $Exception.GetType().FullName)
        $lines += ('Message: ' + $Exception.Message)
        if ($Exception -is [System.Management.Automation.IContainsErrorRecord] -and $Exception.ErrorRecord.InvocationInfo) { $lines += ('At     : ' + $Exception.ErrorRecord.InvocationInfo.PositionMessage) }
        $lines += ([string]$Exception.StackTrace).Split([Environment]::NewLine)
        [System.IO.File]::AppendAllText($global:__crashLog, (($lines -join [Environment]::NewLine) + [Environment]::NewLine))
    } catch { $null = $_ }
}
$window.Dispatcher.Add_UnhandledException({ param($s, $e) & $global:__writeCrash 'DispatcherUnhandledException' $e.Exception; $e.Handled = $false })
[AppDomain]::CurrentDomain.Add_UnhandledException({ param($s, $e) & $global:__writeCrash 'AppDomainUnhandledException' ([Exception]$e.ExceptionObject) })

# === State ===
$script:Inspection = $null
$script:AppRows    = @()
$script:IsBusy     = $false
# Actions are off at each start. The switch is not saved.
$script:ActionsEnabled = $false
$script:ActionLogPath  = Join-Path $__txDir 'DeviceInspector-actions.log'
# An action on a device runs in its own runspace and does not set IsBusy. RunList holds the
# running device actions (the list in the window is bound to it). RunJobs holds the plumbing
# of each run. IsBusy stays only for the work that must be exclusive: an inspection, a device
# list search, the collection list and a change of the site.
$script:RunList       = New-Object -TypeName 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:RunJobs       = @{}
$script:RunTimer      = $null
$script:RunspaceIdle  = @()
$script:ResultNotices = 0
$script:WindowClosing = $false
$script:CloseChoice = 'Wait'
$script:ClosedWithOpenRuns = $false
$script:OwnsProcess = $false
$script:ButtonTips    = @{}
$gridRuns.ItemsSource = $script:RunList

# The device that an action would target is the device of the inspection on screen.
function Get-ActionTargetName {
    if ($script:Inspection) { return [string]$script:Inspection.ComputerName }
    return ''
}

# The site resource ID of the device on screen, when the inspection found the device on the site. 0 otherwise.
function Get-ActionTargetResourceId {
    if ($script:Inspection -and $script:Inspection.Site -and $script:Inspection.Site.Found -and $script:Inspection.Site.ResourceId) { return [long]$script:Inspection.Site.ResourceId }
    return [long]0
}

function Test-SiteActionReady {
    return [string]::IsNullOrEmpty((Get-DeviceInspectorActionBlock -Inspection $script:Inspection -ActionsEnabled $script:ActionsEnabled -Busy $script:IsBusy -Kind Site -Run @($script:RunList) -ComputerName (Get-ActionTargetName) -ResourceId (Get-ActionTargetResourceId)))
}

function Test-DeviceActionReady {
    return [string]::IsNullOrEmpty((Get-DeviceInspectorActionBlock -Inspection $script:Inspection -ActionsEnabled $script:ActionsEnabled -Busy $script:IsBusy -Kind Device -Run @($script:RunList) -ComputerName (Get-ActionTargetName) -ResourceId (Get-ActionTargetResourceId)))
}

function Get-ActionBlockText {
    param([Parameter(Mandatory)][ValidateSet('Device', 'Site')][string]$Kind)
    return [string](Get-DeviceInspectorActionBlock -Inspection $script:Inspection -ActionsEnabled $script:ActionsEnabled -Busy $script:IsBusy -Kind $Kind -Run @($script:RunList) -ComputerName (Get-ActionTargetName) -ResourceId (Get-ActionTargetResourceId))
}

# A button that is off because its device has a running action shows the reason as its tooltip.
# Any other time the button shows its own tooltip from the markup.
function Set-RunTooltip {
    param([Parameter(Mandatory)]$Button, [Parameter(Mandatory)][AllowEmptyString()][string]$Reason)
    $name = [string]$Button.Name
    if (-not $script:ButtonTips.ContainsKey($name)) { $script:ButtonTips[$name] = $Button.ToolTip }
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($Button, $true)
    if ($Reason) { $Button.ToolTip = $Reason } else { $Button.ToolTip = $script:ButtonTips[$name] }
}

function Update-RunPanel {
    $count = $script:RunList.Count
    $panelRuns.Visibility = $(if ($count -gt 0) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
    $lblRuns.Text = $(if ($count -gt 0) { 'Running Actions ({0})' -f $count } else { 'Running Actions' })
}

# After a full inventory or a repair the check is out of date until the next inspection.
# The panels and an export then show that state, not the old result.
function Clear-InventoryCheck {
    if ($script:Inspection -and $null -ne $script:Inspection.PSObject.Properties['InventoryCheck']) {
        $script:Inspection.InventoryCheck = [pscustomobject]@{
            State = 'Unknown'; SiteInventory = $null; DeviceCycle = $null; Differences = 0; Applications = @()
            Message = 'A full hardware inventory ran after this inspection. Inspect the device again after the site processes the report.'
        }
        $script:Inspection.Problems = @($script:Inspection.Problems | Where-Object { ([string]$_) -notlike 'Inventory: *' })
        Show-Inspection -Inspection $script:Inspection
    }
    Update-ControlState
}

function Test-InventoryCorrupt {
    if (-not $script:Inspection) { return $false }
    $check = $script:Inspection.PSObject.Properties['InventoryCheck']
    return [bool]($null -ne $check -and $null -ne $check.Value -and $check.Value.State -eq 'Corrupt')
}

function Update-ControlState {
    $idle = -not $script:IsBusy
    $has = [bool]$script:Inspection
    $btnInspect.IsEnabled    = $idle
    $btnListSearch.IsEnabled = $idle
    $txtListName.IsEnabled = $idle
    $txtListCollection.IsEnabled = $idle
    $btnListInspect.IsEnabled = $idle -and $null -ne $gridDeviceList.SelectedItem
    $txtDevice.IsEnabled     = $idle
    $txtSiteServer.IsEnabled = $idle
    $chkSiteOnly.IsEnabled   = $idle
    $btnExportJson.IsEnabled = $has
    $btnExportHtml.IsEnabled = $has
    $toggleActions.IsEnabled = $idle
    $btnPolicyUpdate.IsEnabled = Test-DeviceActionReady
    $btnFullInventory.IsEnabled = Test-DeviceActionReady
    $btnAddCollection.IsEnabled = Test-SiteActionReady
    $btnRepairInventory.IsEnabled = (Test-DeviceActionReady) -and (Test-InventoryCorrupt)
    $runReason = Get-DeviceInspectorRunBlock -Run @($script:RunList) -ComputerName (Get-ActionTargetName) -ResourceId (Get-ActionTargetResourceId)
    foreach ($button in @($btnPolicyUpdate, $btnFullInventory, $btnRepairInventory, $btnAddCollection)) { Set-RunTooltip -Button $button -Reason $runReason }
    Update-RunPanel
}

# === View switching ===
$script:ViewMeta = @{
    'Device list'  = @{ Title = 'Device List';  Subtitle = 'Devices of the site that match a name pattern or a collection. Select one and inspect it.' }
    'Device'       = @{ Title = 'Device';       Subtitle = 'Operating system, client health and site record of the device.' }
    'Applications' = @{ Title = 'Applications'; Subtitle = 'Applications that the device lists in its uninstall registry keys now. Right-click a row to uninstall or repair.' }
    'Updates'      = @{ Title = 'Updates';      Subtitle = 'Updates that the site lists as required for the device, and updates pending on the device.' }
    'Collections'  = @{ Title = 'Collections';  Subtitle = 'Collections that hold the device and the deployments that target them.' }
    'Problems'     = @{ Title = 'Problems';     Subtitle = 'Parts of the inspection that failed. The other parts still ran.' }
}
function Set-ActiveView {
    param([Parameter(Mandatory)][ValidateSet('Device list', 'Device', 'Applications', 'Updates', 'Collections', 'Problems')][string]$View)
    $script:ActiveView = $View
    $vis = [System.Windows.Visibility]::Visible
    $hid = [System.Windows.Visibility]::Collapsed
    $viewDeviceList.Visibility  = if ($View -eq 'Device list')  { $vis } else { $hid }
    $viewDevice.Visibility      = if ($View -eq 'Device')       { $vis } else { $hid }
    $viewApps.Visibility        = if ($View -eq 'Applications') { $vis } else { $hid }
    $viewUpdates.Visibility     = if ($View -eq 'Updates')      { $vis } else { $hid }
    $viewCollections.Visibility = if ($View -eq 'Collections')  { $vis } else { $hid }
    $viewProblems.Visibility    = if ($View -eq 'Problems')     { $vis } else { $hid }
    $meta = $script:ViewMeta[$View]
    if ($meta) {
        $txtModuleTitle.Text    = $meta.Title
        $txtModuleSubtitle.Text = $meta.Subtitle
    }
    Update-SidebarButtonTheme
    Update-StatusBarSummary
}
$btnViewDeviceList.Add_Click({  Set-ActiveView -View 'Device list' })
$btnViewDevice.Add_Click({      Set-ActiveView -View 'Device' })
$btnViewApps.Add_Click({        Set-ActiveView -View 'Applications' })
$btnViewUpdates.Add_Click({     Set-ActiveView -View 'Updates' })
$btnViewCollections.Add_Click({ Set-ActiveView -View 'Collections' })
$btnViewProblems.Add_Click({    Set-ActiveView -View 'Problems' })

function Update-StatusBarSummary {
    $parts = @()
    if ($script:Inspection) {
        $parts += ('{0} inspected {1}' -f $script:Inspection.ComputerName, $script:Inspection.InspectedAt)
        $parts += ('{0} problems' -f @($script:Inspection.Problems).Count)
    } else {
        $parts += 'Enter a device name and click Inspect'
    }
    $parts += $(if ($script:ActionsEnabled) { 'actions on' } else { 'read only' })
    if ($script:RunList.Count -gt 0) { $parts += ('{0} running' -f $script:RunList.Count) }
    Set-StatusText ($parts -join '   |   ')
}

# === Applications filter ===
function Get-AppTypeFilter {
    if ($cboAppType.SelectedItem) { return [string]$cboAppType.SelectedItem.Content }
    return 'All'
}
function Update-AppFilter {
    $needle = ([string]$txtAppFilter.Text).Trim().ToLowerInvariant()
    $type = Get-AppTypeFilter
    $rows = @($script:AppRows)
    if ($needle) { $rows = @($rows | Where-Object { ([string]$_.Name).ToLowerInvariant().Contains($needle) }) }
    if ($type -ne 'All') { $rows = @($rows | Where-Object { $_.Type -eq $type }) }
    $gridApps.ItemsSource = $rows
}
$txtAppFilter.Add_TextChanged({ Update-AppFilter })
$cboAppType.Add_SelectionChanged({ Update-AppFilter })

# === Show an inspection ===
function Show-Inspection {
    param($Inspection)
    $script:Inspection = $Inspection
    $gridFacts.ItemsSource = @(ConvertTo-DeviceInspectionFactRow -Inspection $Inspection)
    $script:AppRows = @(ConvertTo-DeviceInspectionApplicationRow -Inspection $Inspection)
    Update-AppFilter
    $gridUpdates.ItemsSource     = @(ConvertTo-DeviceInspectionUpdateRow -Inspection $Inspection)
    $gridCollections.ItemsSource = @(ConvertTo-DeviceInspectionCollectionRow -Inspection $Inspection)
    $gridDeployments.ItemsSource = @(ConvertTo-DeviceInspectionDeploymentRow -Inspection $Inspection)
    $problems = @($Inspection.Problems)
    $problemLine = foreach ($problem in $problems) { '- ' + $problem }
    $txtProblems.Text = if ($problems.Count -eq 0) { 'No problems. Every part of the inspection ran.' } else { @($problemLine) -join [Environment]::NewLine }
    $bits = @()
    $bits += ('Device {0}' -f $Inspection.ComputerName)
    if ($Inspection.Device -and $Inspection.Device.Client) { $bits += ('client service {0}, version {1}' -f $Inspection.Device.Client.ServiceState, $Inspection.Device.Client.Version) }
    if ($Inspection.Site -and $Inspection.Site.Found) { $bits += ('site record found (resource ID {0})' -f $Inspection.Site.ResourceId) }
    elseif ($Inspection.Site) { $bits += 'the site has no record of the device' }
    $bits += ('{0} applications' -f $script:AppRows.Count)
    $bits += ('{0} update rows' -f @($gridUpdates.ItemsSource).Count)
    $bits += ('{0} collections' -f @($gridCollections.ItemsSource).Count)
    $bits += ('{0} problems' -f $problems.Count)
    $txtSummary.Text = ($bits -join '; ') + '.'
    $btnViewProblems.Content = if ($problems.Count -gt 0) { 'Problems ({0})' -f $problems.Count } else { 'Problems' }
    Update-ControlState
    Update-StatusBarSummary
}

# === Bg runspace ===
$script:BgRunspace     = $null
$script:BgPowerShell   = $null
$script:BgInvokeHandle = $null
$script:BgState        = $null
$script:BgTimer        = $null
$script:BgGraveyard    = @()
$script:BgOnDone       = $null
$script:ActionChoice   = 'Cancel'
$script:ActionAfterRun = $null
$script:ActionPending  = $null
$script:ActionContext  = @{}

function Initialize-BgRunspace {
    if ($script:BgRunspace -and $script:BgRunspace.RunspaceStateInfo.State -eq 'Opened') { return }
    $script:BgRunspace = New-SuiteBgRunspace -ModulePath $__modulePath -LogPath $script:ToolLogPath
}

function Stop-BackgroundWork {
    $script:BgGraveyard = @(Stop-SuiteBgWork -PowerShell $script:BgPowerShell -Timer $script:BgTimer -Graveyard $script:BgGraveyard)
    $script:BgTimer = $null
    $script:BgPowerShell = $null
    $script:BgInvokeHandle = $null
}

# Runs one piece of work in the background runspace and calls OnDone on the window
# thread when it ends. Work receives ($A, $State) and must set $State.Done in a finally block.
function Start-BackgroundWork {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][scriptblock]$Work,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][scriptblock]$OnDone
    )
    Initialize-BgRunspace
    Stop-BackgroundWork
    $script:BgState = [hashtable]::Synchronized(@{ Step = $Step; Done = $false; Result = $null; ErrorMsg = $null })
    $script:BgOnDone = $OnDone
    $script:IsBusy = $true
    Update-ControlState
    $txtProgressTitle.Text = $Title
    $txtProgressStep.Text  = $Step
    $progressOverlay.Visibility = [System.Windows.Visibility]::Visible
    Set-StatusText ($Title + '...')

    $script:BgPowerShell = [powershell]::Create()
    $script:BgPowerShell.Runspace = $script:BgRunspace
    [void]$script:BgPowerShell.AddScript($Work).AddArgument($Arguments).AddArgument($script:BgState)
    $script:BgInvokeHandle = $script:BgPowerShell.BeginInvoke()
    $script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:BgTimer.Add_Tick({
        if ($script:BgState) { $current = [string]$script:BgState.Step; if ($txtProgressStep.Text -ne $current) { $txtProgressStep.Text = $current } }
        if ($script:BgState -and $script:BgState.Done) {
            $script:BgTimer.Stop()
            try { [void]$script:BgPowerShell.EndInvoke($script:BgInvokeHandle) } catch { $null = $_ }
            try { $script:BgPowerShell.Dispose() } catch { $null = $_ }
            $script:BgPowerShell   = $null
            $script:BgInvokeHandle = $null
            $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            $script:IsBusy = $false
            Update-ControlState
            & $script:BgOnDone $script:BgState
        }
    })
    $script:BgTimer.Start()
}

function Invoke-Inspect {
    $check = Test-DeviceInspectorInput -ComputerName ([string]$txtDevice.Text) -SiteServer ([string]$txtSiteServer.Text) -SiteCode ([string]$global:Prefs.SiteCode)
    if (-not $check.IsValid) {
        Add-LogLine ('Inspect: {0}' -f ($check.Errors -join ' '))
        Set-StatusText $check.Errors[0]
        [void](Show-ThemedMessage -Owner $window -Title 'Inspect' -Message ($check.Errors -join [Environment]::NewLine) -Icon Warn)
        return
    }
    $siteOnly = [bool]$chkSiteOnly.IsChecked
    if ($siteOnly -and -not $check.SiteServer) {
        Add-LogLine 'Inspect: Site Only needs a site server.'
        Set-StatusText 'Enter a site server, or clear Site Only.'
        return
    }
    $global:Prefs['LastDevice'] = $check.ComputerName
    $global:Prefs['SiteOnly']   = $siteOnly
    if ($check.SiteServer) { $global:Prefs['SMSProvider'] = $check.SiteServer }
    Save-DiPreferences -Prefs $global:Prefs
    Add-LogLine ('Inspect: device={0} siteServer={1} siteOnly={2}' -f $check.ComputerName, $(if ($check.SiteServer) { $check.SiteServer } else { '(none)' }), $siteOnly)

    $arguments = @{ Device = $check.ComputerName; Server = $check.SiteServer; Code = [string]$global:Prefs.SiteCode; SiteOnly = $siteOnly }
    Start-BackgroundWork -Title ('Inspecting {0}' -f $check.ComputerName) -Step 'Connecting...' -Arguments $arguments -Work {
        param($A, $State)
        try {
            $p = @{ ComputerName = $A.Device }
            if ($A.Server) { $p['SiteServer'] = $A.Server; $State.Step = 'Reading the site and the device...' } else { $State.Step = 'Reading the device...' }
            if ($A.Server) { $p['SiteCode'] = $A.Code }
            if ($A.SiteOnly) { $p['SkipDevice'] = $true }
            $State.Result = Get-DeviceInspection @p
        }
        catch { $State.ErrorMsg = [string]$_.Exception.Message; if ($_.Exception.Data -and $_.Exception.Data.Contains('RawText')) { $State.ToolMessage = $State.ErrorMsg; $State.ErrorMsg = [string]$_.Exception.Data['RawText'] } }
        finally { $State.Done = $true }
    } -OnDone {
        param($State)
        if ($State.ErrorMsg) {
            Write-ErrorLog ('Inspect failed: {0}' -f $State.ErrorMsg)
            Add-LogLine 'Inspect failed. The log file has the reason.'
            Set-StatusText 'Inspect failed. The log file has the reason.'
            [void](Show-ThemedMessage -Owner $window -Title 'Inspect' -Message $(if ($State.ToolMessage) { [string]$State.ToolMessage } else { 'The inspection failed. Check the site server, the site code and your account rights in Options. The log file has the reason.' }) -Icon Error)
            return
        }
        $r = $State.Result
        Show-Inspection -Inspection $r
        Add-LogLine ('Inspection of {0} finished: {1} problems.' -f $r.ComputerName, @($r.Problems).Count)
        if (-not (Write-DeviceInspectionFullLog -Inspection $r -LogPath $script:ToolLogPath)) { Add-LogLine 'The full report could not be written to the log file.' }
        foreach ($p in @($r.Problems)) { Add-LogLine ('  problem: {0}' -f $p) }
    }
}
$btnInspect.Add_Click({ Invoke-Inspect })
$txtDevice.Add_KeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Return) { Invoke-Inspect } })

# === Exports ===
function Save-TextExport {
    param(
        [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Extension,
        [Parameter(Mandatory)][string]$Filter, [Parameter(Mandatory)][scriptblock]$GetText
    )
    if (-not $script:Inspection) { Add-LogLine ('Export {0}: inspect a device first.' -f $Kind); return }
    try {
        $sfd = New-Object Microsoft.Win32.SaveFileDialog
        $sfd.Filter = $Filter
        $sfd.FileName = ('DeviceInspector-{0}-{1}.{2}' -f $script:Inspection.ComputerName, (Get-Date -Format 'yyyyMMdd-HHmmss'), $Extension)
        $reportsDir = Join-Path $PSScriptRoot 'Reports'
        if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
        $sfd.InitialDirectory = $reportsDir
        if ($sfd.ShowDialog() -eq $true) {
            $written = Write-DeviceInspectionFile -Path $sfd.FileName -Text (& $GetText)
            Add-LogLine ('Exported {0}: {1}' -f $Kind, $written)
        }
    }
    catch {
        Write-ErrorLog ('Export {0} failed: {1}' -f $Kind, $_.Exception.Message)
        Add-LogLine ('Export {0} failed. The log file has the reason.' -f $Kind)
        [void](Show-ThemedMessage -Owner $window -Title 'Export' -Message ('The {0} export failed. Check the folder and the file name. The log file has the reason.' -f $Kind) -Icon Error)
    }
}
$btnExportJson.Add_Click({ Save-TextExport -Kind 'JSON' -Extension 'json' -Filter 'JSON files (*.json)|*.json' -GetText { ConvertTo-DeviceInspectionJson -Inspection $script:Inspection } })
$btnExportHtml.Add_Click({ Save-TextExport -Kind 'HTML' -Extension 'html' -Filter 'HTML files (*.html)|*.html' -GetText { ConvertTo-DeviceInspectionHtml -Inspection $script:Inspection } })

# === Options dialog ===
function Show-OptionsDialog {
    $dlgXaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="Options" Width="640" Height="400"
    MinWidth="560" MinHeight="380"
    WindowStartupLocation="CenterOwner" TitleCharacterCasing="Normal"
    GlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    NonActiveGlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    BorderThickness="1" ShowIconOnTitleBar="False">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Steel.xaml" />
            </ResourceDictionary.MergedDictionaries>
            <!-- Contrast overrides, the same as in MainWindow.xaml: control borders need 3:1 and white title text 4.5:1. -->
            <SolidColorBrush x:Key="MahApps.Brushes.TextBox.Border" Color="#7F7F7F"/>
            <SolidColorBrush x:Key="MahApps.Brushes.WindowTitle.NonActive" Color="#595959"/>
            <!-- The one button template and the one button style, the same as in MainWindow.xaml. No color literal and
                 no Opacity: the colors come from the MahApps theme resources. -->
            <ControlTemplate x:Key="ThemedButtonTemplate" TargetType="Button">
                <Border Name="Bd"
                        Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}"
                        SnapsToDevicePixels="True">
                    <ContentPresenter Name="Cp"
                                      HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                      Margin="{TemplateBinding Padding}"
                                      RecognizesAccessKey="True"
                                      SnapsToDevicePixels="True"/>
                </Border>
                <ControlTemplate.Triggers>
                    <MultiTrigger>
                        <MultiTrigger.Conditions>
                            <Condition Property="IsMouseOver" Value="True"/>
                            <Condition Property="IsEnabled" Value="True"/>
                        </MultiTrigger.Conditions>
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </MultiTrigger>
                    <Trigger Property="IsKeyboardFocused" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="Bd" Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                        <Setter TargetName="Cp" Property="TextElement.Foreground" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>

            <Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="Template" Value="{StaticResource ThemedButtonTemplate}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderThickness" Value="1"/>
                <Setter Property="HorizontalContentAlignment" Value="Center"/>
                <Setter Property="VerticalContentAlignment" Value="Center"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray.MouseOver}"/>
                        <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                    </Trigger>
                </Style.Triggers>
            </Style>

            <!-- The one secondary dialog style: a gray fill, the theme text color and a visible border. Cancel and every
                 other dialog button that is not the main answer use it. The primary dialog style is DialogAccentButton.
                 No other dialog button style sets a Background. -->
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Gray10}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="MinWidth" Value="90"/>
                <Setter Property="Height" Value="32"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
            </Style>
            <!-- The accent fill is the theme highlight (#4A5763 dark, #00589F light): white text is 7:1 on both.
                 The border is the theme foreground: the highlight alone is 2.1:1 on the dark dialog.
                 The plain accent fill of the light theme is 4.49:1. -->
            <Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Highlight}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="MinWidth" Value="90"/>
                <Setter Property="Height" Value="32"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray.MouseOver}"/>
                        <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                    </Trigger>
                </Style.Triggers>
            </Style>
            <Style x:Key="CategoryRowStyle" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Height" Value="36"/>
                <Setter Property="HorizontalContentAlignment" Value="Left"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="FontSize" Value="13"/>
                <Setter Property="Margin" Value="0"/>
            </Style>
            <!-- Field titles are bold, the same in both themes. -->
            <Style x:Key="OptLabel" TargetType="TextBlock">
                <Setter Property="FontWeight" Value="Bold"/>
            </Style>
        </ResourceDictionary>
    </Window.Resources>
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="180"/>
            <ColumnDefinition Width="1"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border Grid.Column="0" Grid.Row="0" Padding="6,12,0,12">
            <StackPanel>
                <Button x:Name="btnCatConnection" Content="Connection" Style="{StaticResource CategoryRowStyle}"/>
                <Button x:Name="btnCatAbout"      Content="About"      Style="{StaticResource CategoryRowStyle}"/>
            </StackPanel>
        </Border>
        <Border Grid.Column="1" Grid.Row="0" Background="{DynamicResource MahApps.Brushes.Gray8}"/>
        <Grid Grid.Column="2" Grid.Row="0" Margin="20,16,20,16">
            <StackPanel x:Name="paneConnection" Visibility="Visible">
                <TextBlock Text="Configuration Manager Connection" Style="{StaticResource OptLabel}" FontSize="13" Margin="0,0,0,10"/>
                <TextBlock Text="Site Server (SMS Provider FQDN)" Style="{StaticResource OptLabel}" FontSize="14" FontWeight="Bold" Margin="0,4,0,2"/>
                <TextBox x:Name="txtSmsProvider" FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="e.g. sms01.example.com"/>
                <TextBlock Text="Site Code" Style="{StaticResource OptLabel}" FontSize="14" FontWeight="Bold" Margin="0,12,0,2"/>
                <TextBox x:Name="txtSiteCode" FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="e.g. XYZ. Required with a site server." Width="240" HorizontalAlignment="Left"/>
                <TextBlock Text="The tool connects with the Windows account that runs it and stores no password. The tool needs the Configuration Manager console on this computer. The account needs local administrator rights on the device (WinRM). For the site, a domain admin account that is a local administrator of the SMS Provider computer needs no Configuration Manager role. An account with fewer rights on the site is not tested. Only actions make changes."
                           FontSize="11" TextWrapping="Wrap" Margin="0,16,0,0"
                           Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
            </StackPanel>
            <StackPanel x:Name="paneAbout" Visibility="Collapsed">
                <TextBlock Text="About" Style="{StaticResource OptLabel}" FontSize="13" Margin="0,0,0,10"/>
                <TextBlock x:Name="txtAboutVersion" Text="Device Inspector v0.0.0" Style="{StaticResource OptLabel}" FontSize="13"/>
                <TextBlock Text="Read the facts of one device from a Configuration Manager site and from the device itself: operating system, client health, installed applications, updates, collections and deployments. Export the result as JSON or as an HTML report."
                           FontSize="12" TextWrapping="Wrap" Margin="0,8,0,0"/>
                <TextBlock Text="Author: Jason Ulbright. License: MIT."
                           FontSize="11" Margin="0,16,0,0" Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
            </StackPanel>
        </Grid>
        <Border Grid.Row="1" Grid.ColumnSpan="3" Padding="16,12,16,12">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="btnOk"     Content="OK"     Style="{StaticResource DialogAccentButton}" IsDefault="True"/>
                <Button x:Name="btnCancel" Content="Cancel" Style="{StaticResource DialogButton}"        IsCancel="True"/>
            </StackPanel>
        </Border>
    </Grid>
</Controls:MetroWindow>
'@
    [xml]$dx = $dlgXaml
    $reader2 = New-Object System.Xml.XmlNodeReader $dx
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader2)
    $dlg.Owner = $window
    Install-TitleBarDragFallback -Window $dlg
    Set-DialogTheme -Dialog $dlg
    $btnCatConnection = $dlg.FindName('btnCatConnection')
    $btnCatAbout      = $dlg.FindName('btnCatAbout')
    $paneConnection   = $dlg.FindName('paneConnection')
    $paneAbout        = $dlg.FindName('paneAbout')
    $txtAboutVersion  = $dlg.FindName('txtAboutVersion')
    if ($txtAboutVersion) { $txtAboutVersion.Text = ($txtAboutVersion.Text -replace 'v[0-9][0-9\.]*[0-9]\s*$', ('v' + $script:AppVersion)) }
    $txtSiteCode    = $dlg.FindName('txtSiteCode')
    $txtSmsProvider = $dlg.FindName('txtSmsProvider')
    $btnOk          = $dlg.FindName('btnOk')
    $btnCancel      = $dlg.FindName('btnCancel')
    $txtSiteCode.Text    = [string]$global:Prefs.SiteCode
    $txtSmsProvider.Text = [string]$global:Prefs.SMSProvider
    $btnCatConnection.Add_Click({ $paneConnection.Visibility = [System.Windows.Visibility]::Visible; $paneAbout.Visibility = [System.Windows.Visibility]::Collapsed })
    $btnCatAbout.Add_Click({      $paneConnection.Visibility = [System.Windows.Visibility]::Collapsed; $paneAbout.Visibility = [System.Windows.Visibility]::Visible })
    $btnOk.Add_Click({
        $neutralName = 'name'
        $check = Test-DeviceInspectorInput -ComputerName $neutralName -SiteServer ([string]$txtSmsProvider.Text) -SiteCode ([string]$txtSiteCode.Text)
        if (-not $check.IsValid) {
            # The title differs from the owner title (Options), so the two windows are not confused.
            [void](Show-ThemedMessage -Owner $dlg -Title 'Device Inspector' -Message ($check.Errors -join [Environment]::NewLine) -Icon Warn)
            return
        }
        $global:Prefs.SiteCode    = $check.SiteCode
        $global:Prefs.SMSProvider = $check.SiteServer
        Save-DiPreferences -Prefs $global:Prefs
        $txtSiteServer.Text = $check.SiteServer
        $dlg.DialogResult = $true; $dlg.Close()
    })
    $btnCancel.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    [void]$dlg.ShowDialog()
    Update-StatusBarSummary
}
$btnOptions.Add_Click({ Show-OptionsDialog })

# === Actions ===
# Every action follows the same path: the switch must be on, a dialog names the action
# and the device count, the person picks Run or Dry run, the work runs in the background,
# and the result goes to the window log, the tool log and the action log.
function Set-ActionsEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)
    $script:ActionsEnabled = $Enabled
    Add-LogLine $(if ($Enabled) { 'Actions on. Each action asks for a confirmation and offers a dry run. Action log: ' + $script:ActionLogPath } else { 'Actions off. The tool only reads.' })
    Update-ControlState
    Update-StatusBarSummary
}
$toggleActions.Add_Toggled({ Set-ActionsEnabled -Enabled ([bool]$toggleActions.IsOn) })

function Show-ActionConfirmDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string[]]$Devices
    )
    $dlgXaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="Confirm Action" Width="560" SizeToContent="Height" MinWidth="460"
    WindowStartupLocation="CenterOwner" TitleCharacterCasing="Normal"
    GlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    NonActiveGlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    BorderThickness="1" ResizeMode="NoResize" ShowIconOnTitleBar="False">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Steel.xaml" />
            </ResourceDictionary.MergedDictionaries>
            <!-- Contrast overrides, the same as in MainWindow.xaml: control borders need 3:1 and white title text 4.5:1. -->
            <SolidColorBrush x:Key="MahApps.Brushes.TextBox.Border" Color="#7F7F7F"/>
            <SolidColorBrush x:Key="MahApps.Brushes.WindowTitle.NonActive" Color="#595959"/>
            <!-- The one button template and the one button style, the same as in MainWindow.xaml. No color literal and
                 no Opacity: the colors come from the MahApps theme resources. -->
            <ControlTemplate x:Key="ThemedButtonTemplate" TargetType="Button">
                <Border Name="Bd"
                        Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}"
                        SnapsToDevicePixels="True">
                    <ContentPresenter Name="Cp"
                                      HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                      Margin="{TemplateBinding Padding}"
                                      RecognizesAccessKey="True"
                                      SnapsToDevicePixels="True"/>
                </Border>
                <ControlTemplate.Triggers>
                    <MultiTrigger>
                        <MultiTrigger.Conditions>
                            <Condition Property="IsMouseOver" Value="True"/>
                            <Condition Property="IsEnabled" Value="True"/>
                        </MultiTrigger.Conditions>
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </MultiTrigger>
                    <Trigger Property="IsKeyboardFocused" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="Bd" Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                        <Setter TargetName="Cp" Property="TextElement.Foreground" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>

            <Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="Template" Value="{StaticResource ThemedButtonTemplate}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderThickness" Value="1"/>
                <Setter Property="HorizontalContentAlignment" Value="Center"/>
                <Setter Property="VerticalContentAlignment" Value="Center"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray.MouseOver}"/>
                        <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                    </Trigger>
                </Style.Triggers>
            </Style>

            <!-- The one secondary dialog style: a gray fill, the theme text color and a visible border. Cancel and every
                 other dialog button that is not the main answer use it. The primary dialog style is DialogAccentButton.
                 No other dialog button style sets a Background. -->
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Gray10}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="MinWidth" Value="90"/>
                <Setter Property="Height" Value="32"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
            </Style>
            <!-- The accent fill is the theme highlight (#4A5763 dark, #00589F light): white text is 7:1 on both.
                 The border is the theme foreground: the highlight alone is 2.1:1 on the dark dialog.
                 The plain accent fill of the light theme is 4.49:1. -->
            <Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Highlight}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="MinWidth" Value="90"/>
                <Setter Property="Height" Value="32"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray.MouseOver}"/>
                        <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                    </Trigger>
                </Style.Triggers>
            </Style>
        </ResourceDictionary>
    </Window.Resources>
    <Grid Margin="16,12,16,12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border x:Name="bannerDevices" Grid.Row="0" Padding="10,6,10,6" Margin="0,4,0,12"
                Background="{DynamicResource MahApps.Brushes.Highlight}">
            <TextBlock x:Name="txtDeviceCount" TextWrapping="Wrap" FontSize="13" FontWeight="Bold"
                       Foreground="{DynamicResource MahApps.Brushes.IdealForeground}"/>
        </Border>
        <TextBlock x:Name="txtActionMessage" Grid.Row="1" TextWrapping="Wrap" FontSize="13" Margin="0,0,0,12"/>
        <TextBlock Grid.Row="2" TextWrapping="Wrap" FontSize="11" Margin="0,0,0,16"
                   Foreground="{DynamicResource MahApps.Brushes.Gray1}"
                   Text="Dry run reads the current state and lists the steps. It changes nothing. Run and Dry run both go to the action log."/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnActionRun"    Content="Run"     Style="{StaticResource DialogAccentButton}"/>
            <Button x:Name="btnActionDryRun" Content="Dry Run" Style="{StaticResource DialogButton}"/>
            <Button x:Name="btnActionCancel" Content="Cancel"  Style="{StaticResource DialogButton}" IsCancel="True" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Controls:MetroWindow>
'@
    [xml]$dx = $dlgXaml
    $dlg = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $dlg.Owner = $window
    $dlg.Title = ConvertTo-TitleCaseText $Title
    Install-TitleBarDragFallback -Window $dlg
    Set-DialogTheme -Dialog $dlg
    $count = @($Devices).Count
    $dlg.FindName('txtDeviceCount').Text = $(if ($count -eq 1) { 'This action targets 1 device: {0}' -f $Devices[0] } else { 'This action targets {0} devices: {1}' -f $count, (@($Devices) -join ', ') })
    $dlg.FindName('txtActionMessage').Text = $Message
    $script:ActionChoice = 'Cancel'
    $dlg.FindName('btnActionRun').Add_Click({ $script:ActionChoice = 'Run'; $dlg.Close() })
    $dlg.FindName('btnActionDryRun').Add_Click({ $script:ActionChoice = 'DryRun'; $dlg.Close() })
    $dlg.FindName('btnActionCancel').Add_Click({ $script:ActionChoice = 'Cancel'; $dlg.Close() })
    [void]$dlg.ShowDialog()
    $choice = $script:ActionChoice
    $script:ActionChoice = 'Cancel'
    return $choice
}

# The action log line comes first, in its own try. A failure of the window log does not drop it.
function Write-ActionResult {
    param([Parameter(Mandatory)]$Result)
    $logError = ''
    try { $null = Write-DeviceInspectorActionLog -Path $script:ActionLogPath -Result $Result }
    catch { $logError = [string]$_.Exception.Message }
    try {
        foreach ($line in @(ConvertTo-DeviceInspectorActionText -Result $Result)) { Add-LogLine $line }
        if ($logError) {
            Write-ErrorLog ('The action log could not be written: {0}' -f $logError)
            foreach ($detailLine in @($Result.Detail)) { if ($detailLine) { Write-ErrorLog ('Detail of {0}: {1}' -f $Result.ActionId, $detailLine) } }
            Add-LogLine 'The action log could not be written. The log file has the reason.'
        }
    }
    catch { Write-Log -Message ('The window log could not show an action result: {0}' -f $_.Exception.Message) -Level ERROR -Quiet }
}

# Shows the result of a device run in a window that does not take the focus. The person can
# keep typing or clicking in the main window. The window goes away with OK or with the main window.
function Show-ActionResultNotice {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Error')][string]$Icon = 'Info'
    )
    $dlgXaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="Action Result" Width="460" MinHeight="140" SizeToContent="Height"
    WindowStartupLocation="CenterOwner" TitleCharacterCasing="Normal"
    ShowActivated="False" ShowInTaskbar="False" ResizeMode="NoResize" ShowIconOnTitleBar="False"
    GlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    NonActiveGlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    BorderThickness="1">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Steel.xaml" />
            </ResourceDictionary.MergedDictionaries>
            <!-- Contrast overrides, the same as in MainWindow.xaml: control borders need 3:1 and white title text 4.5:1. -->
            <SolidColorBrush x:Key="MahApps.Brushes.TextBox.Border" Color="#7F7F7F"/>
            <SolidColorBrush x:Key="MahApps.Brushes.WindowTitle.NonActive" Color="#595959"/>
            <!-- The one button template and the one button style, the same as in MainWindow.xaml. No color literal and
                 no Opacity: the colors come from the MahApps theme resources. -->
            <ControlTemplate x:Key="ThemedButtonTemplate" TargetType="Button">
                <Border Name="Bd"
                        Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}"
                        SnapsToDevicePixels="True">
                    <ContentPresenter Name="Cp"
                                      HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                      Margin="{TemplateBinding Padding}"
                                      RecognizesAccessKey="True"
                                      SnapsToDevicePixels="True"/>
                </Border>
                <ControlTemplate.Triggers>
                    <MultiTrigger>
                        <MultiTrigger.Conditions>
                            <Condition Property="IsMouseOver" Value="True"/>
                            <Condition Property="IsEnabled" Value="True"/>
                        </MultiTrigger.Conditions>
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </MultiTrigger>
                    <Trigger Property="IsKeyboardFocused" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="Bd" Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                        <Setter TargetName="Cp" Property="TextElement.Foreground" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>

            <Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="Template" Value="{StaticResource ThemedButtonTemplate}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderThickness" Value="1"/>
                <Setter Property="HorizontalContentAlignment" Value="Center"/>
                <Setter Property="VerticalContentAlignment" Value="Center"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray.MouseOver}"/>
                        <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                    </Trigger>
                </Style.Triggers>
            </Style>

            <!-- The one secondary dialog style: a gray fill, the theme text color and a visible border. Cancel and every
                 other dialog button that is not the main answer use it. The primary dialog style is DialogAccentButton.
                 No other dialog button style sets a Background. -->
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Gray10}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="MinWidth" Value="90"/>
                <Setter Property="Height" Value="32"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
            </Style>
            <!-- The accent fill is the theme highlight (#4A5763 dark, #00589F light): white text is 7:1 on both.
                 The border is the theme foreground: the highlight alone is 2.1:1 on the dark dialog.
                 The plain accent fill of the light theme is 4.49:1. -->
            <Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Highlight}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="MinWidth" Value="90"/>
                <Setter Property="Height" Value="32"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray.MouseOver}"/>
                        <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                    </Trigger>
                </Style.Triggers>
            </Style>
        </ResourceDictionary>
    </Window.Resources>
    <Grid Margin="20,18,20,14">
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="txtIcon" Grid.Row="0" Grid.Column="0" FontSize="20" VerticalAlignment="Top" Margin="0,0,14,0"/>
        <TextBox x:Name="txtMsg" Grid.Row="0" Grid.Column="1" FontSize="13" TextWrapping="Wrap" IsReadOnly="True" BorderThickness="0" Background="Transparent" VerticalAlignment="Center"/>
        <Button x:Name="btnPrimary" Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" HorizontalAlignment="Right" Margin="0,18,0,0"
                Content="OK" Style="{StaticResource DialogAccentButton}"/>
    </Grid>
</Controls:MetroWindow>
'@
    [xml]$xml = $dlgXaml
    $dlg = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    Install-TitleBarDragFallback -Window $dlg
    $dlg.Owner = $window
    Set-DialogTheme -Dialog $dlg
    $dlg.Title = ConvertTo-TitleCaseText $Title
    $dlg.FindName('txtIcon').Text = $(if ($Icon -eq 'Error') { [string][char]0x2716 } else { [string][char]0x2139 })
    $dlg.FindName('txtMsg').Text = $Message
    $dlg.FindName('btnPrimary').Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).Close() })
    # Each open result window sits a little lower and to the right of the one before.
    if ($window.WindowState -eq [System.Windows.WindowState]::Normal) {
        $step = 28 * ($script:ResultNotices % 6)
        $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        $dlg.Left = $window.Left + 90 + $step
        $dlg.Top  = $window.Top + 110 + $step
    }
    $dlg.Add_Closed({ $script:ResultNotices = [Math]::Max(0, $script:ResultNotices - 1) })
    $script:ResultNotices++
    $dlg.Show()
}

# Warns before the window closes while device actions run. Wait is the default button and the
# Escape button, so Enter and Esc do not close the tool. Returns 'Close' or 'Wait'.
function Show-CloseWarningDialog {
    param([Parameter(Mandatory)][object[]]$Runs)
    $dlgXaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="Actions Still Running" Width="520" MinHeight="180" SizeToContent="Height"
    WindowStartupLocation="CenterOwner" TitleCharacterCasing="Normal"
    ResizeMode="NoResize" ShowIconOnTitleBar="False"
    GlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    NonActiveGlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    BorderThickness="1">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Steel.xaml" />
            </ResourceDictionary.MergedDictionaries>
            <!-- Contrast overrides, the same as in MainWindow.xaml: control borders need 3:1 and white title text 4.5:1. -->
            <SolidColorBrush x:Key="MahApps.Brushes.TextBox.Border" Color="#7F7F7F"/>
            <SolidColorBrush x:Key="MahApps.Brushes.WindowTitle.NonActive" Color="#595959"/>
            <!-- The one button template and the one button style, the same as in MainWindow.xaml. No color literal and
                 no Opacity: the colors come from the MahApps theme resources. -->
            <ControlTemplate x:Key="ThemedButtonTemplate" TargetType="Button">
                <Border Name="Bd"
                        Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}"
                        SnapsToDevicePixels="True">
                    <ContentPresenter Name="Cp"
                                      HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                      Margin="{TemplateBinding Padding}"
                                      RecognizesAccessKey="True"
                                      SnapsToDevicePixels="True"/>
                </Border>
                <ControlTemplate.Triggers>
                    <MultiTrigger>
                        <MultiTrigger.Conditions>
                            <Condition Property="IsMouseOver" Value="True"/>
                            <Condition Property="IsEnabled" Value="True"/>
                        </MultiTrigger.Conditions>
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </MultiTrigger>
                    <Trigger Property="IsKeyboardFocused" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="Bd" Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                        <Setter TargetName="Cp" Property="TextElement.Foreground" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>

            <Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="Template" Value="{StaticResource ThemedButtonTemplate}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderThickness" Value="1"/>
                <Setter Property="HorizontalContentAlignment" Value="Center"/>
                <Setter Property="VerticalContentAlignment" Value="Center"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray.MouseOver}"/>
                        <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                    </Trigger>
                </Style.Triggers>
            </Style>

            <!-- The one secondary dialog style: a gray fill, the theme text color and a visible border. Cancel and every
                 other dialog button that is not the main answer use it. The primary dialog style is DialogAccentButton.
                 No other dialog button style sets a Background. -->
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Gray10}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="MinWidth" Value="90"/>
                <Setter Property="Height" Value="32"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
            </Style>
            <!-- The accent fill is the theme highlight (#4A5763 dark, #00589F light): white text is 7:1 on both.
                 The border is the theme foreground: the highlight alone is 2.1:1 on the dark dialog.
                 The plain accent fill of the light theme is 4.49:1. -->
            <Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Highlight}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="MinWidth" Value="90"/>
                <Setter Property="Height" Value="32"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray.MouseOver}"/>
                        <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                    </Trigger>
                </Style.Triggers>
            </Style>
        </ResourceDictionary>
    </Window.Resources>
    <Grid Margin="20,18,20,14">
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="txtIcon" Grid.Row="0" Grid.Column="0" FontSize="20" VerticalAlignment="Top" Margin="0,0,14,0"/>
        <TextBox x:Name="txtMsg" Grid.Row="0" Grid.Column="1" FontSize="13" TextWrapping="Wrap" IsReadOnly="True" BorderThickness="0" Background="Transparent" VerticalAlignment="Center"/>
        <StackPanel Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
            <Button x:Name="btnWait" Content="Wait" IsDefault="True" IsCancel="True" Style="{StaticResource DialogAccentButton}"/>
            <Button x:Name="btnCloseAnyway" Content="Close Anyway" Style="{StaticResource DialogButton}"/>
        </StackPanel>
    </Grid>
</Controls:MetroWindow>
'@
    [xml]$xml = $dlgXaml
    $dlg = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    Install-TitleBarDragFallback -Window $dlg
    $dlg.Owner = $window
    Set-DialogTheme -Dialog $dlg
    $dlg.FindName('txtIcon').Text = [string][char]0x26A0
    $dlg.FindName('txtMsg').Text = Get-DeviceInspectorCloseWarningText -Run @($Runs)
    $script:CloseChoice = 'Wait'
    $dlg.FindName('btnCloseAnyway').Add_Click({ param($s, $e) $script:CloseChoice = 'Close'; [System.Windows.Window]::GetWindow($s).Close() })
    [void]$dlg.ShowDialog()
    return $script:CloseChoice
}

# Asks, then runs one device action in the background. Function is the name of an action
# function of the module; it receives ComputerName, DryRun and the extra Parameters.
# A device action runs in its own runspace and does not make the window busy. A site action
# (a change of the collections, which acts on the site) keeps the exclusive path: it holds
# the busy state and the progress overlay until it ends.
# AfterRun receives the result and Context, a hashtable that the caller fills. It runs only
# when the run succeeded, was not a dry run, and the device is still the device on screen.
function Invoke-DeviceAction {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Function,
        [hashtable]$Parameters = @{},
        [scriptblock]$AfterRun,
        [hashtable]$Context = @{},
        [string[]]$Detail = @(),
        [switch]$SiteAction
    )
    if ($SiteAction) {
        if (-not (Test-SiteActionReady)) {
            Add-LogLine ('{0}: {1}' -f $Name, (Get-ActionBlockText -Kind Site))
            return
        }
        $Parameters = @{ SiteServer = [string]$script:Inspection.SiteServer; SiteCode = [string]$script:Inspection.SiteCode } + $Parameters
    } elseif (-not (Test-DeviceActionReady)) {
        $why = Get-ActionBlockText -Kind Device
        Add-LogLine ('{0}: {1}' -f $Name, $why)
        if (Get-DeviceInspectorRunBlock -Run @($script:RunList) -ComputerName (Get-ActionTargetName) -ResourceId (Get-ActionTargetResourceId)) { [void](Show-ThemedMessage -Owner $window -Title 'Action' -Message $why -Icon Warn) }
        return
    }
    $device = [string]$script:Inspection.ComputerName
    $choice = Show-ActionConfirmDialog -Title $Name -Message $Message -Devices @($device)
    if ($choice -eq 'Cancel') { Add-LogLine ('{0}: cancelled.' -f $Name); Update-StatusBarSummary; return }
    $dry = ($choice -eq 'DryRun')
    # Each run and each dry run has an ID. The STARTED line, the result line and the close line carry it.
    $actionId = New-DeviceInspectorActionId
    $run = New-DeviceInspectorActionRun -ActionId $actionId -Action $Name -ComputerName $device -DryRun $dry -ResourceId (Get-ActionTargetResourceId)
    if (-not $SiteAction) {
        # The confirmation dialog is open for a while. A run can have started on this device since the check above.
        try { Register-DeviceInspectorActionRun -Runs $script:RunList -Run $run }
        catch {
            Write-ErrorLog ('{0}: {1}' -f $Name, $_.Exception.Message)
            $why = Get-DeviceInspectorRunBlock -Run @($script:RunList) -ComputerName $device -ResourceId (Get-ActionTargetResourceId)
            if (-not $why) { $why = 'Another action runs on this device. A device runs one action at a time. Wait until it ends.' }
            Add-LogLine ('{0}: {1}' -f $Name, $why)
            [void](Show-ThemedMessage -Owner $window -Title 'Action' -Message ([string]$why) -Icon Warn)
            return
        }
        # The run is on the list. A failure of the window code must not undo that.
        try { Update-ControlState } catch { Write-Log -Message ('The controls could not update after the run registered: {0}' -f $_.Exception.Message) -Level ERROR -Quiet }
    }
    if (-not $dry) {
        # A run that stops part way (window closed, connection lost) still leaves this line.
        $start = New-DeviceInspectorActionRecord -Action $Name -ComputerName $device -DryRun $false -Succeeded $false -Outcome 'STARTED' -ActionId $actionId -Summary 'The run started.' -Steps $Detail
        try { $null = Write-DeviceInspectorActionLog -Path $script:ActionLogPath -Result $start }
        catch {
            $logProblem = [string]$_.Exception.Message
            # Nothing runs yet, so the device goes free first, then the window tells the person.
            if (-not $SiteAction) {
                [void](Unregister-DeviceInspectorActionRun -Runs $script:RunList -ActionId $actionId)
                try { Update-ControlState } catch { Write-Log -Message ('The controls could not update: {0}' -f $_.Exception.Message) -Level ERROR -Quiet }
            }
            Write-ErrorLog ('{0}: the action log cannot be written: {1}' -f $Name, $logProblem)
            Add-LogLine ('{0}: the action log cannot be written, so the run does not start. The log file has the reason.' -f $Name)
            [void](Show-ThemedMessage -Owner $window -Title 'Action Log' -Message 'The action log cannot be written, so the run does not start. The log file has the reason.' -Icon Error)
            return
        }
    }
    $arguments = @{ Function = $Function; Parameters = (@{ ComputerName = $device; DryRun = $dry } + $Parameters) }
    if (-not $SiteAction) {
        try {
            Start-DeviceActionRun -Run $run -Arguments $arguments -AfterRun $AfterRun -Context $Context -Detail $Detail
        }
        catch {
            # Start-DeviceActionRun threw before the work began, so no run executes. The device goes free.
            $startProblem = [string]$_.Exception.Message
            [void](Unregister-DeviceInspectorActionRun -Runs $script:RunList -ActionId $actionId)
            try { Update-ControlState } catch { Write-Log -Message ('The controls could not update: {0}' -f $_.Exception.Message) -Level ERROR -Quiet }
            $failed = New-DeviceInspectorActionRecord -Action $Name -ComputerName $device -DryRun $dry -Succeeded $false -ActionId $actionId -Summary 'The run did not start. The action log has the reason.' -Steps $Detail -Detail @($startProblem)
            Write-ActionResult -Result $failed
            [void](Show-ThemedMessage -Owner $window -Title 'Action' -Message 'The run did not start. The action log has the reason.' -Icon Error)
            return
        }
        # From here the work executes. A failure of the window code below never takes the run off the list.
        try {
            Add-LogLine ('{0} on {1}: {2} started in the background (ID {3}).' -f $Name, $device, $(if ($dry) { 'dry run' } else { 'run' }), $actionId)
            Update-StatusBarSummary
        }
        catch { Write-Log -Message ('The window could not show the start of run {0}: {1}' -f $actionId, $_.Exception.Message) -Level ERROR -Quiet }
        return
    }
    $script:ActionAfterRun = $AfterRun
    $script:ActionContext = $Context
    $script:ActionPending = @{ Id = $actionId; Name = $Name; Device = $device; DryRun = $dry; Detail = $Detail }
    $title = $(if ($dry) { 'Dry run: {0} on {1}' -f $Name, $device } else { '{0} on {1}' -f $Name, $device })
    try {
        Start-ActionWork -Title $title -Arguments $arguments -Step 'Connecting to the site...'
    }
    catch {
        Stop-BackgroundWork
        $script:IsBusy = $false
        $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
        Update-ControlState
        $failed = New-DeviceInspectorActionRecord -Action $Name -ComputerName $device -DryRun $dry -Succeeded $false -ActionId $actionId -Summary 'The run did not start. The action log has the reason.' -Steps $Detail -Detail @([string]$_.Exception.Message)
        Write-ActionResult -Result $failed
        [void](Show-ThemedMessage -Owner $window -Title 'Action' -Message 'The run did not start. The action log has the reason.' -Icon Error)
    }
}

# Returns an open runspace for a device run. A runspace that a run left idle is used again, because
# a new one imports the module first. One runspace runs one pipeline at a time, so each running
# action needs its own runspace.
function Get-ActionRunspace {
    while ($script:RunspaceIdle.Count -gt 0) {
        $candidate = $script:RunspaceIdle[0]
        $script:RunspaceIdle = @($script:RunspaceIdle | Select-Object -Skip 1)
        if ($candidate.RunspaceStateInfo.State -eq 'Opened' -and $candidate.RunspaceAvailability -eq 'Available') { return $candidate }
        try { $candidate.CloseAsync() } catch { Write-ErrorLog ('An idle runspace could not be closed: {0}' -f $_.Exception.Message) }
    }
    return (New-SuiteBgRunspace -ModulePath $__modulePath -LogPath $script:ToolLogPath)
}

# Starts the work of one device run. The work runs on a background thread. The window thread
# reads the state of every run on a DispatcherTimer tick (Update-DeviceActionRun), so every
# change of the window happens on the Dispatcher thread.
function Start-DeviceActionRun {
    param(
        [Parameter(Mandatory)][pscustomobject]$Run,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [scriptblock]$AfterRun,
        [hashtable]$Context = @{},
        [string[]]$Detail = @()
    )
    $runspace = Get-ActionRunspace
    $state = [hashtable]::Synchronized(@{ Done = $false; Result = $null; ErrorMsg = $null })
    $ps = [powershell]::Create()
    try {
        $ps.Runspace = $runspace
        [void]$ps.AddScript({
            param($A, $State)
            try {
                $p = $A.Parameters
                $State.Result = & $A.Function @p
            }
            catch { $State.ErrorMsg = [string]$_.Exception.Message; if ($_.Exception.Data -and $_.Exception.Data.Contains('RawText')) { $State.ToolMessage = $State.ErrorMsg; $State.ErrorMsg = [string]$_.Exception.Data['RawText'] } }
            finally { $State.Done = $true }
        }).AddArgument($Arguments).AddArgument($state)
        $handle = $ps.BeginInvoke()
    }
    catch {
        try { $ps.Dispose() } catch { Write-ErrorLog ('A run object could not be disposed: {0}' -f $_.Exception.Message) }
        try { $runspace.CloseAsync() } catch { Write-ErrorLog ('A runspace could not be closed: {0}' -f $_.Exception.Message) }
        throw
    }
    $script:RunJobs[[string]$Run.ActionId] = @{ Run = $Run; PowerShell = $ps; Runspace = $runspace; Handle = $handle; State = $state; AfterRun = $AfterRun; Context = $Context; Detail = @($Detail) }
    # The work already runs. A failure of the timer must not throw into the caller, which would take a running run off the list.
    try {
        if (-not $script:RunTimer) {
            $script:RunTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:RunTimer.Interval = [TimeSpan]::FromMilliseconds(500)
            $script:RunTimer.Add_Tick({ Update-DeviceActionRun })
        }
        $script:RunTimer.Start()
    }
    catch { Write-Log -Message ('The timer of the running actions could not start: {0}' -f $_.Exception.Message) -Level ERROR -Quiet }
}

# One tick: finish every run whose work has ended. A run that fails to finish does not stop the others.
# A run counts as ended when its state says Done or when its asynchronous call is completed, so a
# pipeline that stopped without the Done flag still releases its device (the failure path writes a FAILED line).
function Update-DeviceActionRun {
    foreach ($id in @($script:RunJobs.Keys)) {
        $job = $script:RunJobs[$id]
        if (-not $job) { continue }
        if (-not (Test-DeviceInspectorRunFinished -State $job.State -Handle $job.Handle)) { continue }
        try { Complete-DeviceActionRun -Job $job }
        catch { Write-Log -Message ('Action {0}: the end of the run could not be processed: {1}' -f $id, $_.Exception.Message) -Level ERROR -Quiet }
    }
    if ($script:RunJobs.Count -eq 0 -and $script:RunTimer) { $script:RunTimer.Stop() }
}

# Ends one run on the window thread. The order is fixed:
#   1. read the end state and free the runspace;
#   2. write the result line of the action log (exactly one record for each run, in its own try);
#   3. take the run off the list, so the device is free again;
#   4. update the window. Each step has its own try, so a failure of the window never drops the result line.
function Complete-DeviceActionRun {
    param([Parameter(Mandatory)][hashtable]$Job)
    $run = $Job.Run
    $state = $Job.State
    $script:RunJobs.Remove([string]$run.ActionId)
    $problem = ''
    try { [void]$Job.PowerShell.EndInvoke($Job.Handle) } catch { $problem = [string]$_.Exception.Message }
    if ($state.ErrorMsg) { $problem = [string]$state.ErrorMsg }
    try { $Job.PowerShell.Dispose() } catch { Write-Log -Message ('Action {0}: the background work could not be disposed: {1}' -f $run.ActionId, $_.Exception.Message) -Level WARN -Quiet }
    $script:RunspaceIdle += ,$Job.Runspace
    $record = $null
    try { $record = Resolve-DeviceInspectorRunResult -Run $run -Result $state.Result -ErrorMessage $problem -Detail ([string[]]@($Job.Detail)) }
    catch { $record = New-DeviceInspectorActionRecord -Action ([string]$run.Action) -ComputerName ([string]$run.ComputerName) -DryRun ([bool]$run.DryRun) -Succeeded $false -ActionId ([string]$run.ActionId) -Summary 'The result could not be read. The action log has the reason.' -Steps @() -Detail @([string]$_.Exception.Message) }
    try { Write-ActionResult -Result $record }
    catch { Write-Log -Message ('Action {0}: the result could not be written: {1}' -f $run.ActionId, $_.Exception.Message) -Level ERROR -Quiet }
    try { [void](Unregister-DeviceInspectorActionRun -Runs $script:RunList -ActionId ([string]$run.ActionId)) }
    catch { Write-Log -Message ('Action {0}: the run could not leave the list: {1}' -f $run.ActionId, $_.Exception.Message) -Level ERROR -Quiet }
    try { Update-ControlState } catch { Write-Log -Message ('Action {0}: the controls could not update: {1}' -f $run.ActionId, $_.Exception.Message) -Level ERROR -Quiet }
    try { Update-StatusBarSummary } catch { Write-Log -Message ('Action {0}: the status bar could not update: {1}' -f $run.ActionId, $_.Exception.Message) -Level ERROR -Quiet }
    if (-not $script:WindowClosing) {
        try {
            $resultText = '{0} on {1}, {2} (ID {3}): {4}' -f $run.Action, $run.ComputerName, $run.Mode, $run.ActionId, $record.Summary
            Show-ActionResultNotice -Title $(if ($record.Succeeded) { 'Action result' } else { 'Action failed' }) -Message $resultText -Icon $(if ($record.Succeeded) { 'Info' } else { 'Error' })
        }
        catch { Write-Log -Message ('Action {0}: the result window could not open: {1}' -f $run.ActionId, $_.Exception.Message) -Level ERROR -Quiet }
    }
    if ($record.Succeeded -and -not $record.DryRun -and $Job.AfterRun) {
        try {
            # The same device is the device of the run by its key or by its site resource ID.
            $onScreen = [bool]($script:Inspection -and (Get-DeviceInspectorRunningAction -Run @($run) -ComputerName (Get-ActionTargetName) -ResourceId (Get-ActionTargetResourceId)))
            if ($onScreen) { & $Job.AfterRun $record $Job.Context }
            else { Add-LogLine ('{0}: {1} is not the device on screen. Inspect {1} to see the change.' -f $record.Action, $run.ComputerName) }
        }
        catch { Write-Log -Message ('Action {0}: the view could not refresh: {1}' -f $run.ActionId, $_.Exception.Message) -Level ERROR -Quiet }
    }
}

# Stops the polling when the window closes. It does not stop the open runs: a stop of the pipeline cuts
# off the remote call and can leave a run half done, for example after a delete and before the trigger that
# follows it. The tool only stops waiting. The close line of the action log says that the result is not known.
# Only idle runspaces are closed.
function Stop-DeviceActionRun {
    if ($script:RunTimer) { try { $script:RunTimer.Stop() } catch { Write-Log -Message ('The run timer could not stop: {0}' -f $_.Exception.Message) -Level WARN -Quiet } }
    foreach ($idle in @($script:RunspaceIdle)) {
        try { $idle.CloseAsync() } catch { Write-Log -Message ('An idle runspace could not close: {0}' -f $_.Exception.Message) -Level WARN -Quiet }
    }
    $script:RunspaceIdle = @()
}

# Site actions only: one run at a time, with the progress overlay.
function Start-ActionWork {
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][hashtable]$Arguments, [Parameter(Mandatory)][string]$Step)
    Start-BackgroundWork -Title $Title -Step $Step -Arguments $Arguments -Work {
        param($A, $State)
        try {
            $p = $A.Parameters
            $State.Result = & $A.Function @p
        }
        catch { $State.ErrorMsg = [string]$_.Exception.Message; if ($_.Exception.Data -and $_.Exception.Data.Contains('RawText')) { $State.ToolMessage = $State.ErrorMsg; $State.ErrorMsg = [string]$_.Exception.Data['RawText'] } }
        finally { $State.Done = $true }
    } -OnDone {
        param($State)
        if ($State.ErrorMsg) {
            $failed = New-DeviceInspectorActionRecord -Action $script:ActionPending.Name -ComputerName $script:ActionPending.Device -DryRun ([bool]$script:ActionPending.DryRun) -Succeeded $false -ActionId ([string]$script:ActionPending.Id) -Summary 'The action failed. The action log has the reason.' -Steps ([string[]]@($script:ActionPending.Detail)) -Detail @([string]$State.ErrorMsg)
            Write-ActionResult -Result $failed
            Add-LogLine 'Action failed. The action log has the reason.'
            Set-StatusText 'Action failed. The action log has the reason.'
            [void](Show-ThemedMessage -Owner $window -Title 'Action' -Message 'The action failed. The action log has the reason.' -Icon Error)
            return
        }
        $r = Add-DeviceInspectorActionId -Result $State.Result -ActionId ([string]$script:ActionPending.Id)
        if (@($r.Steps).Count -eq 0 -and @($script:ActionPending.Detail).Count -gt 0) { $r.Steps = [string[]]@($script:ActionPending.Detail) }
        Write-ActionResult -Result $r
        Update-StatusBarSummary
        $icon = $(if ($r.Succeeded) { 'Info' } else { 'Error' })
        [void](Show-ThemedMessage -Owner $window -Title 'Action Result' -Message ('{0} on {1}, {2} (ID {3}): {4}' -f $r.Action, $r.ComputerName, $r.Mode, $script:ActionPending.Id, $r.Summary) -Icon $icon)
        if ($r.Succeeded -and -not $r.DryRun -and $script:ActionAfterRun) { & $script:ActionAfterRun $r $script:ActionContext }
    }
}

$btnPolicyUpdate.Add_Click({
    Invoke-DeviceAction -Name 'Client policy update' -Function 'Invoke-DeviceInspectorPolicyUpdate' `
        -Message 'The Configuration Manager client on the device requests machine policy from its management point, then evaluates it (Machine Policy Retrieval and Evaluation Cycle).'
})

$btnFullInventory.Add_Click({
    Invoke-DeviceAction -Name 'Full hardware inventory' -Function 'Invoke-DeviceInspectorFullInventory' -AfterRun { param($r, $ctx) Clear-InventoryCheck } `
        -Message 'The tool deletes the hardware inventory status record on the device (InventoryActionStatus, root\ccm\invagt), then starts a hardware inventory cycle. The client then sends a full report, and the site replaces all hardware inventory of the device.'
})

$btnRepairInventory.Add_Click({
    if (-not (Test-InventoryCorrupt)) { Add-LogLine 'Repair inventory: the inventory check does not say Corrupt.'; return }
    $check = $script:Inspection.InventoryCheck
    Invoke-DeviceAction -Name 'Corrupt-inventory repair' -Function 'Invoke-DeviceInspectorInventoryRepair' `
        -Message ('{0} The tool deletes the hardware inventory status record on the device and starts a hardware inventory. The client sends a full report, and the site replaces the hardware inventory of the device. Inspect again after the site processes the report.' -f $check.Message) `
        -AfterRun { param($r, $ctx) Clear-InventoryCheck; Add-LogLine ('{0}: inspect {1} again after the site processes the full report.' -f $r.Action, $r.ComputerName) }
})

# Update install: only device rows that the client reports as missing (ComplianceState 0) can be installed.
function Get-InstallableUpdateRow {
    param([object[]]$Rows)
    return @($Rows | Where-Object { $_ -and $_.Source -eq 'Device' -and $_.Required -and -not [string]::IsNullOrEmpty([string]$_.UpdateId) })
}

function Set-MenuItemState {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][bool]$Enabled, [Parameter(Mandatory)][string]$Reason)
    $Item.IsEnabled = $Enabled
    $Item.ToolTip = $Reason
}

# A right-click selects the row under the pointer when that row is not selected,
# and clears the selection off the rows, so a menu entry acts on the row under the pointer.
function Select-RowUnderPointer {
    param([Parameter(Mandatory)]$Grid, [Parameter(Mandatory)]$MouseArgs)
    $node = $MouseArgs.OriginalSource
    while ($node -and -not ($node -is [System.Windows.Controls.DataGridRow])) {
        if ($node -is [System.Windows.Media.Visual] -or $node -is [System.Windows.Media.Media3D.Visual3D]) { $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node) }
        else { $node = [System.Windows.LogicalTreeHelper]::GetParent($node) }
    }
    if (-not $node) {
        $Grid.SelectedItems.Clear()
        return
    }
    if (-not $node.IsSelected) {
        $Grid.SelectedItems.Clear()
        $node.IsSelected = $true
    }
}
$gridUpdates.Add_PreviewMouseRightButtonDown({ param($s, $e) try { Select-RowUnderPointer -Grid $gridUpdates -MouseArgs $e } catch { $null = $_ } })

$gridUpdates.ContextMenu.Add_Opened({
    $all = Get-InstallableUpdateRow -Rows @($gridUpdates.ItemsSource)
    $selected = Get-InstallableUpdateRow -Rows @($gridUpdates.SelectedItems)
    $gate = Get-ActionGateText
    if ($gate) {
        Set-MenuItemState -Item $menuInstallSelected -Enabled $false -Reason $gate
        Set-MenuItemState -Item $menuInstallAll -Enabled $false -Reason $gate
        return
    }
    if ($selected.Count -gt 0) { Set-MenuItemState -Item $menuInstallSelected -Enabled $true -Reason ('Install {0} selected updates that the device lists as missing.' -f $selected.Count) }
    else { Set-MenuItemState -Item $menuInstallSelected -Enabled $false -Reason 'Select rows with the source Device that the client lists as missing.' }
    if ($all.Count -gt 0) { Set-MenuItemState -Item $menuInstallAll -Enabled $true -Reason ('Install all {0} updates that the device lists as missing.' -f $all.Count) }
    else { Set-MenuItemState -Item $menuInstallAll -Enabled $false -Reason 'The device lists no missing update in its client policy.' }
})

function Invoke-UpdateInstall {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows, [Parameter(Mandatory)][bool]$All)
    if ($Rows.Count -eq 0) { Add-LogLine 'Install updates: no row with a missing update.'; return }
    $list = ($Rows | ForEach-Object { '{0} {1}' -f $_.Article, $_.Title }) -join [Environment]::NewLine
    # The IDs of the confirmed rows go to the device also for "all", so an update that
    # arrived after the inspection is not installed without a confirmation.
    $parameters = @{ UpdateId = [string[]]@($Rows | ForEach-Object { [string]$_.UpdateId }); Scope = $(if ($All) { 'All' } else { 'Selected' }) }
    $name = $(if ($All) { 'Install all pending updates' } else { 'Install selected pending updates' })
    Invoke-DeviceAction -Name $name -Function 'Invoke-DeviceInspectorUpdateInstall' -Parameters $parameters `
        -Message ('The client on the device downloads and installs these {0} updates now (CCM_SoftwareUpdatesManager.InstallUpdates). The device can restart, as the deployment sets.{1}{1}{2}' -f $Rows.Count, [Environment]::NewLine, $list) `
        -AfterRun { param($r, $ctx) Add-LogLine ('{0}: inspect {1} again to see the update states.' -f $r.Action, $r.ComputerName) }
}
$menuInstallSelected.Add_Click({ Invoke-UpdateInstall -Rows (Get-InstallableUpdateRow -Rows @($gridUpdates.SelectedItems)) -All $false })
$menuInstallAll.Add_Click({ Invoke-UpdateInstall -Rows (Get-InstallableUpdateRow -Rows @($gridUpdates.ItemsSource)) -All $true })

# The reason why a device action cannot start now, or an empty string. The reason names the running
# action when the device of the inspection has one. A running action of another device does not block.
function Get-ActionGateText {
    return (Get-ActionBlockText -Kind Device)
}

$gridApps.Add_PreviewMouseRightButtonDown({ param($s, $e) try { Select-RowUnderPointer -Grid $gridApps -MouseArgs $e } catch { $null = $_ } })
$gridApps.ContextMenu.Add_Opened({
    $gate = Get-ActionGateText
    $rows = @($gridApps.SelectedItems)
    $row = $(if ($rows.Count -eq 1) { $rows[0] } else { $null })
    foreach ($pair in @(@{ Item = $menuUninstallApp; Op = 'Uninstall'; Flag = 'CanUninstall'; Why = 'UninstallReason'; Command = 'UninstallCommand' }, @{ Item = $menuRepairApp; Op = 'Repair'; Flag = 'CanRepair'; Why = 'RepairReason'; Command = 'RepairCommand' })) {
        if ($gate) { Set-MenuItemState -Item $pair.Item -Enabled $false -Reason $gate; continue }
        if (-not $row) { Set-MenuItemState -Item $pair.Item -Enabled $false -Reason 'Select one row.'; continue }
        if (-not [bool]$row.($pair.Flag)) {
            $why = [string]$row.($pair.Why)
            if ([string]::IsNullOrEmpty($why)) { $why = ('{0} is not available for this entry.' -f $pair.Op) }
            Set-MenuItemState -Item $pair.Item -Enabled $false -Reason $why
            continue
        }
        Set-MenuItemState -Item $pair.Item -Enabled $true -Reason ('{0} {1} on the device with: {2}' -f $pair.Op, $row.Name, $row.($pair.Command))
    }
})

function Invoke-ApplicationOperation {
    param([Parameter(Mandatory)][ValidateSet('Uninstall', 'Repair')][string]$Operation)
    $rows = @($gridApps.SelectedItems)
    if ($rows.Count -ne 1) { Add-LogLine ('{0}: select one row.' -f $Operation); return }
    $row = $rows[0]
    $flagName = ('Can{0}' -f $Operation)
    if (-not [bool]$row.$flagName) { Add-LogLine ('{0}: {1}' -f $Operation, $row.Reason); return }
    # The command is built here for display only. The device reads the key again and builds the real command.
    $commandName = ('{0}Command' -f $Operation)
    $command = [string]$row.$commandName
    $verb = $(if ($Operation -eq 'Uninstall') { 'uninstalls' } else { 'repairs' })
    $nl = [Environment]::NewLine
    $label = Get-DeviceInspectorApplicationLabel -Name ([string]$row.Name) -Version ([string]$row.Version)
    $text = ('The device {0} {1} ({2}, {3} view, key {4}) now. It reads the registry key again, then runs this command and waits up to 10 minutes for it:{5}{5}{6}{5}{5}The tool adds no switches. If the installer needs a restart, the tool does not restart the device.' -f $verb, $label, $row.Type, $row.View, $row.KeyName, $nl, $command)
    Invoke-DeviceAction -Name ('{0} application' -f $Operation) -Function 'Invoke-DeviceInspectorApplicationAction' `
        -Parameters @{ Operation = $Operation; View = [string]$row.View; KeyName = [string]$row.KeyName } `
        -Message $text `
        -Context @{ Row = $row } `
        -Detail @(('Application: {0}, {1}, {2} view, key {3}.' -f $label, $row.Type, $row.View, $row.KeyName), ('Command shown to the person: {0}' -f $command)) `
        -AfterRun {
            param($r, $ctx)
            # After a real Uninstall the row stays in the list until the next inspection. Its actions turn off.
            if ($ctx.Row -and $r.Action -like 'Uninstall*') {
                $done = 'The entry was uninstalled in this session. Inspect the device again to refresh the list.'
                $ctx.Row.CanUninstall = $false; $ctx.Row.CanRepair = $false
                $ctx.Row.UninstallReason = $done; $ctx.Row.RepairReason = $done; $ctx.Row.Reason = $done
                Update-AppFilter
            }
            Add-LogLine ('{0}: inspect {1} again to see the new state.' -f $r.Action, $r.ComputerName)
        }
}
$menuUninstallApp.Add_Click({ Invoke-ApplicationOperation -Operation 'Uninstall' })
$menuRepairApp.Add_Click({ Invoke-ApplicationOperation -Operation 'Repair' })

$gridCollections.Add_PreviewMouseRightButtonDown({ param($s, $e) try { Select-RowUnderPointer -Grid $gridCollections -MouseArgs $e } catch { $null = $_ } })
$gridCollections.ContextMenu.Add_Opened({
    $rows = @($gridCollections.SelectedItems)
    $row = $(if ($rows.Count -eq 1) { $rows[0] } else { $null })
    $gate = Get-ActionBlockText -Kind Site
    $reason = $(if ($gate) { $gate }
        elseif (-not $row) { 'Select one row.' }
        elseif ($row.IsBuiltIn) { 'This is a built-in collection. Built-in collections have no direct membership rules.' }
        elseif ($row.IsRemoved) { 'The direct rule was removed. Inspect the device again.' }
        elseif ($false -eq $row.IsDirect) { 'The device is a member through a query, include or other rule. Only a direct rule can be removed here.' }
        else { '' })
    if ($reason) { Set-MenuItemState -Item $menuRemoveCollection -Enabled $false -Reason $reason }
    else { Set-MenuItemState -Item $menuRemoveCollection -Enabled $true -Reason ('Remove the direct rule of the device from {0}.' -f $row.Name) }
    if ($gate) { Set-MenuItemState -Item $menuAddCollection -Enabled $false -Reason $gate }
    else { Set-MenuItemState -Item $menuAddCollection -Enabled $true -Reason 'Pick a device collection and add a direct membership rule for the device.' }
})
$menuRemoveCollection.Add_Click({
    $rows = @($gridCollections.SelectedItems)
    if ($rows.Count -ne 1 -or $false -eq $rows[0].IsDirect -or $rows[0].IsBuiltIn -or $rows[0].IsRemoved) { Add-LogLine 'Remove from collection: select one row with a direct rule.'; return }
    $row = $rows[0]
    Invoke-DeviceAction -SiteAction -Name 'Remove from collection' -Function 'Invoke-DeviceInspectorCollectionChange' `
        -Parameters @{ CollectionId = [string]$row.CollectionId; Operation = 'Remove'; ExpectedResourceId = [int]$script:Inspection.Site.ResourceId } `
        -Message ('The site removes the direct membership rule of the device from {0} ({1}), starts a membership update of the collection, waits up to 60 seconds for the new membership, and then asks the client for machine policy. If another rule also adds the device, the device stays a member. Deployments to this collection stop applying to the device.' -f $row.Name, $row.CollectionId) `
        -Context @{ Row = $row } `
        -Detail @(('Collection: {0} ({1}).' -f $row.Name, $row.CollectionId)) `
        -AfterRun { param($r, $ctx) if ($ctx.Row) { $ctx.Row.IsRemoved = $true; $ctx.Row.Membership = 'Rule removed: inspect again' }; $gridCollections.Items.Refresh(); Add-LogLine ('{0}: inspect {1} again after the membership update.' -f $r.Action, $r.ComputerName) }
})

function Invoke-AddToCollection {
    $gate = Get-ActionBlockText -Kind Site
    if ($gate) { Add-LogLine ('Add to collection: {0}' -f $gate); return }
    $arguments = @{ Server = [string]$script:Inspection.SiteServer; Code = [string]$script:Inspection.SiteCode }
    Start-BackgroundWork -Title 'Reading the device collections' -Step 'Connecting to the site...' -Arguments $arguments -Work {
        param($A, $State)
        try { $State.Result = @(Get-DeviceInspectorCollectionList -SiteServer $A.Server -SiteCode $A.Code) }
        catch { $State.ErrorMsg = [string]$_.Exception.Message; if ($_.Exception.Data -and $_.Exception.Data.Contains('RawText')) { $State.ToolMessage = $State.ErrorMsg; $State.ErrorMsg = [string]$_.Exception.Data['RawText'] } }
        finally { $State.Done = $true }
    } -OnDone {
        param($State)
        Update-StatusBarSummary
        if ($State.ErrorMsg) {
            Write-ErrorLog ('Add to collection: the collections cannot be read: {0}' -f $State.ErrorMsg)
            Add-LogLine 'Add to collection: the collections cannot be read. The log file has the reason.'
            [void](Show-ThemedMessage -Owner $window -Title 'Add to Collection' -Message $(if ($State.ToolMessage) { [string]$State.ToolMessage } else { 'The collections cannot be read. Check the site server, the site code and your account rights. The log file has the reason.' }) -Icon Error)
            return
        }
        $choices = @(Select-DeviceInspectorAddableCollection -Collections @($State.Result) -Rows @($gridCollections.ItemsSource))
        Add-LogLine ('Add to collection: {0} device collections, {1} to pick from.' -f @($State.Result).Count, $choices.Count)
        if ($choices.Count -eq 0) {
            [void](Show-ThemedMessage -Owner $window -Title 'Add to Collection' -Message 'The site has no device collection to pick: each one is built in or already has a direct rule for the device.' -Icon Info)
            return
        }
        $picked = Show-CollectionPickerDialog -Owner $window -Collections $choices -Folders @() -Title 'Add to Collection' -IncludeBuiltIn $false
        if (-not $picked) { Add-LogLine 'Add to collection: no collection picked.'; return }
        Invoke-DeviceAction -SiteAction -Name 'Add to collection' -Function 'Invoke-DeviceInspectorCollectionChange' `
            -Parameters @{ CollectionId = [string]$picked.CollectionID; Operation = 'Add'; ExpectedResourceId = [int]$script:Inspection.Site.ResourceId } `
            -Message ('The site adds a direct membership rule for the device to {0} ({1}), starts a membership update of the collection, waits up to 60 seconds for the new membership, and then asks the client for machine policy. Deployments to this collection start to apply to the device.' -f $picked.Name, $picked.CollectionID) `
            -Detail @(('Collection: {0} ({1}).' -f $picked.Name, $picked.CollectionID)) `
            -AfterRun { param($r, $ctx) Add-LogLine ('{0}: inspect {1} again to see the new membership.' -f $r.Action, $r.ComputerName) }
    }
}
$btnAddCollection.Add_Click({ Invoke-AddToCollection })
$menuAddCollection.Add_Click({ Invoke-AddToCollection })

# === Device list ===
function Invoke-DeviceListSearch {
    if ($script:IsBusy) { return }
    $pattern = ([string]$txtListName.Text).Trim()
    $collection = ([string]$txtListCollection.Text).Trim().ToUpperInvariant()
    $neutralName = 'name'
    $check = Test-DeviceInspectorInput -ComputerName $neutralName -SiteServer ([string]$txtSiteServer.Text) -SiteCode ([string]$global:Prefs.SiteCode)
    $problems = @()
    if (-not $check.IsValid) { $problems += $check.Errors }
    if (-not $check.SiteServer -and $problems.Count -eq 0) { $problems += 'Enter a site server in the Inspect bar. The device list reads the site.' }
    if (-not $pattern -and -not $collection) { $problems += 'Enter a name pattern, a collection ID, or both.' }
    if ($pattern -and -not $collection -and $pattern -notmatch '[A-Za-z0-9]') { $problems += 'A name pattern without a collection needs at least one letter or digit.' }
    if ($pattern -and $pattern -notmatch '^[A-Za-z0-9_.*?-]{1,63}$') { $problems += 'The name pattern can hold letters, digits, hyphen, underscore, dot, * and ?.' }
    if ($collection -and $collection -notmatch '^[A-Z0-9]{8}$') { $problems += 'A collection ID has eight letters and digits, for example SMS00001.' }
    if ($problems.Count -gt 0) {
        Add-LogLine ('Device list: {0}' -f ($problems -join ' '))
        [void](Show-ThemedMessage -Owner $window -Title 'Device List' -Message ($problems -join [Environment]::NewLine) -Icon Warn)
        return
    }
    $arguments = @{ Server = $check.SiteServer; Code = $check.SiteCode; Pattern = $pattern; Collection = $collection }
    Add-LogLine ('Device list: name={0} collection={1}' -f $(if ($pattern) { $pattern } else { '(any)' }), $(if ($collection) { $collection } else { '(any)' }))
    Start-BackgroundWork -Title 'Reading the device list' -Step 'Connecting to the site...' -Arguments $arguments -Work {
        param($A, $State)
        try { $State.Result = Get-DeviceInspectorDeviceList -SiteServer $A.Server -SiteCode $A.Code -NamePattern $A.Pattern -CollectionId $A.Collection }
        catch { $State.ErrorMsg = [string]$_.Exception.Message; if ($_.Exception.Data -and $_.Exception.Data.Contains('RawText')) { $State.ToolMessage = $State.ErrorMsg; $State.ErrorMsg = [string]$_.Exception.Data['RawText'] } }
        finally { $State.Done = $true }
    } -OnDone {
        param($State)
        Update-StatusBarSummary
        if ($State.ErrorMsg) {
            Write-ErrorLog ('Device list failed: {0}' -f $State.ErrorMsg)
            Add-LogLine 'Device list failed. The log file has the reason.'
            $gridDeviceList.ItemsSource = @()
            $txtListSummary.Text = 'The search failed. The log file has the reason.'
            Update-ControlState
            [void](Show-ThemedMessage -Owner $window -Title 'Device List' -Message $(if ($State.ToolMessage) { [string]$State.ToolMessage } else { 'The search failed. Check the site server, the site code and your account rights. The log file has the reason.' }) -Icon Error)
            return
        }
        $list = $State.Result
        $gridDeviceList.ItemsSource = @($list.Devices)
        $txtListSummary.Text = $(if ($list.Truncated) { '{0} devices match. The list shows the first {1}. Narrow the pattern.' -f $list.Total, @($list.Devices).Count } else { '{0} devices match.' -f $list.Total })
        Add-LogLine ('Device list: {0} devices.' -f $list.Total)
        Update-ControlState
    }
}

function Invoke-ListInspect {
    $row = $gridDeviceList.SelectedItem
    if (-not $row -or [string]::IsNullOrEmpty([string]$row.Name)) { Add-LogLine 'Device list: select a device first.'; return }
    if ($script:IsBusy) { return }
    $txtDevice.Text = [string]$row.Name
    Set-ActiveView -View 'Device'
    Invoke-Inspect
}
$btnListSearch.Add_Click({ Invoke-DeviceListSearch })
$txtListName.Add_KeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Return) { Invoke-DeviceListSearch } })
$txtListCollection.Add_KeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Return) { Invoke-DeviceListSearch } })
$btnListInspect.Add_Click({ Invoke-ListInspect })
$gridDeviceList.Add_MouseDoubleClick({
    param($s, $e)
    # The event also fires on a header, the scroll bar and empty space; only a row inspects.
    $node = $e.OriginalSource
    while ($node -and -not ($node -is [System.Windows.Controls.DataGridRow]) -and -not ($node -is [System.Windows.Controls.DataGrid])) {
        if ($node -is [System.Windows.Media.Visual] -or $node -is [System.Windows.Media.Media3D.Visual3D]) { $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node) }
        else { $node = [System.Windows.LogicalTreeHelper]::GetParent($node) }
    }
    if ($node -is [System.Windows.Controls.DataGridRow]) { Invoke-ListInspect }
})
$gridDeviceList.Add_SelectionChanged({ Update-ControlState })

# === Log file ===
$btnOpenLog.Add_Click({
    if (-not (Test-Path -LiteralPath $script:ToolLogPath)) { Add-LogLine ('The log file does not exist yet: {0}' -f $script:ToolLogPath); return }
    try { Invoke-Item -LiteralPath $script:ToolLogPath -ErrorAction Stop; Add-LogLine ('Opened the log file: {0}' -f $script:ToolLogPath) }
    catch {
        Write-ErrorLog ('The log file cannot be opened: {0}' -f $_.Exception.Message)
        Add-LogLine 'The log file cannot be opened with the default program of Windows.'
    }
})

# === Window state (geometry logic: SuiteCommon) ===
$global:WindowStatePath = Join-Path $PSScriptRoot 'DeviceInspector.windowstate.json'

# Closing with device actions still running needs a confirmation. The tool does not stop the runs. It stops
# waiting for them, and a run on a device can stop before it is complete. The tool cannot write their result
# lines after the window closes, so it writes one CLOSED line for each open run (same ID as the STARTED line).
$window.Add_Closing({
    param($s, $e)
    if ($script:RunList.Count -gt 0) {
        $answer = Show-CloseWarningDialog -Runs @($script:RunList)
        if ($answer -ne 'Close') { $e.Cancel = $true; return }
    }
    $script:WindowClosing = $true
    if ($script:RunTimer) { $script:RunTimer.Stop() }
    # One pass first: a run that ended since the last tick gets its real result line, not a CLOSED line.
    try { Update-DeviceActionRun } catch { Write-Log -Message ('The last pass over the running actions failed: {0}' -f $_.Exception.Message) -Level ERROR -Quiet }
    $open = @($script:RunList)
    if ($open.Count -gt 0) {
        # The end of this script decides whether the process needs an explicit exit (see the end of this script).
        $script:ClosedWithOpenRuns = $true
        try {
            $written = Write-DeviceInspectorCloseLog -Path $script:ActionLogPath -Run $open
            Write-Log -Message ('Window closed with {0} running actions. Wrote {1} CLOSED lines to the action log.' -f $open.Count, $written) -Quiet
        }
        catch { Write-Log -Message ('The action log could not be written at close: {0}' -f $_.Exception.Message) -Level ERROR -Quiet }
    }
    Save-WindowState -Window $window -Path $global:WindowStatePath -ExtraState @{ ActiveView = $script:ActiveView }
    Stop-DeviceActionRun
    Stop-BackgroundWork
    Close-SuiteBgRunspace -Runspace $script:BgRunspace
})

$window.Add_Loaded({
    Restore-WindowState -Window $window -Path $global:WindowStatePath -OnStateLoaded {
        param($s)
        if ($s.ActiveView -in @('Device list', 'Device', 'Applications', 'Updates', 'Collections', 'Problems')) { Set-ActiveView -View ([string]$s.ActiveView) }
    }
    $isDark = [bool]$global:Prefs['DarkMode']
    if (-not $isDark) { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Light.Blue') }
    Update-TitleBarBrushes
    $txtDevice.Text     = [string]$global:Prefs['LastDevice']
    $txtSiteServer.Text = [string]$global:Prefs['SMSProvider']
    $chkSiteOnly.IsChecked = [bool]$global:Prefs['SiteOnly']
    Update-ControlState
    Update-StatusBarSummary
    Add-LogLine 'Device Inspector ready. Enter a device name and a site server, then click Inspect. The tool only reads until you turn on Enable Actions.'
    Add-LogLine ('Log file: {0}' -f $script:ToolLogPath)
})

# Suite update notice: one shared daily lookup across the suite tools; the launcher installs.
$null = Start-SuiteUpdateNotice -Path $PSScriptRoot -OnResult { param($u) if ($u.Available) { Add-LogLine ('Suite update available: v{0}. Update from the AppPackager Suite Launcher.' -f $u.Latest) } }
$script:OwnsProcess = Test-DeviceInspectorProcessOwner -ScriptPath $PSCommandPath -CommandLineArgs @([Environment]::GetCommandLineArgs())
[void]$window.ShowDialog()
try { Stop-Transcript | Out-Null } catch { $null = $_ }
# A run that was open when the window closed holds a Windows PowerShell remoting call (WinRM). The normal end of
# the host waits for that call to return, so the process can stay for as long as the call is held. BeginStop and
# CloseAsync do not change this (measured in the pull request of W-12). Every log line is written and closed by
# now (each write opens and closes the file, and the transcript is stopped), so an explicit exit loses no log
# line. The exit happens only when this script owns the process (started with -File, as the suite launcher
# does). A script that an admin runs inside a console returns as normal: the console stays open. The CLOSED
# lines say that the result of the run is not known.
if (Test-DeviceInspectorExitNeeded -OpenRunClosed $script:ClosedWithOpenRuns -OwnsProcess $script:OwnsProcess) { [Environment]::Exit(0) }
