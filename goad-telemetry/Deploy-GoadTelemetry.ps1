#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DockerElkRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$GoadRoot = 'C:\lab\GOAD',
    [string]$InstanceName = 'c99bdc-goad-vmware',
    [ValidateSet('GOAD', 'GOAD-Light', 'GOAD-Mini', 'MINILAB')]
    [string]$LabName = 'GOAD',
    [ValidateSet('standard', 'disabled-vagrant')]
    [string]$InventoryMode = 'standard',
    [string]$ProvisioningMachine = 'PROVISIONING',
    [ValidateSet('all-windows', 'dc01', 'dc02', 'dc03', 'srv02', 'srv03')]
    [string]$Target = 'all-windows',
    [string]$SysmonDownloadUrl = 'https://download.sysinternals.com/files/Sysmon.zip',
    [string]$SysmonConfigUrl = 'https://github.com/olafhartong/sysmon-modular/releases/latest/download/sysmonconfig-excludes-only.xml',
    [string]$YamatoScriptUrl = 'https://github.com/Yamato-Security/EnableWindowsLogSettings/raw/refs/heads/main/YamatoSecurityConfigureWinEventLogs.bat'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-DotEnvValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    $match = Get-Content -LiteralPath $Path | Where-Object {
        $_ -match ('^\s*' + [regex]::Escape($Name) + '\s*=')
    } | Select-Object -Last 1
    if (-not $match) { return $null }
    return (($match -split '=', 2)[1].Trim().Trim('"').Trim("'"))
}

function Invoke-Vagrant {
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    & vagrant.exe @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "vagrant.exe failed with exit code ${LASTEXITCODE}: $($ArgumentList -join ' ')"
    }
}

function Invoke-ArtifactDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Description
    )

    Write-Host "Downloading $Description on the Windows host..."
    & curl.exe `
        --fail `
        --location `
        --silent `
        --show-error `
        --retry 4 `
        --retry-delay 2 `
        --retry-all-errors `
        --connect-timeout 30 `
        --output $Destination `
        $Url
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $Destination -PathType Leaf) -or
        (Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "Failed to download $Description from $Url"
    }
}

$providerDirectory = Join-Path $GoadRoot "workspace\$InstanceName\provider"
$secretPath = Join-Path $DockerElkRoot '.goad-secrets\fleet-enrollment.json'
$environmentPath = Join-Path $DockerElkRoot '.env'
$caPath = Join-Path $DockerElkRoot 'tls\certs\ca\ca.crt'
$playbookPath = Join-Path $PSScriptRoot 'ansible\goad-telemetry.yml'
$runnerPath = Join-Path $PSScriptRoot 'ansible\run-telemetry.sh'

foreach ($requiredFile in @($secretPath, $environmentPath, $caPath, $playbookPath, $runnerPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required file not found: $requiredFile"
    }
}
if (-not (Test-Path -LiteralPath $providerDirectory -PathType Container)) {
    throw "GOAD provider directory not found: $providerDirectory"
}
if (-not (Get-Command vagrant.exe -ErrorAction SilentlyContinue)) {
    throw 'vagrant.exe is required.'
}
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw 'curl.exe is required to stage telemetry artifacts on the Windows host.'
}
if ($InstanceName -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'InstanceName may contain only letters, numbers, underscores, and hyphens.'
}

$secret = Get-Content -LiteralPath $secretPath -Raw | ConvertFrom-Json
$agentVersion = Get-DotEnvValue -Path $environmentPath -Name 'ELASTIC_VERSION'
if ([string]::IsNullOrWhiteSpace($agentVersion)) {
    throw 'ELASTIC_VERSION was not found in .env.'
}
if ([string]::IsNullOrWhiteSpace([string]$secret.enrollment_token)) {
    throw 'The Fleet enrollment token is missing from fleet-enrollment.json.'
}

