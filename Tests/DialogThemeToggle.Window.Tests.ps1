#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Window test for a theme toggle while a non-modal dialog is open (queue row Q-38, Q-08). The action result notice is not modal.
# The test opens an owner window and a dialog that the owner owns, toggles the theme the way the script does (the function
# Update-OwnedWindowTheme of start-deviceinspector.ps1), and reads the theme of the dialog. The modal dialogs of the app cannot be
# tested: the main window takes no input while one is open.

BeforeDiscovery {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed -and -not $env:SUITE_WINDOW_GUARD_REPORTED) { Write-Host ('Window tests skipped: {0}.' -f $script:WindowGuard.Reason) }
    $script:ThemeCases = @(@{ From = 'dark'; To = 'light'; ToDark = $false; Expect = 'Light' }, @{ From = 'light'; To = 'dark'; ToDark = $true; Expect = 'Dark' })
}

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed) { return }
    . "$PSScriptRoot\WindowConfig.ps1"
    $script:Design = Get-DesignSize
    Add-Type -AssemblyName PresentationFramework
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:AppRoot $script:AppConfig.Shell), [ref]$null, [ref]$null)
    $def = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Update-OwnedWindowTheme' }, $true)
    $script:FunctionText = if ($def) { $def.Extent.Text } else { '' }
}

AfterAll {
    if ($script:WindowGuard.Allowed) { Close-WpfSession }
}

Describe 'Theme toggle with an open non-modal dialog' -Skip:(-not $script:WindowGuard.Allowed) {
    It 'defines Update-OwnedWindowTheme in the start script and calls it from the toggle handler' {
        $script:FunctionText | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $script:AppRoot $script:AppConfig.Shell) -Raw) | Should -Match 'Update-OwnedWindowTheme -Window \$window -IsDark \$isDark'
    }

    It 'gives an open dialog the <To> theme when the theme toggles from <From>' -ForEach $script:ThemeCases {
        $case = @{ FromDark = ($From -eq 'dark'); ToDark = $ToDark; W = $script:Design.W; H = $script:Design.H; Config = $script:AppConfig; FunctionText = $script:FunctionText }
        $r = Invoke-WpfSta -Arguments $case -Script {
            $owner = $null; $dlg = $null
            try {
                $owner = Open-TestWindow -XamlPath (Join-Path $Root $Arguments.Config.Xaml) -Dark $Arguments.FromDark -Width $Arguments.W -Height $Arguments.H
                Initialize-ShellTheme -Window $owner -Dark $Arguments.FromDark -Views $Arguments.Config.Views -OptionsButtonName $Arguments.Config.OptionsButton -LogLabelName $Arguments.Config.LogLabel -ActiveView $Arguments.Config.Views[0].Name
                [xml]$x = '<Controls:MetroWindow xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro" Title="Action Result" Width="360" Height="160"><Grid><TextBlock Text="Done"/></Grid></Controls:MetroWindow>'
                $dlg = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
                $dlg.Owner = $owner
                $dlg.WindowStartupLocation = 'Manual'; $dlg.Left = 120; $dlg.Top = 120; $dlg.ShowInTaskbar = $false
                Set-DialogTheme -Dialog $dlg -IsDark $Arguments.FromDark
                $dlg.Show(); Wait-Layout $dlg
                $before = [ControlzEx.Theming.ThemeManager]::Current.DetectTheme($dlg).BaseColorScheme
                . ([scriptblock]::Create($Arguments.FunctionText))
                Update-OwnedWindowTheme -Window $owner -IsDark $Arguments.ToDark
                Wait-Layout $dlg
                [pscustomobject]@{ Before = $before; After = [ControlzEx.Theming.ThemeManager]::Current.DetectTheme($dlg).BaseColorScheme }
            }
            finally { if ($dlg) { $dlg.Close() }; if ($owner) { $owner.Close() } }
        }
        $r.Before | Should -Not -Be $Expect
        $r.After | Should -Be $Expect
    }
}
