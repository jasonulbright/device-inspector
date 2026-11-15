#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Window test for the chrome and the buttons of the main window and of every dialog and popup, in both themes.
# Dialogs of the start script are built from their XAML text (here-strings in the script), given the theme the way the
# script gives it (Set-DialogTheme), and shown. The popups of SuiteCommon (the themed message box and the collection
# picker) are opened through their own function, owned by the themed main window; a timer on the dispatcher measures
# each one while it is open and closes it, because both wait in ShowDialog. Rules:
#   - the dialog title bar brush (active and inactive) is the title bar brush of the main window
#   - the title bar text of the dialog is readable (4.5:1) on that brush
#   - every button has bold text (SemiBold or heavier, 600; a normal weight is a defect)
#   - no button has a border thicker than 1 px, and no button border has the text color of the theme

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The timer handler of the dispatcher hands the measured chrome to the STA script through global variables.')]
param()

BeforeDiscovery {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed -and -not $env:SUITE_WINDOW_GUARD_REPORTED) { Write-Host ('Window tests skipped: {0}.' -f $script:WindowGuard.Reason) }
    $script:ThemeCases = @(@{ Dark = $true; Theme = 'dark' }, @{ Dark = $false; Theme = 'light' })
}

BeforeAll {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed) { return }
    . "$PSScriptRoot\WindowConfig.ps1"
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ShellText = [System.IO.File]::ReadAllText((Join-Path $script:Root $script:AppConfig.Shell))
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root $script:AppConfig.Shell), [ref]$null, [ref]$null)
    $dialogXaml = @($ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '^\s*<Controls:MetroWindow'
            }, $true) | ForEach-Object { $_.Value })
    # The functions of the script that own a dialog, by name.
    $script:DialogFunctions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Extent.Text -match "<Controls:MetroWindow" }, $true) | ForEach-Object { $_.Name })
    # The SuiteCommon popups that the script opens, by the function that shows them.
    $script:PopupFunctions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Show-ThemedMessage', 'Show-CollectionPickerDialog' }, $true) |
            ForEach-Object { $_.GetCommandName() } | Sort-Object -Unique)
    $script:Measured = @{}
    foreach ($dark in $true, $false) {
        $key = if ($dark) { 'dark' } else { 'light' }
        $script:Measured[$key] = Invoke-WpfSta -Arguments @{ Dark = $dark; Config = $script:AppConfig; Dialogs = $dialogXaml; Popups = $script:PopupFunctions } -Script {
            $cfg = $Arguments.Config
            $main = Open-TestWindow -XamlPath (Join-Path $Root $cfg.Xaml) -Dark $Arguments.Dark
            Initialize-ShellTheme -Window $main -Dark $Arguments.Dark -Views $cfg.Views -OptionsButtonName $cfg.OptionsButton -LogLabelName $cfg.LogLabel -ActiveView $cfg.Views[0].Name
            $mainChrome = Get-SuiteWindowChrome -Window $main -Label 'main'
            $out = [pscustomobject]@{
                ThemeText = $mainChrome.ThemeText
                MainTitle = $mainChrome.Active; MainTitleInactive = $mainChrome.Inactive
                Main = @($mainChrome.Buttons); Dialogs = @()
            }
            $i = 0
            foreach ($xaml in $Arguments.Dialogs) {
                $i++
                [xml]$x = $xaml
                $d = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
                $d.WindowStartupLocation = 'Manual'
                $d.Left = $(if ($env:SUITE_VISIBLE_WINDOWS -eq '1') { 120 } else { -32000 }); $d.Top = $(if ($env:SUITE_VISIBLE_WINDOWS -eq '1') { 120 } else { -32000 })
                $d.ShowInTaskbar = $false
                Set-DialogTheme -Dialog $d -IsDark $Arguments.Dark
                $d.Show(); Wait-Layout $d
                $c = Get-SuiteWindowChrome -Window $d -Label ([string]$d.Title)
                $out.Dialogs += [pscustomobject]@{ Title = $c.Title; Index = $i; Active = $c.Active; Inactive = $c.Inactive; TitleRatio = $c.TitleRatio; Buttons = @($c.Buttons) }
                $d.Close()
            }
            # The SuiteCommon popups. The timer finds the popup among the windows the main window owns (MahApps
            # also owns the glow windows, which are not MetroWindow), reads its chrome after a few ticks, and closes it.
            foreach ($popup in $Arguments.Popups) {
                $global:HarnessOwner = $main
                $global:HarnessChrome = $null
                $global:HarnessTicks = 0
                $timer = New-Object System.Windows.Threading.DispatcherTimer
                $timer.Interval = [TimeSpan]::FromMilliseconds(100)
                $timer.Add_Tick({
                        $global:HarnessTicks++
                        $box = @($global:HarnessOwner.OwnedWindows) | Where-Object { $_.IsLoaded -and $_ -is [MahApps.Metro.Controls.MetroWindow] } | Select-Object -First 1
                        if ($box -and -not $global:HarnessChrome -and $global:HarnessTicks -ge 10) {
                            $c = Get-SuiteWindowChrome -Window $box -Label ([string]$box.Title)
                            $global:HarnessChrome = [pscustomobject]@{ Title = $c.Title; Active = $c.Active; Inactive = $c.Inactive; TitleRatio = $c.TitleRatio; Buttons = @($c.Buttons) }
                            $box.Close()
                        }
                        elseif ($global:HarnessTicks -ge 100) { foreach ($b in @($global:HarnessOwner.OwnedWindows | Where-Object { $_ -is [MahApps.Metro.Controls.MetroWindow] })) { $b.Close() } }
                    })
                $timer.Start()
                try {
                    if ($popup -eq 'Show-ThemedMessage') {
                        [void](Show-ThemedMessage -Owner $main -Title 'Device Inspector' -Message 'A site server needs a site code. Enter it in Options.' -Icon Warn -Buttons OKCancel)
                    }
                    else {
                        $rows = @([pscustomobject]@{ CollectionID = 'SMS00001'; Name = 'All Systems'; MemberCount = 1; CollectionType = 2 })
                        [void](Show-CollectionPickerDialog -Owner $main -Collections $rows -Folders @() -Title 'Add to Collection' -IncludeBuiltIn $false)
                    }
                }
                finally { $timer.Stop() }
                if ($global:HarnessChrome) {
                    $i++
                    $out.Dialogs += [pscustomobject]@{ Title = '{0} ({1})' -f $global:HarnessChrome.Title, $popup; Index = $i; Active = $global:HarnessChrome.Active; Inactive = $global:HarnessChrome.Inactive; TitleRatio = $global:HarnessChrome.TitleRatio; Buttons = @($global:HarnessChrome.Buttons) }
                }
            }
            $main.Close()
            $out
        }
    }
}

