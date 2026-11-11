#Requires -Modules Pester
# Window tests. The main window and the Options dialog (built from XAML text in the start script)
# are opened off screen on an STA thread, in both themes and at 1024x720 and 1440x900, and measured.
# The app-specific names live in WindowConfig.ps1. The tests that open a window run only with the
# opt-in SUITE_ALLOW_WINDOW_TESTS=1 (WindowHarness.ps1). The tests that read text only always run.

BeforeDiscovery {
    . "$PSScriptRoot\WindowHarness.ps1"
    . "$PSScriptRoot\WindowConfig.ps1"
    # No window opens unless this guard allows it (the opt-in must be set). The skipped tests report the reason.
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed) { Write-Host ('Window tests skipped: {0}' -f $script:WindowGuard.Reason) }
    $script:Matrix = foreach ($dark in $true, $false) {
        foreach ($size in @(@(1024, 720), @(1440, 900))) {
            @{ Dark = $dark; Theme = $(if ($dark) { 'dark' } else { 'light' }); W = $size[0]; H = $size[1]; Size = ('{0}x{1}' -f $size[0], $size[1]) }
        }
    }
    $script:ViewCases = @($script:AppConfig.Views | ForEach-Object { @{ View = $_.Name } })
    $script:PaneCases = @(foreach ($p in $script:AppConfig.DialogPanes) { foreach ($t in 'dark', 'light') { @{ Pane = $p; Theme = $t } } })
}

BeforeAll {
    . "$PSScriptRoot\WindowHarness.ps1"
    . "$PSScriptRoot\WindowConfig.ps1"
    . "$PSScriptRoot\ContrastRules.ps1"
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ShellPath = Join-Path $script:Root $script:AppConfig.Shell
    $script:XamlText = [System.IO.File]::ReadAllText((Join-Path $script:Root $script:AppConfig.Xaml))
    $script:ShellText = [System.IO.File]::ReadAllText($script:ShellPath)
    $script:ShellAst = [System.Management.Automation.Language.Parser]::ParseFile($script:ShellPath, [ref]$null, [ref]$null)
    $script:DialogXaml = @($script:ShellAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '^\s*<Controls:MetroWindow'
            }, $true) | ForEach-Object { $_.Value })

    $script:Measured = @{}
    $script:DialogMeasured = @{}
    $script:WindowGuard = Test-WindowTestsAllowed
    if ($script:WindowGuard.Allowed) {
        foreach ($case in @(
                @{ Dark = $true; W = 1024; H = 720 }, @{ Dark = $true; W = 1440; H = 900 },
                @{ Dark = $false; W = 1024; H = 720 }, @{ Dark = $false; W = 1440; H = 900 })) {
            $key = '{0}|{1}x{2}' -f $(if ($case.Dark) { 'dark' } else { 'light' }), $case.W, $case.H
            $case.Config = $script:AppConfig
            $case.Rows = $script:SampleRows
            $script:Measured[$key] = Invoke-WpfSta -Arguments $case -Script $script:MainMeasureScript
        }
        # The Options dialog: every pane, in both themes, at the declared size and at the minimum size.
        foreach ($dark in $true, $false) {
            $theme = if ($dark) { 'dark' } else { 'light' }
            $script:DialogMeasured[$theme] = Invoke-WpfSta -Arguments @{ Config = $script:AppConfig; Xaml = $script:DialogXaml[0]; Dark = $dark } -Script $script:DialogMeasureScript
        }
    }
}

AfterAll { Close-WpfSession }

