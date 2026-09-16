$projectRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $projectRoot 'installer\install.ps1'
$uninstaller = Join-Path $projectRoot 'installer\uninstall.ps1'
$builder = Join-Path $projectRoot 'installer\build-release.ps1'
$packageVerifier = Join-Path $projectRoot 'tests\verify-release-package.ps1'
$skillSource = Join-Path $projectRoot 'skill\codex-project-orchestrator'
$skillVersion = (Get-Content -LiteralPath (Join-Path $skillSource 'VERSION') -Raw -Encoding UTF8).Trim()

Describe 'versioned installer lifecycle' {
    BeforeEach {
        $script:testRoot = Join-Path $projectRoot ("TestResults\installer-" + [guid]::NewGuid().ToString('N'))
        $skillsRoot = Join-Path $script:testRoot 'skills'
        [void](New-Item -ItemType Directory -Path $script:testRoot -Force)
    }

    AfterEach {
        if ($script:testRoot -and (Test-Path -LiteralPath $script:testRoot)) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'installs and repeats the same version without changing content' {
        & $installer -SourcePath $skillSource -DestinationRoot $skillsRoot
        $destination = Join-Path $skillsRoot 'codex-project-orchestrator'
        Test-Path -LiteralPath (Join-Path $destination 'SKILL.md') | Should Be $true
        (Get-Content -LiteralPath (Join-Path $destination 'VERSION') -Raw).Trim() | Should Be $skillVersion
        $before = (Get-FileHash -LiteralPath (Join-Path $destination 'SKILL.md') -Algorithm SHA256).Hash
        & $installer -SourcePath $skillSource -DestinationRoot $skillsRoot
        $after = (Get-FileHash -LiteralPath (Join-Path $destination 'SKILL.md') -Algorithm SHA256).Hash
        $after | Should Be $before
    }

    It 'requires approval for different installed content and backs it up during upgrade' {
        & $installer -SourcePath $skillSource -DestinationRoot $skillsRoot
        $destination = Join-Path $skillsRoot 'codex-project-orchestrator'
        Add-Content -LiteralPath (Join-Path $destination 'SKILL.md') -Value 'changed'
        { & $installer -SourcePath $skillSource -DestinationRoot $skillsRoot } | Should Throw
        & $installer -SourcePath $skillSource -DestinationRoot $skillsRoot -AllowUpgrade
        (Get-ChildItem -LiteralPath (Join-Path $skillsRoot '.toolbbs-backups\codex-project-orchestrator') -Directory).Count | Should Be 1
    }

    It 'uninstalls by moving the managed skill to a recoverable backup' {
        & $installer -SourcePath $skillSource -DestinationRoot $skillsRoot
        & $uninstaller -DestinationRoot $skillsRoot -Confirm:$false
        Test-Path -LiteralPath (Join-Path $skillsRoot 'codex-project-orchestrator') | Should Be $false
        (Get-ChildItem -LiteralPath (Join-Path $skillsRoot '.toolbbs-backups\codex-project-orchestrator') -Directory).Count | Should Be 1
    }

    It 'refuses to uninstall a directory without installation markers' {
        $destination = Join-Path $skillsRoot 'codex-project-orchestrator'
        [void](New-Item -ItemType Directory -Path $destination -Force)
        { & $uninstaller -DestinationRoot $skillsRoot -Confirm:$false } | Should Throw
    }

    It 'builds a versioned archive, manifest, and checksum without overwriting output' {
        $output = Join-Path $script:testRoot 'dist'
        & $builder -OutputDirectory $output
        $archive = Join-Path $output "codex-project-orchestrator-v$skillVersion.zip"
        Test-Path -LiteralPath $archive | Should Be $true
        Test-Path -LiteralPath "$archive.sha256" | Should Be $true
        & $packageVerifier -ArchivePath $archive -ChecksumPath "$archive.sha256" -ExpectedVersion $skillVersion
        $LASTEXITCODE | Should Be 0
        { & $builder -OutputDirectory $output } | Should Throw
    }
}
