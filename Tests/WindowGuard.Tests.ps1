#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# The guard that keeps window tests from opening a window unless the opt-in is set. This file opens no window.
# It checks the guard function with injected values, and checks that every test file that can open a window uses the guard.

BeforeAll {
    . "$PSScriptRoot\WindowHarness.ps1"
}

Describe 'Test-WindowTestsAllowed' {
    It 'allows the window tests with the opt-in 1' {
        $g = Test-WindowTestsAllowed -OptIn '1'
        $g.Allowed | Should -BeTrue
        $g.Reason | Should -Be ''
    }

    It 'refuses the window tests when the opt-in is <Case>' -ForEach @(
        @{ Case = 'empty'; OptIn = '' }, @{ Case = 'null'; OptIn = $null }, @{ Case = '0'; OptIn = '0' }, @{ Case = 'true'; OptIn = 'true' }, @{ Case = '11'; OptIn = '11' }
    ) {
        $g = Test-WindowTestsAllowed -OptIn $OptIn
        $g.Allowed | Should -BeFalse
        $g.Reason | Should -Be 'SUITE_ALLOW_WINDOW_TESTS is not 1'
    }

    It 'reads the opt-in from the environment by default' {
        $g = Test-WindowTestsAllowed
        $g.Allowed | Should -Be ($env:SUITE_ALLOW_WINDOW_TESTS -eq '1')
    }
}

Describe 'Test-WindowTestsAllowed signature' {
    It 'has no ComputerName parameter' {
        (Get-Command Test-WindowTestsAllowed).Parameters.ContainsKey('ComputerName') | Should -BeFalse
    }

    It 'has only the OptIn parameter of its own' {
        $own = @((Get-Command Test-WindowTestsAllowed).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
        $own | Should -Be @('OptIn')
    }

    It 'decides on the opt-in only' {
        (Test-WindowTestsAllowed -OptIn '1').Allowed | Should -BeTrue
        (Test-WindowTestsAllowed -OptIn '0').Allowed | Should -BeFalse
    }
}

Describe 'Window test files' {
    It 'uses the guard in <Name>, which can open a window' -ForEach @(
        Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File |
            Where-Object { $_.Name -ne 'WindowGuard.Tests.ps1' -and (Select-String -LiteralPath $_.FullName -Pattern 'Invoke-WpfSta|New-WpfWindow|ShowDialog|\.Show\(\)' -Quiet) } |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        [System.IO.File]::ReadAllText($Path) | Should -Match 'Test-WindowTestsAllowed'
        [System.IO.File]::ReadAllText($Path) | Should -Match '-Skip:\(-not \$script:WindowGuard\.Allowed\)'
    }

    It 'finds at least one test file that can open a window' {
        @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Where-Object { (Select-String -LiteralPath $_.FullName -Pattern 'Invoke-WpfSta' -Quiet) }).Count | Should -BeGreaterThan 0
    }

    It 'creates windows only inside an if statement that tests the guard' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Window.Tests.ps1'), [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WpfSta' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            # An It block runs only when its Describe is not skipped, so a call inside a skipped Describe is guarded too.
            $guarded = $false
            for ($p = $c.Parent; $p; $p = $p.Parent) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst] -and ($p.Clauses | Where-Object { $_.Item1.Extent.Text -match 'WindowGuard\.Allowed' })) { $guarded = $true; break }
                if ($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Describe' -and $p.Extent.Text -match '-Skip:\(-not \$script:WindowGuard\.Allowed\)') { $guarded = $true; break }
            }
            $guarded | Should -BeTrue -Because ('line {0} opens a window outside the guard' -f $c.Extent.StartLineNumber)
        }
    }
    It 'closes a session that was never opened without an error' {
        { Close-WpfSession } | Should -Not -Throw
    }
}

