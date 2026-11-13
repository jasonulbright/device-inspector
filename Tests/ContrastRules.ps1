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
        # A selected row or item shows white text on the theme highlight, and the text keeps 4.5:1.
        foreach ($r in @(if ($v.PSObject.Properties['Selected']) { $v.Selected })) {
            if ($null -ne $r.TextRatio -and $r.TextRatio -lt 4.5) { [void]$lines.Add(('selected {0}: text = {1} ({2})' -f $r.Type, $r.TextRatio, $r.Detail)) }
            if (-not $r.IsHighlight) { [void]$lines.Add(('selected {0}: the backdrop {1} is not the theme highlight' -f $r.Type, $r.Backdrop)) }
        }
        foreach ($r in @(if ($v.PSObject.Properties['ComboItems']) { $v.ComboItems })) {
            if (-not $r.Applied) { [void]$lines.Add(('combo box {0}: the {1} state was not applied ({2})' -f $r.Name, $r.State, $r.Detail)); continue }
            if ($null -ne $r.TextRatio -and $r.TextRatio -lt 4.5) { [void]$lines.Add(('combo box {0} {1} item: text = {2} ({3})' -f $r.Name, $r.State, $r.TextRatio, $r.Detail)) }
            if (-not $r.IsHighlight) { [void]$lines.Add(('combo box {0} {1} item: the backdrop is not the theme highlight' -f $r.Name, $r.State)) }
        }
        # A button shows the hover border and the keyboard focus border (3:1), and keeps 4.5:1 text in the hover and the pressed state.
        foreach ($r in @(if ($v.PSObject.Properties['ButtonStates']) { $v.ButtonStates })) {
            if (-not ($r.Parts -and $r.Keys -and $r.HoverApplied -and $r.FocusApplied -and $r.PressedApplied)) { [void]$lines.Add(('{0}: the state probe did not run (parts {1}, keys {2}, hover {3}, focus {4}, pressed {5})' -f $r.Name, $r.Parts, $r.Keys, $r.HoverApplied, $r.FocusApplied, $r.PressedApplied)); continue }
            if ($null -ne $r.HoverBorder -and $r.HoverBorder -lt 3.0) { [void]$lines.Add(('{0}:HoverBorder = {1}' -f $r.Name, $r.HoverBorder)) }
            if ($null -ne $r.FocusBorder -and $r.FocusBorder -lt 3.0) { [void]$lines.Add(('{0}:FocusBorder = {1}' -f $r.Name, $r.FocusBorder)) }
            if ($null -ne $r.HoverText -and $r.HoverText -lt 4.5) { [void]$lines.Add(('{0}:HoverText = {1}' -f $r.Name, $r.HoverText)) }
            if ($null -ne $r.PressedText -and $r.PressedText -lt 4.5) { [void]$lines.Add(('{0}:PressedText = {1}' -f $r.Name, $r.PressedText)) }
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
