#!/usr/bin/env bash
# Read-only disk identity and health preflight for the Ubuntu/OpenStack install.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plan_config=${OPENSTACK_PLAN_CONFIG:-}
if [[ -z $plan_config ]]; then
  if [[ -f $repo_dir/inventory/openstack-plan.local.yml ]]; then
    plan_config="$repo_dir/inventory/openstack-plan.local.yml"
  else
    plan_config="$repo_dir/inventory/openstack-plan.yml"
  fi
fi
protected_serials=()

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  protected_output=$(
    python3 - "$plan_config" <<'PY'
import sys
from pathlib import Path

import yaml

path = Path(sys.argv[1])
try:
    storage = yaml.safe_load(path.read_text())["storage"]
    serials = [str(item["serial"]) for item in storage.get("untouched", [])]
except (OSError, KeyError, TypeError, yaml.YAMLError) as exc:
    raise SystemExit(f"cannot read protected disks from {path}: {exc}") from exc
for serial in serials:
    if not serial.startswith("EXAMPLE-") and "REPLACE" not in serial:
        print(serial)
PY
  ) || {
    echo "Could not read protected disk serials from $plan_config" >&2
    exit 1
  }
  [[ -z $protected_output ]] || mapfile -t protected_serials <<<"$protected_output"
else
  echo "WARNING: python3-yaml is unavailable; protected serials from $plan_config will not be highlighted." >&2
fi

section() {
  printf '\n### %s\n' "$1"
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run this script as root on the current server." >&2
  exit 1
fi

for command_name in hostname lsblk blkid readlink awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing command: $command_name" >&2
    exit 1
  fi
done

section "Host"
hostname
sed -n '1,8p' /etc/os-release

section "Block devices"
lsblk -e 7 -o NAME,PATH,SIZE,TYPE,FSTYPE,FSVER,MOUNTPOINTS,MODEL,SERIAL,WWN

section "Filesystem and RAID signatures"
blkid || true

section "Persistent disk aliases"
for disk_path in /dev/disk/by-id/*; do
  [[ -e "$disk_path" ]] || continue
  printf '%s -> %s\n' "$disk_path" "$(readlink -e -- "$disk_path")"
done

section "Disks protected from automatic initialization"
if (( ${#protected_serials[@]} == 0 )); then
  echo "No real protected serials are configured in $plan_config."
  echo 'Copy inventory/openstack-plan.yml to inventory/openstack-plan.local.yml and record the hardware values.'
else
  for serial in "${protected_serials[@]}"; do
    device=$(lsblk -dnpo PATH,SERIAL | awk -v serial="$serial" '$2 == serial {print $1; exit}')
    if [[ -n $device ]]; then
      printf '%s -> %s\n' "$serial" "$device"
    else
      printf '%s -> NOT FOUND\n' "$serial"
    fi
  done
fi

section "SMART health"
if command -v smartctl >/dev/null 2>&1; then
  while IFS= read -r device; do
    printf '\n## %s\n' "$device"
    smartctl -H -i "$device" || true
  done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')
else
  echo "smartctl is unavailable; install smartmontools and rerun before selecting the install disk."
fi

printf '\n%s\n' \
  "No VM, disk, storage, LVM or network configuration was changed." \
  "Match the install target by model and serial; never rely on /dev/sdX ordering."
