#Requires -Modules Pester
# Static checks of the capture scripts in tools\guide-capture. The scripts run on a lab
# workstation and are never run here: this file only parses them. It opens no window.

BeforeDiscovery {
    $script:CaptureFiles = @('Invoke-GuideCapture.ps1', 'guilib.ps1', 'main.ps1', 'steps-guide.ps1', 'steps-console-missing.ps1') | ForEach-Object { @{ File = $_ } }
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:CaptureDir = Join-Path $script:Root 'tools\guide-capture'
    $script:ImageDir = Join-Path $script:Root 'docs\images'

    # The text of every string and comment token of a script.
    function Get-LiteralText {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        foreach ($t in $tokens) {
            if ($t.Kind -in 'Comment', 'StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable') { $t.Text }
        }
    }
}

Describe 'Capture scripts' {
    It 'has <File> and it parses without error' -ForEach $script:CaptureFiles {
        $path = Join-Path $script:CaptureDir $File
        Test-Path -LiteralPath $path | Should -BeTrue
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
    }

    It 'has no host name, address, domain name or account in the strings and comments of <File>' -ForEach $script:CaptureFiles {
        $path = Join-Path $script:CaptureDir $File
        $found = foreach ($text in @(Get-LiteralText -Path $path)) {
            # An IPv4 address, a dotted DNS name, a computer name of letters and a number, or a domain account.
            foreach ($m in [regex]::Matches($text, '\b\d{1,3}(\.\d{1,3}){3}\b|\b[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.(com|net|org|local|lan|corp|internal|test)\b|\b[A-Za-z]{2,}\d{2,}\b|\b[A-Za-z]+\\[A-Za-z]*admin\b')) {
                # Windows library names are not computer names.
                if ($m.Value -notin 'user32', 'kernel32') { $m.Value }
            }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'takes the lab computer, the account and the credential script from parameters' {
        $cmd = Get-Command (Join-Path $script:CaptureDir 'Invoke-GuideCapture.ps1')
        foreach ($name in 'CredentialScript', 'Target', 'LogonUser', 'SmsProvider', 'SiteCode', 'Device', 'SecondDevice') {
            $cmd.Parameters.ContainsKey($name) | Should -BeTrue -Because $name
            $mandatory = @($cmd.Parameters[$name].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory })
            $mandatory.Count | Should -Be 1 -Because "$name has no default value"
        }
    }

    It 'stops before it replaces an image when the run log has an error or an image is missing' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir 'Invoke-GuideCapture.ps1'))
        $text | Should -Match "-match 'ERROR'"
        $text | Should -Match 'No image was replaced'
        $text.IndexOf('No image was replaced') | Should -BeLessThan $text.IndexOf('Copy-Item $png.FullName')
    }

    It 'makes every image of the guide' {
        $steps = (Get-ChildItem -LiteralPath $script:CaptureDir -Filter 'steps-*.ps1' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $missing = foreach ($png in Get-ChildItem -LiteralPath $script:ImageDir -Filter '*.png') {
            $name = $png.BaseName
            # A fixed name, or a name that ends with the second device name (the prefix and $second).
            $prefix = $name -replace '-[^-]+$', ''
            if ($steps -notmatch ("'{0}'" -f [regex]::Escape($name)) -and $steps -notmatch ("'{0}-'\s*\+\s*\`$second" -f [regex]::Escape($prefix))) { $png.Name }
        }
        @($missing) | Should -BeNullOrEmpty
    }

    It 'documents the one command that retakes every capture in the guide index' {
        $index = [System.IO.File]::ReadAllText((Join-Path $script:Root 'docs\index.md'))
        $index | Should -Match '(?m)^## Retake the captures'
        $index | Should -Match 'tools\\guide-capture\\Invoke-GuideCapture\.ps1'
    }
}
