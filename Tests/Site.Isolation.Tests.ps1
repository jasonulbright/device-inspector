#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }

<#
.SYNOPSIS
    Two-site isolation of the per-site data of Device Inspector (Q-112f).

.DESCRIPTION
    Each test seeds an old-layout tool folder in TestDrive (prefs, reports, the action log, a tool log, the
    window state), points APP_PACKAGER_DATA_ROOT at TestDrive, and starts the tool logic for site AB1, then CD2,
    then AB1 again. The tool logic is the real code: Resolve-SuiteToolSite from the vendored SuiteCommon,
    Get-DiPreferences and Save-DiPreferences of the start script (cut out of its syntax tree, as in
    Shell.Logic.Tests.ps1), and the path functions of the module. Site codes are fictional (AB1, CD2, EF3).
    Hosts are example.com. No window opens and no ConfigMgr connection is needed.
#>

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
    $script:ShellPath = Join-Path $script:AppRoot 'start-deviceinspector.ps1'
    $script:ShellText = Get-Content -LiteralPath $script:ShellPath -Raw
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ShellPath, [ref]$null, [ref]$null)
    foreach ($n in 'Get-DiPreferences', 'Save-DiPreferences') {
        $def = $script:Ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
        if (-not $def) { throw "function $n not found in the script" }
        . ([scriptblock]::Create($def.Extent.Text))
    }
    $script:EnvNames = 'SUITE_CM_SITECODE', 'APP_PACKAGER_SITE', 'APP_PACKAGER_DATA_ROOT', 'SUITE_CM_PROVIDER'

    function Write-Seed {
        param([string]$Root, [string]$Relative, [string]$Text)
        $p = Join-Path $Root $Relative
        $d = Split-Path $p -Parent
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        [IO.File]::WriteAllText($p, $Text, (New-Object Text.UTF8Encoding($false)))
    }
    function Get-TreeHash {
        param([string]$Root)
        $h = @{}
        if (Test-Path -LiteralPath $Root) { foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) { $h[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } }
        return $h
    }
    # An old tool folder beside the script, as the tool wrote it before the per-site layout.
    function New-OldToolFolder {
        param([string]$Suite, [switch]$NoSiteCode)
        $t = Join-Path $Suite 'device-inspector'
        $prefs = [ordered]@{ DarkMode = $false; SiteOnly = $true }
        if (-not $NoSiteCode) { $prefs['SiteCode'] = 'AB1'; $prefs['SMSProvider'] = 'cm01.example.com'; $prefs['LastDevice'] = 'AB1-PC01' }
        Write-Seed $t 'DeviceInspector.prefs.json' ($prefs | ConvertTo-Json)
        Write-Seed $t 'DeviceInspector.windowstate.json' '{"ActiveView":"Device"}'
        Write-Seed $t 'Reports\DeviceInspector-AB1-PC01-20261120-100000.json' '{"ComputerName":"AB1-PC01"}'
        Write-Seed $t 'Reports\DeviceInspector-AB1-PC01-20261120-100000.html' '<html><body>AB1-PC01</body></html>'
        Write-Seed $t 'Logs\DeviceInspector-actions.log' ('2026-11-20 10:00:00  AB1-PC01  Policy update  OK' + "`r`n")
        Write-Seed $t 'Logs\DeviceInspector-20261120-100000.log' 'global log'
        return $t
    }
    # An action result for the real action log writer.
    function New-TestActionResult {
        param([string]$Device)
        New-DeviceInspectorActionRecord -Action 'Policy update' -ComputerName $Device -DryRun $true -Succeeded $true -Summary ('Dry run for ' + $Device) -Steps @('Step one')
    }
    # What the start script does at start: resolve the site, read the prefs, resolve the stores.
    function Start-Tool {
        param([string]$Folder)
        if ($Folder) { [Environment]::SetEnvironmentVariable('APP_PACKAGER_SITE', $Folder) } else { [Environment]::SetEnvironmentVariable('APP_PACKAGER_SITE', $null) }
        $global:PrefsPath = Join-Path $script:ToolRoot 'DeviceInspector.prefs.json'
        $script:Site = Resolve-SuiteToolSite -Tool 'device-inspector' -ToolRoot $script:ToolRoot -LegacyPrefsPath $global:PrefsPath
        $global:Prefs = Get-DiPreferences
        return @{
            Site      = $script:Site
            Prefs     = $global:Prefs
            Reports   = Resolve-DeviceInspectorReportsPath -ToolRoot $script:ToolRoot -Site $script:Site -Create
            ActionLog = Resolve-DeviceInspectorActionLogPath -ToolRoot $script:ToolRoot -Site $script:Site -Create
        }
    }
}

