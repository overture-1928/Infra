#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/config/versions.env"

renderer="$repo_dir/scripts/render-openstack-cluster.py"
plan_file="$repo_dir/.cache/cluster/cluster-plan.json"
ceph_plan_file="$repo_dir/.cache/cluster/ceph-plan.json"
generated_globals="$repo_dir/kolla/generated/globals.yml"
generated_magnum_kubeconfig="$repo_dir/kolla/generated/magnum/kubeconfig"
installed_magnum_kubeconfig=/etc/kolla/config/magnum/kubeconfig
management_kubeconfig=${MANAGEMENT_KUBECONFIG:-"$repo_dir/kubeconfig/admin.conf"}
desired_nodes="$repo_dir/.cache/kubespray-inventory/openstack/desired-nodes.json"
terraform_state="$repo_dir/terraform/openstack/terraform.tfstate"
generated_haproxy_config="$repo_dir/kolla/generated/haproxy/services.d/kubernetes-management-api.cfg"
service_account_manifest="$repo_dir/capi/magnum-service-account.yml"
hosted_template="$repo_dir/capi/k0smotron-hosted-control-plane.yml.tmpl"
platform_cache="$repo_dir/.cache/platform"
command_name=${1:-help}
kubectl_bin=

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required."
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Run this command through sudo.'
}

require_versions() {
  local name value
  for name in KUBECTL_VERSION CLUSTERCTL_VERSION CAPI_VERSION CAPO_VERSION ORC_VERSION K0SMOTRON_VERSION; do
    value=${!name:-}
    [[ $value =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || \
      fail "$name must be an exact vX.Y.Z version in config/versions.env."
  done
  for name in \
    CLUSTERCTL_LINUX_AMD64_SHA256 \
    CLUSTERCTL_LINUX_ARM64_SHA256 \
    KUBECTL_LINUX_AMD64_SHA256 \
    KUBECTL_LINUX_ARM64_SHA256 \
    ORC_INSTALL_SHA256; do
    value=${!name:-}
    [[ $value =~ ^[0-9a-f]{64}$ ]] || fail "$name must be an exact lowercase SHA-256."
  done
}

select_kubectl() {
  local architecture download_arch expected_sha
  architecture=$(uname -m)
  case "$architecture" in
    x86_64)
      download_arch=amd64
      expected_sha=$KUBECTL_LINUX_AMD64_SHA256
      ;;
    aarch64|arm64)
      download_arch=arm64
      expected_sha=$KUBECTL_LINUX_ARM64_SHA256
      ;;
    *) fail "Unsupported architecture for kubectl: $architecture" ;;
  esac
  kubectl_bin="$repo_dir/.cache/kubernetes/bin/kubectl-${KUBECTL_VERSION}-${download_arch}"
  [[ -x $kubectl_bin ]] || \
    fail "Pinned kubectl is missing: $kubectl_bin; run scripts/setup-kubespray.sh."
  printf '%s  %s\n' "$expected_sha" "$kubectl_bin" | sha256sum -c - >/dev/null || \
    fail "Pinned kubectl checksum verification failed: $kubectl_bin"
}

topology_config() {
  if [[ -n ${OPENSTACK_CLUSTER_CONFIG:-} ]]; then
    printf '%s\n' "$OPENSTACK_CLUSTER_CONFIG"
  elif [[ -f $repo_dir/inventory/openstack-cluster.local.yml ]]; then
    printf '%s\n' "$repo_dir/inventory/openstack-cluster.local.yml"
  else
    printf '%s\n' "$repo_dir/inventory/openstack-cluster.yml"
  fi
}

