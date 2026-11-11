<#
.SYNOPSIS
    Main window of Device Inspector, a tool that shows the facts of one device from a Configuration Manager site and from the device itself, with optional actions.

.DESCRIPTION
    Sidebar navigation across five panels (Device, Applications, Updates,
    Collections, Problems). The action bar holds the device name, the site
    server, the Inspect button and the JSON and HTML exports.

    The inspection only reads. It reads the site with the ConfigurationManager
    cmdlets and SELECT queries and reads the device with one remote script
    block. Actions change the device or the site. They run only when Enable
    actions is on, after a confirmation, and each run and dry run goes to the
    action log. The tool uses the permissions of the signed-in user and stores
    no password. The only files it writes are the log files, the action log
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
    Version    : 2026.11.10.0005
    Updated    : 2026-11-07
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

$viewDevice      = $window.FindName('viewDevice')
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
$cboAppStatus    = $window.FindName('cboAppStatus')
$gridApps        = $window.FindName('gridApps')
$gridUpdates     = $window.FindName('gridUpdates')
# Context menu items are outside the name scope of the window.
$menuInstallSelected = @($gridUpdates.ContextMenu.Items | Where-Object { $_.Name -eq 'menuInstallSelected' })[0]
$menuInstallAll      = @($gridUpdates.ContextMenu.Items | Where-Object { $_.Name -eq 'menuInstallAll' })[0]
$gridCollections = $window.FindName('gridCollections')
$gridDeployments = $window.FindName('gridDeployments')
$txtProblems     = $window.FindName('txtProblems')

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

# === Title-bar drag fallback: SuiteCommon owns the hook ===
Install-TitleBarDragFallback -Window $window