AfterAll {
    Remove-Variable -Name PrefsPath, Prefs -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Per-site data of Device Inspector' {
    BeforeAll {
        $script:Saved = @{}
        foreach ($n in $script:EnvNames) { $script:Saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
        # Short names: the path limit of 260 characters in Windows PowerShell 5.1 counts the data root, the SID and the .migrating copy.
        $temp = Join-Path $TestDrive 'a'
        $script:Suite = Join-Path $temp 'Suite'
        $script:Data = Join-Path $temp 'D'
        [void](New-Item -ItemType Directory -Path $script:Suite, $script:Data -Force)
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_DATA_ROOT', $script:Data)
        $script:ToolRoot = New-OldToolFolder -Suite $script:Suite
        $script:OldHash = Get-TreeHash -Root $script:ToolRoot
        $script:DataRoot = Get-SuiteDataRoot

        # Start for AB1, save a changed provider and a new last device, write one report and one action result.
        $script:Ab1 = Start-Tool -Folder 'AB1'
        $script:Ab1Prefs = $script:Ab1.Prefs.Clone()
        $global:Prefs['SMSProvider'] = 'cm02.example.com'
        $global:Prefs['LastDevice'] = 'AB1-PC02'
        Save-DiPreferences -Prefs $global:Prefs
        Write-Seed $script:Ab1.Reports 'DeviceInspector-AB1-PC02-20261121-090000.json' '{"ComputerName":"AB1-PC02"}'
        [void](Write-DeviceInspectorActionLog -Path $script:Ab1.ActionLog -Result (New-TestActionResult -Device 'AB1-PC02'))
        $script:Ab1After = Get-TreeHash -Root (Join-Path $script:DataRoot 'sites\AB1')

        # Start for CD2 and write there.
        $script:Cd2 = Start-Tool -Folder 'CD2'
        $script:Cd2Prefs = $script:Cd2.Prefs.Clone()
        Write-Seed $script:Cd2.Reports 'DeviceInspector-CD2-PC01-20261121-100000.json' '{"ComputerName":"CD2-PC01"}'
        [void](Write-DeviceInspectorActionLog -Path $script:Cd2.ActionLog -Result (New-TestActionResult -Device 'CD2-PC01'))
        $global:Prefs['SMSProvider'] = 'cm03.example.com'
        $global:Prefs['LastDevice'] = 'CD2-PC01'
        Save-DiPreferences -Prefs $global:Prefs

        # Back to AB1.
        $script:Ab1Again = Start-Tool -Folder 'AB1'
    }

    AfterAll {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:Saved[$n]) }
    }

    It 'keeps every old file unchanged (SHA-256), except the prefs file, which only gets global keys' {
        $now = Get-TreeHash -Root $script:ToolRoot
        foreach ($k in $script:OldHash.Keys) {
            $now.ContainsKey($k) | Should -BeTrue -Because "$k must still exist"
            if ($k -like '*DeviceInspector.prefs.json') { continue }
            $now[$k] | Should -Be $script:OldHash[$k] -Because "$k must keep its content"
        }
        $oldPrefs = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'DeviceInspector.prefs.json') -Raw | ConvertFrom-Json
        $oldPrefs.SMSProvider | Should -Be 'cm01.example.com' -Because 'the old file keeps the site keys it already had'
        $oldPrefs.LastDevice | Should -Be 'AB1-PC01'
        @(Get-ChildItem -LiteralPath (Join-Path $script:ToolRoot 'Reports') -File).Count | Should -Be 2 -Because 'no new report went to the old folder'
    }

    It 'copies the AB1 reports and the action log once into sites\AB1\tools\device-inspector' {
        $tool = Join-Path $script:DataRoot 'sites\AB1\tools\device-inspector'
        $script:Ab1.Site.Active | Should -BeTrue -Because $script:Ab1.Site.Reason
        $script:Ab1.Site.ToolFolder | Should -Be $tool
        $script:Ab1.Reports | Should -Be (Join-Path $tool 'reports')
        $script:Ab1.ActionLog | Should -Be (Join-Path $tool 'DeviceInspector-actions.log')
        (Get-Content -LiteralPath (Join-Path $tool 'reports\DeviceInspector-AB1-PC01-20261120-100000.json') -Raw) | Should -Match 'AB1-PC01'
        Test-Path -LiteralPath (Join-Path $tool 'reports\DeviceInspector-AB1-PC01-20261120-100000.html') | Should -BeTrue
        $log = Get-Content -LiteralPath (Join-Path $tool 'DeviceInspector-actions.log') -Raw
        $log | Should -Match 'AB1-PC01  Policy update  OK' -Because 'the old action log was copied'
        $log | Should -Match 'AB1-PC02' -Because 'the new result was appended to the copy'
        (Get-Content -LiteralPath (Join-Path $tool 'migrated.json') -Raw | ConvertFrom-Json).tool | Should -Be 'device-inspector'
    }

    It 'reads the AB1 site keys from the old prefs and keeps the other keys in the old file' {
        $script:Ab1Prefs['SiteCode'] | Should -Be 'AB1'
        $script:Ab1Prefs['SMSProvider'] | Should -Be 'cm01.example.com'
        $script:Ab1Prefs['LastDevice'] | Should -Be 'AB1-PC01'
        $script:Ab1Prefs['DarkMode'] | Should -BeFalse
        $script:Ab1Prefs['SiteOnly'] | Should -BeTrue
        $siteFile = Get-Content -LiteralPath (Join-Path $script:DataRoot 'sites\AB1\tools\device-inspector\prefs.json') -Raw | ConvertFrom-Json
        $siteFile.SiteCode | Should -Be 'AB1'
        $siteFile.LastDevice | Should -Be 'AB1-PC02'
        $siteFile.PSObject.Properties.Name | Should -Not -Contain 'DarkMode'
        $siteFile.PSObject.Properties.Name | Should -Not -Contain 'SiteOnly'
    }

    It 'shows none of the AB1 values or files for CD2' {
        $script:Cd2.Site.SiteFolder | Should -Be 'CD2'
        $script:Cd2Prefs['SiteCode'] | Should -Be 'CD2'
        $script:Cd2Prefs['SMSProvider'] | Should -Be ''
        $script:Cd2Prefs['SMSProvider'] | Should -Not -Match 'example.com'
        $script:Cd2Prefs['LastDevice'] | Should -Be '' -Because 'the last device is a site key'
        $script:Cd2Prefs['DarkMode'] | Should -BeFalse -Because 'the theme is a global key'
        $tool = Join-Path $script:DataRoot 'sites\CD2\tools\device-inspector'
        $script:Cd2.Reports | Should -Be (Join-Path $tool 'reports')
        Test-Path -LiteralPath (Join-Path $tool 'reports\DeviceInspector-AB1-PC01-20261120-100000.json') | Should -BeFalse
        $cd2Log = Get-Content -LiteralPath (Join-Path $tool 'DeviceInspector-actions.log') -Raw
        $cd2Log | Should -Not -Match 'AB1' -Because 'the action log of CD2 starts empty'
        @(Get-ChildItem -LiteralPath $tool -Recurse -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'AB1' -and $_.Name -ne 'migrated.json' -and $_.Name -ne 'prefs.json' }) | Should -BeNullOrEmpty
    }

    It 'writes the CD2 data only under sites\CD2 and leaves AB1 and the old folder alone' {
        $cd2Root = Join-Path $script:DataRoot 'sites\CD2'
        Test-Path -LiteralPath (Join-Path $cd2Root 'tools\device-inspector\reports\DeviceInspector-CD2-PC01-20261121-100000.json') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $cd2Root 'tools\device-inspector\DeviceInspector-actions.log') -Raw) | Should -Match 'CD2-PC01'
        $ab1Now = Get-TreeHash -Root (Join-Path $script:DataRoot 'sites\AB1')
        foreach ($k in $script:Ab1After.Keys) {
            if ($k -like '*prefs.json') { continue }
            $ab1Now[$k] | Should -Be $script:Ab1After[$k] -Because "$k of AB1 must not change while CD2 runs"
        }
        foreach ($k in $script:OldHash.Keys) {
            if ($k -like '*DeviceInspector.prefs.json') { continue }
            (Get-FileHash -LiteralPath $k -Algorithm SHA256).Hash | Should -Be $script:OldHash[$k]
        }
    }

    It 'gives the AB1 values back when the tool starts for AB1 again' {
        $script:Ab1Again.Site.SiteFolder | Should -Be 'AB1'
        $script:Ab1Again.Prefs['SiteCode'] | Should -Be 'AB1'
        $script:Ab1Again.Prefs['SMSProvider'] | Should -Be 'cm02.example.com' -Because 'AB1 saved this provider before CD2 started'
        $script:Ab1Again.Prefs['LastDevice'] | Should -Be 'AB1-PC02'
        Test-Path -LiteralPath (Join-Path $script:Ab1Again.Reports 'DeviceInspector-AB1-PC02-20261121-090000.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Ab1Again.Reports 'DeviceInspector-CD2-PC01-20261121-100000.json') | Should -BeFalse
        $log = Get-Content -LiteralPath $script:Ab1Again.ActionLog -Raw
        $log | Should -Match 'AB1-PC02'
        $log | Should -Not -Match 'CD2-PC01'
    }

    It 'keeps a different provider and last device for each site' {
        $cd2 = Get-Content -LiteralPath (Join-Path $script:DataRoot 'sites\CD2\tools\device-inspector\prefs.json') -Raw | ConvertFrom-Json
        $ab1 = Get-Content -LiteralPath (Join-Path $script:DataRoot 'sites\AB1\tools\device-inspector\prefs.json') -Raw | ConvertFrom-Json
        $cd2.SMSProvider | Should -Be 'cm03.example.com'
        $cd2.LastDevice | Should -Be 'CD2-PC01'
        $ab1.SMSProvider | Should -Be 'cm02.example.com'
        $ab1.LastDevice | Should -Be 'AB1-PC02'
    }
}

