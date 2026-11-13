# Helpers of Theme.Guard.Tests.ps1. Dot-source from BeforeDiscovery and from BeforeAll.
# The helpers parse files. They create no WPF control, so they run on Windows PowerShell 5.1 and PowerShell 7.
#

$script:strRepoRoot = Split-Path -Path $PSScriptRoot -Parent
$script:arrThemeProperty = @('FontSize', 'FontWeight', 'FontStyle', 'TextDecorations', 'FontFamily', 'FontStretch')
$script:strBannedPattern = '(?i)\b(easily|simply|seamless(ly)?|powerful|robust|streamline[sd]?|streamlining|quickly|just|effortless(ly)?|intuitive(ly)?|handy|helps you|allows you to)\b'
$script:strXamlNamespace = 'http://schemas.microsoft.com/winfx/2006/xaml'
$script:strExceptionPattern = '\$_(?![\w])|\$PSItem|Exception|ErrorMsg|ErrorMessage|DetailMsg|\.Error\b|\.Detail\b|\$err\b|\$ex\b'
$script:strRequiresLine = "#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }"

# The leaf of a property name: Border.Background, Controls:ControlsHelper.MouseOverBorderBrush and Background give the last word.
function Get-PropertyLeaf {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return '' }
    return ($Name -split '[.:]')[-1]
}

# True when a brush value names an accent or a blue color.
function Test-BlueBrush {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match 'MahApps\.(Brushes|Colors)\.(Accent\d*|AccentBase|Highlight\d*|Button\.Flat\.Background\.Pressed)\b') { return $true }
    if ($Value -match 'SystemColors\.Highlight(Brush|Color)?(Key)?\b') { return $true }
    if ($Value -match '^\s*\{(Static|Dynamic)Resource\s+(\w+\.)*Highlight\d*\s*\}\s*$') { return $true }
    if ($Value -match '(?i)^\s*(blue|dodgerblue|royalblue|steelblue|navy|mediumblue|darkblue|cornflowerblue|deepskyblue|lightskyblue|skyblue)\s*$') { return $true }
    $strHex = $Value.Trim()
    if ($strHex -match '^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$') { $strHex = '#{0}{0}{1}{1}{2}{2}' -f $Matches[1], $Matches[2], $Matches[3] }
    if ($strHex -match '^#(?:[0-9A-Fa-f]{2})?([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})$') {
        $dblRed = [Convert]::ToInt32($Matches[1], 16) / 255.0
        $dblGreen = [Convert]::ToInt32($Matches[2], 16) / 255.0
        $dblBlue = [Convert]::ToInt32($Matches[3], 16) / 255.0
        $dblMax = [Math]::Max($dblRed, [Math]::Max($dblGreen, $dblBlue))
        $dblMin = [Math]::Min($dblRed, [Math]::Min($dblGreen, $dblBlue))
        $dblDelta = $dblMax - $dblMin
        if ($dblDelta -lt 0.2 -or $dblMax -eq 0) { return $false }
        if ($dblMax -ne $dblBlue) { return $false }
        $dblHue = 60.0 * (4.0 + (($dblRed - $dblGreen) / $dblDelta))
        return ($dblHue -ge 190 -and $dblHue -le 260)
    }
    return $false
}

function Test-WhiteBrush {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -match '(?i)^\s*(white|#FFFFFF|#FFFFFFFF|#FFF)\s*$' -or $Value -match 'MahApps\.Brushes\.(Ideal|ThemeIdeal)Foreground')
}

# A literal color is a hex value or any bare alphabetic value (White, Orange, Silver, WhiteSmoke). A value in braces is a resource.
function Test-LiteralColor {
    param([string]$Value)
    return (($Value -match '^\s*#[0-9A-Fa-f]{3,8}\s*$') -or ($Value -match '^\s*[A-Za-z]+\s*$'))
}

# The value of a Setter: the Value attribute, or the Color attribute of a nested brush element at any depth.
function Get-SetterValue {
    param($Setter)
    if ($Setter.HasAttribute('Value')) { return $Setter.GetAttribute('Value') }
    $objNode = $Setter.SelectSingleNode('.//*[@Color]')
    if ($objNode) { return $objNode.GetAttribute('Color') }
    return ''
}

# The direct Setter children of a node whose property leaf matches a pattern.
function Get-SetterChild {
    param($Node, [string]$LeafPattern)
    if (-not $Node) { return @() }
    return @($Node.ChildNodes | Where-Object { $_.LocalName -eq 'Setter' -and (Get-PropertyLeaf $_.GetAttribute('Property')) -match $LeafPattern })
}

# The x:Key of a node.
function Get-XamlKey {
    param($Node)
    return $Node.GetAttribute('Key', $script:strXamlNamespace)
}

# The keyed nodes of a document as a table key -> node. Name is the element (Style, ControlTemplate), Target limits Style nodes
# to one TargetType. The nodes of the context document join the table first, so that a node of the document itself replaces
# a node of the context with the same key.
function Get-KeyedNodeTable {
    param([string]$Text, [string]$Context = '', [string]$Name = 'Style', [string]$Target = '')
    $hashTable = @{}
    foreach ($strSource in @($Context, $Text)) {
        if ([string]::IsNullOrWhiteSpace($strSource)) { continue }
        [xml]$xmlSource = $strSource
        foreach ($objNode in @($xmlSource.SelectNodes(("//*[local-name()='{0}']" -f $Name)))) {
            if ($Target -and $objNode.GetAttribute('TargetType') -ne $Target) { continue }
            $strKey = Get-XamlKey $objNode
            if ($strKey) { $hashTable[$strKey] = $objNode }
        }
    }
    return $hashTable
}

