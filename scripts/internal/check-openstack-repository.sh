#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/openstack-repository-check.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

notice() {
  printf 'NOTICE: %s\n' "$*"
}

find_optional_executable() {
  local name=$1
  local candidate
  candidate=$(command -v "$name" || true)
  if [[ -n $candidate ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in \
    "$repo_dir/.cache/kolla-venv/bin/$name" \
    "$repo_dir/.cache/kubespray-venv/bin/$name"; do
    if [[ -x $candidate ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

mapfile -d '' shell_files < <(find scripts -maxdepth 2 -type f -name '*.sh' -print0 | sort -z)
(( ${#shell_files[@]} > 0 )) || { echo 'No shell scripts found.' >&2; exit 1; }
for file in "${shell_files[@]}"; do
  [[ -x $file ]] || { echo "Script is not executable: $file" >&2; exit 1; }
  bash -n "$file"
done

for pattern in \
  '.terraform/' \
  '*.tfstate' \
  '.terraform.tfstate.lock.info' \
  '*.tfvars.json' \
  'override.tf' \
  '*.local.yml' \
  '*.local.yaml' \
  'inventory/*.local.yml' \
  'inventory/*.local.yaml' \
  'kolla/generated/' \
  'kolla/config/nova/nova-compute.conf' \
  'kolla/config/nova.conf' \
  'kubeconfig/' \
  'clouds.yaml' \
  'secure.yaml' \
  'secure.yml' \
  'secure.json' \
  'terraform/openstack/clouds.yaml' \
  'state/' \
  '.secrets/' \
  'ubuntu-autoinstall/generated/' \
  '*.key' \
  '*.keyring' \
  '*.p8' \
  '*.ppk' \
  '.ssh/' \
  '.docker/' \
  '*.kubeconfig' \
  'admin.conf' \
  '*.iso' \
  '*.img' \
  '*.qcow2' \
  '*.raw' \
  '*.vmdk' \
  '*.vdi'; do
  grep -Fxq "$pattern" .gitignore || {
    echo "Required secret/generated ignore pattern is missing: $pattern" >&2
    exit 1
  }
done

for local_private_file in \
  inventory/openstack-cluster.local.yml \
  inventory/openstack-plan.local.yml \
  inventory/openwrt-router.local.yml \
  terraform/openstack/terraform.tfvars \
  kolla/config/nova/nova-compute.conf \
  kolla/config/nova.conf; do
  [[ ! -e $local_private_file ]] || [[ $(stat -c '%a' "$local_private_file") == 600 ]] || {
    echo "Local private input must use mode 0600: $local_private_file" >&2
    exit 1
  }
done

while IFS= read -r -d '' workload_tfvars; do
  [[ $(stat -c '%a' "$workload_tfvars") == 600 ]] || {
    echo "Local workload input must use mode 0600: $workload_tfvars" >&2
    exit 1
  }
done < <(find terraform/workloads -mindepth 2 -maxdepth 2 -type f -name terraform.tfvars -print0 2>/dev/null)

while IFS= read -r -d '' workload_ansible_settings; do
  [[ $(stat -c '%a' "$workload_ansible_settings") == 600 ]] || {
    echo "Local workload Ansible settings must use mode 0600: $workload_ansible_settings" >&2
    exit 1
  }
done < <(find ansible/inventory/workloads -maxdepth 1 -type f -name '*.local.yml' -print0 2>/dev/null)

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked_ignored=$(git ls-files -ci --exclude-standard)
  [[ -z $tracked_ignored ]] || {
    printf 'Files are both tracked and ignored; remove them from the Git index:\n%s\n' \
      "$tracked_ignored" >&2
    exit 1
  }
fi

mapfile -d '' python_files < <(find scripts -maxdepth 2 -type f -name '*.py' -print0 | sort -z)
(( ${#python_files[@]} > 0 )) || { echo 'No Python scripts found.' >&2; exit 1; }
PYTHONPYCACHEPREFIX="$work_dir/pycache" python3 -m py_compile "${python_files[@]}"

python3 - <<'PY'
import ipaddress
import re
from pathlib import Path

import yaml


yaml_files = []
for root in (Path("inventory"), Path("ansible"), Path("kolla"), Path("kubespray")):
    yaml_files.extend(root.rglob("*.yml"))
    yaml_files.extend(root.rglob("*.yaml"))

for path in sorted(set(yaml_files)):
    if ".cache" in path.parts or ".terraform" in path.parts:
        continue
    documents = list(yaml.safe_load_all(path.read_text()))
    if path.parent.name == "playbooks":
        assert documents and isinstance(documents[0], list), f"{path}: Ansible playbook must be a list"
        for play in documents[0]:
            assert isinstance(play, dict) and "hosts" in play, f"{path}: invalid Ansible play"

for inventory_path in (Path("ansible/inventory/openstack-three-node.yml"),):
    inventory = yaml.safe_load(inventory_path.read_text())
    assert isinstance(inventory, dict) and isinstance(inventory.get("all"), dict), (
        f"{inventory_path}: invalid Ansible inventory root"
    )

autoinstall = Path("ubuntu-autoinstall/user-data.template").read_text()
for token, value in {
    "HOSTNAME": "cloud01",
    "PASSWORD_HASH": "$6$placeholder$hash",
    "SSH_PUBLIC_KEY": "ssh-ed25519 AAAAplaceholder",
    "MANAGEMENT_INTERFACE": "mgmt0",
    "MANAGEMENT_MAC": "02:00:00:00:00:01",
    "MANAGEMENT_ADDRESS": "192.0.2.2/24",
    "MANAGEMENT_GATEWAY": "192.0.2.1",
    "DNS_SERVERS": "          - 192.0.2.1",
    "OS_DISK_SERIAL": "EXAMPLE-OS-SSD-0001",
}.items():
    autoinstall = autoinstall.replace(f"@@{token}@@", value)
assert "@@" not in autoinstall, "unhandled Ubuntu autoinstall template token"
data = yaml.safe_load(autoinstall)
storage_config = data["autoinstall"]["storage"]["config"]
storage_by_id = {item["id"]: item for item in storage_config}
assert storage_by_id["disk-os"]["grub_device"] is True
assert "grub_device" not in storage_by_id["part-bios"]
assert storage_by_id["part-efi"]["grub_device"] is True
late_commands = "\n".join(data["autoinstall"]["late-commands"])
assert "operator ALL=(ALL:ALL) NOPASSWD: ALL" in late_commands
assert "/usr/sbin/visudo -cf /etc/sudoers.d/90-operator-ansible" in late_commands

plan = yaml.safe_load(Path("inventory/openstack-plan.yml").read_text())
untouched = {item["serial"] for item in plan["storage"]["untouched"]}
expected = {
    "EXAMPLE-RESERVED-SSD-0001",
    "EXAMPLE-RESERVED-HDD-0001",
    "EXAMPLE-RESERVED-HDD-0002",
}
assert untouched == expected, "protected disk serial set changed"
public_serials = {
    plan["storage"]["os"]["serial"],
    plan["storage"]["openstack_data"]["serial"],
    plan["storage"]["ceph_osd"]["serial"],
    *untouched,
}
assert plan["storage"]["ceph_osd"]["device_class"] == "nvme"
assert plan["storage"]["ceph_osd"]["min_size_bytes"] >= 1_800_000_000_000
assert all(str(serial).startswith("EXAMPLE-") for serial in public_serials), (
    "the tracked OpenStack plan must contain only public example disk serials"
)
cluster_example = yaml.safe_load(Path("inventory/openstack-cluster.yml").read_text())
cloud01 = cluster_example["nodes"]["cloud01"]
assert cloud01["os_disk_serial"].startswith("EXAMPLE-")
first_octet = int(str(cloud01["management_mac"]).split(":", 1)[0], 16)
assert first_octet & 0x02, "the tracked inventory MAC must be locally administered"
assert ipaddress.ip_address(cluster_example["cluster"]["api_vip"]) in ipaddress.ip_network("192.0.2.0/24")
assert ipaddress.ip_interface(cloud01["management_address"]).network == ipaddress.ip_network("192.0.2.0/24")
ceph_network = ipaddress.ip_network(cluster_example["cluster"]["ceph"]["public_network"])
assert ceph_network == ipaddress.ip_network("192.168.30.0/24")
for node in cluster_example["nodes"].values():
    assert ipaddress.ip_address(node["ceph_address"]) in ceph_network
assert ipaddress.ip_network(plan["openstack"]["external_cidr"]) == ipaddress.ip_network("198.51.100.0/24")
assert ipaddress.ip_network(plan["openstack"]["tenant_cidr"]) == ipaddress.ip_network("203.0.113.0/24")

public_roots = [Path("README.md"), Path("docs"), Path("inventory"), Path("scripts")]
home_prefix = "/" + "home" + "/"
for root in public_roots:
    paths = [root] if root.is_file() else root.rglob("*")
    for path in paths:
        if not path.is_file() or ".local." in path.name or "__pycache__" in path.parts:
            continue
        text = path.read_text(errors="ignore")
        home_users = re.findall(re.escape(home_prefix) + r"([^/\s`'\"]+)/", text)
        unexpected = sorted(set(home_users) - {"operator"})
        assert not unexpected, f"{path}: public source contains local home paths for {unexpected}"

local_data_doc = Path("docs/operations/local-data-and-recovery.md")
assert local_data_doc.is_file(), "the local secrets and state guide is missing"
readme = Path("README.md").read_text()
assert "docs/operations/local-data-and-recovery.md" in readme, "README does not link the local data guide"
docs_index_path = Path("docs/README.md")
assert docs_index_path.is_file(), "the documentation index is missing"
docs_index = docs_index_path.read_text()
documentation_sections = (
    "getting-started",
    "architecture",
    "operations",
    "workloads",
    "platform",
)
root_markdown = sorted(Path("docs").glob("*.md"))
assert root_markdown == [docs_index_path], "docs root must contain only the main README"
for section_name in documentation_sections:
    section = Path("docs") / section_name
    section_index = section / "README.md"
    assert section_index.is_file(), f"documentation section index is missing: {section_index}"
    assert f"({section_name}/README.md)" in docs_index, f"documentation index omits {section_name}"
    section_text = section_index.read_text()
    for guide in sorted(section.glob("*.md")):
        if guide == section_index:
            continue
        assert f"({guide.name})" in section_text, f"{section_index} omits {guide.name}"

markdown_sources = [
    Path("README.md"),
    Path("scripts/README.md"),
    Path("terraform/README.md"),
    Path("ansible/playbooks/README.md"),
    Path("terraform/workloads/_template/README.md"),
    *sorted(Path("docs").rglob("*.md")),
]
for source in markdown_sources:
    assert source.is_file(), f"missing Markdown source: {source}"
    source_text = source.read_text()
    assert source_text.count("```") % 2 == 0, f"{source}: unbalanced fenced code block"
    for target in re.findall(r"(?<!!)\[[^\]]+\]\(([^)]+)\)", source_text):
        target = target.strip().split(maxsplit=1)[0].strip("<>")
        if not target or target.startswith("#") or re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
            continue
        relative_path = target.split("#", 1)[0]
        resolved = (source.parent / relative_path).resolve()
        assert resolved.exists(), f"{source}: broken relative Markdown link: {target}"

for visual_guide in (
    "docs/README.md",
    "docs/architecture/current-limitations.md",
    "docs/getting-started/installation.md",
    "docs/operations/scenarios.md",
    "docs/operations/backup-and-restore.md",
    "docs/operations/observability.md",
    "docs/operations/failure-drills.md",
    "docs/operations/ceph-day2.md",
    "docs/operations/upgrades.md",
    "docs/operations/security.md",
    "docs/operations/openstack-day2.md",
    "docs/operations/kubernetes-day2.md",
    "docs/workloads/terraform.md",
    "docs/architecture/automation-boundaries.md",
    "docs/workloads/pci-passthrough.md",
):
    assert "```mermaid" in Path(visual_guide).read_text(), f"{visual_guide} needs a Mermaid diagram"

operations_runbook_requirements = {
    "docs/operations/backup-and-restore.md": (
        "openstack.sh backup",
        "mariadb-full.tgz",
        "복원 성공 기준",
    ),
    "docs/operations/observability.md": (
        "enable_prometheus",
        "SMART",
        "점검 주기",
    ),
    "docs/operations/failure-drills.md": (
        "중단 기준",
        "자동 evacuation",
        "합격 기록",
    ),
    "docs/operations/ceph-day2.md": (
        "osd-plan/osd-apply",
        "safe-to-destroy",
        "완료 기준",
    ),
    "docs/operations/upgrades.md": (
        "openstack.sh reconfigure",
        "release upgrade",
        "rollback",
    ),
    "docs/operations/security.md": (
        "운영 PC를 분실한 경우",
        "SSH key 정기 교체",
        "공개 저장소에 secret을 올린 경우",
    ),
    "docs/operations/openstack-day2.md": (
        "VM 생성 또는 scheduling 실패",
        "Network와 Floating IP 진단",
        "Volume 진단",
    ),
    "docs/operations/kubernetes-day2.md": (
        "Node가 NotReady인 경우",
        "PVC가 Pending 또는 attach 실패인 경우",
        "LoadBalancer가 Pending인 경우",
    ),
}
for runbook_name, required_terms in operations_runbook_requirements.items():
    runbook_text = Path(runbook_name).read_text()
    for required_term in required_terms:
        assert required_term in runbook_text, f"{runbook_name} omits {required_term}"

for guide_name in (
    "docs/getting-started/installation.md",
    "docs/architecture/automation-boundaries.md",
):
    guide_text = Path(guide_name).read_text()
    for command in ("workload-inventory", "workload-configure"):
        assert command in guide_text, f"{guide_name} omits {command}"
local_data_text = local_data_doc.read_text()
for required_path in (
    "inventory/openstack-cluster.local.yml",
    "inventory/openstack-plan.local.yml",
    "inventory/openwrt-router.local.yml",
    "terraform/openstack/terraform.tfvars",
    "terraform/workloads/<stack>/terraform.tfvars",
    "ansible/inventory/workloads/<stack>.local.yml",
    "inventory/masakari-fencing.local.yml",
    "kolla/generated/passwords.yml",
    "terraform/openstack/terraform.tfstate*",
    "terraform/workloads/<stack>/terraform.tfstate*",
):
    assert required_path in local_data_text, f"local data guide omits {required_path}"

tfvars_example = Path("terraform/openstack/terraform.tfvars.example").read_text()
for variable in (
    "external_cidr",
    "external_gateway",
    "external_dns",
    "floating_ip_pool",
    "tenant_cidr",
    "tenant_gateway",
    "admin_cidr",
    "management_api_address",
    "kubernetes_nodes",
):
    assert re.search(rf"(?m)^\s*{re.escape(variable)}\s*=", tfvars_example), (
        f"terraform.tfvars.example omits local override {variable}"
    )

platform_services = Path("scripts/internal/platform-services.sh").read_text()
assert 'secret_file="$platform_cache/magnum-token-secret.json"' not in platform_services
assert 'cluster_file="$platform_cache/management-cluster.json"' not in platform_services
assert 'mktemp "$platform_cache/magnum-token-secret.XXXXXX"' in platform_services
assert 'mktemp "$platform_cache/management-cluster.XXXXXX"' in platform_services

openstack_script = Path("scripts/openstack.sh").read_text()
cluster_script = Path("scripts/cluster.sh").read_text()
verify_cluster_script = Path("scripts/internal/verify-openstack-cluster.sh").read_text()
prepare_playbook = Path("ansible/playbooks/openstack/prepare-openstack-host.yml").read_text()
verify_playbook = Path("ansible/playbooks/openstack/verify-openstack-hosts.yml").read_text()
assert yaml.safe_load(Path("inventory/openstack-plan.yml").read_text())["openstack"]["deployment"] == "fresh-three-node-ceph"
assert 'inventory="$generated_dir/multinode"' in openstack_script
assert 'http://$(api_vip):9999' in openstack_script
assert '"python-masakariclient"' in openstack_script
assert '"$openstack_bin" segment list' in verify_cluster_script
assert 'kolla_inventory="$repo_dir/kolla/generated/multinode"' in cluster_script
for path in (Path("scripts/openstack.sh"), Path("scripts/cluster.sh")):
    assert "all-in-one" not in path.read_text(), f"{path}: all-in-one inventory hardcoding returned"
assert "^127\\.0\\.1\\.1\\s+" in prepare_playbook
assert "getent ahostsv4" in verify_playbook
for unit in ("iscsid.service", "iscsid.socket", "open-iscsi.service"):
    assert unit in prepare_playbook and unit in verify_playbook
PY

# Public example hardware identifiers must fail before either destructive disk
# preparation or credential-bearing autoinstall output can be produced.
if OPENSTACK_PLAN_CONFIG="$repo_dir/inventory/openstack-plan.yml" \
  ./scripts/prepare-openstack-storage.sh >"$work_dir/public-storage.out" 2>&1; then
  echo 'Public example storage plan was accepted.' >&2
  exit 1
fi
grep -q 'Replace public example serials' "$work_dir/public-storage.out"

python3 - inventory/openstack-plan.yml "$work_dir/storage-plan.yml" <<'PY'
import sys
from pathlib import Path

import yaml

plan = yaml.safe_load(Path(sys.argv[1]).read_text())
plan["storage"]["os"]["serial"] = "CHECK-OS"
plan["storage"]["openstack_data"]["serial"] = "CHECK-DATA"
plan["storage"]["ceph_osd"]["serial"] = "CHECK-CEPH"
plan["storage"]["untouched"] = [{"serial": "CHECK-PROTECTED"}]
Path(sys.argv[2]).write_text(yaml.safe_dump(plan, sort_keys=False))
PY
mkdir -p "$work_dir/storage-bin"
cat >"$work_dir/storage-bin/lsblk" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-dn -o PATH,SERIAL,TYPE')
    cat <<'OUT'
/dev/sda CHECK-OS disk
/dev/sdb CHECK-DATA disk
/dev/nvme0n1 CHECK-CEPH disk
/dev/sdc CHECK-PROTECTED disk
OUT
    ;;
  '-bdno SIZE /dev/sda') echo 128000000000 ;;
  '-bdno SIZE /dev/sdb') echo 1000000000000 ;;
  '-bdno SIZE /dev/nvme0n1') echo 2000000000000 ;;
  '-sno PATH /dev/mapper/root') echo /dev/mapper/root ;;
  *) echo "unexpected lsblk arguments: $*" >&2; exit 2 ;;
esac
SH
cat >"$work_dir/storage-bin/findmnt" <<'SH'
#!/usr/bin/env bash
[[ $* == '-n -o SOURCE /' ]] || exit 2
echo /dev/mapper/root
SH
cat >"$work_dir/storage-bin/blkid" <<'SH'
#!/usr/bin/env bash
exit 2
SH
chmod +x "$work_dir/storage-bin/lsblk" "$work_dir/storage-bin/findmnt" "$work_dir/storage-bin/blkid"
PATH="$work_dir/storage-bin:$PATH" \
OPENSTACK_PLAN_CONFIG="$work_dir/storage-plan.yml" \
  ./scripts/prepare-openstack-storage.sh >"$work_dir/storage-dry-run.out"
grep -q "OPENSTACK_STORAGE_CONFIRM='WIPE-OPENSTACK-DATA:CHECK-DATA:KEEP-CEPH:CHECK-CEPH'" \
  "$work_dir/storage-dry-run.out"
grep -q 'Initial Ceph OSD, unchanged:' "$work_dir/storage-dry-run.out"

if OPENSTACK_CLUSTER_CONFIG="$repo_dir/inventory/openstack-cluster.yml" \
  UBUNTU_OPERATOR_PASSWORD_HASH='$6$placeholder$hash' \
  UBUNTU_OPERATOR_SSH_PUBLIC_KEY='ssh-ed25519 AAAAplaceholder' \
  ./scripts/render-ubuntu-autoinstall.sh >"$work_dir/public-autoinstall.out" 2>&1; then
  echo 'Public example topology was accepted for autoinstall.' >&2
  exit 1
fi
grep -q 'replace public example value' "$work_dir/public-autoinstall.out"

source config/versions.env
python3 - \
  "$OPENSTACK_SERIES" \
  "$OPENSTACK_TERRAFORM_PROVIDER_VERSION" \
  "$KUBECTL_VERSION" \
  "$TERRAFORM_CLI_VERSION" \
  "$TERRAFORM_LINUX_AMD64_SHA256" \
  "$TERRAFORM_LINUX_ARM64_SHA256" \
  "$CEPHADM_VERSION" \
  "$CEPHADM_SHA256" <<'PY'
import re
import sys
from pathlib import Path

import yaml

(
    series,
    provider,
    kubectl,
    terraform_cli,
    terraform_amd64,
    terraform_arm64,
    cephadm_version,
    cephadm_sha256,
) = sys.argv[1:]
globals_data = yaml.safe_load(Path("kolla/globals.yml").read_text())
assert str(globals_data["openstack_release"]) == series
assert globals_data["enable_horizon"] == "no"
assert globals_data["enable_skyline"] == "yes"
assert globals_data["enable_cinder_backend_lvm"] == "no"
assert globals_data["cinder_backend_ceph"] == "yes"
assert globals_data["glance_backend_ceph"] == "yes"
assert globals_data["nova_backend_ceph"] == "yes"
assert globals_data["enable_masakari"] == "yes"
assert globals_data["enable_masakari_instancemonitor"] == "yes"
assert globals_data["enable_masakari_hostmonitor"] == "no"
masakari_config = Path("kolla/config/masakari.conf").read_text()
assert "evacuate_all_instances = false" in masakari_config
assert "process_all_instances = false" in masakari_config
masakari_doc = Path("docs/operations/masakari.md").read_text()
for required_term in (
    "스마트 플러그",
    "로컬 API",
    "inventory/masakari-fencing.local.yml",
    "fence-status",
    "fence-plan",
    "fence-test",
):
    assert required_term in masakari_doc, f"Masakari guide omits {required_term}"
assert globals_data["cinder_backends"] == []
assert globals_data["cinder_backend_ceph_name"] == "ceph-rbd"
assert globals_data["cinder_cluster_name"] == "ceph-rbd"
assert globals_data["ceph_cinder_pool_name"] == "volumes"
assert globals_data["ceph_glance_pool_name"] == "images"
assert globals_data["ceph_nova_pool_name"] == "vms"
terraform_main = Path("terraform/openstack/main.tf").read_text()
terraform_variables = Path("terraform/openstack/variables.tf").read_text()
assert 'policies = ["soft-anti-affinity"]' in terraform_main
assert 'HA_Enabled      = "True"' in terraform_main
assert 'openstack_blockstorage_volume_type_v3" "standard' not in terraform_main
assert 'openstack_blockstorage_volume_type_v3" "ceph' in terraform_main
assert 'k8s-01' in terraform_variables and 'k8s-02' in terraform_variables and 'k8s-03' in terraform_variables
assert 'volume_type' not in terraform_variables
storage_prepare = Path("scripts/prepare-openstack-storage.sh").read_text()
assert 'sgdisk --zap-all "$data_disk"' in storage_prepare
for forbidden in (
    'sgdisk --zap-all "$ceph_disk"',
    'pvcreate -ff -y "$ceph_disk"',
    'vgcreate "$data_vg" "$ceph_disk"',
):
    assert forbidden not in storage_prepare, f"reserved Ceph disk mutation returned: {forbidden}"
versions = Path("terraform/openstack/versions.tf").read_text()
match = re.search(r'(?m)^\s*version\s*=\s*"([^"]+)"', versions)
assert match and match.group(1) == provider
required = re.search(r'(?m)^\s*required_version\s*=\s*"= ([^"]+)"', versions)
assert required and required.group(1) == terraform_cli
for terraform_versions in (
    Path("terraform/modules/openstack-vm/versions.tf"),
    Path("terraform/workloads/_template/versions.tf"),
):
    text = terraform_versions.read_text()
    match = re.search(r'(?m)^\s*version\s*=\s*"([^"]+)"', text)
    assert match and match.group(1) == provider, terraform_versions
    required = re.search(r'(?m)^\s*required_version\s*=\s*"= ([^"]+)"', text)
    assert required and required.group(1) == terraform_cli, terraform_versions
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", terraform_cli)
assert re.fullmatch(r"[0-9a-f]{64}", terraform_amd64)
assert re.fullmatch(r"[0-9a-f]{64}", terraform_arm64)
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", cephadm_version)
assert re.fullmatch(r"[0-9a-f]{64}", cephadm_sha256)
versions_env = Path("config/versions.env").read_text()
assert f"CEPH_IMAGE='quay.io/ceph/ceph:v{cephadm_version}'" in versions_env
k8s = yaml.safe_load(Path("kubespray/openstack/group_vars/k8s_cluster/zz-openstack.yml").read_text())
assert "v" + str(k8s["kube_version"]) == kubectl
assert k8s["kube_vip_arp_enabled"] is True

cluster_script = Path("scripts/cluster.sh").read_text()
assert 'terraform_bin="$repo_dir/.cache/terraform/bin/terraform"' in cluster_script
assert "init -input=false -lockfile=readonly" in cluster_script
assert "scripts/internal/setup-terraform.sh" in cluster_script
assert "enabled_hosts=$(plan_value nodes)" in cluster_script
assert 'expected="EXPAND-OPENSTACK:${enabled_hosts}"' in cluster_script
assert "Physical host expansion after Magnum/CAPI activation is not automated" in cluster_script
ceph_script = Path("scripts/ceph-cluster.sh").read_text()
assert "require_initial_osd_deployment()" in ceph_script
assert "ceph_cmd osd ls --format json" in ceph_script
assert "incremental OSD expansion is not implemented" in ceph_script
initial_osd_guard = ceph_script.split("require_initial_osd_deployment() {", 1)[1].split("\n}", 1)[0]
assert initial_osd_guard.index("require_cluster") < initial_osd_guard.index("ceph_cmd osd ls --format json")
assert "existing_osd_count == 0" in initial_osd_guard
osd_dry_run = ceph_script.split("osd_dry_run() {", 1)[1].split("\n}", 1)[0]
assert osd_dry_run.index("require_initial_osd_deployment") < osd_dry_run.index("preflight_devices")
ceph_transition = Path("docs/operations/ceph-initial-deployment.md").read_text()
assert "최초 OSD 배포 전용" in ceph_transition
assert "ceph osd ls --format json" in ceph_transition
terraform_main = Path("terraform/openstack/main.tf").read_text()
assert "external_fixed_ip" in terraform_main and "local.router_external_ip" in terraform_main
assert terraform_main.count('allocation_pool {') == 3
assert 'resource "openstack_networking_port_v2" "kubernetes_api_vip"' in terraform_main
assert "depends_on = [openstack_networking_port_v2.kubernetes_api_vip]" in terraform_main
assert 'output "skyline_url"' in Path("terraform/openstack/outputs.tf").read_text()
workload_module = Path("terraform/modules/openstack-vm/main.tf").read_text()
for resource in (
    'resource "openstack_networking_port_v2" "this"',
    'resource "openstack_blockstorage_volume_v3" "root"',
    'resource "openstack_compute_instance_v2" "this"',
    'resource "openstack_networking_floatingip_v2" "this"',
):
    assert resource in workload_module
assert workload_module.count("prevent_destroy = true") == 2
assert "delete_on_termination = false" in workload_module
assert "security_groups = []" not in workload_module
workload_module_variables = Path("terraform/modules/openstack-vm/variables.tf").read_text()
assert "length(trimspace(var.flavor_id)) > 0" in workload_module_variables
workload_template = Path("terraform/workloads/_template/main.tf").read_text()
assert 'source   = "../../modules/openstack-vm"' in workload_template
assert 'for_each = local.enabled_instances' in workload_template
assert 'name       = "${var.workload_name}-${each.key}"' in workload_template
assert 'resource "openstack_compute_aggregate_v2" "workload"' in workload_template
assert 'resource "openstack_compute_flavor_v2" "workload"' in workload_template
assert '"pci_passthrough:alias"' in Path("terraform/workloads/_template/terraform.tfvars.example").read_text()
assert workload_template.count("prevent_destroy = true") == 2
workload_example = Path("terraform/workloads/_template/terraform.tfvars.example").read_text()
assert re.search(r"(?m)^enable_instances\s*=\s*false$", workload_example)
for variable in ("network_id", "subnet_id", "image_id", "flavor_id", "instances"):
    assert re.search(rf"(?m)^\s*{variable}\s*=", workload_example), variable
workload_script = Path("scripts/internal/terraform-workload.sh").read_text()
for command in ("new", "plan", "show", "apply", "output", "inventory", "configure"):
    assert re.search(rf"(?m)^\s*{command}\)$", workload_script), command
assert "APPLY-TERRAFORM-WORKLOAD:$stack:$digest" in workload_script
assert 'plan -input=false -lock=true -var="workload_name=$stack"' in workload_script
assert 'apply -input=false -lock=true -parallelism=1 "$plan"' in workload_script
assert "^[a-z0-9][a-z0-9-]{0,62}$" in workload_script
assert 'cloud_context_sha256' in workload_script
assert 'tfplan.context.json' in workload_script
assert 'for template_file in "${template_files[@]}"' in workload_script
assert 'cp -a "$template_dir/."' not in workload_script
for command in ("workload-plan", "workload-apply", "workload-inventory", "workload-configure"):
    assert command in cluster_script, command
inventory_renderer = Path("scripts/internal/render-workload-ansible-inventory.py")
assert inventory_renderer.exists() and inventory_renderer.stat().st_mode & 0o111
assert Path("ansible/inventory/workloads/settings.example.yml").is_file()
assert "docs/workloads/terraform.md" in Path("README.md").read_text()
PY

# Validate the checked-in fresh three-node topology without writing generated files.
python3 scripts/internal/render-openstack-cluster.py \
  --config inventory/openstack-cluster.yml \
  --validate-only >/dev/null

# Exercise a three-node topology in an isolated repository so the check never
# overwrites reviewed or generated files in the working tree.
topology_repo="$work_dir/topology-repo"
mkdir -p \
  "$topology_repo/scripts/internal" \
  "$topology_repo/kolla/inventory" \
  "$topology_repo/kolla/generated" \
  "$topology_repo/.cache/kolla-venv/bin" \
  "$topology_repo/.cache/kolla-venv/share/kolla-ansible/ansible/inventory" \
  "$work_dir/topology-output"
cp scripts/internal/render-openstack-cluster.py "$topology_repo/scripts/internal/"
cp scripts/internal/render-kolla-multinode.sh "$topology_repo/scripts/internal/"
cp kolla/globals.yml "$topology_repo/kolla/"
ln -s "$(command -v python3)" "$topology_repo/.cache/kolla-venv/bin/python"
cat >"$topology_repo/.cache/kolla-venv/share/kolla-ansible/ansible/inventory/multinode" <<'INI'
[control]
template-control ansible_connection=local

[network]
template-network ansible_connection=local

[compute]
template-compute ansible_connection=local

[monitoring]
template-monitoring ansible_connection=local

[storage]
template-storage ansible_connection=local

[deployment]
template-deployment ansible_connection=local

[cinder-backup-multiple:children]
cinder
storage

[cinder-volume-multiple:children]
cinder
storage

[mariadb:children]
control
INI

python3 - \
  inventory/openstack-cluster.yml \
  "$work_dir/three-node.yml" \
  "$work_dir/two-node.yml" \
  "$work_dir/one-node-platform.yml" \
  "$work_dir/zun-provider.yml" \
  "$work_dir/three-node-platform.yml" \
  "$work_dir/container-service-enabled.yml" \
  "$work_dir/five-node.yml" \
  "$work_dir/seven-node.yml" <<'PY'
import copy
import sys
from pathlib import Path

import yaml


source = yaml.safe_load(Path(sys.argv[1]).read_text())
replacements = {
    "cloud02": {
        "management_mac": "02:00:00:00:00:02",
        "os_disk_serial": "CHECK-CLOUD02-OS",
    },
    "cloud03": {
        "management_mac": "02:00:00:00:00:03",
        "os_disk_serial": "CHECK-CLOUD03-OS",
    },
}
three = copy.deepcopy(source)
for name, values in replacements.items():
    three["nodes"][name]["enabled"] = True
    three["nodes"][name].update(values)
Path(sys.argv[2]).write_text(yaml.safe_dump(three, sort_keys=False))

two = copy.deepcopy(three)
two["nodes"]["cloud03"]["enabled"] = False
Path(sys.argv[3]).write_text(yaml.safe_dump(two, sort_keys=False))

one_platform = copy.deepcopy(source)
one_platform["nodes"]["cloud02"]["enabled"] = False
one_platform["nodes"]["cloud03"]["enabled"] = False
one_platform["cluster"]["platform"]["magnum_capi"]["enabled"] = True
Path(sys.argv[4]).write_text(yaml.safe_dump(one_platform, sort_keys=False))

zun = copy.deepcopy(source)
zun["cluster"]["platform"]["container_service"]["provider"] = "zun"
Path(sys.argv[5]).write_text(yaml.safe_dump(zun, sort_keys=False))

platform = copy.deepcopy(three)
platform["cluster"]["storage_backend"] = "ceph"
platform["cluster"]["ceph"]["enabled"] = True
platform["cluster"]["ceph"]["openstack_pool_device_class"] = "nvme"
platform["cluster"]["platform"]["magnum_capi"]["enabled"] = True
for index, name in enumerate(("cloud01", "cloud02", "cloud03"), start=1):
    if "storage" not in platform["nodes"][name]["roles"]:
        platform["nodes"][name]["roles"].append("storage")
    platform["nodes"][name]["ceph_osd_devices"] = [{
        "by_id": f"/dev/disk/by-id/check-osd-{index}",
        "serial": f"CHECK-OSD-{index}",
        "min_size_bytes": 2_000_000_000_000,
        "device_class": "nvme",
    }]
Path(sys.argv[6]).write_text(yaml.safe_dump(platform, sort_keys=False))

container_service = copy.deepcopy(source)
container_service["cluster"]["platform"]["container_service"]["enabled"] = True
Path(sys.argv[7]).write_text(yaml.safe_dump(container_service, sort_keys=False))

seven = copy.deepcopy(three)
for index in range(4, 8):
    name = f"cloud{index:02d}"
    address = f"192.0.2.{index + 2}"
    seven["nodes"][name] = {
        "enabled": True,
        "connection": "ssh",
        "ansible_host": address,
        "ansible_user": "operator",
        "management_interface": "mgmt0",
        "management_mac": f"02:00:00:00:00:{index:02x}",
        "management_address": f"{address}/24",
        "management_gateway": "192.0.2.1",
        "management_dns": ["192.0.2.1"],
        "neutron_external_interface": "mgmt0.10",
        "neutron_external_vlan_id": 10,
        "os_disk_serial": f"CHECK-CLOUD{index:02d}-OS",
        "require_docker_mount": False,
        "roles": ["compute"],
        "ceph_interface": "ceph0",
        "ceph_mac": f"02:00:00:00:30:{index:02x}",
        "ceph_address": f"192.168.30.{index + 2}",
        "ceph_osd_devices": [],
    }
five = copy.deepcopy(seven)
five["nodes"]["cloud06"]["enabled"] = False
five["nodes"]["cloud07"]["enabled"] = False
Path(sys.argv[8]).write_text(yaml.safe_dump(five, sort_keys=False))
Path(sys.argv[9]).write_text(yaml.safe_dump(seven, sort_keys=False))
PY

python3 "$topology_repo/scripts/internal/render-openstack-cluster.py" \
  --config "$work_dir/three-node.yml" \
  --output-dir "$work_dir/topology-output" >/dev/null
bash "$topology_repo/scripts/internal/render-kolla-multinode.sh" >/dev/null

if python3 scripts/internal/render-openstack-cluster.py \
  --config "$work_dir/two-node.yml" \
  --validate-only >"$work_dir/two-node.stdout" 2>"$work_dir/two-node.stderr"; then
  echo 'Two-node topology unexpectedly passed quorum validation.' >&2
  exit 1
fi
grep -q 'first supported deployment requires at least three enabled nodes' "$work_dir/two-node.stderr"

if python3 scripts/internal/render-openstack-cluster.py \
  --config "$work_dir/one-node-platform.yml" \
  --validate-only >"$work_dir/one-platform.stdout" 2>"$work_dir/one-platform.stderr"; then
  echo 'One-node managed platform unexpectedly passed validation.' >&2
  exit 1
fi
grep -q 'first supported deployment requires at least three enabled nodes' \
  "$work_dir/one-platform.stderr"

if python3 scripts/internal/render-openstack-cluster.py \
  --config "$work_dir/zun-provider.yml" \
  --validate-only >"$work_dir/zun.stdout" 2>"$work_dir/zun.stderr"; then
  echo 'Unsupported Zun provider unexpectedly passed validation.' >&2
  exit 1
fi
grep -q 'Zun is unsupported by Kolla-Ansible 2026.2' "$work_dir/zun.stderr"

if python3 scripts/internal/render-openstack-cluster.py \
  --config "$work_dir/container-service-enabled.yml" \
  --validate-only >"$work_dir/container-service.stdout" 2>"$work_dir/container-service.stderr"; then
  echo 'Unimplemented container service unexpectedly passed validation.' >&2
  exit 1
fi
grep -q 'container_service.enabled=true is not implemented' \
  "$work_dir/container-service.stderr"

for scale in five seven; do
  python3 scripts/internal/render-openstack-cluster.py \
    --config "$work_dir/${scale}-node.yml" \
    --validate-only >/dev/null
done

mkdir -p "$work_dir/platform-output"
python3 "$topology_repo/scripts/internal/render-openstack-cluster.py" \
  --config "$work_dir/three-node-platform.yml" \
  --output-dir "$work_dir/platform-output" >/dev/null
python3 - \
  "$topology_repo/kolla/generated/globals.yml" \
  "$work_dir/platform-output/cluster-plan.json" \
  "$work_dir/three-node-platform.yml" <<'PY'
import json
import sys
from pathlib import Path

import yaml

globals_data = yaml.safe_load(Path(sys.argv[1]).read_text())
assert globals_data["neutron_plugin_agent"] == "ovn"
assert globals_data["enable_magnum"] == "yes"
assert globals_data["enable_octavia"] == "yes"
assert globals_data["enable_barbican"] == "yes"
assert globals_data["octavia_provider_drivers"] == "ovn:OVN provider"
plan = json.loads(Path(sys.argv[2]).read_text())
assert plan["node_count"] == 3
assert plan["storage_backend"] == "ceph"
assert plan["platform"]["magnum_capi"]["enabled"] is True
ceph_plan = json.loads(Path(sys.argv[2]).with_name("ceph-plan.json").read_text())
assert ceph_plan["openstack_pool_device_class"] == "nvme"
assert Path(ceph_plan["config"]).resolve() == Path(sys.argv[3]).resolve()
PY

python3 - \
  "$work_dir/topology-output/ansible-inventory.yml" \
  "$topology_repo/kolla/inventory/multinode.local" \
  "$topology_repo/kolla/generated/multinode" \
  "$topology_repo/kolla/generated/globals.yml" \
  "$work_dir/topology-output/cluster-plan.json" <<'PY'
import json
import sys
from pathlib import Path

import yaml


ansible_inventory = yaml.safe_load(Path(sys.argv[1]).read_text())
hosts = ansible_inventory["all"]["hosts"]
assert list(hosts) == ["cloud01", "cloud02", "cloud03"]
for role in ("control", "network", "compute"):
    assert set(ansible_inventory["all"]["children"][role]["hosts"]) == set(hosts)
assert {values["timezone"] for values in hosts.values()} == {"Asia/Seoul"}

kolla_primary_lines = Path(sys.argv[2]).read_text().splitlines()
def group_hosts(lines, group):
    members = []
    in_group = False
    for line in lines:
        if line.strip() == f"[{group}]":
            in_group = True
            continue
        if in_group and line.startswith("["):
            break
        if in_group and line.strip() and not line.lstrip().startswith("#"):
            members.append(line.split()[0])
    return members

for role in ("control", "network", "compute"):
    assert set(group_hosts(kolla_primary_lines, role)) == set(hosts), f"Kolla {role} group mismatch"
assert "all-in-one" not in Path(sys.argv[2]).read_text()

generated_lines = Path(sys.argv[3]).read_text().splitlines()
for role in ("control", "network", "compute"):
    assert set(group_hosts(generated_lines, role)) == set(hosts), f"generated Kolla {role} mismatch"
assert "template-control" not in Path(sys.argv[3]).read_text()

globals_data = yaml.safe_load(Path(sys.argv[4]).read_text())
assert globals_data["kolla_internal_vip_address"] == "192.0.2.10"
plan = json.loads(Path(sys.argv[5]).read_text())
assert plan["node_count"] == 3
assert plan["roles"]["storage"] == ["cloud01", "cloud02", "cloud03"]
PY

# Keep 5/7-node physical scaling generic: three controller/network nodes and
# additional compute nodes must render through both topology and Kolla layers.
mkdir -p "$work_dir/seven-node-output"
python3 "$topology_repo/scripts/internal/render-openstack-cluster.py" \
  --config "$work_dir/seven-node.yml" \
  --output-dir "$work_dir/seven-node-output" >/dev/null
bash "$topology_repo/scripts/internal/render-kolla-multinode.sh" >/dev/null
python3 - \
  "$work_dir/seven-node-output/ansible-inventory.yml" \
  "$topology_repo/kolla/generated/multinode" \
  "$work_dir/seven-node-output/cluster-plan.json" <<'PY'
import json
import sys
from pathlib import Path

import yaml


inventory = yaml.safe_load(Path(sys.argv[1]).read_text())["all"]
all_hosts = {f"cloud{index:02d}" for index in range(1, 8)}
core_hosts = {"cloud01", "cloud02", "cloud03"}
assert set(inventory["hosts"]) == all_hosts
assert set(inventory["children"]["control"]["hosts"]) == core_hosts
assert set(inventory["children"]["network"]["hosts"]) == core_hosts
assert set(inventory["children"]["compute"]["hosts"]) == all_hosts

def group_hosts(lines, group):
    members = []
    in_group = False
    for line in lines:
        if line.strip() == f"[{group}]":
            in_group = True
            continue
        if in_group and line.startswith("["):
            break
        if in_group and line.strip() and not line.lstrip().startswith("#"):
            members.append(line.split()[0])
    return members

kolla_lines = Path(sys.argv[2]).read_text().splitlines()
assert set(group_hosts(kolla_lines, "control")) == core_hosts
assert set(group_hosts(kolla_lines, "network")) == core_hosts
assert set(group_hosts(kolla_lines, "compute")) == all_hosts
plan = json.loads(Path(sys.argv[3]).read_text())
assert plan["node_count"] == 7
assert set(plan["nodes"]) == all_hosts
assert plan["roles"]["storage"] == ["cloud01", "cloud02", "cloud03"]
PY

# Run the Kubespray renderer against deterministic Terraform output fixtures.
# This checks role membership, inventory order and generated kube-vip variables
# without an OpenStack cloud, Terraform state, or network access.
kubespray_repo="$work_dir/kubespray-repo"
mkdir -p \
  "$kubespray_repo/scripts/internal" \
  "$kubespray_repo/config" \
  "$kubespray_repo/terraform/openstack" \
  "$kubespray_repo/.cache/terraform/bin"
cp scripts/internal/render-openstack-kubespray-inventory.sh "$kubespray_repo/scripts/internal/"
cp scripts/internal/render-openstack-cluster.py "$kubespray_repo/scripts/internal/"
cp config/versions.env "$kubespray_repo/config/"
: >"$kubespray_repo/terraform/openstack/terraform.tfstate"
cat >"$work_dir/kubernetes-nodes.json" <<'JSON'
{
  "k8s-control-1": {
    "fixed_ip": "203.0.113.11",
    "floating_ip": "198.51.100.50",
    "roles": ["control_plane", "etcd", "worker"],
    "inventory_order": 20
  },
  "k8s-worker-1": {
    "fixed_ip": "203.0.113.14",
    "floating_ip": "198.51.100.53",
    "roles": ["worker"],
    "inventory_order": 10
  },
  "k8s-control-2": {
    "fixed_ip": "203.0.113.12",
    "floating_ip": "198.51.100.51",
    "roles": ["control_plane", "etcd", "worker"],
    "inventory_order": 30
  },
  "k8s-control-3": {
    "fixed_ip": "203.0.113.13",
    "floating_ip": "198.51.100.52",
    "roles": ["control_plane", "etcd"],
    "inventory_order": 40
  }
}
JSON
cat >"$work_dir/kubernetes-api.json" <<'JSON'
{
  "internal_vip": "203.0.113.10",
  "management_api": "192.0.2.10",
  "network_id": "network-check-id",
  "subnet_id": "subnet-check-id",
  "floating_network_id": "public-check-id",
  "control_plane_floating_ips": ["198.51.100.50", "198.51.100.51", "198.51.100.52"]
}
JSON
cat >"$kubespray_repo/.cache/terraform/bin/terraform" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
fixture_repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$fixture_repo/config/versions.env"
case " $* " in
  *" version -json "*) printf '{"terraform_version":"%s"}\n' "$TERRAFORM_CLI_VERSION" ;;
  *" output -json kubernetes_nodes "*) cat "$CHECK_KUBERNETES_NODES_JSON" ;;
  *" output -json kubernetes_api "*) cat "$CHECK_KUBERNETES_API_JSON" ;;
  *) echo "unexpected fixture Terraform command: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$kubespray_repo/.cache/terraform/bin/terraform"

OPENSTACK_CLUSTER_CONFIG="$work_dir/three-node-platform.yml" \
CHECK_KUBERNETES_NODES_JSON="$work_dir/kubernetes-nodes.json" \
CHECK_KUBERNETES_API_JSON="$work_dir/kubernetes-api.json" \
  bash "$kubespray_repo/scripts/internal/render-openstack-kubespray-inventory.sh" >/dev/null

python3 - \
  "$kubespray_repo/.cache/kubespray-inventory/openstack/hosts.yml" \
  "$kubespray_repo/.cache/kubespray-inventory/openstack/group_vars/k8s_cluster/zzz-openstack-generated.yml" \
  "$kubespray_repo/.cache/kubespray-inventory/openstack/desired-nodes.json" <<'PY'
import json
import sys
from pathlib import Path

import yaml


inventory = yaml.safe_load(Path(sys.argv[1]).read_text())["all"]
assert list(inventory["hosts"]) == [
    "k8s-worker-1",
    "k8s-control-1",
    "k8s-control-2",
    "k8s-control-3",
]
children = inventory["children"]
assert list(children["kube_control_plane"]["hosts"]) == [
    "k8s-control-1",
    "k8s-control-2",
    "k8s-control-3",
]
assert list(children["etcd"]["hosts"]) == [
    "k8s-control-1",
    "k8s-control-2",
    "k8s-control-3",
]
assert list(children["kube_node"]["hosts"]) == [
    "k8s-worker-1",
    "k8s-control-1",
    "k8s-control-2",
]

generated = yaml.safe_load(Path(sys.argv[2]).read_text())
assert generated["kube_vip_address"] == "203.0.113.10"
assert generated["loadbalancer_apiserver"] == {
    "address": "{{ kube_vip_address }}",
    "port": 6443,
}
assert generated["supplementary_addresses_in_ssl_keys"] == [
    "192.0.2.10",
    "198.51.100.50",
    "198.51.100.51",
    "198.51.100.52",
]
desired = json.loads(Path(sys.argv[3]).read_text())
assert desired["management_api"] == "192.0.2.10"
assert desired["bootstrap_api"] == "198.51.100.50"
assert desired["platform_enabled"] is False
assert len(desired["provenance"]["terraform_state_sha256"]) == 64
assert desired["provenance"]["cluster_plan_sha256"] is None
PY

# The same renderer enables OpenStack CCM, Octavia and Cinder CSI only when the
# reviewed three-node platform profile is active.
mkdir -p "$kubespray_repo/.cache/cluster"
cp "$work_dir/platform-output/cluster-plan.json" \
  "$kubespray_repo/.cache/cluster/cluster-plan.json"
PATH="$work_dir/fake-bin:$PATH" \
OPENSTACK_CLUSTER_CONFIG="$work_dir/three-node-platform.yml" \
CHECK_KUBERNETES_NODES_JSON="$work_dir/kubernetes-nodes.json" \
CHECK_KUBERNETES_API_JSON="$work_dir/kubernetes-api.json" \
  bash "$kubespray_repo/scripts/internal/render-openstack-kubespray-inventory.sh" >/dev/null
python3 - \
  "$kubespray_repo/.cache/kubespray-inventory/openstack/group_vars/all/zzz-openstack-platform.yml" \
  "$kubespray_repo/.cache/kubespray-inventory/openstack/desired-nodes.json" <<'PY'
import json
import sys
from pathlib import Path

import yaml

values = yaml.safe_load(Path(sys.argv[1]).read_text())
assert values["cloud_provider"] == "external"
assert values["external_cloud_provider"] == "openstack"
assert values["cinder_csi_enabled"] is True
assert values["storage_classes"][0]["name"] == "cinder-csi"
assert values["storage_classes"][0]["is_default"] is True
assert values["external_openstack_lbaas_provider"] == "ovn"
assert values["external_openstack_lbaas_method"] == "SOURCE_IP_PORT"
assert values["external_openstack_lbaas_manage_security_groups"] is True
assert values["external_openstack_lbaas_network_id"] == "network-check-id"
assert values["external_openstack_lbaas_subnet_id"] == "subnet-check-id"
desired = json.loads(Path(sys.argv[2]).read_text())
assert desired["platform_enabled"] is True
assert len(desired["provenance"]["terraform_state_sha256"]) == 64
assert len(desired["provenance"]["cluster_plan_sha256"]) == 64
PY

# A cached platform plan must never activate CCM/CSI after its authoritative
# topology changes. The renderer must fail closed until cluster.sh render runs.
touch "$work_dir/three-node-platform.yml"
if PATH="$work_dir/fake-bin:$PATH" \
  OPENSTACK_CLUSTER_CONFIG="$work_dir/three-node-platform.yml" \
  CHECK_KUBERNETES_NODES_JSON="$work_dir/kubernetes-nodes.json" \
  CHECK_KUBERNETES_API_JSON="$work_dir/kubernetes-api.json" \
    bash "$kubespray_repo/scripts/internal/render-openstack-kubespray-inventory.sh" \
      >"$work_dir/stale-plan.stdout" 2>"$work_dir/stale-plan.stderr"; then
  echo 'Stale managed-platform plan unexpectedly passed Kubespray rendering.' >&2
  exit 1
fi
grep -q 'cluster plan is older than the authoritative topology' \
  "$work_dir/stale-plan.stderr"

# Exercise the management-cloud credential safety transaction with fake
# OpenStack/SDK entry points. The first run must be read-only, a confirmed run
# must save only a member credential, and a failed run must roll back its user.
credential_repo="$work_dir/credential-repo"
mkdir -p \
  "$credential_repo/scripts/internal" \
  "$credential_repo/.cache/kolla-venv/bin" \
  "$credential_repo/terraform/openstack"
cp scripts/internal/management-kubernetes-cloud.sh "$credential_repo/scripts/internal/"
cat >"$credential_repo/scripts/internal/render-openstack-cluster.py" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$repo_dir/.cache/cluster"
cat >"$repo_dir/.cache/cluster/cluster-plan.json" <<'JSON'
{"node_count": 3, "storage_backend": "ceph", "platform": {"magnum_capi": {"enabled": true}}}
JSON
SH
chmod +x "$credential_repo/scripts/internal/render-openstack-cluster.py"
cat >"$credential_repo/terraform/openstack/clouds.yaml" <<'YAML'
clouds:
  admin:
    region_name: RegionOne
    cacert: /tmp/fake-openstack-ca.pem
    auth:
      auth_url: https://identity.example/v3
      username: admin
      password: fake-admin-password
      project_name: admin
      user_domain_name: Default
YAML
cat >"$credential_repo/.cache/kolla-venv/bin/python" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
arguments=("$@")
password_file=${arguments[${#arguments[@]}-2]}
output_file=${arguments[${#arguments[@]}-1]}
password=$(cat "$password_file")
[[ -n $password ]]
for argument in "$@"; do
  [[ $argument != "$password" ]] || {
    echo 'generated password appeared in SDK argv' >&2
    exit 70
  }
done
touch "$repo_dir/.fake-user"
printf '{"id":"user-1","domain_id":"domain-1"}\n' >"$output_file"
SH
cat >"$credential_repo/.cache/kolla-venv/bin/openstack" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
case " $* " in
  *' token issue '*)
    if [[ -n ${OS_APPLICATION_CREDENTIAL_ID:-} ]]; then
      printf '{"id":"token-1","project_id":"project-1","user_id":"user-1"}\n'
    else
      printf '{"id":"admin-token","project_id":"project-1","user_id":"admin-1"}\n'
    fi
    ;;
  *' user show kubespray-management '*)
    [[ -f $repo_dir/.fake-user ]] || exit 1
    printf '{"id":"user-1","name":"kubespray-management","domain_id":"domain-1","enabled":true}\n'
    ;;
  *' user show user-1 '*)
    [[ -f $repo_dir/.fake-user ]] || exit 1
    printf '{"id":"user-1","name":"kubespray-management","domain_id":"domain-1","enabled":true}\n'
    ;;
  *' role show member '*)
    printf '{"id":"role-member","name":"member"}\n'
    ;;
  *' role add '*)
    [[ -f $repo_dir/.fake-user ]]
    touch "$repo_dir/.fake-role"
    ;;
  *' application credential create '*)
    [[ " $* " == *' --role member '* ]]
    [[ ${FAKE_APPLICATION_CREDENTIAL_FAILURE:-0} != 1 ]] || exit 42
    printf '{"id":"credential-1","secret":"one-time-secret"}\n'
    ;;
  *' role assignment list '*)
    [[ -f $repo_dir/.fake-role ]]
    printf '[{"Role":"member","User":"kubespray-management@Default","Project":"admin@Default"}]\n'
    ;;
  *' user delete user-1 '*)
    rm -f "$repo_dir/.fake-user" "$repo_dir/.fake-role"
    touch "$repo_dir/.fake-rollback"
    ;;
  *)
    echo "unexpected fake OpenStack command: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x \
  "$credential_repo/.cache/kolla-venv/bin/python" \
  "$credential_repo/.cache/kolla-venv/bin/openstack"

