<#
.SYNOPSIS
    Main window of Device Inspector, a read-only tool that shows the facts of one device from a Configuration Manager site and from the device itself.

.DESCRIPTION
    Sidebar navigation across five panels (Device, Applications, Updates,
    Collections, Problems). The action bar holds the device name, the site
    server, the Inspect button and the JSON and HTML exports.

    The tool is read only. It reads the site with SELECT queries and reads the
    device with one remote script block. It uses the permissions of the
    signed-in user and stores no password. The only files it writes are the
    log files and the exports that the person names.

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
    Version    : 2026.11.07.0004
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
$gridFacts       = $window.FindName('gridFacts')
$txtAppFilter    = $window.FindName('txtAppFilter')
$cboAppStatus    = $window.FindName('cboAppStatus')
$gridApps        = $window.FindName('gridApps')
$gridUpdates     = $window.FindName('gridUpdates')
$gridCollections = $window.FindName('gridCollections')
$gridDeployments = $window.FindName('gridDeployments')
$txtProblems     = $window.FindName('txtProblems')

$progressOverlay  = $window.FindName('progressOverlay')
$txtProgressTitle = $window.FindName('txtProgressTitle')
$txtProgressStep  = $window.FindName('txtProgressStep')

$lblLogOutput = $window.FindName('lblLogOutput')
$txtLog       = $window.FindName('txtLog')
$txtStatus    = $window.FindName('txtStatus')

$null = $txtAppTitle, $toggleActions

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

# === Owned windows open centered on their owner ===
# The SuiteCommon message box (Show-ThemedMessage: CenterOwner with SizeToContent) opens with its
# center on the left edge of its owner. A class handler centers every owned window that asks for
# CenterOwner when it loads. The shared fix belongs in SuiteCommon (app-packager-suite).
function Register-OwnerCentering {
    if ($global:__ownerCenteringRegistered) { return }
    $global:__ownerCenteringRegistered = $true
    [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Window], [System.Windows.FrameworkElement]::LoadedEvent, [System.Windows.RoutedEventHandler]{
            param($s, $e)
            if (-not $s.Owner -or $s.WindowStartupLocation -ne [System.Windows.WindowStartupLocation]::CenterOwner) { return }
            # Center after the first layout and after the placement of WPF, which runs after Loaded.
            $w = $s
            [void]$s.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ContextIdle, [action]({
                    $owner = $w.Owner
                    if (-not $owner) { return }
                    # The owner position in device-independent units, also when the owner is maximized.
                    $left = $owner.Left; $top = $owner.Top
                    $source = [System.Windows.PresentationSource]::FromVisual($owner)
                    if ($source -and $source.CompositionTarget) {
                        $corner = $source.CompositionTarget.TransformFromDevice.Transform($owner.PointToScreen([System.Windows.Point]::new(0, 0)))
                        $left = $corner.X; $top = $corner.Y
                    }
                    $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
                    $w.Left = $left + ($owner.ActualWidth - $w.ActualWidth) / 2
                    $w.Top = $top + ($owner.ActualHeight - $w.ActualHeight) / 2
                    $global:__ownerCenteringCount = 1 + [int]$global:__ownerCenteringCount
                }.GetNewClosure()))
        })
}
Register-OwnerCentering

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

function Update-ControlState {
    $idle = -not $script:IsBusy
    $has = [bool]$script:Inspection
    $btnInspect.IsEnabled    = $idle
    $txtDevice.IsEnabled     = $idle
    $txtSiteServer.IsEnabled = $idle
    $chkSiteOnly.IsEnabled   = $idle
    $btnExportJson.IsEnabled = $has
    $btnExportHtml.IsEnabled = $has
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
    $parts += 'read only'
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

    Initialize-BgRunspace
    Stop-BackgroundWork
    $script:BgState = [hashtable]::Synchronized(@{ Step = 'Connecting...'; Done = $false; Result = $null; ErrorMsg = $null })
    $script:IsBusy = $true
    Update-ControlState
    $txtProgressTitle.Text = ('Inspecting {0}' -f $check.ComputerName)
    $txtProgressStep.Text  = 'Connecting...'
    $progressOverlay.Visibility = [System.Windows.Visibility]::Visible
    Set-StatusText 'Inspecting...'

    $arguments = @{ Device = $check.ComputerName; Server = $check.SiteServer; Code = [string]$global:Prefs.SiteCode; SiteOnly = $siteOnly }
    $script:BgPowerShell = [powershell]::Create()
    $script:BgPowerShell.Runspace = $script:BgRunspace
    [void]$script:BgPowerShell.AddScript({
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
    }).AddArgument($arguments).AddArgument($script:BgState)

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
            if ($script:BgState.ErrorMsg) {
                Add-LogLine ('Inspect failed: {0}' -f $script:BgState.ErrorMsg)
                Set-StatusText 'Inspect failed. See the log.'
                [void](Show-ThemedMessage -Owner $window -Title 'Inspect' -Message ([string]$script:BgState.ErrorMsg) -Icon Error)
                return
            }
            $r = $script:BgState.Result
            Show-Inspection -Inspection $r
            Add-LogLine ('Inspection of {0} finished: {1} problems.' -f $r.ComputerName, @($r.Problems).Count)
            foreach ($p in @($r.Problems)) { Add-LogLine ('  problem: {0}' -f $p) }
        }
    })
    $script:BgTimer.Start()
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
                         Controls:TextBoxHelper.Watermark="e.g. cm01.contoso.com"/>
                <TextBlock Text="Site Code" FontSize="11" Margin="0,12,0,2" Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
                <TextBox x:Name="txtSiteCode" FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="e.g. MCM. Required with a site server." Width="240" HorizontalAlignment="Left"/>
                <TextBlock Text="The tool connects with the Windows account that runs it and stores no password. The tool needs the Configuration Manager console on this computer. The account needs local administrator rights on the device (WinRM). For the site, a domain admin account that is a local administrator of the SMS Provider computer needs no Configuration Manager role. An account with fewer rights on the site is not tested. The tool only reads."
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
    Add-LogLine 'Device Inspector ready. Enter a device name and a site server, then click Inspect. The tool only reads.'
})

# Suite update notice: one shared daily lookup across the suite tools; the launcher installs.
$null = Start-SuiteUpdateNotice -Path $PSScriptRoot -OnResult { param($u) if ($u.Available) { Add-LogLine ('Suite update available: v{0}. Update from the AppPackager Suite Launcher.' -f $u.Latest) } }
[void]$window.ShowDialog()
try { Stop-Transcript | Out-Null } catch { $null = $_ }
