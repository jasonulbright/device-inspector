#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Window test for the Inspect bar (Q-81). The main window is opened off screen at the minimum size (1024x640) and at 1440x900, in both
# themes. The Device box holds a device name and the SMS Provider box holds a full provider name, and the test proves that
#   - both boxes are wide enough to show their whole text (the defect: "CLIENT0" and "cm01.cor" were cut off at 1024),
#   - every control of the bar is inside the window (nothing is pushed out of the right edge),
#   - no two controls of one row overlap.
param ()

BeforeDiscovery {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed -and -not $env:SUITE_WINDOW_GUARD_REPORTED) { Write-Host ('Window tests skipped: {0}.' -f $script:WindowGuard.Reason) }
    $script:Cases = @(foreach ($dark in $true, $false) {
            foreach ($size in @(@(1024, 640), @(1440, 900))) {
                @{ Dark = $dark; Theme = $(if ($dark) { 'dark' } else { 'light' }); W = $size[0]; H = $size[1]; Size = ('{0}x{1}' -f $size[0], $size[1]) }
            }
        })
}

BeforeAll {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed) { return }
    . "$PSScriptRoot\WindowConfig.ps1"
    Add-Type -AssemblyName PresentationFramework

    $script:Measured = @{}
    foreach ($dark in $true, $false) {
        foreach ($size in @(@(1024, 640), @(1440, 900))) {
            $case = @{ Dark = $dark; W = $size[0]; H = $size[1]; Config = $script:AppConfig }
            $script:Measured[('{0}|{1}x{2}' -f $(if ($dark) { 'dark' } else { 'light' }), $size[0], $size[1])] = Invoke-WpfSta -Arguments $case -Script {
                $win = Open-TestWindow -XamlPath (Join-Path $Root $Arguments.Config.Xaml) -Dark $Arguments.Dark -Width $Arguments.W -Height $Arguments.H
                try {
                    $device = $win.FindName('txtDevice'); $server = $win.FindName('txtSiteServer')
                    $device.Text = 'CLIENT01'
                    $server.Text = 'cm01.contoso.com'
                    Wait-Layout $win
                    function Get-Fit([System.Windows.Controls.TextBox]$Box) {
                        $face = New-Object System.Windows.Media.Typeface($Box.FontFamily, $Box.FontStyle, $Box.FontWeight, $Box.FontStretch)
                        $formatted = New-Object System.Windows.Media.FormattedText($Box.Text, [cultureinfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, $face, $Box.FontSize, [System.Windows.Media.Brushes]::Black, 1.0)
                        $inner = $Box.ActualWidth - $Box.Padding.Left - $Box.Padding.Right - $Box.BorderThickness.Left - $Box.BorderThickness.Right
                        [pscustomobject]@{ Name = $Box.Name; Text = $Box.Text; BoxWidth = [math]::Round($Box.ActualWidth, 1); TextWidth = [math]::Round($formatted.WidthIncludingTrailingWhitespace, 1); Inner = [math]::Round($inner, 1) }
                    }
                    $names = 'btnInspect', 'txtDevice', 'txtSiteServer', 'chkSiteOnly', 'btnExportJson', 'btnExportHtml'
                    $boxes = @(foreach ($n in $names) {
                            $el = $win.FindName($n)
                            $p = $el.TransformToAncestor($win).Transform([System.Windows.Point]::new(0, 0))
                            [pscustomobject]@{ Name = $n; Left = [math]::Round($p.X, 1); Top = [math]::Round($p.Y, 1); Right = [math]::Round($p.X + $el.ActualWidth, 1); Bottom = [math]::Round($p.Y + $el.ActualHeight, 1); Visible = [bool]$el.IsVisible }
                        })
                    [pscustomobject]@{ Fits = @((Get-Fit $device), (Get-Fit $server)); Controls = $boxes; WindowWidth = [math]::Round($win.ActualWidth, 1) }
                }
                finally { $win.Close() }
            }
        }
    }
}

AfterAll { if ($script:WindowGuard.Allowed) { Close-WpfSession } }

Describe 'The Inspect bar (<Theme> <Size>)' -ForEach $script:Cases {
    BeforeAll { $script:M = $script:Measured[('{0}|{1}' -f $Theme, $Size)] }

    It 'shows the whole text of the Device and SMS Provider boxes' -Skip:(-not $script:WindowGuard.Allowed) {
        foreach ($f in $script:M.Fits) {
            $f.TextWidth | Should -BeLessOrEqual $f.Inner -Because ("the box {0} is {1} px wide and its text '{2}' needs {3} px of the {4} px inside the padding" -f $f.Name, $f.BoxWidth, $f.Text, $f.TextWidth, $f.Inner)
        }
    }

    It 'keeps every control of the bar inside the window' -Skip:(-not $script:WindowGuard.Allowed) {
        foreach ($c in $script:M.Controls) {
            $c.Visible | Should -BeTrue
            $c.Right | Should -BeLessOrEqual $script:M.WindowWidth -Because ('{0} ends at {1} px in a window of {2} px' -f $c.Name, $c.Right, $script:M.WindowWidth)
        }
    }

    It 'does not let two controls of one row overlap' -Skip:(-not $script:WindowGuard.Allowed) {
        $sorted = @($script:M.Controls | Sort-Object Top, Left)
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            for ($j = $i + 1; $j -lt $sorted.Count; $j++) {
                $a = $sorted[$i]; $b = $sorted[$j]
                $sameRow = ($a.Top -lt $b.Bottom) -and ($b.Top -lt $a.Bottom)
                if ($sameRow) { ($a.Right -le ($b.Left + 0.5) -or $b.Right -le ($a.Left + 0.5)) | Should -BeTrue -Because ('{0} ({1}-{2}) overlaps {3} ({4}-{5})' -f $a.Name, $a.Left, $a.Right, $b.Name, $b.Left, $b.Right) }
            }
        }
    }
}