$fleetUri = [Uri]$secret.fleet_url
if ($fleetUri.Scheme -ne 'https') {
    throw 'Fleet URL must use HTTPS.'
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('goad-telemetry-' + [guid]::NewGuid().ToString('N'))
$remoteDirectory = '/tmp/goad-telemetry-' + [guid]::NewGuid().ToString('N')
$remoteCreated = $false
$ansibleLimit = if ($Target -eq 'all-windows') { 'dc01:dc02:dc03:srv02:srv03' } else { $Target }

New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
try {
    $variablePath = Join-Path $temporaryDirectory 'vars.json'
    $sysmonConfigPath = Join-Path $temporaryDirectory 'sysmonconfig.xml'
    $yamatoScriptPath = Join-Path $temporaryDirectory 'YamatoSecurityConfigureWinEventLogs.bat'

    Invoke-ArtifactDownload -Url $SysmonConfigUrl -Destination $sysmonConfigPath -Description 'the Hartong Sysmon configuration'
    Invoke-ArtifactDownload -Url $YamatoScriptUrl -Destination $yamatoScriptPath -Description 'the Yamato logging configuration'

    try {
        [xml]$sysmonConfiguration = Get-Content -LiteralPath $sysmonConfigPath -Raw -ErrorAction Stop
    } catch {
        throw "Downloaded Hartong configuration is not valid XML: $($_.Exception.Message)"
    }
    if ($sysmonConfiguration.DocumentElement.LocalName -ne 'Sysmon') {
        throw "Unexpected Hartong configuration root element: $($sysmonConfiguration.DocumentElement.LocalName)"
    }
    $yamatoContent = Get-Content -LiteralPath $yamatoScriptPath -Raw
    if ($yamatoContent -notmatch 'Yamato Security' -or
        $yamatoContent -notmatch '(?im)^\s*wevtutil\s' -or
        $yamatoContent -notmatch '(?im)^\s*auditpol\s') {
        throw 'Downloaded Yamato logging configuration failed content validation.'
    }

    [ordered]@{
        fleet_url = $secret.fleet_url
        fleet_host = $fleetUri.Host
        fleet_port = $fleetUri.Port
        fleet_enrollment_token = $secret.enrollment_token
        elastic_agent_version = $agentVersion
        sysmon_download_url = $SysmonDownloadUrl
    } | ConvertTo-Json | Set-Content -LiteralPath $variablePath -Encoding UTF8

    Push-Location $providerDirectory
    try {
        Write-Host "Preparing temporary deployment directory on $ProvisioningMachine..."
        Invoke-Vagrant -ArgumentList @('ssh', $ProvisioningMachine, '-c', "mkdir -m 700 '$remoteDirectory'")
        $remoteCreated = $true

        $uploads = @(
            [pscustomobject]@{ Source = $caPath; Name = 'ca.crt' }
            [pscustomobject]@{ Source = $playbookPath; Name = 'goad-telemetry.yml' }
            [pscustomobject]@{ Source = $runnerPath; Name = 'run-telemetry.sh' }
            [pscustomobject]@{ Source = $variablePath; Name = 'vars.json' }
            [pscustomobject]@{ Source = $sysmonConfigPath; Name = 'sysmonconfig.xml' }
            [pscustomobject]@{ Source = $yamatoScriptPath; Name = 'YamatoSecurityConfigureWinEventLogs.bat' }
        )
        foreach ($entry in $uploads) {
            Write-Host "Uploading $($entry.Name)..."
            Invoke-Vagrant -ArgumentList @(
                'upload',
                $entry.Source,
                "$remoteDirectory/$($entry.Name)",
                $ProvisioningMachine
            )
        }

        Write-Host 'Deploying telemetry to the five GOAD Windows VMs...'
        Invoke-Vagrant -ArgumentList @(
            'ssh',
            $ProvisioningMachine,
            '-c',
            "chmod 700 '$remoteDirectory/run-telemetry.sh' && '$remoteDirectory/run-telemetry.sh' '$remoteDirectory' '$ansibleLimit' '$InstanceName' '$LabName' '$InventoryMode'"
        )
    }
    finally {
        if ($remoteCreated) {
            Write-Host 'Removing temporary deployment material from PROVISIONING...'
            & vagrant.exe ssh $ProvisioningMachine -c "rm -rf -- '$remoteDirectory'"
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Could not remove temporary directory $remoteDirectory from $ProvisioningMachine."
            }
        }
        Pop-Location
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

Write-Host 'GOAD telemetry deployment completed successfully.' -ForegroundColor Green
Write-Host 'Open Fleet > Agents and confirm all five Windows agents are Healthy.'
