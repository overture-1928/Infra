#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/config/versions.env"
terraform_dir="$repo_dir/terraform/openstack"
terraform_bin="$repo_dir/.cache/terraform/bin/terraform"
runtime_dir="$repo_dir/.cache/kubespray-inventory/openstack"
output="$runtime_dir/hosts.yml"
cluster_plan="$repo_dir/.cache/cluster/cluster-plan.json"
topology_renderer="$repo_dir/scripts/render-openstack-cluster.py"

topology_config() {
  if [[ -n ${OPENSTACK_CLUSTER_CONFIG:-} ]]; then
    printf '%s\n' "$OPENSTACK_CLUSTER_CONFIG"
  elif [[ -f $repo_dir/inventory/openstack-cluster.local.yml ]]; then
    printf '%s\n' "$repo_dir/inventory/openstack-cluster.local.yml"
  else
    printf '%s\n' "$repo_dir/inventory/openstack-cluster.yml"
  fi
}

command -v jq >/dev/null || { echo 'jq is required.' >&2; exit 1; }
command -v sha256sum >/dev/null || { echo 'sha256sum is required.' >&2; exit 1; }
[[ -f $terraform_dir/terraform.tfstate ]] || {
  echo 'Apply terraform/openstack before rendering the Kubespray inventory.' >&2
  exit 1
}
[[ -x $terraform_bin ]] || {
  echo 'Run scripts/cluster.sh setup to install the pinned Terraform CLI.' >&2
  exit 1
}
terraform_version=$(
  "$terraform_bin" version -json 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || true
)
[[ $terraform_version == "$TERRAFORM_CLI_VERSION" ]] || {
  echo "Expected Terraform $TERRAFORM_CLI_VERSION; found ${terraform_version:-unknown}." >&2
  exit 1
}
terraform_state_sha256=$(sha256sum "$terraform_dir/terraform.tfstate" | awk '{print $1}')
nodes_json=$("$terraform_bin" -chdir="$terraform_dir" output -json kubernetes_nodes)
api_json=$("$terraform_bin" -chdir="$terraform_dir" output -json kubernetes_api)
terraform_state_sha256_after=$(sha256sum "$terraform_dir/terraform.tfstate" | awk '{print $1}')
[[ $terraform_state_sha256 == "$terraform_state_sha256_after" ]] || {
  echo 'Terraform state changed while rendering Kubespray input; rerun after Terraform is idle.' >&2
  exit 1
}
[[ $(jq 'length' <<<"$nodes_json") -ge 1 ]] || { echo 'No applied Kubernetes nodes found.' >&2; exit 1; }

platform_enabled=false
expected_management_api=
if [[ -f $cluster_plan ]]; then
  config=$(topology_config)
  [[ -f $config ]] || {
    echo "Authoritative OpenStack topology is missing: $config" >&2
    exit 1
  }
  [[ -f $topology_renderer ]] || {
    echo "OpenStack topology renderer is missing: $topology_renderer" >&2
    exit 1
  }
  python3 "$topology_renderer" --config "$config" --validate-only >/dev/null
  mapfile -t plan_values < <(python3 - "$cluster_plan" "$config" <<'PY'
import json
import sys
from pathlib import Path

plan_path = Path(sys.argv[1])
config_path = Path(sys.argv[2])
plan = json.loads(plan_path.read_text())
expected = config_path.resolve()
recorded_value = plan.get("config")
if not isinstance(recorded_value, str) or not recorded_value:
    raise SystemExit("Rendered cluster plan does not record its authoritative config path")
recorded = Path(recorded_value).resolve()
if recorded != expected:
    raise SystemExit(
        f"Rendered cluster plan uses {recorded}, not {expected}; run scripts/cluster.sh render"
    )
if plan_path.stat().st_mtime_ns < config_path.stat().st_mtime_ns:
    raise SystemExit(
        "Rendered cluster plan is older than the authoritative topology; "
        "run scripts/cluster.sh render"
    )
enabled = plan.get("platform", {}).get("magnum_capi", {}).get("enabled") is True
print("true" if enabled else "false")
print(str(plan.get("api_vip", "")))
PY
  )
  platform_enabled=${plan_values[0]}
  expected_management_api=${plan_values[1]:-}
fi

mkdir -p "$runtime_dir/group_vars/all" "$runtime_dir/group_vars/k8s_cluster"
NODES_JSON="$nodes_json" API_JSON="$api_json" RUNTIME_DIR="$runtime_dir" \
PLATFORM_ENABLED="$platform_enabled" EXPECTED_MANAGEMENT_API="$expected_management_api" \
TERRAFORM_STATE_SHA256="$terraform_state_sha256" CLUSTER_PLAN="$cluster_plan" python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

