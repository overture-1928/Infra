#!/usr/bin/env bash
# Manage an external Ceph cluster for Kolla-Ansible.
# Read-only validation is the default; OSD creation requires a topology digest.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/config/versions.env"

cache_dir="$repo_dir/.cache/ceph"
metadata="$cache_dir/topology.json"
ansible_inventory="$cache_dir/ansible-inventory.yml"
osd_spec="$cache_dir/ceph-osd-spec.yml"
manifest="$cache_dir/ceph-osd-manifest.txt"
digest_file="$cache_dir/ceph-osd-manifest.sha256"
device_playbook="$repo_dir/ansible/playbooks/verify-ceph-devices.yml"
temp_dir=

if [[ -n ${OPENSTACK_CLUSTER_CONFIG:-} ]]; then
  topology=$OPENSTACK_CLUSTER_CONFIG
elif [[ -f $repo_dir/inventory/openstack-cluster.local.yml ]]; then
  topology=$repo_dir/inventory/openstack-cluster.local.yml
else
  topology=$repo_dir/inventory/openstack-cluster.yml
fi

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  [[ -z $temp_dir ]] || rm -rf -- "$temp_dir"
}
trap cleanup EXIT

render_plan() {
  mkdir -p "$cache_dir"
  CEPH_TOPOLOGY="$topology" CEPH_CACHE="$cache_dir" python3 - <<'PY'
from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import re
from pathlib import Path

import yaml


def abort(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


topology_path = Path(os.environ["CEPH_TOPOLOGY"]).resolve()
cache = Path(os.environ["CEPH_CACHE"])
try:
    config = yaml.safe_load(topology_path.read_text())
except (OSError, yaml.YAMLError) as exc:
    abort(f"cannot read {topology_path}: {exc}")
if not isinstance(config, dict) or config.get("schema_version") != 1:
    abort("the topology must be a schema_version 1 YAML mapping")

cluster = config.get("cluster")
nodes_config = config.get("nodes")
if not isinstance(cluster, dict) or not isinstance(nodes_config, dict):
    abort("cluster and nodes must be mappings")
nodes = {
    name: node
    for name, node in nodes_config.items()
    if isinstance(node, dict) and node.get("enabled") is True
}
if not nodes:
    abort("at least one node must be enabled")

ceph = cluster.get("ceph")
ceph_enabled = (
    cluster.get("storage_backend") == "ceph"
    and isinstance(ceph, dict)
    and ceph.get("enabled") is True
)
metadata = {
    "enabled": ceph_enabled,
    "topology": str(topology_path),
    "hosts": {},
}
if not ceph_enabled:
    for name in (
        "ansible-inventory.yml",
        "ceph-osd-spec.yml",
        "ceph-osd-manifest.txt",
        "ceph-osd-manifest.sha256",
    ):
        (cache / name).unlink(missing_ok=True)
    (cache / "topology.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Validated topology; Ceph is disabled in {topology_path}")
    raise SystemExit(0)

if len(nodes) < 3:
    abort("Ceph requires at least three enabled hosts")
bootstrap_host = ceph.get("bootstrap_host")
if bootstrap_host not in nodes:
    abort("cluster.ceph.bootstrap_host must name an enabled host")
if nodes[bootstrap_host].get("connection", "ssh") != "local":
    abort("the Ceph bootstrap host must use connection=local")

try:
    public_network = ipaddress.ip_network(ceph["public_network"], strict=True)
except (KeyError, ValueError) as exc:
    abort(f"cluster.ceph.public_network is invalid: {exc}")
cluster_network_text = str(ceph.get("cluster_network", "")).strip()
try:
    cluster_network = (
        ipaddress.ip_network(cluster_network_text, strict=True)
        if cluster_network_text
        else None
    )
except ValueError as exc:
    abort(f"cluster.ceph.cluster_network is invalid: {exc}")
try:
    ratio = float(ceph.get("osd_memory_target_ratio", 0.2))
except (TypeError, ValueError):
    abort("cluster.ceph.osd_memory_target_ratio must be numeric")
if not 0.05 <= ratio <= 0.5:
    abort("osd_memory_target_ratio must be between 0.05 and 0.5 on converged hosts")
pool_device_class = ceph.get("openstack_pool_device_class")
if pool_device_class not in {"hdd", "ssd", "nvme"}:
    abort("cluster.ceph.openstack_pool_device_class must be hdd, ssd or nvme")

osd_nodes: dict[str, dict] = {}
for host, node in nodes.items():
    devices = node.get("ceph_osd_devices", [])
    if not isinstance(devices, list):
        abort(f"{host}.ceph_osd_devices must be a list")
    if devices:
        osd_nodes[host] = node
if len(osd_nodes) < 3:
    abort("Ceph requires explicit OSD devices on at least three enabled hosts")
ceph_nodes = {
    host: nodes[host]
    for host in sorted(set(osd_nodes) | {bootstrap_host})
}

ssh_private_key = str(cluster.get("ssh_private_key", "")).strip()
if not ssh_private_key.startswith("/") or any(ch in ssh_private_key for ch in "\n\r\0"):
    abort("cluster.ssh_private_key must be an absolute path")

path_re = re.compile(r"^/dev/disk/by-id/[A-Za-z0-9._:+-]+$")
host_re = re.compile(r"^[a-z][a-z0-9-]*$")
seen_paths: set[str] = set()
class_hosts: dict[str, set[str]] = {}
manifest_lines: list[str] = []
specs: list[dict] = []
ansible_hosts: dict[str, dict] = {}

for host, node in sorted(ceph_nodes.items()):
    if not host_re.fullmatch(host):
        abort(f"invalid bare hostname: {host}")
    address_text = str(node.get("ceph_address", "")).strip()
    try:
        address = ipaddress.ip_address(address_text)
    except ValueError as exc:
        abort(f"{host}.ceph_address is invalid: {exc}")
    if address not in public_network:
        abort(f"{host}.ceph_address is outside cluster.ceph.public_network")
    user = str(node.get("ansible_user", "")).strip()
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", user):
        abort(f"{host}.ansible_user is invalid")
    devices = node.get("ceph_osd_devices")
    if not devices and host != bootstrap_host:
        abort(f"{host} must declare at least one explicit ceph_osd_devices entry")

    rendered_devices = []
    for index, device in enumerate(devices or [], start=1):
        if not isinstance(device, dict):
            abort(f"{host}.ceph_osd_devices[{index}] must be a mapping")
        missing = {"by_id", "serial", "min_size_bytes", "device_class"} - set(device)
        if missing:
            abort(f"{host} Ceph device is missing: {', '.join(sorted(missing))}")
        by_id = str(device["by_id"])
        serial = str(device["serial"])
        device_class = str(device["device_class"])
        try:
            minimum = int(device["min_size_bytes"])
        except (TypeError, ValueError):
            abort(f"{host} min_size_bytes must be an integer")
        if not path_re.fullmatch(by_id):
            abort(f"{host} Ceph device must be a strict /dev/disk/by-id path")
        if by_id in seen_paths:
            abort(f"duplicate Ceph device path: {by_id}")
        seen_paths.add(by_id)
        if not serial or "REPLACE" in serial or any(ch in serial for ch in "|\n\r\0"):
            abort(f"{host} Ceph device serial is invalid or still a placeholder")
        if minimum < 10 * 1024**3:
            abort(f"{host} Ceph device minimum size must be at least 10 GiB")
        if device_class not in {"hdd", "ssd", "nvme"}:
            abort(f"{host} Ceph device_class must be hdd, ssd or nvme")
        class_hosts.setdefault(device_class, set()).add(host)
        rendered = {
            "by_id": by_id,
            "serial": serial,
            "min_size_bytes": minimum,
            "device_class": device_class,
        }
        rendered_devices.append(rendered)
        manifest_lines.append(
            "|".join([host, by_id, serial, str(minimum), device_class])
        )
        specs.append(
            {
                "service_type": "osd",
                "service_id": f"openstack-{host}-{index}",
                "placement": {"hosts": [host]},
                "crush_device_class": device_class,
                "spec": {
                    "data_devices": {"paths": [by_id]},
                },
            }
        )

    host_values = {
        "ansible_host": node.get("ansible_host", address_text),
        "ansible_user": user,
        "ansible_become": True,
        "ceph_address": address_text,
        "ceph_public_network": str(public_network),
        "ceph_cluster_network": str(cluster_network) if cluster_network else "",
        "ceph_osd_devices": rendered_devices,
    }
    connection = node.get("connection", "ssh")
    if connection == "local":
        host_values["ansible_connection"] = "local"
    elif connection == "ssh":
        host_values["ansible_ssh_private_key_file"] = ssh_private_key
    else:
        abort(f"{host}.connection must be local or ssh")
    ansible_hosts[host] = host_values
    metadata["hosts"][host] = {
        "address": address_text,
        "ansible_user": user,
        "connection": connection,
        "osd_devices": rendered_devices,
    }

for device_class, hosts in sorted(class_hosts.items()):
    if len(hosts) < 3:
        abort(
            f"device_class {device_class} is present on only {len(hosts)} host(s); "
            "a size=3 host-failure-domain pool requires that class on at least three hosts"
        )
if len(class_hosts.get(pool_device_class, set())) < 3:
    abort(
        f"openstack_pool_device_class {pool_device_class} is not present on at least "
        "three OSD hosts"
    )

ordered_hosts = [bootstrap_host] + sorted(set(osd_nodes) - {bootstrap_host})
monitor_hosts = ordered_hosts[:3]
metadata.update(
    {
        "bootstrap_host": bootstrap_host,
        "public_network": str(public_network),
        "cluster_network": str(cluster_network) if cluster_network else "",
        "osd_memory_target_ratio": ratio,
        "openstack_pool_device_class": pool_device_class,
        "ssh_private_key": ssh_private_key,
        "monitor_hosts": monitor_hosts,
        "osd_hosts": sorted(osd_nodes),
    }
)
manifest = "\n".join(sorted(manifest_lines)) + "\n"
digest = hashlib.sha256(manifest.encode()).hexdigest()
inventory = {
    "all": {
        "hosts": ansible_hosts,
        "children": {
            "ceph_hosts": {"hosts": {host: {} for host in sorted(osd_nodes)}}
        },
    }
}

(cache / "topology.json").write_text(json.dumps(metadata, indent=2) + "\n")
(cache / "ansible-inventory.yml").write_text(
    yaml.safe_dump(inventory, sort_keys=False)
)
(cache / "ceph-osd-spec.yml").write_text(
    yaml.safe_dump_all(specs, sort_keys=False)
)
(cache / "ceph-osd-manifest.txt").write_text(manifest)
(cache / "ceph-osd-manifest.sha256").write_text(digest + "\n")
print(
    f"Rendered Ceph plan for {len(ceph_nodes)} Ceph host(s), "
    f"including {len(osd_nodes)} OSD host(s), from {topology_path}"
)
print(f"OSD plan SHA256: {digest}")
PY
}

validate_topology() {
  python3 "$repo_dir/scripts/internal/render-openstack-cluster.py" \
    --config "$topology" --validate-only
}

require_enabled_plan() {
  validate_topology
  render_plan
  [[ $(python3 - "$metadata" <<'PY'
import json, sys
print("yes" if json.load(open(sys.argv[1]))["enabled"] else "no")
PY
) == yes ]] || fail 'Ceph is not enabled; use a reviewed local topology with storage_backend=ceph and ceph.enabled=true.'
}

metadata_value() {
  local key=$1
  python3 - "$metadata" "$key" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split('.'):
    value = value[key]
print(value)
PY
}

metadata_host_rows() {
  python3 - "$metadata" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for host, values in sorted(data["hosts"].items()):
    print(f"{host}\t{values['address']}\t{values['ansible_user']}")
PY
}

host_csv() {
  python3 - "$metadata" <<'PY'
import json, sys
print(",".join(sorted(json.load(open(sys.argv[1]))["hosts"])))
PY
}

monitor_placement() {
  python3 - "$metadata" <<'PY'
import json, sys
hosts = json.load(open(sys.argv[1]))["monitor_hosts"]
print(f"{len(hosts)} " + " ".join(hosts))
PY
}

find_ansible_playbook() {
  if [[ -x $repo_dir/.cache/kolla-venv/bin/ansible-playbook ]]; then
    printf '%s\n' "$repo_dir/.cache/kolla-venv/bin/ansible-playbook"
  else
    command -v ansible-playbook || true
  fi
}

preflight_devices() {
  require_enabled_plan
  local executable
  executable=$(find_ansible_playbook)
  [[ -n $executable ]] || fail 'ansible-playbook is required; run scripts/cluster.sh setup first.'
  ANSIBLE_CONFIG="$repo_dir/ansible/ansible.cfg" \
  ANSIBLE_LOCAL_TEMP=/tmp/openstack-ceph-ansible \
    "$executable" -i "$ansible_inventory" "$device_playbook"
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Run this command through sudo.'
}

require_cephadm() {
  command -v cephadm >/dev/null || fail 'cephadm is required on the bootstrap host.'
  [[ $CEPH_IMAGE != *[[:space:]]* && $CEPH_IMAGE == *:* && $CEPH_IMAGE != *:latest ]] || \
    fail 'CEPH_IMAGE must be an exact, non-latest image tag or digest.'
}

require_cluster() {
  require_root
  require_cephadm
  [[ -s /etc/ceph/ceph.conf ]] || fail '/etc/ceph/ceph.conf is missing; bootstrap Ceph first.'
  ceph_cmd status --format json >/dev/null
}

require_initial_osd_deployment() {
  require_cluster
  local existing_osd_count
  if ! existing_osd_count=$(
    ceph_cmd osd ls --format json |
      python3 -c '
import json, sys
osds = json.load(sys.stdin)
if not isinstance(osds, list):
    raise SystemExit("Ceph OSD list is not a JSON array")
print(len(osds))
'
  ); then
    fail 'Unable to inspect the existing Ceph OSD list.'
  fi
  (( existing_osd_count == 0 )) || fail \
    "Found $existing_osd_count existing Ceph OSD(s). osd-plan and osd-apply are only for the initial empty-cluster OSD deployment; incremental OSD expansion is not implemented."
}

ceph_cmd() {
  cephadm --image "$CEPH_IMAGE" shell -- ceph "$@"
}

ceph_tool() {
  cephadm --image "$CEPH_IMAGE" shell -- "$@"
}

ceph_with_spec() {
  cephadm --image "$CEPH_IMAGE" shell \
    --mount "$osd_spec" -- \
    ceph orch apply -i /mnt/ceph-osd-spec.yml "$@"
}

bootstrap_cluster() {
  preflight_devices
  require_root
  require_cephadm
  [[ ! -e /etc/ceph/ceph.conf ]] || fail 'A Ceph config already exists; refusing to bootstrap another cluster.'

  local existing_fsid
  existing_fsid=$(python3 - <<'PY'
from pathlib import Path
from uuid import UUID

root = Path("/var/lib/ceph")
if root.is_dir():
    for child in root.iterdir():
        try:
            UUID(child.name)
        except ValueError:
            continue
        print(child.name)
        break
PY
  )
  [[ -z $existing_fsid ]] || \
    fail "Existing cephadm state for FSID $existing_fsid is present under /var/lib/ceph."

  local bootstrap bootstrap_address bootstrap_user expected hosts key public_key ratio public_network cluster_network
  bootstrap=$(metadata_value bootstrap_host)
  bootstrap_address=$(metadata_value "hosts.$bootstrap.address")
  bootstrap_user=$(metadata_value "hosts.$bootstrap.ansible_user")
  hosts=$(host_csv)
  expected="BOOTSTRAP-CEPH:$hosts"
  [[ ${CEPH_BOOTSTRAP_CONFIRM:-} == "$expected" ]] || \
    fail "Set CEPH_BOOTSTRAP_CONFIRM='$expected' after reviewing the topology and device preflight."
  [[ $(hostname -s) == "$bootstrap" ]] || fail "Run bootstrap on $bootstrap; local hostname is $(hostname -s)."

  key=$(metadata_value ssh_private_key)
  public_key="${key}.pub"
  [[ -r $key && -r $public_key ]] || fail "Cephadm SSH key pair is missing: $key and $public_key"
  public_network=$(metadata_value public_network)
  cluster_network=$(metadata_value cluster_network)
  ratio=$(metadata_value osd_memory_target_ratio)

  cat >"$cache_dir/initial-ceph.conf" <<EOF
[global]
public_network = $public_network
EOF
  if [[ -n $cluster_network ]]; then
    printf 'cluster_network = %s\n' "$cluster_network" >>"$cache_dir/initial-ceph.conf"
  fi

  local -a bootstrap_args=(
    --mon-ip "$bootstrap_address"
    --ssh-user "$bootstrap_user"
    --ssh-private-key "$key"
    --ssh-public-key "$public_key"
    --config "$cache_dir/initial-ceph.conf"
  )
  [[ -z $cluster_network ]] || bootstrap_args+=(--cluster-network "$cluster_network")
  cephadm --image "$CEPH_IMAGE" bootstrap "${bootstrap_args[@]}"
  ceph_cmd config set mgr mgr/cephadm/autotune_memory_target_ratio "$ratio"
  ceph_cmd status
  echo 'Ceph bootstrap completed. Run add-hosts next; no OSD was created by this script.'
}

add_hosts() {
  require_enabled_plan
  require_cluster
  local address existing expected host hosts placement ratio _user
  hosts=$(host_csv)
  expected="ADD-CEPH-HOSTS:$hosts"
  [[ ${CEPH_HOSTS_CONFIRM:-} == "$expected" ]] || \
    fail "Set CEPH_HOSTS_CONFIRM='$expected' after reviewing host names and Ceph addresses."

  while IFS=$'\t' read -r host address _user; do
    existing=$(
      ceph_cmd orch host ls --format json |
        python3 -c 'import json,sys; name=sys.argv[1]; rows=json.load(sys.stdin); print(next((str(x.get("addr", "")) for x in rows if x.get("hostname") == name), "__MISSING__"))' "$host"
    )
    if [[ $existing == __MISSING__ ]]; then
      ceph_cmd orch host add "$host" "$address"
    elif [[ $existing != "$address" ]]; then
      fail "Ceph already knows $host with address $existing, expected $address."
    fi
  done < <(metadata_host_rows)

  placement=$(monitor_placement)
  ceph_cmd orch apply mon --placement "$placement"
  ceph_cmd orch apply mgr --placement "2 $(python3 - "$metadata" <<'PY'
import json, sys
print(" ".join(json.load(open(sys.argv[1]))["monitor_hosts"]))
PY
)"
  ratio=$(metadata_value osd_memory_target_ratio)
  ceph_cmd config set mgr mgr/cephadm/autotune_memory_target_ratio "$ratio"
  ceph_cmd orch host ls --detail
  echo 'Hosts and MON/MGR placement submitted. OSD devices remain untouched.'
}

