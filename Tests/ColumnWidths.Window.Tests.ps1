#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Window test for the grid columns. The main window is opened off screen at 1440x900 and at the minimum size (1024x640), in
# both themes (a session with a screen smaller than 1440x900 opens the window at the size of its screen), and every grid of every view is filled with two sets of rows: short rows that look like real cell text, and
# one row whose every text is far too long. The test proves that
#   - a column that does not take the free width fits its widest cell text (a short value in a wide column is the defect),
#   - only the last column of a grid takes the free width (a column that does not take it never grows to fill the grid),
#   - no other column is wider than 700 px,
#   - a text that does not fit ends with an ellipsis (TextTrimming) and shows its full text as the tooltip,
#   - the grids do not scroll sideways with the short rows, also at the minimum size.
param ()

BeforeDiscovery {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed -and -not $env:SUITE_WINDOW_GUARD_REPORTED) { Write-Host ('Window tests skipped: {0}.' -f $script:WindowGuard.Reason) }
    $script:Cases = @(foreach ($dark in $true, $false) {
            foreach ($size in @(@(1440, 900), @(1024, 640))) {
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

    # The long row has the same properties as the short row, and every text of it is far too long for any column.
    $script:LongText = ('A very long cell text that no column can show. ' * 8).Trim()
    $script:ShortAndLong = @{}
    foreach ($grid in $script:SampleRows.Keys) {
        $short = @($script:SampleRows[$grid])
        $long = [pscustomobject]@{}
        foreach ($p in $short[0].PSObject.Properties) {
            $long | Add-Member -NotePropertyName $p.Name -NotePropertyValue $(if ($p.Value -is [string]) { $script:LongText } else { $p.Value })
        }
        $script:ShortAndLong[$grid] = @{ Short = $short; Long = $long }
    }

    $script:Measured = @{}
    $script:Cases = @(foreach ($dark in $true, $false) {
            foreach ($size in @(@(1440, 900), @(1024, 640))) {
                @{ Dark = $dark; Theme = $(if ($dark) { 'dark' } else { 'light' }); W = $size[0]; H = $size[1]; Size = ('{0}x{1}' -f $size[0], $size[1]) }
            }
        })
    foreach ($case in $script:Cases) {
        $case.Config = $script:AppConfig
        $case.Sets = $script:ShortAndLong
        $script:Measured[('{0}|{1}' -f $case.Theme, $case.Size)] = Invoke-WpfSta -Arguments $case -Script {
            $cfg = $Arguments.Config
            $win = Open-TestWindow -XamlPath (Join-Path $Root $cfg.Xaml) -Dark $Arguments.Dark -Width $Arguments.W -Height $Arguments.H
            try {
                function Get-TextWidth([System.Windows.Controls.TextBlock]$Block, [string]$Text) {
                    $face = New-Object System.Windows.Media.Typeface($Block.FontFamily, $Block.FontStyle, $Block.FontWeight, $Block.FontStretch)
                    $formatted = New-Object System.Windows.Media.FormattedText($Text, [cultureinfo]::CurrentCulture, [System.Windows.FlowDirection]::LeftToRight, $face, $Block.FontSize, [System.Windows.Media.Brushes]::Black, 1.0)
                    $formatted.WidthIncludingTrailingWhitespace
                }
                function Read-Grids([bool]$WithLong) {
                    foreach ($view in $cfg.Views) {
                        foreach ($v in $cfg.Views) { $win.FindName($v.Container).Visibility = if ($v.Name -eq $view.Name) { 'Visible' } else { 'Collapsed' } }
                        Wait-Layout $win
                        $container = $win.FindName($view.Container)
                        foreach ($grid in (Get-VisualDescendants $container | Where-Object { $_ -is [System.Windows.Controls.DataGrid] -and (Test-VisibleInTree $_) })) {
                            $headers = @{}
                            foreach ($h in (Get-VisualDescendants $grid | Where-Object { $_ -is [System.Windows.Controls.Primitives.DataGridColumnHeader] -and $_.Column })) { $headers[$h.Column.DisplayIndex] = $h }
                            $widest = @{}; $trim = @{}
                            foreach ($cell in (Get-VisualDescendants $grid | Where-Object { $_ -is [System.Windows.Controls.DataGridCell] })) {
                                $block = $cell.Content -as [System.Windows.Controls.TextBlock]
                                if (-not $block -or -not $block.Text) { continue }
                                $index = $cell.Column.DisplayIndex
                                $natural = Get-TextWidth $block $block.Text
                                if ($block.Text.Length -lt 100) { if ($natural -gt [double]$widest[$index]) { $widest[$index] = $natural } }
                                else { $trim[$index] = [pscustomobject]@{ Trimming = [string]$block.TextTrimming; Tooltip = [string]$block.ToolTip; Natural = $natural; Actual = $block.ActualWidth } }
                            }
                            $scroll = Get-VisualDescendants $grid | Where-Object { $_ -is [System.Windows.Controls.ScrollViewer] } | Select-Object -First 1
                            $count = $grid.Columns.Count
                            [pscustomobject]@{
                                View        = $view.Name
                                Grid        = $grid.Name
                                WithLong    = $WithLong
                                Width       = $grid.ActualWidth
                                ExtentWidth = $(if ($scroll) { $scroll.ExtentWidth } else { 0 })
                                Viewport    = $(if ($scroll) { $scroll.ViewportWidth } else { 0 })
                                Columns     = @(foreach ($col in $grid.Columns) {
                                        $i = $col.DisplayIndex
                                        $hdr = $headers[$i]
                                        [pscustomobject]@{
                                            Header     = [string]$col.Header
                                            Actual     = $col.ActualWidth
                                            IsAuto     = $col.Width.IsAuto
                                            IsStar     = $col.Width.IsStar
                                            MinWidth   = $col.MinWidth
                                            MaxWidth   = $(if ($col.MaxWidth -ge 10000) { -1 } else { $col.MaxWidth })
                                            IsLast     = ($i -eq $count - 1)
                                            HeaderText = $(if ($hdr) { Get-TextWidth (New-Object System.Windows.Controls.TextBlock -Property @{ FontSize = $hdr.FontSize; FontWeight = $hdr.FontWeight; FontFamily = $hdr.FontFamily }) ([string]$col.Header) } else { 0 })
                                            Widest     = [double]$widest[$i]
                                            Long       = $trim[$i]
                                        }
                                    })
                            }
                        }
                    }
                }
                foreach ($name in $Arguments.Sets.Keys) { $g = $win.FindName($name); if ($g) { $g.ItemsSource = @($Arguments.Sets[$name].Short) } }
                Wait-Layout $win
                $shortRows = @(Read-Grids $false)
                foreach ($name in $Arguments.Sets.Keys) { $g = $win.FindName($name); if ($g) { $g.ItemsSource = @($Arguments.Sets[$name].Short) + @($Arguments.Sets[$name].Long) } }
                Wait-Layout $win
                $longRows = @(Read-Grids $true)
                [pscustomobject]@{ Short = $shortRows; Long = $longRows }
            }
            finally { $win.Close() }
        }
    }
}

AfterAll {
    if ($script:WindowGuard.Allowed) { Close-WpfSession }
}

Describe 'Grid columns <Theme> <Size>' -ForEach $script:Cases -Skip:(-not $script:WindowGuard.Allowed) {
    BeforeAll {
        $script:Result = @($script:Measured['{0}|{1}' -f $Theme, $Size])[0]
    }

    It 'has a text grid in each of the views with rows' {
        @($script:Result.Short | Where-Object { $_.Columns.Count -gt 0 }).Count | Should -BeGreaterOrEqual 6
    }

    It 'fits a column that does not take the free width to its widest cell text' {
        $bad = @(foreach ($g in $script:Result.Short) {
                foreach ($c in $g.Columns | Where-Object { -not $_.IsStar -and $_.IsAuto }) {
                    $limit = [Math]::Max($c.MinWidth, [Math]::Max($c.Widest + 16, $c.HeaderText + 34)) + 24
                    if ($c.Actual -gt $limit) { '{0}/{1} "{2}": {3} px for a text of {4} px' -f $g.View, $g.Grid, $c.Header, [int]$c.Actual, [int]$c.Widest }
                }
            })
        $bad | Should -BeNullOrEmpty -Because ('columns wider than their content: ' + ($bad -join '; '))
    }

    It 'has at most one column that takes the free width, and it is the last column' {
        $bad = @(foreach ($g in $script:Result.Short) {
                $stars = @($g.Columns | Where-Object { $_.IsStar })
                if ($stars.Count -gt 1 -or ($stars.Count -eq 1 -and -not $stars[0].IsLast)) { '{0}/{1}: {2}' -f $g.View, $g.Grid, (($stars | ForEach-Object { '"{0}"' -f $_.Header }) -join ', ') }
            })
        $bad | Should -BeNullOrEmpty -Because ('grids with columns that share the free width: ' + ($bad -join '; '))
    }
    It 'makes no column wider than 700 px, also with a very long text' {
        $bad = @(foreach ($g in @($script:Result.Short) + @($script:Result.Long)) {
                foreach ($c in $g.Columns | Where-Object { -not $_.IsStar -and $_.Actual -gt 700 }) { '{0}/{1} "{2}": {3} px' -f $g.View, $g.Grid, $c.Header, [int]$c.Actual }
            })
        $bad | Should -BeNullOrEmpty -Because ('columns that are too wide: ' + ($bad -join '; '))
    }

    It 'ends a long text with an ellipsis and shows the full text as its tooltip' {
        $bad = @(foreach ($g in $script:Result.Long) {
                foreach ($c in $g.Columns | Where-Object { $_.Long }) {
                    if ($c.Long.Trimming -ne 'CharacterEllipsis') { '{0}/{1} "{2}": trimming is {3}' -f $g.View, $g.Grid, $c.Header, $c.Long.Trimming }
                    elseif ($c.Long.Tooltip -notlike 'A very long cell text*') { '{0}/{1} "{2}": no tooltip with the full text' -f $g.View, $g.Grid, $c.Header }
                    elseif ($c.Long.Actual -ge $c.Long.Natural) { '{0}/{1} "{2}": the text is not shortened' -f $g.View, $g.Grid, $c.Header }
                }
            })
        $bad | Should -BeNullOrEmpty -Because ('text that is not trimmed: ' + ($bad -join '; '))
    }

    It 'does not scroll a grid sideways with the short rows' {
        $bad = @(foreach ($g in $script:Result.Short | Where-Object { $_.Viewport -gt 0 -and $_.ExtentWidth -gt ($_.Viewport + 1) }) { '{0}/{1}: content {2} px in {3} px' -f $g.View, $g.Grid, [int]$g.ExtentWidth, [int]$g.Viewport })
        $bad | Should -BeNullOrEmpty -Because ('grids that scroll sideways: ' + ($bad -join '; '))
    }
}