# === Theme (palette, sidebar, title bar, dialogs: SuiteCommon) ===
[void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Dark.Steel')

$script:ViewButtons = @(
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

function Test-DeviceActionReady {
    # A device action needs the switch, an idle window and an inspection that reached the device.
    return [bool]($script:ActionsEnabled -and -not $script:IsBusy -and $script:Inspection -and $null -ne $script:Inspection.Device)
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
    $txtDevice.IsEnabled     = $idle
    $txtSiteServer.IsEnabled = $idle
    $chkSiteOnly.IsEnabled   = $idle
    $btnExportJson.IsEnabled = $has
    $btnExportHtml.IsEnabled = $has
    $toggleActions.IsEnabled = $idle
    $btnPolicyUpdate.IsEnabled = Test-DeviceActionReady
    $btnFullInventory.IsEnabled = Test-DeviceActionReady
    $btnRepairInventory.IsEnabled = (Test-DeviceActionReady) -and (Test-InventoryCorrupt)
}

# === View switching ===
$script:ViewMeta = @{
    'Device'       = @{ Title = 'Device';       Subtitle = 'Operating system, client health and site record of the device.' }
    'Applications' = @{ Title = 'Applications'; Subtitle = 'Applications installed on the device compared with the site hardware inventory.' }
    'Updates'      = @{ Title = 'Updates';      Subtitle = 'Updates that the site lists as required for the device, and updates pending on the device.' }
    'Collections'  = @{ Title = 'Collections';  Subtitle = 'Collections that hold the device and the deployments that target them.' }
    'Problems'     = @{ Title = 'Problems';     Subtitle = 'Parts of the inspection that failed. The other parts still ran.' }
}
function Set-ActiveView {
    param([Parameter(Mandatory)][ValidateSet('Device', 'Applications', 'Updates', 'Collections', 'Problems')][string]$View)
    $script:ActiveView = $View
    $vis = [System.Windows.Visibility]::Visible
    $hid = [System.Windows.Visibility]::Collapsed
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
    Set-StatusText ($parts -join '   |   ')
}

# === Applications filter ===
function Get-AppStatusFilter {
    if ($cboAppStatus.SelectedItem) { return [string]$cboAppStatus.SelectedItem.Content }
    return 'All'
}
function Update-AppFilter {
    $needle = ([string]$txtAppFilter.Text).Trim().ToLowerInvariant()
    $status = Get-AppStatusFilter
    $rows = @($script:AppRows)
    if ($needle) { $rows = @($rows | Where-Object { ([string]$_.Name).ToLowerInvariant().Contains($needle) }) }
    if ($status -ne 'All') { $rows = @($rows | Where-Object { $_.Status -eq $status }) }
    $gridApps.ItemsSource = $rows
}
$txtAppFilter.Add_TextChanged({ Update-AppFilter })
$cboAppStatus.Add_SelectionChanged({ Update-AppFilter })

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
    $txtProblems.Text = if ($problems.Count -eq 0) { 'No problems. Every part of the inspection ran.' } else { ($problems | ForEach-Object { '- ' + $_ }) -join [Environment]::NewLine }
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
        Add-LogLine 'Inspect: Site only needs a site server.'
        Set-StatusText 'Enter a site server, or clear Site only.'
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
        catch { $State.ErrorMsg = $_.Exception.Message }
        finally { $State.Done = $true }
    } -OnDone {
        param($State)
        if ($State.ErrorMsg) {
            Add-LogLine ('Inspect failed: {0}' -f $State.ErrorMsg)
            Set-StatusText 'Inspect failed. See the log.'
            [void](Show-ThemedMessage -Owner $window -Title 'Inspect' -Message ([string]$State.ErrorMsg) -Icon Error)
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
        Add-LogLine ('Export {0} failed: {1}' -f $Kind, $_.Exception.Message)
        [void](Show-ThemedMessage -Owner $window -Title 'Export' -Message ([string]$_.Exception.Message) -Icon Error)
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
            <!-- Contrast fixes, the same as in MainWindow.xaml: inactive dark title bar, text box border,
                 and a button template that keeps 4.5:1 text and a 3:1 border when disabled. -->
            <SolidColorBrush x:Key="MahApps.Brushes.WindowTitle.NonActive" Color="#666666"/>
            <SolidColorBrush x:Key="MahApps.Brushes.TextBox.Border" Color="#7A7A7A"/>
            <ControlTemplate x:Key="AppButtonTemplate" TargetType="ButtonBase">
                <Grid>
                    <Border x:Name="AppBd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True"/>
                    <Rectangle x:Name="AppHover" Margin="{TemplateBinding BorderThickness}" Opacity="0"
                               Fill="{DynamicResource MahApps.Brushes.Gray.SemiTransparent}"/>
                    <ContentPresenter x:Name="AppContent" Margin="{TemplateBinding Padding}"
                                      HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                      RecognizesAccessKey="True" SnapsToDevicePixels="True"/>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="AppHover" Property="Opacity" Value="1"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="AppHover" Property="Opacity" Value="0"/>
                        <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                    </Trigger>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                        <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                        <Setter TargetName="AppContent" Property="Opacity" Value="0.6"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
            <Style x:Key="CategoryRowStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="Template" Value="{StaticResource AppButtonTemplate}"/>
                <Setter Property="VerticalContentAlignment" Value="Center"/>
                <Setter Property="Height" Value="36"/>
                <Setter Property="HorizontalContentAlignment" Value="Left"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="FontSize" Value="13"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
                <Setter Property="Margin" Value="0"/>
            </Style>
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="Template" Value="{StaticResource AppButtonTemplate}"/>
                <Setter Property="HorizontalContentAlignment" Value="Center"/>
                <Setter Property="VerticalContentAlignment" Value="Center"/>
                <Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="32"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
            <!-- The MahApps accent (80 percent opaque) gives white text 3.3:1 in the light theme.
                 The opaque highlight colour gives 7:1 in both themes. -->
            <Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource DialogButton}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Highlight}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>
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
                <TextBlock Text="Configuration Manager Connection" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock Text="Site server (SMS Provider FQDN)" FontSize="11" Margin="0,4,0,2" Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
                <TextBox x:Name="txtSmsProvider" FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="e.g. sms01.example.com"/>
                <TextBlock Text="Site Code" FontSize="11" Margin="0,12,0,2" Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
                <TextBox x:Name="txtSiteCode" FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="e.g. XYZ. Required with a site server." Width="240" HorizontalAlignment="Left"/>
                <TextBlock Text="The tool connects with the Windows account that runs it and stores no password. The tool needs the Configuration Manager console on this computer. The account needs local administrator rights on the device (WinRM). For the site, a domain admin account that is a local administrator of the SMS Provider computer needs no Configuration Manager role. An account with fewer rights on the site is not tested. Only actions make changes."
                           FontSize="11" TextWrapping="Wrap" Margin="0,16,0,0"
                           Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
            </StackPanel>
            <StackPanel x:Name="paneAbout" Visibility="Collapsed">
                <TextBlock Text="About" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock x:Name="txtAboutVersion" Text="Device Inspector v0.0.0" FontSize="13" FontWeight="SemiBold"/>
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
    Title="Confirm action" Width="560" SizeToContent="Height" MinWidth="460"
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
            <SolidColorBrush x:Key="MahApps.Brushes.WindowTitle.NonActive" Color="#666666"/>
            <ControlTemplate x:Key="AppButtonTemplate" TargetType="ButtonBase">
                <Grid>
                    <Border x:Name="AppBd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True"/>
                    <Rectangle x:Name="AppHover" Margin="{TemplateBinding BorderThickness}" Opacity="0"
                               Fill="{DynamicResource MahApps.Brushes.Gray.SemiTransparent}"/>
                    <ContentPresenter x:Name="AppContent" Margin="{TemplateBinding Padding}"
                                      HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                      RecognizesAccessKey="True" SnapsToDevicePixels="True"/>
                </Grid>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="AppHover" Property="Opacity" Value="1"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="AppHover" Property="Opacity" Value="0"/>
                        <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                        <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="Template" Value="{StaticResource AppButtonTemplate}"/>
                <Setter Property="HorizontalContentAlignment" Value="Center"/>
                <Setter Property="VerticalContentAlignment" Value="Center"/>
                <Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="32"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
            <Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource DialogButton}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Highlight}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>
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
            <TextBlock x:Name="txtDeviceCount" TextWrapping="Wrap" FontSize="13" FontWeight="SemiBold"
                       Foreground="{DynamicResource MahApps.Brushes.IdealForeground}"/>
        </Border>
        <TextBlock x:Name="txtActionMessage" Grid.Row="1" TextWrapping="Wrap" FontSize="13" Margin="0,0,0,12"/>
        <TextBlock Grid.Row="2" TextWrapping="Wrap" FontSize="11" Margin="0,0,0,16"
                   Foreground="{DynamicResource MahApps.Brushes.Gray1}"
                   Text="Dry run reads the current state and lists the steps. It changes nothing. Run and Dry run both go to the action log."/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnActionRun"    Content="Run"     Style="{StaticResource DialogAccentButton}"/>
            <Button x:Name="btnActionDryRun" Content="Dry run" Style="{StaticResource DialogButton}"/>
            <Button x:Name="btnActionCancel" Content="Cancel"  Style="{StaticResource DialogButton}" IsCancel="True" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Controls:MetroWindow>