# The files of the repository below a folder, with the path relative to the repository root. The filter works on the
# relative path, so a worktree below .claude does not exclude itself.
function Get-RepoFile {
    param([string]$Filter, [string[]]$Skip = @('.claude', '.git', 'TestOutput', 'Logs', 'Reports'), [string]$Root = '')
    if (-not $Root) { $Root = $script:strRepoRoot }
    $strRoot = $Root.TrimEnd('\')
    # The top level is read first, so that a skipped folder (.claude holds worktrees) is never walked.
    foreach ($objTop in @(Get-ChildItem -LiteralPath $strRoot -Force)) {
        if ($Skip -contains $objTop.Name) { continue }
        $arrFile = @()
        if ($objTop.PSIsContainer) { $arrFile = @(Get-ChildItem -LiteralPath $objTop.FullName -Filter $Filter -File -Recurse) }
        elseif ($objTop.Name -like $Filter) { $arrFile = @($objTop) }
        foreach ($objFile in $arrFile) {
            $strRelative = $objFile.FullName.Substring($strRoot.Length + 1)
            [PSCustomObject]@{ File = $objFile; Relative = $strRelative; Top = ($strRelative -split '\\')[0] }
        }
    }
}

# Every XAML document of the repository: the XAML files and the XAML here-strings of the scripts. Kind is Main (MainWindow.xaml),
# Module (a page below Modules), Dialog (a here-string of the app script), Suite (a here-string of SuiteCommon) or Other.
# Context is the text of MainWindow.xaml for a module page (it holds the styles the page names), and empty for the others.
function Get-XamlDocument {
    $arrDoc = @()
    foreach ($objItem in @(Get-RepoFile -Filter '*.xaml')) {
        $strKind = 'Other'
        if ($objItem.Relative -eq 'MainWindow.xaml') { $strKind = 'Main' }
        elseif ($objItem.Top -eq 'Modules') { $strKind = 'Module' }
        $arrDoc += [PSCustomObject]@{ Source = $objItem.File.Name; Kind = $strKind; Text = (Get-Content -LiteralPath $objItem.File.FullName -Raw); Context = '' }
    }
    foreach ($strFilter in '*.ps1', '*.psm1') {
        foreach ($objItem in @(Get-RepoFile -Filter $strFilter -Skip @('.claude', '.git', 'Tests', 'tools', 'TestOutput', 'Logs', 'Reports'))) {
            $strRaw = Get-Content -LiteralPath $objItem.File.FullName -Raw
            $strKind = 'Dialog'
            if ($objItem.File.Name -match 'SuiteCommon') { $strKind = 'Suite' }
            $intIndex = 0
            foreach ($objMatch in [regex]::Matches($strRaw, "(?s)@'\r?\n(\s*<[^\r\n]*Window.*?)\r?\n'@")) {
                $intIndex++
                $arrDoc += [PSCustomObject]@{ Source = ('{0} here-string {1}' -f $objItem.File.Name, $intIndex); Kind = $strKind; Text = $objMatch.Groups[1].Value; Context = '' }
            }
        }
    }
    $objMain = @($arrDoc | Where-Object { $_.Kind -eq 'Main' }) | Select-Object -First 1
    if ($objMain) {
        foreach ($objDoc in @($arrDoc | Where-Object { $_.Kind -eq 'Module' })) { $objDoc.Context = $objMain.Text }
    }
    return $arrDoc
}

# Resolves {StaticResource Key} and {DynamicResource Key} to the key.
function Get-ResourceKey {
    param([string]$Value)
    if ($Value -match '^\{(?:Static|Dynamic)Resource\s+([^}\s]+)\}$') { return $Matches[1] }
    return ''
}

# Every key named by a {StaticResource Key} or {DynamicResource Key} in the attributes of a document. A reference that has a
# nested markup extension, such as {DynamicResource {x:Static SystemColors.HighlightBrushKey}}, is left out.
function Get-ResourceReference {
    param([string]$Text)
    [xml]$xml = $Text
    foreach ($objAttribute in @($xml.SelectNodes('//@*'))) {
        foreach ($objMatch in [regex]::Matches([string]$objAttribute.Value, '\{(?:Static|Dynamic)Resource\s+([^\s{}]+)\s*\}')) { $objMatch.Groups[1].Value }
    }
}

# Every x:Key of a document.
function Get-DefinedKey {
    param([string]$Text)
    [xml]$xml = $Text
    foreach ($objAttribute in @($xml.SelectNodes("//@*[local-name()='Key']"))) { [string]$objAttribute.Value }
}

# The resource keys that a document names with {StaticResource} or {DynamicResource} and that the context document does not
# define with x:Key. The keys of MahApps (MahApps.*), the system colors (SystemColors*) and x: references are not the app's own.
function Get-UnresolvedResourceKey {
    param([string]$Text, [string]$Context)
    $arrDefined = @(Get-DefinedKey -Text $Context)
    foreach ($strKey in @(Get-ResourceReference -Text $Text | Sort-Object -Unique)) {
        if ($strKey -match '^(MahApps\.|SystemColors|x:)') { continue }
        if ($arrDefined -cnotcontains $strKey) { $strKey }
    }
}

# A Foreground setter of the same scope is white: a sibling Setter, or a Setter of the enclosing Style.
function Test-WhiteForegroundInScope {
    param($Setter)
    $arrScope = @($Setter.ParentNode)
    $objStyle = $Setter.ParentNode
    while ($objStyle -and $objStyle.LocalName -ne 'Style' -and $objStyle.LocalName -ne 'ControlTemplate') { $objStyle = $objStyle.ParentNode }
    if ($objStyle) { $arrScope += $objStyle }
    foreach ($objScope in $arrScope) {
        foreach ($objForeground in @(Get-SetterChild -Node $objScope -LeafPattern 'Foreground$')) {
            if (Test-WhiteBrush (Get-SetterValue $objForeground)) { return $true }
        }
    }
    return $false
}

# Returns one text per blue-background rule that has no white foreground. It reads Setter nodes of styles, templates and
# triggers (also with a qualified property such as Border.Background or Controls:ControlsHelper.MouseOverBackground and with a nested brush
# whose Color attribute is at any depth), attributes of elements, and property elements such as <Border.Background>.
function Get-BlueWithoutWhite {
    param([string]$Text, [string]$Source)
    [xml]$xml = $Text
    $listFound = New-Object System.Collections.Generic.List[string]
    $strContainer = '^(Border|Grid|StackPanel|DockPanel|WrapPanel|Canvas|UniformGrid)$'
    foreach ($objElement in @($xml.SelectNodes('//*'))) {
        if ($objElement.LocalName -eq 'Setter') {
            if ((Get-PropertyLeaf $objElement.GetAttribute('Property')) -match 'Background$') {
                $strValue = Get-SetterValue $objElement
                if ((Test-BlueBrush $strValue) -and -not (Test-WhiteForegroundInScope $objElement)) {
                    [void]$listFound.Add(('{0}: Setter {1} {2} in <{3}> has no white Foreground' -f $Source, $objElement.GetAttribute('Property'), $strValue, $objElement.ParentNode.LocalName))
                }
            }
            continue
        }
        if ($objElement.LocalName -match '\.\w*Background$') {
            $objBrush = $objElement.SelectSingleNode('.//*[@Color]')
            if ($objBrush -and (Test-BlueBrush $objBrush.GetAttribute('Color')) -and $objElement.ParentNode -and -not (Test-WhiteBrush $objElement.ParentNode.GetAttribute('Foreground'))) {
                [void]$listFound.Add(('{0}: <{1}> has a blue brush and its owner has no white Foreground' -f $Source, $objElement.LocalName))
            }
            continue
        }
        foreach ($objAttribute in @($objElement.Attributes | Where-Object { (Get-PropertyLeaf $_.Name) -match 'Background$' })) {
            if (-not (Test-BlueBrush $objAttribute.Value)) { continue }
            $strOwnForeground = ''
            foreach ($objForeground in @($objElement.Attributes | Where-Object { (Get-PropertyLeaf $_.Name) -match 'Foreground$' })) {
                if (Test-WhiteBrush $objForeground.Value) { $strOwnForeground = $objForeground.Value }
            }
            if ($strOwnForeground) { continue }
            # A container has no Foreground. Its text elements must carry the white foreground themselves.
            if ($objElement.LocalName -match $strContainer) {
                $arrText = @($objElement.SelectNodes(".//*[local-name()='TextBlock' or local-name()='Label' or local-name()='ContentPresenter']"))
                $boolAllWhite = ($arrText.Count -gt 0)
                foreach ($objText in $arrText) { if (-not (Test-WhiteBrush $objText.GetAttribute('Foreground'))) { $boolAllWhite = $false } }
                if ($boolAllWhite) { continue }
            }
            [void]$listFound.Add(('{0}: <{1}> {2} {3} has no white Foreground' -f $Source, $objElement.LocalName, $objAttribute.Name, $objAttribute.Value))
        }
    }
    return $listFound.ToArray()
}

# Returns the text of a script without comment lines and block comments, so that a match cannot come from a comment.
function Remove-ScriptComment {
    param([string]$Text)
    $strText = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return (($strText -split "\r?\n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
}

# The syntax tree of a script file.
function Get-ScriptAst {
    param([string]$Path)
    return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
}

# Every string of a script: the constant strings and the text parts of expandable strings.
function Get-ScriptString {
    param([string]$Path)
    $objAst = Get-ScriptAst -Path $Path
    $arrNode = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
    foreach ($objNode in $arrNode) { [string]$objNode.Value }
}

# The calls of one or more commands below a node of a syntax tree.
function Get-AstCommand {
    param($Ast, [string[]]$Name)
    return @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $Name -contains $n.GetCommandName() }, $true))
}

