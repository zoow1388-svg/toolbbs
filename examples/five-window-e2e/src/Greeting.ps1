function Get-Greeting {
    param([Parameter(Mandatory=$true)][string]$Name)
    "Hello, $Name"
}