require_platform_plan() {
  local config
  config=$(topology_config)
  [[ -f $config ]] || fail "Topology file is missing: $config"
  python3 "$renderer" --config "$config" --validate-only >/dev/null
  [[ -f $plan_file ]] || fail 'Rendered cluster plan is missing; run scripts/cluster.sh render.'
  [[ -f $ceph_plan_file ]] || fail 'Rendered Ceph plan is missing; run scripts/cluster.sh render.'
  [[ -f $generated_globals ]] || fail 'Rendered Kolla globals are missing; run scripts/cluster.sh render.'

  python3 - \
    "$plan_file" \
    "$ceph_plan_file" \
    "$config" \
    "$generated_globals" \
    "$repo_dir/kolla/globals.yml" <<'PY'
import json
import sys
from pathlib import Path

plan_path, ceph_plan_path, config_path, globals_path, base_globals_path = map(Path, sys.argv[1:])
plan = json.loads(plan_path.read_text())
ceph_plan = json.loads(ceph_plan_path.read_text())

expected = config_path.resolve()
recorded = Path(plan.get("config", ""))
if not recorded.is_absolute():
    recorded = (Path.cwd() / recorded).resolve()
else:
    recorded = recorded.resolve()
if recorded != expected:
    raise SystemExit(
        f"ERROR: rendered plan uses {recorded}, not {expected}; run scripts/cluster.sh render"
    )
ceph_recorded = Path(ceph_plan.get("config", ""))
if not ceph_recorded.is_absolute():
    ceph_recorded = (Path.cwd() / ceph_recorded).resolve()
else:
    ceph_recorded = ceph_recorded.resolve()
if ceph_recorded != expected:
    raise SystemExit(
        f"ERROR: rendered Ceph plan uses {ceph_recorded}, not {expected}; "
        "run scripts/cluster.sh render"
    )

newest_input = max(config_path.stat().st_mtime, base_globals_path.stat().st_mtime)
if plan_path.stat().st_mtime < newest_input or globals_path.stat().st_mtime < newest_input:
    raise SystemExit("ERROR: rendered topology is stale; run scripts/cluster.sh render")
if ceph_plan_path.stat().st_mtime < max(newest_input, plan_path.stat().st_mtime):
    raise SystemExit("ERROR: rendered Ceph plan is stale; run scripts/cluster.sh render")

if plan.get("node_count", 0) < 3:
    raise SystemExit("ERROR: Magnum CAPI requires at least three enabled physical nodes")
if plan.get("storage_backend") != "ceph":
    raise SystemExit("ERROR: Magnum CAPI requires storage_backend=ceph")

platform = plan.get("platform")
if not isinstance(platform, dict):
    raise SystemExit("ERROR: rendered plan has no platform mapping")
magnum = platform.get("magnum_capi", {})
containers = platform.get("container_service", {})
if magnum.get("enabled") is not True:
    raise SystemExit("ERROR: set cluster.platform.magnum_capi.enabled=true and rerender")
if containers.get("enabled") is True and containers.get("provider") != "kubernetes":
    raise SystemExit("ERROR: cluster.platform.container_service.provider must be kubernetes")
PY
}

require_ovn_octavia_plan() {
  python3 - "$generated_globals" <<'PY'
import sys
from pathlib import Path

import yaml

values = yaml.safe_load(Path(sys.argv[1]).read_text()) or {}
expected = {
    "neutron_plugin_agent": "ovn",
    "enable_octavia": "yes",
    "enable_magnum": "yes",
    "enable_barbican": "yes",
    "octavia_provider_drivers": "ovn:OVN provider",
    "octavia_provider_agents": "ovn",
    "octavia_auto_configure": "no",
}
for key, wanted in expected.items():
    actual = values.get(key)
    if str(actual).lower() != wanted.lower():
        raise SystemExit(f"ERROR: rendered Kolla globals require {key}={wanted!r}; got {actual!r}")
if "amphora" in str(values.get("octavia_provider_drivers", "")).lower():
    raise SystemExit("ERROR: Amphora must not be enabled in octavia_provider_drivers")
PY
}

kube() {
  [[ -n $kubectl_bin ]] || select_kubectl
  "$kubectl_bin" --kubeconfig "$management_kubeconfig" "$@"
}

require_management_cluster() {
  select_kubectl
  [[ -r $management_kubeconfig ]] || \
    fail "Management Kubernetes kubeconfig is missing or unreadable: $management_kubeconfig"

  local nodes_json storage_json
  nodes_json=$(kube get nodes -o json)
  python3 -c '
import json, sys
data = json.load(sys.stdin)
ready = []
control = []
for node in data.get("items", []):
    conditions = node.get("status", {}).get("conditions", [])
    is_ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)
    if not is_ready:
        continue
    ready.append(node["metadata"]["name"])
    labels = node.get("metadata", {}).get("labels", {})
    if "node-role.kubernetes.io/control-plane" in labels or "node-role.kubernetes.io/master" in labels:
        control.append(node["metadata"]["name"])
if len(ready) < 3:
    raise SystemExit(f"ERROR: management Kubernetes needs at least 3 Ready nodes; found {len(ready)}")
if len(control) < 3:
    raise SystemExit(f"ERROR: management Kubernetes needs at least 3 Ready control-plane nodes; found {len(control)}")
print(f"Management Kubernetes: {len(ready)} Ready nodes, {len(control)} Ready control-plane nodes")
' <<<"$nodes_json"

  storage_json=$(kube get storageclass -o json)
  python3 -c '
import json, sys
data = json.load(sys.stdin)
defaults = []
for item in data.get("items", []):
    annotations = item.get("metadata", {}).get("annotations", {})
    if annotations.get("storageclass.kubernetes.io/is-default-class") == "true" or annotations.get("storageclass.beta.kubernetes.io/is-default-class") == "true":
        defaults.append(item)
if len(defaults) != 1:
    raise SystemExit(f"ERROR: management Kubernetes must have exactly one default StorageClass; found {len(defaults)}")
storage_class = defaults[0]
name = storage_class.get("metadata", {}).get("name", "")
provisioner = storage_class.get("provisioner", "").lower()
blocked = ("local", "hostpath", "no-provisioner")
if not provisioner or any(value in provisioner for value in blocked):
    raise SystemExit(f"ERROR: default StorageClass {name!r} is local or has no dynamic provisioner: {provisioner!r}")