show_status() {
  require_enabled_plan
  require_cluster
  ceph_cmd status
  ceph_cmd orch host ls --detail
  ceph_cmd orch device ls --wide --refresh
  ceph_cmd orch ps
}

osd_dry_run() {
  require_initial_osd_deployment
  preflight_devices
  ceph_cmd orch device ls --wide --refresh
  ceph_with_spec --dry-run
  local digest
  digest=$(<"$digest_file")
  printf '\nReviewed OSD manifest:\n'
  cat "$manifest"
  printf 'OSD plan SHA256: %s\n' "$digest"
  printf "Apply guard: CEPH_OSD_CONFIRM='WIPE-CEPH-OSDS:%s' sudo %s osd-apply\n" \
    "$digest" "$0"
}

apply_osds() {
  osd_dry_run
  local digest expected
  digest=$(<"$digest_file")
  expected="WIPE-CEPH-OSDS:$digest"
  [[ ${CEPH_OSD_CONFIRM:-} == "$expected" ]] || \
    fail "Set CEPH_OSD_CONFIRM exactly to $expected after reviewing this fresh dry-run."
  ceph_with_spec
  ceph_cmd orch ps --daemon-type osd
  echo 'OSD specifications submitted. Wait for recovery and HEALTH_OK before configuring pools.'
}

