#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/config/versions.env"
renderer="$repo_dir/scripts/internal/render-openstack-cluster.py"
cluster_cache="$repo_dir/.cache/cluster"
ansible_inventory="$cluster_cache/ansible-inventory.yml"
kolla_inventory="$repo_dir/kolla/generated/multinode"
kolla_venv="$repo_dir/.cache/kolla-venv"
terraform_bin="$repo_dir/.cache/terraform/bin/terraform"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

render_topology() {
  "$renderer"
}

require_kolla() {
  [[ -x $kolla_venv/bin/kolla-ansible ]] || fail 'Run scripts/cluster.sh setup first.'
}

require_terraform() {
  [[ -x $terraform_bin ]] || fail 'Run scripts/cluster.sh setup to install the pinned Terraform CLI.'
  local actual
  actual=$(
    "$terraform_bin" version -json 2>/dev/null |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || true
  )
  [[ $actual == "$TERRAFORM_CLI_VERSION" ]] || \
    fail "Expected Terraform $TERRAFORM_CLI_VERSION at $terraform_bin; found ${actual:-unknown}."
}

prepare_terraform() {
  require_terraform
  export OS_CLIENT_CONFIG_FILE=${OS_CLIENT_CONFIG_FILE:-/etc/kolla/clouds.yaml}
  [[ -r $OS_CLIENT_CONFIG_FILE ]] || \
    fail "OpenStack cloud configuration is not readable: $OS_CLIENT_CONFIG_FILE"
  mkdir -p "$cluster_cache"
  "$terraform_bin" -chdir="$repo_dir/terraform/openstack" \
    init -input=false -lockfile=readonly
}

render_all() {
  render_topology
  require_kolla
  "$repo_dir/scripts/internal/render-kolla-multinode.sh"
}

require_initial_three_node_ceph() {
  local node_count backend
  node_count=$(plan_value node_count)
  backend=$(plan_value storage_backend)
  (( node_count >= 3 )) || fail 'Initial OpenStack deployment requires at least three enabled physical nodes.'
  [[ $backend == ceph ]] || fail 'Initial OpenStack deployment requires the Ceph storage backend.'
}

ansible_playbook() {
  local executable
  if [[ -x $kolla_venv/bin/ansible-playbook ]]; then
    executable="$kolla_venv/bin/ansible-playbook"
  else
    executable=$(command -v ansible-playbook || true)
  fi
  [[ -n $executable ]] || fail 'Install ansible-core or run scripts/cluster.sh setup.'
  ANSIBLE_CONFIG="$repo_dir/ansible/ansible.cfg" \
  ANSIBLE_LOCAL_TEMP=/tmp/openstack-cluster-ansible \
    "$executable" -i "$ansible_inventory" "$@"
}

reject_generic_managed_deploy() {
  local operation=$1
  if [[ $(plan_value platform.magnum_capi.enabled) == True ]]; then
    if [[ $operation == expand ]]; then
      fail 'Physical host expansion after Magnum/CAPI activation is not automated; add hosts before enabling the managed platform or use a separately reviewed Kolla expansion workflow.'
    fi
    fail 'Managed platform profile is enabled; use platform-apply or platform-reconfigure so CAPI and the Magnum kubeconfig are prepared first.'
  fi
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Run this command through sudo.'
}

plan_value() {
  local expression=$1
  python3 - "$cluster_cache/cluster-plan.json" "$expression" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
value = data
for key in sys.argv[2].split('.'):
    value = value[key]
if isinstance(value, list):
    print(",".join(value))
elif isinstance(value, dict):
    print(",".join(sorted(value)))
else:
    print(value)
PY
}

verify_hosts() {
  render_all
  ansible_playbook "$repo_dir/ansible/playbooks/openstack/verify-openstack-hosts.yml"
}