if OS_CLIENT_CONFIG_FILE="$credential_repo/terraform/openstack/clouds.yaml" \
  OS_CLOUD=admin \
  "$credential_repo/scripts/internal/management-kubernetes-cloud.sh" create-credential \
    >"$work_dir/credential-plan.stdout" 2>"$work_dir/credential-plan.stderr"; then
  echo 'Unconfirmed management credential creation unexpectedly succeeded.' >&2
  exit 1
fi
grep -q "CREATE-K8S-CLOUD-PRINCIPAL:project-1:kubespray-management:member" \
  "$work_dir/credential-plan.stderr"
[[ ! -e $credential_repo/.fake-user ]]

OS_CLIENT_CONFIG_FILE="$credential_repo/terraform/openstack/clouds.yaml" \
OS_CLOUD=admin \
MANAGEMENT_CLOUD_CONFIRM='CREATE-K8S-CLOUD-PRINCIPAL:project-1:kubespray-management:member' \
  "$credential_repo/scripts/internal/management-kubernetes-cloud.sh" create-credential >/dev/null
credential_env="$credential_repo/kubeconfig/openstack-management.env"
[[ -f $credential_env && $(stat -c '%a' "$credential_env") == 600 ]]
grep -q '^MANAGEMENT_CLOUD_ROLE_NAME=member$' "$credential_env"
grep -q '^MANAGEMENT_CLOUD_USER_ID=user-1$' "$credential_env"
grep -q '^OS_CACERT=/tmp/fake-openstack-ca.pem$' "$credential_env"
OS_CLIENT_CONFIG_FILE="$credential_repo/terraform/openstack/clouds.yaml" \
OS_CLOUD=admin \
  "$credential_repo/scripts/internal/management-kubernetes-cloud.sh" status >/dev/null

