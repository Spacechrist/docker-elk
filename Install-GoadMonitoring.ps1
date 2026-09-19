#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DockerElkRoot = $PSScriptRoot,
    [string]$GoadRoot = 'C:\lab\GOAD',
    [string]$InstanceName = 'c99bdc-goad-vmware',
    [ValidateSet('GOAD', 'GOAD-Light', 'GOAD-Mini', 'MINILAB')]
    [string]$LabName = 'GOAD',
    [ValidateSet('standard', 'disabled-vagrant')]
    [string]$InventoryMode = 'standard',
    [ValidateSet('all-windows', 'dc01', 'dc02', 'dc03', 'srv02', 'srv03')]
    [string]$Target = 'all-windows',
    [string]$LabAddress = '192.168.56.1',
    [int]$ReadinessTimeoutSeconds = 600,
    [switch]$SkipGoadVmStart,
    [switch]$SkipStackSetup,
    [switch]$SkipFleetInitialization,
    [switch]$SkipTelemetryDeployment
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Phase {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$Description = $FilePath
    )

    & $FilePath @ArgumentList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Description failed with exit code ${exitCode}: $($ArgumentList -join ' ')"
    }
}

function Get-DotEnvValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $match = Get-Content -LiteralPath $Path | Where-Object {
        $_ -match ('^\s*' + [regex]::Escape($Name) + '\s*=')
    } | Select-Object -Last 1
    if (-not $match) { return $null }
    $value = ($match -split '=', 2)[1].Trim()
    if ($value.Length -ge 2 -and
        (($value.StartsWith('"') -and $value.EndsWith('"')) -or
         ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
}

function Set-DotEnvValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $raw = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @([regex]::Split($raw, "`r?`n"))
    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*='
    $found = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match $pattern) {
            $lines[$index] = "$Name=$Value"
            $found = $true
        }
    }
    if (-not $found) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrEmpty($lines[-1])) {
            $lines += ''
        }
        $lines += "$Name=$Value"
    }
    [IO.File]::WriteAllText($Path, ($lines -join $newline), (New-Object Text.UTF8Encoding($false)))
}

function New-RandomHex {
    param([ValidateRange(16, 128)][int]$ByteCount = 32)

    $bytes = New-Object byte[] $ByteCount
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $generator.Dispose()
    }
}

function Get-CertificateSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "CA certificate not found: $Path"
    }
    $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($certificate.RawData))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $certificate.Dispose()
    }
}

function Ensure-LocalEnvironment {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "docker-elk environment file not found: $Path"
    }
    if ([string]::IsNullOrWhiteSpace((Get-DotEnvValue -Path $Path -Name 'ELASTIC_VERSION'))) {
        throw 'ELASTIC_VERSION must be set in .env.'
    }
    foreach ($name in @('ELASTIC_PASSWORD', 'KIBANA_SYSTEM_PASSWORD', 'LOGSTASH_INTERNAL_PASSWORD')) {
        if ([string]::IsNullOrWhiteSpace((Get-DotEnvValue -Path $Path -Name $name))) {
            throw "$name must be set in .env."
        }
    }
    if ([string]::IsNullOrWhiteSpace((Get-DotEnvValue -Path $Path -Name 'COMPOSE_PROJECT_NAME'))) {
        Set-DotEnvValue -Path $Path -Name 'COMPOSE_PROJECT_NAME' -Value 'goad-monitoring'
        Write-Host 'Generated local COMPOSE_PROJECT_NAME.'
    }
    foreach ($name in @(
        'KIBANA_SECURITY_ENCRYPTION_KEY',
        'KIBANA_SAVED_OBJECTS_ENCRYPTION_KEY',
        'KIBANA_REPORTING_ENCRYPTION_KEY'
    )) {
        if ([string]::IsNullOrWhiteSpace((Get-DotEnvValue -Path $Path -Name $name))) {
            Set-DotEnvValue -Path $Path -Name $name -Value (New-RandomHex)
            Write-Host "Generated local $name."
        }
    }
    if ($null -eq (Get-DotEnvValue -Path $Path -Name 'ELASTIC_CA_FINGERPRINT')) {
        Set-DotEnvValue -Path $Path -Name 'ELASTIC_CA_FINGERPRINT' -Value ''
    }
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMilliseconds = 2000
    )

    $client = New-Object Net.Sockets.TcpClient
    try {
        $result = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($result)
        return $true
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Wait-TcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-TcpPort -HostName $HostName -Port $Port) {
            Write-Host "$Name is accepting connections on ${HostName}:$Port."
            return
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Name on ${HostName}:$Port."
}