deploy_openstack() {
  require_root
  render_all
  require_initial_three_node_ceph
  reject_generic_managed_deploy initial
  ansible_playbook "$repo_dir/ansible/playbooks/openstack/verify-openstack-hosts.yml"
  "$repo_dir/scripts/openstack.sh" bootstrap --inventory "$kolla_inventory"
  "$repo_dir/scripts/openstack.sh" gather-facts --inventory "$kolla_inventory"
  "$repo_dir/scripts/openstack.sh" deploy --inventory "$kolla_inventory"
  "$repo_dir/scripts/openstack.sh" validate-config --inventory "$kolla_inventory"
  "$repo_dir/scripts/openstack.sh" check --inventory "$kolla_inventory"
}

command_name=${1:-help}
case "$command_name" in
  help)
    cat <<'HELP'
Usage: scripts/cluster.sh COMMAND [ARGUMENTS]

  validate             validate the authoritative node topology
  setup                install pinned Kolla/Terraform tooling, preserve passwords, render inventories
  render               regenerate Ansible and Kolla inventories
  prepare-hosts        configure every enabled Ubuntu host; reboot them afterwards
  verify-hosts         verify hostnames, management/Ceph NICs, time and Docker storage
  openwrt-discover     collect read-only OpenWrt hardware and network facts
  openwrt-plan         render the OpenWrt VLAN 10 UCI plan without changing it
  openwrt-apply        apply, probe and confirm OpenWrt with an automatic rollback guard
  openwrt-status       verify the last confirmed OpenWrt plan
  openwrt-rollback     manually trigger a still-armed OpenWrt rollback transaction
  deploy-openstack     deploy a fresh three-node-or-larger Ceph-backed cloud (root)
  expand-openstack     back up DB and add hosts after the initial three-node cloud (root, confirmation)
  verify-openstack     verify APIs and registered OpenStack services
  terraform-plan       create a reviewed Kubernetes infrastructure plan
  terraform-apply      apply that saved plan serially (confirmation)
  workload-new STACK   create an isolated Terraform workload stack from the template
  workload-plan STACK  save a reviewable plan for one workload stack
  workload-show STACK  show a saved workload plan and its SHA-256 confirmation
  workload-apply STACK apply the exact saved workload plan serially (confirmation)
  workload-output STACK show outputs from one workload stack's state
  deploy-kubernetes    install or scale Kubernetes through Kubespray
  prepare-k8s-cloud    create a dedicated non-admin management-cloud credential
  platform-plan        verify the 3-node/Ceph management-service prerequisites (root)
  platform-apply       install CAPI/CAPO/ORC and deploy Magnum/Octavia (root, confirmation)
  platform-reconfigure reconcile the pinned platform providers and Kolla services (root)
  platform-status      verify deployed CAPI, Magnum, Octavia and OVN state (root)
  hosted-plan          render a future-only K0smotron hosted-control-plane scaffold