# A function definition of a syntax tree by name.
function Get-AstFunction {
    param($Ast, [string]$Name)
    return $Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
}

# The text of the value of a named parameter in a call, for -Name value and for -Name:value. Null when the parameter is absent.
function Get-CommandParameterValue {
    param($Command, [string]$Name)
    $arrElement = @($Command.CommandElements)
    for ($intIndex = 0; $intIndex -lt $arrElement.Count; $intIndex++) {
        $objElement = $arrElement[$intIndex]
        if ($objElement -is [System.Management.Automation.Language.CommandParameterAst] -and $objElement.ParameterName -eq $Name) {
            if ($objElement.Argument) { return $objElement.Argument.Extent.Text }
            if ($intIndex + 1 -lt $arrElement.Count) { return $arrElement[$intIndex + 1].Extent.Text }
        }
    }
    return $null
}

# The script block that a script assigns to a variable, such as $script:ApplyTheme = { ... }. The name is the variable path
# without the dollar sign: script:ApplyTheme.
function Get-AssignedScriptBlock {
    param($Ast, [string]$Variable)
    $arrAssign = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq $Variable }, $true)
    foreach ($objAssign in $arrAssign) {
        $objBlock = $objAssign.Right.Find({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
        if ($objBlock) { return $objBlock }
    }
    return $null
}

# The variable names of the buttons that the shell hands to the theme: each Button value of a hashtable that is assigned
# to $script:ViewButtons, and the -OptionsButton argument of Initialize-SuiteTheme.
function Get-ShellThemedButton {
    param($Ast)
    $listName = New-Object System.Collections.Generic.List[string]
    $arrAssign = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'script:ViewButtons' }, $true)
    foreach ($objAssign in $arrAssign) {
        foreach ($objHash in @($objAssign.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))) {
            foreach ($objPair in $objHash.KeyValuePairs) {
                if ([string]$objPair.Item1.Value -eq 'Button') { [void]$listName.Add($objPair.Item2.Extent.Text.Trim().TrimStart('$')) }
            }
        }
    }
    foreach ($objCall in @(Get-AstCommand -Ast $Ast -Name 'Initialize-SuiteTheme')) {
        $strValue = Get-CommandParameterValue -Command $objCall -Name 'OptionsButton'
        if ($strValue) { [void]$listName.Add($strValue.Trim().TrimStart('$')) }
    }
    return $listName.ToArray()
}

# The text a user can read in a XAML document: tooltips and text attributes.
function Get-XamlUiText {
    param([string]$Text)
    [xml]$xml = $Text
    foreach ($objElement in @($xml.SelectNodes('//*'))) {
        foreach ($objAttribute in @($objElement.Attributes)) {
            if ($objAttribute.LocalName -match '^(ToolTip|Text|Content|Header|Title|Watermark|OnContent|OffContent|ToolTipService.*)$' -or $objAttribute.Name -match 'Watermark$') {
                if ($objAttribute.Value -notmatch '^\{') { $objAttribute.Value }
            }
        }
    }
}

# Returns one text per assignment of a blue string literal to a Background property in a script.
function Get-ScriptBlueBackground {
    param([string]$Path)
    $objAst = Get-ScriptAst -Path $Path
    $arrAssign = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)
    foreach ($objAssign in $arrAssign) {
        if ([string]$objAssign.Left.Member.Value -ne 'Background') { continue }
        # A white or ideal foreground set on the same control in the same block makes the blue background safe.
        $strTarget = $objAssign.Left.Expression.Extent.Text
        $arrSibling = @()
        if ($objAssign.Parent.PSObject.Properties['Statements']) { $arrSibling = @($objAssign.Parent.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left -is [System.Management.Automation.Language.MemberExpressionAst] }) }
        $arrWhite = @($arrSibling | Where-Object { [string]$_.Left.Member.Value -eq 'Foreground' -and $_.Left.Expression.Extent.Text -eq $strTarget -and $_.Right.Extent.Text -match '(?i)IdealForeground|White|#FFFFFF' })
        if ($arrWhite.Count -gt 0) { continue }
        $arrString = $objAssign.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
        foreach ($objString in $arrString) {
            if (Test-BlueBrush ([string]$objString.Value)) { '{0}:{1}: Background {2}' -f (Split-Path -Leaf $Path), $objAssign.Extent.StartLineNumber, $objString.Value }
        }
    }
}

# Returns one text per style that is based on a MahApps accent button and has no white foreground.
function Get-AccentButtonWithoutWhite {
    param([string]$Text, [string]$Source)
    [xml]$xml = $Text
    $listFound = New-Object System.Collections.Generic.List[string]
    foreach ($objStyle in @($xml.SelectNodes("//*[local-name()='Style']"))) {
        if ($objStyle.GetAttribute('BasedOn') -notmatch 'Button\.(Square\.|Flat\.)?Accent') { continue }
        $objForeground = Get-SetterChild -Node $objStyle -LeafPattern '^Foreground$' | Select-Object -First 1
        if (-not $objForeground -or -not (Test-WhiteBrush (Get-SetterValue $objForeground))) {
            [void]$listFound.Add(('{0}: accent button style {1} has no white Foreground' -f $Source, (Get-XamlKey $objStyle)))
        }
    }
    return $listFound.ToArray()
}

# True when a style node has a trigger on the property (IsSelected, IsHighlighted) that sets a blue Background and a white Foreground.
function Test-StateTrigger {
    param($Style, [string]$Property)
    foreach ($objTrigger in @($Style.SelectNodes(".//*[local-name()='Trigger'][@Property='$Property']"))) {
        $objBackground = Get-SetterChild -Node $objTrigger -LeafPattern '^Background$' | Select-Object -First 1
        $objForeground = Get-SetterChild -Node $objTrigger -LeafPattern '^Foreground$' | Select-Object -First 1
        if ($objBackground -and (Test-BlueBrush (Get-SetterValue $objBackground)) -and $objForeground -and (Test-WhiteBrush (Get-SetterValue $objForeground))) { return $true }
    }
    return $false
}