rm -f \
  "$credential_env" \
  "$credential_repo/.fake-user" \
  "$credential_repo/.fake-role" \
  "$credential_repo/.fake-rollback"
if OS_CLIENT_CONFIG_FILE="$credential_repo/terraform/openstack/clouds.yaml" \
  OS_CLOUD=admin \
  MANAGEMENT_CLOUD_CONFIRM='CREATE-K8S-CLOUD-PRINCIPAL:project-1:kubespray-management:member' \
  FAKE_APPLICATION_CREDENTIAL_FAILURE=1 \
    "$credential_repo/scripts/internal/management-kubernetes-cloud.sh" create-credential \
      >"$work_dir/credential-failure.stdout" 2>"$work_dir/credential-failure.stderr"; then
  echo 'Injected management credential failure unexpectedly succeeded.' >&2
  exit 1
fi
[[ -f $credential_repo/.fake-rollback ]]
[[ ! -e $credential_repo/.fake-user && ! -e $credential_env ]]

# Exercise the OpenWrt renderer without contacting a router. The fixture binds
# exact hardware facts to the initial three-node topology and verifies the
# generated transaction contract consumed by the Ansible playbooks.
openwrt_inventory="$work_dir/openwrt-inventory.yml"
openwrt_discovery="$work_dir/openwrt-discovery.json"
openwrt_output="$work_dir/openwrt-output"
mkdir -p "$openwrt_output"
python3 - \
  inventory/openwrt-router.example.yml \
  "$openwrt_inventory" \
  "$openwrt_discovery" <<'PY'
