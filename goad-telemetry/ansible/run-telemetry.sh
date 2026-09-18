#!/usr/bin/env bash
set -euo pipefail

deploy_dir="${1:?deployment directory is required}"
target_limit="${2:?target limit is required}"
instance_name="${3:?GOAD instance name is required}"
lab_name="${4:?GOAD lab name is required}"
inventory_mode="${5:-standard}"

goad_root="$HOME/GOAD"
instance_dir="$goad_root/workspace/$instance_name"

if command -v ansible-playbook >/dev/null 2>&1; then
  ansible_command="$(command -v ansible-playbook)"
elif [[ -x "$HOME/GOAD/.venv/bin/ansible-playbook" ]]; then
  ansible_command="$HOME/GOAD/.venv/bin/ansible-playbook"
elif [[ -x "$HOME/GOAD/venv/bin/ansible-playbook" ]]; then
  ansible_command="$HOME/GOAD/venv/bin/ansible-playbook"
else
  echo 'ansible-playbook was not found on the PROVISIONING VM.' >&2
  exit 127
fi

if [[ ! "$instance_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo 'Invalid GOAD instance name.' >&2
  exit 2
fi

inventory_args=()
if [[ "$inventory_mode" == 'disabled-vagrant' ]]; then
  disabled_inventory="$instance_dir/inventory_disable_vagrant"
  if [[ ! -f "$disabled_inventory" ]]; then
    echo "GOAD disabled-vagrant inventory not found: $disabled_inventory" >&2
    exit 2
  fi
  inventory_args+=( -i "$disabled_inventory" )
elif [[ "$inventory_mode" == 'standard' ]]; then
  lab_inventory="$goad_root/ad/$lab_name/data/inventory"
  provider_inventory="$instance_dir/inventory"
  for required_inventory in "$lab_inventory" "$provider_inventory"; do
    if [[ ! -f "$required_inventory" ]]; then
      echo "Required GOAD inventory not found: $required_inventory" >&2
      exit 2
    fi
  done
  inventory_args+=( -i "$lab_inventory" -i "$provider_inventory" )
else
  echo "Unknown inventory mode: $inventory_mode" >&2
  exit 2
fi

shopt -s nullglob
for extension_inventory in "$instance_dir"/*_inventory; do
  inventory_args+=( -i "$extension_inventory" )
done
shopt -u nullglob

if [[ -f "$goad_root/globalsettings.ini" ]]; then
  inventory_args+=( -i "$goad_root/globalsettings.ini" )
fi

"$ansible_command" \
  "${inventory_args[@]}" \
  "$deploy_dir/goad-telemetry.yml" \
  --limit "$target_limit" \
  --extra-vars "@$deploy_dir/vars.json" \
  --extra-vars "goad_ca_source=$deploy_dir/ca.crt" \
  --extra-vars "goad_sysmon_config_source=$deploy_dir/sysmonconfig.xml" \
  --extra-vars "goad_yamato_script_source=$deploy_dir/YamatoSecurityConfigureWinEventLogs.bat"
