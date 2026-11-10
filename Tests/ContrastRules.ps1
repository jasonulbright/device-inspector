# Contrast rules for the window tests. Text must reach 4.5:1 (3:1 for large text) and a
# control border 3:1, enabled and disabled, in both themes. There is no list of known
# defects: a test passes only with zero violations.

function Test-LargeText {
    # WCAG large text: 24 px, or 18.66 px and bold. It needs 3:1; other text needs 4.5:1.
    param([Parameter(Mandatory)]$Row)
    return ($Row.Size -ge 24 -or ($Row.Bold -and $Row.Size -ge 18.66))
}

function Get-ContrastViolation {
    # The one place that decides what a contrast violation is. The window test and
    # Show-ContrastViolations.ps1 both call it. $Views are measured views (Text,
    # Interactive and TitleBar). Each result is one line that names the control and the value.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Views)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($v in $Views) {
        foreach ($r in $v.Text) {
            $min = if (Test-LargeText $r) { 3.0 } else { 4.5 }
            if ($r.Ratio -lt $min) { [void]$lines.Add(('text "{0}" ({1}) {2} on {3} = {4}' -f $r.Text, $r.Name, $r.Foreground, $r.Backdrop, $r.Ratio)) }
        }
        foreach ($c in $v.Interactive) {
            foreach ($metric in 'EnabledText', 'DisabledText', 'EnabledBorder', 'DisabledBorder') {
                $value = $c.$metric
                if ($null -eq $value) { continue }
                $min = if ($metric -like '*Text') { 4.5 } else { 3.0 }
                if ($value -lt $min) {
                    $detail = if ($metric -eq 'EnabledText') { $c.EnabledDetail } elseif ($metric -eq 'DisabledText') { $c.DisabledDetail } else { $null }
                    [void]$lines.Add(('{0}:{1} = {2}{3}' -f $c.Name, $metric, $value, $(if ($detail) { ' (' + $detail + ')' })))
                }
            }
        }
        if ($v.TitleBar) {
            foreach ($state in 'Active', 'Inactive') {
                $ratio = $v.TitleBar.$state
                if ($null -ne $ratio -and $ratio -lt 4.5) { [void]$lines.Add(('titlebar:{0} = {1}' -f $state, $ratio)) }
            }
        }
    }
    return @($lines | Sort-Object -Unique)
}