import json
import sys
from pathlib import Path

import yaml


inventory = yaml.safe_load(Path(sys.argv[1]).read_text())
router = inventory["all"]["children"]["openwrt"]["hosts"]["router"]
router["enabled"] = True
router["physical_console_available"] = True
router["expected"] = {
    "board_name": "check-router",
    "release": {"target": "ath79/generic", "version": "24.10.0"},
    "capabilities": {"dsa": True, "fw4": True},
}
router["dsa_bridge"] = {
    "section": "br_lan",
    "name": "br-lan",
    "ports": ["lan1", "lan2"],
    "management_ports": ["lan1", "lan2"],
    "provider_tagged_ports": ["lan2"],
}
router["networks"]["provider"]["deployed_nodes"] = []
router["networks"]["provider"]["probe_addresses"] = {
    "cloud01": "198.51.100.2",
    "cloud02": "198.51.100.3",
    "cloud03": "198.51.100.4",
}
Path(sys.argv[2]).write_text(yaml.safe_dump(inventory, sort_keys=False))

discovery = {
    "schema_version": 1,
    "inventory_hostname": "router",
    "board_name": "check-router",
    "release": {"target": "ath79/generic", "version": "24.10.0"},
    "capabilities": {
        "dsa": True,
        "fw4": True,
        "dsa_evidence": "sysfs-dsa-port",
    },
    "root_ssh_key_configured": True,
    "rollback_guard": {"armed": False, "change_id": ""},
    "configs": {
        "network_sha256": "1" * 64,
        "firewall_sha256": "2" * 64,
        "dhcp_sha256": "3" * 64,
        "pending_changes": {"network": False, "firewall": False, "dhcp": False},
    },
    "dsa": {
        "bridge": {"section": "br_lan", "name": "br-lan", "ports": ["lan1", "lan2"]},
        "bridges": [
            {"section": "br_guest", "name": "br-guest", "ports": ["guest1"]},
            {"section": "br_lan", "name": "br-lan", "ports": ["lan1", "lan2"]},
        ],
        "bridge_vlans": [],
    },
    "firewall": {
        "zones": [
            {"section": "lan", "name": "lan", "masq": False},
            {"section": "wan", "name": "wan", "masq": True},
        ]
    },
    "uci": {
        "network": [
            "network.lan=interface",
            "network.lan.device='br-lan'",
            "network.lan.proto='static'",
            "network.lan.ipaddr='192.0.2.1'",
            "network.lan.netmask='255.255.255.0'",
            "network.br_lan=device",
            "network.br_lan.type='bridge'",
            "network.br_lan.name='br-lan'",
            "network.br_lan.ports='lan1' 'lan2'",
        ],
        "firewall": [],
        "dhcp": [
            "dhcp.lan=dhcp",
            "dhcp.lan.interface='lan'",
            "dhcp.lan.start='100'",
            "dhcp.lan.limit='150'",
        ],
    },
}
Path(sys.argv[3]).write_text(json.dumps(discovery, indent=2) + "\n")
PY

