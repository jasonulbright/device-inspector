#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Tooltip guard. It parses MainWindow.xaml and the XAML here-strings of the start script, and checks that each control
# of the audit list has a tooltip. It creates no WPF control, opens no window and needs no ConfigMgr.
#
# Rules:
#   1. Each x:Name of the audit list exists once in the XAML of the app, and the control has a ToolTip attribute.
#   2. The tooltip is not empty, holds ASCII only, ends with a period and has at most 200 characters.
#
# A control that gets its tooltip from code (a context menu item, or a button that shows the reason it is off) is not in the list.

BeforeAll {
    $script:TtRepoRoot = Split-Path -Parent $PSScriptRoot
    $script:TtNamespace = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
    $script:TtKeyNamespace = 'http://schemas.microsoft.com/winfx/2006/xaml'
    $script:TtMaxLength = 200

    # The controls of the audit (Q-103): x:Name values of controls that had no tooltip.
    $script:TtAudited = @(
        'txtDevice', 'txtListName', 'txtListCollection', 'txtAppFilter', 'btnCancelWork',
        'btnCatConnection', 'btnCatAbout', 'txtSmsProvider', 'txtSiteCode',
        'btnActionRun', 'btnActionDryRun', 'btnWait', 'btnCloseAnyway'
    )

    # Every XAML document of the app: MainWindow.xaml and the XAML here-strings of the start script.
    function Get-TtDocument {
        $docs = @()
        $xamlPath = Join-Path $script:TtRepoRoot 'MainWindow.xaml'
        $docs += @{ Source = 'MainWindow.xaml'; Text = (Get-Content -LiteralPath $xamlPath -Raw) }
        $scriptPath = Join-Path $script:TtRepoRoot 'start-deviceinspector.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput((Get-Content -LiteralPath $scriptPath -Raw), [ref]$tokens, [ref]$errors)
        $nodes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -in 'SingleQuotedHereString', 'DoubleQuotedHereString' }, $true)
        $i = 0
        foreach ($n in @($nodes)) {
            if ($n.Value -notmatch ('^\s*<[^>]*xmlns="' + [regex]::Escape($script:TtNamespace) + '"')) { continue }
            $i++
            $docs += @{ Source = ('start-deviceinspector.ps1 here-string {0}' -f $i); Text = $n.Value }
        }
        return $docs
    }

    # The elements with a given x:Name in a XAML text.
    function Get-TtElement {
        param([string]$Text, [string]$Name)
        [xml]$x = $Text
        $found = @()
        foreach ($el in @($x.SelectNodes('//*'))) {
            $n = $el.GetAttribute('Name', $script:TtKeyNamespace)
            if (-not $n) { $n = $el.GetAttribute('Name') }
            if ($n -eq $Name) { $found += $el }
        }
        return $found
    }

    # The problems of the tooltip text of one control.
    function Get-TtTextProblem {
        param([string]$Name, [AllowNull()][string]$Tip)
        $found = New-Object System.Collections.Generic.List[string]
        if ([string]::IsNullOrWhiteSpace($Tip)) { [void]$found.Add(('{0}: the tooltip is missing or empty' -f $Name)); return @($found) }
        if ($Tip -match '[^\x20-\x7E]') { [void]$found.Add(('{0}: the tooltip holds a character that is not ASCII' -f $Name)) }
        if (-not $Tip.TrimEnd().EndsWith('.')) { [void]$found.Add(('{0}: the tooltip does not end with a period' -f $Name)) }
        if ($Tip.Length -gt $script:TtMaxLength) { [void]$found.Add(('{0}: the tooltip has {1} characters, the limit is {2}' -f $Name, $Tip.Length, $script:TtMaxLength)) }
        return @($found)
    }
}

Describe 'Tooltip guard' {
    It 'finds the main window and the dialog here-strings (the scan is not empty)' {
        $docs = @(Get-TtDocument)
        $docs.Count | Should -BeGreaterThan 1
        $docs[0].Source | Should -Be 'MainWindow.xaml'
    }

    It 'finds each audited control once' {
        $docs = @(Get-TtDocument)
        $v = @()
        foreach ($name in $script:TtAudited) {
            $count = 0
            foreach ($d in $docs) { $count += @(Get-TtElement -Text $d.Text -Name $name).Count }
            if ($count -ne 1) { $v += ('{0}: found {1} times, expected 1' -f $name, $count) }
        }
        ($v -join [Environment]::NewLine) | Should -BeNullOrEmpty
    }

    It 'gives each audited control a tooltip of ASCII text that ends with a period' {
        $docs = @(Get-TtDocument)
        $v = @()
        foreach ($name in $script:TtAudited) {
            foreach ($d in $docs) {
                foreach ($el in @(Get-TtElement -Text $d.Text -Name $name)) {
                    $v += @(Get-TtTextProblem -Name ('{0} ({1})' -f $name, $d.Source) -Tip $el.GetAttribute('ToolTip'))
                }
            }
        }
        ($v -join [Environment]::NewLine) | Should -BeNullOrEmpty
    }

    It 'reports a missing, a non-ASCII, an unfinished and a long tooltip (the check itself works)' {
        @(Get-TtTextProblem -Name 'a' -Tip '').Count | Should -Be 1
        @(Get-TtTextProblem -Name 'a' -Tip ('Caf' + [char]0xE9 + '.')).Count | Should -Be 1
        @(Get-TtTextProblem -Name 'a' -Tip 'No period').Count | Should -Be 1
        @(Get-TtTextProblem -Name 'a' -Tip (('x' * 201) + '.')).Count | Should -Be 1
        @(Get-TtTextProblem -Name 'a' -Tip 'Good tip.').Count | Should -Be 0
    }
}
