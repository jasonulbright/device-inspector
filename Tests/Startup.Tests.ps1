#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Start-up without the Configuration Manager console: the message is plain text,
# the start script stops with exit code 2, and no raw exception reaches the user.

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
    $script:ShellPath = Join-Path $script:AppRoot 'start-deviceinspector.ps1'
}

Describe 'Test-DeviceInspectorConsole without the ConfigurationManager module' {
    BeforeEach {
        Mock Resolve-ConfigurationManagerModulePath { $null } -ModuleName DeviceInspectorCommon
    }

    It 'reports the console as not available with a plain message' {
        $r = Test-DeviceInspectorConsole
        $r.Available | Should -BeFalse
        $r.Path | Should -Be ''
        $r.Message | Should -BeLike 'The Configuration Manager console is not installed on this computer.*'
    }

    It 'writes no PowerShell error text such as a stack trace or exception type' {
        (Test-DeviceInspectorConsole).Message | Should -Not -Match 'Exception|at <ScriptBlock>|CategoryInfo|FullyQualifiedErrorId'
    }

    It 'makes Connect-InspectorSite throw the plain message and keep it as the raw text' {
        $err = $null
        # Connect-InspectorSite is a private function of the module.
        try { InModuleScope DeviceInspectorCommon { Connect-InspectorSite -SiteServer 'sms01.contoso.com' -SiteCode 'MCM' } } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.Message | Should -BeLike 'The Configuration Manager console is not installed*'
        $err.Data['RawText'] | Should -Be $err.Message
    }
}

Describe 'Test-DeviceInspectorConsole with the ConfigurationManager module' {
    It 'reports the console as available and gives the path' {
        Mock Resolve-ConfigurationManagerModulePath { 'C:\Fake\ConfigurationManager.psd1' } -ModuleName DeviceInspectorCommon
        $r = Test-DeviceInspectorConsole
        $r.Available | Should -BeTrue
        $r.Path | Should -Be 'C:\Fake\ConfigurationManager.psd1'
        $r.Message | Should -Be ''
    }
}

Describe 'Start script start-up order' {
    BeforeAll {
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ShellPath, [ref]$null, [ref]$null)
        $script:Text = Get-Content -LiteralPath $script:ShellPath -Raw
    }

    It 'checks the console after it imports the module and before it opens the window' {
        $import = $script:Text.IndexOf('Import-Module -Name $__modulePath')
        $check = $script:Text.IndexOf('Test-DeviceInspectorConsole')
        $load = $script:Text.IndexOf('XamlReader]::Load')
        $import | Should -BeGreaterThan 0
        $check | Should -BeGreaterThan $import
        $load | Should -BeGreaterThan $check
    }

    It 'stops with exit code 2 and shows the plain message when the console is missing' {
        $ifs = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match '__console\.Available' }, $true))
        $ifs.Count | Should -BeGreaterThan 0
        $body = $ifs[0].Clauses[0].Item2.Extent.Text
        $body | Should -Match 'Write-Warning -Message \$__console\.Message'
        $body | Should -Match 'MessageBox\]::Show\(\$__console\.Message'
        $body | Should -Match 'exit 2'
    }

    It 'shows no exception text in that branch' {
        $ifs = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match '__console\.Available' }, $true))
        $ifs[0].Clauses[0].Item2.Extent.Text | Should -Not -Match '\.Exception'
    }

    It 'relaunches itself in an STA thread before it loads WPF' {
        $sta = $script:Text.IndexOf("GetApartmentState() -ne 'STA'")
        $wpf = $script:Text.IndexOf('Add-Type -AssemblyName PresentationFramework')
        $sta | Should -BeGreaterThan 0
        $wpf | Should -BeGreaterThan $sta
    }
}