up_osd_host_count() {
  ceph_cmd osd tree --format json | python3 -c '
import json, sys
tree = json.load(sys.stdin)
nodes = tree.get("nodes", [])
up = {
    n["id"] for n in nodes
    if n.get("type") == "osd"
    and n.get("status") == "up"
    and float(n.get("reweight", 0)) > 0
    and float(n.get("crush_weight", 0)) > 0
}
hosts = {n.get("name") for n in nodes if n.get("type") == "host" and up.intersection(n.get("children", []))}
print(len(hosts))
'
}

up_osd_host_count_for_class() {
  local device_class=$1
  ceph_cmd osd tree --format json | python3 -c '
import json, sys
device_class = sys.argv[1]
nodes = json.load(sys.stdin).get("nodes", [])
up = {
    node.get("id")
    for node in nodes
    if node.get("type") == "osd"
    and node.get("status") == "up"
    and float(node.get("reweight", 0)) > 0
    and float(node.get("crush_weight", 0)) > 0
    and node.get("device_class") == device_class
}
hosts = {
    node.get("name")
    for node in nodes
    if node.get("type") == "host" and up.intersection(node.get("children", []))
}
print(len(hosts))
' "$device_class"
}

configure_pools() {
  require_enabled_plan
  require_cluster
  local pool_class expected rule_name
  pool_class=$(metadata_value openstack_pool_device_class)
  expected="CONFIGURE-CEPH-POOLS:${pool_class}:size3:min2"
  [[ ${CEPH_POOL_CONFIRM:-} == "$expected" ]] || \
    fail "Set CEPH_POOL_CONFIRM=$expected after OSD recovery is healthy."
  local health host_count class_host_count pools pool rules rule_json
  health=$(ceph_cmd health --format json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", "UNKNOWN"))')
  [[ $health == HEALTH_OK ]] || \
    fail "Ceph must be HEALTH_OK before pool configuration; current status is $health."
  host_count=$(up_osd_host_count)
  (( host_count >= 3 )) || fail "At least three hosts with up/in OSDs are required; found $host_count."
  class_host_count=$(up_osd_host_count_for_class "$pool_class")
  (( class_host_count >= 3 )) || \
    fail "Device class $pool_class needs up/in OSDs on at least three hosts; found $class_host_count."

  rule_name="openstack-${pool_class}-host"
  rules=$(ceph_cmd osd crush rule ls --format json)
  if ! python3 -c 'import json,sys; raise SystemExit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' \
    "$rule_name" <<<"$rules"; then
    ceph_cmd osd crush rule create-replicated "$rule_name" default host "$pool_class"
  fi
  rule_json=$(ceph_cmd osd crush rule dump "$rule_name" --format json)
  python3 -c '
import json, sys
rule = json.load(sys.stdin)
device_class = sys.argv[1]
steps = rule.get("steps", [])
take = next((step for step in steps if step.get("op") == "take"), {})
choose = next((step for step in steps if str(step.get("op", "")).startswith("chooseleaf")), {})
if not str(take.get("item_name", "")).endswith("~" + device_class):
    raise SystemExit("ERROR: existing CRUSH rule does not select device class " + device_class)
if choose.get("type") != "host":
    raise SystemExit("ERROR: existing CRUSH rule does not use host failure domain")
' "$pool_class" <<<"$rule_json"

  pools=$(ceph_cmd osd pool ls --format json)
  for pool in images volumes vms; do
    if ! python3 -c 'import json,sys; raise SystemExit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$pool" <<<"$pools"; then
      ceph_cmd osd pool create "$pool"
    fi
    ceph_cmd osd pool set "$pool" size 3
    ceph_cmd osd pool set "$pool" min_size 2
    ceph_cmd osd pool set "$pool" crush_rule "$rule_name"
    ceph_cmd osd pool set "$pool" pg_autoscale_mode on
    ceph_cmd osd pool application enable "$pool" rbd
    ceph_tool rbd pool init "$pool"
  done
  ceph_cmd osd pool ls detail
  echo "Created or verified images, volumes and vms pools on $pool_class with size=3 and min_size=2."
}

export_kolla() {
  require_enabled_plan
  require_cluster
  [[ ${CEPH_EXPORT_CONFIRM:-} == EXPORT-KOLLA-CEPH-CLIENTS ]] || \
    fail 'Set CEPH_EXPORT_CONFIRM=EXPORT-KOLLA-CEPH-CLIENTS to create least-privilege clients and export their keyrings.'

  local output="$repo_dir/kolla/generated/ceph-config"
  local pools
  pools=$(ceph_cmd osd pool ls --format json)
  for pool in images volumes vms; do
    python3 -c 'import json,sys; raise SystemExit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$pool" <<<"$pools" || \
      fail "Required Ceph pool is missing: $pool"
  done

  temp_dir=$(mktemp -d /tmp/openstack-ceph-export.XXXXXX)
  umask 077
  ceph_cmd auth get-or-create client.glance \
    mon 'profile rbd' \
    osd 'profile rbd pool=images' \
    mgr 'profile rbd pool=images' >/dev/null
  ceph_cmd auth caps client.glance \
    mon 'profile rbd' \
    osd 'profile rbd pool=images' \
    mgr 'profile rbd pool=images' >/dev/null
  ceph_cmd auth get-or-create client.cinder \
    mon 'profile rbd' \
    osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images' \
    mgr 'profile rbd pool=volumes, profile rbd pool=vms' >/dev/null
  ceph_cmd auth caps client.cinder \
    mon 'profile rbd' \
    osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images' \
    mgr 'profile rbd pool=volumes, profile rbd pool=vms' >/dev/null
  ceph_cmd config generate-minimal-conf >"$temp_dir/ceph.conf.raw"
  sed 's/^\t//' "$temp_dir/ceph.conf.raw" >"$temp_dir/ceph.conf"
  ceph_cmd auth get client.glance >"$temp_dir/ceph.client.glance.keyring"
  ceph_cmd auth get client.cinder >"$temp_dir/ceph.client.cinder.keyring"

  install -d -m 0700 \
    "$output/glance" \
    "$output/cinder/cinder-volume" \
    "$output/nova"
  install -m 0600 "$temp_dir/ceph.conf" \
    "$output/glance/ceph.conf"
  install -m 0600 "$temp_dir/ceph.conf" \
    "$output/cinder/ceph.conf"
  install -m 0600 "$temp_dir/ceph.conf" \
    "$output/nova/ceph.conf"
  install -m 0600 "$temp_dir/ceph.client.glance.keyring" \
    "$output/glance/ceph.client.glance.keyring"
  install -m 0600 "$temp_dir/ceph.client.cinder.keyring" \
    "$output/cinder/cinder-volume/ceph.client.cinder.keyring"
  install -m 0600 "$temp_dir/ceph.client.cinder.keyring" \
    "$output/nova/ceph.client.cinder.keyring"
  echo "Exported Kolla Ceph client files to $output"
  echo 'No Kolla configuration was installed or reconfigured, and no LVM volume was migrated.'
}

command_name=${1:-help}
case "$command_name" in
  help)
    cat <<'HELP'
