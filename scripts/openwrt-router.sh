#!/usr/bin/env bash
set -euo pipefail

umask 077

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
openwrt_inventory=${OPENWRT_INVENTORY:-$repo_dir/inventory/openwrt-router.local.yml}
openwrt_cache="$repo_dir/.cache/openwrt"
openwrt_plan="$openwrt_cache/plan.json"
openwrt_discovery="$openwrt_cache/discovery.json"
openwrt_attempt_file="$openwrt_cache/apply-attempt"
openstack_plan=${OPENSTACK_PLAN_CONFIG:-}
if [[ -z $openstack_plan ]]; then
  if [[ -f $repo_dir/inventory/openstack-plan.local.yml ]]; then
    openstack_plan="$repo_dir/inventory/openstack-plan.local.yml"
  else
    openstack_plan="$repo_dir/inventory/openstack-plan.yml"
  fi
fi
cluster_config=${OPENSTACK_CLUSTER_CONFIG:-}
cluster_inventory="$repo_dir/.cache/cluster/ansible-inventory.yml"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

select_cluster_config() {
  if [[ -n $cluster_config ]]; then
    return
  fi
  if [[ -f $repo_dir/inventory/openstack-cluster.local.yml ]]; then
    cluster_config="$repo_dir/inventory/openstack-cluster.local.yml"
  else
    cluster_config="$repo_dir/inventory/openstack-cluster.yml"
  fi
}

find_ansible_playbook() {
  if [[ -x $repo_dir/.cache/kolla-venv/bin/ansible-playbook ]]; then
    printf '%s\n' "$repo_dir/.cache/kolla-venv/bin/ansible-playbook"
    return
  fi
  command -v ansible-playbook || fail 'Run scripts/cluster.sh setup or install ansible-core first.'
}

require_inventory() {
  [[ -f $openwrt_inventory ]] || fail \
    "Create $openwrt_inventory from inventory/openwrt-router.example.yml first."
}

require_plan() {
  [[ -f $openwrt_plan ]] || fail 'Run scripts/cluster.sh openwrt-plan first.'
}

openwrt_playbook() {
  local executable
  executable=$(find_ansible_playbook)
  ANSIBLE_CONFIG="$repo_dir/ansible/ansible.cfg" \
  ANSIBLE_LOCAL_TEMP=/tmp/openstack-openwrt-ansible \
    "$executable" -i "$openwrt_inventory" "$@"
}

cluster_playbook() {
  local executable
  executable=$(find_ansible_playbook)
  ANSIBLE_CONFIG="$repo_dir/ansible/ansible.cfg" \
  ANSIBLE_LOCAL_TEMP=/tmp/openstack-openwrt-ansible \
    "$executable" -i "$cluster_inventory" "$@"
}

discover_router() {
  require_inventory
  mkdir -p "$openwrt_cache"
  openwrt_playbook "$repo_dir/ansible/playbooks/discover-openwrt.yml"
  printf 'OpenWrt discovery: %s\n' "$openwrt_discovery"
}

render_plan() {
  select_cluster_config
  "$repo_dir/scripts/render-openwrt-plan.py" \
    --inventory "$openwrt_inventory" \
    --discovery "$openwrt_discovery" \
    --openstack-plan "$openstack_plan" \
    --cluster-config "$cluster_config" \
    --output-dir "$openwrt_cache"
  python3 - "$openwrt_plan" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1]))
print("Confirm only after the automatic router and provider probes pass:")
print(f"  OPENWRT_CONFIRM='{plan['confirmations']['confirm']}'")
print("Manual rollback while the guard is armed:")
print(f"  OPENWRT_ROLLBACK_CONFIRM='{plan['confirmations']['rollback']}'")
PY
}

prepare_plan() {
  discover_router
  render_plan
}

require_apply_confirmations() {
  python3 - \
    "$openwrt_plan" \
    "${OPENWRT_APPLY_CONFIRM:-}" \
    "${OPENWRT_CONFIRM:-}" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1]))
provided_apply, provided_confirm = sys.argv[2:]
expected_apply = plan["confirmations"]["apply"]
expected_confirm = plan["confirmations"]["confirm"]
if provided_apply != expected_apply:
    raise SystemExit(
        "ERROR: OPENWRT_APPLY_CONFIRM does not match the freshly rendered plan.\n"
        f"Expected: {expected_apply}"
    )
