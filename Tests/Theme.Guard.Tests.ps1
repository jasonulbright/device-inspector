#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Guard tests for the theme rules. They parse the files (XML, syntax tree, regular expressions) and create no window, so they
# run on Windows PowerShell 5.1 and PowerShell 7. One test creates a single Button in a background STA runspace, to prove the
# behavior of Set-ThemeForeground on a real control. No test shows a window.
#   (a) Every blue background in XAML and PowerShell has a white foreground, also in hover, pressed and selected states.
#   (b) No font size, weight, style or text decoration depends on the theme. The titles of a connection box (site code,
#       provider, site server) are bold and 14 pt or larger. Their values are not.
#   (c) No banned word is in a tooltip, a UI string, the README or the user guide.
#   (d) Every button takes the shared themed style. Titles are in Title Case, in the window and in the guide.
#   (e) No window text shows the text of an exception.

BeforeDiscovery {
    . "$PSScriptRoot\ThemeGuardHelpers.ps1"
    $script:arrPsFileD = @(
        'start-deviceinspector.ps1', 'Invoke-DeviceInspector.ps1', 'Module\DeviceInspectorCommon.psm1', 'Module\DeviceInspectorActions.ps1', 'Lib\SuiteCommon\SuiteCommon.psm1'
    ) | ForEach-Object { @{ Name = $_; Path = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath $_) } }
    $script:arrAppPsFileD = @($script:arrPsFileD | Where-Object { $_.Name -notmatch 'SuiteCommon' })
    $script:arrXamlDocD = @(Get-XamlDocument)
    $script:arrOwnXamlDocD = @($script:arrXamlDocD | Where-Object { $_.Source -notmatch 'SuiteCommon' })
    $script:arrDialogDocD = @($script:arrOwnXamlDocD | Where-Object { $_.Kind -eq 'Dialog' })
    $script:arrChromeDocD = @($script:arrOwnXamlDocD | Where-Object { $_.Kind -eq 'Main' -or $_.Kind -eq 'Dialog' })
}

BeforeAll {
    . "$PSScriptRoot\ThemeGuardHelpers.ps1"
    $script:arrXamlDoc = @(Get-XamlDocument)
    $script:arrOwnXamlDoc = @($script:arrXamlDoc | Where-Object { $_.Source -notmatch 'SuiteCommon' })
    $script:arrDialogDoc = @($script:arrOwnXamlDoc | Where-Object { $_.Kind -eq 'Dialog' })
    $script:arrChromeDoc = @($script:arrOwnXamlDoc | Where-Object { $_.Kind -eq 'Main' -or $_.Kind -eq 'Dialog' })
    $script:objMainDoc = @($script:arrOwnXamlDoc | Where-Object { $_.Kind -eq 'Main' }) | Select-Object -First 1
    $script:strShellPath = Join-Path -Path $script:strRepoRoot -ChildPath 'start-deviceinspector.ps1'
    $script:strCommonPath = Join-Path -Path $script:strRepoRoot -ChildPath 'Module\DeviceInspectorCommon.psm1'
    $script:strActionsPath = Join-Path -Path $script:strRepoRoot -ChildPath 'Module\DeviceInspectorActions.ps1'
    $script:strSuiteFile = Join-Path -Path $script:strRepoRoot -ChildPath 'Lib\SuiteCommon\SuiteCommon.psm1'
    # The root attributes of a sample document in the self-tests.
    $script:strXamlHead = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"'
}