Describe 'Main window XAML' -Skip:(-not $script:WindowGuard.Allowed) {
    It 'loads as a MetroWindow with the app title and a minimum size that fits 1024x720' {
        $r = Invoke-WpfSta -Arguments @{ Xaml = $script:AppConfig.Xaml } -Script {
            $w = Open-TestWindow -XamlPath (Join-Path $Root $Arguments.Xaml)
            $o = [PSCustomObject]@{ Type = $w.GetType().FullName; Title = $w.Title; MinW = $w.MinWidth; MinH = $w.MinHeight }
            $w.Close(); $o
        }
        $r.Type | Should -Be 'MahApps.Metro.Controls.MetroWindow'
        $r.Title | Should -Be $script:AppConfig.Title
        $r.MinW | Should -BeLessOrEqual 1024
        $r.MinH | Should -BeLessOrEqual 720
    }

    It 'shows the first view and keeps the others hidden' {
        $r = Invoke-WpfSta -Arguments @{ Config = $script:AppConfig } -Script {
            $w = Open-TestWindow -XamlPath (Join-Path $Root $Arguments.Config.Xaml)
            $o = foreach ($v in $Arguments.Config.Views) { [PSCustomObject]@{ Name = $v.Name; Vis = [string]$w.FindName($v.Container).Visibility } }
            $w.Close(); , @($o)
        }
        $first = $script:AppConfig.Views[0].Name
        ($r | Where-Object Name -eq $first).Vis | Should -Be 'Visible'
        @($r | Where-Object { $_.Name -ne $first -and $_.Vis -ne 'Collapsed' }) | Should -BeNullOrEmpty
    }
}