Usage: scripts/ceph-cluster.sh COMMAND

  setup             install checksum-pinned cephadm on the bootstrap host
  validate          validate topology and render a deterministic OSD manifest
  preflight         verify every selected by-id device without changing it
  bootstrap         bootstrap cephadm on cloud01 (confirmation required)
  add-hosts         add all topology hosts and place MON/MGR (confirmation required)
  status            show Ceph health, hosts, devices and daemons
  osd-plan          plan the initial empty-cluster OSD deployment only
  osd-apply         submit initial OSD specs only (SHA confirmation required)
  configure-pools   create images/volumes/vms pools at size=3, min_size=2
  export-kolla      export least-privilege config/keyrings to an ignored directory

This script never zaps a non-empty disk and never migrates LVM, Glance or Nova data.
osd-plan and osd-apply stop when any OSD already exists; incremental expansion is not implemented.
Set OPENSTACK_CLUSTER_CONFIG to select a reviewed topology file.
HELP
    ;;
  setup)
    "$repo_dir/scripts/internal/setup-cephadm.sh"
    ;;
  validate)
    validate_topology
    render_plan
    ;;
  preflight)
    preflight_devices
    ;;
  bootstrap)
    bootstrap_cluster
    ;;
  add-hosts)
    add_hosts
    ;;
  status)
    show_status
    ;;
  osd-plan)
    osd_dry_run
    ;;
  osd-apply)
    apply_osds
    ;;
  configure-pools)
    configure_pools
    ;;
  export-kolla)
    export_kolla
    ;;
  *)
    fail "Unknown command: $command_name"
    ;;
esac