Describe 'Repository layout and test files' {
    It 'lists the XAML files by path relative to the repository and skips .claude and .git' {
        $arrFile = @(Get-RepoFile -Filter '*.xaml')
        $arrRelative = @($arrFile | ForEach-Object { $_.Relative })
        $arrRelative | Should -Contain 'MainWindow.xaml'
        @($arrRelative | Where-Object { $_ -like '.claude*' -or $_ -like '.git*' }) | Should -BeNullOrEmpty
    }

    It 'skips a top-level folder by name and keeps a worktree path out of the filter' {
        $strTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('themeguard-' + [guid]::NewGuid().ToString('N'))
        try {
            foreach ($strRelative in '.claude\worktrees\x\skipped.xaml', '.git\skipped2.xaml', 'Reports\skipped3.xaml', 'Sub\kept.xaml', 'top.xaml') {
                $strFile = Join-Path -Path $strTemp -ChildPath $strRelative
                New-Item -ItemType Directory -Path (Split-Path -Path $strFile -Parent) -Force | Out-Null
                [System.IO.File]::WriteAllText($strFile, '<Grid/>')
            }
            $arrRelative = @(Get-RepoFile -Filter '*.xaml' -Root $strTemp | ForEach-Object { $_.Relative } | Sort-Object)
            ($arrRelative -join ',') | Should -Be 'Sub\kept.xaml,top.xaml'
        }
        finally {
            Remove-Item -LiteralPath $strTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'finds the main window, the four dialogs and the here-strings of SuiteCommon' {
        $arrOwn = @($script:arrXamlDoc | Where-Object { $_.Source -notmatch 'SuiteCommon' })
        $arrOwn.Count | Should -Be 5
        $arrOwn | ForEach-Object { $_.Source } | Should -Contain 'MainWindow.xaml'
        @($arrOwn | Where-Object { $_.Source -like 'start-deviceinspector.ps1 here-string*' }).Count | Should -Be 4
        @($arrOwn | Where-Object { $_.Kind -eq 'Main' }).Count | Should -Be 1
        @($arrOwn | Where-Object { $_.Kind -eq 'Dialog' }).Count | Should -Be 4
        @($script:arrXamlDoc | Where-Object { $_.Source -match 'SuiteCommon' -and $_.Kind -eq 'Suite' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'starts every test file with the Pester 5.1 #Requires line' {
        $arrFile = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:strRepoRoot -ChildPath 'Tests') -Filter '*.Tests.ps1' -File)
        $arrFile.Count | Should -BeGreaterOrEqual 8
        $arrBad = foreach ($objFile in $arrFile) {
            $strFirst = @(Get-Content -LiteralPath $objFile.FullName | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)[0]
            if (([string]$strFirst).Trim() -ne $script:strRequiresLine) { '{0}: the first line is {1}' -f $objFile.Name, $strFirst }
        }
        @($arrBad) | Should -BeNullOrEmpty
    }
}

Describe 'Blue backgrounds have white text (a)' {
    It 'finds XAML to check' {
        $script:arrXamlDoc.Count | Should -BeGreaterThan 5
        @($script:arrXamlDoc | Where-Object { $_.Source -eq 'MainWindow.xaml' }).Count | Should -Be 1
        @($script:arrXamlDoc | Where-Object { $_.Source -like 'start-deviceinspector.ps1 here-string*' }).Count | Should -Be 4
    }

    It 'sets a white foreground on every blue background in <_.Source>' -ForEach $script:arrXamlDocD {
        $arrBad = @(Get-BlueWithoutWhite -Text $_.Text -Source $_.Source)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'recognizes blue and white brushes' {
        Test-BlueBrush '{DynamicResource MahApps.Brushes.Accent}' | Should -BeTrue
        Test-BlueBrush '{DynamicResource MahApps.Colors.Accent}' | Should -BeTrue
        Test-BlueBrush '{DynamicResource MahApps.Colors.AccentBase}' | Should -BeTrue
        Test-BlueBrush '{DynamicResource MahApps.Brushes.Accent3}' | Should -BeTrue
        Test-BlueBrush '{DynamicResource MahApps.Brushes.Highlight}' | Should -BeTrue
        Test-BlueBrush '{DynamicResource Highlight}' | Should -BeTrue
        Test-BlueBrush '{DynamicResource {x:Static SystemColors.HighlightBrushKey}}' | Should -BeTrue
        Test-BlueBrush '{x:Static SystemColors.HighlightBrush}' | Should -BeTrue
        Test-BlueBrush '{x:Static SystemColors.HighlightColor}' | Should -BeTrue
        Test-BlueBrush 'DodgerBlue' | Should -BeTrue
        Test-BlueBrush '#0078D4' | Should -BeTrue
        Test-BlueBrush '#FF0078D4' | Should -BeTrue
        Test-BlueBrush '#07D' | Should -BeTrue
        Test-BlueBrush '#1E1E1E' | Should -BeFalse
        Test-BlueBrush '#3A3A3A' | Should -BeFalse
        Test-BlueBrush '{DynamicResource MahApps.Brushes.ThemeBackground}' | Should -BeFalse
        Test-BlueBrush '{DynamicResource {x:Static SystemColors.HighlightTextBrushKey}}' | Should -BeFalse
        Test-WhiteBrush '{DynamicResource MahApps.Brushes.IdealForeground}' | Should -BeTrue
        Test-WhiteBrush 'White' | Should -BeTrue
        Test-WhiteBrush 'Black' | Should -BeFalse
    }

    It 'flags a blue background that has no white foreground, with every property form' {
        $strOpen = '<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro" TargetType="Button">'
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Setter Property="Background" Value="#0078D4"/></Style>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Setter Property="Background" Value="#0078D4"/><Setter Property="Foreground" Value="White"/></Style>') -Source 's').Count | Should -Be 0
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Setter Property="Border.Background" Value="{DynamicResource MahApps.Brushes.Accent}"/></Style>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Highlight}"/></Style>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Setter Property="Background" Value="{DynamicResource {x:Static SystemColors.HighlightBrushKey}}"/></Style>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Setter Property="Controls:ControlsHelper.MouseOverBackground" Value="{DynamicResource MahApps.Brushes.Accent}"/></Style>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Setter Property="Background"><Setter.Value><SolidColorBrush Color="{DynamicResource MahApps.Colors.Accent}"/></Setter.Value></Setter></Style>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Setter Property="Background"><Setter.Value><LinearGradientBrush><GradientStop Color="#0078D4"/></LinearGradientBrush></Setter.Value></Setter></Style>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Accent}"/></Trigger></Style.Triggers></Style>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strOpen + '<Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Accent}"/><Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/></Trigger></Style.Triggers></Style>') -Source 's').Count | Should -Be 0
        $strGrid = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">'
        @(Get-BlueWithoutWhite -Text ($strGrid + '<Border Background="#0078D4"><TextBlock Text="x"/></Border></Grid>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strGrid + '<Border Background="#0078D4"><TextBlock Text="x" Foreground="White"/></Border></Grid>') -Source 's').Count | Should -Be 0
        @(Get-BlueWithoutWhite -Text ($strGrid + '<Button Background="{DynamicResource MahApps.Brushes.Accent}" Content="x"/></Grid>') -Source 's').Count | Should -Be 1
        @(Get-BlueWithoutWhite -Text ($strGrid + '<Border><Border.Background><SolidColorBrush Color="#0078D4"/></Border.Background></Border></Grid>') -Source 's').Count | Should -Be 1
    }

    It 'sets no blue color as a Background in <Name>, and each CSS rule with a blue background has white text' -ForEach $script:arrAppPsFileD {
        $arrBad = @(foreach ($strHit in @(Get-ScriptBlueBackground -Path $Path)) { 'background ' + $strHit })
        $arrBad += @(foreach ($strString in @(Get-ScriptString -Path $Path)) {
                foreach ($objMatch in [regex]::Matches($strString, '\{([^}]*)\}')) {
                    $strRule = $objMatch.Groups[1].Value
                    $objBackground = [regex]::Match($strRule, '(?i)(?<![-\w])background(?:-color)?\s*:\s*(#[0-9A-F]{6,8})\b')
                    if ($objBackground.Success -and (Test-BlueBrush $objBackground.Groups[1].Value) -and $strRule -notmatch '(?i)(?<![-\w])color\s*:\s*(#fff(fff)?|white)\b') { 'css ' + $strRule }
                }
            })
        $arrBad | Should -BeNullOrEmpty
    }

    It 'finds a blue Background assignment in a script' {
        $strTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('themeguard-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            [System.IO.File]::WriteAllText($strTemp, "`$b.Background = '#0078D4'`n`$c.Foreground = '#0078D4'`n`$d.Background = '#1E1E1E'`n")
            @(Get-ScriptBlueBackground -Path $strTemp).Count | Should -Be 1
            [System.IO.File]::WriteAllText($strTemp, "`$b.Background = '#0078D4'`n`$b.Foreground = 'White'`n")
            @(Get-ScriptBlueBackground -Path $strTemp).Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $strTemp -Force -ErrorAction SilentlyContinue }
    }

    It 'sets a white foreground on every accent button style outside SuiteCommon in <_.Source>' -ForEach $script:arrOwnXamlDocD {
        $arrBad = @(Get-AccentButtonWithoutWhite -Text $_.Text -Source $_.Source)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'flags an accent button style that has no white foreground' {
        $strXaml = '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Style x:Key="A" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square.Accent}"><Setter Property="Height" Value="32"/></Style></ResourceDictionary>'
        @(Get-AccentButtonWithoutWhite -Text $strXaml -Source 'sample').Count | Should -Be 1
        $strOk = $strXaml.Replace('<Setter Property="Height" Value="32"/>', '<Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>')
        @(Get-AccentButtonWithoutWhite -Text $strOk -Source 'sample').Count | Should -Be 0
    }

    It 'sets the foreground of every selected-state trigger that sets a Background in <_.Source>' -ForEach $script:arrXamlDocD {
        [xml]$xml = $_.Text
        $arrBad = foreach ($objTrigger in @($xml.SelectNodes("//*[local-name()='Trigger'][@Property='IsSelected' or @Property='IsHighlighted' or @Property='IsMouseOver' or @Property='IsPressed']"))) {
            $objBackground = Get-SetterChild -Node $objTrigger -LeafPattern 'Background$' | Select-Object -First 1
            $objForeground = Get-SetterChild -Node $objTrigger -LeafPattern 'Foreground$' | Select-Object -First 1
            if ($objBackground -and -not $objForeground -and -not (Test-WhiteForegroundInScope $objBackground)) { '{0} trigger sets a Background and no Foreground' -f $objTrigger.GetAttribute('Property') }
        }
        @($arrBad) | Should -BeNullOrEmpty
    }

    It 'gives every list, combo box, tree and grid a selected state with white text on blue in <_.Source>' -ForEach $script:arrOwnXamlDocD {
        $arrBad = @(Get-SelectedStateViolation -Text $_.Text -Source $_.Source -Context $_.Context)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'finds the item controls of the main window, so that a rename cannot empty the scan' {
        [xml]$xml = $script:objMainDoc.Text
        @($xml.SelectNodes("//*[local-name()='ComboBox']")).Count | Should -BeGreaterOrEqual 1
        @($xml.SelectNodes("//*[local-name()='DataGrid']")).Count | Should -BeGreaterOrEqual 7
        @(Get-KeyedNodeTable -Text $script:objMainDoc.Text -Name 'Style' -Target 'ComboBoxItem').Count | Should -BeGreaterOrEqual 1
        @(Get-KeyedNodeTable -Text $script:objMainDoc.Text -Name 'Style' -Target 'DataGridCell').Count | Should -BeGreaterOrEqual 1
        @(Get-KeyedNodeTable -Text $script:objMainDoc.Text -Name 'Style' -Target 'DataGridRow').Count | Should -BeGreaterOrEqual 1
    }

    It 'flags a combo box without the IsHighlighted state and a list without an item container style' {
        $strOpen = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">'
        $strSelected = '<Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Accent}"/><Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/></Trigger>'
        $strHighlighted = '<Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Accent}"/><Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/></Trigger>'
        $strRow = '<Style x:Key="R" TargetType="DataGridRow"><Style.Triggers>' + $strSelected + '</Style.Triggers></Style><Style x:Key="G" TargetType="DataGrid"><Setter Property="RowStyle" Value="{StaticResource R}"/></Style>'
        $strCell = '<Style x:Key="C" TargetType="DataGridCell"><Style.Triggers>' + $strSelected + '</Style.Triggers></Style>'
        $strComboBad = '<Style x:Key="I" TargetType="ComboBoxItem"><Style.Triggers>' + $strSelected + '</Style.Triggers></Style>'
        $strComboGood = '<Style x:Key="I" TargetType="ComboBoxItem"><Style.Triggers>' + $strSelected + $strHighlighted + '</Style.Triggers></Style>'
        $strBox = '<ComboBox ItemContainerStyle="{StaticResource I}"/>'
        @(Get-SelectedStateViolation -Text ($strOpen + '<Grid.Resources>' + $strComboBad + '</Grid.Resources>' + $strBox + '</Grid>') -Source 's').Count | Should -Be 1
        @(Get-SelectedStateViolation -Text ($strOpen + '<Grid.Resources>' + $strComboGood + '</Grid.Resources>' + $strBox + '</Grid>') -Source 's').Count | Should -Be 0
        @(Get-SelectedStateViolation -Text ($strOpen + '<ListBox/></Grid>') -Source 's').Count | Should -Be 1
        @(Get-SelectedStateViolation -Text ($strOpen + '<Grid.Resources>' + $strRow + $strCell + '</Grid.Resources><DataGrid Style="{StaticResource G}" CellStyle="{StaticResource C}"/></Grid>') -Source 's').Count | Should -Be 0
        @(Get-SelectedStateViolation -Text ($strOpen + '<Grid.Resources>' + $strRow + '</Grid.Resources><DataGrid Style="{StaticResource G}"/></Grid>') -Source 's').Count | Should -Be 1
    }

    It 'resolves the styles of a page through the context document' {
        $strOpen = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">'
        $strSelected = '<Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Accent}"/><Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/></Trigger>'
        $strHighlighted = '<Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Accent}"/><Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/></Trigger>'
        $strContext = $strOpen + '<Grid.Resources><Style x:Key="I" TargetType="ComboBoxItem"><Style.Triggers>' + $strSelected + $strHighlighted + '</Style.Triggers></Style></Grid.Resources></Grid>'
        $strPage = $strOpen + '<ComboBox x:Name="cbo" ItemContainerStyle="{DynamicResource I}"/></Grid>'
        @(Get-SelectedStateViolation -Text $strPage -Source 's').Count | Should -Be 1
        @(Get-SelectedStateViolation -Text $strPage -Source 's' -Context $strContext).Count | Should -Be 0
    }

    It 'finds the sidebar buttons of the window and lists each in the theme call of the shell' {
        $objAst = Get-ScriptAst -Path $script:strShellPath
        $arrThemed = @(Get-ShellThemedButton -Ast $objAst)
        $arrThemed.Count | Should -BeGreaterOrEqual 7
        [xml]$xml = $script:objMainDoc.Text
        $arrSidebar = @($xml.SelectNodes("//*[local-name()='Button'][contains(@Style,'ViewButtonStyle') or contains(@Style,'OptionsButtonStyle')]"))
        $arrSidebar.Count | Should -BeGreaterOrEqual 7
        $arrMissing = foreach ($objButton in $arrSidebar) {
            $strName = $objButton.GetAttribute('Name', $script:strXamlNamespace)
            if (-not $strName) { 'a sidebar button has no x:Name' } elseif ($arrThemed -notcontains $strName) { $strName }
        }
        @($arrMissing) | Should -BeNullOrEmpty
        $objInit = @(Get-AstCommand -Ast $objAst -Name 'Initialize-SuiteTheme')
        $objInit.Count | Should -Be 1
        (Get-CommandParameterValue -Command $objInit[0] -Name 'ViewButtons') | Should -Be '$script:ViewButtons'
        (Get-CommandParameterValue -Command $objInit[0] -Name 'OptionsButton') | Should -Be '$btnOptions'
        @(Get-AstCommand -Ast $objAst -Name 'Update-SidebarButtonTheme').Count | Should -BeGreaterOrEqual 3
    }
}

Describe 'Theme helpers of SuiteCommon behave and are used (a, b)' {
    BeforeAll {
        # Set-ThemeForeground tests a type of WindowsBase. The test loads the assemblies itself, so it runs alone.
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $script:objSuiteAst = Get-ScriptAst -Path $script:strSuiteFile
        $script:strThemeForegroundText = (Get-AstFunction -Ast $script:objSuiteAst -Name 'Set-ThemeForeground').Extent.Text
        . ([scriptblock]::Create($script:strThemeForegroundText))
    }

    It 'paints the light theme buttons of SuiteCommon with white text' {
        $objInit = Get-AstFunction -Ast $script:objSuiteAst -Name 'Initialize-SuiteTheme'
        $objInit | Should -Not -BeNullOrEmpty
        $arrPair = @(foreach ($objHash in @($objInit.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))) {
                foreach ($objPair in $objHash.KeyValuePairs) { if ([string]$objPair.Item1.Value -eq 'OnBlue') { $objPair } }
            })
        $arrPair.Count | Should -Be 1
        $objCall = $arrPair[0].Item2.Find({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
        $objCall | Should -Not -BeNullOrEmpty
        [string]$objCall.Member.Value | Should -Be 'ConvertFrom'
        [string]$objCall.Arguments[0].Value | Should -Be '#FFFFFF'
        foreach ($strName in 'Update-SidebarButtonTheme', 'Set-ButtonTheme') {
            $objFunction = Get-AstFunction -Ast $script:objSuiteAst -Name $strName
            $objFunction | Should -Not -BeNullOrEmpty -Because $strName
            @(Get-AstCommand -Ast $objFunction -Name 'Set-ThemeForeground').Count | Should -BeGreaterThan 0 -Because ('{0} sets the foreground with each background' -f $strName)
            @(Get-AstCommand -Ast $objFunction -Name 'Set-ConnectionTextTheme').Count | Should -BeGreaterThan 0 -Because $strName
        }
    }

    It 'Set-ThemeForeground sets the on-blue brush in light mode and clears it in dark mode' {
        $objControl = [pscustomobject]@{ Foreground = $null }
        Set-ThemeForeground -Control $objControl -IsDark $false -OnBlue 'White'
        $objControl.Foreground | Should -Be 'White'
        Set-ThemeForeground -Control $objControl -IsDark $true -OnBlue 'White'
        $objControl.Foreground | Should -BeNullOrEmpty
    }

    It 'Set-ThemeForeground clears a dependency object through ClearValue and takes a null control' {
        $script:strThemeForegroundText | Should -Match 'ClearValue\(\[System\.Windows\.Controls\.Control\]::ForegroundProperty\)'
        { Set-ThemeForeground -Control $null -IsDark $false -OnBlue 'White' } | Should -Not -Throw
    }

    It 'Set-ThemeForeground sets white on a real Button in light mode and gives the style color back in dark mode' {
        # A WPF control needs a single-threaded apartment. Windows PowerShell 5.1 runs Pester in one, PowerShell 7 does not, so the
        # test uses its own STA runspace. It creates one Button and shows no window.
        $objRunspace = [runspacefactory]::CreateRunspace()
        $objRunspace.ApartmentState = 'STA'
        $objRunspace.ThreadOptions = 'ReuseThread'
        $objRunspace.Open()
        $objShell = [powershell]::Create()
        try {
            $objShell.Runspace = $objRunspace
            [void]$objShell.AddScript({
                    param($FunctionText)
                    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
                    . ([scriptblock]::Create($FunctionText))
                    $objButton = New-Object System.Windows.Controls.Button
                    $objWhite = [System.Windows.Media.Brushes]::White
                    $strUnset = [System.Windows.DependencyProperty]::UnsetValue
                    $objStart = $objButton.ReadLocalValue([System.Windows.Controls.Control]::ForegroundProperty)
                    Set-ThemeForeground -Control $objButton -IsDark $false -OnBlue $objWhite
                    $objLight = $objButton.ReadLocalValue([System.Windows.Controls.Control]::ForegroundProperty)
                    Set-ThemeForeground -Control $objButton -IsDark $true -OnBlue $objWhite
                    $objDark = $objButton.ReadLocalValue([System.Windows.Controls.Control]::ForegroundProperty)
                    [pscustomobject]@{ Apartment = [string][System.Threading.Thread]::CurrentThread.GetApartmentState(); StartUnset = [object]::ReferenceEquals($objStart, $strUnset); LightIsWhite = [object]::ReferenceEquals($objLight, $objWhite); DarkUnset = [object]::ReferenceEquals($objDark, $strUnset) }
                }).AddArgument($script:strThemeForegroundText)
            $arrResult = @($objShell.Invoke())
            $objShell.HadErrors | Should -BeFalse -Because (($objShell.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ')
            $arrResult.Count | Should -Be 1
            $arrResult[0].Apartment | Should -Be 'STA'
            $arrResult[0].StartUnset | Should -BeTrue
            $arrResult[0].LightIsWhite | Should -BeTrue
            $arrResult[0].DarkUnset | Should -BeTrue
        }
        finally {
            $objShell.Dispose()
            $objRunspace.Dispose()
        }
    }

    It 'the script starts the theme, applies it in both themes and every dialog calls Set-DialogTheme' {
        $objShell = Get-ScriptAst -Path $script:strShellPath
        $arrInit = @(Get-AstCommand -Ast $objShell -Name 'Initialize-SuiteTheme')
        $arrInit.Count | Should -Be 1
        (Get-CommandParameterValue -Command $arrInit[0] -Name 'LogLabel') | Should -Be '$lblLogOutput'
        (Get-CommandParameterValue -Command $arrInit[0] -Name 'Brushes') | Should -Not -BeNullOrEmpty
        $arrToggle = @($objShell.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -eq 'Add_Toggled' -and $n.Expression.Extent.Text -eq '$toggleTheme' }, $true))
        $arrToggle.Count | Should -Be 1
        $strToggle = $arrToggle[0].Extent.Text
        $strToggle | Should -Match 'ChangeTheme\(\$window, ''Dark\.Steel''\)'
        $strToggle | Should -Match 'ChangeTheme\(\$window, ''Light\.Blue''\)'
        $strToggle | Should -Match 'Update-SidebarButtonTheme'
        $strToggle | Should -Match 'Update-TitleBarBrushes'
        $objView = Get-AstFunction -Ast $objShell -Name 'Set-ActiveView'
        $objView | Should -Not -BeNullOrEmpty
        @(Get-AstCommand -Ast $objView -Name 'Update-SidebarButtonTheme').Count | Should -BeGreaterThan 0
        $intDialog = @($script:arrXamlDoc | Where-Object { $_.Kind -eq 'Dialog' }).Count
        $intDialog | Should -Be 4
        $arrDialogCall = @(Get-AstCommand -Ast $objShell -Name 'Set-DialogTheme')
        $arrDialogCall.Count | Should -BeGreaterOrEqual $intDialog
        foreach ($objCall in $arrDialogCall) { (Get-CommandParameterValue -Command $objCall -Name 'Dialog') | Should -Not -BeNullOrEmpty }
        foreach ($strName in 'Set-DialogTheme', 'Update-TitleBarBrushes', 'Update-SidebarButtonTheme', 'Initialize-SuiteTheme') {
            (Get-AstFunction -Ast $script:objSuiteAst -Name $strName) | Should -Not -BeNullOrEmpty -Because $strName
        }
    }
}

Describe 'Fonts do not depend on the theme (b)' {
    It 'has no font property in a theme branch of <Name>' -ForEach $script:arrPsFileD {
        $objAst = Get-ScriptAst -Path $Path
        $arrAssign = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)
        $arrBad = foreach ($objAssign in $arrAssign) {
            $strMember = [string]$objAssign.Left.Member.Value
            if ($script:arrThemeProperty -notcontains $strMember) { continue }
            $objParent = $objAssign.Parent
            while ($objParent) {
                $strCondition = ''
                if ($objParent -is [System.Management.Automation.Language.IfStatementAst]) { $strCondition = (@($objParent.Clauses | ForEach-Object { $_.Item1.Extent.Text }) -join ' ') }
                elseif ($objParent -is [System.Management.Automation.Language.SwitchStatementAst]) { $strCondition = $objParent.Condition.Extent.Text }
                if ($strCondition -match '(?i)IsDark|DarkMode|Light|Theme|IsOn') { '{0}:{1} sets {2} in a theme branch' -f $Name, $objAssign.Extent.StartLineNumber, $strMember; break }
                $objParent = $objParent.Parent
            }
        }
        @($arrBad) | Should -BeNullOrEmpty
    }

    It 'sets no font property in the theme functions of SuiteCommon except the connection boxes' {
        $objAst = Get-ScriptAst -Path $script:strSuiteFile
        foreach ($strName in 'Set-ThemeForeground', 'Update-SidebarButtonTheme', 'Set-ButtonTheme', 'Set-DialogTheme', 'Update-TitleBarBrushes', 'Initialize-SuiteTheme') {
            $objFunction = Get-AstFunction -Ast $objAst -Name $strName
            $objFunction | Should -Not -BeNullOrEmpty -Because $strName
            $objFunction.Extent.Text | Should -Not -Match '\.(FontSize|FontWeight|FontStyle|TextDecorations)\s*=' -Because $strName
        }
    }

    It 'makes the title of each connection box bold and 14 pt or larger, and leaves the value alone, the same way in both themes' {
        $strText = Remove-ScriptComment -Text (Get-Content -LiteralPath $script:strSuiteFile -Raw)
        $strText | Should -Match 'FieldTitleFontSize\s*=\s*14'
        $objAst = Get-ScriptAst -Path $script:strSuiteFile
        $objFunction = Get-AstFunction -Ast $objAst -Name 'Set-ConnectionTextTheme'
        $objFunction | Should -Not -BeNullOrEmpty
        $strCode = Remove-ScriptComment -Text $objFunction.Extent.Text
        $strCode | Should -Match '\$title\.FontWeight\s*=\s*\[System\.Windows\.FontWeights\]::Bold'
        $strCode | Should -Not -Match '\$box\.(FontSize|FontWeight)\s*='
    }

    It 'has Set-ConnectionTextTheme and a connection box list in SuiteCommon that holds the site code, the provider and the site server' {
        $objAst = Get-ScriptAst -Path $script:strSuiteFile
        (Get-AstFunction -Ast $objAst -Name 'Set-ConnectionTextTheme') | Should -Not -BeNullOrEmpty
        $arrAssign = @($objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'script:ConnectionBoxNames' }, $true))
        $arrAssign.Count | Should -Be 1
        $arrName = @($arrAssign[0].Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { [string]$_.Value })
        foreach ($strName in 'txtSiteCode', 'txtSmsProvider', 'txtProvider', 'txtSiteServer') { $arrName | Should -Contain $strName }
    }

    It 'keeps the page title, the progress title, the log header, the running actions header, the device count and the Options headers SemiBold' {
        $arrExpect = @(
            @{ Source = 'MainWindow.xaml'; Name = 'txtModuleTitle' }, @{ Source = 'MainWindow.xaml'; Name = 'txtProgressTitle' }
            @{ Source = 'MainWindow.xaml'; Name = 'lblLogOutput' }, @{ Source = 'MainWindow.xaml'; Name = 'lblRuns' }
        )
        foreach ($hashCase in $arrExpect) {
            $objDoc = @($script:arrOwnXamlDoc | Where-Object { $_.Source -eq $hashCase.Source })[0]
            [xml]$xml = $objDoc.Text
            $xml.SelectSingleNode(("//*[@*[local-name()='Name']='{0}']" -f $hashCase.Name)).GetAttribute('FontWeight') | Should -Be 'SemiBold' -Because $hashCase.Name
        }
        $strShell = Get-Content -LiteralPath (Join-Path -Path $script:strRepoRoot -ChildPath 'start-deviceinspector.ps1') -Raw
        foreach ($strName in 'txtDeviceCount', 'txtAboutVersion') {
            $strShell | Should -Match ('x:Name="{0}"[^>]*FontWeight="SemiBold"' -f $strName)
        }
        foreach ($strText in 'Configuration Manager Connection', 'About') {
            $strShell | Should -Match ('Text="{0}" Style="\{{StaticResource OptLabel\}}" FontSize="13" FontWeight="SemiBold"' -f $strText)
        }
    }

    It 'uses no theme trigger on a font property in <_.Source>' -ForEach $script:arrXamlDocD {
        # A trigger on the selected tab or on the mouse is not a theme trigger. A trigger is a theme trigger when its own condition names the theme.
        [xml]$xml = $_.Text
        $arrBad = foreach ($objSetter in @($xml.SelectNodes("//*[local-name()='Setter']"))) {
            if ($script:arrThemeProperty -contains (Get-PropertyLeaf $objSetter.GetAttribute('Property'))) {
                $objParent = $objSetter.ParentNode
                if ($objParent.LocalName -match 'Trigger') {
                    $strCondition = '{0} {1} {2}' -f $objParent.GetAttribute('Property'), $objParent.GetAttribute('Binding'), $objParent.GetAttribute('Value')
                    if ($strCondition -match '(?i)theme|dark|light|IsDark') { $objParent.OuterXml.Substring(0, [Math]::Min(80, $objParent.OuterXml.Length)) }
                }
            }
        }
        @($arrBad) | Should -BeNullOrEmpty
    }

    It 'finds the site code, SMS Provider and site server boxes in the documents' {
        $arrName = foreach ($objDoc in @($script:arrOwnXamlDoc)) {
            [xml]$xml = $objDoc.Text
            foreach ($strName in 'txtDevice', 'txtSiteCode', 'txtSmsProvider', 'txtSiteServer') { if ($xml.SelectSingleNode(("//*[@*[local-name()='Name']='{0}']" -f $strName))) { $strName } }
        }
        (@($arrName | Sort-Object -Unique) -join ',') | Should -Be 'txtDevice,txtSiteCode,txtSiteServer,txtSmsProvider'
    }

    It 'sets the title of each connection box that <_.Source> has to bold 14 pt or more, and the value to normal weight and a size below 14 pt' -ForEach $script:arrOwnXamlDocD {
        [xml]$xml = $_.Text
        foreach ($strName in 'txtDevice', 'txtSiteCode', 'txtSmsProvider', 'txtProvider', 'txtSiteServer') {
            $objElement = $xml.SelectSingleNode(("//*[@*[local-name()='Name']='{0}']" -f $strName))
            if (-not $objElement) { continue }
            $objTitle = $objElement.PreviousSibling
            while ($objTitle -and $objTitle.NodeType -ne 'Element') { $objTitle = $objTitle.PreviousSibling }
            $objTitle | Should -Not -BeNullOrEmpty -Because ('{0} has a title element before it' -f $strName)
            $objTitle.LocalName | Should -BeIn @('TextBlock', 'Label') -Because $strName
            [double]$objTitle.GetAttribute('FontSize') | Should -BeGreaterOrEqual 14 -Because ('the title of {0}' -f $strName)
            $objTitle.GetAttribute('FontWeight') | Should -Be 'Bold' -Because ('the title of {0}' -f $strName)
            $objElement.GetAttribute('FontWeight') | Should -Not -Be 'Bold' -Because ('the value of {0}' -f $strName)
            if ($objElement.GetAttribute('FontSize')) { [double]$objElement.GetAttribute('FontSize') | Should -BeLessThan 14 -Because ('the value of {0}' -f $strName) }
        }
    }

    It 'makes every field label of the main window and the dialogs bold in <_.Source>' -ForEach $script:arrOwnXamlDocD {
        $arrBad = @(Get-FieldLabelViolation -Text $_.Text -Context $_.Context)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'finds the field labels of the documents' {
        $intCount = 0
        foreach ($objDoc in $script:arrOwnXamlDoc) {
            [xml]$xml = $objDoc.Text
            $intCount += @($xml.SelectNodes("//*[local-name()='TextBlock'][contains(@Style,'FieldLabelStyle') or contains(@Style,'OptLabel')]")).Count
        }
        $intCount | Should -BeGreaterOrEqual 4
    }

    It 'flags a field label that is not bold, and resolves its style through the context' {
        $strOpen = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">'
        $strContext = $strOpen + '<Grid.Resources><Style x:Key="FieldLabelStyle" TargetType="TextBlock"><Setter Property="FontWeight" Value="Bold"/></Style><Style x:Key="OptLabel" TargetType="TextBlock"><Setter Property="FontSize" Value="12"/></Style></Grid.Resources></Grid>'
        $strPage = $strOpen + '<TextBlock Style="{DynamicResource FieldLabelStyle}" Text="Key Path:"/></Grid>'
        @(Get-FieldLabelViolation -Text $strPage).Count | Should -Be 1
        @(Get-FieldLabelViolation -Text $strPage -Context $strContext).Count | Should -Be 0
        @(Get-FieldLabelViolation -Text ($strOpen + '<TextBlock Style="{DynamicResource OptLabel}" Text="Stack:"/></Grid>') -Context $strContext).Count | Should -Be 1
        @(Get-FieldLabelViolation -Text ($strOpen + '<TextBlock Style="{DynamicResource OptLabel}" FontWeight="Bold" Text="Stack:"/></Grid>') -Context $strContext).Count | Should -Be 0
    }
}

Describe 'No banned word in the UI text and the documents (c)' {
    It 'finds the banned word <Word>' -ForEach @(@{ Word = 'simply' }, @{ Word = 'Helps you' }, @{ Word = 'streamlines' }, @{ Word = 'just' }, @{ Word = 'quickly' }) {
        $Word | Should -Match $script:strBannedPattern
    }

    It 'has no banned word in the XAML text of <_.Source>' -ForEach $script:arrXamlDocD {
        $arrBad = @(Get-XamlUiText -Text $_.Text | Where-Object { $_ -match $script:strBannedPattern })
        $arrBad | Should -BeNullOrEmpty
    }

    It 'has no banned word in the strings of <Name>' -ForEach $script:arrPsFileD {
        $arrBad = @(Get-ScriptString -Path $Path | Where-Object { $_ -match $script:strBannedPattern })
        $arrBad | Should -BeNullOrEmpty
    }

    It 'has no banned word in the README or the user guide' {
        $arrFile = @(Get-Item -LiteralPath (Join-Path -Path $script:strRepoRoot -ChildPath 'README.md')) + @(Get-ChildItem -LiteralPath (Join-Path -Path $script:strRepoRoot -ChildPath 'docs') -Filter '*.md' -File -Recurse)
        $arrFile.Count | Should -BeGreaterThan 5
        $arrBad = foreach ($objFile in $arrFile) {
            $intLine = 0
            foreach ($strLine in (Get-Content -LiteralPath $objFile.FullName)) {
                $intLine++
                if ($strLine -match $script:strBannedPattern) { '{0}:{1}: {2}' -f $objFile.Name, $intLine, $Matches[0] }
            }
        }
        @($arrBad) | Should -BeNullOrEmpty
    }

    It 'writes ConfigMgr and never MECM in the UI text and the documents' {
        $arrFile = @(Get-Item -LiteralPath (Join-Path -Path $script:strRepoRoot -ChildPath 'README.md')) + @(Get-ChildItem -LiteralPath (Join-Path -Path $script:strRepoRoot -ChildPath 'docs') -Filter '*.md' -File -Recurse)
        $arrBad = foreach ($objFile in $arrFile) { if ((Get-Content -LiteralPath $objFile.FullName -Raw) -cmatch '\bMECM\b') { $objFile.Name } }
        @($arrBad) | Should -BeNullOrEmpty
        $arrText = foreach ($objDoc in $script:arrOwnXamlDoc) { Get-XamlUiText -Text $objDoc.Text }
        @($arrText).Count | Should -BeGreaterThan 20
        @($arrText | Where-Object { $_ -cmatch '\bMECM\b' }) | Should -BeNullOrEmpty
    }
}

Describe 'Every button takes the shared themed style (d)' {
    It 'has no unthemed button and no literal button color in <_.Source>' -ForEach $script:arrOwnXamlDocD {
        $arrBad = @(Get-ButtonThemeViolation -Text $_.Text -Source $_.Source -Context $_.Context)
        $arrBad | Should -BeNullOrEmpty
    }

    # The dialogs of SuiteCommon are vendored code. They are fixed in the suite repository (app-packager-suite), not here.
    # The test is skipped on purpose and shows in the result as Skipped with this reason.
    It 'SKIPPED until the suite repository fixes its dialogs: has no unthemed button in <_.Source>' -Skip -ForEach @($script:arrXamlDocD | Where-Object { $_.Source -match 'SuiteCommon' }) {
        $arrBad = @(Get-ButtonThemeViolation -Text $_.Text -Source $_.Source)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'finds the buttons of the documents' {
        $intCount = 0
        foreach ($objDoc in $script:arrOwnXamlDoc) {
            [xml]$xml = $objDoc.Text
            $intCount += @($xml.SelectNodes("//*[local-name()='Button']")).Count
        }
        $intCount | Should -BeGreaterThan 25
    }

    It 'resolves a button style of a page through the context' {
        $strThemed = '<Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}"/><Style x:Key="S" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}"/>'
        $strContext = '<Grid ' + $script:strXamlHead + '><Grid.Resources>' + $strThemed + '</Grid.Resources></Grid>'
        $strPage = '<Grid ' + $script:strXamlHead + '><Button x:Name="b" Style="{DynamicResource S}"/></Grid>'
        @(Get-ButtonThemeViolation -Text $strPage -Source 's').Count | Should -Be 1
        @(Get-ButtonThemeViolation -Text $strPage -Source 's' -Context $strContext).Count | Should -Be 0
    }

    It 'flags a button that has no style, a literal color and a style that is not shared' {
        $strNamespace = $script:strXamlHead
        $strThemed = '<Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}"/>'
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Button x:Name=`"a`"/></Grid>" -Source 's').Count | Should -Be 1
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed<Style x:Key=`"S`" TargetType=`"Button`" BasedOn=`"{StaticResource ThemedButtonStyle}`"/></Grid.Resources><Button Style=`"{StaticResource S}`" Background=`"#1E1E1E`"/></Grid>" -Source 's').Count | Should -Be 1
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed<Style x:Key=`"S`" TargetType=`"Button`" BasedOn=`"{StaticResource MahApps.Styles.Button.Square.Accent}`"/></Grid.Resources><Button Style=`"{StaticResource S}`"/></Grid>" -Source 's').Count | Should -Be 2
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed<Style x:Key=`"S`" TargetType=`"Button`" BasedOn=`"{StaticResource ThemedButtonStyle}`"><Setter Property=`"Foreground`" Value=`"White`"/></Style></Grid.Resources><Button Style=`"{StaticResource S}`"/></Grid>" -Source 's').Count | Should -Be 1
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed<Style x:Key=`"S`" TargetType=`"Button`" BasedOn=`"{StaticResource ThemedButtonStyle}`"><Setter Property=`"Foreground`" Value=`"{DynamicResource MahApps.Brushes.ThemeForeground}`"/></Style></Grid.Resources><Button Style=`"{StaticResource S}`"/></Grid>" -Source 's').Count | Should -Be 0
    }

    It 'flags a named color and a color in a style or template of another control' {
        $strNamespace = $script:strXamlHead
        $strThemed = '<Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}"/>'
        foreach ($strName in 'Orange', 'Silver', 'WhiteSmoke') {
            $strStyle = '<Style x:Key="T" TargetType="TextBlock"><Setter Property="Foreground" Value="' + $strName + '"/></Style>'
            @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed$strStyle</Grid.Resources></Grid>" -Source 's').Count | Should -Be 1 -Because $strName
        }
        $strTemplate = '<ControlTemplate TargetType="ListBoxItem"><Border Background="Silver"/></ControlTemplate>'
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed$strTemplate</Grid.Resources></Grid>" -Source 's').Count | Should -Be 1
        $strOk = '<Style x:Key="T" TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray1}"/></Style>'
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed$strOk</Grid.Resources></Grid>" -Source 's').Count | Should -Be 0
    }

    It 'flags a literal color in a qualified brush property and in a nested brush of a button template' {
        $strNamespace = $script:strXamlHead
        $strThemed = '<Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}"/>'
        $strStyle = '<Style x:Key="S" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}"><Setter Property="Controls:ControlsHelper.MouseOverBorderBrush" Value="#3A3A3A"/></Style>'
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed$strStyle</Grid.Resources><Button Style=`"{StaticResource S}`"/></Grid>" -Source 's').Count | Should -Be 1
        $strNested = '<ControlTemplate TargetType="Button"><Border><Border.Background><SolidColorBrush Color="#3A3A3A"/></Border.Background></Border></ControlTemplate>'
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed$strNested</Grid.Resources></Grid>" -Source 's').Count | Should -Be 1
        $strSetter = '<Style x:Key="S" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}"><Setter Property="Background"><Setter.Value><SolidColorBrush Color="#3A3A3A"/></Setter.Value></Setter></Style>'
        @(Get-ButtonThemeViolation -Text "<Grid $strNamespace><Grid.Resources>$strThemed$strSetter</Grid.Resources><Button Style=`"{StaticResource S}`"/></Grid>" -Source 's').Count | Should -Be 1
    }
}

Describe 'Button template, single definition and dialog buttons (d)' {
    It 'defines the button template and the button style once in <_.Source>' -ForEach $script:arrChromeDocD {
        [xml]$xml = $_.Text
        @($xml.SelectNodes("//*[local-name()='Style'][@*[local-name()='Key']='ThemedButtonStyle']")).Count | Should -Be 1 -Because $_.Source
        @($xml.SelectNodes("//*[local-name()='ControlTemplate'][@*[local-name()='Key']='ThemedButtonTemplate']")).Count | Should -Be 1 -Because $_.Source
        @($xml.SelectNodes("//*[local-name()='ControlTemplate'][@TargetType='Button' or @TargetType='ButtonBase']")).Count | Should -Be 1 -Because $_.Source
    }

    It 'uses the same button template and the same button style in the main window and in every dialog' {
        $arrTemplate = foreach ($objDoc in $script:arrChromeDoc) {
            [xml]$xml = $objDoc.Text
            $objNode = $xml.SelectSingleNode("//*[local-name()='ControlTemplate'][@*[local-name()='Key']='ThemedButtonTemplate']")
            $objNode | Should -Not -BeNullOrEmpty -Because $objDoc.Source
            ($objNode.InnerXml -replace '\s+', ' ').Trim()
        }
        @($arrTemplate).Count | Should -Be 5
        @($arrTemplate | Sort-Object -Unique).Count | Should -Be 1
        $arrStyle = foreach ($objDoc in $script:arrChromeDoc) {
            [xml]$xml = $objDoc.Text
            $objNode = $xml.SelectSingleNode("//*[local-name()='Style'][@*[local-name()='Key']='ThemedButtonStyle']")
            ($objNode.InnerXml -replace '\s+', ' ').Trim()
        }
        @($arrStyle | Sort-Object -Unique).Count | Should -Be 1
    }

    It 'has no Opacity, a hover border and a swapped pressed state in the button template of <_.Source>' -ForEach $script:arrChromeDocD {
        $arrBad = @(Get-ButtonTemplateViolation -Text $_.Text -Source $_.Source)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'flags an Opacity setter, a literal hover color and a pressed state that does not swap' {
        $strHover = '<Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>'
        $strPressed = '<Setter TargetName="Bd" Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/><Setter TargetName="Cp" Property="TextElement.Foreground" Value="{DynamicResource MahApps.Brushes.ThemeBackground}"/>'
        $scriptMake = {
            param($strHoverSetter, $strPressedSetter, $strExtra)
            '<Grid ' + $script:strXamlHead + '><Grid.Resources><ControlTemplate x:Key="ThemedButtonTemplate" TargetType="Button"><Border Name="Bd" Background="{TemplateBinding Background}"><ContentPresenter Name="Cp"/></Border><ControlTemplate.Triggers><MultiTrigger><MultiTrigger.Conditions><Condition Property="IsMouseOver" Value="True"/><Condition Property="IsEnabled" Value="True"/></MultiTrigger.Conditions>' + $strHoverSetter + '</MultiTrigger><Trigger Property="IsPressed" Value="True">' + $strPressedSetter + '</Trigger></ControlTemplate.Triggers></ControlTemplate>' + $strExtra + '</Grid.Resources></Grid>'
        }
        @(Get-ButtonTemplateViolation -Text (& $scriptMake $strHover $strPressed '') -Source 's').Count | Should -Be 0
        $strOpacity = '<Setter Property="Opacity" Value="0.5"/>'
        @(Get-ButtonTemplateViolation -Text (& $scriptMake ($strHover + $strOpacity) $strPressed '') -Source 's').Count | Should -Be 1
        @(Get-ButtonTemplateViolation -Text (& $scriptMake $strHover $strPressed ('<Style x:Key="S" TargetType="Button">' + $strOpacity + '</Style>')) -Source 's').Count | Should -Be 1
        @(Get-ButtonTemplateViolation -Text (& $scriptMake ($strHover + '<Setter TargetName="Bd" Property="Background" Value="#3A3A3A"/>') $strPressed '') -Source 's').Count | Should -Be 1
        @(Get-ButtonTemplateViolation -Text (& $scriptMake '<Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Accent}"/>' $strPressed '') -Source 's').Count | Should -Be 1
        @(Get-ButtonTemplateViolation -Text (& $scriptMake $strHover '<Setter TargetName="Bd" Property="Background" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>' '') -Source 's').Count | Should -Be 1
        @(Get-ButtonTemplateViolation -Text ('<Grid ' + $script:strXamlHead + '/>') -Source 's').Count | Should -Be 1
    }

    It 'has one primary button style in the main window and no other button style that sets a Background' {
        # ThemedButtonStyle is the base of every button style and is not counted.
        [xml]$xml = $script:objMainDoc.Text
        $arrWithBackground = foreach ($objStyle in @($xml.SelectNodes("//*[local-name()='Style'][@TargetType='Button']"))) {
            $strKey = Get-XamlKey $objStyle
            if ($strKey -ne 'ThemedButtonStyle' -and @(Get-SetterChild -Node $objStyle -LeafPattern '^Background$').Count -gt 0) { $strKey }
        }
        (@($arrWithBackground | Sort-Object) -join ',') | Should -Be 'PrimaryButtonStyle'
    }

    It 'has one gray secondary style and one primary style in <_.Source>, documented, defined once, of one size, and no other button style that sets a Background' -ForEach $script:arrDialogDocD {
        $arrBad = @(Get-DialogButtonViolation -Text $_.Text -Source $_.Source)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'defines the same secondary and primary dialog button style in every dialog' {
        $arrDoc = @($script:arrDialogDoc)
        $arrDoc.Count | Should -Be 4
        foreach ($strKey in 'DialogButton', 'DialogAccentButton') {
            $arrStyle = foreach ($objDoc in $arrDoc) {
                [xml]$xml = $objDoc.Text
                $arrNode = @($xml.SelectNodes(("//*[local-name()='Style'][@*[local-name()='Key']='{0}']" -f $strKey)))
                $arrNode.Count | Should -Be 1 -Because ('{0} in {1}' -f $strKey, $objDoc.Source)
                ($arrNode[0].InnerXml -replace '\s+', ' ').Trim()
            }
            @($arrStyle | Sort-Object -Unique).Count | Should -Be 1 -Because $strKey
        }
    }

    It 'gives Cancel the secondary style and every other answer of a dialog a dialog style' {
        $intCancel = 0
        foreach ($objDoc in $script:arrDialogDoc) {
            [xml]$xml = $objDoc.Text
            foreach ($objButton in @($xml.SelectNodes("//*[local-name()='Button']"))) {
                (Get-ResourceKey $objButton.GetAttribute('Style')) | Should -BeIn @('DialogButton', 'DialogAccentButton', 'CategoryRowStyle') -Because ('{0} {1}' -f $objDoc.Source, $objButton.GetAttribute('Name', $script:strXamlNamespace))
                if ($objButton.GetAttribute('Content') -eq 'Cancel') { $intCancel++; (Get-ResourceKey $objButton.GetAttribute('Style')) | Should -Be 'DialogButton' }
            }
        }
        $intCancel | Should -Be 2
    }

    It 'flags a second secondary style, a size that differs, a missing comment, a literal color, a Cancel with the wrong style and an own size in the dialog styles' {
        $scriptMake = {
            param($strCancelHeight, $strOkHeight, $strComment, $strFill, $strCancelStyle, $strCancelAttribute, $strExtra)
            '<Grid ' + $script:strXamlHead + '><Grid.Resources><Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}"/>' + $strComment + '<Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}"><Setter Property="Background" Value="' + $strFill + '"/><Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="' + $strCancelHeight + '"/></Style><Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}"><Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Highlight}"/><Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="' + $strOkHeight + '"/></Style>' + $strExtra + '</Grid.Resources><Button x:Name="btnOk" Content="OK" Style="{StaticResource DialogAccentButton}"/><Button x:Name="btnCancel" Content="Cancel" Style="{StaticResource ' + $strCancelStyle + '}" ' + $strCancelAttribute + '/></Grid>'
        }
        $strComment = '<!-- The secondary style. -->'
        $strGray = '{DynamicResource MahApps.Brushes.Gray10}'
        @(Get-DialogButtonViolation -Text (& $scriptMake '32' '32' $strComment $strGray 'DialogButton' '' '') -Source 's').Count | Should -Be 0
        @(Get-DialogButtonViolation -Text (& $scriptMake '28' '32' $strComment $strGray 'DialogButton' '' '') -Source 's').Count | Should -Be 1
        @(Get-DialogButtonViolation -Text (& $scriptMake '32' '32' '' $strGray 'DialogButton' '' '') -Source 's').Count | Should -Be 1
        @(Get-DialogButtonViolation -Text (& $scriptMake '32' '32' $strComment '#C0C0C0' 'DialogButton' '' '') -Source 's').Count | Should -Be 1
        @(Get-DialogButtonViolation -Text (& $scriptMake '32' '32' $strComment $strGray 'DialogAccentButton' '' '') -Source 's').Count | Should -Be 1
        @(Get-DialogButtonViolation -Text (& $scriptMake '32' '32' $strComment $strGray 'DialogButton' 'MinWidth="120"' '') -Source 's').Count | Should -Be 1
        @(Get-DialogButtonViolation -Text (& $scriptMake '32' '32' $strComment $strGray 'DialogButton' 'Padding="4"' '') -Source 's').Count | Should -Be 1
        @(Get-DialogButtonViolation -Text (& $scriptMake '32' '32' $strComment $strGray 'DialogButton' '' '<Style x:Key="Second" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}"><Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Gray8}"/></Style>') -Source 's').Count | Should -Be 1
        @(Get-DialogButtonViolation -Text (& $scriptMake '32' '32' $strComment $strGray 'DialogButton' '' '<Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}"/>') -Source 's').Count | Should -BeGreaterOrEqual 1
        @(Get-DialogButtonViolation -Text ('<Grid ' + $script:strXamlHead + '/>') -Source 's').Count | Should -Be 2
    }

    It 'sets no size, padding or font size of a button in code, and builds no button in code' {
        @(Get-ButtonCodeSizeViolation -Path $script:strShellPath) | Should -BeNullOrEmpty
        @(Get-ButtonCreatedInCode -Path $script:strShellPath) | Should -BeNullOrEmpty
        @(Get-ScriptAst -Path $script:strShellPath | ForEach-Object { $_.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -match '^btn\w+$' }, $true) }).Count | Should -BeGreaterThan 20
    }

    It 'flags a button size set in code and a button built in code' {
        $strTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('themeguard-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            $arrLine = @('$btnOk.Height = 40', "`$dlg.FindName('btnCancel').MinWidth = 120", '$btnX.Padding = 4', '$txtA.Height = 3', '$btnY.Content = ''x''', '$b = New-Object System.Windows.Controls.Button', '$c = [System.Windows.Controls.Button]::new()')
            [System.IO.File]::WriteAllText($strTemp, ($arrLine -join "`n"))
            @(Get-ButtonCodeSizeViolation -Path $strTemp).Count | Should -Be 3
            @(Get-ButtonCreatedInCode -Path $strTemp).Count | Should -Be 2
        }
        finally { Remove-Item -LiteralPath $strTemp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Static XAML guards: button size, Opacity, resource brushes, Pester requirement (d)' {
    BeforeAll {
        # The hex colors that a brush resource may hold: contrast overrides of MahApps theme brushes and of the SuiteCommon palette.
        # Each key has one exact value. #7F7F7F is 4.0:1 on white and 3.8:1 on #252525 (a control border needs 3:1). #595959 is 7.0:1
        # with white title text. #557595 is 4.9:1 with white title text (the SuiteCommon default #4BA3E0 is 2.6:1).
        $script:hashBrushAllow = @{
            'MahApps.Brushes.TextBox.Border'        = '#7F7F7F'
            'MahApps.Brushes.WindowTitle.NonActive' = '#595959'
            'SuiteTheme.TitleBarInactive'           = '#557595'
        }
    }

    It 'scans the five own documents and a useful number of buttons, styles and brush resources' {
        $script:arrOwnXamlDoc.Count | Should -Be 5
        $intButton = 0; $intStyle = 0; $intBrush = 0
        foreach ($objDoc in $script:arrOwnXamlDoc) {
            [xml]$xml = $objDoc.Text
            $intButton += @($xml.SelectNodes("//*[local-name()='Button']")).Count
            $intStyle += @($xml.SelectNodes("//*[local-name()='Style']")).Count
            $intBrush += @($xml.SelectNodes("//*[@Color and @*[local-name()='Key']]")).Count
        }
        $intButton | Should -BeGreaterThan 25
        $intStyle | Should -BeGreaterThan 20
        $intBrush | Should -BeGreaterOrEqual 9
    }

    It 'sets no size or padding on a Button element in <_.Source>' -ForEach $script:arrOwnXamlDocD {
        $arrBad = @(Get-ButtonLocalSizeViolation -Text $_.Text -Source $_.Source)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'uses no Opacity in a style or template and none on a blue element in <_.Source>' -ForEach $script:arrOwnXamlDocD {
        $arrBad = @(Get-OpacityViolation -Text $_.Text -Source $_.Source)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'holds a literal color in a brush resource only for the allow list in <_.Source>' -ForEach $script:arrOwnXamlDocD {
        $arrBad = @(Get-ResourceBrushViolation -Text $_.Text -Source $_.Source -Allow $script:hashBrushAllow)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'finds the allow-listed brush resources where the documents define them' {
        $arrFound = New-Object System.Collections.Generic.List[string]
        foreach ($objDoc in $script:arrOwnXamlDoc) {
            [xml]$xml = $objDoc.Text
            foreach ($objBrush in @($xml.SelectNodes("//*[@Color and @*[local-name()='Key']]"))) { [void]$arrFound.Add((Get-XamlKey $objBrush)) }
        }
        $arrFound | Should -Contain 'MahApps.Brushes.TextBox.Border'
        $arrFound | Should -Contain 'MahApps.Brushes.WindowTitle.NonActive'
        $arrFound | Should -Contain 'SuiteTheme.TitleBarInactive'
        @($arrFound | Where-Object { -not $script:hashBrushAllow.ContainsKey($_) }) | Should -BeNullOrEmpty
    }

    It 'flags a button with its own size and padding' {
        $strSample = '<Grid ' + $script:strXamlHead + '><Button x:Name="a" Height="28" Padding="10,0"/><Button x:Name="b" MinWidth="90"/><Button x:Name="c" Margin="4"/><Button x:Name="d" Width="100"/></Grid>'
        @(Get-ButtonLocalSizeViolation -Text $strSample -Source 's').Count | Should -Be 4
        @(Get-ButtonLocalSizeViolation -Text ('<Grid ' + $script:strXamlHead + '><Button x:Name="c" Margin="4" Style="{DynamicResource S}"/></Grid>') -Source 's').Count | Should -Be 0
    }

    It 'flags Opacity in a style, in a template and on a blue element' {
        $strHead = '<Grid ' + $script:strXamlHead + '>'
        @(Get-OpacityViolation -Text ($strHead + '<Grid.Resources><Style x:Key="S" TargetType="Button"><Setter Property="Opacity" Value="0.5"/></Style></Grid.Resources></Grid>') -Source 's').Count | Should -Be 1
        @(Get-OpacityViolation -Text ($strHead + '<Grid.Resources><ControlTemplate x:Key="T" TargetType="Button"><Border Opacity="0.5"/></ControlTemplate></Grid.Resources></Grid>') -Source 's').Count | Should -Be 1
        @(Get-OpacityViolation -Text ($strHead + '<Border Background="{DynamicResource MahApps.Brushes.Accent}" Opacity="0.5"/></Grid>') -Source 's').Count | Should -Be 1
        @(Get-OpacityViolation -Text ($strHead + '<Border Background="#0078D4" Opacity="0.5"/></Grid>') -Source 's').Count | Should -Be 1
        @(Get-OpacityViolation -Text ($strHead + '<Border Background="{DynamicResource MahApps.Brushes.Gray10}" Opacity="0.5"/></Grid>') -Source 's').Count | Should -Be 0
        @(Get-OpacityViolation -Text ($strHead + '<Grid.Resources><Style x:Key="S" TargetType="Button"><Setter Property="Height" Value="28"/></Style></Grid.Resources></Grid>') -Source 's').Count | Should -Be 0
    }

    It 'flags a brush resource that is not in the allow list, or has another value' {
        $strHead = '<ResourceDictionary ' + $script:strXamlHead + '>'
        $hashAllow = @{ 'MahApps.Brushes.TextBox.Border' = '#7F7F7F' }
        @(Get-ResourceBrushViolation -Text ($strHead + '<SolidColorBrush x:Key="MahApps.Brushes.TextBox.Border" Color="#7F7F7F"/></ResourceDictionary>') -Source 's' -Allow $hashAllow).Count | Should -Be 0
        @(Get-ResourceBrushViolation -Text ($strHead + '<SolidColorBrush x:Key="MahApps.Brushes.TextBox.Border" Color="#123456"/></ResourceDictionary>') -Source 's' -Allow $hashAllow).Count | Should -Be 1
        @(Get-ResourceBrushViolation -Text ($strHead + '<SolidColorBrush x:Key="Other" Color="Orange"/></ResourceDictionary>') -Source 's' -Allow $hashAllow).Count | Should -Be 1
        @(Get-ResourceBrushViolation -Text ($strHead + '<SolidColorBrush x:Key="Other" Color="{DynamicResource MahApps.Colors.Accent}"/></ResourceDictionary>') -Source 's' -Allow $hashAllow).Count | Should -Be 0
    }

    It 'requires Pester 5.1.0 in every test file, read from the syntax tree of the script' {
        $arrFile = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:strRepoRoot -ChildPath 'Tests') -Filter '*.Tests.ps1' -File)
        $arrFile.Count | Should -BeGreaterOrEqual 8
        $arrBad = foreach ($objFile in $arrFile) { if (-not (Test-PesterRequirement -Path $objFile.FullName)) { $objFile.Name } }
        @($arrBad) | Should -BeNullOrEmpty
    }

    It 'flags a script that has no Pester requirement, an older one, or another module' {
        $strTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('themeguard-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            [System.IO.File]::WriteAllText($strTemp, "Describe 'x' { }`n")
            Test-PesterRequirement -Path $strTemp | Should -BeFalse
            [System.IO.File]::WriteAllText($strTemp, "#Requires -Modules Pester`nDescribe 'x' { }`n")
            Test-PesterRequirement -Path $strTemp | Should -BeFalse
            [System.IO.File]::WriteAllText($strTemp, "#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }`nDescribe 'x' { }`n")
            Test-PesterRequirement -Path $strTemp | Should -BeFalse
            [System.IO.File]::WriteAllText($strTemp, "#Requires -Modules @{ ModuleName = 'Other'; ModuleVersion = '5.1.0' }`nDescribe 'x' { }`n")
            Test-PesterRequirement -Path $strTemp | Should -BeFalse
            [System.IO.File]::WriteAllText($strTemp, "#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }`nDescribe 'x' { }`n")
            Test-PesterRequirement -Path $strTemp | Should -BeTrue
        }
        finally { Remove-Item -LiteralPath $strTemp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Titles are in Title Case (d)' {
    BeforeAll {
        $script:arrViewTitle = @('Device List', 'Device', 'Applications', 'Updates', 'Collections', 'Problems')
        $script:hashTitle = Get-UiTitleTable -Text @($script:arrOwnXamlDoc | ForEach-Object { $_.Text }) -ViewTitle $script:arrViewTitle
        $script:arrDocFile = @(Get-Item -LiteralPath (Join-Path -Path $script:strRepoRoot -ChildPath 'README.md')) + @(Get-ChildItem -LiteralPath (Join-Path -Path $script:strRepoRoot -ChildPath 'docs') -Filter '*.md' -File -Recurse)
    }

    It 'recognizes Title Case' {
        Test-TitleCase 'Device List' | Should -BeTrue
        Test-TitleCase 'Add to Collection...' | Should -BeTrue
        Test-TitleCase 'Install Selected Pending Updates...' | Should -BeTrue
        Test-TitleCase 'Last Active (UTC)' | Should -BeTrue
        Test-TitleCase 'Export JSON' | Should -BeTrue
        Test-TitleCase 'Device Inspector v1.2.3' | Should -BeTrue
        Test-TitleCase 'Device inspector v1.2.3' | Should -BeFalse
        Test-TitleCase 'Device list' | Should -BeFalse
        Test-TitleCase 'Open log file' | Should -BeFalse
        Test-TitleCase 'Add to collection...' | Should -BeFalse
        Test-TitleCase 'enable Actions' | Should -BeFalse
    }

    It 'skips bindings and the words On and Off' {
        $strXaml = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Button Content="{Binding Name}"/><Button Content="On"/><Button Content="Off"/><Button Content="Run Test"/><CheckBox Content="enable it"/><MenuItem Header="remove it..."/></Grid>'
        $arrTitle = @(Get-XamlTitle -Text $strXaml)
        $arrTitle.Count | Should -Be 3
        $arrTitle | Should -Contain 'Run Test'
        $arrTitle | Should -Contain 'enable it'
        $arrTitle | Should -Contain 'remove it...'
    }

    It 'has Title Case for every button, header, menu item, check box, field label and window title in <_.Source>' -ForEach $script:arrOwnXamlDocD {
        $arrBad = @(Get-XamlTitle -Text $_.Text | Where-Object { -not (Test-TitleCase $_) })
        $arrBad | Should -BeNullOrEmpty
    }

    It 'finds titles to check in the main window and the dialogs' {
        $intCount = 0
        foreach ($objDoc in $script:arrOwnXamlDoc) { $intCount += @(Get-XamlTitle -Text $objDoc.Text).Count }
        $intCount | Should -BeGreaterThan 60
        @(Get-XamlTitle -Text $script:objMainDoc.Text).Count | Should -BeGreaterThan 40
    }

    It 'has Title Case in the title of every message box and picker of the script' {
        $objAst = Get-ScriptAst -Path $script:strShellPath
        $arrCall = @(Get-AstCommand -Ast $objAst -Name @('Show-ThemedMessage', 'Show-CollectionPickerDialog'))
        $arrCall.Count | Should -BeGreaterThan 10
        $arrBad = foreach ($objCall in $arrCall) {
            $strTitle = Get-CommandParameterValue -Command $objCall -Name 'Title'
            if (-not $strTitle) { 'line {0}: no Title' -f $objCall.Extent.StartLineNumber; continue }
            if ($strTitle -notmatch "^'([^']*)'$") { 'line {0}: the title is not a fixed text: {1}' -f $objCall.Extent.StartLineNumber, $strTitle; continue }
            if (-not (Test-TitleCase $Matches[1])) { $Matches[1] }
        }
        @($arrBad) | Should -BeNullOrEmpty
    }

    It 'sets the title of the action confirmation in Title Case through ConvertTo-TitleCaseText' {
        $objAst = Get-ScriptAst -Path $script:strShellPath
        $objFunction = Get-AstFunction -Ast $objAst -Name 'Show-ActionConfirmDialog'
        $objFunction | Should -Not -BeNullOrEmpty
        $objFunction.Extent.Text | Should -Match '\$dlg\.Title\s*=\s*ConvertTo-TitleCaseText\s+\$Title'
        $objResult = Get-AstFunction -Ast $objAst -Name 'Show-ActionResultNotice'
        $objResult.Extent.Text | Should -Match '\$dlg\.Title\s*=\s*ConvertTo-TitleCaseText\s+\$Title'
    }

    It 'turns each action name into a Title Case window title' {
        $objAst = Get-ScriptAst -Path $script:strShellPath
        $objFunction = Get-AstFunction -Ast $objAst -Name 'ConvertTo-TitleCaseText'
        $objFunction | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($objFunction.Extent.Text))
        $hashExpected = [ordered]@{
            'Client policy update'            = 'Client Policy Update'
            'Full hardware inventory'         = 'Full Hardware Inventory'
            'Corrupt-inventory repair'        = 'Corrupt-Inventory Repair'
            'Check 32-bit entries'            = 'Check 32-bit Entries'
            'Remove from collection'          = 'Remove from Collection'
            'Add to collection'               = 'Add to Collection'
            'Install selected pending updates' = 'Install Selected Pending Updates'
            'Uninstall application'           = 'Uninstall Application'
            'Action result'                   = 'Action Result'
            ''                                = ''
        }
        foreach ($strName in $hashExpected.Keys) {
            (ConvertTo-TitleCaseText $strName) | Should -BeExactly $hashExpected[$strName]
            Test-TitleCase (ConvertTo-TitleCaseText $strName) | Should -BeTrue
        }
        # Every action name of the script goes through it: a fixed name, or a name that the module builds.
        $arrCall = @(Get-AstCommand -Ast $objAst -Name 'Invoke-DeviceAction')
        $arrCall.Count | Should -BeGreaterOrEqual 6
    }

    It 'uses the term SMS Provider and never the lower case form in the XAML text' {
        $arrText = foreach ($objDoc in $script:arrOwnXamlDoc) { Get-XamlUiText -Text $objDoc.Text }
        @($arrText | Where-Object { $_ -cmatch 'SMS provider' }) | Should -BeNullOrEmpty
    }

    It 'writes the label of the window in the case of the window in the README and the guide' {
        $script:hashTitle.Count | Should -BeGreaterThan 40
        $script:hashTitle['device list'] | Should -Be 'Device List'
        $script:hashTitle['open log file'] | Should -Be 'Open Log File'
        $script:hashTitle['enable actions'] | Should -Be 'Enable Actions'
        $script:arrDocFile.Count | Should -BeGreaterThan 5
        $arrBad = foreach ($objFile in $script:arrDocFile) { Get-DocLabelViolation -Text (Get-Content -LiteralPath $objFile.FullName -Raw) -Name $objFile.Name -Title $script:hashTitle }
        @($arrBad) | Should -BeNullOrEmpty
        $arrHeading = foreach ($objFile in $script:arrDocFile) { Get-DocHeadingViolation -Text (Get-Content -LiteralPath $objFile.FullName -Raw) -Name $objFile.Name -Title $script:hashTitle }
        @($arrHeading) | Should -BeNullOrEmpty
    }

    It 'flags a heading of a page that has another case than the window' {
        $hashTitle = @{ 'running actions' = 'Running Actions' }
        @(Get-DocHeadingViolation -Text "## Running actions`n## Running Actions`n## Other words`n" -Name 'p.md' -Title $hashTitle).Count | Should -Be 1
    }

    It 'flags a bold label of a page that has another case than the window' {
        $hashTitle = @{ 'open log file' = 'Open Log File'; 'device' = 'Device' }
        $strPage = "Select **Open log file** at the right.`nSelect **Open Log File**.`nThe **Device** panel and **device list** stay.`n"
        $arrBad = @(Get-DocLabelViolation -Text $strPage -Name 'p.md' -Title $hashTitle)
        $arrBad.Count | Should -Be 1
        $arrBad[0] | Should -Match 'p\.md:1: Open log file should be Open Log File'
    }
}

Describe 'No raw exception text in the window (e)' {
    It 'finds the text writes of the script' {
        $objAst = Get-ScriptAst -Path $script:strShellPath
        $arrAssign = @($objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Left.Member.Value -eq 'Text' }, $true))
        $arrAssign.Count | Should -BeGreaterThan 20
        @(Get-AstCommand -Ast $objAst -Name @('Add-LogLine', 'Set-StatusText', 'Show-ThemedMessage')).Count | Should -BeGreaterThan 40
    }

    It 'shows no exception text in a log line, a status text, a message box or a Text property of start-deviceinspector.ps1' {
        $arrBad = @(Get-UiExceptionText -Path $script:strShellPath)
        $arrBad | Should -BeNullOrEmpty
    }

    It 'assigns no exception text to a Text property in a catch block of start-deviceinspector.ps1' {
        $arrAssign = @(Get-CatchTextAssignment -Path $script:strShellPath)
        $arrBad = @($arrAssign | Where-Object { $_.Right -match $script:strExceptionPattern } | ForEach-Object { '{0}: {1}' -f $_.Line, $_.Text })
        $arrBad | Should -BeNullOrEmpty
    }

    It 'writes exception text only to the log file (-Quiet) in start-deviceinspector.ps1' {
        $objAst = Get-ScriptAst -Path $script:strShellPath
        $arrCall = @(Get-AstCommand -Ast $objAst -Name 'Write-Log')
        $arrCall.Count | Should -BeGreaterThan 0
        $intChecked = 0
        $arrBad = foreach ($objCall in $arrCall) {
            if ($objCall.Extent.Text -notmatch '\$_(?![\w])|Exception\.Message|ErrorMsg|\$err\b|\$Message\b') { continue }
            $intChecked++
            $arrQuiet = @($objCall.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Quiet' })
            if ($arrQuiet.Count -eq 0) { '{0}: {1}' -f $objCall.Extent.StartLineNumber, $objCall.Extent.Text }
        }
        $intChecked | Should -BeGreaterOrEqual 5
        @($arrBad) | Should -BeNullOrEmpty
    }

    It 'treats a background exception with the marker Data RawText as a message of the tool, in every catch of the script' {
        $objAst = Get-ScriptAst -Path $script:strShellPath
        $arrCatch = @($objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] -and $n.Body.Extent.Text -match 'State\.ErrorMsg\s*=' }, $true))
        $arrCatch.Count | Should -BeGreaterOrEqual 5
        $arrBad = foreach ($objCatch in $arrCatch) {
            $strText = $objCatch.Body.Extent.Text
            if ($strText -notmatch 'Data\.Contains\(''RawText''\)' -or $strText -notmatch 'State\.ToolMessage\s*=\s*\$State\.ErrorMsg' -or $strText -notmatch 'State\.ErrorMsg\s*=\s*\[string\]\$_\.Exception\.Data\[''RawText''\]') { 'line {0}: {1}' -f $objCatch.Extent.StartLineNumber, $strText }
        }
        @($arrBad) | Should -BeNullOrEmpty
        # The windows that show a failure of such a read show the message of the tool when there is one.
        $objAst.Extent.Text | Should -Match 'if \(\$State\.ToolMessage\) \{ \[string\]\$State\.ToolMessage \} else'
        ([regex]::Matches($objAst.Extent.Text, 'if \(\$State\.ToolMessage\)')).Count | Should -BeGreaterOrEqual 3
    }

    It 'has a Write-ErrorLog that writes to the log file only, and the script uses it for each failure' {
        $objAst = Get-ScriptAst -Path $script:strShellPath
        $objFunction = Get-AstFunction -Ast $objAst -Name 'Write-ErrorLog'
        $objFunction | Should -Not -BeNullOrEmpty
        $arrWrite = @(Get-AstCommand -Ast $objFunction -Name 'Write-Log')
        $arrWrite.Count | Should -Be 1
        $arrWrite[0].Extent.Text | Should -Match '-Quiet'
        $arrWrite[0].Extent.Text | Should -Match '-Level ERROR'
        @(Get-AstCommand -Ast $objAst -Name 'Write-ErrorLog').Count | Should -BeGreaterOrEqual 9
    }

    It 'flags exception text in a UI call and in a Text property' {
        $strTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('themeguard-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            $arrBadCall = @('try { 1 } catch { Add-LogLine ($_.Exception.Message) }', 'try { 1 } catch { Show-ThemedMessage -Message $script:State.ErrorMsg }', "Add-LogLine 'The step failed.'")
            [System.IO.File]::WriteAllText($strTemp, ($arrBadCall -join "`n"))
            @(Get-UiExceptionText -Path $strTemp).Count | Should -Be 2
            $arrBadText = @('$txtStatus.Text = $state.ErrorMessage', '$txtLog.Text = $r.Detail', '$txtLog.Text = $e.Error', "`$txtLog.Text = 'Ready.'", 'Set-StatusText $r.Detail', '$txtLog.Text = ($x | ForEach-Object { $_ })', '$txtLog.Text = $e.DetailMsg')
            [System.IO.File]::WriteAllText($strTemp, ($arrBadText -join "`n"))
            @(Get-UiExceptionText -Path $strTemp).Count | Should -Be 6
        }
        finally { Remove-Item -LiteralPath $strTemp -Force -ErrorAction SilentlyContinue }
    }

    It 'finds a Text assignment in a catch block only' {
        $strTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('themeguard-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            $arrLine = @('try { 1 } catch { $x.Text = $_.Exception.Message }', "try { 1 } catch { `$x.Text = 'The step failed.' }", '$y.Text = $_')
            [System.IO.File]::WriteAllText($strTemp, ($arrLine -join "`n"))
            $arrAssign = @(Get-CatchTextAssignment -Path $strTemp)
            $arrAssign.Count | Should -Be 2
            @($arrAssign | Where-Object { $_.Right -match $script:strExceptionPattern }).Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $strTemp -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps the exception text out of the Summary, the steps and the problems that the modules build' {
        foreach ($strPath in $script:strActionsPath, $script:strCommonPath) {
            @(Get-ModuleExceptionLeak -Path $strPath) | Should -BeNullOrEmpty -Because (Split-Path -Leaf $strPath)
        }
    }

    It 'flags exception text in a Summary, in a step and in a problem, and passes fixed text and Detail' {
        $strTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('themeguard-' + [guid]::NewGuid().ToString('N') + '.psm1')
        try {
            $arrBad = @(
                'function A { try { 1 } catch { $r = [pscustomobject]@{ Summary = ("Failed: {0}" -f $_.Exception.Message) } } }',
                'function B { try { 1 } catch { $listStep.Add(("Failed: {0}" -f $_.Exception.Message)) } }',
                'function C { try { 1 } catch { $Problems.Add(("Site: {0}" -f $_.Exception.Message)) } }',
                'function D { $r.Summary = "Failed: $($ex.Message)" }',
                'function E { New-Record -Summary ("Failed: {0}" -f $_.Exception.Message) }',
                'function F { $strSummary = "Failed: $_" }'
            )
            [System.IO.File]::WriteAllText($strTemp, ($arrBad -join "`n"))
            @(Get-ModuleExceptionLeak -Path $strTemp).Count | Should -Be 6
            $arrGood = @(
                'function A { try { 1 } catch { $listDetail.Add($_.Exception.Message); $r = [pscustomobject]@{ Summary = "The client does not answer. The action log has the reason."; Detail = @($listDetail) } } }',
                'function B { $listStep.Add(("TriggerSchedule returned {0}." -f $objReturnValue)) }',
                'function C { try { 1 } catch { $Problems.Add("Site: the read failed. The log file has the reason."); $ProblemDetail.Add($_.Exception.Message) } }'
            )
            [System.IO.File]::WriteAllText($strTemp, ($arrGood -join "`n"))
            @(Get-ModuleExceptionLeak -Path $strTemp).Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $strTemp -Force -ErrorAction SilentlyContinue }
    }
}
