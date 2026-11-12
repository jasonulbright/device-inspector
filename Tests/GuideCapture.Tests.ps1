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
    # The default names that the public lab builder ships: the machines, the domain, the site code and the
    # 192.168.50.x addresses. They are public and can show in tracked files, guides and images.
    $script:PublicLabPattern = '(?i)^(CM01|DC01|CLIENT01|MCM|contoso\.com|[A-Za-z0-9-]+\.contoso\.com|192\.168\.50\.\d{1,3})$'
    # Values that stay private: the lab account and the file that holds the lab credential. They are built
    # from parts, so this file does not hold them either.
    $script:PrivateNames = @(('lab', 'admin'), ('lab-', 'credentials')) | ForEach-Object { $_ -join '' }
    $script:PrivateNamePattern = '(?i)\b(' + (($script:PrivateNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'

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

    It 'has no host name, address, domain name or account other than a lab builder default in the strings and comments of <File>' -ForEach $script:CaptureFiles {
        $path = Join-Path $script:CaptureDir $File
        $found = foreach ($text in @(Get-LiteralText -Path $path)) {
            # An IPv4 address, a dotted DNS name, a computer name of letters and a number, or a domain account.
            foreach ($m in [regex]::Matches($text, '\b\d{1,3}(\.\d{1,3}){3}\b|\b[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.(com|net|org|local|lan|corp|internal|test)\b|\b[A-Za-z]{2,}\d{2,}\b|\b[A-Za-z]+\\[A-Za-z]*admin\b')) {
                # Windows library names are not computer names. The lab builder defaults are public.
                if ($m.Value -notin 'user32', 'kernel32' -and $m.Value -notmatch $script:PublicLabPattern) { $m.Value }
            }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'has no lab account name or lab credential file name in <File>' -ForEach $script:CaptureFiles {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir $File))
        @([regex]::Matches($text, $script:PrivateNamePattern) | ForEach-Object { $_.Value }) | Should -BeNullOrEmpty
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

    It 'never presses Run in a confirmation dialog' {
        # The capture turns on Enable actions. It may choose Dry run or Cancel. Run would change a lab device.
        $files = @(Get-ChildItem -LiteralPath $script:CaptureDir -Filter '*.ps1' -Recurse)
        $files.Count | Should -BeGreaterThan 0
        foreach ($file in $files) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $text | Should -Not -Match 'btnActionRun' -Because $file.Name
            # A button chosen by its name: Run passed to Find-Role, Find-Item or Click-El.
            $text | Should -Not -Match '(?i)\b(Find-Role|Find-Item|Click-El)\b[^\r\n]*[''"]Run[''"]' -Because $file.Name
        }
    }

    It 'takes optional Section and Image parameters that select sections and images' {
        $cmd = Get-Command (Join-Path $script:CaptureDir 'Invoke-GuideCapture.ps1')
        foreach ($name in 'Section', 'Image') {
            $cmd.Parameters.ContainsKey($name) | Should -BeTrue -Because $name
            $cmd.Parameters[$name].ParameterType | Should -Be ([string[]]) -Because $name
            @($cmd.Parameters[$name].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 0 -Because "$name is optional"
        }
    }

    It 'stops on an unknown section name before it connects to the lab computer' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir 'Invoke-GuideCapture.ps1'))
        $text | Should -Match 'Unknown section'
        $text.IndexOf('Unknown section') | Should -BeLessThan $text.IndexOf('New-PSSession')
        # A run with -Section takes the guide steps only, and it passes the names to the lab side.
        $text | Should -Match 'Sections = @\(\$Section'
        $text | Should -Match 'if \(\$Section\) \{ @\(''steps-guide\.ps1''\)'
    }

    It 'copies only the named images and checks that each one was taken' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir 'Invoke-GuideCapture.ps1'))
        $text | Should -Match 'did not produce these named images'
        $text.IndexOf('did not produce these named images') | Should -BeLessThan $text.IndexOf('Copy-Item $png.FullName')
        $text | Should -Match 'Where-Object \{ \$wanted -contains \$_\.BaseName \}'
    }

    It 'names each section of the guide steps once, and keeps the uninstall images in the section action menus' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:CaptureDir 'steps-guide.ps1'), [ref]$null, [ref]$null)
        $sections = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Section' }, $true))
        $names = @($sections | ForEach-Object { $_.CommandElements[1].Value })
        $names.Count | Should -BeGreaterThan 8
        @($names | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name) | Should -BeNullOrEmpty
        $body = @{}
        foreach ($s in $sections) { $body[$s.CommandElements[1].Value] = $s.CommandElements[2].Extent.Text }
        $body['action menus'] | Should -Match 'apps-uninstall-confirm'
        $body['action menus'] | Should -Match 'apps-context-menu'
        foreach ($n in $names | Where-Object { $_ -ne 'action menus' }) {
            $body[$n] | Should -Not -Match 'apps-uninstall-confirm' -Because "$n must run on a workstation with no uninstallable row"
            $body[$n] | Should -Not -Match 'apps-context-menu' -Because $n
        }
        # The image of the action buttons and of the running list are in a section of their own, before the menus.
        $names.IndexOf('actions') | Should -BeLessThan $names.IndexOf('action menus')
        $body['actions'] | Should -Match 'actions-device-buttons'
        $body['actions'] | Should -Match 'actions-running-list'
    }

    It 'runs only the selected sections and sets the site server and the site code in a section that is not an image section' {
        $lib = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir 'guilib.ps1'))
        $lib | Should -Match '\$Capture\.Sections'
        $lib | Should -Match '\$Name -ne ''setup'''
        $lib | Should -Match 'not selected'
        $steps = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir 'steps-guide.ps1'))
        $steps | Should -Match "Section 'setup'"
        $setup = [regex]::Match($steps, "(?s)Section 'setup' \{.*?\r?\n    \}").Value
        $setup | Should -Not -BeNullOrEmpty
        $setup | Should -Not -Match '\bShot\b'
        # The sections that set the site server and the site code themselves do not get the setup first.
        $steps | Should -Match '''first run'' -notin \$selectedSections -and ''options'' -notin'
    }

    It 'documents the one command that retakes every capture in the guide index' {
        $index = [System.IO.File]::ReadAllText((Join-Path $script:Root 'docs\index.md'))
        $index | Should -Match '(?m)^## Retake the captures'
        $index | Should -Match 'tools\\guide-capture\\Invoke-GuideCapture\.ps1'
    }
}

Describe 'Repository text' {
    It 'has no lab account name or lab credential file name in a tracked text file of the repository' {
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
            foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($path), $script:PrivateNamePattern)) { '{0}: {1}' -f $f, $m.Value }
        }
        @($found) | Should -BeNullOrEmpty
    }
}
