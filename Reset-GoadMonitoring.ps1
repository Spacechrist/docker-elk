#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LabRoot = 'C:\lab',
    [string]$GoadBranch = 'feature/elastic-monitoring',
    [string]$DockerElkBranch = 'feature/goad-monitoring',
    [switch]$ConfirmPermanentDestruction
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$Description = $FilePath
    )
    if ($WorkingDirectory) { Push-Location $WorkingDirectory }
    try {
        & $FilePath @ArgumentList
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "$Description failed with exit code ${exitCode}: $($ArgumentList -join ' ')"
        }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }
}

function Assert-RemoteBranchCurrent {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Branch,
        [string[]]$AllowedDirtyPath = @()
    )
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git') -PathType Container)) {
        throw "Git repository not found: $RepositoryPath"
    }
    $currentBranch = (& git.exe -C $RepositoryPath branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $Branch) {
        throw "Expected branch '$Branch' in $RepositoryPath; found '$currentBranch'."
    }
    $dirty = @(& git.exe -C $RepositoryPath status --porcelain | Where-Object {
        $path = if ($_.Length -gt 3) { $_.Substring(3).Trim('"') } else { '' }
        $AllowedDirtyPath -notcontains $path
    })
    if ($dirty.Count -gt 0) {
        throw "Uncommitted files would be lost in ${RepositoryPath}:`n$($dirty -join "`n")"
    }
    $head = (& git.exe -C $RepositoryPath rev-parse HEAD).Trim()
    $tracking = (& git.exe -C $RepositoryPath rev-parse '@{u}').Trim()
    $remoteLine = (& git.exe -C $RepositoryPath ls-remote origin "refs/heads/$Branch" | Select-Object -First 1)
    $remote = if ($remoteLine) { ($remoteLine -split '\s+')[0] } else { '' }
    if ([string]::IsNullOrWhiteSpace($head) -or $head -ne $tracking -or $head -ne $remote) {
        throw "Local, tracking, and remote commits do not match for $RepositoryPath."
    }
    Write-Host "$RepositoryPath is recoverable from origin/$Branch at $head."
}

if (-not $ConfirmPermanentDestruction) {
    throw 'Permanent deletion was not confirmed. Re-run with -ConfirmPermanentDestruction.'
}
foreach ($command in @('git.exe', 'vagrant.exe', 'docker.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required and was not found in PATH."
    }
}

$LabRoot = [IO.Path]::GetFullPath($LabRoot)
if ([IO.Path]::GetPathRoot($LabRoot) -eq $LabRoot) {
    throw 'LabRoot may not be a filesystem root.'
}
$goadPath = Join-Path $LabRoot 'GOAD'
$dockerElkPath = Join-Path $LabRoot 'docker-elk'
$venvPath = Join-Path $LabRoot 'venv'
$providerRoot = Join-Path $goadPath 'workspace'

Write-Host 'Validating that both repositories are recoverable before deletion...' -ForegroundColor Yellow
Assert-RemoteBranchCurrent -RepositoryPath $goadPath -Branch $GoadBranch
Assert-RemoteBranchCurrent -RepositoryPath $dockerElkPath -Branch $DockerElkBranch -AllowedDirtyPath @('.env')

Write-Host 'Destroying GOAD VMware machines...' -ForegroundColor Yellow
$providers = @(Get-ChildItem -LiteralPath $providerRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'provider' } |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'Vagrantfile') -PathType Leaf })
foreach ($provider in $providers) {
    Invoke-Native -FilePath 'vagrant.exe' -ArgumentList @('destroy', '--force') `
        -WorkingDirectory $provider -Description "Vagrant destroy in $provider"
}

Write-Host 'Removing GOAD monitoring containers, images, networks, and volumes...' -ForegroundColor Yellow
$baseCompose = Join-Path $dockerElkPath 'docker-compose.yml'
$fleetCompose = Join-Path $dockerElkPath 'extensions\fleet\fleet-compose.yml'
Invoke-Native -FilePath 'docker.exe' -WorkingDirectory $dockerElkPath -ArgumentList @(
    'compose', '-f', $baseCompose, '-f', $fleetCompose,
    'down', '--volumes', '--remove-orphans', '--rmi', 'local'
) -Description 'Docker Compose teardown'

foreach ($volumeName in @('goad-monitoring_elasticsearch', 'docker-elk_elasticsearch')) {
    $existing = & docker.exe volume ls --quiet --filter "name=^${volumeName}$"
    if ($LASTEXITCODE -eq 0 -and $existing) {
        Invoke-Native -FilePath 'docker.exe' -ArgumentList @('volume', 'rm', $volumeName) `
            -Description "Removing Docker volume $volumeName"
    }
}

Write-Host 'Permanently deleting repositories, generated certificates, secrets, and Python environment...' -ForegroundColor Yellow
Set-Location $LabRoot
foreach ($path in @($dockerElkPath, $goadPath, $venvPath)) {
    if (Test-Path -LiteralPath $path) {
        $resolved = [IO.Path]::GetFullPath($path)
        if ($resolved -notlike ($LabRoot.TrimEnd('\') + '\*')) {
            throw "Refusing to delete path outside LabRoot: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Write-Host "Deleted $resolved"
    }
}

Write-Host 'Permanent GOAD monitoring teardown completed.' -ForegroundColor Green