Describe 'Device Inspector with no site chosen' {
    BeforeAll {
        $script:Saved = @{}
        foreach ($n in $script:EnvNames) { $script:Saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
        $temp = Join-Path $TestDrive 'b'
        $script:Suite = Join-Path $temp 'Suite'
        $script:Data = Join-Path $temp 'D'
        [void](New-Item -ItemType Directory -Path $script:Suite, $script:Data -Force)
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_DATA_ROOT', $script:Data)
        $script:ToolRoot = New-OldToolFolder -Suite $script:Suite -NoSiteCode
        $script:OldHash = Get-TreeHash -Root $script:ToolRoot
        $script:None = Start-Tool -Folder ''
    }
    AfterAll {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:Saved[$n]) }
    }

    It 'is not active and uses the old Reports folder and the old action log' {
        $script:None.Site.Active | Should -BeFalse
        $script:None.Reports | Should -Be (Join-Path $script:ToolRoot 'Reports')
        $script:None.ActionLog | Should -Be (Join-Path $script:ToolRoot 'Logs\DeviceInspector-actions.log')
    }

    It 'creates no site folder and changes no old file' {
        Test-Path -LiteralPath (Join-Path (Get-SuiteDataRoot) 'sites') | Should -BeFalse
        $now = Get-TreeHash -Root $script:ToolRoot
        foreach ($k in $script:OldHash.Keys) { $now[$k] | Should -Be $script:OldHash[$k] }
    }

    It 'saves the site keys and the other keys to the old prefs file' {
        $global:Prefs['SiteCode'] = 'EF3'
        $global:Prefs['SMSProvider'] = 'cm04.example.com'
        $global:Prefs['LastDevice'] = 'EF3-PC01'
        Save-DiPreferences -Prefs $global:Prefs
        $p = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'DeviceInspector.prefs.json') -Raw | ConvertFrom-Json
        $p.SiteCode | Should -Be 'EF3'
        $p.SMSProvider | Should -Be 'cm04.example.com'
        $p.LastDevice | Should -Be 'EF3-PC01'
        Test-Path -LiteralPath (Join-Path (Get-SuiteDataRoot) 'sites') | Should -BeFalse
    }

    It 'appends an action result to the old action log' {
        [void](Write-DeviceInspectorActionLog -Path $script:None.ActionLog -Result (New-TestActionResult -Device 'EF3-PC01'))
        (Get-Content -LiteralPath $script:None.ActionLog -Raw) | Should -Match 'EF3-PC01'
    }
}