print(f"Default StorageClass: {name} ({provisioner})")
' <<<"$storage_json"
}

require_management_ha_plan() {
  [[ -f $desired_nodes ]] || \
    fail "Rendered Kubespray desired state is missing: $desired_nodes"
  [[ -f $terraform_state ]] || \
    fail "Terraform state is missing: $terraform_state"
  python3 - "$desired_nodes" "$plan_file" "$terraform_state" <<'PY'
import hashlib
import ipaddress
import json
import re
import sys
from pathlib import Path

desired = json.loads(Path(sys.argv[1]).read_text())
plan = json.loads(Path(sys.argv[2]).read_text())
state_path = Path(sys.argv[3])
provenance = desired.get("provenance", {})
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
if provenance.get("terraform_state_sha256") != digest(state_path):
    raise SystemExit(
        "ERROR: Kubespray desired state does not match current Terraform state; "
        "run scripts/render-openstack-kubespray-inventory.sh"
    )
if provenance.get("cluster_plan_sha256") != digest(Path(sys.argv[2])):
    raise SystemExit(
        "ERROR: Kubespray desired state does not match the rendered cluster plan; "
        "rerender the Kubespray inventory"
    )
if desired.get("platform_enabled") is not True:
    raise SystemExit("ERROR: Kubespray desired state does not enable the managed platform")
management_api = str(desired.get("management_api", ""))
try:
    ipaddress.ip_address(management_api)
except ValueError as exc:
    raise SystemExit(f"ERROR: invalid management API address: {exc}")
if management_api != str(plan.get("api_vip", "")):
    raise SystemExit(
        "ERROR: management Kubernetes HA endpoint must equal the OpenStack API VIP"
    )
nodes = desired.get("nodes", {})
controls = {
    name for name, values in nodes.items()
    if "control_plane" in values.get("roles", [])
}
etcd = {
    name for name, values in nodes.items()
    if "etcd" in values.get("roles", [])
}
if len(controls) < 3 or len(etcd) < 3:
    raise SystemExit(
        f"ERROR: management HA requires at least 3 control-plane and 3 etcd nodes; "
        f"found {len(controls)} and {len(etcd)}"
    )
if controls != etcd:
    raise SystemExit("ERROR: management control-plane and etcd membership must match")
addresses = []
for name in sorted(controls):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        raise SystemExit(f"ERROR: unsafe management node name: {name!r}")
    address = str(nodes[name].get("floating_ip", ""))
    try:
        ipaddress.ip_address(address)
    except ValueError as exc:
        raise SystemExit(f"ERROR: invalid management address for {name}: {exc}")
    addresses.append(address)
if len(addresses) != len(set(addresses)):
    raise SystemExit("ERROR: management control-plane addresses must be unique")
print(
    f"Management HA endpoint: {management_api}:6443 -> "
    f"{len(controls)} control-plane nodes"
)
PY
}

default_storage_class() {
  kube get storageclass -o json | python3 -c '
import json, sys
for item in json.load(sys.stdin).get("items", []):
    annotations = item.get("metadata", {}).get("annotations", {})
    if annotations.get("storageclass.kubernetes.io/is-default-class") == "true" or annotations.get("storageclass.beta.kubernetes.io/is-default-class") == "true":
        print(item["metadata"]["name"])
        break
'
}

