#requires -Version 5.1
# Revision 7: accepts blank lines while editing preconfigured output YAML.
[CmdletBinding()]
param(
    [string]$KibanaUrl = 'https://192.168.56.1:5601',
    [string]$ElasticsearchUrl = 'https://192.168.56.1:9200',
    [string]$FleetUrl = 'https://192.168.56.1:8220',
    [string]$CaCertificate = (Join-Path $PSScriptRoot 'tls\certs\ca\ca.crt'),
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '.env'),
    [string]$OutputId = 'goad-windows-output',
    [string]$PolicyId = 'goad-windows-edr',
    [string]$WindowsIntegrationName = 'GOAD Windows telemetry',
    [string]$DefendIntegrationName = 'GOAD Elastic Defend',
    [string]$EnrollmentKeyName = 'goad-windows-enrollment',
    [string]$ElasticUsername = 'elastic',
    [string]$ElasticPassword,
    [string]$SecretDirectory = (Join-Path $PSScriptRoot '.goad-secrets')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Get-CertificateSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "CA certificate not found: $Path"
    }
    $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($certificate.RawData))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $certificate.Dispose()
    }
}

function Set-LineRange {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][int]$Start,
        [Parameter(Mandatory)][int]$End,
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Replacement
    )

    $before = if ($Start -gt 0) { @($Lines[0..($Start - 1)]) } else { @() }
    $after = if ($End -lt $Lines.Count) { @($Lines[$End..($Lines.Count - 1)]) } else { @() }
    return @($before + $Replacement + $after)
}