# Returns one text per list, combo box, tree, grid row or grid cell without a selected-state style. Each item control of a
# document takes an explicit item container style (a base style is not enough, MahApps sets its own); the style has a
# blue background with a white foreground for IsSelected, and for a combo box item also for IsHighlighted. The style keys
# resolve against the styles of the document and the styles of the context (MainWindow.xaml for a module page).
function Get-SelectedStateViolation {
    param([string]$Text, [string]$Source, [string]$Context = '')
    [xml]$xml = $Text
    $listFound = New-Object System.Collections.Generic.List[string]
    $hashStyle = Get-KeyedNodeTable -Text $Text -Context $Context -Name 'Style'
    $hashRule = @(
        @{ Control = 'ListBox'; Attribute = 'ItemContainerStyle'; Item = 'ListBoxItem'; Property = @('IsSelected') }
        @{ Control = 'ListView'; Attribute = 'ItemContainerStyle'; Item = 'ListViewItem'; Property = @('IsSelected') }
        @{ Control = 'ComboBox'; Attribute = 'ItemContainerStyle'; Item = 'ComboBoxItem'; Property = @('IsSelected', 'IsHighlighted') }
        @{ Control = 'TreeView'; Attribute = 'ItemContainerStyle'; Item = 'TreeViewItem'; Property = @('IsSelected') }
        @{ Control = 'DataGrid'; Attribute = 'CellStyle'; Item = 'DataGridCell'; Property = @('IsSelected') }
    )
    foreach ($hashControl in $hashRule) {
        foreach ($objElement in @($xml.SelectNodes(("//*[local-name()='{0}']" -f $hashControl.Control)))) {
            $strName = $objElement.GetAttribute('Name', $script:strXamlNamespace)
            $strKey = Get-ResourceKey $objElement.GetAttribute($hashControl.Attribute)
            if (-not $strKey -or -not $hashStyle.ContainsKey($strKey)) {
                [void]$listFound.Add(('{0}: {1} {2} has no {3}' -f $Source, $hashControl.Control, $strName, $hashControl.Attribute))
                continue
            }
            foreach ($strProperty in $hashControl.Property) {
                if (-not (Test-StateTrigger -Style $hashStyle[$strKey] -Property $strProperty)) {
                    [void]$listFound.Add(('{0}: style {1} of {2} {3} has no blue Background with white Foreground for {4}' -f $Source, $strKey, $hashControl.Control, $strName, $strProperty))
                }
            }
        }
    }
    foreach ($objElement in @($xml.SelectNodes("//*[local-name()='DataGrid']"))) {
        $strName = $objElement.GetAttribute('Name', $script:strXamlNamespace)
        $strGridStyle = Get-ResourceKey $objElement.GetAttribute('Style')
        $objRowStyle = $null
        if ($strGridStyle -and $hashStyle.ContainsKey($strGridStyle)) {
            $objRowSetter = Get-SetterChild -Node $hashStyle[$strGridStyle] -LeafPattern '^RowStyle$' | Select-Object -First 1
            if ($objRowSetter) { $strRowKey = Get-ResourceKey $objRowSetter.GetAttribute('Value'); if ($strRowKey -and $hashStyle.ContainsKey($strRowKey)) { $objRowStyle = $hashStyle[$strRowKey] } }
        }
        if (-not $objRowStyle -or -not (Test-StateTrigger -Style $objRowStyle -Property 'IsSelected')) {
            [void]$listFound.Add(('{0}: DataGrid {1} has no row style with a blue Background and a white Foreground for IsSelected' -f $Source, $strName))
        }
    }
    return $listFound.ToArray()
}

# Returns one text per button problem in a XAML document. Every Button has a Style whose chain of BasedOn
# styles ends at ThemedButtonStyle (the chain resolves through the context too). ThemedButtonStyle is the only button style
# of the document that is based on MahApps directly. No button, style or control template has a literal color: every Style and
# every ControlTemplate of the document is scanned, not only those of a button. Qualified properties and the Color attribute of a
# nested brush at any depth count.
function Get-ButtonThemeViolation {
    param([string]$Text, [string]$Source, [string]$Context = '')
    [xml]$xml = $Text
    $listFound = New-Object System.Collections.Generic.List[string]
    $hashOwn = Get-KeyedNodeTable -Text $Text -Name 'Style' -Target 'Button'
    $hashAll = Get-KeyedNodeTable -Text $Text -Context $Context -Name 'Style' -Target 'Button'
    $hashBased = @{}
    foreach ($strKey in @($hashAll.Keys)) { $hashBased[$strKey] = $hashAll[$strKey].GetAttribute('BasedOn') }
    $scriptResolve = {
        param($key)
        $hashSeen = @{}
        while ($key -and -not $hashSeen.ContainsKey($key)) {
            if ($key -eq 'ThemedButtonStyle') { return $true }
            $hashSeen[$key] = $true
            if (-not $hashBased.ContainsKey($key)) { return $false }
            $key = Get-ResourceKey $hashBased[$key]
        }
        return $false
    }
    foreach ($strKey in @($hashOwn.Keys)) {
        if ($strKey -ne 'ThemedButtonStyle' -and $hashBased[$strKey] -match 'MahApps\.') { [void]$listFound.Add(('{0}: Button style {1} is based on MahApps and not on ThemedButtonStyle' -f $Source, $strKey)) }
    }
    foreach ($objButton in @($xml.SelectNodes("//*[local-name()='Button']"))) {
        $strName = $objButton.GetAttribute('Name', $script:strXamlNamespace)
        $strKey = Get-ResourceKey $objButton.GetAttribute('Style')
        if (-not $strKey -or -not (& $scriptResolve $strKey)) {
            [void]$listFound.Add(('{0}: Button {1} does not take ThemedButtonStyle' -f $Source, $strName))
        }
        foreach ($objAttribute in @($objButton.Attributes)) {
            if ((Get-PropertyLeaf $objAttribute.Name) -match '(Background|Foreground|Brush)$' -and (Test-LiteralColor $objAttribute.Value)) { [void]$listFound.Add(('{0}: Button {1} sets {2} to the literal {3}' -f $Source, $strName, $objAttribute.Name, $objAttribute.Value)) }
        }
    }
    $arrScope = @($xml.SelectNodes("//*[local-name()='Style']")) + @($xml.SelectNodes("//*[local-name()='ControlTemplate']"))
    foreach ($objScope in $arrScope) {
        $strKey = Get-XamlKey $objScope
        foreach ($objNode in @($objScope.SelectNodes('descendant-or-self::*'))) {
            foreach ($objAttribute in @($objNode.Attributes)) {
                $strLeaf = Get-PropertyLeaf $objAttribute.Name
                if ($strLeaf -eq 'Value') {
                    if ((Get-PropertyLeaf $objNode.GetAttribute('Property')) -notmatch '(Background|Foreground|Brush)$') { continue }
                }
                elseif ($strLeaf -notmatch '^(Color|Fill|Stroke)$' -and $strLeaf -notmatch '(Background|Foreground|Brush)$') { continue }
                if (Test-LiteralColor $objAttribute.Value) { [void]$listFound.Add(('{0}: {1} {2} uses the literal color {3}' -f $Source, $objScope.LocalName, $strKey, $objAttribute.Value)) }
            }
        }
    }
    return $listFound.ToArray()
}

