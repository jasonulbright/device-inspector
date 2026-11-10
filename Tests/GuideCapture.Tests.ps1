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
    # The names of the lab machines, the lab domain, the lab site code and the lab account. They are built
    # from parts, so this file does not hold them either.
    $script:LabNames = @(('C', 'M', '0', '1'), ('C', 'LIENT', '0', '1'), ('D', 'C', '0', '1'), ('con', 'toso'), ('M', 'C', 'M'), ('lab', 'admin')) | ForEach-Object { $_ -join '' }
    $script:LabNamePattern = '(?i)\b(' + (($script:LabNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'

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

    It 'has no lab machine, lab domain, lab site code or lab account name in <File>' -ForEach $script:CaptureFiles {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir $File))
        @([regex]::Matches($text, $script:LabNamePattern) | ForEach-Object { $_.Value }) | Should -BeNullOrEmpty
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

    It 'quotes the app folder name in the command line of the scheduled task' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir 'Invoke-GuideCapture.ps1'))
        $text | Should -Match '-App `"\$a`"'
        $text | Should -Not -Match '-App \$a\b'
    }

    It 'stops the app on the lab computer and reports a failed cleanup of C:\guide' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:CaptureDir 'Invoke-GuideCapture.ps1'), [ref]$null, [ref]$null)
        $try = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally }, $false))[0]
        $try | Should -Not -BeNullOrEmpty
        $finally = $try.Finally.Extent.Text
        # The finally block runs after a timeout and after a failure. It stops the app before it removes the folder.
        $finally | Should -Match 'Invoke-Command \$session \$stopCapture'
        $finally.IndexOf('$stopCapture') | Should -BeLessThan $finally.IndexOf('Remove-Item C:\guide')
        $finally | Should -Match 'Remove-Item C:\\guide -Recurse -Force -ErrorAction Stop'
        $finally | Should -Not -Match 'Remove-Item C:\\guide[^\r\n]*SilentlyContinue'
        $finally | Should -Match 'The cleanup of C:\\guide on the lab computer failed'
        $stop = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$stopCapture' }, $true))[0]
        $stop | Should -Not -BeNullOrEmpty
        $stop.Right.Extent.Text | Should -Match 'Stop-ScheduledTask'
        $stop.Right.Extent.Text | Should -Match 'Stop-Process'
        $stop.Right.Extent.Text | Should -Match 'throw'
    }

    It 'makes every image of the guide' {
        $steps = (Get-ChildItem -LiteralPath $script:CaptureDir -Filter 'steps-*.ps1' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $missing = foreach ($png in Get-ChildItem -LiteralPath $script:ImageDir -Filter '*.png') {
            if ($steps -notmatch ("'{0}'" -f [regex]::Escape($png.BaseName))) { $png.Name }
        }
        @($missing) | Should -BeNullOrEmpty
    }

    It 'documents the one command that retakes every capture in the guide index' {
        $index = [System.IO.File]::ReadAllText((Join-Path $script:Root 'docs\index.md'))
        $index | Should -Match '(?m)^## Retake the captures'
        $index | Should -Match 'tools\\guide-capture\\Invoke-GuideCapture\.ps1'
    }
}

Describe 'Repository text' {
    It 'has no lab machine, lab domain, lab site code or lab account name in a tracked text file of the repository' {
        # Only the files in git are published. Untracked local files (logs, lab notes) are not scanned.
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'git is not installed'; return }
        $tracked = @(& git -C $script:Root -c core.quotepath=off ls-files 2>$null)
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'the folder is not a git work tree'; return }
        # The vendored Lib folder is the copy of another repository and is left out.
        $extensions = '.ps1', '.psm1', '.psd1', '.md', '.xaml', '.yml', '.yaml', '.json', '.txt'
        $files = @($tracked | Where-Object { $extensions -contains [System.IO.Path]::GetExtension($_) -and $_ -notmatch '^Lib/' })
        $files.Count | Should -BeGreaterThan 10
        $found = foreach ($f in $files) {
            $path = Join-Path $script:Root $f
            # A tracked file that is deleted in the work tree has no text to scan.
            if (-not (Test-Path -LiteralPath $path)) { continue }
            foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($path), $script:LabNamePattern)) { '{0}: {1}' -f $f, $m.Value }
        }
        @($found) | Should -BeNullOrEmpty
    }
}
