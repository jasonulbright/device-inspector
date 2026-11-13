# The guide steps. main.ps1 dot-sources this file in the interactive session of the lab workstation.
# $Capture holds the site code, the SMS Provider and the device names (Invoke-GuideCapture.ps1).
# The app only reads. No step changes the site or a device.
$win = Start-App 'start-deviceinspector.ps1' 'Device Inspector'
Size-Win $win 1440 900
$win = Find-Top 'Device Inspector' 10
function Wait-Idle { Start-Sleep -Seconds 2; $null = Wait-Until { (Get-El $win 'btnInspect').Current.IsEnabled } 240; Start-Sleep -Seconds 1 }
# An inspection that read the device lists its applications. A summary with 0 applications means that the step did not inspect the device (for example a message box stayed open).
function Assert-Applications { $s = Get-ElText (Get-El $win 'txtSummary'); if ($s -notmatch '; [1-9]\d* applications;') { throw ('The inspection did not read the device applications: ' + $s) } }
function Show-View([string]$Button) { Invoke-El (Get-El $win $Button); Start-Sleep -Milliseconds 600 }
function Close-Message($Box) { Invoke-El (Get-El $Box 'btnPrimary'); Start-Sleep -Milliseconds 500 }
function Select-AppType([string]$Item) { Expand-El (Get-El $win 'cboAppType'); Start-Sleep -Milliseconds 400; Click-El (Find-Role $win 'ListItem' $Item); Start-Sleep -Milliseconds 600 }
function Get-RunRows {
    $g = Get-El $win 'gridRuns' -Quiet
    if (-not $g) { return @() }
    @($g.FindAll('Descendants', (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem))))
}
# A dry run on a lab device lasts a second or two: poll fast so that the running-actions list is in the image.
function Wait-RunRow([int]$Seconds = 10) { $end = (Get-Date).AddSeconds($Seconds); while ((Get-Date) -lt $end) { if (@(Get-RunRows).Count -gt 0) { return $true }; Start-Sleep -Milliseconds 50 }; $false }
function Wait-NoRun { $null = Wait-Until { @(Get-RunRows).Count -eq 0 } 120 }
function Close-ResultWindows { foreach ($w in @(Find-All 'Action Result') + @(Find-All 'Action Failed')) { try { Invoke-El (Get-El $w 'btnPrimary') } catch { $null = $_ } }; Start-Sleep -Milliseconds 400 }
# The first row of a grid whose UI Automation name matches the pattern, else the first row.
# Like Find-Item, but with no fallback to the first row: a row that does not match is an error.
function Find-NamedItem($Grid, [string]$Pattern) {
    $items = @($Grid.FindAll('Descendants', (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem))))
    $hit = $items | Where-Object { $_.Current.Name -like $Pattern } | Select-Object -First 1
    if (-not $hit) { throw ('The grid has no row that matches ' + $Pattern) }
    $hit
}
function Find-Item($Grid, [string]$Pattern) {
    $items = @($Grid.FindAll('Descendants', (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem))))
    $hit = $items | Where-Object { $_.Current.Name -like $Pattern } | Select-Object -First 1
    if ($hit) { return $hit }
    if (-not $items.Count) { throw 'The grid has no row.' }
    $items[0]
}

