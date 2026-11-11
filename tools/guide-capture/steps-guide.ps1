# The guide steps. main.ps1 dot-sources this file in the interactive session of the lab workstation.
# $Capture holds the site code, the SMS Provider and the device names (Invoke-GuideCapture.ps1).
# The app only reads. No step changes the site or a device.
$win = Start-App 'start-deviceinspector.ps1' 'Device Inspector'
Size-Win $win 1440 900
$win = Find-Top 'Device Inspector' 10
function Wait-Idle { Start-Sleep -Seconds 2; $null = Wait-Until { (Get-El $win 'btnInspect').Current.IsEnabled } 240; Start-Sleep -Seconds 1 }
function Show-View([string]$Button) { Invoke-El (Get-El $win $Button); Start-Sleep -Milliseconds 600 }
function Close-Message($Box) { Invoke-El (Get-El $Box 'btnPrimary'); Start-Sleep -Milliseconds 500 }
function Select-AppType([string]$Item) { Expand-El (Get-El $win 'cboAppType'); Start-Sleep -Milliseconds 400; Click-El (Find-Role $win 'ListItem' $Item); Start-Sleep -Milliseconds 600 }

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
    Wait-Idle; Shot $win 'device-panel'
    Show-View 'btnViewApps'; Set-Text (Get-El $win 'txtAppFilter') 'micro'; Start-Sleep -Milliseconds 600; Shot $win 'apps-panel'
    Set-Text (Get-El $win 'txtAppFilter') 'edge'; Start-Sleep -Milliseconds 600; Shot $win 'apps-filter-text'
    Set-Text (Get-El $win 'txtAppFilter') 'micro'; Start-Sleep -Milliseconds 400
    Expand-El (Get-El $win 'cboAppType'); Start-Sleep -Milliseconds 500; Shot $win 'apps-type-list' -Hover
    Click-El (Find-Role $win 'ListItem' 'MSI'); Start-Sleep -Milliseconds 600; Shot $win 'apps-type-msi'
    Select-AppType 'EXE'; Shot $win 'apps-type-exe'
    Select-AppType 'All'
    $row = (Get-El $win 'gridApps').FindFirst('Descendants', (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem)))
    if (-not $row) { throw 'The Applications grid has no row.' }
    # Shot copies the screen area of the window, so the open context menu is in the image.
    # -Hover keeps the mouse and the focus where they are, so the menu stays open.
    RightClick-El $row; Shot $win 'apps-context-menu' -Hover; Send-Keys '{ESC}'
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
    Toggle-El (Get-El $win 'chkSiteOnly'); Set-Text (Get-El $win 'txtSiteServer') ''; Invoke-El (Get-El $win 'btnInspect'); Wait-Idle; Shot $win 'device-device-only'
    Set-Text (Get-El $win 'txtSiteServer') $Capture.SmsProvider
}
Section 'enter key' {
    Show-View 'btnViewDevice'; Set-Text (Get-El $win 'txtDevice') $Capture.Device
    Click-El (Get-El $win 'txtDevice'); Send-Keys '{ENTER}'; Start-Sleep -Milliseconds 700; Shot $win 'inspect-by-enter'; Wait-Idle
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
    $win = Start-App 'start-deviceinspector.ps1' 'Device Inspector'; Shot $win 'start-reopen-saved-state'
}
Stop-App 'start-deviceinspector.ps1'
