[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ArchivePath,
    [Parameter(Mandatory=$true)][string]$ChecksumPath,
    [Parameter(Mandatory=$true)][string]$ExpectedVersion
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$archive=[IO.Path]::GetFullPath($ArchivePath)
$checksum=[IO.Path]::GetFullPath($ChecksumPath)
if(-not(Test-Path -LiteralPath $archive -PathType Leaf)){throw 'Release archive not found.'}
if(-not(Test-Path -LiteralPath $checksum -PathType Leaf)){throw 'Release checksum not found.'}

$declared=((Get-Content -LiteralPath $checksum -Raw -Encoding UTF8).Trim() -split '\s+')[0].ToLowerInvariant()
$actual=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if($declared-notmatch'^[a-f0-9]{64}$'-or$declared-ne$actual){throw 'Release archive checksum mismatch.'}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
    $entries=@{};foreach($entry in $zip.Entries){$entries[$entry.FullName.Replace('\','/')]=$entry}
    if(-not$entries.ContainsKey('PACKAGE_MANIFEST.json')){throw 'PACKAGE_MANIFEST.json is missing.'}
    $reader=[IO.StreamReader]::new($entries['PACKAGE_MANIFEST.json'].Open(),[Text.UTF8Encoding]::new($false))
    try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
    if($manifest.package-ne'codex-project-orchestrator'-or$manifest.version-ne$ExpectedVersion){throw 'Package manifest identity mismatch.'}
    foreach($file in $manifest.files){
        $path=([string]$file.path).Replace('\','/')
        if(-not$entries.ContainsKey($path)){throw "Manifest file is missing: $path"}
        $entry=$entries[$path]
        if([int64]$entry.Length-ne[int64]$file.size){throw "Manifest size mismatch: $path"}
        $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}
        if($hash-ne$file.sha256){throw "Manifest hash mismatch: $path"}
    }
    $versionEntry='skill/codex-project-orchestrator/VERSION'
    if(-not$entries.ContainsKey($versionEntry)){throw 'Packaged VERSION is missing.'}
    $versionReader=[IO.StreamReader]::new($entries[$versionEntry].Open(),[Text.UTF8Encoding]::new($false))
    try{$packagedVersion=$versionReader.ReadToEnd().Trim()}finally{$versionReader.Dispose()}
    if($packagedVersion-ne$ExpectedVersion){throw 'Packaged VERSION mismatch.'}
    Write-Output "PACKAGE VALID: $ExpectedVersion, $($manifest.files.Count) manifested files, SHA-256 $actual"
}finally{$zip.Dispose()}