require_ceph_cluster() {
  require_root
  require_command cephadm
  [[ -n ${CEPH_IMAGE:-} ]] || fail 'CEPH_IMAGE must be pinned in config/versions.env.'

  local health_json tree_json pool_class rule_name rule_json rule_id pools_json
  health_json=$(cephadm --image "$CEPH_IMAGE" shell -- ceph health --format json)
  python3 -c '
import json, sys
status = json.load(sys.stdin).get("status")
if status != "HEALTH_OK":
    raise SystemExit(f"ERROR: Ceph health must be HEALTH_OK; got {status!r}")
print("Ceph health: HEALTH_OK")
' <<<"$health_json"

  tree_json=$(cephadm --image "$CEPH_IMAGE" shell -- ceph osd tree --format json)
  pool_class=$(python3 - "$ceph_plan_file" <<'PY'
import json, sys
value = json.load(open(sys.argv[1])).get("openstack_pool_device_class")
if value not in {"hdd", "ssd", "nvme"}:
    raise SystemExit("ERROR: rendered Ceph plan has no valid OpenStack pool device class")
print(value)
PY
  )
  python3 -c '
import json, sys
nodes = json.load(sys.stdin).get("nodes", [])
device_class = sys.argv[1]
up_osds = {
    node.get("id") for node in nodes
    if node.get("type") == "osd"
    and node.get("status") == "up"
    and float(node.get("reweight", 0)) > 0
    and float(node.get("crush_weight", 0)) > 0
    and node.get("device_class") == device_class
}
hosts = {
    node.get("name")
    for node in nodes
    if node.get("type") == "host" and up_osds.intersection(node.get("children", []))
}
if len(hosts) < 3:
    raise SystemExit(
        f"ERROR: Ceph class {device_class} needs up/in OSDs on at least 3 hosts; "
        f"found {len(hosts)}"
    )
print(f"Ceph {device_class} OSD hosts: {len(hosts)}")
' "$pool_class" <<<"$tree_json"

  rule_name="openstack-${pool_class}-host"
  rule_json=$(cephadm --image "$CEPH_IMAGE" shell -- \
    ceph osd crush rule dump "$rule_name" --format json)
  rule_id=$(python3 -c '
import json, sys
rule = json.load(sys.stdin)
device_class = sys.argv[1]
steps = rule.get("steps", [])
take = next((step for step in steps if step.get("op") == "take"), {})
choose = next((step for step in steps if str(step.get("op", "")).startswith("chooseleaf")), {})
if not str(take.get("item_name", "")).endswith("~" + device_class):
    raise SystemExit("ERROR: OpenStack CRUSH rule selects the wrong device class")
if choose.get("type") != "host":
    raise SystemExit("ERROR: OpenStack CRUSH rule must use host failure domain")
print(rule["rule_id"])
' "$pool_class" <<<"$rule_json")
  pools_json=$(cephadm --image "$CEPH_IMAGE" shell -- \
    ceph osd pool ls detail --format json)
  python3 -c '
import json, sys
rows = {row.get("pool_name"): row for row in json.load(sys.stdin)}
rule_id = int(sys.argv[1])
for name in ("images", "volumes", "vms"):
    row = rows.get(name)
    if row is None:
        raise SystemExit(f"ERROR: required Ceph pool is missing: {name}")
    if row.get("size") != 3 or row.get("min_size") != 2:
        raise SystemExit(
            f"ERROR: Ceph pool {name} must use size=3 and min_size=2"
        )
    if row.get("crush_rule") != rule_id:
        raise SystemExit(
            f"ERROR: Ceph pool {name} does not use CRUSH rule ID {rule_id}"
        )
print("Ceph OpenStack pools: images, volumes and vms verified")
' "$rule_id" <<<"$pools_json"
}

strict_preflight() {
  require_versions
  require_platform_plan
  require_ovn_octavia_plan
  require_ceph_cluster
  require_management_cluster
  require_management_ha_plan
  printf 'Pinned providers: clusterctl=%s CAPI=%s CAPO=%s ORC=%s\n' \
    "$CLUSTERCTL_VERSION" "$CAPI_VERSION" "$CAPO_VERSION" "$ORC_VERSION"
}

render_management_api_proxy() {
  local staging
  mkdir -p "$(dirname -- "$generated_haproxy_config")"
  staging="${generated_haproxy_config}.partial.$$"
  python3 - "$desired_nodes" "$staging" <<'PY'
import ipaddress
import json
import re
import sys
from pathlib import Path

desired = json.loads(Path(sys.argv[1]).read_text())
management_api = str(desired["management_api"])
ipaddress.ip_address(management_api)
servers = []
for name, values in sorted(
    desired["nodes"].items(),
    key=lambda item: (item[1]["inventory_order"], item[0]),
):
    if "control_plane" not in values.get("roles", []):
        continue
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        raise SystemExit(f"ERROR: unsafe HAProxy server name: {name!r}")
    address = str(values["floating_ip"])
    ipaddress.ip_address(address)
    servers.append(
        f"    server {name} {address}:6443 check inter 5s rise 2 fall 3"
    )
if len(servers) < 3:
    raise SystemExit("ERROR: HAProxy management API needs at least three backends")
lines = [
    "# Generated by scripts/platform-services.sh; do not edit.",
    "listen kubernetes_management_api",
    f"    bind {management_api}:6443",
    "    mode tcp",
    "    option tcp-check",
    "    balance roundrobin",
    "    timeout client 1h",
    "    timeout server 1h",
    *servers,
    "",
]
Path(sys.argv[2]).write_text("\n".join(lines))
PY
  chmod 0640 "$staging"
  mv -f "$staging" "$generated_haproxy_config"
  printf 'Management API HAProxy config: %s\n' "$generated_haproxy_config"
}

require_confirmation() {
  local action=$1 expected
  expected="${action}-MAGNUM-CAPI:${CLUSTERCTL_VERSION}:${CAPI_VERSION}:${CAPO_VERSION}:${ORC_VERSION}"
  [[ ${PLATFORM_SERVICES_CONFIRM:-} == "$expected" ]] || \
    fail "Set PLATFORM_SERVICES_CONFIRM='$expected' after reviewing the plan."
}

clusterctl_binary() {
  local architecture download_arch target staging expected_sha
  architecture=$(uname -m)
  case "$architecture" in
    x86_64)
      download_arch=amd64
      expected_sha=$CLUSTERCTL_LINUX_AMD64_SHA256
      ;;
    aarch64|arm64)
      download_arch=arm64
      expected_sha=$CLUSTERCTL_LINUX_ARM64_SHA256
      ;;
    *) fail "Unsupported architecture for clusterctl: $architecture" ;;
  esac
  target="$platform_cache/bin/clusterctl-${CLUSTERCTL_VERSION}-${download_arch}"
  if [[ ! -x $target ]]; then
    require_command curl
    mkdir -p "$platform_cache/bin"
    staging="${target}.partial.$$"
    curl -fL \
      "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-linux-${download_arch}" \
      -o "$staging"
    chmod 0755 "$staging"
    mv -f "$staging" "$target"
  fi
  printf '%s  %s\n' "$expected_sha" "$target" | sha256sum -c - >/dev/null
  "$target" version >/dev/null
  printf '%s\n' "$target"
}

