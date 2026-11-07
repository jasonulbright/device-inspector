param ()

BeforeAll {
    $strTestsFolder = Split-Path -Path $PSCommandPath -Parent
    $script:strRepositoryRoot = Split-Path -Path $strTestsFolder -Parent
    $script:strDocsRoot = Join-Path -Path $script:strRepositoryRoot -ChildPath 'docs'
    $script:arrPage = @(Get-ChildItem -LiteralPath $script:strDocsRoot -Recurse -File -Filter '*.md')
    $script:arrImage = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:strDocsRoot -ChildPath 'images') -File -Filter '*.png')

    function Get-DocLink {
        param ([System.IO.FileInfo]$Page)
        $strText = Get-Content -LiteralPath $Page.FullName -Raw
        foreach ($objMatch in [regex]::Matches($strText, '(?<!\!)\[[^\]]*\]\(([^)\s]+)\)')) {
            [pscustomobject]@{ Page = $Page; Target = $objMatch.Groups[1].Value; Kind = 'Link' }
        }
        foreach ($objMatch in [regex]::Matches($strText, '\!\[[^\]]*\]\(([^)\s]+)\)')) {
            [pscustomobject]@{ Page = $Page; Target = $objMatch.Groups[1].Value; Kind = 'Image' }
        }
    }
    $script:arrRef = @(foreach ($objPage in $script:arrPage) { Get-DocLink -Page $objPage })
}

Describe 'User guide' {
    It 'has an index and the standard pages' {
        foreach ($strName in 'index.md', 'getting-started.md', 'troubleshooting.md', 'external-references.md') {
            Test-Path -LiteralPath (Join-Path -Path $script:strDocsRoot -ChildPath $strName) | Should -BeTrue -Because $strName
        }
    }

    It 'resolves every relative link and image to a file' {
        $arrMissing = foreach ($objRef in @($script:arrRef | Where-Object { $_.Target -notmatch '^(https?:|mailto:|#)' })) {
            $strPath = ($objRef.Target -split '#')[0]
            if (-not $strPath) { continue }
            $strFull = Join-Path -Path (Split-Path -Path $objRef.Page.FullName -Parent) -ChildPath $strPath
            if (-not (Test-Path -LiteralPath $strFull)) { '{0}: {1}' -f $objRef.Page.Name, $objRef.Target }
        }
        @($arrMissing) | Should -BeNullOrEmpty
    }

    It 'links every page from the index' {
        $strIndex = Get-Content -LiteralPath (Join-Path -Path $script:strDocsRoot -ChildPath 'index.md') -Raw
        $arrOrphan = foreach ($objPage in $script:arrPage) {
            $strRelative = $objPage.FullName.Substring($script:strDocsRoot.Length + 1).Replace('\', '/')
            if ($strRelative -ne 'index.md' -and $strIndex -notmatch [regex]::Escape('(' + $strRelative + ')')) { $strRelative }
        }
        @($arrOrphan) | Should -BeNullOrEmpty
    }

    It 'uses every image in at least one page' {
        $arrUsed = @($script:arrRef | Where-Object { $_.Kind -eq 'Image' } | ForEach-Object { Split-Path -Path $_.Target -Leaf })
        $arrUnused = @($script:arrImage | Where-Object { $arrUsed -notcontains $_.Name } | ForEach-Object { $_.Name })
        $arrUnused | Should -BeNullOrEmpty
    }

    It 'names every image in lower case with hyphens' {
        @($script:arrImage | Where-Object { $_.Name -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*\.png$' }) | Should -BeNullOrEmpty
    }

    It 'gives every image a description' {
        @($script:arrRef | Where-Object { $_.Kind -eq 'Image' }).Count | Should -BeGreaterThan 0
        foreach ($objPage in $script:arrPage) {
            (Get-Content -LiteralPath $objPage.FullName -Raw) | Should -Not -Match '\!\[\]\(' -Because $objPage.Name
        }
    }

    It 'links the guide from the README' {
        (Get-Content -LiteralPath (Join-Path -Path $script:strRepositoryRoot -ChildPath 'README.md') -Raw) | Should -Match '\(docs/index\.md\)'
    }
}
