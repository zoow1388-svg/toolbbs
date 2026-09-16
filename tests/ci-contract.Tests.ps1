$projectRoot=Split-Path -Parent $PSScriptRoot
$ciPath=Join-Path $projectRoot '.github\workflows\ci.yml'
$releasePath=Join-Path $projectRoot '.github\workflows\release-validation.yml'

Describe 'remote validation workflow contract' {
    It 'runs the unified validator for pull requests and main' {
        Test-Path -LiteralPath $ciPath | Should Be $true
        $content=Get-Content -LiteralPath $ciPath -Raw -Encoding UTF8
        $content | Should Match 'pull_request:'
        $content | Should Match 'branches: \[main\]'
        $content | Should Match 'tests/run-validation\.ps1'
        $content | Should Match 'requirements-validation\.txt'
        $content | Should Match 'if: always\(\)'
        $content | Should Match 'path: TestResults/'
    }

    It 'validates tag identity before building an artifact' {
        Test-Path -LiteralPath $releasePath | Should Be $true
        $content=Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8
        $content | Should Match "tags: \['v\*'\]"
        $content | Should Match 'Tag does not match VERSION'
        $content | Should Match 'installer/build-release\.ps1'
        $content | Should Match 'verify-release-package\.ps1'
        $content | Should Match 'actions/upload-artifact@v4'
        $content | Should Not Match 'gh release create'
    }
}