AfterAll {
    if ($script:WindowGuard.Allowed) { Close-WpfSession }
}

Describe 'Chrome <Theme>' -ForEach $script:ThemeCases -Skip:(-not $script:WindowGuard.Allowed) {
    BeforeAll { $script:M = $script:Measured[$Theme] }

    It 'finds every dialog and popup of the script' {
        # One measured window for each function of the script that holds a dialog XAML, and one for each SuiteCommon popup function it calls.
        $script:DialogFunctions.Count | Should -BeGreaterThan 0
        $xamlLoads = @([regex]::Matches($script:ShellText, '(?m)XamlReader\]::Load\(')).Count
        # The main window is the first load of the script. Every other load is a dialog.
        ($xamlLoads - 1) | Should -Be $script:DialogFunctions.Count
        @($script:M.Dialogs).Count | Should -Be ($script:DialogFunctions.Count + $script:PopupFunctions.Count)
    }

    It 'gives every dialog the title bar brush of the main window' {
        $bad = @($script:M.Dialogs | Where-Object { $_.Active -ne $script:M.MainTitle -or $_.Inactive -ne $script:M.MainTitleInactive } |
                ForEach-Object { '{0}: active {1} inactive {2}, main {3} {4}' -f $_.Title, $_.Active, $_.Inactive, $script:M.MainTitle, $script:M.MainTitleInactive })
        $bad | Should -BeNullOrEmpty
    }

    It 'keeps the title text of every dialog readable at 4.5:1' {
        $bad = @($script:M.Dialogs | Where-Object { $_.TitleRatio -lt 4.5 } | ForEach-Object { '{0}: {1}' -f $_.Title, $_.TitleRatio })
        $bad | Should -BeNullOrEmpty
    }

    It 'shows bold text on every button of the main window and of every dialog' {
        $all = @($script:M.Main) + @($script:M.Dialogs | ForEach-Object { $_.Buttons })
        $all.Count | Should -BeGreaterThan 5
        $bad = @($all | Where-Object { $_.Weight -lt 600 } | ForEach-Object { '{0} "{1}" weight {2}' -f $_.Window, $_.Text, $_.Weight })
        $bad | Should -BeNullOrEmpty
    }

    It 'gives no button a border thicker than 1 px or in the text color of the theme' {
        $all = @($script:M.Main) + @($script:M.Dialogs | ForEach-Object { $_.Buttons })
        $bad = @($all | Where-Object { $_.BorderThickness -gt 1 -or ($_.BorderThickness -gt 0 -and $_.BorderColor -eq $script:M.ThemeText) } |
                ForEach-Object { '{0} "{1}" border {2}px {3}' -f $_.Window, $_.Text, $_.BorderThickness, $_.BorderColor })
        $bad | Should -BeNullOrEmpty
    }
}