function Ensure-PreconfiguredOutputCa {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$CertificatePem
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Kibana configuration not found: $ConfigPath"
    }

    $raw = [IO.File]::ReadAllText($ConfigPath)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @([regex]::Split($raw, "`r?`n"))
    $idPattern = '^(?<indent>\s*)-\s+id:\s*["'']?' + [regex]::Escape($Id) + '["'']?\s*(?:#.*)?$'
    $idIndex = -1
    $listIndent = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $match = [regex]::Match($lines[$i], $idPattern)
        if ($match.Success) {
            $idIndex = $i
            $listIndent = $match.Groups['indent'].Value.Length
            break
        }
    }
    if ($idIndex -lt 0) {
        throw "Could not locate preconfigured Fleet output '$Id' in $ConfigPath."
    }

    $blockEnd = $lines.Count
    for ($i = $idIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*(?:#.*)?$') { continue }
        $indent = ([regex]::Match($lines[$i], '^\s*')).Value.Length
        if ($indent -le $listIndent) {
            $blockEnd = $i
            break
        }
    }

    $sslIndent = $listIndent + 2
    $sslIndex = -1
    for ($i = $idIndex + 1; $i -lt $blockEnd; $i++) {
        if ($lines[$i] -match ('^\s{' + $sslIndent + '}ssl:\s*(?:#.*)?$')) {
            $sslIndex = $i
            break
        }
    }

    $certificateLines = @($CertificatePem -split "`n")
    if ($sslIndex -lt 0) {
        $replacement = @(
            ((' ' * $sslIndent) + 'ssl:'),
            ((' ' * ($sslIndent + 2)) + 'certificate_authorities:'),
            ((' ' * ($sslIndent + 4)) + '- |')
        ) + @($certificateLines | ForEach-Object { (' ' * ($sslIndent + 6)) + $_ })
        $lines = Set-LineRange -Lines $lines -Start $blockEnd -End $blockEnd -Replacement $replacement
    }
    else {
        $sslEnd = $blockEnd
        for ($i = $sslIndex + 1; $i -lt $blockEnd; $i++) {
            if ($lines[$i] -match '^\s*(?:#.*)?$') { continue }
            $indent = ([regex]::Match($lines[$i], '^\s*')).Value.Length
            if ($indent -le $sslIndent) {
                $sslEnd = $i
                break
            }
        }

        $caIndent = $sslIndent + 2
        $caIndex = -1
        for ($i = $sslIndex + 1; $i -lt $sslEnd; $i++) {
            if ($lines[$i] -match ('^\s{' + $caIndent + '}certificate_authorities:\s*')) {
                $caIndex = $i
                break
            }
        }
        $replacement = @(
            ((' ' * $caIndent) + 'certificate_authorities:'),
            ((' ' * ($caIndent + 2)) + '- |')
        ) + @($certificateLines | ForEach-Object { (' ' * ($caIndent + 4)) + $_ })

        if ($caIndex -lt 0) {
            $lines = Set-LineRange -Lines $lines -Start $sslEnd -End $sslEnd -Replacement $replacement
        }
        else {
            $caEnd = $sslEnd
            for ($i = $caIndex + 1; $i -lt $sslEnd; $i++) {
                if ($lines[$i] -match '^\s*(?:#.*)?$') { continue }
                $indent = ([regex]::Match($lines[$i], '^\s*')).Value.Length
                if ($indent -le $caIndent) {
                    $caEnd = $i
                    break
                }
            }
            $lines = Set-LineRange -Lines $lines -Start $caIndex -End $caEnd -Replacement $replacement
        }
    }

    $backupPath = $ConfigPath + '.goad-before-ca.bak'
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath
    }
    [IO.File]::WriteAllText($ConfigPath, ($lines -join $newline), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-KibanaApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )

    $arguments = @(
        '--silent', '--show-error',
        '--ssl-no-revoke', '--cacert', $CaCertificate,
        '--user', ('{0}:{1}' -f $ElasticUsername, $script:ResolvedPassword),
        '--request', $Method,
        '--header', 'kbn-xsrf: true',
        '--header', 'Content-Type: application/json'
    )
    $temporaryBody = $null
    $temporaryResponse = [IO.Path]::GetTempFileName()
    try {
        if ($PSBoundParameters.ContainsKey('Body')) {
            $temporaryBody = [IO.Path]::GetTempFileName()
            $json = $Body | ConvertTo-Json -Depth 30 -Compress
            [IO.File]::WriteAllText($temporaryBody, $json, (New-Object Text.UTF8Encoding($false)))
            $arguments += @('--data-binary', ('@' + $temporaryBody))
        }
        $arguments += @(
            '--output', $temporaryResponse,
            '--write-out', '%{http_code}',
            ($KibanaUrl.TrimEnd('/') + $Path)
        )
        $statusCode = & curl.exe @arguments
        $responseText = if (Test-Path -LiteralPath $temporaryResponse) {
            [IO.File]::ReadAllText($temporaryResponse)
        } else { '' }
        if ($LASTEXITCODE -ne 0) {
            throw "Kibana API request failed: $Method $Path (curl exit $LASTEXITCODE)"
        }
        $statusCode = [int](($statusCode -join '').Trim())
        if ($statusCode -ge 400) {
            throw "Kibana API request failed: $Method $Path (HTTP $statusCode)`n$responseText"
        }
        if ([string]::IsNullOrWhiteSpace($responseText)) { return $null }
        return ($responseText | ConvertFrom-Json)
    }
    finally {
        if ($temporaryBody -and (Test-Path -LiteralPath $temporaryBody)) {
            Remove-Item -LiteralPath $temporaryBody -Force
        }
        if ($temporaryResponse -and (Test-Path -LiteralPath $temporaryResponse)) {
            Remove-Item -LiteralPath $temporaryResponse -Force
        }
    }
}

function Get-Items {
    param([object]$Response)
    if ($null -eq $Response) { return @() }
    if ($null -ne $Response.items) { return @($Response.items) }
    if ($null -ne $Response.list) { return @($Response.list) }
    return @()
}

function Test-OutputEmbeddedCa {
    param([object]$Output)

    if ($null -eq $Output) { return $false }
    $configYamlProperty = $Output.PSObject.Properties['config_yaml']
    if ($null -ne $configYamlProperty -and ($configYamlProperty.Value | Out-String) -match 'BEGIN CERTIFICATE') {
        return $true
    }
    $sslProperty = $Output.PSObject.Properties['ssl']
    if ($null -ne $sslProperty -and $null -ne $sslProperty.Value) {
        $authoritiesProperty = $sslProperty.Value.PSObject.Properties['certificate_authorities']
        if ($null -ne $authoritiesProperty -and ($authoritiesProperty.Value | Out-String) -match 'BEGIN CERTIFICATE') {
            return $true
        }
    }
    return $false
}

function Wait-Kibana {
    Write-Host 'Waiting for Kibana...'
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $status = Invoke-KibanaApi -Method GET -Path '/api/status'
            if ($status.status.overall.level -in @('available', 'degraded')) { return }
        }
        catch {
            if ($attempt -eq 60) { throw }
        }
        Start-Sleep -Seconds 5
    }
    throw 'Kibana did not become ready within five minutes.'
}