'@
    [xml]$dx = $dlgXaml
    $dlg = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $dlg.Owner = $window
    $dlg.Title = $Title
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

function Write-ActionResult {
    param([Parameter(Mandatory)]$Result)
    $lines = @(ConvertTo-DeviceInspectorActionText -Result $Result)
    foreach ($line in $lines) { Add-LogLine $line }
    try { $null = Write-DeviceInspectorActionLog -Path $script:ActionLogPath -Result $Result }
    catch { Add-LogLine ('The action log could not be written: {0}' -f $_.Exception.Message) }
}

# Asks, then runs one device action in the background. Function is the name of an action
# function of the module; it receives ComputerName, DryRun and the extra Parameters.
function Invoke-DeviceAction {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Function,
        [hashtable]$Parameters = @{},
        [scriptblock]$AfterRun
    )
    if (-not (Test-DeviceActionReady)) {
        Add-LogLine ('{0}: turn on Enable actions and inspect a device that answers first.' -f $Name)
        return
    }
    $device = [string]$script:Inspection.ComputerName
    $choice = Show-ActionConfirmDialog -Title $Name -Message $Message -Devices @($device)
    if ($choice -eq 'Cancel') { Add-LogLine ('{0}: cancelled.' -f $Name); return }
    $dry = ($choice -eq 'DryRun')
    if (-not $dry) {
        # A run that stops part way (window closed, connection lost) still leaves this line.
        $start = New-DeviceInspectorActionRecord -Action $Name -ComputerName $device -DryRun $false -Succeeded $false -Outcome 'STARTED' -Summary 'The run started.' -Steps @()
        try { $null = Write-DeviceInspectorActionLog -Path $script:ActionLogPath -Result $start }
        catch {
            Add-LogLine ('{0}: the action log cannot be written, so the run does not start. {1}' -f $Name, $_.Exception.Message)
            [void](Show-ThemedMessage -Owner $window -Title 'Action log' -Message ('The action log cannot be written, so the run does not start: {0}' -f $_.Exception.Message) -Icon Error)
            return
        }
    }
    $script:ActionAfterRun = $AfterRun
    $script:ActionPending = @{ Name = $Name; Device = $device; DryRun = $dry }
    $arguments = @{ Function = $Function; Parameters = (@{ ComputerName = $device; DryRun = $dry } + $Parameters) }
    $title = $(if ($dry) { 'Dry run: {0} on {1}' -f $Name, $device } else { '{0} on {1}' -f $Name, $device })
    try {
        Start-ActionWork -Title $title -Arguments $arguments
    }
    catch {
        Stop-BackgroundWork
        $script:IsBusy = $false
        $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
        Update-ControlState
        $failed = New-DeviceInspectorActionRecord -Action $Name -ComputerName $device -DryRun $dry -Succeeded $false -Summary ('The run did not start: {0}' -f $_.Exception.Message) -Steps @()
        Write-ActionResult -Result $failed
        [void](Show-ThemedMessage -Owner $window -Title 'Action' -Message ('The run did not start: {0}' -f $_.Exception.Message) -Icon Error)
    }
}

