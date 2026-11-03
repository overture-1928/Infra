#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
node_name=${1:-cloud01}
config=${OPENSTACK_CLUSTER_CONFIG:-$repo_dir/inventory/openstack-cluster.local.yml}
[[ -f $config ]] || config="$repo_dir/inventory/openstack-cluster.yml"
template="$repo_dir/ubuntu-autoinstall/user-data.template"
meta_template="$repo_dir/ubuntu-autoinstall/meta-data"
output_dir="$repo_dir/ubuntu-autoinstall/generated/$node_name"
password_hash=${UBUNTU_OPERATOR_PASSWORD_HASH:-}
ssh_public_key=${UBUNTU_OPERATOR_SSH_PUBLIC_KEY:-}

if [[ -f $repo_dir/ubuntu-autoinstall/generated/user-data ]]; then
  echo 'WARNING: legacy ubuntu-autoinstall/generated/user-data is ignored; use the per-node generated directory.' >&2
fi

[[ $password_hash == \$6\$* || $password_hash == \$y\$* ]] || {
  echo 'Set UBUNTU_OPERATOR_PASSWORD_HASH to a SHA-512 or yescrypt crypt hash.' >&2
  echo "Example: export UBUNTU_OPERATOR_PASSWORD_HASH=\"\$(openssl passwd -6)\"" >&2
  exit 1
}
[[ $ssh_public_key =~ ^ssh-(ed25519|rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || {
  echo 'Set UBUNTU_OPERATOR_SSH_PUBLIC_KEY to one complete OpenSSH public key.' >&2
  exit 1
}
[[ $password_hash != *$'\n'* && $ssh_public_key != *$'\n'* ]] || {
  echo 'Autoinstall values must each be a single line.' >&2
  exit 1
}

mkdir -p "$output_dir"
AUTOINSTALL_CONFIG="$config" AUTOINSTALL_NODE="$node_name" \
AUTOINSTALL_TEMPLATE="$template" AUTOINSTALL_META_TEMPLATE="$meta_template" \
AUTOINSTALL_OUTPUT_DIR="$output_dir" AUTOINSTALL_PASSWORD_HASH="$password_hash" \
AUTOINSTALL_SSH_KEY="$ssh_public_key" python3 - <<'PY'
import os
import re
from pathlib import Path

import yaml

config = yaml.safe_load(Path(os.environ["AUTOINSTALL_CONFIG"]).read_text())
name = os.environ["AUTOINSTALL_NODE"]
try:
    node = config["nodes"][name]
except KeyError:
    raise SystemExit(f"unknown node in cluster inventory: {name}")

required = [
    "management_interface",
    "management_mac",
    "management_address",
    "management_gateway",
    "management_dns",
    "os_disk_serial",
]
for key in required:
    if key not in node or not node[key]:
        raise SystemExit(f"missing {name}.{key}")
    value = str(node[key])
    if "REPLACE" in value or value.startswith("EXAMPLE-"):
        raise SystemExit(f"replace public example value {name}.{key} before rendering autoinstall")
if not re.fullmatch(r"[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}", node["management_mac"]):
    raise SystemExit(f"invalid management MAC for {name}")
if not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", node["management_interface"]):
    raise SystemExit(f"invalid management interface for {name}")

dns_lines = "\n".join(f"            - {address}" for address in node["management_dns"])
source = Path(os.environ["AUTOINSTALL_TEMPLATE"]).read_text()
values = {
    "@@HOSTNAME@@": name,
    "@@MANAGEMENT_INTERFACE@@": node["management_interface"],
    "@@MANAGEMENT_MAC@@": node["management_mac"],
    "@@MANAGEMENT_ADDRESS@@": node["management_address"],
    "@@MANAGEMENT_GATEWAY@@": node["management_gateway"],
    "@@DNS_SERVERS@@": dns_lines,
    "@@OS_DISK_SERIAL@@": str(node["os_disk_serial"]),
    "@@PASSWORD_HASH@@": os.environ["AUTOINSTALL_PASSWORD_HASH"],
    "@@SSH_PUBLIC_KEY@@": os.environ["AUTOINSTALL_SSH_KEY"],
}
for marker, value in values.items():
    if marker not in source:
        raise SystemExit(f"missing marker: {marker}")
    source = source.replace(marker, value)
if "@@" in source:
    raise SystemExit("unresolved autoinstall marker remains")
yaml.safe_load(source)

meta = Path(os.environ["AUTOINSTALL_META_TEMPLATE"]).read_text().replace("@@HOSTNAME@@", name)
output = Path(os.environ["AUTOINSTALL_OUTPUT_DIR"])
(output / "user-data").write_text(source)
(output / "meta-data").write_text(meta)
PY
chmod 0600 "$output_dir/user-data"
chmod 0644 "$output_dir/meta-data"
echo "Rendered $output_dir for $node_name"
echo 'The generated user-data contains a password hash and stays outside Git.'