function Restart-Kibana {
    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue) -and
        -not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker CLI is required to reload a preconfigured Fleet output.'
    }
    Push-Location $PSScriptRoot
    try {
        & docker compose restart kibana
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose restart kibana failed with exit code ${LASTEXITCODE}."
        }
    }
    finally {
        Pop-Location
    }
}

function Get-PackagePolicyAgentIds {
    param([Parameter(Mandatory)][object]$PackagePolicy)

    $policyIdsProperty = $PackagePolicy.PSObject.Properties['policy_ids']
    if ($null -ne $policyIdsProperty) { return @($policyIdsProperty.Value) }
    $policyIdProperty = $PackagePolicy.PSObject.Properties['policy_id']
    if ($null -ne $policyIdProperty) { return @($policyIdProperty.Value) }
    return @()
}

function Ensure-FleetPackage {
    param([Parameter(Mandatory)][string]$Name)

    $packageResponse = Invoke-KibanaApi -Method GET -Path ('/api/fleet/epm/packages/' + $Name)
    $package = $packageResponse.item
    if ($null -eq $package -or [string]::IsNullOrWhiteSpace([string]$package.version)) {
        throw "Fleet did not return a usable version for package '$Name'."
    }

    $installedVersion = $null
    $installationInfoProperty = $package.PSObject.Properties['installationInfo']
    if ($null -ne $installationInfoProperty -and
        $null -ne $installationInfoProperty.Value -and
        $installationInfoProperty.Value.install_status -eq 'installed') {
        $installedVersion = [string]$package.version
    }
    if ([string]::IsNullOrWhiteSpace($installedVersion)) {
        $targetVersion = [string]$package.version
        Write-Host "Installing Fleet package '$Name' version $targetVersion..."
        [void](Invoke-KibanaApi -Method POST -Path ('/api/fleet/epm/packages/{0}/{1}' -f $Name, $targetVersion) -Body @{
            force = $false
        })
        return $targetVersion
    }

    Write-Host "Fleet package '$Name' version $installedVersion is installed."
    return $installedVersion
}

function Find-PackagePolicy {
    param(
        [Parameter(Mandatory)][object[]]$PackagePolicies,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$AgentPolicyId
    )

    $named = $PackagePolicies | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -ne $named) {
        $agentIds = @(Get-PackagePolicyAgentIds -PackagePolicy $named)
        if ($named.package.name -ne $PackageName -or $AgentPolicyId -notin $agentIds) {
            throw "Package policy '$Name' already exists but is attached to a different package or agent policy."
        }
        return $named
    }

    return $PackagePolicies | Where-Object {
        $_.package.name -eq $PackageName -and
        $AgentPolicyId -in @(Get-PackagePolicyAgentIds -PackagePolicy $_)
    } | Select-Object -First 1
}

$script:ResolvedPassword = $ElasticPassword
if ([string]::IsNullOrWhiteSpace($script:ResolvedPassword)) {
    $script:ResolvedPassword = Get-DotEnvValue -Path $EnvironmentFile -Name 'ELASTIC_PASSWORD'
}
if ([string]::IsNullOrWhiteSpace($script:ResolvedPassword)) {
    throw 'Set ELASTIC_PASSWORD in .env or pass -ElasticPassword.'
}
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw 'curl.exe is required.'
}

$fingerprint = Get-CertificateSha256 -Path $CaCertificate
$caPem = [IO.File]::ReadAllText($CaCertificate).Replace("`r`n", "`n").Trim()
if ($caPem -notmatch '^-----BEGIN CERTIFICATE-----' -or
    $caPem -notmatch '-----END CERTIFICATE-----$') {
    throw "CA certificate is not a PEM certificate: $CaCertificate"
}
$indentedCaPem = (($caPem -split "`n") | ForEach-Object { '      ' + $_ }) -join "`n"
$outputConfigYaml = "ssl:`n  certificate_authorities:`n    - |`n$indentedCaPem`n"

Wait-Kibana

Write-Host 'Initializing Fleet...'
[void](Invoke-KibanaApi -Method POST -Path '/api/fleet/setup' -Body @{})