Describe 'Window cleanup' {
    BeforeAll {
        # The nodes that open a window: Open-TestWindow, and a Show or ShowDialog call on a window object.
        function Get-OpeningNode {
            param($Ast)
            @($Ast.FindAll({
                        param($n)
                        ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Open-TestWindow') -or
                        ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -in 'Show', 'ShowDialog')
                    }, $true))
        }
        # True when the node is in the body of a try statement that has a finally block, or when a later statement of the
        # same block is such a try statement (the window is opened, then the try that closes it starts).
        function Test-CleanedUp {
            param($Node)
            for ($p = $Node.Parent; $p; $p = $p.Parent) {
                if ($p -is [System.Management.Automation.Language.TryStatementAst] -and $p.Finally -and $p.Body.Extent.StartOffset -le $Node.Extent.StartOffset -and $p.Body.Extent.EndOffset -ge $Node.Extent.EndOffset) { return $true }
            }
            $stmt = $Node
            while ($stmt.Parent -and $stmt.Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -and $stmt.Parent -isnot [System.Management.Automation.Language.NamedBlockAst]) { $stmt = $stmt.Parent }
            if (-not $stmt.Parent) { return $false }
            foreach ($s in @($stmt.Parent.Statements)) {
                if ($s.Extent.StartOffset -gt $stmt.Extent.StartOffset -and $s -is [System.Management.Automation.Language.TryStatementAst] -and $s.Finally) { return $true }
            }
            return $false
        }
        function Get-UncleanedOpening {
            param([string]$Text)
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
            @(Get-OpeningNode $ast | Where-Object { -not (Test-CleanedUp $_) } | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Extent.Text })
        }
    }

    It 'closes the windows that a call left open, in the finally block of Invoke-WpfSta' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'WindowHarness.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-WpfSta' }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $tries = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally }, $true))
        @($tries | Where-Object { $_.Finally.Extent.Text -match 'Close-SuiteOpenWindow' }).Count | Should -BeGreaterThan 0
    }

    It 'opens no window outside a try statement with a finally block in <Name>' -ForEach @(
        Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
            Where-Object { $_.Name -notin 'WindowHarness.ps1', 'WindowGuard.Tests.ps1' } |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $bad = Get-UncleanedOpening -Text ([System.IO.File]::ReadAllText($Path))
        $bad | Should -BeNullOrEmpty
    }

    It 'finds an opening that is not cleaned up (bad sample) and accepts the cleaned ones' {
        @(Get-UncleanedOpening -Text '$w = Open-TestWindow -XamlPath x; $w.Close()').Count | Should -Be 1
        @(Get-UncleanedOpening -Text '$d.Show(); $d.Close()').Count | Should -Be 1
        @(Get-UncleanedOpening -Text "`$w = Open-TestWindow -XamlPath x`ntry { 1 } finally { `$w.Close() }").Count | Should -Be 0
        @(Get-UncleanedOpening -Text 'try { $d.Show() } finally { $d.Close() }').Count | Should -Be 0
        @(Get-UncleanedOpening -Text 'try { 1 } finally { $d.Show() }').Count | Should -Be 1
    }
}

Describe 'Disabled controls in the contrast rules' {
    BeforeAll {
        . "$PSScriptRoot\ContrastRules.ps1"
        function New-View {
            param([double]$Enabled, [double]$Disabled, $EnabledBorder = 4.0, $DisabledBorder = 1.2)
            [pscustomobject]@{ Text = @(); TitleBar = $null; Interactive = @([pscustomobject]@{ Name = 'btnX'; EnabledText = $Enabled; DisabledText = $Disabled; EnabledBorder = $EnabledBorder; DisabledBorder = $DisabledBorder; EnabledDetail = ''; DisabledDetail = '' }) }
        }
    }

    It 'exempts a dimmed disabled control from the 4.5:1 text and 3:1 border rules (WCAG 1.4.3)' {
        @(Get-ContrastViolation -Views @(New-View -Enabled 15 -Disabled 2.75)).Count | Should -Be 0
    }

    It 'flags a disabled control that does not look dimmed' {
        @(Get-ContrastViolation -Views @(New-View -Enabled 15 -Disabled 14)) -join ';' | Should -Match 'btnX:DisabledNotDimmed'
    }

    It 'flags a disabled control whose label vanishes' {
        @(Get-ContrastViolation -Views @(New-View -Enabled 15 -Disabled 1.2)) -join ';' | Should -Match 'btnX:DisabledUnreadable'
    }

    It 'still applies the enabled text and border rules' {
        (@(Get-ContrastViolation -Views @(New-View -Enabled 4.0 -Disabled 2.0 -EnabledBorder 2.0)) -join ';') | Should -Match 'btnX:EnabledText = 4.*btnX:EnabledBorder = 2|btnX:EnabledBorder = 2.*btnX:EnabledText = 4'
    }
}
