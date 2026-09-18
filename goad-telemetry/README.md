# GOAD telemetry deployment

This add-on uses the existing GOAD `PROVISIONING` VM to configure the five
Windows lab machines:

- `dc01`, `dc02`, `dc03`, `srv02`, and `srv03`
- Sysmon with Olaf Hartong's modular configuration
- Yamato Security's enhanced Windows event-log settings
- Elastic Agent matching `ELASTIC_VERSION` from docker-elk `.env`
- Enrollment into the existing `goad-windows-edr` Fleet policy
- The docker-elk CA in the Windows `LocalMachine\Root` trust store, allowing
  every Elastic Agent component to validate Elasticsearch

Elastic Defend is already configured in Fleet's non-blocking **Data Collection**
preset. The playbook does not configure prevention modes.

## Layout

Copy this entire `goad-telemetry` directory into the docker-elk repository:

```text
C:\lab\docker-elk\goad-telemetry
```

The launcher expects these existing files in the parent docker-elk directory:

```text
.env
.goad-secrets\fleet-enrollment.json
tls\certs\ca\ca.crt
```

It also expects the GOAD instance at:

```text
C:\lab\GOAD\workspace\c99bdc-goad-vmware
```

Both Docker Desktop and all six Vagrant machines must be running.

The deployment downloads the two small GitHub-hosted configuration artifacts
once on the Windows host, uploads them temporarily to `PROVISIONING`, and copies
them to the Windows VMs over WinRM. The older lab VMs therefore do not need a
GitHub-compatible TLS stack. Signed Microsoft Sysmon and Elastic Agent binaries
remain direct vendor downloads. It executes Ansible inside `PROVISIONING` using GOAD's synchronized
inventory stack in `~/GOAD`: the lab inventory, rendered provider inventory,
enabled extension inventories, and `globalsettings.ini`. This preserves GOAD's
WinRM connection settings and credentials; Windows targets are never contacted
over SSH.

## One-command deployment

For a fully provisioned GOAD instance, the root-level orchestrator performs the
entire monitoring workflow. It starts stopped Vagrant machines with
`--no-provision`, generates missing local Kibana encryption keys, validates the
Compose configuration, prepares and starts the TLS-enabled Elastic stack,
initializes Fleet, starts Fleet Server, deploys the Windows telemetry, and
prints a final health summary:

```powershell
cd C:\lab\docker-elk
.\Install-GoadMonitoring.ps1
```

The workflow is resumable and idempotent. Individual phases can be skipped when
troubleshooting or rerunning a completed deployment:

```powershell
.\Install-GoadMonitoring.ps1 `
    -SkipGoadVmStart `
    -SkipStackSetup `
    -SkipFleetInitialization
```

Use `-Target dc01` for a canary deployment. Local secrets written to `.env` and
`.goad-secrets` are runtime material and must not be committed.

For a completely empty `C:\lab`, use the repository-root
`Bootstrap-GoadMonitoring.ps1`. It clones the fixed GOAD and docker-elk
branches, creates the GOAD Python virtual environment at `GOAD\.venv`,
provisions GOAD with VMware, discovers the generated instance identifier, and then invokes
`Install-GoadMonitoring.ps1`.

`Reset-GoadMonitoring.ps1` is the destructive clean-room companion. It refuses
to run unless permanent destruction is explicitly selected and both local
repositories match their tracking and remote branches. It asks GOAD itself to
destroy the selected VMware instance, checks for residual Vagrant machines,
and removes the Compose project before deleting only `C:\lab\GOAD`,
including its `.venv`, and `C:\lab\docker-elk`.

## Recommended first run

Before deploying agents, run the idempotent Fleet initializer from the
docker-elk repository root. It embeds the private CA in the Elasticsearch
output policy so every managed component can validate Elasticsearch:

```powershell
cd C:\lab\docker-elk
.\Initialize-GoadFleet.ps1
```

When `goad-windows-output` is preconfigured, the initializer updates its
`ssl.certificate_authorities` setting in `kibana\config\kibana.yml`, preserves
the original once as `kibana.yml.goad-before-ca.bak`, restarts Kibana, and
verifies that Fleet loaded the CA. API-managed outputs are updated directly.

Deploy to `dc01` as a canary:

```powershell
cd C:\lab\docker-elk\goad-telemetry
.\Deploy-GoadTelemetry.ps1 -Target dc01
```

Confirm `dc01` is Healthy in **Fleet → Agents**, then deploy the remaining
machines (rerunning against `dc01` is safe):

```powershell
.\Deploy-GoadTelemetry.ps1
```

The playbook runs one Windows VM at a time. Downloads and configurations are
idempotent; a healthy existing Elastic Agent is not reinstalled. Temporary
inventory, CA, playbook, and enrollment material are removed from the
`PROVISIONING` VM in a `finally` block.

## Overrides

For a differently named instance or GOAD location:

```powershell
.\Deploy-GoadTelemetry.ps1 `
    -GoadRoot 'D:\GOAD' `
    -InstanceName 'my-goad-instance'
```

If you explicitly ran GOAD's `disable_vagrant` workflow, select its alternate
credential inventory:

```powershell
.\Deploy-GoadTelemetry.ps1 -InventoryMode disabled-vagrant -Target dc01
```

Upstream URLs can be overridden with `-SysmonDownloadUrl`,
`-SysmonConfigUrl`, and `-YamatoScriptUrl`. Sysmon and Elastic Agent binaries
must have valid Authenticode signatures from their expected publishers. The
downloaded Hartong configuration is parsed as XML and must have a `Sysmon` root
element before it is applied. By default, the Hartong configuration comes from
the repository's `releases/latest/download/sysmonconfig.xml` asset.

## Verification

The playbook checks on every target:

- TCP reachability to Fleet Server
- a valid Microsoft signature on `Sysmon64.exe`
- the Sysmon service and event-log channel
- a valid Elasticsearch signature on the Elastic Agent MSI
- the docker-elk CA is present in the machine-wide Windows trust store
- a running, healthy Elastic Agent

After all agents are Healthy, verify data in Kibana Discover with:

```text
host.name:* and data_stream.namespace:goad
```

Then check these datasets separately:

```text
data_stream.dataset:windows.sysmon_operational
data_stream.dataset:windows.security
data_stream.dataset:endpoint.events.process
```

## Security notes

- `.goad-secrets` must remain ignored by Git.
- The enrollment token is written only to a local temporary directory and the
  provisioning VM's mode-0700 temporary directory.
- Ansible hides the enrollment assertions and installer task with `no_log`.
- Do not use this playbook outside the isolated GOAD lab without reviewing the
  Sysmon and Windows audit configurations first.