Write-Host "Ensuring Fleet output '$OutputId'..."
$outputsResponse = Invoke-KibanaApi -Method GET -Path '/api/fleet/outputs'
$output = Get-Items $outputsResponse | Where-Object { $_.id -eq $OutputId -or $_.name -eq 'GOAD Windows output' } | Select-Object -First 1
$outputBody = [ordered]@{
    id = $OutputId
    name = 'GOAD Windows output'
    type = 'elasticsearch'
    hosts = @($ElasticsearchUrl)
    is_default = $false
    is_default_monitoring = $false
    ca_trusted_fingerprint = $fingerprint
    config_yaml = $outputConfigYaml
}
if ($null -eq $output) {
    $created = Invoke-KibanaApi -Method POST -Path '/api/fleet/outputs' -Body $outputBody
    $output = $created.item
}
elseif (-not ($null -ne $output.PSObject.Properties["is_preconfigured"] -and $output.PSObject.Properties["is_preconfigured"].Value -eq $true)) {
    $outputBody.Remove('id')
    $updated = Invoke-KibanaApi -Method PUT -Path ('/api/fleet/outputs/' + $output.id) -Body $outputBody
    $output = $updated.item
}
elseif ($output.id -ne $OutputId) {
    throw "A preconfigured output named 'GOAD Windows output' exists with unexpected ID '$($output.id)'."
}