Do not deploy until cloud01-cloud03 and their dedicated Ceph devices are ready.
Future compute/OSD expansion remains a separate reviewed workflow.
HELP
    ;;
  validate)
    "$renderer" --validate-only
    ;;
  setup)
    "$repo_dir/scripts/openstack.sh" setup
    "$repo_dir/scripts/internal/setup-terraform.sh"
    ;;
  render)
    render_all
    ;;
  prepare-hosts)
    render_all
    ansible_playbook "$repo_dir/ansible/playbooks/openstack/prepare-openstack-host.yml"
    echo 'Host preparation completed. Reboot changed hosts, then run verify-hosts.'
    ;;
  verify-hosts)
    verify_hosts
    ;;
  openwrt-discover)
    "$repo_dir/scripts/internal/openwrt-router.sh" discover
    ;;
  openwrt-plan)
    "$repo_dir/scripts/internal/openwrt-router.sh" plan
    ;;
  openwrt-apply)
    "$repo_dir/scripts/internal/openwrt-router.sh" apply
    ;;
  openwrt-status)
    "$repo_dir/scripts/internal/openwrt-router.sh" status
    ;;
  openwrt-rollback)
    "$repo_dir/scripts/internal/openwrt-router.sh" rollback
    ;;
  deploy-openstack)
    deploy_openstack
    ;;
  expand-openstack)
    require_root
    render_all
    reject_generic_managed_deploy expand
    node_count=$(plan_value node_count)
    (( node_count >= 4 )) || fail 'Expansion is only for adding hosts after the initial three-node deployment.'
    enabled_hosts=$(plan_value nodes)
    expected="EXPAND-OPENSTACK:${enabled_hosts}"
    [[ ${OPENSTACK_EXPAND_CONFIRM:-} == "$expected" ]] || \
      fail "Set OPENSTACK_EXPAND_CONFIRM='$expected' after reviewing the rendered inventories."
    ansible_playbook "$repo_dir/ansible/playbooks/openstack/verify-openstack-hosts.yml"
    "$repo_dir/scripts/openstack.sh" backup --inventory "$kolla_inventory"
    "$repo_dir/scripts/openstack.sh" gather-facts --inventory "$kolla_inventory"
    "$repo_dir/scripts/openstack.sh" bootstrap --inventory "$kolla_inventory"
    "$repo_dir/scripts/openstack.sh" deploy --inventory "$kolla_inventory"
    "$repo_dir/scripts/openstack.sh" validate-config --inventory "$kolla_inventory"
    "$repo_dir/scripts/openstack.sh" check --inventory "$kolla_inventory"
    "$repo_dir/scripts/internal/verify-openstack-cluster.sh"
    ;;
  verify-openstack)
    require_root
    "$repo_dir/scripts/internal/verify-openstack-cluster.sh"
    ;;
  terraform-plan)
    prepare_terraform
    "$terraform_bin" -chdir="$repo_dir/terraform/openstack" \
      plan -input=false -out="$cluster_cache/kubernetes.tfplan"
    ;;
  terraform-apply)
    [[ ${TERRAFORM_APPLY_CONFIRM:-} == APPLY-KUBERNETES-INFRA ]] || \
      fail 'Set TERRAFORM_APPLY_CONFIRM=APPLY-KUBERNETES-INFRA after reviewing terraform-plan.'
    [[ -f $cluster_cache/kubernetes.tfplan ]] || fail 'Run terraform-plan first.'
    prepare_terraform
    "$terraform_bin" -chdir="$repo_dir/terraform/openstack" \
      apply -input=false -parallelism=1 "$cluster_cache/kubernetes.tfplan"
    ;;
  workload-new)
    "$repo_dir/scripts/internal/terraform-workload.sh" new "${@:2}"
    ;;
  workload-plan)
    "$repo_dir/scripts/internal/terraform-workload.sh" plan "${@:2}"
    ;;
  workload-show)
    "$repo_dir/scripts/internal/terraform-workload.sh" show "${@:2}"
    ;;
  workload-apply)
    "$repo_dir/scripts/internal/terraform-workload.sh" apply "${@:2}"
    ;;
  workload-output)
    "$repo_dir/scripts/internal/terraform-workload.sh" output "${@:2}"
    ;;
  deploy-kubernetes)
    "$repo_dir/scripts/internal/deploy-openstack-kubernetes.sh"
    ;;
  prepare-k8s-cloud)
    "$repo_dir/scripts/internal/management-kubernetes-cloud.sh" create-credential
    ;;
  platform-plan)
    "$repo_dir/scripts/internal/platform-services.sh" plan
    ;;
  platform-apply)
    "$repo_dir/scripts/internal/platform-services.sh" apply
    ;;
  platform-reconfigure)
    "$repo_dir/scripts/internal/platform-services.sh" reconfigure
    ;;
  platform-status)
    "$repo_dir/scripts/internal/platform-services.sh" status
    ;;
  hosted-plan)
    "$repo_dir/scripts/internal/platform-services.sh" hosted-control-plane-plan
    ;;
  *)
    fail "Unknown command: $command_name"
    ;;
esac
