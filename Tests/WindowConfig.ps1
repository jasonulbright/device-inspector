# App-specific names for Window.Tests.ps1 and Show-ContrastViolations.ps1.
# The main window has five view containers. The shell shows one container at a time
# (Set-ActiveView). Each view lists the container, its sidebar button and the active
# view name the theme uses.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The STA runspace hands state to WPF event handlers and theme getters through global variables.')]
param()
$script:AppConfig = @{
    Title         = 'Device Inspector'
    Shell         = 'start-deviceinspector.ps1'
    Xaml          = 'MainWindow.xaml'
    OptionsButton = 'btnOptions'
    LogLabel      = 'lblLogOutput'
    Views         = @(
        @{ Name = 'Device';       Container = 'viewDevice';      Button = 'btnViewDevice' }
        @{ Name = 'Applications'; Container = 'viewApps';        Button = 'btnViewApps' }
        @{ Name = 'Updates';      Container = 'viewUpdates';     Button = 'btnViewUpdates' }
        @{ Name = 'Collections';  Container = 'viewCollections'; Button = 'btnViewCollections' }
        @{ Name = 'Problems';     Container = 'viewProblems';    Button = 'btnViewProblems' }
    )
    # The panes of the Options dialog, in the order of its category buttons.
    DialogPanes   = @('paneConnection', 'paneAbout')
}

# Rows of the shape that the panel functions of the module return, so the grids show real cell text.
$script:SampleRows = @{
    gridFacts       = @(
        [PSCustomObject]@{ Group = 'Operating system (device)'; Name = 'Caption'; Value = 'Windows 11 Enterprise' }
        [PSCustomObject]@{ Group = 'Client health (device)'; Name = 'Service CcmExec'; Value = 'Running (start mode Auto)' }
        [PSCustomObject]@{ Group = 'Site record'; Name = 'Resource ID'; Value = '16777221' }
    )
    gridApps        = @(
        [PSCustomObject]@{ Name = 'Sample application'; DeviceVersion = '2.0'; InventoryVersion = '1.0'; Publisher = 'Sample publisher'; Status = 'Version differs' }
        [PSCustomObject]@{ Name = 'Second application'; DeviceVersion = '3.1'; InventoryVersion = '3.1'; Publisher = 'Sample publisher'; Status = 'Match' }
    )
    gridUpdates     = @(
        [PSCustomObject]@{ Source = 'Site'; Article = 'KB5001'; Severity = 'Critical'; State = 'Required'; Deadline = ''; Title = 'Cumulative update' }
        [PSCustomObject]@{ Source = 'Device'; Article = 'KB5001'; Severity = ''; State = 'Available'; Deadline = '2026-11-09T00:00:00Z'; Title = 'Cumulative update' }
    )
    gridCollections = @([PSCustomObject]@{ CollectionId = 'SMS00001'; Name = 'All Systems' })
    gridDeployments = @([PSCustomObject]@{ Name = 'Sample deployment'; Type = 'Application'; Intent = 'Available'; Collection = 'All Systems'; Deadline = '' })
}