install_orc() {
  local manifest staging
  manifest="$platform_cache/orc-${ORC_VERSION}-install.yml"
  if [[ ! -f $manifest ]]; then
    require_command curl
    mkdir -p "$platform_cache"
    staging="${manifest}.partial.$$"
    curl -fL \
      "https://github.com/k-orc/openstack-resource-controller/releases/download/${ORC_VERSION}/install.yaml" \
      -o "$staging"
    mv -f "$staging" "$manifest"
  fi
  printf '%s  %s\n' "$ORC_INSTALL_SHA256" "$manifest" | sha256sum -c - >/dev/null
  kube apply --server-side -f "$manifest"
  kube wait --for=condition=Established --timeout=180s crd/servers.openstack.k-orc.cloud
  kube wait --for=condition=Established --timeout=180s crd/images.openstack.k-orc.cloud
  kube wait --for=condition=Available --timeout=300s \
    deployment/orc-controller-manager -n orc-system
  kube label --overwrite crd/servers.openstack.k-orc.cloud clusterctl.cluster.x-k8s.io/move=''
  kube label --overwrite crd/images.openstack.k-orc.cloud clusterctl.cluster.x-k8s.io/move=''
}

install_capi_providers() {
  local binary
  binary=$(clusterctl_binary)
  mkdir -p "$platform_cache/xdg"
  KUBECONFIG="$management_kubeconfig" XDG_CONFIG_HOME="$platform_cache/xdg" \
    "$binary" init \
      --core "cluster-api:$CAPI_VERSION" \
      --bootstrap "kubeadm:$CAPI_VERSION" \
      --control-plane "kubeadm:$CAPI_VERSION" \
      --infrastructure "openstack:$CAPO_VERSION"

  kube wait --for=condition=Available --timeout=300s \
    deployment/capi-controller-manager -n capi-system
  kube wait --for=condition=Available --timeout=300s \
    deployment/capi-kubeadm-bootstrap-controller-manager -n capi-kubeadm-bootstrap-system
  kube wait --for=condition=Available --timeout=300s \
    deployment/capi-kubeadm-control-plane-controller-manager -n capi-kubeadm-control-plane-system
  kube wait --for=condition=Available --timeout=300s \
    deployment/capo-controller-manager -n capo-system
}

write_magnum_kubeconfig() (
  kube apply -f "$service_account_manifest"

  local secret_file cluster_file attempt staging
  secret_file=
  cluster_file=
  staging=
  trap 'rm -f -- "${secret_file:-}" "${cluster_file:-}" "${staging:-}"' EXIT
  umask 077
  mkdir -p "$platform_cache" "$(dirname -- "$generated_magnum_kubeconfig")"
  # Remove credential-bearing cache files written by earlier repository versions.
  rm -f -- \
    "$platform_cache/magnum-token-secret.json" \
    "$platform_cache/management-cluster.json"
  secret_file=$(mktemp "$platform_cache/magnum-token-secret.XXXXXX")
  cluster_file=$(mktemp "$platform_cache/management-cluster.XXXXXX")
  for (( attempt=1; attempt<=30; attempt++ )); do
    kube get secret magnum-capi-token -n magnum-system -o json >"$secret_file"
    if python3 - "$secret_file" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1])).get("data", {})
raise SystemExit(0 if data.get("token") and data.get("ca.crt") else 1)
PY
    then
      break
    fi
    sleep 1
  done
  python3 - "$secret_file" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1])).get("data", {})
if not data.get("token") or not data.get("ca.crt"):
    raise SystemExit("ERROR: timed out waiting for the Magnum ServiceAccount token Secret")
PY

  kube config view --raw --minify -o json >"$cluster_file"
  staging=$(mktemp "$(dirname -- "$generated_magnum_kubeconfig")/.magnum-kubeconfig.XXXXXX")
  python3 - "$secret_file" "$cluster_file" "$desired_nodes" "$staging" <<'PY'
import base64
import json
import sys
from pathlib import Path

import yaml

secret = json.loads(Path(sys.argv[1]).read_text())["data"]
cluster = json.loads(Path(sys.argv[2]).read_text())
desired = json.loads(Path(sys.argv[3]).read_text())
if not cluster.get("clusters"):
    raise SystemExit("ERROR: management kubeconfig has no cluster")