# Returns one text per problem in the button template ThemedButtonTemplate of a document:
#  - no Setter on the Opacity property, in the template and in every Button style of the document (and no Opacity attribute in the template)
#  - hover (IsMouseOver) sets BorderBrush to the theme foreground, and sets no Background or Foreground to a literal color
#  - pressed (IsPressed) swaps: Background is the theme foreground, TextElement.Foreground is the theme background
function Get-ButtonTemplateViolation {
    param([string]$Text, [string]$Source)
    [xml]$xml = $Text
    $listFound = New-Object System.Collections.Generic.List[string]
    $strForeground = '^\{DynamicResource MahApps\.Brushes\.ThemeForeground\}$'
    $strBackground = '^\{DynamicResource MahApps\.Brushes\.ThemeBackground\}$'
    $objTemplate = $xml.SelectSingleNode("//*[local-name()='ControlTemplate'][@*[local-name()='Key']='ThemedButtonTemplate']")
    if (-not $objTemplate) {
        [void]$listFound.Add(('{0}: has no ControlTemplate ThemedButtonTemplate' -f $Source))
        return $listFound.ToArray()
    }
    $arrScope = @($objTemplate) + @($xml.SelectNodes("//*[local-name()='Style'][@TargetType='Button']"))
    foreach ($objScope in $arrScope) {
        foreach ($objSetter in @($objScope.SelectNodes(".//*[local-name()='Setter']"))) {
            if ((Get-PropertyLeaf $objSetter.GetAttribute('Property')) -eq 'Opacity') {
                [void]$listFound.Add(('{0}: a Setter on Opacity in {1} {2}' -f $Source, $objScope.LocalName, (Get-XamlKey $objScope)))
            }
        }
    }
    foreach ($objNode in @($objTemplate.SelectNodes('.//*[@Opacity]'))) {
        [void]$listFound.Add(('{0}: <{1}> in ThemedButtonTemplate sets Opacity' -f $Source, $objNode.LocalName))
    }
    # The hover rule is a MultiTrigger on IsMouseOver and IsEnabled: a disabled button shows no hover border.
    $objHover = $objTemplate.SelectSingleNode(".//*[local-name()='MultiTrigger'][*[local-name()='MultiTrigger.Conditions']/*[local-name()='Condition'][@Property='IsMouseOver'][@Value='True']][*[local-name()='MultiTrigger.Conditions']/*[local-name()='Condition'][@Property='IsEnabled'][@Value='True']]")
    if (-not $objHover) {
        [void]$listFound.Add(('{0}: ThemedButtonTemplate has no hover MultiTrigger on IsMouseOver and IsEnabled' -f $Source))
    }
    else {
        $arrBorder = @(Get-SetterChild -Node $objHover -LeafPattern '^BorderBrush$')
        $arrBorderOk = @($arrBorder | Where-Object { (Get-SetterValue $_) -match $strForeground })
        if ($arrBorder.Count -eq 0 -or $arrBorderOk.Count -ne $arrBorder.Count) {
            [void]$listFound.Add(('{0}: the IsMouseOver trigger does not set BorderBrush to MahApps.Brushes.ThemeForeground' -f $Source))
        }
        foreach ($objSetter in @(Get-SetterChild -Node $objHover -LeafPattern '(Background|Foreground)$')) {
            if (Test-LiteralColor (Get-SetterValue $objSetter)) { [void]$listFound.Add(('{0}: the IsMouseOver trigger sets {1} to the literal {2}' -f $Source, $objSetter.GetAttribute('Property'), (Get-SetterValue $objSetter))) }
        }
    }
    $objPressed = $objTemplate.SelectSingleNode(".//*[local-name()='Trigger'][@Property='IsPressed']")
    if (-not $objPressed) {
        [void]$listFound.Add(('{0}: ThemedButtonTemplate has no IsPressed trigger' -f $Source))
    }
    else {
        $arrFill = @(Get-SetterChild -Node $objPressed -LeafPattern '^Background$' | Where-Object { $_.GetAttribute('Property') -eq 'Background' -and (Get-SetterValue $_) -match $strForeground })
        if ($arrFill.Count -eq 0) { [void]$listFound.Add(('{0}: the IsPressed trigger does not set Background to MahApps.Brushes.ThemeForeground' -f $Source)) }
        $arrText = @(Get-SetterChild -Node $objPressed -LeafPattern '^Foreground$' | Where-Object { $_.GetAttribute('Property') -eq 'TextElement.Foreground' -and (Get-SetterValue $_) -match $strBackground })
        if ($arrText.Count -eq 0) { [void]$listFound.Add(('{0}: the IsPressed trigger does not set TextElement.Foreground to MahApps.Brushes.ThemeBackground' -f $Source)) }
    }
    return $listFound.ToArray()
}

# The effective value of a Setter property of a style: the Setter of the style, else of the style it is based on, and so on.
function Get-EffectiveSetterValue {
    param($Table, [string]$Key, [string]$Property)
    $hashSeen = @{}
    while ($Key -and $Table.ContainsKey($Key) -and -not $hashSeen.ContainsKey($Key)) {
        $hashSeen[$Key] = $true
        $objSetter = @(Get-SetterChild -Node $Table[$Key] -LeafPattern ('^{0}$' -f $Property)) | Select-Object -First 1
        if ($objSetter) { return (Get-SetterValue $objSetter) }
        $Key = Get-ResourceKey $Table[$Key].GetAttribute('BasedOn')
    }
    return ''
}

# True when a node is a XML comment that is the previous element sibling of the style (whitespace is skipped).
function Test-DocumentedByComment {
    param($Node, [string]$Pattern)
    $objPrevious = $Node.PreviousSibling
    while ($objPrevious -and $objPrevious.NodeType -in 'Whitespace', 'SignificantWhitespace') { $objPrevious = $objPrevious.PreviousSibling }
    return ($objPrevious -and $objPrevious.NodeType -eq 'Comment' -and $objPrevious.Value -match $Pattern)
}