if provided_confirm != expected_confirm:
    raise SystemExit(
        "ERROR: OPENWRT_CONFIRM does not match the freshly rendered plan.\n"
        f"Expected: {expected_confirm}"
    )
PY
}

guarded_failure() {
  printf '%s\n' \
    'ERROR: OpenWrt verification did not complete. If the change was committed, the rollback guard remains armed.' \
    'Do not remove power; wait for the configured rollback deadline, or use openwrt-rollback while SSH is reachable.' >&2
  exit 1
}

acquire_controller_apply_lock() {
  mkdir -p "$openwrt_cache"
  command -v flock >/dev/null 2>&1 || fail 'flock is required for guarded OpenWrt apply.'
  exec 9>"$openwrt_cache/controller-apply.lock"
  flock -n 9 || fail 'Another OpenWrt apply is already running from this repository.'
}

cleanup_previous_prearm_attempt() {
  local previous_attempt
  [[ -s $openwrt_attempt_file ]] || return 0
  require_plan
  previous_attempt=$(cat "$openwrt_attempt_file")
  [[ $previous_attempt =~ ^[0-9a-f]{32}$ ]] || fail 'The saved OpenWrt apply attempt ID is invalid.'
  export OPENWRT_APPLY_ATTEMPT=$previous_attempt
  openwrt_playbook "$repo_dir/ansible/playbooks/cleanup-openwrt-prearm.yml" || fail \
    'The previous apply is still active or guarded; inspect openwrt-status or run the exact rollback.'
  rm -f "$openwrt_attempt_file"
}

begin_apply_attempt() {
  OPENWRT_APPLY_ATTEMPT=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  export OPENWRT_APPLY_ATTEMPT
  printf '%s\n' "$OPENWRT_APPLY_ATTEMPT" >"$openwrt_attempt_file"
  chmod 0600 "$openwrt_attempt_file"
}

apply_router() {
  acquire_controller_apply_lock
  cleanup_previous_prearm_attempt
  prepare_plan
  require_apply_confirmations
  begin_apply_attempt

  if ! openwrt_playbook "$repo_dir/ansible/playbooks/apply-openwrt.yml"; then
    if openwrt_playbook "$repo_dir/ansible/playbooks/cleanup-openwrt-prearm.yml"; then
      rm -f "$openwrt_attempt_file"
    fi
    guarded_failure
  fi
  openwrt_playbook "$repo_dir/ansible/playbooks/verify-openwrt.yml" || guarded_failure

  select_cluster_config
  "$repo_dir/scripts/render-openstack-cluster.py" --config "$cluster_config" >/dev/null || guarded_failure
  cluster_playbook \
    "$repo_dir/ansible/playbooks/probe-openstack-provider.yml" || guarded_failure

  openwrt_playbook "$repo_dir/ansible/playbooks/confirm-openwrt.yml" || guarded_failure
  rm -f "$openwrt_attempt_file"
  printf '%s\n' \
    'OpenWrt VLAN 10 routing was applied and confirmed after every enabled OpenStack node was verified.'
}

command_name=${1:-help}
case "$command_name" in
  help)
    cat <<'HELP'
Usage: scripts/openwrt-router.sh COMMAND

  discover  collect nonsecret board, DSA, firewall and network facts
  plan      rediscover and render a reviewed UCI plan without changing the router
  apply     rediscover, apply with rollback guard, probe from OpenStack hosts, confirm
  status    verify the last plan against the router without changing it
  rollback  trigger the still-armed transaction using its exact confirmation

Set OPENWRT_INVENTORY to override inventory/openwrt-router.local.yml.
Set OPENSTACK_CLUSTER_CONFIG to override inventory/openstack-cluster.local.yml.
Set OPENSTACK_PLAN_CONFIG to override inventory/openstack-plan.local.yml.
HELP
    ;;
  discover)
    discover_router
    ;;
  plan)
    prepare_plan
    ;;
  apply)
    apply_router
    ;;
  status)
    require_inventory
    require_plan
    openwrt_playbook \
      -e openwrt_require_guard_armed=false \
      "$repo_dir/ansible/playbooks/verify-openwrt.yml"
    ;;
  rollback)
    require_inventory
    require_plan
    openwrt_playbook "$repo_dir/ansible/playbooks/rollback-openwrt.yml"
    ;;
  *)
    fail "Unknown command: $command_name"
    ;;
esac