Describe 'Store paths' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'old-tool'
        $script:SiteObj = [pscustomobject]@{ Active = $true; ToolFolder = (Join-Path $TestDrive 'sites\AB1\tools\device-inspector') }
    }

    It 'uses the stores of the site and the old paths with no site' {
        Resolve-DeviceInspectorReportsPath -ToolRoot $script:Root -Site $script:SiteObj | Should -Be (Join-Path $script:SiteObj.ToolFolder 'reports')
        Resolve-DeviceInspectorReportsPath -ToolRoot $script:Root -Site $null | Should -Be (Join-Path $script:Root 'Reports')
        Resolve-DeviceInspectorReportsPath -ToolRoot $script:Root -Site ([pscustomobject]@{ Active = $false }) | Should -Be (Join-Path $script:Root 'Reports')
        Resolve-DeviceInspectorActionLogPath -ToolRoot $script:Root -Site $script:SiteObj | Should -Be (Join-Path $script:SiteObj.ToolFolder 'DeviceInspector-actions.log')
        Resolve-DeviceInspectorActionLogPath -ToolRoot $script:Root -Site $null | Should -Be (Join-Path $script:Root 'Logs\DeviceInspector-actions.log')
    }

    It 'creates the folders only with -Create' {
        $r = Resolve-DeviceInspectorReportsPath -ToolRoot $script:Root -Site $script:SiteObj
        Test-Path -LiteralPath $r | Should -BeFalse
        $a = Resolve-DeviceInspectorActionLogPath -ToolRoot $script:Root -Site $script:SiteObj
        Test-Path -LiteralPath (Split-Path $a -Parent) | Should -BeFalse
        [void](Resolve-DeviceInspectorReportsPath -ToolRoot $script:Root -Site $script:SiteObj -Create)
        Test-Path -LiteralPath $r | Should -BeTrue
        [void](Resolve-DeviceInspectorActionLogPath -ToolRoot $script:Root -Site $script:SiteObj -Create)
        Test-Path -LiteralPath (Split-Path $a -Parent) | Should -BeTrue
        Test-Path -LiteralPath $a | Should -BeFalse -Because 'only the folder is created, not the file'
        [void](Resolve-DeviceInspectorReportsPath -ToolRoot $script:Root -Site $null -Create)
        Test-Path -LiteralPath (Join-Path $script:Root 'Reports') | Should -BeTrue
        [void](Resolve-DeviceInspectorActionLogPath -ToolRoot $script:Root -Site $null -Create)
        Test-Path -LiteralPath (Join-Path $script:Root 'Logs') | Should -BeTrue
    }
}