# Returns one text per break of the dialog button rule in one dialog document. The dialog has ONE secondary style (DialogButton:
# gray fill, documented by a comment that says secondary) and ONE primary style (DialogAccentButton). Both are based on
# ThemedButtonStyle, defined once, and have the same Height and MinWidth. No other button style sets a Background. A button that
# says Cancel takes DialogButton. The values of the secondary style are theme resources. A dialog button takes its size from
# the style only: no own size, padding or font size.
function Get-DialogButtonViolation {
    param([string]$Text, [string]$Source)
    [xml]$xml = $Text
    $listFound = New-Object System.Collections.Generic.List[string]
    $arrAllowed = @('DialogAccentButton', 'DialogButton')
    $hashStyle = @{}
    foreach ($objStyle in @($xml.SelectNodes("//*[local-name()='Style'][@TargetType='Button']"))) {
        $strKey = Get-XamlKey $objStyle
        if ($hashStyle.ContainsKey($strKey)) { [void]$listFound.Add(('{0}: button style {1} is defined twice' -f $Source, $strKey)) }
        $hashStyle[$strKey] = $objStyle
        if ($strKey -ne 'ThemedButtonStyle' -and @(Get-SetterChild -Node $objStyle -LeafPattern '^Background$').Count -gt 0 -and $arrAllowed -notcontains $strKey) {
            [void]$listFound.Add(('{0}: button style {1} sets a Background and is not a dialog button style' -f $Source, $strKey))
        }
    }
    foreach ($strKey in $arrAllowed) {
        if (-not $hashStyle.ContainsKey($strKey)) { [void]$listFound.Add(('{0}: style {1} is missing' -f $Source, $strKey)); continue }
        if ($hashStyle[$strKey].GetAttribute('BasedOn') -ne '{StaticResource ThemedButtonStyle}') { [void]$listFound.Add(('{0}: style {1} is not based on ThemedButtonStyle' -f $Source, $strKey)) }
    }
    if (-not ($hashStyle.ContainsKey('DialogButton') -and $hashStyle.ContainsKey('DialogAccentButton'))) { return $listFound.ToArray() }
    if (-not (Test-DocumentedByComment -Node $hashStyle['DialogButton'] -Pattern '(?i)secondary')) { [void]$listFound.Add(('{0}: style DialogButton has no comment that documents it as the secondary style' -f $Source)) }
    foreach ($strProperty in 'Height', 'MinWidth') {
        $arrValue = foreach ($strKey in $arrAllowed) {
            $objSetter = Get-SetterChild -Node $hashStyle[$strKey] -LeafPattern ('^{0}$' -f $strProperty) | Select-Object -First 1
            if ($objSetter) { $objSetter.GetAttribute('Value') } else { '' }
        }
        if (@($arrValue | Where-Object { -not $_ }).Count -gt 0 -or @($arrValue | Sort-Object -Unique).Count -ne 1) { [void]$listFound.Add(('{0}: the dialog button styles do not have the same {1}' -f $Source, $strProperty)) }
    }
    foreach ($objSetter in @(Get-SetterChild -Node $hashStyle['DialogButton'] -LeafPattern '(Background|Foreground|Brush)$')) {
        if ($objSetter.GetAttribute('Value') -notmatch '^\{DynamicResource MahApps\.Brushes\.') { [void]$listFound.Add(('{0}: DialogButton sets {1} to a value that is not a theme resource' -f $Source, $objSetter.GetAttribute('Property'))) }
    }
    foreach ($objButton in @($xml.SelectNodes("//*[local-name()='Button']"))) {
        $strStyle = Get-ResourceKey $objButton.GetAttribute('Style')
        if ($arrAllowed -notcontains $strStyle) { continue }
        foreach ($strAttribute in 'Width', 'MinWidth', 'MaxWidth', 'Height', 'MinHeight', 'MaxHeight', 'Padding', 'FontSize') {
            if ($objButton.HasAttribute($strAttribute)) { [void]$listFound.Add(('{0}: dialog button {1} sets {2} itself' -f $Source, $objButton.GetAttribute('Name', $script:strXamlNamespace), $strAttribute)) }
        }
        if ($objButton.GetAttribute('Content') -eq 'Cancel' -and $strStyle -ne 'DialogButton') { [void]$listFound.Add(('{0}: Cancel button {1} does not take DialogButton' -f $Source, $objButton.GetAttribute('Name', $script:strXamlNamespace))) }
    }
    return $listFound.ToArray()
}

# Returns one text per field label (a TextBlock with FieldLabelStyle or OptLabel) that is not bold: no FontWeight Bold on the
# label and none in its style. The style resolves against the document and the context.
function Get-FieldLabelViolation {
    param([string]$Text, [string]$Context = '')
    [xml]$xml = $Text
    $hashStyle = Get-KeyedNodeTable -Text $Text -Context $Context -Name 'Style' -Target 'TextBlock'
    foreach ($objText in @($xml.SelectNodes("//*[local-name()='TextBlock'][contains(@Style,'FieldLabelStyle') or contains(@Style,'OptLabel')]"))) {
        $strKey = Get-ResourceKey $objText.GetAttribute('Style')
        # A header keeps the SemiBold weight of its own. It is not a field label.
        if ($objText.GetAttribute('FontWeight') -eq 'SemiBold') { continue }
        $boolBold = ($objText.GetAttribute('FontWeight') -eq 'Bold')
        if (-not $boolBold -and $hashStyle.ContainsKey($strKey)) {
            $boolBold = (@(Get-SetterChild -Node $hashStyle[$strKey] -LeafPattern '^FontWeight$' | Where-Object { $_.GetAttribute('Value') -eq 'Bold' }).Count -gt 0)
        }
        if (-not $boolBold) { $objText.GetAttribute('Text') }
    }
}

# True when a UI title is in Title Case: each word starts with a capital letter or a digit, except the small words in the
# middle. A word of capitals (JSON) and a word with a dot (sms01.example.com) pass. The text may end with dots.
function Test-TitleCase {
    param([string]$Text)
    $strClean = ($Text -replace '\.\.\.$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($strClean)) { return $true }
    $arrSmall = @('a', 'an', 'the', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'per', 'by', 'at', 'as', 'but', 'nor', 'with', 'from')
    $arrWord = @($strClean -split '\s+')
    for ($intIndex = 0; $intIndex -lt $arrWord.Count; $intIndex++) {
        $strWord = $arrWord[$intIndex].Trim(',', ':', '(', ')')
        # A word with no letter and no digit (an arrow, a bullet, a dash) is a symbol and has no case.
        if (-not $strWord -or $strWord -cnotmatch '[A-Za-z0-9]') { continue }
        # A version number (v1.2.3) has no case.
        if ($strWord -cmatch '^v\d[\d.]*$') { continue }
        $boolEdge = ($intIndex -eq 0 -or $intIndex -eq $arrWord.Count - 1)
        if (-not $boolEdge -and ($arrSmall -contains $strWord)) { continue }
        if ($strWord -cnotmatch '^[A-Z0-9#<\[\(]') { return $false }
    }
    return $true
}

# The titles of a XAML document that must be in Title Case: button content, tab and column headers, field labels, window
# titles, check box, radio button and switch text. A binding or a name with a dot stays out.
function Get-XamlTitle {
    param([string]$Text)
    [xml]$xml = $Text
    foreach ($objElement in @($xml.SelectNodes('//*'))) {
        $strName = $objElement.LocalName
        $strValue = ''
        if ($strName -in 'Button', 'CheckBox', 'RadioButton', 'ToggleButton') { $strValue = $objElement.GetAttribute('Content') }
        elseif ($strName -in 'MenuItem', 'TabItem', 'GroupBox', 'Expander') { $strValue = $objElement.GetAttribute('Header') }
        elseif ($strName -in 'DataGridTextColumn', 'DataGridCheckBoxColumn', 'DataGridTemplateColumn') { $strValue = $objElement.GetAttribute('Header') }
        elseif ($strName -eq 'ToggleSwitch') { $strValue = $objElement.GetAttribute('Header') }
        elseif ($strName -eq 'MetroWindow' -or $strName -eq 'Window') { $strValue = $objElement.GetAttribute('Title') }
        elseif ($strName -eq 'TextBlock' -and ($objElement.GetAttribute('Style') -match 'FieldLabelStyle|OptLabel' -or $objElement.ParentNode.LocalName -eq 'TabItem.Header')) { $strValue = $objElement.GetAttribute('Text') }
        if ($strValue -and $strValue -notmatch '^\{' -and $strValue -notmatch '^(On|Off)$') { $strValue }
    }
}

# Returns one text per call of a UI command (a log line, the status text, a message box, a confirmation) that carries the
# text of an exception: $_, an Exception property, an error message variable. An assignment to the Text property of a control
# is a UI write too, and is scanned the same way.
function Get-UiExceptionText {
    param([string]$Path, [string[]]$Command = @('Add-LogLine', 'Set-StatusText', 'Show-ThemedMessage', 'Show-ConfirmDialog'))
    $objAst = Get-ScriptAst -Path $Path
    $arrCall = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $Command -contains $n.GetCommandName() }, $true)
    foreach ($objCall in $arrCall) {
        if ($objCall.Extent.Text -match $script:strExceptionPattern) { '{0}:{1}: {2}' -f (Split-Path -Leaf $Path), $objCall.Extent.StartLineNumber, $objCall.Extent.Text }
    }
    $arrAssign = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Left.Member.Value -eq 'Text' }, $true)
    foreach ($objAssign in $arrAssign) {
        if ($objAssign.Right.Extent.Text -match $script:strExceptionPattern) { '{0}:{1}: {2}' -f (Split-Path -Leaf $Path), $objAssign.Extent.StartLineNumber, $objAssign.Extent.Text }
    }
}