Describe 'Window XAML text' {
    It 'has the container and the sidebar button of view <View>' -ForEach @($script:AppConfig.Views | ForEach-Object { @{ View = $_.Name; Container = $_.Container; Button = $_.Button } }) {
        $script:XamlText | Should -Match ('x:Name="{0}"' -f $Container)
        $script:XamlText | Should -Match ('x:Name="{0}"' -f $Button)
    }

    It 'lists in the configuration every view that the script switches to' {
        $m = [regex]::Match($script:ShellText, "function Set-ActiveView[\s\S]*?ValidateSet\(([^)]*)\)")
        $m.Success | Should -BeTrue
        $views = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $configured = @($script:AppConfig.Views | ForEach-Object { $_.Name })
        @($views | Where-Object { $configured -notcontains $_ }) | Should -BeNullOrEmpty
        @($configured | Where-Object { $views -notcontains $_ }) | Should -BeNullOrEmpty
    }

    It 'passes the SuiteTheme palette overrides of the window to Initialize-SuiteTheme' {
        # The harness applies the same overrides (Get-SuiteBrushOverride), so the measured colours are the colours of the app.
        $script:ShellText | Should -Match "StartsWith\('SuiteTheme\.'\)"
        $call = $script:ShellAst.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Initialize-SuiteTheme' }, $true)
        $call | Should -Not -BeNullOrEmpty
        @($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Brushes' }).Count | Should -Be 1
    }
}

Describe 'Dialog text' {
    It 'finds the Options dialog XAML first, the action confirmation XAML second and the result window XAML third in the script' {
        $script:DialogXaml.Count | Should -Be 3
        $script:DialogXaml[0] | Should -Match 'x:Name="paneConnection"'
        $script:DialogXaml[1] | Should -Match 'x:Name="btnActionRun"'
        $script:DialogXaml[2] | Should -Match 'ShowActivated="False"'
        $script:DialogXaml[2] | Should -Match 'x:Name="txtMsg"'
    }

    It 'has every control that the dialog code looks up' {
        $lookups = @([regex]::Matches($script:ShellText, "\`$dlg\.FindName\('([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $lookups.Count | Should -BeGreaterThan 5
        foreach ($n in $lookups) { ($script:DialogXaml -join "`n") | Should -Match ('x:Name="{0}"' -f [regex]::Escape($n)) }
    }

    It 'gives every message box a title that differs from the title of its owner window' {
        # Owner window titles: the main window ($window) and the Options dialog ($dlg).
        $ownerTitle = @{
            '$window' = ([regex]::Match($script:XamlText, '\sTitle="([^"]*)"')).Groups[1].Value
            '$dlg'    = ([regex]::Match($script:DialogXaml[0], '\sTitle="([^"]*)"')).Groups[1].Value
        }
        $ownerTitle['$window'] | Should -Be 'Device Inspector'
        $ownerTitle['$dlg'] | Should -Not -BeNullOrEmpty
        $calls = @($script:ShellAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Show-ThemedMessage' }, $true))
        $calls.Count | Should -BeGreaterThan 3
        $bad = foreach ($c in $calls) {
            $e = $c.CommandElements
            $owner = $null; $title = $null
            for ($i = 1; $i -lt $e.Count - 1; $i++) {
                if ($e[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                if ($e[$i].ParameterName -eq 'Owner') { $owner = $e[$i + 1].Extent.Text }
                if ($e[$i].ParameterName -eq 'Title' -and $e[$i + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $title = $e[$i + 1].Value }
            }
            if (-not $ownerTitle.ContainsKey([string]$owner)) { 'line {0}: unknown owner {1}' -f $c.Extent.StartLineNumber, $owner; continue }
            if (-not $title) { 'line {0}: the title is not a fixed text' -f $c.Extent.StartLineNumber; continue }
            if ($title -eq $ownerTitle[$owner]) { 'line {0}: the title "{1}" equals the title of its owner {2}' -f $c.Extent.StartLineNumber, $title, $owner }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'Dialog windows' -Skip:(-not $script:WindowGuard.Allowed) {
    It 'parses the Options dialog as a MetroWindow with named controls' {
        $r = Invoke-WpfSta -Arguments @{ Xaml = $script:DialogXaml[0] } -Script {
            [xml]$x = $Arguments.Xaml
            $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
            # Names inside a ControlTemplate belong to the template, not to the window, so FindName does not see them.
            $names = @($x.SelectNodes('//*[@*[local-name()="Name"]]') | Where-Object { -not $_.SelectSingleNode('ancestor::*[local-name()="ControlTemplate"]') } |
                    ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') } | Where-Object { $_ })
            [PSCustomObject]@{ Type = $w.GetType().Name; Missing = @($names | Where-Object { -not $w.FindName($_) }); Count = @($names).Count }
        }
        $r.Type | Should -Be 'MetroWindow'
        $r.Missing | Should -BeNullOrEmpty
        $r.Count | Should -BeGreaterThan 0
    }

    It 'shows pane <Pane> of the Options dialog without clipped text or off-screen controls at its declared and minimum size in the <Theme> theme' -ForEach $script:PaneCases {
        $rows = @($script:DialogMeasured[$Theme] | Where-Object Pane -eq $Pane)
        $rows.Count | Should -Be 2
        foreach ($m in $rows) {
            $m.Clipped | ForEach-Object { '{0}: {1}: needs {2}px, has {3}px' -f $m.Size, $_.Text, $_.Needed, $_.Actual } | Should -BeNullOrEmpty
            $m.Overflow | ForEach-Object { '{0}: {1} needs {2}px high, has {3}px' -f $m.Size, $_.Name, $_.Needed, $_.Available } | Should -BeNullOrEmpty
            $m.Offscreen | ForEach-Object { '{0}: {1} at {2},{3} size {4}x{5}' -f $m.Size, $_.Name, $_.X, $_.Y, $_.W, $_.H } | Should -BeNullOrEmpty
        }
    }

    It 'meets the contrast standard on every text, control and title bar of the Options dialog in the <Theme> theme' -ForEach @(@{ Theme = 'dark' }, @{ Theme = 'light' }) {
        $first = @($script:DialogMeasured[$Theme])[0].Size
        $views = @($script:DialogMeasured[$Theme] | Where-Object Size -eq $first)
        $views.Count | Should -Be $script:AppConfig.DialogPanes.Count
        # An empty measurement has no violation. Each pane shows a heading, body text and the OK, Cancel and category buttons.
        foreach ($v in $views) {
            $v.Text.Count | Should -BeGreaterThan 2 -Because "pane $($v.Pane) shows text"
            $v.Interactive.Count | Should -BeGreaterThan 2 -Because "pane $($v.Pane) shows buttons"
        }
        Get-ContrastViolation -Views $views | Should -BeNullOrEmpty
    }
}

Describe 'Action confirmation' -Skip:(-not $script:WindowGuard.Allowed) {
    It 'shows the action confirmation without clipped text and meets the contrast standard in the <Theme> theme' -ForEach @(@{ Dark = $true; Theme = 'dark' }, @{ Dark = $false; Theme = 'light' }) {
        $m = Invoke-WpfSta -Arguments @{ Config = $script:AppConfig; Xaml = $script:DialogXaml[1]; Dark = $Dark } -Script $script:ActionDialogMeasureScript
        $m.Text.Count | Should -BeGreaterThan 2
        $m.Interactive.Count | Should -Be 3
        $m.Clipped | ForEach-Object { '{0}: needs {1}px, has {2}px' -f $_.Text, $_.Needed, $_.Actual } | Should -BeNullOrEmpty
        $m.Offscreen | ForEach-Object { '{0} at {1},{2}' -f $_.Name, $_.X, $_.Y } | Should -BeNullOrEmpty
        Get-ContrastViolation -Views @($m) | Should -BeNullOrEmpty
    }
}

Describe 'Message boxes' -Skip:(-not $script:WindowGuard.Allowed) {
    It 'opens a message box centered on its owner, the <Owner>' -ForEach @(@{ Owner = 'main window'; UseDialog = $false }, @{ Owner = 'Options dialog'; UseDialog = $true }) {
        $xaml = if ($UseDialog) { $script:DialogXaml[0] } else { '' }
        $r = Invoke-WpfSta -Arguments @{ Config = $script:AppConfig; Xaml = $xaml; Dark = $true } -Script $script:MessageBoxMeasureScript
        $r | Should -Not -BeNullOrEmpty -Because 'the message box must open'
        $r.BoxWidth | Should -BeGreaterThan 0
        $ownerX = $r.OwnerLeft + $r.OwnerWidth / 2; $ownerY = $r.OwnerTop + $r.OwnerHeight / 2
        $boxX = $r.BoxLeft + $r.BoxWidth / 2; $boxY = $r.BoxTop + $r.BoxHeight / 2
        [math]::Abs($boxX - $ownerX) | Should -BeLessOrEqual 2 -Because ('box center x {0}, owner center x {1}' -f $boxX, $ownerX)
        [math]::Abs($boxY - $ownerY) | Should -BeLessOrEqual 2 -Because ('box center y {0}, owner center y {1}' -f $boxY, $ownerY)
    }
}

Describe 'Layout <Theme> <Size>' -ForEach $script:Matrix -Skip:(-not $script:WindowGuard.Allowed) {
    It 'has no clipped text in the <View> view' -ForEach $script:ViewCases {
        $m = ($script:Measured['{0}|{1}' -f $Theme, $Size] | Where-Object View -eq $View)
        $m.Clipped | ForEach-Object { '{0}: needs {1}px, has {2}px' -f $_.Text, $_.Needed, $_.Actual } | Should -BeNullOrEmpty
    }

    It 'keeps every button, box and list inside the window in the <View> view' -ForEach $script:ViewCases {
        $m = ($script:Measured['{0}|{1}' -f $Theme, $Size] | Where-Object View -eq $View)
        $m.Offscreen | ForEach-Object { '{0} at {1},{2} size {3}x{4}' -f $_.Name, $_.X, $_.Y, $_.W, $_.H } | Should -BeNullOrEmpty
    }
}

Describe 'Contrast <Theme>' -ForEach @(@{ Theme = 'dark' }, @{ Theme = 'light' }) -Skip:(-not $script:WindowGuard.Allowed) {
    It 'meets the contrast standard on every text, control and title bar of the <View> view' -ForEach $script:ViewCases {
        $m = ($script:Measured['{0}|1440x900' -f $Theme] | Where-Object View -eq $View)
        $m.Text.Count | Should -BeGreaterThan 3
        $m.Interactive.Count | Should -BeGreaterThan 5
        Get-ContrastViolation -Views @($m) | Should -BeNullOrEmpty
    }
}
