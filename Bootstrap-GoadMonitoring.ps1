#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LabRoot = 'C:\lab',
    [string]$GoadRepository = 'https://github.com/Spacechrist/GOAD.git',
    [string]$GoadBranch = 'feature/elastic-monitoring',
    [string]$DockerElkRepository = 'https://github.com/Spacechrist/docker-elk',
    [string]$DockerElkBranch = 'feature/goad-monitoring',
    [string]$RequiredGoadAncestor = '6aa04d86a0a61445fd04a45385c3f877417ea665',
    [string]$RequiredDockerElkAncestor = '5459587de58dc3c0e605dd014c4b4fde5008b03a',
    [string]$PythonCommand = 'python.exe',
    [string]$LabName = 'GOAD',
    [string]$Provider = 'vmware',
    [string]$IpRange = '192.168.56',
    [string]$Method = 'vm',
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

function Ensure-RepositoryClone {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RequiredCommit,
        [Parameter(Mandatory)][string]$Description
    )

    if (Test-Path -LiteralPath (Join-Path $Path '.git') -PathType Container) {
        $currentBranch = (& git.exe -C $Path branch --show-current).Trim()
        if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $Branch) {
            throw "Expected $Description branch '$Branch'; found '$currentBranch' in $Path."
        }
        $dirty = @(& git.exe -C $Path status --porcelain | Where-Object {
            $_ -notmatch '^\?\? \.venv(?:/|$)'
        })
        if ($dirty.Count -gt 0) {
            throw "$Description clone has unexpected local changes:`n$($dirty -join "`n")"
        }
        Invoke-Native -FilePath 'git.exe' -ArgumentList @('-C', $Path, 'fetch', 'origin', $Branch) `
            -Description "$Description fetch"
        Assert-GitAncestor -RepositoryPath $Path -RequiredCommit $RequiredCommit -Description $Description
        Write-Host "Reusing existing $Description clone at $Path."
        return
    }
    if (Test-Path -LiteralPath $Path) {
        throw "$Description target exists but is not a Git repository: $Path"
    }
    Invoke-Native -FilePath 'git.exe' -ArgumentList @(
        'clone', '--branch', $Branch, '--single-branch', $Repository, $Path
    ) -Description "$Description clone"
    Assert-GitAncestor -RepositoryPath $Path -RequiredCommit $RequiredCommit -Description $Description
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

function Install-GoadPythonDependencies {
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$RequirementsPath
    )

    $installPath = $RequirementsPath
    $temporaryRequirements = $null
    $nativeWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    try {
        if ($nativeWindows) {
            $temporaryRequirements = [IO.Path]::GetTempFileName()
            $lines = @(Get-Content -LiteralPath $RequirementsPath | Where-Object {
                $_ -notmatch '^\s*ansible-core(?:\s*[<>=!~].*)?\s*$'
            })
            [IO.File]::WriteAllLines(
                $temporaryRequirements,
                [string[]]$lines,
                (New-Object Text.UTF8Encoding($false))
            )
            $installPath = $temporaryRequirements
            Write-Host 'Native Windows detected: ansible-core is delegated to the Linux PROVISIONING VM.'
        }
        Invoke-Native -FilePath $PythonPath -ArgumentList @('-m', 'pip', 'install', '-r', $installPath) `
            -Description 'GOAD Python dependency installation'
        Invoke-Native -FilePath $PythonPath -ArgumentList @(
            '-c', 'import rich, psutil, jinja2, yaml, ansible_runner, winrm; print("GOAD Python dependencies OK")'
        ) -Description 'GOAD Python dependency validation'
    }
    finally {
        if ($temporaryRequirements -and (Test-Path -LiteralPath $temporaryRequirements)) {
            Remove-Item -LiteralPath $temporaryRequirements -Force
        }
    }
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
    Write-Phase 'Cloning the fixed GOAD branch'
    Ensure-RepositoryClone -Path $goadPath -Repository $GoadRepository -Branch $GoadBranch `
        -RequiredCommit $RequiredGoadAncestor -Description 'GOAD'

    Write-Phase 'Cloning the GOAD monitoring branch of docker-elk'
    Ensure-RepositoryClone -Path $dockerElkPath -Repository $DockerElkRepository -Branch $DockerElkBranch `
        -RequiredCommit $RequiredDockerElkAncestor -Description 'docker-elk'

    Write-Phase 'Creating the GOAD Python environment'
    $venvPython = Join-Path $venvPath 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        $pythonArguments = if ([IO.Path]::GetFileName($python) -ieq 'py.exe') {
            @('-3', '-m', 'venv', $venvPath)
        }
        else {
            @('-m', 'venv', $venvPath)
        }
        Invoke-Native -FilePath $python -ArgumentList $pythonArguments -Description 'Python virtual environment creation'
    }
    else {
        Write-Host "Reusing existing GOAD virtual environment at $venvPath."
    }
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw "Virtual-environment Python was not created: $venvPython"
    }
    Invoke-Native -FilePath $venvPython -ArgumentList @('-m', 'pip', 'install', '--upgrade', 'pip') `
        -Description 'pip upgrade'
    $requirements = @(
        (Join-Path $goadPath 'noansible_requirements.yml'),
        (Join-Path $goadPath 'requirements.txt'),
        (Join-Path $goadPath 'requirements-windows.txt')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $requirements) {
        throw 'No supported GOAD Python requirements file was found.'
    }
    Install-GoadPythonDependencies -PythonPath $venvPython -RequirementsPath $requirements

    Write-Host "`nClean-room preparation completed successfully." -ForegroundColor Green
    Write-Host 'Run GOAD manually so its built-in retry and resume workflow remains visible:'
    Write-Host "  cd $goadPath"
    Write-Host "  .\.venv\Scripts\python.exe .\goad.py --task install --lab $LabName --provider $Provider --ip_range $IpRange --method $Method"
    Write-Host 'After GOAD succeeds, run Install-GoadMonitoring.ps1 with the explicit generated instance name.'
    Write-Host "Transcript: $transcriptPath"
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