python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$openwrt_inventory" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config inventory/openstack-cluster.yml \
  --discovery "$openwrt_discovery" \
  --output-dir "$openwrt_output" >/dev/null
python3 - "$openwrt_output/plan.json" "$openwrt_output/uci.batch" <<'PY'
import hashlib
import json
import sys
from pathlib import Path


plan = json.loads(Path(sys.argv[1]).read_text())
batch = Path(sys.argv[2]).read_text()
assert plan["schema_version"] == 1
assert plan["router"]["board_name"] == "check-router"
assert plan["router"]["capabilities"]["dsa_evidence"] == "sysfs-dsa-port"
assert plan["provider"]["probes"]["cloud01"] == {
    "interface": "mgmt0.10",
    "temporary_cidr": "198.51.100.2/24",
    "gateway": "198.51.100.1",
}
assert set(plan["provider"]["probes"]) == {"cloud01", "cloud02", "cloud03"}
assert plan["provider"]["deployed"] == {}
assert plan["provider"]["deployed_nodes_without_temporary_probe"] == []
assert plan["management"]["dhcp_dynamic_pool"] == {
    "start": "192.0.2.100",
    "end": "192.0.2.249",
}
assert plan["preflight"]["require_physical_console"] is True
assert plan["confirmations"]["apply"].startswith("APPLY-OPENWRT:check-router:lan2:vlan10:")
assert plan["confirmations"]["confirm"].startswith("CONFIRM-OPENWRT:openwrt-")
assert plan["confirmations"]["rollback"].startswith("ROLLBACK-OPENWRT:check-router:lan2:vlan10:")
assert plan["artifacts"]["uci_batch_sha256"] == hashlib.sha256(batch.encode()).hexdigest()
assert "set network.lan.device='br-lan.1'" in batch
assert "set network.os_provider.ipaddr='198.51.100.1'" in batch
assert "set firewall.os_provider_to_lan_reject.target='REJECT'" in batch
assert "commit " not in batch
PY

