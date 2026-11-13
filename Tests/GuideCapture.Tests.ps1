#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Static checks of the capture scripts in tools\guide-capture. The scripts run on a lab
# workstation and are never run here: this file only parses them. It opens no window.

BeforeDiscovery {
    $script:CaptureFiles = @('Invoke-GuideCapture.ps1', 'guilib.ps1', 'main.ps1', 'steps-guide.ps1', 'steps-console-missing.ps1') | ForEach-Object { @{ File = $_ } }
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:CaptureDir = Join-Path $script:Root 'tools\guide-capture'
    $script:ImageDir = Join-Path $script:Root 'docs\images'
    $script:InvokePath = Join-Path $script:CaptureDir 'Invoke-GuideCapture.ps1'
    $script:InvokeText = [System.IO.File]::ReadAllText($script:InvokePath)
    $script:InvokeAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InvokePath, [ref]$null, [ref]$null)
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

    It 'stops before it replaces an image when a step failed, an error is in the run log or an image is missing' {
        $iThrow = $script:InvokeText.IndexOf('if ($failed.Count) { throw')
        $iStage = $script:InvokeText.IndexOf('$staging = ')
        $iCopy = $script:InvokeText.IndexOf('Copy-Item $png.FullName')
        $iThrow | Should -BeGreaterThan 0
        $iStage | Should -BeGreaterThan $iThrow
        $iCopy | Should -BeGreaterThan $iThrow
        $script:InvokeText | Should -Match "ERROR'"
        $script:InvokeText | Should -Match 'No image was replaced'
        $script:InvokeText.IndexOf('No image was replaced') | Should -BeLessThan $iStage
        $script:InvokeText | Should -Match 'catch \{\s*foreach \(\$name in \$placed\)'
    }

    It 'quotes the guide root in the command line of the scheduled task and passes it to the runner' {
        $script:InvokeText | Should -Match '-GuideRoot `"\$r`"'
        $script:InvokeText | Should -Match '-File `"\$r\\ui\\main\.ps1`"'
        $script:InvokeText | Should -Not -Match '-App '
        $main = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir 'main.ps1'))
        $main | Should -Match 'param\(\[string\]\$GuideRoot\)'
        $main | Should -Not -Match "C:\\guide"
    }

    It 'connects and schedules the task with the values of the caller' {
        $calls = @($script:InvokeAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'New-PSSession', 'New-ScheduledTaskPrincipal' }, $true))
        $calls.Count | Should -Be 2
        foreach ($c in $calls) {
            $text = $c.Extent.Text
            if ($c.GetCommandName() -eq 'New-PSSession') {
                $text | Should -Match '-ComputerName \$Target\b'
                $text | Should -Match '-Credential \$LabCredential\b'
            }
            else { $text | Should -Match '-UserId \$user\b' }
        }
        $script:InvokeText | Should -Match '-ArgumentList \$root, \$LogonUser, \$captureJson, \$taskName'
    }

    It 'takes the capture lock with New-Item and an IOException catch, and treats a lock older than 60 minutes as stale' {
        $newItem = @($script:InvokeAst.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-Item' -and
                    $n.Extent.Text -match '-ItemType File' -and $n.Extent.Text -match '-ErrorAction Stop'
                }, $true))
        $newItem.Count | Should -Be 1
        $catch = @($script:InvokeAst.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CatchClauseAst] -and
                    @($n.CatchTypes | Where-Object { $_.TypeName.FullName -eq 'System.IO.IOException' }).Count -gt 0
                }, $true))
        $catch.Count | Should -Be 1
        $script:InvokeText | Should -Match "\`$lockPath = 'C:\\guide\\capture\.lock'"
        $script:InvokeText | Should -Match '-ArgumentList \$lockPath, \$lockToken, 60, \$LockWaitMinutes'
        $script:InvokeText | Should -Match 'TotalMinutes -gt \$staleMinutes'
    }

    It 'works in its own folder and its own task, removes only its own files and the lock, and never removes C:\guide' {
        $script:InvokeText | Should -Match '\$root = "C:\\guide\\\$app"'
        $script:InvokeText | Should -Match '\$taskName = "GuideShots-\$app"'
        $script:InvokeText | Should -Match "\`$app = 'device-inspector'"
        $script:InvokeText | Should -Not -Match 'TaskName GuideShots\b'
        $removals = @($script:InvokeAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-Item' }, $true))
        $removals.Count | Should -BeGreaterThan 4
        foreach ($c in $removals) { $c.Extent.Text | Should -Not -Match "C:\\guide\b(?!\\)" -Because $c.Extent.Text }
    }

    It 'stops a running capture in the finally block before it removes the task, the folder and the lock' {
        $iFinally = $script:InvokeText.LastIndexOf('finally {')
        $iFinally | Should -BeGreaterThan 0
        $tail = $script:InvokeText.Substring($iFinally)
        $iStop = $tail.IndexOf('Stop-ScheduledTask')
        $iKill = $tail.IndexOf('Stop-Process')
        $iUnregister = $tail.IndexOf('Unregister-ScheduledTask')
        $iFolder = $tail.IndexOf('Remove-Item $r -Recurse')
        $iLock = $tail.IndexOf('Remove-Item -LiteralPath $path -Force')
        $tail | Should -Match 'Get-Content -LiteralPath \$path -Raw -ErrorAction SilentlyContinue\)\)\.Trim\(\)'
        $iStop | Should -BeGreaterThan -1
        $iKill | Should -BeGreaterThan $iStop
        $tail | Should -Match 'if \(\$session -and \$haveLock\) \{ try \{' -Because 'only a capture that holds the lock stops the task and removes the folder'
        $iUnregister | Should -BeGreaterThan $iKill
        $iFolder | Should -BeGreaterThan $iUnregister
        $iLock | Should -BeGreaterThan $iFolder
    }

    It 'creates the session before the try block ends the work, and closes it in the finally block' {
        $iTry = $script:InvokeText.IndexOf("try {`n    `$session = New-PSSession")
        if ($iTry -lt 0) { $iTry = $script:InvokeText.IndexOf("try {`r`n    `$session = New-PSSession") }
        $iTry | Should -BeGreaterThan 0 -Because 'New-PSSession is the first call inside the try block'
        $script:InvokeText.Substring($script:InvokeText.LastIndexOf('finally {')) | Should -Match 'Remove-PSSession \$session'
    }

    It 'does not spin on a stale lock, re-reads the age before the delete and touches the lock while it runs' {
        $script:InvokeText | Should -Match '\$again = Get-Item -LiteralPath \$path'
        $script:InvokeText | Should -Match 'Move-Item -LiteralPath \$path -Destination \$stale -ErrorAction Stop'
        $script:InvokeText | Should -Match '\$stale = "\$path\.stale\.\$token"'
        # After the rename the age of the moved file is read again. A live lock moves back. Only a stale one is deleted.
        $script:InvokeText | Should -Match '\$moved = Get-Item -LiteralPath \$stale -ErrorAction Stop'
        $script:InvokeText | Should -Match '\$moved\.LastWriteTime\)\.TotalMinutes -gt \$staleMinutes'
        $script:InvokeText | Should -Match 'Move-Item -LiteralPath \$stale -Destination \$path -ErrorAction Stop'
        $iRead = $script:InvokeText.IndexOf('$moved = Get-Item')
        $iDelete = $script:InvokeText.IndexOf('Remove-Item -LiteralPath $stale')
        $iRead | Should -BeGreaterThan 0
        $iDelete | Should -BeGreaterThan $iRead -Because 'the delete follows the age check of the moved file'
        $script:InvokeText | Should -Not -Match '(?s)\$again = Get-Item.{0,400}Remove-Item -LiteralPath \$path\b'
        $script:InvokeText | Should -Match 'if \(-not \(Test-Path -LiteralPath \$path\)\) \{ continue \}'
        $script:InvokeText | Should -Match 'Start-Sleep -Seconds 15'
        # The token is written after the IOException catch, and a lost lock stops the capture.
        $script:InvokeText | Should -Match 'New-Item -ItemType File -Path \$path -Value \$token -ErrorAction Stop'
        $script:InvokeText | Should -Not -Match 'Set-Content -LiteralPath \$path'
        $script:InvokeText | Should -Match 'The capture lock is lost\.'
        # A lost lock clears the flag, so that the clean-up leaves the task and the folder of the other capture alone.
        $script:InvokeText | Should -Match '-match ''The capture lock is lost''\) \{ \$haveLock = \$false \}'
        # A live lock that cannot go back to its name is deleted under the stale name.
        $script:InvokeText | Should -Match 'catch \{ Remove-Item -LiteralPath \$stale -Force -ErrorAction SilentlyContinue \}'
        $script:InvokeText | Should -Match '\.LastWriteTime = Get-Date'
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

    It 'takes an optional UninstallApp name and hands it to the steps, which use it for the filter and the row' {
        $cmd = Get-Command $script:InvokePath
        $cmd.Parameters.ContainsKey('UninstallApp') | Should -BeTrue
        $cmd.Parameters['UninstallApp'].ParameterType | Should -Be ([string])
        @($cmd.Parameters['UninstallApp'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 0
        $script:InvokeText | Should -Match 'UninstallApp = \$UninstallApp'
        $steps = [System.IO.File]::ReadAllText((Join-Path $script:CaptureDir 'steps-guide.ps1'))
        $steps | Should -Match '\$Capture\.UninstallApp'
        $steps | Should -Match 'Find-NamedItem \(Get-El \$win ''gridApps''\) \(''\*'' \+ \$uninstallApp \+ ''\*''\)'
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