if ($null -ne $output -and ($null -ne $output.PSObject.Properties["is_preconfigured"] -and $output.PSObject.Properties["is_preconfigured"].Value -eq $true)) {
    Write-Host "Updating preconfigured Fleet output '$OutputId' in kibana.yml..."
    $kibanaConfiguration = Join-Path $PSScriptRoot 'kibana\config\kibana.yml'
    Ensure-PreconfiguredOutputCa `
        -ConfigPath $kibanaConfiguration `
        -Id $OutputId `
        -CertificatePem $caPem
    Restart-Kibana
    Wait-Kibana
    [void](Invoke-KibanaApi -Method POST -Path '/api/fleet/setup' -Body @{})
}

$verifiedOutputsResponse = Invoke-KibanaApi -Method GET -Path '/api/fleet/outputs'
$verifiedOutput = Get-Items $verifiedOutputsResponse | Where-Object { $_.id -eq $OutputId } | Select-Object -First 1
if (-not (Test-OutputEmbeddedCa -Output $verifiedOutput)) {
    throw "Fleet output '$OutputId' did not retain the embedded CA certificate."
}
$output = $verifiedOutput

Write-Host "Ensuring agent policy '$PolicyId'..."
$policiesResponse = Invoke-KibanaApi -Method GET -Path '/api/fleet/agent_policies?perPage=100'
$policy = Get-Items $policiesResponse | Where-Object { $_.id -eq $PolicyId -or $_.name -eq 'GOAD Windows EDR' } | Select-Object -First 1
$policyBody = [ordered]@{
    id = $PolicyId
    name = 'GOAD Windows EDR'
    description = 'Fleet-managed telemetry policy for the GOAD Windows lab.'
    namespace = 'goad'
    monitoring_enabled = @('logs', 'metrics')
    data_output_id = $output.id
    monitoring_output_id = $output.id
}
if ($null -eq $policy) {
    $created = Invoke-KibanaApi -Method POST -Path '/api/fleet/agent_policies' -Body $policyBody
    $policy = $created.item
}
elseif (-not $policy.is_managed) {
    $policyBody.Remove('id')
    $updated = Invoke-KibanaApi -Method PUT -Path ('/api/fleet/agent_policies/' + $policy.id) -Body $policyBody
    $policy = $updated.item
}

Write-Host 'Ensuring Windows telemetry and Elastic Defend integrations...'
$windowsVersion = Ensure-FleetPackage -Name 'windows'
$endpointVersion = Ensure-FleetPackage -Name 'endpoint'

$packagePoliciesResponse = Invoke-KibanaApi -Method GET -Path '/api/fleet/package_policies?perPage=100'
$packagePolicies = @(Get-Items $packagePoliciesResponse)

$windowsPolicy = Find-PackagePolicy `
    -PackagePolicies $packagePolicies `
    -Name $WindowsIntegrationName `
    -PackageName 'windows' `
    -AgentPolicyId $policy.id
if ($null -eq $windowsPolicy) {
    Write-Host "Creating Windows integration '$WindowsIntegrationName'..."
    $created = Invoke-KibanaApi -Method POST -Path '/api/fleet/package_policies' -Body ([ordered]@{
        name = $WindowsIntegrationName
        description = 'Windows event channels for the GOAD lab, including Sysmon when installed.'
        namespace = 'goad'
        policy_ids = @($policy.id)
        package = [ordered]@{
            name = 'windows'
            version = $windowsVersion
        }
        inputs = [ordered]@{}
    })
    $windowsPolicy = $created.item
}
else {
    Write-Host "Windows integration '$($windowsPolicy.name)' already exists."
}

$defendPolicy = Find-PackagePolicy `
    -PackagePolicies $packagePolicies `
    -Name $DefendIntegrationName `
    -PackageName 'endpoint' `
    -AgentPolicyId $policy.id
if ($null -eq $defendPolicy) {
    Write-Host "Creating Elastic Defend integration '$DefendIntegrationName' in Data Collection mode..."
    $created = Invoke-KibanaApi -Method POST -Path '/api/fleet/package_policies' -Body ([ordered]@{
        name = $DefendIntegrationName
        description = 'Non-blocking endpoint telemetry for the GOAD attack lab.'
        namespace = 'goad'
        policy_id = $policy.id
        enabled = $true
        inputs = @(
            [ordered]@{
                enabled = $true
                streams = @()
                type = 'ENDPOINT_INTEGRATION_CONFIG'
                config = [ordered]@{
                    _config = [ordered]@{
                        value = [ordered]@{
                            type = 'endpoint'
                            endpointConfig = [ordered]@{
                                preset = 'DataCollection'
                            }
                        }
                    }
                }
            }
        )
        package = [ordered]@{
            name = 'endpoint'
            title = 'Elastic Defend'
            version = $endpointVersion
        }
    })
    $defendPolicy = $created.item
}
else {
    Write-Host "Elastic Defend integration '$($defendPolicy.name)' already exists."
}

Write-Host 'Ensuring an active enrollment token...'
$keysResponse = Invoke-KibanaApi -Method GET -Path '/api/fleet/enrollment_api_keys?perPage=100'
$enrollmentKeys = @(Get-Items $keysResponse)
$enrollmentKey = $enrollmentKeys | Where-Object {
    $_.policy_id -eq $policy.id -and $_.active -eq $true
} | Sort-Object created_at -Descending | Select-Object -First 1
if ($null -eq $enrollmentKey) {
    Write-Host "No active enrollment key matched policy '$($policy.id)'."
    Write-Host "Kibana returned $($enrollmentKeys.Count) enrollment-key record(s)."
    $enrollmentKeys |
        Select-Object id, name, policy_id, active, hidden |
        Format-Table -AutoSize | Out-Host
    $keyName = $EnrollmentKeyName
    if ($enrollmentKeys | Where-Object { $_.name -eq $keyName }) {
        $keyName = '{0}-{1}' -f $EnrollmentKeyName, $policy.id
    }
    $created = Invoke-KibanaApi -Method POST -Path '/api/fleet/enrollment_api_keys' -Body @{
        name = $keyName
        policy_id = $policy.id
    }
    $enrollmentKey = $created.item
}

New-Item -ItemType Directory -Path $SecretDirectory -Force | Out-Null
$secretPath = Join-Path $SecretDirectory 'fleet-enrollment.json'
[ordered]@{
    policy_id = $policy.id
    output_id = $output.id
    fleet_url = $FleetUrl
    elasticsearch_url = $ElasticsearchUrl
    ca_sha256 = $fingerprint
    windows_package_policy_id = $windowsPolicy.id
    elastic_defend_package_policy_id = $defendPolicy.id
    windows_package_version = $windowsVersion
    endpoint_package_version = $endpointVersion
    enrollment_key_id = $enrollmentKey.id
    enrollment_token = $enrollmentKey.api_key
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath $secretPath -Encoding UTF8

Write-Host 'Fleet bootstrap complete.' -ForegroundColor Green
Write-Host "Policy: $($policy.id)"
Write-Host "Output: $($output.id)"
Write-Host "Windows integration: $($windowsPolicy.id)"
Write-Host "Elastic Defend integration: $($defendPolicy.id) (Data Collection preset)"
Write-Host "Enrollment material: $secretPath"
Write-Host 'The enrollment token was intentionally not printed.'