# A run with -Section starts the app with no saved settings. The sections 'first run' and 'options' set the site server
# and the site code, and 'first run' needs the empty first-run state. When neither is selected, this part sets the
# site server and the site code instead, and it takes no image.
$selectedSections = @($Capture.Sections | Where-Object { $_ })
if ($selectedSections.Count -and 'first run' -notin $selectedSections -and 'options' -notin $selectedSections) {
    Section 'setup' {
        Invoke-El (Get-El $win 'btnOptions'); $d = Find-Top 'Options' 10
        Set-Text (Get-El $d 'txtSmsProvider') $Capture.SmsProvider; Set-Text (Get-El $d 'txtSiteCode') $Capture.SiteCode
        Invoke-El (Get-El $d 'btnOk'); Start-Sleep -Milliseconds 800
        Set-Text (Get-El $win 'txtSiteServer') $Capture.SmsProvider
    }
}
Section 'first run' {
    Shot $win 'start-first-run'
    Invoke-El (Get-El $win 'btnInspect'); Start-Sleep -Seconds 1
    $m = Find-Message 'Inspect'; Shot $m 'inspect-empty-device'; Close-Message $m
    Set-Text (Get-El $win 'txtDevice') 'bad name!'; Invoke-El (Get-El $win 'btnInspect'); Start-Sleep -Seconds 1
    $m = Find-Message 'Inspect'; Shot $m 'inspect-bad-device'; Close-Message $m
    Set-Text (Get-El $win 'txtDevice') $Capture.Device; Toggle-El (Get-El $win 'chkSiteOnly'); Invoke-El (Get-El $win 'btnInspect'); Start-Sleep -Seconds 1
    Shot $win 'inspect-site-only-no-server'; Toggle-El (Get-El $win 'chkSiteOnly')
}
Section 'options' {
    Invoke-El (Get-El $win 'btnOptions'); $d = Find-Top 'Options' 10
    Set-Text (Get-El $d 'txtSmsProvider') $Capture.SmsProvider
    # The message boxes of the Options dialog carry the app name as their title.
    Set-Text (Get-El $d 'txtSiteCode') 'ab'; Invoke-El (Get-El $d 'btnOk'); Start-Sleep -Seconds 1
    $m = Find-Message 'Device Inspector'; Shot $m 'options-bad-site-code'; Close-Message $m
    Set-Text (Get-El $d 'txtSiteCode') ''; Invoke-El (Get-El $d 'btnOk'); Start-Sleep -Seconds 1
    $m = Find-Message 'Device Inspector'; Shot $m 'options-needs-site-code'; Close-Message $m
    Set-Text (Get-El $d 'txtSiteCode') $Capture.SiteCode; Shot $d 'options-connection'
    Invoke-El (Get-El $d 'btnCatAbout'); Start-Sleep -Milliseconds 500; Shot $d 'options-about'
    Invoke-El (Get-El $d 'btnOk'); Start-Sleep -Milliseconds 800
}
Section 'inspect the client' {
    Set-Text (Get-El $win 'txtDevice') $Capture.Device
    Invoke-El (Get-El $win 'btnInspect'); Start-Sleep -Milliseconds 700; Shot $win 'inspect-running'
    Wait-Idle; Assert-Applications; Shot $win 'device-panel'
    Show-View 'btnViewApps'; Set-Text (Get-El $win 'txtAppFilter') 'micro'; Start-Sleep -Milliseconds 600; Shot $win 'apps-panel'
    Set-Text (Get-El $win 'txtAppFilter') 'edge'; Start-Sleep -Milliseconds 600; Shot $win 'apps-filter-text'
    Set-Text (Get-El $win 'txtAppFilter') 'micro'; Start-Sleep -Milliseconds 400
    Expand-El (Get-El $win 'cboAppType'); Start-Sleep -Milliseconds 500; Shot $win 'apps-type-list' -Hover
    Click-El (Find-Role $win 'ListItem' 'MSI'); Start-Sleep -Milliseconds 600; Shot $win 'apps-type-msi'
    Select-AppType 'EXE'; Shot $win 'apps-type-exe'
    Select-AppType 'All'

    Show-View 'btnViewUpdates'; Shot $win 'updates-panel'
    Show-View 'btnViewCollections'; Shot $win 'collections-panel'
    Show-View 'btnViewProblems'; Shot $win 'problems-panel'
}
Section 'inspect the server' {
    Show-View 'btnViewDevice'
    Set-Text (Get-El $win 'txtDevice') $Capture.SecondDevice; Invoke-El (Get-El $win 'btnInspect'); Wait-Idle
    Shot $win 'device-server'
    Show-View 'btnViewCollections'; Shot $win 'collections-server'
    Show-View 'btnViewUpdates'; Shot $win 'updates-server'
    Show-View 'btnViewProblems'; Shot $win 'problems-server'
}
Section 'inspect an unreachable device' {
    Show-View 'btnViewDevice'
    Set-Text (Get-El $win 'txtDevice') $Capture.UnreachableDevice; Invoke-El (Get-El $win 'btnInspect'); Wait-Idle; Shot $win 'device-unreachable'
    Show-View 'btnViewProblems'; Shot $win 'problems-unreachable'
}
Section 'site only and device only' {
    Show-View 'btnViewDevice'
    Set-Text (Get-El $win 'txtDevice') $Capture.Device; Toggle-El (Get-El $win 'chkSiteOnly'); Invoke-El (Get-El $win 'btnInspect'); Wait-Idle; Shot $win 'device-site-only'
    Toggle-El (Get-El $win 'chkSiteOnly')
    # A device only inspection has no site server and no site code. A site code without a site server stops Inspect with a message.
    Invoke-El (Get-El $win 'btnOptions'); $d = Find-Top 'Options' 10
    Set-Text (Get-El $d 'txtSmsProvider') ''; Set-Text (Get-El $d 'txtSiteCode') ''; Invoke-El (Get-El $d 'btnOk'); Start-Sleep -Milliseconds 800
    Invoke-El (Get-El $win 'btnInspect'); Wait-Idle; Assert-Applications; Shot $win 'device-device-only'
    Invoke-El (Get-El $win 'btnOptions'); $d = Find-Top 'Options' 10
    Set-Text (Get-El $d 'txtSmsProvider') $Capture.SmsProvider; Set-Text (Get-El $d 'txtSiteCode') $Capture.SiteCode; Invoke-El (Get-El $d 'btnOk'); Start-Sleep -Milliseconds 800
    Set-Text (Get-El $win 'txtSiteServer') $Capture.SmsProvider
}
Section 'enter key' {
    Show-View 'btnViewDevice'; Set-Text (Get-El $win 'txtDevice') $Capture.Device
    Click-El (Get-El $win 'txtDevice'); Send-Keys '{ENTER}'; Start-Sleep -Milliseconds 700; Shot $win 'inspect-by-enter'; Wait-Idle; Assert-Applications
}
Section 'exports' {
    Invoke-El (Get-El $win 'btnExportJson'); File-Dialog $null 'export-save-dialog'
    Invoke-El (Get-El $win 'btnExportHtml'); File-Dialog $null $null
    Shot $win 'exported'
}
Section 'tab order' {
    Show-View 'btnViewDevice'; Focus-Win $win; Click-El (Get-El $win 'btnViewDevice')
    $seen = $false
    foreach ($i in 1..24) {
        Send-Keys '{TAB}'
        $f = [System.Windows.Automation.AutomationElement]::FocusedElement
        Log ('tab -> ' + $f.Current.AutomationId + ' / ' + $f.Current.Name)
        if ($f.Current.AutomationId -eq 'btnInspect') { Shot $win 'focus-inspect' -Hover; $seen = $true; break }
    }
    if (-not $seen) { throw 'The Tab key did not reach the Inspect button.' }
}
Section 'light' {
    Toggle-El (Get-El $win 'toggleTheme'); Start-Sleep -Seconds 1; Show-View 'btnViewDevice'; Shot $win 'device-light'
    foreach ($v in @(@('btnViewApps', 'apps-light'), @('btnViewUpdates', 'updates-light'), @('btnViewCollections', 'collections-light'), @('btnViewProblems', 'problems-light'))) { Show-View $v[0]; Shot $win $v[1] }
    Invoke-El (Get-El $win 'btnOptions'); $d = Find-Top 'Options' 10; Shot $d 'options-light'; Invoke-El (Get-El $d 'btnCancel'); Start-Sleep -Milliseconds 800
    Toggle-El (Get-El $win 'toggleTheme'); Start-Sleep -Seconds 1
}
Section 'persist' {
    Show-View 'btnViewCollections'
    Invoke-El (Get-El $win 'Close'); Start-Sleep -Seconds 4
    $script:win = Start-App 'start-deviceinspector.ps1' 'Device Inspector'; Shot $win 'start-reopen-saved-state'
}
# Actions. The reopened window of the last section is a fresh process with an empty log, so the window log holds only the lines of this part.
# The steps open each confirmation dialog and choose Dry run or Cancel. No step presses Run, so the capture changes nothing
# on the site or on a device.
# The window log shows the account of each action result. The images must not show it: Hide-LogTail scrolls the log to its first lines.
function Hide-LogTail { $null = (Get-El $win 'txtLog').GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern).SetScrollPercent(-1, 0); Start-Sleep -Milliseconds 300 }
Section 'actions' {
    Show-View 'btnViewDevice'
    # The reopened window restores the settings of the last run, which can include Site only. The actions need a device inspection.
    $siteOnly = Get-El $win 'chkSiteOnly'
    if ($siteOnly.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq 'On') { Toggle-El $siteOnly }
    Set-Text (Get-El $win 'txtDevice') $Capture.Device; Invoke-El (Get-El $win 'btnInspect'); Wait-Idle
    Toggle-El (Get-El $win 'toggleActions'); Start-Sleep -Milliseconds 800
    Shot $win 'actions-device-buttons'
    Invoke-El (Get-El $win 'btnPolicyUpdate'); $dlg = Find-Top 'Client Policy Update' 15
    Shot $dlg 'actions-confirm-dialog'
    Invoke-El (Get-El $dlg 'btnActionDryRun')
    if (-not (Wait-RunRow 10)) { throw 'The running-actions list did not show the dry run.' }
    Shot $win 'actions-running-list' -Now
    Wait-NoRun
    $res = Find-Top 'Action Result' 15; Shot $res 'actions-result'; Close-ResultWindows
    # The close warning: close the window right after a dry run starts, then choose Wait.
    # Find the Close button before the dialog opens, and the dry run button at once: the dry run must still be open when the window closes.
    $closeButton = Get-El $win 'Close'
    Invoke-El (Get-El $win 'btnFullInventory'); $dlg = Find-Top 'Full Hardware Inventory' 15
    $dryButton = Get-El $dlg 'btnActionDryRun'
    Invoke-El $dryButton
    Invoke-El $closeButton
    $warn = Find-Top 'Actions Still Running' 15
    Shot $warn 'actions-close-warning'
    Invoke-El (Get-El $warn 'btnWait'); Start-Sleep -Milliseconds 800
    Wait-NoRun; Close-ResultWindows
}
# The right-click menus of the Updates and Applications panels and the uninstall confirmation. Enable actions stays on from the section before.
# This section has its own name so that a run with -Section can leave it out: its guard stops the capture on a workstation
# that has no harmless uninstallable row.
Section 'action menus' {
    # The menu is a popup: Shot -Hover keeps it open and it is in the image.
    Show-View 'btnViewApps'; Hide-LogTail
    # The name filter keeps a lab application with a personal publisher name out of the images (D-05). It is the whole name of the row.
    $uninstallApp = if ($Capture.UninstallApp) { [string]$Capture.UninstallApp } else { 'Microsoft Visual C++ 2022 X86 Minimum Runtime' }
    Set-Text (Get-El $win 'txtAppFilter') $uninstallApp; Start-Sleep -Milliseconds 400
    Select-AppType 'MSI'
    # A harmless named row with the Uninstall entry on: the name of a row in UI Automation lists its properties.
    # Never the Configuration Manager console (POLICY 2a): the guard stops the capture before the right click.
    # This row is a system component on a plain lab device (no Uninstall entry), and then the capture stops with that message.
    $appRow = Find-NamedItem (Get-El $win 'gridApps') ('*' + $uninstallApp + '*')
    if ($appRow.Current.Name -like '*Configuration Manager*') { throw ('The capture selected a Configuration Manager row: ' + $appRow.Current.Name) }
    if ($appRow.Current.Name -notlike '*CanUninstall=True*') { throw ('The selected application row has no Uninstall entry: ' + $appRow.Current.Name) }
    RightClick-El $appRow; Shot $win 'apps-context-menu' -Hover
    # The first entry of the open menu is Uninstall...: the Down key selects it and Enter opens the confirmation dialog.
    Send-Keys '{DOWN}'; Send-Keys '{ENTER}'; $dlg = Find-Top 'Uninstall Application' 15
    Shot $dlg 'apps-uninstall-confirm'
    Invoke-El (Get-El $dlg 'btnActionCancel'); Start-Sleep -Milliseconds 600
    Select-AppType 'All'
    # The workstation can list no required update (the site has none for it). The Updates menu then comes from the server,
    # which lists rows of the site. The menu entries are off for a site row, as the guide says.
    Show-View 'btnViewDevice'; Set-Text (Get-El $win 'txtDevice') $Capture.SecondDevice; Invoke-El (Get-El $win 'btnInspect'); Wait-Idle
    Show-View 'btnViewUpdates'; Hide-LogTail
    RightClick-El (Find-Item (Get-El $win 'gridUpdates') '*Source=Device*'); Shot $win 'updates-context-menu' -Hover; Send-Keys '{ESC}'
}
# Enable actions is on from the section 'actions'. This section turns it off at its end.
Section 'collection menus' {
    # The collection images use the server: the collections of the workstation hold test collections of other tools.
    Show-View 'btnViewDevice'; Set-Text (Get-El $win 'txtDevice') $Capture.SecondDevice; Invoke-El (Get-El $win 'btnInspect'); Wait-Idle
    Show-View 'btnViewCollections'; Hide-LogTail
    RightClick-El (Find-Item (Get-El $win 'gridCollections') '*'); Shot $win 'collections-context-menu' -Hover; Send-Keys '{ESC}'
    Invoke-El (Get-El $win 'btnAddCollection'); $pick = Find-Top 'Add to Collection' 90
    $null = Get-El $pick 'btnCancel'
    Set-Text (Get-El $pick 'txtPickerFilter') 'All'; Start-Sleep -Milliseconds 600
    Shot $pick 'collections-browser'
    Invoke-El (Get-El $pick 'btnCancel'); Start-Sleep -Milliseconds 800
    Toggle-El (Get-El $win 'toggleActions'); Start-Sleep -Milliseconds 600
}
Section 'device list' {
    Show-View 'btnViewDeviceList'
    Set-Text (Get-El $win 'txtListName') 'CLIENT*'
    Invoke-El (Get-El $win 'btnListSearch'); Wait-Idle
    Select-El (Find-Item (Get-El $win 'gridDeviceList') '*CLIENT01*'); Start-Sleep -Milliseconds 500; Hide-LogTail
    Shot $win 'device-list-results'
}
Stop-App 'start-deviceinspector.ps1'