server = f"https://{desired['management_api']}:6443"
token = base64.b64decode(secret["token"], validate=True).decode()
ca_data = secret["ca.crt"]
output = {
    "apiVersion": "v1",
    "kind": "Config",
    "clusters": [
        {
            "name": "magnum-management",
            "cluster": {
                "server": server,
                "certificate-authority-data": ca_data,
            },
        }
    ],
    "users": [{"name": "magnum-capi", "user": {"token": token}}],
    "contexts": [
        {
            "name": "magnum-capi@magnum-management",
            "context": {"cluster": "magnum-management", "user": "magnum-capi"},
        }
    ],
    "current-context": "magnum-capi@magnum-management",
}
Path(sys.argv[4]).write_text(yaml.safe_dump(output, sort_keys=False))
PY
  chmod 0600 "$staging"
  mv -f "$staging" "$generated_magnum_kubeconfig"
  staging=
  printf 'Magnum kubeconfig: %s\n' "$generated_magnum_kubeconfig"
)

verify_openstack_services() {
  local openstack_bin magnum_conf octavia_conf
  openstack_bin="$repo_dir/.cache/kolla-venv/bin/openstack"
  [[ -x $openstack_bin ]] || fail 'OpenStack CLI is missing; run scripts/openstack.sh setup.'
  [[ -f /etc/kolla/clouds.yaml ]] || fail '/etc/kolla/clouds.yaml is missing.'
  magnum_conf=/etc/kolla/magnum-conductor/magnum.conf
  octavia_conf=/etc/kolla/octavia-api/octavia.conf
  [[ -f $magnum_conf ]] || fail "Rendered Magnum configuration is missing: $magnum_conf"
  [[ -f $octavia_conf ]] || fail "Rendered Octavia configuration is missing: $octavia_conf"
  if grep -Eiq '^disabled_drivers[[:space:]]*=.*k8s_cluster_api' "$magnum_conf"; then
    fail 'Kolla left the Magnum Cluster API drivers disabled.'
  fi
  grep -Eiq "^[[:space:]]*enabled_provider_drivers[[:space:]]*=[[:space:]]*['\"]?ovn:OVN provider['\"]?[[:space:]]*$" \
    "$octavia_conf" || \
    fail 'Rendered Octavia configuration does not contain the OVN-only provider.'

  OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=admin \
    "$openstack_bin" endpoint list -f json | python3 -c '
import json, sys
rows = json.load(sys.stdin)
types = {str(row.get("Service Type", row.get("Type", ""))) for row in rows}
missing = {"container-infra", "load-balancer"} - types
if missing:
    raise SystemExit("ERROR: missing OpenStack service endpoints: " + ", ".join(sorted(missing)))
'
  OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml OS_CLOUD=admin \
    "$openstack_bin" loadbalancer provider list -f json | python3 -c '
import json, sys
rows = json.load(sys.stdin)
providers = {str(row.get("name", row.get("Name", ""))).lower() for row in rows}
if "ovn" not in providers:
    raise SystemExit(f"ERROR: Octavia OVN provider is not registered; found {sorted(providers)}")
'
}

