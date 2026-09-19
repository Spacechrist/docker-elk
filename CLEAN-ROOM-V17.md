# GOAD monitoring clean-room v17

Before committing these scripts, remove the `goad-windows-output` item from
`kibana/config/kibana.yml`. Keep the existing `fleet-default-output`. The
initializer will create `goad-windows-output` through the Fleet API with the
CA generated for the current deployment.

The bootstrap now stops after cloning repositories, creating `GOAD\.venv`, and
installing `noansible_requirements.yml`. Run GOAD manually with `--method vm`.
After GOAD provisioning succeeds, run `Install-GoadMonitoring.ps1` with the
explicit instance name.

When multiple historical workspace instances exist, pass the active instance
explicitly to the reset script with `-InstanceName`.

The monitoring installer now writes `ELASTIC_CA_FINGERPRINT` after TLS
generation and treats transient Fleet TLS startup failures as retryable.