function Start-ActionWork {
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][hashtable]$Arguments)
    Start-BackgroundWork -Title $Title -Step 'Connecting to the device...' -Arguments $Arguments -Work {
        param($A, $State)
        try {
            $p = $A.Parameters
            $State.Result = & $A.Function @p
        }
        catch { $State.ErrorMsg = $_.Exception.Message }
        finally { $State.Done = $true }
    } -OnDone {
        param($State)
        if ($State.ErrorMsg) {
            $failed = New-DeviceInspectorActionRecord -Action $script:ActionPending.Name -ComputerName $script:ActionPending.Device -DryRun ([bool]$script:ActionPending.DryRun) -Succeeded $false -Summary ([string]$State.ErrorMsg) -Steps @()
            Write-ActionResult -Result $failed
            Add-LogLine ('Action failed: {0}' -f $State.ErrorMsg)
            Set-StatusText 'Action failed. See the log.'
            [void](Show-ThemedMessage -Owner $window -Title 'Action' -Message ([string]$State.ErrorMsg) -Icon Error)
            return
        }
        $r = $State.Result
        Write-ActionResult -Result $r
        Update-StatusBarSummary
        $icon = $(if ($r.Succeeded) { 'Info' } else { 'Error' })
        [void](Show-ThemedMessage -Owner $window -Title 'Action result' -Message ('{0} on {1}, {2}: {3}' -f $r.Action, $r.ComputerName, $r.Mode, $r.Summary) -Icon $icon)
        if ($r.Succeeded -and -not $r.DryRun -and $script:ActionAfterRun) { & $script:ActionAfterRun $r }
    }
}

$btnPolicyUpdate.Add_Click({
    Invoke-DeviceAction -Name 'Client policy update' -Function 'Invoke-DeviceInspectorPolicyUpdate' `
        -Message 'The Configuration Manager client on the device requests machine policy from its management point, then evaluates it (Machine Policy Retrieval and Evaluation Cycle).'
})

$btnFullInventory.Add_Click({
    Invoke-DeviceAction -Name 'Full hardware inventory' -Function 'Invoke-DeviceInspectorFullInventory' -AfterRun { param($r) Clear-InventoryCheck } `
        -Message 'The tool deletes the hardware inventory status record on the device (InventoryActionStatus, root\ccm\invagt), then starts a hardware inventory cycle. The client then sends a full report, and the site replaces all hardware inventory of the device.'
})

