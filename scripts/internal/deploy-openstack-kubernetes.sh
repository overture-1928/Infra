#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
runtime_dir="$repo_dir/.cache/kubespray-inventory/openstack"
state_dir="$repo_dir/state/kubespray/openstack"

"$repo_dir/scripts/internal/setup-kubespray.sh"

sample_dir="$repo_dir/.cache/kubespray/inventory/sample"
mkdir -p "$runtime_dir/group_vars"
cp -a "$sample_dir/group_vars/." "$runtime_dir/group_vars/"
cp -a "$repo_dir/kubespray/openstack/group_vars/." "$runtime_dir/group_vars/"
"$repo_dir/scripts/internal/render-openstack-kubespray-inventory.sh"

ansible_playbook="$repo_dir/.cache/kubespray-venv/bin/ansible-playbook"
inventory="$runtime_dir/hosts.yml"
desired="$runtime_dir/desired-nodes.json"
applied="$state_dir/applied-nodes.json"
legacy_applied="$runtime_dir/applied-nodes.json"
scale_plan="$runtime_dir/scale-plan.json"
management_cloud_env="$repo_dir/kubeconfig/openstack-management.env"
export ANSIBLE_CONFIG="$repo_dir/.cache/kubespray/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="$repo_dir/.cache/ansible-local"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
install -d -m 0700 "$state_dir"
if [[ ! -f $applied && -f $legacy_applied ]]; then
  install -m 0600 "$legacy_applied" "$applied"
fi

if [[ $(jq -r '.platform_enabled // false' "$desired") == true ]]; then
  [[ -r $management_cloud_env ]] || {
    echo "Management Kubernetes needs its OpenStack application credential: $management_cloud_env" >&2
    echo 'Run scripts/internal/management-kubernetes-cloud.sh create-credential first.' >&2
    exit 1
  }
  [[ $(stat -c '%a' "$management_cloud_env") == 600 ]] || {
    echo "Credential file must have mode 0600: $management_cloud_env" >&2
    exit 1
  }
  set -a
  # Generated locally by management-kubernetes-cloud.sh and stored in an ignored directory.
  source "$management_cloud_env"
  set +a
  for required_name in \
    OS_AUTH_URL \
    OS_APPLICATION_CREDENTIAL_ID \
    OS_APPLICATION_CREDENTIAL_NAME \
    OS_APPLICATION_CREDENTIAL_SECRET \
    OS_REGION_NAME; do
    [[ -n ${!required_name:-} ]] || {
      echo "Missing $required_name in $management_cloud_env" >&2
      exit 1
    }
  done
fi

DESIRED="$desired" APPLIED="$applied" SCALE_PLAN="$scale_plan" \
MANAGEMENT_KUBECONFIG="$repo_dir/kubeconfig/admin.conf" python3 - <<'PY'
import json
import os
from pathlib import Path

desired = json.loads(Path(os.environ["DESIRED"]).read_text())
applied_path = Path(os.environ["APPLIED"])
if not applied_path.exists():
    if Path(os.environ["MANAGEMENT_KUBECONFIG"]).exists():
        raise SystemExit(
            "applied-nodes.json is missing while a management kubeconfig exists; "
            "restore the applied topology backup before scaling"
        )
    controls = sorted(
        name for name, values in desired["nodes"].items()
        if set(values["roles"]) & {"control_plane", "etcd"}
    )
    plan = {
        "action": "initial-control" if len(controls) > 1 else "initial",
        "new_nodes": sorted(desired["nodes"]),
        "control_changes": controls if len(controls) > 1 else [],
    }
else:
    applied = json.loads(applied_path.read_text())
    old_nodes = applied["nodes"]
    new_nodes = desired["nodes"]
    removed = sorted(set(old_nodes) - set(new_nodes))
    if removed:
        raise SystemExit(f"automatic node removal is blocked: {', '.join(removed)}")
    role_removals = []
    control_changes = []
    additions = []
    for name, old in old_nodes.items():
        removed_roles = set(old["roles"]) - set(new_nodes[name]["roles"])
        if removed_roles:
            role_removals.append(f"{name}:{','.join(sorted(removed_roles))}")
        added_roles = set(new_nodes[name]["roles"]) - set(old["roles"])
        if added_roles & {"control_plane", "etcd"}:
            control_changes.append(name)
    if role_removals:
        raise SystemExit(f"automatic role removal is blocked: {'; '.join(role_removals)}")
    additions = sorted(set(new_nodes) - set(old_nodes))
    control_changes.extend(
        name for name in additions
        if set(new_nodes[name]["roles"]) & {"control_plane", "etcd"}
    )
    if control_changes:
        action = "control"
    elif additions:
        action = "workers"
    else:
        action = "reconcile"
    plan = {
        "action": action,
        "new_nodes": additions,
        "control_changes": sorted(set(control_changes)),
    }
Path(os.environ["SCALE_PLAN"]).write_text(json.dumps(plan, indent=2) + "\n")
PY

action=$(jq -r .action "$scale_plan")
new_nodes=$(jq -r '.new_nodes | join(",")' "$scale_plan")
control_changes=$(jq -r '.control_changes | join(",")' "$scale_plan")

if [[ $action == control || $action == initial-control ]]; then
  expected="SCALE-KUBERNETES-CONTROL:${control_changes}"
  [[ ${KUBERNETES_CONTROL_PLANE_SCALE_CONFIRM:-} == "$expected" ]] || {
    echo "Control-plane/etcd expansion needs a reviewed staged run." >&2
    echo "Set KUBERNETES_CONTROL_PLANE_SCALE_CONFIRM='$expected' and rerun." >&2
    exit 1
  }
fi

prepare_args=(-i "$inventory" "$repo_dir/ansible/playbooks/prepare-openstack-kubernetes.yml")
[[ -z $new_nodes ]] || prepare_args+=(--limit "$new_nodes")
"$ansible_playbook" "${prepare_args[@]}"

case "$action" in
  workers)
    "$ansible_playbook" -i "$inventory" "$repo_dir/.cache/kubespray/scale.yml" -b --limit "$new_nodes"
    ;;
  initial|initial-control|control|reconcile)
    "$ansible_playbook" -i "$inventory" "$repo_dir/.cache/kubespray/cluster.yml" -b
    ;;
esac

[[ -f $runtime_dir/artifacts/admin.conf ]] || {
  echo 'Kubespray did not export artifacts/admin.conf.' >&2
  exit 1
}
mkdir -p "$repo_dir/kubeconfig"
install -m 0600 "$runtime_dir/artifacts/admin.conf" "$repo_dir/kubeconfig/admin.conf"
bootstrap_api=$(jq -r .bootstrap_api "$desired")
KUBECONFIG_FILE="$repo_dir/kubeconfig/admin.conf" KUBERNETES_API_IP="$bootstrap_api" \
  "$repo_dir/.cache/kubespray-venv/bin/python" - <<'PY'
import os
from pathlib import Path
import yaml

path = Path(os.environ["KUBECONFIG_FILE"])
data = yaml.safe_load(path.read_text())
data["clusters"][0]["cluster"]["server"] = f"https://{os.environ['KUBERNETES_API_IP']}:6443"
path.write_text(yaml.safe_dump(data, sort_keys=False))
PY
install -m 0600 "$desired" "$applied"
echo "Kubernetes action: $action"
echo "Kubernetes kubeconfig: $repo_dir/kubeconfig/admin.conf"