Describe 'Static guard: no site store is built from the script folder' {
    It 'builds no reports path or action log path from $PSScriptRoot in the start script' {
        $script:ShellText | Should -Not -Match "PSScriptRoot\s+'Reports"
        $script:ShellText | Should -Not -Match "Join-Path\s+\`$__txDir\s+'DeviceInspector-actions"
    }

    It 'resolves the reports folder and the action log only through the module functions (syntax tree)' {
        $reports = $script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Resolve-DeviceInspectorReportsPath' }, $true)
        @($reports).Count | Should -Be 1 -Because 'the export folder'
        $logs = $script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Resolve-DeviceInspectorActionLogPath' }, $true)
        @($logs).Count | Should -Be 1 -Because 'the action log is resolved once at start'
        $joins = $script:Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and ($x.Value -eq 'Reports' -or $x.Value -eq 'DeviceInspector-actions.log') }, $true)
        @($joins).Count | Should -Be 0
    }

    It 'stores no absolute path in the prefs defaults' {
        $def = $script:Ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-DiPreferences' }, $true)
        $def.Extent.Text | Should -Not -Match 'Join-Path|PSScriptRoot'
    }

    It 'reads and saves the prefs through the site prefs functions' {
        $script:ShellText | Should -Match 'Read-SuiteToolPrefs'
        $script:ShellText | Should -Match 'Save-SuiteToolPrefs'
        $script:ShellText | Should -Not -Match 'Read-SuiteSettings'
        $script:ShellText | Should -Not -Match 'Save-SuiteSettings'
    }

    It 'makes the Site Code box read-only with the launcher tooltip when a site is active' {
        $script:ShellText | Should -Match 'The site is chosen in the AppPackager Suite launcher\. Restart this tool after you change it\.'
        $script:ShellText | Should -Match 'Start-SuiteSiteWatch'
    }
}