function Get-VagrantMachineState {
    param([Parameter(Mandatory)][string]$Machine)

    $output = & vagrant.exe status $Machine --machine-readable 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Vagrant status for $Machine.`n$($output -join "`n")"
    }
    $stateLine = $output | Where-Object { $_ -match ',state,' } | Select-Object -Last 1
    if (-not $stateLine) { return 'unknown' }
    return ($stateLine -split ',', 4)[3].Trim()
}

function Start-GoadMachines {
    param(
        [Parameter(Mandatory)][string]$ProviderDirectory,
        [Parameter(Mandatory)][string]$DeploymentTarget
    )

    $machineMap = @{
        dc01 = 'GOAD-DC01'
        dc02 = 'GOAD-DC02'
        dc03 = 'GOAD-DC03'
        srv02 = 'GOAD-SRV02'
        srv03 = 'GOAD-SRV03'
    }
    $machines = if ($DeploymentTarget -eq 'all-windows') {
        @('GOAD-DC01', 'GOAD-DC02', 'GOAD-DC03', 'GOAD-SRV02', 'GOAD-SRV03', 'PROVISIONING')
    }
    else {
        @($machineMap[$DeploymentTarget], 'PROVISIONING')
    }

    Push-Location $ProviderDirectory
    try {
        foreach ($machine in $machines) {
            $state = Get-VagrantMachineState -Machine $machine
            if ($state -eq 'running') {
                Write-Host "$machine is already running."
                continue
            }
            Write-Host "Starting $machine without rerunning GOAD provisioners..."
            Invoke-NativeCommand -FilePath 'vagrant.exe' `
                -ArgumentList @('up', $machine, '--no-provision') `
                -Description "Starting $machine"
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-DockerCompose {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$Description = 'Docker Compose'
    )
    Invoke-NativeCommand -FilePath 'docker.exe' `
        -ArgumentList (@('compose') + $ArgumentList) `
        -Description $Description
}

function Wait-FleetServer {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$CaCertificate,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $response = $null
        $curlExitCode = -1
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            $response = & curl.exe `
                --silent `
                --ssl-no-revoke `
                --cacert $CaCertificate `
                --max-time 10 `
                "$($Url.TrimEnd('/'))/api/status" 2>$null
            $curlExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($curlExitCode -eq 0 -and $response) {
            try {
                $status = (($response -join '') | ConvertFrom-Json).status
                Write-Host "Fleet Server status: $status"
                if ($status -eq 'HEALTHY') { return }
            }
            catch { }
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for a healthy Fleet Server at $Url."
}

function Test-ElasticsearchAuthentication {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$CaCertificate,
        [Parameter(Mandatory)][string]$EnvironmentPath
    )

    if (-not (Test-Path -LiteralPath $CaCertificate -PathType Leaf)) { return $false }
    $password = Get-DotEnvValue -Path $EnvironmentPath -Name 'ELASTIC_PASSWORD'
    $temporaryResponse = [IO.Path]::GetTempFileName()
    try {
        $statusCode = & curl.exe `
            --silent `
            --show-error `
            --ssl-no-revoke `
            --cacert $CaCertificate `
            --user "elastic:$password" `
            --max-time 10 `
            --output $temporaryResponse `
            --write-out '%{http_code}' `
            "$($Url.TrimEnd('/'))/_cluster/health" 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $code = [int](($statusCode -join '').Trim())
        return ($code -ge 200 -and $code -lt 400)
    }
    catch { return $false }
    finally {
        if (Test-Path -LiteralPath $temporaryResponse) {
            Remove-Item -LiteralPath $temporaryResponse -Force
        }
    }
}

function Show-FleetAgentSummary {
    param(
        [Parameter(Mandatory)][string]$KibanaUrl,
        [Parameter(Mandatory)][string]$CaCertificate,
        [Parameter(Mandatory)][string]$EnvironmentPath
    )

    $password = Get-DotEnvValue -Path $EnvironmentPath -Name 'ELASTIC_PASSWORD'
    $temporaryResponse = [IO.Path]::GetTempFileName()
    try {
        $statusCode = & curl.exe `
            --silent `
            --show-error `
            --ssl-no-revoke `
            --cacert $CaCertificate `
            --user "elastic:$password" `
            --header 'kbn-xsrf: true' `
            --output $temporaryResponse `
            --write-out '%{http_code}' `
            "$($KibanaUrl.TrimEnd('/'))/api/fleet/agents?perPage=100"
        if ($LASTEXITCODE -ne 0 -or [int](($statusCode -join '').Trim()) -ge 400) {
            Write-Warning 'Could not retrieve the final Fleet agent summary.'
            return
        }
        $response = [IO.File]::ReadAllText($temporaryResponse) | ConvertFrom-Json
        $agents = @($response.items | Where-Object { $_.policy_id -eq 'goad-windows-edr' })
        $online = @($agents | Where-Object { $_.status -eq 'online' }).Count
        $other = @($agents | Where-Object { $_.status -ne 'online' }).Count
        Write-Host "GOAD Fleet agents: $online online, $other requiring attention, $($agents.Count) total."
        if ($other -gt 0) {
            $agents | Where-Object { $_.status -ne 'online' } |
                Select-Object local_metadata, status, last_checkin |
                Format-Table -AutoSize | Out-Host
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryResponse) {
            Remove-Item -LiteralPath $temporaryResponse -Force
        }
    }
}

$DockerElkRoot = [IO.Path]::GetFullPath($DockerElkRoot)
$environmentPath = Join-Path $DockerElkRoot '.env'
$baseComposePath = Join-Path $DockerElkRoot 'docker-compose.yml'
$fleetComposePath = Join-Path $DockerElkRoot 'extensions\fleet\fleet-compose.yml'
$caPath = Join-Path $DockerElkRoot 'tls\certs\ca\ca.crt'
$fleetInitializer = Join-Path $DockerElkRoot 'Initialize-GoadFleet.ps1'
$telemetryLauncher = Join-Path $DockerElkRoot 'goad-telemetry\Deploy-GoadTelemetry.ps1'
$providerDirectory = Join-Path $GoadRoot "workspace\$InstanceName\provider"
$kibanaUrl = "https://${LabAddress}:5601"
$fleetUrl = "https://${LabAddress}:8220"

Write-Phase 'Preflight checks'
foreach ($command in @('docker.exe', 'vagrant.exe', 'curl.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required and was not found in PATH."
    }
}
foreach ($path in @($environmentPath, $baseComposePath, $fleetComposePath, $fleetInitializer, $telemetryLauncher)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required deployment file not found: $path"
    }
}
if (-not (Test-Path -LiteralPath $providerDirectory -PathType Container)) {
    throw "GOAD provider directory not found: $providerDirectory"
}
Ensure-LocalEnvironment -Path $environmentPath
if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
    $matchingAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $LabAddress } |
        Select-Object -First 1
    if (-not $matchingAddress) {
        throw "The host does not currently own GOAD adapter address $LabAddress."
    }
    Write-Host "GOAD host-only address $LabAddress is available on $($matchingAddress.InterfaceAlias)."
}
Invoke-NativeCommand -FilePath 'docker.exe' `
    -ArgumentList @('info', '--format', '{{.ServerVersion}}') `
    -Description 'Docker engine preflight'
Push-Location $DockerElkRoot
try {
    Invoke-DockerCompose -ArgumentList @(
        '-f', $baseComposePath,
        '-f', $fleetComposePath,
        'config', '--quiet'
    ) -Description 'Docker Compose configuration validation'
}
finally {
    Pop-Location
}

if (-not $SkipGoadVmStart) {
    Write-Phase 'Starting required GOAD VMs'
    Start-GoadMachines -ProviderDirectory $providerDirectory -DeploymentTarget $Target
}

if (-not $SkipStackSetup) {
    Write-Phase 'Starting the TLS-enabled Elastic stack'
    Push-Location $DockerElkRoot
    try {
        if (-not (Test-Path -LiteralPath $caPath -PathType Leaf)) {
            Write-Host 'Generating the private TLS certificate authority and service certificates...'
            Invoke-DockerCompose -ArgumentList @(
                '-f', $baseComposePath,
                '--profile', 'setup',
                'run', '--rm', 'tls'
            ) -Description 'TLS certificate generation'
        }
        $caFingerprint = Get-CertificateSha256 -Path $caPath
        if ((Get-DotEnvValue -Path $environmentPath -Name 'ELASTIC_CA_FINGERPRINT') -ne $caFingerprint) {
            Set-DotEnvValue -Path $environmentPath -Name 'ELASTIC_CA_FINGERPRINT' -Value $caFingerprint
            Write-Host 'Updated local ELASTIC_CA_FINGERPRINT.'
        }
        if (Test-ElasticsearchAuthentication `
            -Url "https://${LabAddress}:9200" `
            -CaCertificate $caPath `
            -EnvironmentPath $environmentPath) {
            Write-Host 'Elasticsearch authentication is already initialized.'
        }
        else {
            Invoke-DockerCompose -ArgumentList @(
                '-f', $baseComposePath,
                '--profile', 'setup',
                'run', '--rm', 'setup'
            ) -Description 'Elastic built-in user setup'
        }
        Invoke-DockerCompose -ArgumentList @(
            '-f', $baseComposePath,
            'up', '--detach', '--build',
            'elasticsearch', 'kibana', 'logstash'
        ) -Description 'Elastic stack startup'
    }
    finally {
        Pop-Location
    }
}
elseif (-not (Test-Path -LiteralPath $caPath -PathType Leaf)) {
    throw "The CA certificate is missing while -SkipStackSetup was selected: $caPath"
}

