#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/config/versions.env"
command_name=${1:-help}
[[ $# -eq 0 ]] || shift
venv_dir="$repo_dir/.cache/kolla-venv"
generated_dir="$repo_dir/kolla/generated"
inventory="$generated_dir/multinode"
limit=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory)
      [[ $# -ge 2 ]] || { echo 'ERROR: --inventory requires a path.' >&2; exit 2; }
      inventory=$2
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { echo 'ERROR: --limit requires a host or group pattern.' >&2; exit 2; }
      limit=$2
      shift 2
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

ansible_tmp=/tmp/openstack-kolla-ansible
export ANSIBLE_LOCAL_TEMP="$ansible_tmp"
export ANSIBLE_COLLECTIONS_PATH="$repo_dir/.cache/ansible-collections"
export PATH="$venv_dir/bin:$PATH"
mkdir -p "$ansible_tmp"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

find_kolla_share() {
  find -L "$venv_dir" -type d -path '*/share/kolla-ansible' -print -quit
}

require_inventory() {
  [[ -f $inventory ]] || fail "Kolla inventory is missing: $inventory. Run setup or render first."
}

run_kolla() {
  local action=$1
  shift
  require_inventory
  local args=("$venv_dir/bin/kolla-ansible" "$action" -i "$inventory")
  [[ -z $limit ]] || args+=(--limit "$limit")
  args+=("$@")
  "${args[@]}"
}

render() {
  [[ -x $venv_dir/bin/python ]] || fail 'Run scripts/openstack.sh setup first.'
  "$repo_dir/scripts/render-openstack-cluster.py"
  "$repo_dir/scripts/render-kolla-multinode.sh"
}

setup() {
  command -v python3 >/dev/null || fail 'python3 is required.'
  command -v git >/dev/null || fail 'git is required.'
  [[ -x $venv_dir/bin/python ]] || python3 -m venv "$venv_dir"
  mkdir -p "$ANSIBLE_COLLECTIONS_PATH"
  "$venv_dir/bin/pip" install --disable-pip-version-check \
    "ansible-core>=2.20,<2.22" \
    "kolla-ansible==$KOLLA_ANSIBLE_VERSION" \
    "python-openstackclient" \
    "python-cinderclient" \
    "python-magnumclient" \
    "python-octaviaclient"
  deps_marker="$ANSIBLE_COLLECTIONS_PATH/.kolla-deps-$KOLLA_ANSIBLE_VERSION"
  if [[ ! -f $deps_marker ]]; then
    "$venv_dir/bin/kolla-ansible" install-deps
    touch "$deps_marker"
  fi

  kolla_share=$(find_kolla_share)
  [[ -n $kolla_share ]] || fail 'Could not locate the installed Kolla-Ansible share directory.'
  mkdir -p "$generated_dir"
  if [[ ! -f $generated_dir/passwords.yml ]]; then
    cp "$kolla_share/etc_examples/kolla/passwords.yml" "$generated_dir/passwords.yml"
    "$venv_dir/bin/kolla-genpwd" -p "$generated_dir/passwords.yml"
    chmod 0600 "$generated_dir/passwords.yml"
  fi
  render
  echo "Kolla-Ansible $KOLLA_ANSIBLE_VERSION is ready."
  echo "Stable inventory: $generated_dir/multinode"
  echo "Generated secrets: $generated_dir/passwords.yml"
}

storage_backend() {
  python3 - "$repo_dir/.cache/cluster/cluster-plan.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit("missing rendered cluster plan; run render first")
print(json.loads(path.read_text())["storage_backend"])
PY
}

api_vip() {
  python3 - "$repo_dir/.cache/cluster/cluster-plan.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit("missing rendered cluster plan; run render first")
print(json.loads(path.read_text())["api_vip"])
PY
}

install_config() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Run deployment operations through sudo.'
  require_inventory
  [[ -f $generated_dir/passwords.yml && -f $generated_dir/globals.yml ]] || \
    fail 'Run scripts/openstack.sh setup as the operator user first.'
  install -d -m 0750 /etc/kolla /etc/kolla/config
  install -m 0640 "$generated_dir/globals.yml" /etc/kolla/globals.yml
  install -m 0600 "$generated_dir/passwords.yml" /etc/kolla/passwords.yml
  cp -a "$repo_dir/kolla/config/." /etc/kolla/config/
  rm -f /etc/kolla/config/nova/nova-compute.conf.example

  magnum_kubeconfig="$generated_dir/magnum/kubeconfig"
  if [[ -f $magnum_kubeconfig ]]; then
    install -d -m 0750 /etc/kolla/config/magnum
    install -m 0600 "$magnum_kubeconfig" /etc/kolla/config/magnum/kubeconfig
  fi

  haproxy_services="$generated_dir/haproxy/services.d"
  if [[ -d $haproxy_services ]]; then
    install -d -m 0750 /etc/kolla/config/haproxy/services.d
    find "$haproxy_services" -maxdepth 1 -type f -name '*.cfg' -exec \
      install -m 0640 {} /etc/kolla/config/haproxy/services.d/ \;
  fi

  if [[ $(storage_backend) == ceph ]]; then
    ceph_config="$generated_dir/ceph-config"
    [[ -d $ceph_config ]] || fail 'Ceph client configuration is missing; run scripts/ceph-cluster.sh export-kolla.'
    cp -a "$ceph_config/." /etc/kolla/config/
  fi
}

require_local_storage() {
  [[ $(storage_backend) != lvm ]] || {
    findmnt -n /var/lib/docker >/dev/null || fail '/var/lib/docker is not a separate mounted filesystem.'
    vgs cinder-ssd >/dev/null 2>&1 || fail 'VG cinder-ssd is missing.'
  }
}

case "$command_name" in
  help)
    cat <<'HELP'
Usage: scripts/openstack.sh COMMAND [--inventory PATH] [--limit PATTERN]

  setup            install pinned Kolla-Ansible, retain passwords, and render inventory
  render           validate topology and regenerate Ansible/Kolla inputs
  bootstrap        prepare target hosts for Kolla containers (root; may restart Docker)
  gather-facts     refresh facts before a limited expansion (root)
  prechecks        run Kolla deployment prechecks (root)
  pull             pull images to selected hosts (root)
  deploy           deploy new services/hosts and write clouds.yaml (root)
  reconfigure      apply reviewed Kolla configuration changes (root)
  validate-config  validate rendered service configuration after deployment (root)
  backup           take a full MariaDB backup before controller expansion (root)
  cloud-init       upload the Ubuntu 24.04 cloud image (root)
  check            check deployed container services (root)

The stable inventory key is cloud01 for both one-node and multinode operation.
The script intentionally has no destroy command.
HELP
    ;;
  setup)
    setup
    ;;
  render)
    render
    ;;
  bootstrap)
    install_config
    require_local_storage
    run_kolla bootstrap-servers
    ;;
  gather-facts)
    install_config
    run_kolla gather-facts
    ;;
  prechecks)
    install_config
    require_local_storage
    run_kolla prechecks
    ;;
  pull)
    install_config
    run_kolla pull
    ;;
  deploy)
    install_config
    require_local_storage
    run_kolla prechecks
    run_kolla pull
    run_kolla deploy
    run_kolla post-deploy
    echo "OpenStack deployed. Skyline is served at http://$(api_vip):9999."
    ;;
  reconfigure)
    install_config
    run_kolla prechecks
    run_kolla reconfigure
    ;;
  validate-config)
    install_config
    run_kolla validate-config
    ;;
  backup)
    install_config
    run_kolla mariadb-backup --full
    ;;
  cloud-init)
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Run cloud-init through sudo.'
    [[ -f /etc/kolla/clouds.yaml ]] || fail '/etc/kolla/clouds.yaml is missing; deploy OpenStack first.'
    image_dir="$repo_dir/.cache/openstack-images"
    image_file="$image_dir/ubuntu-24.04-noble-amd64.img"
    mkdir -p "$image_dir"
    [[ -f $image_file ]] || curl -fL "$UBUNTU_CLOUD_IMAGE_URL" -o "$image_file"
    export OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml
    export OS_CLOUD=admin
    if ! "$venv_dir/bin/openstack" image show ubuntu-24.04 >/dev/null 2>&1; then
      "$venv_dir/bin/openstack" image create ubuntu-24.04 \
        --disk-format qcow2 --container-format bare --private --file "$image_file"
    fi
    "$venv_dir/bin/openstack" image show ubuntu-24.04
    ;;
  check)
    install_config
    run_kolla check
    ;;
  *)
    fail "Unknown command: $command_name"
    ;;
esac