verify_capi_status() {
  local reference deployment_reference expected_version namespace name resource_json
  local deployments=(
    "capi-system/capi-controller-manager|$CAPI_VERSION"
    "capi-kubeadm-bootstrap-system/capi-kubeadm-bootstrap-controller-manager|$CAPI_VERSION"
    "capi-kubeadm-control-plane-system/capi-kubeadm-control-plane-controller-manager|$CAPI_VERSION"
    "capo-system/capo-controller-manager|$CAPO_VERSION"
    "orc-system/orc-controller-manager|$ORC_VERSION"
  )
  local crds=(
    'clusters.cluster.x-k8s.io'
    'kubeadmconfigs.bootstrap.cluster.x-k8s.io'
    'kubeadmcontrolplanes.controlplane.cluster.x-k8s.io'
    'openstackclusters.infrastructure.cluster.x-k8s.io'
    'servers.openstack.k-orc.cloud'
    'images.openstack.k-orc.cloud'
  )

  for reference in "${deployments[@]}"; do
    deployment_reference=${reference%%|*}
    expected_version=${reference#*|}
    namespace=${deployment_reference%%/*}
    name=${deployment_reference#*/}
    resource_json=$(kube get deployment "$name" -n "$namespace" -o json)
    python3 -c '
import json, sys
deployment = json.load(sys.stdin)
expected_version = sys.argv[1]
metadata = deployment.get("metadata", {})
spec = deployment.get("spec", {})
status = deployment.get("status", {})
desired = spec.get("replicas", 1)
available = status.get("availableReplicas", 0)
deployment_name = metadata.get("name")
images = [container.get("image", "") for container in spec.get("template", {}).get("spec", {}).get("containers", [])]
tags = [image.rsplit(":", 1)[-1] for image in images if "@" not in image and ":" in image]
if expected_version not in tags:
    raise SystemExit(
        f"ERROR: deployment {deployment_name} does not use pinned version {expected_version}; "
        f"images={images}"
    )
if status.get("observedGeneration", 0) < metadata.get("generation", 0) or available < desired:
    raise SystemExit(
        f"ERROR: deployment {deployment_name} is not Available "
        f"({available}/{desired})"
    )
print(f"Deployment {deployment_name}: Available {available}/{desired}, version {expected_version}")
' "$expected_version" <<<"$resource_json"
  done

  for name in "${crds[@]}"; do
    kube get crd "$name" -o name
  done
}

verify_magnum_credentials() {
  local secret_json
  kube get serviceaccount magnum-capi -n magnum-system -o name
  secret_json=$(kube get secret magnum-capi-token -n magnum-system -o json)
  python3 -c '
import json, sys
secret = json.load(sys.stdin)
data = secret.get("data", {})
if secret.get("type") != "kubernetes.io/service-account-token":
    raise SystemExit("ERROR: magnum-capi-token is not a ServiceAccount token Secret")
if not data.get("token") or not data.get("ca.crt"):
    raise SystemExit("ERROR: magnum-capi-token has no token or CA data")
print("Magnum ServiceAccount token: populated")
' <<<"$secret_json"

  [[ -f $generated_magnum_kubeconfig ]] || \
    fail "Generated Magnum kubeconfig is missing: $generated_magnum_kubeconfig"
  [[ $(stat -c '%a' "$generated_magnum_kubeconfig") == 600 ]] || \
    fail 'The generated Magnum management kubeconfig must have mode 0600.'
  printf 'Generated Magnum kubeconfig: present (0600)\n'
}

verify_installed_magnum_kubeconfig() {
  [[ -f $installed_magnum_kubeconfig ]] || \
    fail 'Kolla did not install the Magnum management kubeconfig.'
  [[ $(stat -c '%a' "$installed_magnum_kubeconfig") == 600 ]] || \
    fail 'The installed Magnum management kubeconfig must have mode 0600.'
  cmp -s "$generated_magnum_kubeconfig" "$installed_magnum_kubeconfig" || \
    fail 'The installed Magnum kubeconfig differs from the reviewed generated file; run platform-reconfigure.'
  printf 'Installed Magnum kubeconfig: current and mode 0600\n'
}

verify_management_api_proxy() {
  local installed_config address response backend_output
  local -a backend_addresses
  installed_config=/etc/kolla/config/haproxy/services.d/kubernetes-management-api.cfg
  [[ -f $installed_config ]] || \
    fail 'Kolla management Kubernetes HAProxy configuration is missing.'
  if ! backend_output=$(python3 - "$desired_nodes" "$installed_config" <<'PY'
import ipaddress
import json
import re
import sys
from pathlib import Path

desired = json.loads(Path(sys.argv[1]).read_text())
management_api = str(desired["management_api"])
if ipaddress.ip_address(management_api).version != 4:
    raise SystemExit("ERROR: management HAProxy bind must use an IPv4 address")
servers = []
addresses = []
for name, values in sorted(
    desired["nodes"].items(),
    key=lambda item: (item[1]["inventory_order"], item[0]),
):
    if "control_plane" not in values.get("roles", []):
        continue
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        raise SystemExit(f"ERROR: unsafe HAProxy server name: {name!r}")
    address = str(values["floating_ip"])
    if ipaddress.ip_address(address).version != 4:
        raise SystemExit("ERROR: management HAProxy backends must use IPv4 addresses")
    addresses.append(address)
    servers.append(
        f"    server {name} {address}:6443 check inter 5s rise 2 fall 3"
    )
if len(servers) < 3:
    raise SystemExit("ERROR: management HAProxy needs at least three backends")
expected = "\n".join([
    "# Generated by scripts/platform-services.sh; do not edit.",
    "listen kubernetes_management_api",
    f"    bind {management_api}:6443",
    "    mode tcp",
    "    option tcp-check",
    "    balance roundrobin",
    "    timeout client 1h",
    "    timeout server 1h",
    *servers,
    "",
])
actual = Path(sys.argv[2]).read_text()
if actual != expected:
    raise SystemExit(
        "ERROR: installed management HAProxy configuration differs from the "
        "reviewed desired node set; run platform-reconfigure"
    )
for address in addresses:
    print(address)
PY
  ); then
    fail 'Installed management HAProxy configuration validation failed.'
  fi
  mapfile -t backend_addresses <<<"$backend_output"
  (( ${#backend_addresses[@]} >= 3 )) || \
    fail 'Installed management HAProxy configuration has fewer than three backends.'
  verify_installed_magnum_kubeconfig
  [[ -n $kubectl_bin ]] || select_kubectl
  for address in "${backend_addresses[@]}"; do
    response=$("$kubectl_bin" \
      --kubeconfig "$management_kubeconfig" \
      --server="https://${address}:6443" \
      --request-timeout=15s \
      get --raw=/readyz)
    [[ $response == ok ]] || \
      fail "Management Kubernetes backend ${address}:6443 did not return readyz=ok."
  done
  response=$("$kubectl_bin" \
    --kubeconfig "$installed_magnum_kubeconfig" \
    --request-timeout=15s \
    get --raw=/readyz)
  [[ $response == ok ]] || \
    fail 'Management Kubernetes HA endpoint did not return readyz=ok.'
  printf 'Management Kubernetes HA endpoint: ready with %s healthy backends\n' \
    "${#backend_addresses[@]}"
}

platform_status() {
  require_root
  require_versions
  require_platform_plan
  require_ovn_octavia_plan
  require_management_ha_plan
  select_kubectl
  [[ -r $management_kubeconfig ]] || \
    fail "Management Kubernetes kubeconfig is missing or unreadable: $management_kubeconfig"
  verify_capi_status
  verify_magnum_credentials
  verify_management_api_proxy
  verify_openstack_services
  printf 'Magnum CAPI, CAPO, ORC and Octavia OVN status checks passed.\n'
}

apply_platform() {
  local action=$1 kolla_action=$2
  strict_preflight
  require_confirmation "$action"
  install_orc
  install_capi_providers
  verify_capi_status
  render_management_api_proxy
  write_magnum_kubeconfig
  verify_magnum_credentials
  "$repo_dir/scripts/openstack.sh" "$kolla_action" --inventory "$repo_dir/kolla/generated/multinode"
  verify_management_api_proxy
  verify_openstack_services
}

render_hosted_scaffold() {
  strict_preflight
  python3 - "$plan_file" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1]))
if plan["platform"]["magnum_capi"].get("hosted_control_plane") is not True:
    raise SystemExit(
        "ERROR: set cluster.platform.magnum_capi.hosted_control_plane=true and rerender"
    )
PY
  [[ -n ${HOSTED_K0S_VERSION:-} ]] || \
    fail 'Set HOSTED_K0S_VERSION to the reviewed k0s Kubernetes version for the scaffold.'

  local namespace cluster_name storage_class output staging
  namespace=${HOSTED_NAMESPACE:-hosted-clusters}
  cluster_name=${HOSTED_CLUSTER_NAME:-example-hosted}
  storage_class=$(default_storage_class)
  output="$platform_cache/k0smotron-${cluster_name}.yml"
  staging="${output}.partial.$$"
  mkdir -p "$platform_cache"
  python3 - "$hosted_template" "$staging" \
    "$namespace" "$cluster_name" "$HOSTED_K0S_VERSION" "$storage_class" "$K0SMOTRON_VERSION" <<'PY'
import sys
from pathlib import Path

source, output, namespace, name, k0s_version, storage_class, k0smotron_version = sys.argv[1:]
text = Path(source).read_text()
replacements = {
    "@@NAMESPACE@@": namespace,
    "@@CLUSTER_NAME@@": name,
    "@@K0S_VERSION@@": k0s_version,
    "@@STORAGE_CLASS@@": storage_class,
    "@@K0SMOTRON_VERSION@@": k0smotron_version,
}
for token, value in replacements.items():
    if not value or any(character in value for character in "\n\r\0"):
        raise SystemExit(f"ERROR: unsafe or empty scaffold value for {token}")
    text = text.replace(token, value)
Path(output).write_text(text)
PY
  mv -f "$staging" "$output"
  printf 'Future-only hosted control-plane scaffold: %s\n' "$output"
  printf 'No K0smotron provider or hosted control plane was applied.\n'
}

case "$command_name" in
  help)
    cat <<'HELP'