openwrt_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"])' "$openwrt_output/plan.json")
python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$openwrt_inventory" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config inventory/openstack-cluster.yml \
  --discovery "$openwrt_discovery" \
  --output-dir "$openwrt_output" >/dev/null
[[ $openwrt_digest == "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"])' "$openwrt_output/plan.json")" ]]

# A router that already has the exact managed VLAN sections must remain
# renderable so later node additions and revalidation are idempotent.
python3 - "$openwrt_discovery" "$work_dir/openwrt-post-apply.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
data["configs"]["network_sha256"] = "4" * 64
data["configs"]["firewall_sha256"] = "5" * 64
data["configs"]["dhcp_sha256"] = "6" * 64
data["uci"]["network"] = [
    line.replace("network.lan.device='br-lan'", "network.lan.device='br-lan.1'")
    for line in data["uci"]["network"]
]
data["dsa"]["bridge_vlans"] = [
    {
        "section": "os_management_vlan",
        "device": "br-lan",
        "vlan": 1,
        "ports": ["lan1:u*", "lan2:u*"],
    },
    {
        "section": "os_provider_vlan",
        "device": "br-lan",
        "vlan": 10,
        "ports": ["lan2:t"],
    },
]
data["firewall"]["zones"].append({
    "section": "os_provider_zone",
    "name": "os_provider",
    "masq": False,
})
Path(sys.argv[2]).write_text(json.dumps(data))
PY
python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$openwrt_inventory" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config inventory/openstack-cluster.yml \
  --discovery "$work_dir/openwrt-post-apply.json" \
  --output-dir "$work_dir/openwrt-post-apply-output" >/dev/null

# Expanding the reviewed provider trunk to another existing LAN port must be a
# renderable managed change after the first application.
python3 - "$openwrt_inventory" "$work_dir/openwrt-expanded-port.yml" <<'PY'
import sys
from pathlib import Path
import yaml

data = yaml.safe_load(Path(sys.argv[1]).read_text())
router = data["all"]["children"]["openwrt"]["hosts"]["router"]
router["dsa_bridge"]["provider_tagged_ports"] = ["lan1", "lan2"]
Path(sys.argv[2]).write_text(yaml.safe_dump(data, sort_keys=False))
PY
python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$work_dir/openwrt-expanded-port.yml" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config inventory/openstack-cluster.yml \
  --discovery "$work_dir/openwrt-post-apply.json" \
  --output-dir "$work_dir/openwrt-expanded-port-output" >/dev/null
grep -q "add_list network.os_provider_vlan.ports='lan1:t'" \
  "$work_dir/openwrt-expanded-port-output/uci.batch"

# The same router trunk must render unique probes for every enabled node when
# cloud02 and cloud03 are enabled together.
python3 - "$openwrt_inventory" "$work_dir/openwrt-three-node.yml" <<'PY'
import sys
from pathlib import Path
import yaml

data = yaml.safe_load(Path(sys.argv[1]).read_text())
router = data["all"]["children"]["openwrt"]["hosts"]["router"]
router["networks"]["provider"]["probe_addresses"] = {
    "cloud01": "198.51.100.2",
    "cloud02": "198.51.100.3",
    "cloud03": "198.51.100.4",
}
Path(sys.argv[2]).write_text(yaml.safe_dump(data, sort_keys=False))
PY
python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$work_dir/openwrt-three-node.yml" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config "$work_dir/three-node.yml" \
  --discovery "$openwrt_discovery" \
  --output-dir "$work_dir/openwrt-three-node-output" >/dev/null
python3 - "$work_dir/openwrt-three-node-output/plan.json" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1]))
assert set(plan["provider"]["probes"]) == {"cloud01", "cloud02", "cloud03"}
assert [plan["provider"]["probes"][name]["temporary_cidr"] for name in sorted(plan["provider"]["probes"])] == [
    "198.51.100.2/24",
    "198.51.100.3/24",
    "198.51.100.4/24",
]
assert plan["verification"]["router_ping_targets"] == [
    "192.0.2.2",
    "192.0.2.4",
    "192.0.2.5",
]
PY

# During physical expansion, existing br-ex nodes are explicitly declared and
# only newly prepared nodes receive temporary probe addresses.
python3 - "$work_dir/openwrt-three-node.yml" "$work_dir/openwrt-expansion.yml" <<'PY'
import sys
from pathlib import Path
import yaml

data = yaml.safe_load(Path(sys.argv[1]).read_text())
provider = data["all"]["children"]["openwrt"]["hosts"]["router"]["networks"]["provider"]
provider["deployed_nodes"] = ["cloud01"]
del provider["probe_addresses"]["cloud01"]
Path(sys.argv[2]).write_text(yaml.safe_dump(data, sort_keys=False))
PY
python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$work_dir/openwrt-expansion.yml" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config "$work_dir/three-node.yml" \
  --discovery "$work_dir/openwrt-post-apply.json" \
  --output-dir "$work_dir/openwrt-expansion-output" >/dev/null
python3 - "$work_dir/openwrt-expansion-output/plan.json" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1]))
assert set(plan["provider"]["probes"]) == {"cloud02", "cloud03"}
assert plan["provider"]["deployed"] == {
    "cloud01": {"interface": "mgmt0.10"},
}
assert plan["provider"]["deployed_nodes_without_temporary_probe"] == ["cloud01"]
PY

# A post-apply bridge must retain every reviewed native management port and
# may retain only provider ports that are still present in the desired trunk.
python3 - \
  "$work_dir/openwrt-post-apply.json" \
  "$work_dir/openwrt-management-port-drift.json" \
  "$work_dir/openwrt-provider-port-drift.json" <<'PY'
import copy
import json
import sys
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text())
management = copy.deepcopy(source)
management["dsa"]["bridge_vlans"][0]["ports"] = ["lan2:u*"]
Path(sys.argv[2]).write_text(json.dumps(management))
provider = copy.deepcopy(source)
provider["dsa"]["bridge_vlans"][1]["ports"] = ["lan1:t"]
Path(sys.argv[3]).write_text(json.dumps(provider))
PY
for openwrt_drift in management-port provider-port; do
  if python3 scripts/internal/render-openwrt-plan.py \
    --inventory "$openwrt_inventory" \
    --openstack-plan inventory/openstack-plan.yml \
    --cluster-config inventory/openstack-cluster.yml \
    --discovery "$work_dir/openwrt-${openwrt_drift}-drift.json" \
    --output-dir "$work_dir/openwrt-${openwrt_drift}-drift-output" \
    >"$work_dir/openwrt-${openwrt_drift}-drift.stdout" \
    2>"$work_dir/openwrt-${openwrt_drift}-drift.stderr"; then
    echo "Unsafe OpenWrt ${openwrt_drift} drift unexpectedly passed." >&2
    exit 1
  fi
done
grep -q 'os_management_vlan ports do not match the inventory' \
  "$work_dir/openwrt-management-port-drift.stderr"
grep -q 'os_provider_vlan has ports outside the inventory' \
  "$work_dir/openwrt-provider-port-drift.stderr"

python3 - "$openwrt_discovery" "$work_dir/openwrt-dhcp-conflict.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
data["uci"]["dhcp"] = [
    "dhcp.lan=dhcp",
    "dhcp.lan.interface='lan'",
    "dhcp.lan.start='2'",
    "dhcp.lan.limit='20'",
]
Path(sys.argv[2]).write_text(json.dumps(data))
PY
if python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$openwrt_inventory" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config inventory/openstack-cluster.yml \
  --discovery "$work_dir/openwrt-dhcp-conflict.json" \
  --output-dir "$work_dir/openwrt-dhcp-conflict-output" \
  >"$work_dir/openwrt-dhcp-conflict.stdout" 2>"$work_dir/openwrt-dhcp-conflict.stderr"; then
  echo 'OpenWrt DHCP overlap with reserved management addresses unexpectedly passed.' >&2
  exit 1
fi
grep -q 'overlaps reserved management addresses' "$work_dir/openwrt-dhcp-conflict.stderr"

python3 - "$openwrt_inventory" "$work_dir/openwrt-no-console.yml" <<'PY'
import sys
from pathlib import Path
import yaml

data = yaml.safe_load(Path(sys.argv[1]).read_text())
data["all"]["children"]["openwrt"]["hosts"]["router"]["physical_console_available"] = False
Path(sys.argv[2]).write_text(yaml.safe_dump(data, sort_keys=False))
PY
if python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$work_dir/openwrt-no-console.yml" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config inventory/openstack-cluster.yml \
  --discovery "$openwrt_discovery" \
  --output-dir "$work_dir/openwrt-no-console-output" \
  >"$work_dir/openwrt-no-console.stdout" 2>"$work_dir/openwrt-no-console.stderr"; then
  echo 'OpenWrt plan without a recovery console unexpectedly passed.' >&2
  exit 1
