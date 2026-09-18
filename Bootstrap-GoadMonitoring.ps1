#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LabRoot = 'C:\lab',
    [string]$GoadRepository = 'https://github.com/Spacechrist/GOAD.git',
    [string]$GoadBranch = 'feature/elastic-monitoring',
    [string]$DockerElkRepository = 'https://github.com/Spacechrist/docker-elk',
    [string]$DockerElkBranch = 'feature/goad-monitoring',
    [string]$RequiredGoadAncestor = 'c26d592a45f3c7a85d525ddcc50d1c725c743bdd',
    [string]$RequiredDockerElkAncestor = '5459587de58dc3c0e605dd014c4b4fde5008b03a',
    [string]$PythonCommand = 'python.exe',
    [string]$LabName = 'GOAD',
    [string]$Provider = 'vmware',
    [string]$IpRange = '192.168.56',
    [string]$Method = 'local',
    [ValidateSet('standard', 'disabled-vagrant')]
    [string]$InventoryMode = 'standard',
    [ValidateSet('all-windows', 'dc01', 'dc02', 'dc03', 'srv02', 'srv03')]
    [string]$Target = 'all-windows'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Phase {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

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

function Resolve-Python {
    param([Parameter(Mandatory)][string]$RequestedCommand)
    $command = Get-Command $RequestedCommand -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $launcher = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($launcher) { return $launcher.Source }
    throw 'Python 3 was not found in PATH.'
}

function Assert-GitAncestor {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$RequiredCommit,
        [Parameter(Mandatory)][string]$Description
    )
    & git.exe -C $RepositoryPath merge-base --is-ancestor $RequiredCommit HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "$Description does not contain required commit $RequiredCommit."
    }
}

function Ensure-DockerEngine {
    & docker.exe info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path -LiteralPath $desktop -PathType Leaf)) {
        throw 'Docker Desktop is installed but its engine is not running.'
    }
    Write-Host 'Starting Docker Desktop...'
    Start-Process -FilePath $desktop | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        Start-Sleep -Seconds 5
        & docker.exe info --format '{{.ServerVersion}}' 2>$null
        if ($LASTEXITCODE -eq 0) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Docker Desktop did not become ready within five minutes.'
}

$LabRoot = [IO.Path]::GetFullPath($LabRoot)
if ([IO.Path]::GetPathRoot($LabRoot) -eq $LabRoot) {
    throw 'LabRoot may not be a filesystem root.'
}
$goadPath = Join-Path $LabRoot 'GOAD'
$dockerElkPath = Join-Path $LabRoot 'docker-elk'
$venvPath = Join-Path $goadPath '.venv'
$transcriptPath = Join-Path $LabRoot ('goad-clean-build-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.log')

New-Item -ItemType Directory -Path $LabRoot -Force | Out-Null
Start-Transcript -Path $transcriptPath -Force | Out-Null
try {
    Write-Phase 'Prerequisite checks'
    foreach ($command in @('git.exe', 'vagrant.exe', 'docker.exe', 'curl.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "$command is required and was not found in PATH."
        }
    }
    $python = Resolve-Python -RequestedCommand $PythonCommand
    Ensure-DockerEngine
    foreach ($path in @($goadPath, $dockerElkPath)) {
        if (Test-Path -LiteralPath $path) {
            throw "Clean bootstrap target already exists: $path"
        }
    }

    Write-Phase 'Cloning the fixed GOAD branch'
    Invoke-Native -FilePath 'git.exe' -ArgumentList @(
        'clone', '--branch', $GoadBranch, '--single-branch', $GoadRepository, $goadPath
    ) -Description 'GOAD clone'
    Assert-GitAncestor -RepositoryPath $goadPath -RequiredCommit $RequiredGoadAncestor -Description 'GOAD branch'

    Write-Phase 'Cloning the GOAD monitoring branch of docker-elk'
    Invoke-Native -FilePath 'git.exe' -ArgumentList @(
        'clone', '--branch', $DockerElkBranch, '--single-branch', $DockerElkRepository, $dockerElkPath
    ) -Description 'docker-elk clone'
    Assert-GitAncestor -RepositoryPath $dockerElkPath -RequiredCommit $RequiredDockerElkAncestor -Description 'docker-elk branch'

    Write-Phase 'Creating the GOAD Python environment'
    $pythonArguments = if ([IO.Path]::GetFileName($python) -ieq 'py.exe') {
        @('-3', '-m', 'venv', $venvPath)
    }
    else {
        @('-m', 'venv', $venvPath)
    }
    Invoke-Native -FilePath $python -ArgumentList $pythonArguments -Description 'Python virtual environment creation'
    $venvPython = Join-Path $venvPath 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw "Virtual-environment Python was not created: $venvPython"
    }
    Invoke-Native -FilePath $venvPython -ArgumentList @('-m', 'pip', 'install', '--upgrade', 'pip') `
        -Description 'pip upgrade'
    $requirements = @(
        (Join-Path $goadPath 'requirements.txt'),
        (Join-Path $goadPath 'requirements-windows.txt')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $requirements) {
        throw 'No supported GOAD Python requirements file was found.'
    }
    Invoke-Native -FilePath $venvPython -ArgumentList @('-m', 'pip', 'install', '-r', $requirements) `
        -Description 'GOAD Python dependency installation'

    Write-Phase 'Installing and provisioning GOAD'
    Invoke-Native -FilePath $venvPython -WorkingDirectory $goadPath -ArgumentList @(
        'goad.py', '--task', 'install', '--lab', $LabName, '--provider', $Provider,
        '--ip_range', $IpRange, '--method', $Method
    ) -Description 'GOAD installation'

    Write-Phase 'Discovering the generated GOAD instance'
    $instances = @(Get-ChildItem -LiteralPath (Join-Path $goadPath 'workspace') -Directory -ErrorAction Stop |
        Where-Object {
            $_.Name -like '*-goad-vmware' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'provider\Vagrantfile') -PathType Leaf)
        })
    if ($instances.Count -ne 1) {
        throw "Expected exactly one GOAD VMware instance, found $($instances.Count)."
    }
    $instanceName = $instances[0].Name
    Write-Host "Discovered GOAD instance: $instanceName"

    Write-Phase 'Deploying Elastic monitoring, Fleet, EDR, Sysmon, and Windows logging'
    $monitoringInstaller = Join-Path $dockerElkPath 'Install-GoadMonitoring.ps1'
    if (-not (Test-Path -LiteralPath $monitoringInstaller -PathType Leaf)) {
        throw "Monitoring installer not found in cloned branch: $monitoringInstaller"
    }
    & $monitoringInstaller `
        -DockerElkRoot $dockerElkPath -GoadRoot $goadPath -InstanceName $instanceName `
        -LabName $LabName -InventoryMode $InventoryMode -Target $Target

    Write-Host "`nClean GOAD monitoring deployment completed successfully." -ForegroundColor Green
    Write-Host "Transcript: $transcriptPath"
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