# Every assignment to a Text property inside a catch block of a script, as an object with the line and the text of the right side.
function Get-CatchTextAssignment {
    param([string]$Path)
    $objAst = Get-ScriptAst -Path $Path
    $arrCatch = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true)
    foreach ($objCatch in $arrCatch) {
        $arrAssign = $objCatch.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Left.Member.Value -eq 'Text' }, $true)
        foreach ($objAssign in $arrAssign) {
            [PSCustomObject]@{ Line = $objAssign.Extent.StartLineNumber; Right = $objAssign.Right.Extent.Text; Text = $objAssign.Extent.Text }
        }
    }
}

# Returns one text per place in a module where exception text can reach the window: a value of Summary (an assignment, a key of
# a hashtable literal or a named parameter) and an argument of an Add call on a list of steps or problems that matches the
# exception pattern. The window shows Summary, the steps and the problems. The reason of a failure goes to Detail and to
# ProblemDetail, which the window never shows. Script output and the error stream text of the script do not match the pattern.
function Get-ModuleExceptionLeak {
    param([string]$Path)
    $objAst = Get-ScriptAst -Path $Path
    $strFile = Split-Path -Leaf $Path
    $arrAssign = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($objAssign in $arrAssign) {
        $boolSummary = ($objAssign.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$objAssign.Left.Member.Value -eq 'Summary') -or ($objAssign.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $objAssign.Left.VariablePath.UserPath -match '^str(Summary|Failure)$')
        if ($boolSummary -and $objAssign.Right.Extent.Text -match $script:strExceptionPattern) { '{0}:{1}: Summary {2}' -f $strFile, $objAssign.Extent.StartLineNumber, $objAssign.Right.Extent.Text }
    }
    $arrHash = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
    foreach ($objHash in $arrHash) {
        foreach ($objPair in $objHash.KeyValuePairs) {
            if ($objPair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$objPair.Item1.Value -eq 'Summary' -and $objPair.Item2.Extent.Text -match $script:strExceptionPattern) {
                '{0}:{1}: Summary {2}' -f $strFile, $objPair.Item2.Extent.StartLineNumber, $objPair.Item2.Extent.Text
            }
        }
    }
    # A named parameter takes its value as the next element (-Summary value) or as an argument (-Summary:value).
    foreach ($objCommand in @($objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $strValue = Get-CommandParameterValue -Command $objCommand -Name 'Summary'
        if ($strValue -and $strValue -match $script:strExceptionPattern) { '{0}:{1}: -Summary {2}' -f $strFile, $objCommand.Extent.StartLineNumber, $strValue }
    }
    $arrAdd = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -eq 'Add' -and $n.Expression.Extent.Text -match '(?i)\$(list|arr)?(Step|Problem)s?$|\$script:\w*(Step|Problem)\w*$' }, $true)
    foreach ($objAdd in $arrAdd) {
        if ($objAdd.Extent.Text -match $script:strExceptionPattern) { '{0}:{1}: {2}' -f $strFile, $objAdd.Extent.StartLineNumber, $objAdd.Extent.Text }
    }
}

# ---- Static XAML guards: button size, Opacity, resource brush literals, Pester requirement -----------------------------------

# One text per Button element that sets its own size or padding. The size of a button comes from its style, so that every
# button of one kind has the same size in every page and dialog.
function Get-ButtonLocalSizeViolation {
    param([string]$Text, [string]$Source)
    [xml]$xml = $Text
    $listFound = New-Object System.Collections.Generic.List[string]
    foreach ($objButton in @($xml.SelectNodes("//*[local-name()='Button']"))) {
        foreach ($strName in 'Height', 'Width', 'MinHeight', 'MinWidth', 'MaxHeight', 'MaxWidth', 'Padding') {
            if ($objButton.HasAttribute($strName)) {
                [void]$listFound.Add(('{0}: Button {1} sets its own {2}' -f $Source, $objButton.GetAttribute('Name', $script:strXamlNamespace), $strName))
            }
        }
    }
    return $listFound.ToArray()
}

# One text per use of Opacity that the theme rules forbid: a Setter or an attribute on Opacity in a Style or a ControlTemplate
# (a state must change colors, never fade), and an Opacity attribute on an element with a blue Background.
function Get-OpacityViolation {
    param([string]$Text, [string]$Source)
    [xml]$xml = $Text
    $listFound = New-Object System.Collections.Generic.List[string]
    $arrScope = @($xml.SelectNodes("//*[local-name()='Style']")) + @($xml.SelectNodes("//*[local-name()='ControlTemplate']"))
    foreach ($objScope in $arrScope) {
        foreach ($objNode in @($objScope.SelectNodes('descendant-or-self::*'))) {
            if ((Get-PropertyLeaf $objNode.GetAttribute('Property')) -eq 'Opacity' -or $objNode.HasAttribute('Opacity')) {
                [void]$listFound.Add(('{0}: Opacity in {1} {2}' -f $Source, $objScope.LocalName, (Get-XamlKey $objScope)))
            }
        }
    }
    foreach ($objElement in @($xml.SelectNodes('//*[@Opacity]'))) {
        foreach ($objAttribute in @($objElement.Attributes | Where-Object { (Get-PropertyLeaf $_.Name) -match 'Background$' })) {
            if (Test-BlueBrush $objAttribute.Value) { [void]$listFound.Add(('{0}: <{1}> has a blue {2} and an Opacity' -f $Source, $objElement.LocalName, $objAttribute.Name)) }
        }
    }
    return $listFound.ToArray()
}