Wait-TcpPort -HostName $LabAddress -Port 9200 -Name 'Elasticsearch' -TimeoutSeconds $ReadinessTimeoutSeconds
Wait-TcpPort -HostName $LabAddress -Port 5601 -Name 'Kibana' -TimeoutSeconds $ReadinessTimeoutSeconds

if (-not $SkipFleetInitialization) {
    Write-Phase 'Initializing Fleet policies, integrations, output, and enrollment material'
    & $fleetInitializer `
        -KibanaUrl $kibanaUrl `
        -ElasticsearchUrl "https://${LabAddress}:9200" `
        -FleetUrl $fleetUrl `
        -CaCertificate $caPath `
        -EnvironmentFile $environmentPath
}

Write-Phase 'Starting Fleet Server'
Push-Location $DockerElkRoot
try {
    Invoke-DockerCompose -ArgumentList @(
        '-f', $baseComposePath,
        '-f', $fleetComposePath,
        'up', '--detach', '--build', 'fleet-server'
    ) -Description 'Fleet Server startup'
}
finally {
    Pop-Location
}
Wait-TcpPort -HostName $LabAddress -Port 8220 -Name 'Fleet Server' -TimeoutSeconds $ReadinessTimeoutSeconds
Wait-FleetServer -Url $fleetUrl -CaCertificate $caPath -TimeoutSeconds $ReadinessTimeoutSeconds

if (-not $SkipTelemetryDeployment) {
    Write-Phase "Deploying telemetry to $Target"
    & $telemetryLauncher `
        -DockerElkRoot $DockerElkRoot `
        -GoadRoot $GoadRoot `
        -InstanceName $InstanceName `
        -LabName $LabName `
        -InventoryMode $InventoryMode `
        -Target $Target
}

Write-Phase 'Final health summary'
Push-Location $DockerElkRoot
try {
    Invoke-DockerCompose -ArgumentList @(
        '-f', $baseComposePath,
        '-f', $fleetComposePath,
        'ps'
    ) -Description 'Docker Compose health summary'
}
finally {
    Pop-Location
}
Show-FleetAgentSummary -KibanaUrl $kibanaUrl -CaCertificate $caPath -EnvironmentPath $environmentPath

Write-Host "`nGOAD monitoring deployment completed successfully." -ForegroundColor Green
Write-Host "Kibana: $kibanaUrl"
Write-Host 'The generated .env secrets and .goad-secrets directory must remain uncommitted.'