fi
grep -q 'physical_console_available must be true' "$work_dir/openwrt-no-console.stderr"

python3 - "$openwrt_inventory" "$work_dir/openwrt-pool-probe.yml" <<'PY'
import sys
from pathlib import Path
import yaml

data = yaml.safe_load(Path(sys.argv[1]).read_text())
router = data["all"]["children"]["openwrt"]["hosts"]["router"]
router["networks"]["provider"]["probe_addresses"]["cloud01"] = "198.51.100.50"
Path(sys.argv[2]).write_text(yaml.safe_dump(data, sort_keys=False))
PY
if python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$work_dir/openwrt-pool-probe.yml" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config inventory/openstack-cluster.yml \
  --discovery "$openwrt_discovery" \
  --output-dir "$work_dir/openwrt-pool-probe-output" \
  >"$work_dir/openwrt-pool-probe.stdout" 2>"$work_dir/openwrt-pool-probe.stderr"; then
  echo 'OpenWrt probe inside the Floating IP pool unexpectedly passed.' >&2
  exit 1
fi
grep -q 'must be outside the floating IP pool' "$work_dir/openwrt-pool-probe.stderr"

python3 - "$openwrt_discovery" "$work_dir/openwrt-pending.json" "$work_dir/openwrt-no-masq.json" "$work_dir/openwrt-vlan-conflict.json" <<'PY'
import copy
import json
import sys
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text())
pending = copy.deepcopy(source)
pending["configs"]["pending_changes"]["network"] = True
Path(sys.argv[2]).write_text(json.dumps(pending))
no_masq = copy.deepcopy(source)
for zone in no_masq["firewall"]["zones"]:
    if zone["name"] == "wan":
        zone["masq"] = False
Path(sys.argv[3]).write_text(json.dumps(no_masq))
conflict = copy.deepcopy(source)
conflict["dsa"]["bridge_vlans"] = [{
    "section": "existing_provider",
    "device": "br-lan",
    "vlan": 10,
    "ports": ["lan2:t"],
}]
Path(sys.argv[4]).write_text(json.dumps(conflict))
PY
for openwrt_failure in pending no-masq vlan-conflict; do
  if python3 scripts/internal/render-openwrt-plan.py \
    --inventory "$openwrt_inventory" \
    --openstack-plan inventory/openstack-plan.yml \
    --cluster-config inventory/openstack-cluster.yml \
    --discovery "$work_dir/openwrt-${openwrt_failure}.json" \
    --output-dir "$work_dir/openwrt-${openwrt_failure}-output" \
    >"$work_dir/openwrt-${openwrt_failure}.stdout" \
    2>"$work_dir/openwrt-${openwrt_failure}.stderr"; then
    echo "Unsafe OpenWrt ${openwrt_failure} fixture unexpectedly passed." >&2
    exit 1
  fi
done
grep -q 'uncommitted UCI changes in network' "$work_dir/openwrt-pending.stderr"
grep -q 'wan firewall zone must have masquerading enabled' "$work_dir/openwrt-no-masq.stderr"
grep -q 'unmanaged bridge-vlan section existing_provider conflicts' "$work_dir/openwrt-vlan-conflict.stderr"

python3 - "$openwrt_discovery" "$work_dir/openwrt-armed.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
data["rollback_guard"] = {"armed": True, "change_id": "openwrt-existing-transaction"}
Path(sys.argv[2]).write_text(json.dumps(data))
PY
cp "$openwrt_output/plan.json" "$work_dir/openwrt-preserved-plan.json"
if python3 scripts/internal/render-openwrt-plan.py \
  --inventory "$openwrt_inventory" \
  --openstack-plan inventory/openstack-plan.yml \
  --cluster-config inventory/openstack-cluster.yml \
  --discovery "$work_dir/openwrt-armed.json" \
  --output-dir "$openwrt_output" \
  >"$work_dir/openwrt-armed.stdout" 2>"$work_dir/openwrt-armed.stderr"; then
  echo 'An OpenWrt plan overwrote an armed rollback transaction.' >&2
  exit 1
fi
grep -q 'rollback guard openwrt-existing-transaction is armed' "$work_dir/openwrt-armed.stderr"
cmp "$work_dir/openwrt-preserved-plan.json" "$openwrt_output/plan.json"

python3 - <<'PY'
from pathlib import Path

apply = Path("ansible/playbooks/openwrt/apply-openwrt.yml").read_text()
cleanup = Path("ansible/playbooks/openwrt/cleanup-openwrt-prearm.yml").read_text()
probe = Path("ansible/playbooks/openwrt/probe-openstack-provider.yml").read_text()
discovery_playbook = Path("ansible/playbooks/openwrt/discover-openwrt.yml").read_text()
assert "['scp', '-O', '-P'" in apply
assert 'uci -q changes "${config}"' in apply
assert "USE_PROCD=1" in apply and "FINALIZE_LOCK" in apply
assert "APPLY_LOCK" in apply and "Atomically stage, validate, and commit" in apply
assert 'if [ "${remaining}" -gt "${duration}" ]' in apply
assert "lock_handed_off=1" in apply and "cleanup_reload_lock" in apply
assert 'test -s "${transaction}/GUARD_PID"' in apply
assert 'wait-and-rollback.sh"' in apply and 'kill -0 "${guard_pid}"' in apply
assert "FAILED_PRE_ARM" in cleanup and "ATTEMPT_ID" in cleanup
for service in ("network", "firewall", "dnsmasq", "odhcpd"):
    assert f"openwrt-rollback-{service}.log 2>&1 || true" not in apply
assert "The provider interface already has an IPv4 address." in probe
assert "failed_when: openwrt_provider_address_removed.rc != 0" in probe
assert "provider.deployed" in probe and "port-to-br" in probe
assert "rollback_guard_change_id=(.*)$', '\\\\1')" in discovery_playbook
wrapper = Path("scripts/internal/openwrt-router.sh").read_text()
assert "provider_probe_limit" not in wrapper
assert '"$repo_dir/ansible/playbooks/openwrt/probe-openstack-provider.yml"' in wrapper
assert "flock -n 9" in wrapper and "cleanup-openwrt-prearm.yml" in wrapper
PY

ansible_inventory_bin=$(find_optional_executable ansible-inventory || true)
ansible_playbook_bin=$(find_optional_executable ansible-playbook || true)
if [[ -n $ansible_inventory_bin && -n $ansible_playbook_bin ]]; then
  export ANSIBLE_CONFIG="$repo_dir/ansible/ansible.cfg"
  export ANSIBLE_LOCAL_TEMP="$work_dir/ansible-local"
  mkdir -p "$ANSIBLE_LOCAL_TEMP"
  cat >"$work_dir/ceph-inventory.yml" <<'YAML'
all:
  children:
    ceph_hosts:
      hosts:
        cloud01:
YAML
  "$ansible_inventory_bin" -i "$work_dir/topology-output/ansible-inventory.yml" --list >/dev/null
  mapfile -d '' ansible_playbooks < <(
    find ansible/playbooks -mindepth 2 -maxdepth 2 -type f -name '*.yml' -print0 | sort -z
  )
  (( ${#ansible_playbooks[@]} > 0 )) || {
    echo 'No Ansible playbooks found.' >&2
    exit 1
  }
  for playbook in "${ansible_playbooks[@]}"; do
    playbook_inventory="$work_dir/topology-output/ansible-inventory.yml"
    if [[ $playbook == *probe-openstack-provider.yml ]]; then
      :
    elif [[ $playbook == ansible/playbooks/openwrt/* ]]; then
      playbook_inventory="$openwrt_inventory"
    elif [[ $playbook == *prepare-openstack-kubernetes.yml ]]; then
      playbook_inventory="$kubespray_repo/.cache/kubespray-inventory/openstack/hosts.yml"
    elif [[ $playbook == *verify-ceph-devices.yml ]]; then
      playbook_inventory="$work_dir/ceph-inventory.yml"
    fi
    "$ansible_playbook_bin" -i "$playbook_inventory" "$playbook" --syntax-check >/dev/null
  done
else
  notice 'Ansible executables are unavailable; structural YAML and generated inventory checks passed.'
fi

# Exercise isolated workload roots without contacting OpenStack. The fake CLI
# verifies the wrapper's state separation, plan confirmation and argument flow.
workload_repo="$work_dir/workload-repo"
mkdir -p \
  "$workload_repo/scripts/internal" \
  "$workload_repo/config" \
  "$workload_repo/ansible/inventory/workloads" \
  "$workload_repo/ansible/playbooks/workloads" \
  "$workload_repo/terraform/modules" \
  "$workload_repo/terraform/workloads" \
  "$workload_repo/.cache/terraform/bin"
cp scripts/internal/terraform-workload.sh "$workload_repo/scripts/internal/"
cp scripts/internal/render-workload-ansible-inventory.py "$workload_repo/scripts/internal/"
cp config/versions.env "$workload_repo/config/"
cp ansible/inventory/workloads/settings.example.yml \
  "$workload_repo/ansible/inventory/workloads/"
cp -a terraform/modules/openstack-vm "$workload_repo/terraform/modules/"
cp -a terraform/workloads/_template "$workload_repo/terraform/workloads/"
printf 'fake certificate authority\n' >"$workload_repo/ca.pem"
cat >"$workload_repo/cloud-a.yaml" <<YAML
clouds:
  admin:
    region_name: RegionOne
    cacert: $workload_repo/ca.pem
YAML
cat >"$workload_repo/cloud-b.yaml" <<'YAML'
clouds:
  admin:
    region_name: RegionTwo
YAML
cat >"$workload_repo/cloud-relative-cert.yaml" <<'YAML'
clouds:
  admin:
    cacert: ca.pem
YAML
mkdir "$workload_repo/terraform/workloads/_template/.terraform"
printf 'template state must never be copied\n' > \
  "$workload_repo/terraform/workloads/_template/terraform.tfstate"
printf 'template provider cache must never be copied\n' > \
  "$workload_repo/terraform/workloads/_template/.terraform/provider-sentinel"
printf 'template credential must never be copied\n' > \
  "$workload_repo/terraform/workloads/_template/clouds.yaml"
printf 'template override must never be copied\n' > \
  "$workload_repo/terraform/workloads/_template/override.tf"
cat >"$workload_repo/.cache/terraform/bin/terraform" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "$0")/../../../" && pwd)
source "$repo_dir/config/versions.env"

if [[ ${1:-} == version && ${2:-} == -json ]]; then
  printf '{"terraform_version":"%s"}\n' "$TERRAFORM_CLI_VERSION"
  exit 0
fi

workdir=
operation=
out_file=
for argument in "$@"; do
  case "$argument" in
    -chdir=*) workdir=${argument#-chdir=} ;;
    workspace) operation=workspace ;;
    show)
      if [[ $operation == workspace ]]; then
        operation=workspace-show
      else
        operation=show
      fi
      ;;
    init|plan|apply|output) operation=$argument ;;
    -out=*) out_file=${argument#-out=} ;;
  esac
done
[[ -n $workdir && -n $operation ]] || exit 2
printf 'cloud=%s args=%s\n' "${OS_CLIENT_CONFIG_FILE:-}" "$*" >>"$FAKE_TERRAFORM_LOG"

case "$operation" in
  init)
    mkdir -p "$workdir/.terraform"
    ;;
  workspace-show)
    if [[ -f $workdir/.terraform/environment ]]; then
      cat "$workdir/.terraform/environment"
    else
      printf 'default\n'
    fi
    ;;
  plan)
    [[ -n $out_file ]]
    printf 'fake plan for %s\n' "$*" >"$out_file"
    ;;
  show)
    printf 'fake saved plan\n'
    ;;
  apply)
    [[ " $* " == *" -parallelism=1 "* ]]
    : >"$workdir/terraform.tfstate"
    ;;
  output)
    if [[ " $* " == *" -json instances "* ]]; then
      stack=$(basename "$workdir")
      printf '{"node-01":{"instance_id":"instance-%s","instance_name":"%s-node-01","fixed_ips":["10.20.0.11"],"floating_ip":"198.51.100.61"}}\n' \
        "$stack" "$stack"
    else
      printf 'instances = {}\n'
    fi
    ;;
esac
SH
chmod 0755 "$workload_repo/scripts/internal/terraform-workload.sh" \
  "$workload_repo/scripts/internal/render-workload-ansible-inventory.py" \
  "$workload_repo/.cache/terraform/bin/terraform"
workload_cli="$workload_repo/scripts/internal/terraform-workload.sh"
fake_terraform="$workload_repo/.cache/terraform/bin/terraform"
fake_log="$workload_repo/terraform-calls.log"

if (cd "$workload_repo" && "$workload_cli" new ../escape >/dev/null 2>&1); then
  echo 'Workload wrapper accepted a path traversal stack name.' >&2
  exit 1
fi
if (cd "$workload_repo" && "$workload_cli" new _template >/dev/null 2>&1); then
  echo 'Workload wrapper accepted its template as a stack.' >&2
  exit 1
fi
if (cd "$workload_repo" && "$workload_cli" new UPPER >/dev/null 2>&1); then
  echo 'Workload wrapper accepted an uppercase stack name.' >&2
  exit 1
fi
if (cd "$workload_repo" && "$workload_cli" new aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1); then
  echo 'Workload wrapper accepted a stack name longer than 63 characters.' >&2
  exit 1
fi

(cd "$workload_repo" && "$workload_cli" new app >/dev/null)
(cd "$workload_repo" && "$workload_cli" new database >/dev/null)
for contaminated_path in \
  terraform.tfstate \
  .terraform/provider-sentinel \
  clouds.yaml \
  override.tf; do
  [[ ! -e $workload_repo/terraform/workloads/app/$contaminated_path ]]
  [[ ! -e $workload_repo/terraform/workloads/database/$contaminated_path ]]
done
[[ $(stat -c '%a' "$workload_repo/terraform/workloads/app/terraform.tfvars") == 600 ]]
[[ $(stat -c '%a' "$workload_repo/ansible/inventory/workloads/app.local.yml") == 600 ]]
chmod 0644 "$workload_repo/terraform/workloads/app/terraform.tfvars"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" plan app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted an insecure terraform.tfvars mode.' >&2
  exit 1
fi
chmod 0600 "$workload_repo/terraform/workloads/app/terraform.tfvars"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-relative-cert.yaml \
  TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" plan database >/dev/null 2>&1); then
  echo 'Workload wrapper accepted a relative certificate path from clouds.yaml.' >&2
  exit 1
fi

app_plan_output=$(
  cd "$workload_repo"
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
    "$workload_cli" plan app
)
app_plan="$workload_repo/.cache/terraform/workloads/app.tfplan"
app_context="$workload_repo/.cache/terraform/workloads/app.tfplan.context.json"
[[ -f $app_plan && $(stat -c '%a' "$app_plan") == 600 ]]
[[ -f $app_context && ! -L $app_context && $(stat -c '%a' "$app_context") == 600 ]]
app_digest=$(sha256sum "$app_plan" | cut -d' ' -f1)
grep -Fq "APPLY-TERRAFORM-WORKLOAD:app:$app_digest" <<<"$app_plan_output"
grep -Fq "\"plan_sha256\": \"$app_digest\"" "$app_context"
grep -Fq '"stack": "app"' "$app_context"

if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TF_CLI_ARGS_apply=-lock=false \
  TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  TERRAFORM_WORKLOAD_APPLY_CONFIRM="APPLY-TERRAFORM-WORKLOAD:app:$app_digest" \
  "$workload_cli" apply app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted ambient TF_CLI_ARGS_apply.' >&2
  exit 1
fi
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TF_DATA_DIR=.shared-terraform-data \
  TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted ambient TF_DATA_DIR.' >&2
  exit 1
fi
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TF_WORKSPACE=other \
  TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted ambient TF_WORKSPACE.' >&2
  exit 1
fi
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TF_VAR_flavor_id=unreviewed \
  TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted ambient TF_VAR input.' >&2
  exit 1
fi

for hidden_input in unreviewed.auto.tfvars override.tf; do
  printf 'enable_instances = true\n' > \
    "$workload_repo/terraform/workloads/app/$hidden_input"
  if (cd "$workload_repo" && \
    OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
    "$workload_cli" show app >/dev/null 2>&1); then
    echo "Workload wrapper accepted ignored Terraform input: $hidden_input" >&2
    exit 1
  fi
  rm "$workload_repo/terraform/workloads/app/$hidden_input"
done

printf 'other\n' >"$workload_repo/terraform/workloads/app/.terraform/environment"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted a non-default persisted Terraform workspace.' >&2
  exit 1
fi
rm "$workload_repo/terraform/workloads/app/.terraform/environment"

cat >"$workload_repo/terraform/workloads/app/secure.yaml" <<'YAML'
clouds:
  admin:
    auth:
      password: changed-after-plan
YAML
chmod 0600 "$workload_repo/terraform/workloads/app/secure.yaml"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null 2>&1); then
  echo 'Workload wrapper ignored a provider-discovered secure.yaml added after planning.' >&2
  exit 1
fi
rm "$workload_repo/terraform/workloads/app/secure.yaml"

cp "$workload_repo/ca.pem" "$workload_repo/ca.pem.original"
printf 'changed after plan\n' >>"$workload_repo/ca.pem"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null 2>&1); then
  echo 'Workload wrapper ignored certificate content changed after planning.' >&2
  exit 1
fi
mv "$workload_repo/ca.pem.original" "$workload_repo/ca.pem"

(
  exec 8<"$workload_repo/.cache/terraform/workloads"
  flock -n 8
  if cd "$workload_repo" && \
    OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
    "$workload_cli" show app >/dev/null 2>&1; then
    echo 'Workload wrapper ignored contention on the shared workload lock.' >&2
    exit 1
  fi
  flock -u 8
)

calls_before_context_rejection=$(wc -l <"$fake_log")
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-b.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null 2>&1); then
  echo 'Workload wrapper showed a plan under a different OpenStack credential context.' >&2
  exit 1
fi
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-b.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  TERRAFORM_WORKLOAD_APPLY_CONFIRM="APPLY-TERRAFORM-WORKLOAD:app:$app_digest" \
  "$workload_cli" apply app >/dev/null 2>&1); then
  echo 'Workload wrapper applied a plan under a different OpenStack credential context.' >&2
  exit 1
fi
calls_after_context_rejection=$(wc -l <"$fake_log")
[[ $calls_after_context_rejection == "$calls_before_context_rejection" ]] || {
  echo 'Workload wrapper ran Terraform init before rejecting a different credential context.' >&2
  exit 1
}

cp "$workload_repo/cloud-a.yaml" "$workload_repo/cloud-a.yaml.original"
printf '# changed after plan\n' >>"$workload_repo/cloud-a.yaml"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted a cloud configuration modified after planning.' >&2
  exit 1
fi
mv "$workload_repo/cloud-a.yaml.original" "$workload_repo/cloud-a.yaml"

(cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null)
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  TERRAFORM_WORKLOAD_APPLY_CONFIRM=wrong "$workload_cli" apply app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted an incorrect plan confirmation.' >&2
  exit 1
fi
(cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  TERRAFORM_WORKLOAD_APPLY_CONFIRM="APPLY-TERRAFORM-WORKLOAD:app:$app_digest" \
  "$workload_cli" apply app >/dev/null)
chmod 0644 "$workload_repo/terraform/workloads/app/terraform.tfstate"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" output app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted an insecure local Terraform state mode.' >&2
  exit 1
fi
chmod 0600 "$workload_repo/terraform/workloads/app/terraform.tfstate"
printf 'fake backup state\n' >"$workload_repo/terraform/workloads/app/terraform.tfstate.backup"
chmod 0644 "$workload_repo/terraform/workloads/app/terraform.tfstate.backup"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" show app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted an insecure Terraform state backup mode.' >&2
  exit 1
fi
rm "$workload_repo/terraform/workloads/app/terraform.tfstate.backup"
(cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" output app >/dev/null)
chmod 0644 "$workload_repo/ansible/inventory/workloads/app.local.yml"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" inventory app >/dev/null 2>&1); then
  echo 'Workload wrapper accepted insecure Ansible settings permissions.' >&2
  exit 1
fi
chmod 0600 "$workload_repo/ansible/inventory/workloads/app.local.yml"
(cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-a.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" inventory app >/dev/null)
workload_inventory="$workload_repo/.cache/ansible/workloads/app.yml"
[[ -f $workload_inventory && ! -L $workload_inventory ]]
[[ $(stat -c '%a' "$workload_inventory") == 600 ]]
python3 - "$workload_inventory" <<'PY'
import sys
from pathlib import Path

import yaml

inventory = yaml.safe_load(Path(sys.argv[1]).read_text())
workload = inventory["all"]["children"]["workload"]
assert workload["vars"]["workload_name"] == "app"
assert workload["vars"]["ansible_user"] == "ubuntu"
host = workload["hosts"]["app-node-01"]
assert host["ansible_host"] == "198.51.100.61"
assert host["terraform_instance_key"] == "node-01"
assert host["openstack_instance_id"] == "instance-app"
PY
ln -s ../app/.terraform "$workload_repo/terraform/workloads/database/.terraform"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-b.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" plan database >/dev/null 2>&1); then
  echo 'Workload wrapper accepted a shared symbolic-link Terraform data directory.' >&2
  exit 1
fi
rm "$workload_repo/terraform/workloads/database/.terraform"
ln -s ../app/terraform.tfstate \
  "$workload_repo/terraform/workloads/database/terraform.tfstate"
if (cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-b.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" plan database >/dev/null 2>&1); then
  echo 'Workload wrapper accepted a symbolic-link Terraform state.' >&2
  exit 1
fi
rm "$workload_repo/terraform/workloads/database/terraform.tfstate"
(cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-b.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" plan database >/dev/null)
[[ -f $workload_repo/.cache/terraform/workloads/database.tfplan ]]
[[ -f $workload_repo/.cache/terraform/workloads/database.tfplan.context.json ]]
(cd "$workload_repo" && \
  OS_CLIENT_CONFIG_FILE=cloud-b.yaml TERRAFORM_BIN="$fake_terraform" FAKE_TERRAFORM_LOG="$fake_log" \
  "$workload_cli" output database >/dev/null)
grep -Fq -- '-var=workload_name=app' "$fake_log"
grep -Fq -- '-var=workload_name=database' "$fake_log"
grep -Fq -- 'plan -input=false -lock=true' "$fake_log"
grep -Fq -- 'apply -input=false -lock=true -parallelism=1' "$fake_log"
grep -Fq "cloud=$workload_repo/cloud-a.yaml" "$fake_log"
grep -Fq "cloud=$workload_repo/cloud-b.yaml" "$fake_log"

terraform_bin=
[[ ! -x .cache/terraform/bin/terraform ]] || terraform_bin=.cache/terraform/bin/terraform
[[ -n $terraform_bin ]] || terraform_bin=$(command -v terraform || true)
[[ -n $terraform_bin ]] || [[ ! -x /tmp/terraform-bin/terraform ]] || terraform_bin=/tmp/terraform-bin/terraform
if [[ -n $terraform_bin ]]; then
  "$terraform_bin" -chdir=terraform fmt -check -recursive
  if [[ -d terraform/openstack/.terraform ]]; then
    if ! terraform_validate_output=$(
      "$terraform_bin" -chdir=terraform/openstack validate -no-color 2>&1
    ); then
      if grep -q 'Unrecognized remote plugin message' <<<"$terraform_validate_output"; then
        notice 'Terraform provider execution is restricted here; fmt passed and provider validation was skipped.'
      else
        printf '%s\n' "$terraform_validate_output" >&2
        exit 1
      fi
    fi
  else
    notice 'Terraform providers are not initialized; fmt passed and offline validate was skipped.'
  fi
else
  notice 'Terraform is unavailable; Terraform checks were skipped.'
fi

echo 'OpenStack repository checks passed.'