$btnRepairInventory.Add_Click({
    if (-not (Test-InventoryCorrupt)) { Add-LogLine 'Repair inventory: the inventory check does not say Corrupt.'; return }
    $check = $script:Inspection.InventoryCheck
    Invoke-DeviceAction -Name 'Corrupt-inventory repair' -Function 'Invoke-DeviceInspectorInventoryRepair' `
        -Message ('{0} The tool deletes the hardware inventory status record on the device and starts a hardware inventory. The client sends a full report, and the site replaces the hardware inventory of the device. Inspect again after the site processes the report.' -f $check.Message) `
        -AfterRun { param($r) Clear-InventoryCheck; Add-LogLine ('{0}: inspect {1} again after the site processes the full report.' -f $r.Action, $r.ComputerName) }
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

$gridUpdates.ContextMenu.Add_Opened({
    $all = Get-InstallableUpdateRow -Rows @($gridUpdates.ItemsSource)
    $selected = Get-InstallableUpdateRow -Rows @($gridUpdates.SelectedItems)
    $gate = $(if (-not $script:ActionsEnabled) { 'Turn on Enable actions first.' } elseif (-not (Test-DeviceActionReady)) { 'Inspect a device that answers first.' } else { '' })
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
    $parameters = @{}
    if (-not $All) { $parameters['UpdateId'] = [string[]]@($Rows | ForEach-Object { [string]$_.UpdateId }) }
    $name = $(if ($All) { 'Install all pending updates' } else { 'Install selected pending updates' })
    Invoke-DeviceAction -Name $name -Function 'Invoke-DeviceInspectorUpdateInstall' -Parameters $parameters `
        -Message ('The client on the device downloads and installs these {0} updates now (CCM_SoftwareUpdatesManager.InstallUpdates). The device can restart, as the deployment sets.{1}{1}{2}' -f $Rows.Count, [Environment]::NewLine, $list) `
        -AfterRun { param($r) Add-LogLine ('{0}: inspect {1} again to see the update states.' -f $r.Action, $r.ComputerName) }
}
$menuInstallSelected.Add_Click({ Invoke-UpdateInstall -Rows (Get-InstallableUpdateRow -Rows @($gridUpdates.SelectedItems)) -All $false })
$menuInstallAll.Add_Click({ Invoke-UpdateInstall -Rows (Get-InstallableUpdateRow -Rows @($gridUpdates.ItemsSource)) -All $true })

# === Log file ===
$btnOpenLog.Add_Click({
    if (-not (Test-Path -LiteralPath $script:ToolLogPath)) { Add-LogLine ('The log file does not exist yet: {0}' -f $script:ToolLogPath); return }
    try { Invoke-Item -LiteralPath $script:ToolLogPath -ErrorAction Stop; Add-LogLine ('Opened the log file: {0}' -f $script:ToolLogPath) }
    catch { Add-LogLine ('The log file cannot be opened: {0}' -f $_.Exception.Message) }
})

# === Window state (geometry logic: SuiteCommon) ===
$global:WindowStatePath = Join-Path $PSScriptRoot 'DeviceInspector.windowstate.json'

$window.Add_Closing({
    Save-WindowState -Window $window -Path $global:WindowStatePath -ExtraState @{ ActiveView = $script:ActiveView }
    Stop-BackgroundWork
    Close-SuiteBgRunspace -Runspace $script:BgRunspace
})

$window.Add_Loaded({
    Restore-WindowState -Window $window -Path $global:WindowStatePath -OnStateLoaded {
        param($s)
        if ($s.ActiveView -in @('Device', 'Applications', 'Updates', 'Collections', 'Problems')) { Set-ActiveView -View ([string]$s.ActiveView) }
    }
    $isDark = [bool]$global:Prefs['DarkMode']
    if (-not $isDark) { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Light.Blue') }
    Update-TitleBarBrushes
    $txtDevice.Text     = [string]$global:Prefs['LastDevice']
    $txtSiteServer.Text = [string]$global:Prefs['SMSProvider']
    $chkSiteOnly.IsChecked = [bool]$global:Prefs['SiteOnly']
    Update-ControlState
    Update-StatusBarSummary
    Add-LogLine 'Device Inspector ready. Enter a device name and a site server, then click Inspect. The tool only reads until you turn on Enable actions.'
    Add-LogLine ('Log file: {0}' -f $script:ToolLogPath)
})

# Suite update notice: one shared daily lookup across the suite tools; the launcher installs.
$null = Start-SuiteUpdateNotice -Path $PSScriptRoot -OnResult { param($u) if ($u.Available) { Add-LogLine ('Suite update available: v{0}. Update from the AppPackager Suite Launcher.' -f $u.Latest) } }
[void]$window.ShowDialog()
try { Stop-Transcript | Out-Null } catch { $null = $_ }