Usage: scripts/platform-services.sh COMMAND

  preflight                    verify 3+ physical nodes, Ceph, management K8s and OVN config
  plan                         run preflight and print exact apply/reconfigure confirmations
  status                       read and verify deployed CAPI, Magnum and OpenStack state
  apply                        install pinned CAPI providers and deploy Magnum/Octavia
  reconfigure                  reconcile CAPI providers and reconfigure Magnum/Octavia
  hosted-control-plane-plan    render a future-only K0smotron scaffold; never applies it

Set MANAGEMENT_KUBECONFIG when the management cluster kubeconfig is not
kubeconfig/admin.conf. apply and reconfigure require sudo and the exact
PLATFORM_SERVICES_CONFIRM value printed by plan. No command removes resources.
HELP
    ;;
  preflight)
    strict_preflight
    ;;
  plan)
    strict_preflight
    printf 'Apply confirmation: APPLY-MAGNUM-CAPI:%s:%s:%s:%s\n' \
      "$CLUSTERCTL_VERSION" "$CAPI_VERSION" "$CAPO_VERSION" "$ORC_VERSION"
    printf 'Reconfigure confirmation: RECONFIGURE-MAGNUM-CAPI:%s:%s:%s:%s\n' \
      "$CLUSTERCTL_VERSION" "$CAPI_VERSION" "$CAPO_VERSION" "$ORC_VERSION"
    ;;
  status)
    platform_status
    ;;
  apply)
    apply_platform APPLY deploy
    ;;
  reconfigure)
    apply_platform RECONFIGURE reconfigure
    ;;
  hosted-control-plane-plan)
    render_hosted_scaffold
    ;;
  *)
    fail "Unknown command: $command_name"
    ;;
esac