# One text per brush resource (an element with x:Key and a literal Color attribute outside a Style or a ControlTemplate) that is not
# in the allow list. The allow list names the key and the exact value: a contrast override of a MahApps theme brush.
function Get-ResourceBrushViolation {
    param([string]$Text, [string]$Source, [hashtable]$Allow)
    [xml]$xml = $Text
    $listFound = New-Object System.Collections.Generic.List[string]
    foreach ($objBrush in @($xml.SelectNodes("//*[@Color and @*[local-name()='Key']]"))) {
        $objAncestor = $objBrush.ParentNode
        $boolInScope = $false
        while ($objAncestor -and $objAncestor.NodeType -eq 'Element') {
            if ($objAncestor.LocalName -eq 'Style' -or $objAncestor.LocalName -eq 'ControlTemplate') { $boolInScope = $true }
            $objAncestor = $objAncestor.ParentNode
        }
        if ($boolInScope) { continue }
        $strKey = Get-XamlKey $objBrush
        $strColor = $objBrush.GetAttribute('Color')
        if (-not (Test-LiteralColor $strColor)) { continue }
        if (-not $Allow.ContainsKey($strKey) -or $Allow[$strKey] -ne $strColor) {
            [void]$listFound.Add(('{0}: brush resource {1} has the literal color {2} and is not in the allow list' -f $Source, $strKey, $strColor))
        }
    }
    return $listFound.ToArray()
}

# The modules that the #Requires statements of a script name, read from the syntax tree: one object per module with Name and Version.
function Get-ScriptModuleRequirement {
    param([string]$Path)
    $objAst = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    if (-not $objAst.ScriptRequirements) { return @() }
    return @($objAst.ScriptRequirements.RequiredModules | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Version = [string]$_.Version } })
}

# True when the script requires Pester 5.1.0 or later.
function Test-PesterRequirement {
    param([string]$Path)
    foreach ($objModule in @(Get-ScriptModuleRequirement -Path $Path)) {
        if ($objModule.Name -eq 'Pester' -and $objModule.Version -and ([version]$objModule.Version) -ge [version]'5.1.0') { return $true }
    }
    return $false
}

# One text per assignment in a script that sets the size, the padding or the font size of a button: a variable named btn... and
# a button that FindName returns. The size of a button comes from its style, so that every button of one kind has the same size.
function Get-ButtonCodeSizeViolation {
    param([string]$Path)
    $objAst = Get-ScriptAst -Path $Path
    $arrAssign = $objAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)
    foreach ($objAssign in $arrAssign) {
        $strMember = [string]$objAssign.Left.Member.Value
        if ($strMember -notin 'Width', 'MinWidth', 'MaxWidth', 'Height', 'MinHeight', 'MaxHeight', 'Padding', 'FontSize') { continue }
        $strTarget = $objAssign.Left.Expression.Extent.Text
        if ($strTarget -match '^\$btn\w+$' -or $strTarget -match "FindName\('btn\w+'\)") { '{0}:{1}: {2}' -f (Split-Path -Leaf $Path), $objAssign.Extent.StartLineNumber, $objAssign.Extent.Text }
    }
}

# One text per button that a script builds in code. The app builds none: every button is in a XAML document.
function Get-ButtonCreatedInCode {
    param([string]$Path)
    $objAst = Get-ScriptAst -Path $Path
    $arrCreate = $objAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst] -and $n.Extent.Text -match 'New-Object\s+(-TypeName\s+)?[''"]?System\.Windows\.Controls\.(Primitives\.)?\w*Button\b') -or ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text -match '\[System\.Windows\.Controls\.Button\]::new') }, $true)
    foreach ($objCreate in $arrCreate) { '{0}:{1}: {2}' -f (Split-Path -Leaf $Path), $objCreate.Extent.StartLineNumber, $objCreate.Extent.Text }
}

# Every text that the UI shows as a title, as a table lower case -> text: the titles of the XAML documents, the headers of menu
# items, the content of the sidebar buttons and the view titles of the script (-ViewTitle).
function Get-UiTitleTable {
    param([string[]]$Text, [string[]]$ViewTitle = @())
    $hashTitle = @{}
    foreach ($strText in $Text) {
        [xml]$xml = $strText
        $arrTitle = @(Get-XamlTitle -Text $strText)
        foreach ($objElement in @($xml.SelectNodes("//*[local-name()='MenuItem' or local-name()='Button' or local-name()='CheckBox' or local-name()='TextBlock']"))) {
            foreach ($strAttribute in 'Header', 'Content', 'Text') {
                $strValue = $objElement.GetAttribute($strAttribute)
                if ($strValue -and $strValue -notmatch '^\{' -and $strValue.Length -le 40 -and $strValue -match '^[A-Z][\w ()/.-]*$') { $arrTitle += $strValue }
            }
        }
        foreach ($strTitle in $arrTitle) { $hashTitle[$strTitle.ToLowerInvariant().Trim().TrimEnd('.', ':')] = $strTitle.Trim().TrimEnd('.', ':') }
    }
    foreach ($strTitle in $ViewTitle) { $hashTitle[$strTitle.ToLowerInvariant()] = $strTitle }
    return $hashTitle
}

# One text per bold label in a Markdown page that names a UI title in another case: **Open log file** where the window says
# Open Log File. The pages use bold for the labels of the window.
function Get-DocLabelViolation {
    param([string]$Text, [string]$Name, [hashtable]$Title)
    $intLine = 0
    foreach ($strLine in ($Text -split "\r?\n")) {
        $intLine++
        foreach ($objMatch in [regex]::Matches($strLine, '\*\*([^*]+)\*\*')) {
            $strLabel = $objMatch.Groups[1].Value.Trim().TrimEnd('.', ':')
            $strKey = $strLabel.ToLowerInvariant()
            if ($Title.ContainsKey($strKey) -and $Title[$strKey] -cne $strLabel) { '{0}:{1}: {2} should be {3}' -f $Name, $intLine, $strLabel, $Title[$strKey] }
        }
    }
}

# One text per heading of a Markdown page that names a UI title in another case: '## Running actions' where the window says
# Running Actions. A heading may hold other words, so only a heading that equals a title ignoring case is checked.
function Get-DocHeadingViolation {
    param([string]$Text, [string]$Name, [hashtable]$Title)
    $intLine = 0
    foreach ($strLine in ($Text -split "\r?\n")) {
        $intLine++
        $objMatch = [regex]::Match($strLine, '^#{1,6}\s+(.+?)\s*$')
        if (-not $objMatch.Success) { continue }
        $strLabel = $objMatch.Groups[1].Value.Trim()
        $strKey = $strLabel.ToLowerInvariant()
        if ($Title.ContainsKey($strKey) -and $Title[$strKey] -cne $strLabel) { '{0}:{1}: heading {2} should be {3}' -f $Name, $intLine, $strLabel, $Title[$strKey] }
    }
}
