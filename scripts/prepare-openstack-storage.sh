#!/usr/bin/env bash
# Prepare the reviewed data SSD while preserving the future Ceph NVMe.
# Dry-run unless --apply is supplied.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
apply=false
[[ ${1:-} == --apply ]] && apply=true
[[ -z ${1:-} || ${1:-} == --apply ]] || {
  echo "Usage: $0 [--apply]" >&2
  exit 2
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

plan_config=${OPENSTACK_PLAN_CONFIG:-}
if [[ -z $plan_config ]]; then
  if [[ -f $repo_dir/inventory/openstack-plan.local.yml ]]; then
    plan_config="$repo_dir/inventory/openstack-plan.local.yml"
  else
    plan_config="$repo_dir/inventory/openstack-plan.yml"
  fi
fi
[[ -r $plan_config ]] || fail "OpenStack plan is not readable: $plan_config"
command -v python3 >/dev/null || fail 'python3 is required to read the OpenStack plan.'

storage_config=$(
  python3 - "$plan_config" <<'PY'
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    raise SystemExit("python3-yaml is required to read the OpenStack plan") from exc

path = Path(sys.argv[1])
try:
    document = yaml.safe_load(path.read_text())
    storage = document["storage"]
    os_serial = str(storage["os"]["serial"])
    data = storage["openstack_data"]
    ceph = storage["ceph_reserve"]
    values = [
        os_serial,
        str(data["serial"]),
        str(ceph["serial"]),
        str(data["docker_partition"]),
        str(data["cinder_volume_group"]),
        str(ceph["min_size_bytes"]),
        str(ceph["device_class"]),
    ]
    protected = [str(item["serial"]) for item in storage.get("untouched", [])]
except (OSError, KeyError, TypeError) as exc:
    raise SystemExit(f"invalid storage configuration in {path}: {exc}") from exc

for serial in values[:3] + protected:
    if not serial or not re.fullmatch(r"[A-Za-z0-9._:+-]+", serial):
        raise SystemExit(f"invalid disk serial in {path}: {serial!r}")
if not re.fullmatch(r"[1-9][0-9]*GiB", values[3]):
    raise SystemExit("storage.openstack_data.docker_partition must look like 256GiB")
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+_.-]*", values[4]):
    raise SystemExit(f"invalid Cinder volume group: {values[4]!r}")
if not re.fullmatch(r"[1-9][0-9]*", values[5]):
    raise SystemExit("storage.ceph_reserve.min_size_bytes must be a positive integer")
if values[6] not in {"hdd", "ssd", "nvme"}:
    raise SystemExit("storage.ceph_reserve.device_class must be hdd, ssd or nvme")

print(*values, *protected, sep="\n")
PY
) || fail "Could not load storage settings from $plan_config"
mapfile -t storage_values <<<"$storage_config"
(( ${#storage_values[@]} >= 7 )) || fail "Storage settings are incomplete in $plan_config"

os_serial=${storage_values[0]}
data_serial=${storage_values[1]}
ceph_serial=${storage_values[2]}
docker_partition_size=${storage_values[3]}
data_vg=${storage_values[4]}
ceph_min_size=${storage_values[5]}
ceph_device_class=${storage_values[6]}
protected_serials=("${storage_values[@]:7}")

for serial in "$os_serial" "$data_serial" "$ceph_serial"; do
  [[ $serial != EXAMPLE-* && $serial != *REPLACE* ]] || fail \
    "Replace public example serials in inventory/openstack-plan.local.yml before preparing storage."
done
confirmation="WIPE-OPENSTACK-DATA:${data_serial}:KEEP-CEPH:${ceph_serial}"

find_disk() {
  local wanted=$1 path serial type
  while read -r path serial type; do
    [[ $type == disk && $serial == "$wanted" ]] && { printf '%s\n' "$path"; return 0; }
  done < <(lsblk -dn -o PATH,SERIAL,TYPE)
  return 1
}

partition_path() {
  local disk=$1 number=$2
  if [[ $disk =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$number"
  else
    printf '%s%s\n' "$disk" "$number"
  fi
}

data_disk=$(find_disk "$data_serial") || fail "1TB SSD serial $data_serial was not found."
ceph_disk=$(find_disk "$ceph_serial") || fail "Reserved Ceph disk serial $ceph_serial was not found."
os_disk=$(find_disk "$os_serial") || fail "OS SSD serial $os_serial was not found."
[[ $data_disk != "$ceph_disk" && $data_disk != "$os_disk" && $ceph_disk != "$os_disk" ]] || \
  fail 'Storage roles resolved to the same device.'

data_size=$(lsblk -bdno SIZE "$data_disk")
ceph_size=$(lsblk -bdno SIZE "$ceph_disk")
os_size=$(lsblk -bdno SIZE "$os_disk")
(( os_size >= 120000000000 )) || fail 'OS SSD is smaller than the reviewed 128GB class device.'
(( data_size >= 900000000000 )) || fail 'OpenStack data SSD is smaller than the reviewed 1TB class device.'
(( ceph_size >= ceph_min_size )) || fail 'Reserved Ceph disk is smaller than storage.ceph_reserve.min_size_bytes.'

for serial in "${protected_serials[@]}"; do
  protected_disk=$(find_disk "$serial" || true)
  [[ -z $protected_disk || ( $protected_disk != "$data_disk" && $protected_disk != "$ceph_disk" ) ]] || \
    fail "Protected disk $serial resolved to an initialization target."
done

root_source=$(findmnt -n -o SOURCE /)
for disk in "$data_disk" "$ceph_disk"; do
  if lsblk -sno PATH "$root_source" | grep -Fxq "$disk"; then
    fail "$disk contains the active root filesystem."
  fi
done

data_part_docker=$(partition_path "$data_disk" 1)
data_part_cinder=$(partition_path "$data_disk" 2)

cat <<PLAN
Storage plan:
  Source:                          $plan_config
  OS disk, unchanged:              $os_disk ($os_serial)
  OpenStack data SSD:              $data_disk ($data_serial)
    partition 1: $docker_partition_size ext4      -> /var/lib/docker
    partition 2: remaining space   -> LVM VG $data_vg
  Future Ceph OSD, unchanged:      $ceph_disk ($ceph_serial)
    minimum size:                  $ceph_min_size bytes
    device class:                  $ceph_device_class
    one-node phase:                no partition, filesystem, PV or VG is created
  Explicitly protected serials:    ${protected_serials[*]}
PLAN

if [[ $(blkid -s LABEL -o value "$data_part_docker" 2>/dev/null || true) == openstack-docker ]] && \
   vgs "$data_vg" >/dev/null 2>&1; then
  ssd_pv=$(pvs --noheadings -o pv_name --select "vg_name=$data_vg" | xargs)
  [[ $ssd_pv == "$data_part_cinder" ]] || \
    fail 'The existing Cinder VG does not use the expected partition.'
  echo 'Expected storage layout already exists; no destructive action is needed.'
  echo "Reserved Ceph disk remains unchanged: $ceph_disk ($ceph_serial)"
  exit 0
fi

[[ $apply == true ]] || {
  echo 'Dry-run complete. Recheck the physical labels and serials before applying.'
  echo "Apply with: OPENSTACK_STORAGE_CONFIRM='$confirmation' sudo $0 --apply"
  exit 0
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Run the apply step as root.'
[[ ${OPENSTACK_STORAGE_CONFIRM:-} == "$confirmation" ]] || \
  fail "Set OPENSTACK_STORAGE_CONFIRM exactly to $confirmation"

for command_name in sgdisk partprobe udevadm mkfs.ext4 pvcreate vgcreate blkid findmnt; do
  command -v "$command_name" >/dev/null || fail "$command_name is required."
done

if lsblk -nrpo MOUNTPOINTS "$data_disk" | grep -qE '/.+'; then
  fail "$data_disk or one of its partitions is mounted."
fi
if lsblk -nrpo MOUNTPOINTS "$ceph_disk" | grep -qE '/.+'; then
  fail "$ceph_disk is reserved for Ceph but it or one of its partitions is mounted."
fi
if [[ -d /var/lib/docker && -n $(find /var/lib/docker -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  fail '/var/lib/docker is not empty; move or remove its existing contents before applying.'
fi
! vgs "$data_vg" >/dev/null 2>&1 || fail "VG $data_vg already exists with an unverified layout."

sgdisk --zap-all "$data_disk"
sgdisk --new="1:1MiB:+$docker_partition_size" --typecode=1:8300 --change-name=1:openstack-docker "$data_disk"
sgdisk --new=2:0:0 --typecode=2:8e00 --change-name="2:$data_vg" "$data_disk"
partprobe "$data_disk"
udevadm settle

mkfs.ext4 -F -L openstack-docker "$data_part_docker"
pvcreate -ff -y "$data_part_cinder"
vgcreate "$data_vg" "$data_part_cinder"

mkdir -p /var/lib/docker
docker_uuid=$(blkid -s UUID -o value "$data_part_docker")
fstab_line="UUID=$docker_uuid /var/lib/docker ext4 defaults,noatime 0 2"
grep -qF "$fstab_line" /etc/fstab || printf '%s\n' "$fstab_line" >>/etc/fstab
mount /var/lib/docker

echo 'Storage prepared. The future Ceph disk was not modified.'
echo 'Reboot once, then verify findmnt /var/lib/docker and vgs cinder-ssd.'