# Runs in the STA runspace. Opens the main window and measures every view in one theme and size.
# Arguments: Config, Dark, W, H, Rows.
$script:MainMeasureScript = {
    $cfg = $Arguments.Config
    $w = Open-TestWindow -XamlPath (Join-Path $Root $cfg.Xaml) -Dark $Arguments.Dark -Width $Arguments.W -Height $Arguments.H
    foreach ($grid in $Arguments.Rows.Keys) { $w.FindName($grid).ItemsSource = @($Arguments.Rows[$grid]) }
    # Entered text, so the contrast of the input text is measured too.
    $w.FindName('txtDevice').Text = 'device-a'
    $w.FindName('txtSiteServer').Text = 'site.example.test'
    $w.FindName('txtSummary').Text = 'Device device-a; client service Running; site record found; 2 applications; 2 update rows; 1 collections; 0 problems.'
    $w.FindName('txtProblems').Text = 'No problems. Every part of the inspection ran.'
    $w.FindName('txtLog').Text = '09:00:00  Device Inspector ready.'
    $w.FindName('txtVersion').Text = 'v2026.11.07.0004'
    # Contrast is read only at 1440x900. Clipped text and off-screen controls are read at both sizes.
    $full = $Arguments.W -ge 1440
    $out = @()
    foreach ($view in $cfg.Views) {
        foreach ($v in $cfg.Views) { $w.FindName($v.Container).Visibility = if ($v.Name -eq $view.Name) { 'Visible' } else { 'Collapsed' } }
        Initialize-ShellTheme -Window $w -Dark $Arguments.Dark -Views $cfg.Views `
            -OptionsButtonName $cfg.OptionsButton -LogLabelName $cfg.LogLabel -ActiveView $view.Name
        $out += [PSCustomObject]@{
            View        = $view.Name
            Text        = if ($full) { @(Get-TextContrast $w) } else { @() }
            Clipped     = @(Get-ClippedText $w)
            Offscreen   = @(Get-OffscreenControls $w)
            Interactive = if ($full) { @(Get-InteractiveContrast $w) } else { @() }
            TitleBar    = if ($full) { Get-TitleBarContrast $w } else { $null }
        }
    }
    $w.Close()
    , $out
}

# Runs in the STA runspace. Opens the Options dialog from its XAML text at its declared and minimum
# size and measures every pane. The main window is opened first, because the dialog takes the theme
# context of the shell (Set-DialogTheme). Arguments: Config, Xaml, Dark.
$script:DialogMeasureScript = {
    $cfg = $Arguments.Config
    $main = Open-TestWindow -XamlPath (Join-Path $Root $cfg.Xaml) -Dark $Arguments.Dark -Width 1024 -Height 720
    Initialize-ShellTheme -Window $main -Dark $Arguments.Dark -Views $cfg.Views -OptionsButtonName $cfg.OptionsButton -LogLabelName $cfg.LogLabel -ActiveView $cfg.Views[0].Name
    [xml]$x = $Arguments.Xaml
    $probe = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $sizes = @(, @($probe.Width, $probe.Height))
    if ($probe.MinWidth -gt 0 -and $probe.MinHeight -gt 0) { $sizes += , @($probe.MinWidth, $probe.MinHeight) }
    $probe = $null
    $panes = $cfg.DialogPanes
    $rows = foreach ($s in $sizes) {
        $w = Open-TestWindow -XamlText $Arguments.Xaml -Dark $Arguments.Dark -Width $s[0] -Height $s[1]
        # Entered text, so the contrast of the input text is measured too.
        $w.FindName('txtSiteCode').Text = 'ABC'
        $w.FindName('txtSmsProvider').Text = 'site.example.test'
        $w.FindName('txtAboutVersion').Text = 'Device Inspector v2026.11.07.0004'
        Set-DialogTheme -Dialog $w -IsDark $Arguments.Dark
        foreach ($pane in $panes) {
            foreach ($p in $panes) { $w.FindName($p).Visibility = if ($p -eq $pane) { 'Visible' } else { 'Collapsed' } }
            Wait-Layout $w
            [PSCustomObject]@{
                Pane = $pane; Size = ('{0}x{1}' -f $s[0], $s[1])
                Text = @(Get-TextContrast $w); Interactive = @(Get-InteractiveContrast $w)
                Clipped = @(Get-ClippedText $w); Offscreen = @(Get-OffscreenControls $w)
                Overflow = @(Get-VerticalOverflow $w $panes)
                TitleBar = Get-TitleBarContrast $w
            }
        }
        $w.Close()
    }
    $main.Close()
    , @($rows)
}

# Runs in the STA runspace. Opens the main window (and, for the Options case, the Options dialog
# owned by it), opens a SuiteCommon message box owned by that window, and reads the place and the
# title of both windows while the box is open. A timer on the dispatcher reads the box and closes it,
# because Show-ThemedMessage waits in ShowDialog. Arguments: Config, Xaml (dialog XAML or empty), Dark.
$script:MessageBoxMeasureScript = {
    $cfg = $Arguments.Config
    $main = Open-TestWindow -XamlPath (Join-Path $Root $cfg.Xaml) -Dark $Arguments.Dark -Width 1024 -Height 720
    Initialize-ShellTheme -Window $main -Dark $Arguments.Dark -Views $cfg.Views -OptionsButtonName $cfg.OptionsButton -LogLabelName $cfg.LogLabel -ActiveView $cfg.Views[0].Name
    # Put the owner on screen, where a person sees it, at its minimum size.
    $main.Left = 0; $main.Top = 0; $main.Width = $main.MinWidth; $main.Height = $main.MinHeight
    Wait-Layout $main
    $owner = $main
    $dialog = $null
    if ($Arguments.Xaml) {
        [xml]$x = $Arguments.Xaml
        $dialog = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
        $dialog.Owner = $main
        $dialog.ShowInTaskbar = $false
        Set-DialogTheme -Dialog $dialog -IsDark $Arguments.Dark
        $dialog.Show()
        Wait-Layout $dialog
        $owner = $dialog
    }
    $global:HarnessOwner = $owner
    $global:HarnessBox = $null
    $global:HarnessTicks = 0
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
            $global:HarnessTicks++
            # The owner also owns the glow windows of MahApps (one on each edge), so the box is found by its button.
            $box = @($global:HarnessOwner.OwnedWindows) | Where-Object { $_.IsLoaded -and $_ -is [MahApps.Metro.Controls.MetroWindow] -and $_.FindName('btnPrimary') } | Select-Object -First 1
            # Read the box some ticks after it loaded, so SizeToContent and the start location are applied.
            if ($box -and -not $global:HarnessBox -and $global:HarnessTicks -ge 10) {
                $o = $global:HarnessOwner
                $global:HarnessBox = [PSCustomObject]@{
                    OwnerTitle = $o.Title; BoxTitle = $box.Title
                    OwnerLeft = $o.Left; OwnerTop = $o.Top; OwnerWidth = $o.ActualWidth; OwnerHeight = $o.ActualHeight
                    BoxLeft = $box.Left; BoxTop = $box.Top; BoxWidth = $box.ActualWidth; BoxHeight = $box.ActualHeight
                }
                $box.Close()
            }
            elseif ($global:HarnessTicks -ge 100) { foreach ($b in @($global:HarnessOwner.OwnedWindows | Where-Object { $_ -is [MahApps.Metro.Controls.MetroWindow] })) { $b.Close() } }
        })
    $timer.Start()
    try { [void](Show-ThemedMessage -Owner $owner -Title 'Device Inspector' -Message 'A site server needs a site code. Enter it in Options.' -Icon Warn) }
    finally { $timer.Stop() }
    if ($dialog) { $dialog.Close() }
    $main.Close()
    $global:HarnessBox
}
