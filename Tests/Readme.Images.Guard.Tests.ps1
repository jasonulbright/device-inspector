#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Every image that README.md shows is current: it is a file of docs\images (a capture output) or it is listed in
# tools\guide-capture\readme-images.json as a copy of one, and a listed copy is byte-identical to its source.
# The test parses and compares files only. It opens no window.
param ()

BeforeAll {
    $script:strRoot = Split-Path -Path (Split-Path -Path $PSCommandPath -Parent) -Parent
    $script:strReadme = Get-Content -LiteralPath (Join-Path -Path $script:strRoot -ChildPath 'README.md') -Raw
    $script:arrImage = @([regex]::Matches($script:strReadme, '\!\[[^\]]*\]\(([^)\s]+)\)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^https?:' })
    $script:objMap = Get-Content -LiteralPath (Join-Path -Path $script:strRoot -ChildPath 'tools\guide-capture\readme-images.json') -Raw | ConvertFrom-Json
    $script:arrMapped = @($script:objMap.PSObject.Properties)
}

Describe 'README images' {
    It 'shows at least one local image' {
        $script:arrImage.Count | Should -BeGreaterThan 0
    }

    It 'shows only images of docs/images or images that the map lists' {
        $arrBad = @($script:arrImage | Where-Object { $_ -notmatch '^docs/images/[^/]+\.png$' -and $script:objMap.PSObject.Properties.Name -notcontains $_ })
        $arrBad | Should -BeNullOrEmpty
    }

    It 'has every shown image as a file' {
        $arrMissing = @($script:arrImage | Where-Object { -not (Test-Path -LiteralPath (Join-Path -Path $script:strRoot -ChildPath $_)) })
        $arrMissing | Should -BeNullOrEmpty
    }

    It 'maps a README image only to an existing image of docs/images' {
        foreach ($objEntry in $script:arrMapped) {
            [string]$objEntry.Value | Should -Match '^docs/images/[^/]+\.png$'
            Test-Path -LiteralPath (Join-Path -Path $script:strRoot -ChildPath ([string]$objEntry.Value)) | Should -BeTrue -Because $objEntry.Value
        }
    }

    It 'keeps every mapped README image byte-identical to its source' {
        foreach ($objEntry in $script:arrMapped) {
            $strTarget = Join-Path -Path $script:strRoot -ChildPath $objEntry.Name
            $strSource = Join-Path -Path $script:strRoot -ChildPath ([string]$objEntry.Value)
            (Get-FileHash -LiteralPath $strTarget -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath $strSource -Algorithm SHA256).Hash -Because $objEntry.Name
        }
    }

    It 'finds a README image outside docs/images that the map does not list (bad sample)' {
        $arrSample = @('docs/images/a.png', 'screenshot.png')
        @($arrSample | Where-Object { $_ -notmatch '^docs/images/[^/]+\.png$' -and @() -notcontains $_ }).Count | Should -Be 1
    }
}