nodes = json.loads(os.environ["NODES_JSON"])
api = json.loads(os.environ["API_JSON"])
runtime = Path(os.environ["RUNTIME_DIR"])
platform_enabled = os.environ["PLATFORM_ENABLED"] == "true"
expected_management_api = os.environ["EXPECTED_MANAGEMENT_API"]
terraform_state_sha256 = os.environ["TERRAFORM_STATE_SHA256"]
cluster_plan_path = Path(os.environ["CLUSTER_PLAN"])
allowed_roles = {"control_plane", "etcd", "worker"}
ordered = sorted(nodes.items(), key=lambda item: (item[1]["inventory_order"], item[0]))
orders = [values["inventory_order"] for _, values in ordered]
if len(orders) != len(set(orders)):
    raise SystemExit("duplicate Kubernetes inventory_order")
for name, values in ordered:
    roles = set(values["roles"])
    if not roles or not roles <= allowed_roles:
        raise SystemExit(f"invalid roles for {name}: {sorted(roles)}")

lines = ["---", "all:", "  hosts:"]
for name, values in ordered:
    lines.extend([
        f"    {name}:",
        f"      ansible_host: {values['floating_ip']}",
        f"      ip: {values['fixed_ip']}",
        f"      access_ip: {values['fixed_ip']}",
    ])

group_map = {
    "kube_control_plane": "control_plane",
    "kube_node": "worker",
    "etcd": "etcd",
}
lines.extend(["  children:"])
for group, role in group_map.items():
    lines.extend([f"    {group}:", "      hosts:"])
    members = [name for name, values in ordered if role in values["roles"]]
    if not members:
        raise SystemExit(f"Kubespray group {group} is empty")
    for name in members:
        lines.append(f"        {name}:")
lines.extend([
    "    k8s_cluster:",
    "      children:",
    "        kube_control_plane:",
    "        kube_node:",
    "    calico_rr:",
    "      hosts: {}",
])
(runtime / "hosts.yml").write_text("\n".join(lines) + "\n")

control_plane_floating_ips = api["control_plane_floating_ips"]
management_api = api.get("management_api")
if platform_enabled:
    if not management_api:
        raise SystemExit("Terraform kubernetes_api output has no management_api address")
    if management_api != expected_management_api:
        raise SystemExit(
            "Terraform management_api does not match cluster.api_vip: "
            f"{management_api!r} != {expected_management_api!r}"
        )
sans = list(dict.fromkeys([value for value in [management_api, *control_plane_floating_ips] if value]))
generated_vars = [
    "---",
    f"kube_vip_address: {api['internal_vip']}",
    "loadbalancer_apiserver:",
    "  address: '{{ kube_vip_address }}'",
    "  port: 6443",
    "supplementary_addresses_in_ssl_keys:",
]
generated_vars.extend(f"  - {address}" for address in sans)
(runtime / "group_vars/k8s_cluster/zzz-openstack-generated.yml").write_text(
    "\n".join(generated_vars) + "\n"
)

platform_vars_path = runtime / "group_vars/all/zzz-openstack-platform.yml"
if platform_enabled:
    required_api_values = ("network_id", "subnet_id", "floating_network_id")
    missing = [name for name in required_api_values if not api.get(name)]
    if missing:
        raise SystemExit(
            "Terraform kubernetes_api output is missing platform network values: "
            + ", ".join(missing)
        )
    platform_vars = {
        "cloud_provider": "external",
        "external_cloud_provider": "openstack",
        "cinder_csi_enabled": True,
        "cinder_csi_controller_replicas": 3,
        "cinder_csi_ignore_volume_az": True,
        "storage_classes": [
            {
                "name": "cinder-csi",
                "is_default": True,
                "parameters": {"type": "ceph", "availability": "nova"},
            }
        ],
        "local_path_provisioner_is_default_storageclass": "false",
        "external_openstack_lbaas_enabled": True,
        "external_openstack_lbaas_provider": "ovn",
        "external_openstack_lbaas_method": "SOURCE_IP_PORT",
        "external_openstack_lbaas_manage_security_groups": True,
        "external_openstack_lbaas_network_id": api["network_id"],
        "external_openstack_lbaas_subnet_id": api["subnet_id"],
        "external_openstack_lbaas_floating_network_id": api["floating_network_id"],
        "external_openstack_network_internal_networks": ["kubernetes"],
    }
    import yaml
    platform_vars_path.write_text(yaml.safe_dump(platform_vars, sort_keys=False))
else:
    platform_vars_path.unlink(missing_ok=True)

desired = {
    "nodes": dict(ordered),
    "internal_vip": api["internal_vip"],
    "management_api": management_api,
    "bootstrap_api": control_plane_floating_ips[0],
    "platform_enabled": platform_enabled,
    "provenance": {
        "terraform_state_sha256": terraform_state_sha256,
        "cluster_plan_sha256": (
            hashlib.sha256(cluster_plan_path.read_bytes()).hexdigest()
            if cluster_plan_path.exists()
            else None
        ),
    },
}
(runtime / "desired-nodes.json").write_text(json.dumps(desired, indent=2) + "\n")
PY

echo "Rendered $output"
echo "Rendered $runtime_dir/group_vars/k8s_cluster/zzz-openstack-generated.yml"
