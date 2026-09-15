$builder=Join-Path $PSScriptRoot '..\skill\codex-project-orchestrator\scripts\build-dispatch-prompt.ps1'
$dispatch=Join-Path $PSScriptRoot '..\examples\read-only-analysis\dispatch.json'

Describe 'native task adapter artifacts' {
    It 'builds an immutable UTF-8 dispatch prompt with stable identities' {
        $output=Join-Path $TestDrive 'dispatch.md'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -DispatchPath $dispatch -OutputPath $output | Out-Null
        $LASTEXITCODE|Should Be 0
        $content=Get-Content $output -Raw -Encoding UTF8
        $content|Should Match 'ANALYSIS-001-exampledispatch'
        $content|Should Match 'example-thread'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builder -DispatchPath $dispatch -OutputPath $output 2>$null|Out-Null
        $LASTEXITCODE|Should Be 1
    }
}
