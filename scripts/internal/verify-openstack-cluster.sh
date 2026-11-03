#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
openstack_bin="$repo_dir/.cache/kolla-venv/bin/openstack"
plan="$repo_dir/.cache/cluster/cluster-plan.json"

[[ -x $openstack_bin ]] || { echo 'Run scripts/openstack.sh setup first.' >&2; exit 1; }
[[ -f $plan ]] || { echo 'Run scripts/openstack.sh render first.' >&2; exit 1; }
[[ -f /etc/kolla/clouds.yaml ]] || { echo '/etc/kolla/clouds.yaml is missing.' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl is required for the Skyline health check.' >&2; exit 1; }

export OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml
export OS_CLOUD=admin

"$openstack_bin" token issue >/dev/null
compute_services_json=$("$openstack_bin" compute service list --service nova-compute -f json)
actual_compute=$(
  COMPUTE_SERVICES_JSON="$compute_services_json" python3 - "$plan" <<'PY'
import json
import os
import sys

plan = json.load(open(sys.argv[1]))
expected = set(plan["roles"]["compute"])
rows = json.loads(os.environ["COMPUTE_SERVICES_JSON"])
by_host = {}
for row in rows:
    host = str(row.get("Host", row.get("host", "")))
    if host:
        by_host.setdefault(host, []).append(row)

errors = []
for host in sorted(expected):
    matches = by_host.get(host, [])
    if len(matches) != 1:
        errors.append(f"{host}: expected exactly one nova-compute service, found {len(matches)}")
        continue
    row = matches[0]
    status = str(row.get("Status", row.get("status", ""))).lower()
    state = str(row.get("State", row.get("state", ""))).lower()
    if status != "enabled" or state != "up":
        errors.append(f"{host}: nova-compute status={status or 'unknown'} state={state or 'unknown'}")

if errors:
    raise SystemExit("ERROR: topology compute verification failed:\n  " + "\n  ".join(errors))
extra = sorted(set(by_host) - expected)
if extra:
    print("WARNING: stale or extra nova-compute service rows: " + ", ".join(extra), file=sys.stderr)
print(len(expected))
PY
)

hypervisors_json=$("$openstack_bin" hypervisor list -f json)
HYPERVISORS_JSON="$hypervisors_json" python3 - "$plan" <<'PY'
import json
import os
import sys

expected = set(json.load(open(sys.argv[1]))["roles"]["compute"])
rows = json.loads(os.environ["HYPERVISORS_JSON"])
healthy = set()
for row in rows:
    host = str(
        row.get("Hypervisor Hostname", row.get("Hypervisor hostname", row.get("Host", "")))
    )
    state = str(row.get("State", row.get("state", "up"))).lower()
    status = str(row.get("Status", row.get("status", "enabled"))).lower()
    if state == "up" and status == "enabled":
        healthy.add(host)
missing = sorted(expected - healthy)
if missing:
    raise SystemExit("ERROR: enabled/up hypervisors missing for: " + ", ".join(missing))
PY

api_vip=$(python3 - "$plan" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["api_vip"])
PY
)
skyline_url="http://${api_vip}:9999"
curl --fail --silent --show-error --location --connect-timeout 5 --max-time 15 \
  "$skyline_url/" >/dev/null

"$openstack_bin" hypervisor list
"$openstack_bin" compute service list
"$openstack_bin" network agent list
"$openstack_bin" volume service list
echo "OpenStack API, $actual_compute topology compute service(s), and Skyline at $skyline_url passed verification."
