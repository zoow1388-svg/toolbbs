. (Join-Path $PSScriptRoot '..\src\Greeting.ps1')

Describe 'Get-Greeting' {
    It 'returns a greeting for a supplied name' {
        Get-Greeting -Name 'Codex' | Should Be 'Hello, Codex'
    }
}
