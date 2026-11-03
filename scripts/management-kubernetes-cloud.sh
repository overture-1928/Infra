#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
command_name=${1:-help}
credential_name=${MANAGEMENT_CLOUD_CREDENTIAL_NAME:-kubespray-management}
principal_name=${MANAGEMENT_CLOUD_USER_NAME:-kubespray-management}
principal_role=${MANAGEMENT_CLOUD_ROLE_NAME:-member}
credentials_file="$repo_dir/kubeconfig/openstack-management.env"
clouds_file=${OS_CLIENT_CONFIG_FILE:-/etc/kolla/clouds.yaml}
cloud_name=${OS_CLOUD:-admin}
openstack_bin="$repo_dir/.cache/kolla-venv/bin/openstack"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_platform_profile() {
  "$repo_dir/scripts/render-openstack-cluster.py" >/dev/null
  python3 - "$repo_dir/.cache/cluster/cluster-plan.json" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1]))
if plan.get("node_count", 0) < 3:
    raise SystemExit("ERROR: management cloud integration requires at least three physical nodes")
if plan.get("storage_backend") != "ceph":
    raise SystemExit("ERROR: management cloud integration requires storage_backend=ceph")
if plan.get("platform", {}).get("magnum_capi", {}).get("enabled") is not True:
    raise SystemExit("ERROR: set cluster.platform.magnum_capi.enabled=true first")
PY
}

require_openstack() {
  [[ -x $openstack_bin ]] || fail 'OpenStack CLI is missing; run scripts/openstack.sh setup.'
  [[ -r $clouds_file ]] || fail "OpenStack clouds.yaml is missing or unreadable: $clouds_file"
  [[ $credential_name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail 'MANAGEMENT_CLOUD_CREDENTIAL_NAME contains unsupported characters.'
  [[ $principal_name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail 'MANAGEMENT_CLOUD_USER_NAME contains unsupported characters.'
  [[ $principal_role =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail 'MANAGEMENT_CLOUD_ROLE_NAME contains unsupported characters.'
  [[ $principal_role == member ]] || \
    fail 'MANAGEMENT_CLOUD_ROLE_NAME must remain member for the non-admin management principal.'
}

cloud_values() {
  python3 - "$clouds_file" "$cloud_name" <<'PY'
import sys
from pathlib import Path

import yaml

path = Path(sys.argv[1])
name = sys.argv[2]
data = yaml.safe_load(path.read_text()) or {}
cloud = data.get("clouds", {}).get(name)
if not isinstance(cloud, dict):
    raise SystemExit(f"ERROR: cloud {name!r} is missing from {path}")
auth = cloud.get("auth", {})
auth_url = str(auth.get("auth_url", "")).strip()
region = str(cloud.get("region_name", "RegionOne")).strip()
cacert = cloud.get("cacert", "")
if not cacert and isinstance(cloud.get("verify"), str):
    cacert = cloud["verify"]
cacert = str(cacert).strip()
for label, value in (("auth_url", auth_url), ("region_name", region)):
    if not value or any(character in value for character in "\n\r\0"):
        raise SystemExit(f"ERROR: invalid {label} in cloud {name!r}")
if any(character in cacert for character in "\n\r\0"):
    raise SystemExit(f"ERROR: invalid cacert in cloud {name!r}")
print(auth_url)
print(region)
print(cacert)
PY
}

create_credential() {
  require_platform_profile
  require_openstack
  command -v openssl >/dev/null || fail 'openssl is required.'
  [[ ! -e $credentials_file ]] || \
    fail "Credential file already exists: $credentials_file. Refusing to replace its one-time secret."

  export OS_CLIENT_CONFIG_FILE="$clouds_file"
  export OS_CLOUD="$cloud_name"
  local token_file project_id user_domain expected password password_file user_file
  local user_id user_domain_id principal_cloud credential_json credential_staging
  local -a values cloud_config_values
  token_file=$(mktemp "${TMPDIR:-/tmp}/openstack-management-token.XXXXXX")
  password_file=$(mktemp "${TMPDIR:-/tmp}/openstack-management-password.XXXXXX")
  user_file=$(mktemp "${TMPDIR:-/tmp}/openstack-management-user.XXXXXX")
  principal_cloud=$(mktemp "${TMPDIR:-/tmp}/openstack-management-cloud.XXXXXX")
  credential_json=$(mktemp "${TMPDIR:-/tmp}/openstack-management-credential.XXXXXX")
  cleanup_token_file=$token_file
  cleanup_password_file=$password_file
  cleanup_user_file=$user_file
  cleanup_principal_cloud=$principal_cloud
  cleanup_credential_json=$credential_json
  cleanup_credential_staging=
  cleanup_user_id=
  cleanup_user_domain_id=
  cleanup_user_created=0
  cleanup_credential_file_created=0
  cleanup_completed=0
  cleanup_create() {
    local status=$? rollback_user_id rollback_domain_id
    trap - EXIT
    if (( status != 0 && cleanup_completed == 0 )); then
      if (( cleanup_credential_file_created == 1 )); then
        rm -f -- "$credentials_file"
      fi
      if (( cleanup_user_created == 1 )); then
        rollback_user_id=$cleanup_user_id
        rollback_domain_id=$cleanup_user_domain_id
        if [[ -z $rollback_user_id && -s $cleanup_user_file ]]; then
          read -r rollback_user_id rollback_domain_id < <(python3 - "$cleanup_user_file" <<'PY'
import json
import sys

try:
    user = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    raise SystemExit(1)
print(str(user.get("id", "")), str(user.get("domain_id", "")))
PY
          ) || true
        fi
        if [[ -n $rollback_user_id ]]; then
          if ! OS_CLIENT_CONFIG_FILE="$clouds_file" OS_CLOUD="$cloud_name" \
            "$openstack_bin" user delete "$rollback_user_id" >/dev/null 2>&1; then
            printf 'ERROR: automatic cleanup could not delete newly created user ID %s in domain %s; review it manually.\n' \
              "$rollback_user_id" "$rollback_domain_id" >&2
          else
            printf 'Rolled back newly created management user after the failed operation.\n' >&2
          fi
        fi
      fi
    fi
    rm -f -- \
      "$cleanup_token_file" \
      "$cleanup_password_file" \
      "$cleanup_user_file" \
      "$cleanup_principal_cloud" \
      "$cleanup_credential_json" \
      "$cleanup_credential_staging"
    exit "$status"
  }
  trap cleanup_create EXIT
  "$openstack_bin" token issue -f json >"$token_file"
  read -r project_id user_domain < <(python3 - "$token_file" "$clouds_file" "$cloud_name" <<'PY'
import json
import sys
from pathlib import Path

import yaml

token = {str(k).lower().replace(" ", "_"): v for k, v in json.loads(Path(sys.argv[1]).read_text()).items()}
cloud = (yaml.safe_load(Path(sys.argv[2]).read_text()) or {}).get("clouds", {}).get(sys.argv[3], {})
project_id = str(token.get("project_id", "")).strip()
auth = cloud.get("auth", {})
domain = str(auth.get("user_domain_id") or auth.get("user_domain_name") or "").strip()
if not project_id or not domain or any(ch in project_id + domain for ch in "\n\r\0"):
    raise SystemExit(
        "ERROR: could not determine source project ID and explicit user_domain_id/user_domain_name"
    )
print(project_id, domain)
PY
  )
  if "$openstack_bin" user show "$principal_name" --domain "$user_domain" >/dev/null 2>&1; then
    fail "Dedicated user $principal_name already exists in domain $user_domain while the local secret is absent. Review it manually; this script will not reset or delete it."
  fi
  expected="CREATE-K8S-CLOUD-PRINCIPAL:${project_id}:${principal_name}:${principal_role}"
  [[ ${MANAGEMENT_CLOUD_CONFIRM:-} == "$expected" ]] || \
    fail "Set MANAGEMENT_CLOUD_CONFIRM='$expected' after reviewing the dedicated non-admin principal."

  "$openstack_bin" role show "$principal_role" >/dev/null
  password=$(openssl rand -hex 32)
  printf '%s' "$password" >"$password_file"
  chmod 0600 "$password_file"
  cleanup_user_created=1
  OS_CLIENT_CONFIG_FILE="$clouds_file" OS_CLOUD="$cloud_name" \
    "$repo_dir/.cache/kolla-venv/bin/python" - \
      "$clouds_file" "$cloud_name" "$principal_name" "$user_domain" \
      "$password_file" "$user_file" <<'PY'
import json
import sys
from pathlib import Path

from openstack.config import OpenStackConfig
from openstack.connection import Connection

clouds_file, cloud_name, username, domain_reference, password_file, output_file = sys.argv[1:]
password = Path(password_file).read_text()
if not password or any(character in password for character in "\n\r\0"):
    raise SystemExit("ERROR: generated management user password is invalid")
config = OpenStackConfig(
    config_files=[clouds_file],
    load_envvars=False,
).get_one_cloud(cloud_name)
connection = Connection(config=config)
domain = connection.identity.find_domain(domain_reference, ignore_missing=False)
user = None
try:
    user = connection.identity.create_user(
        name=username,
        domain_id=domain.id,
        password=password,
        description="Kubespray OpenStack CCM, Cinder CSI and Octavia",
        is_enabled=True,
    )
    Path(output_file).write_text(
        json.dumps({"id": user.id, "domain_id": user.domain_id}) + "\n"
    )
except BaseException:
    if user is not None:
        connection.identity.delete_user(user, ignore_missing=True)
    raise
PY
  mapfile -t values < <(python3 - "$user_file" <<'PY'
import json, sys
user = json.load(open(sys.argv[1]))
for key in ("id", "domain_id"):
    value = str(user.get(key, "")).strip()
    if not value or any(character in value for character in "\n\r\0"):
        raise SystemExit(f"ERROR: OpenStack did not return a valid user {key}")
    print(value)
PY
  )
  (( ${#values[@]} == 2 )) || fail 'Could not read the dedicated user ID and domain ID.'
  user_id=${values[0]}
  user_domain_id=${values[1]}
  cleanup_user_id=$user_id
  cleanup_user_domain_id=$user_domain_id
  "$openstack_bin" role add --user "$user_id" --project "$project_id" "$principal_role"

  python3 - "$clouds_file" "$cloud_name" "$principal_cloud" \
    "$principal_name" "$password_file" "$project_id" "$user_domain_id" <<'PY'
import copy
import sys
from pathlib import Path

import yaml

source, cloud_name, output, username, password_file, project_id, domain_id = sys.argv[1:]
password = Path(password_file).read_text()
data = yaml.safe_load(Path(source).read_text()) or {}
cloud = copy.deepcopy(data.get("clouds", {}).get(cloud_name))
if not isinstance(cloud, dict):
    raise SystemExit(f"ERROR: cloud {cloud_name!r} is missing")
auth_url = str(cloud.get("auth", {}).get("auth_url", "")).strip()
if not auth_url:
    raise SystemExit("ERROR: source cloud has no auth_url")
cloud["auth"] = {
    "auth_url": auth_url,
    "username": username,
    "password": password,
    "project_id": project_id,
    "user_domain_id": domain_id,
}
Path(output).write_text(yaml.safe_dump({"clouds": {"management-member": cloud}}, sort_keys=False))
PY
  chmod 0600 "$principal_cloud"
  OS_CLIENT_CONFIG_FILE="$principal_cloud" OS_CLOUD=management-member \
    "$openstack_bin" application credential create "$credential_name" \
      --restricted \
      --role "$principal_role" \
      --description 'Kubespray OpenStack CCM, Cinder CSI and Octavia' \
      -f json >"$credential_json"

  mapfile -t cloud_config_values < <(cloud_values)
  (( ${#cloud_config_values[@]} == 3 )) || fail 'Could not read auth_url, region_name and cacert from clouds.yaml.'
  mkdir -p "$(dirname -- "$credentials_file")"
  credential_staging=$(mktemp "$(dirname -- "$credentials_file")/.openstack-management.env.XXXXXX")
  cleanup_credential_staging=$credential_staging
  python3 - "$credential_json" "$credential_staging" \
    "${cloud_config_values[0]}" "${cloud_config_values[1]}" "${cloud_config_values[2]}" \
    "$credential_name" "$principal_name" "$principal_role" "$project_id" \
    "$user_id" "$user_domain_id" <<'PY'
import json
import shlex
import sys
from pathlib import Path

(
    source,
    output,
    auth_url,
    region,
    cacert,
    credential_name,
    principal_name,
    role_name,
    project_id,
    user_id,
    user_domain_id,
  ) = sys.argv[1:]
values = json.loads(Path(source).read_text())
normalized = {str(key).lower().replace(" ", "_"): value for key, value in values.items()}
credential_id = str(normalized.get("id", "")).strip()
secret = str(normalized.get("secret", "")).strip()
if not credential_id or not secret:
    raise SystemExit("ERROR: OpenStack did not return an application credential ID and secret")
environment = {
    "OS_AUTH_TYPE": "v3applicationcredential",
    "OS_AUTH_URL": auth_url,
    "OS_APPLICATION_CREDENTIAL_ID": credential_id,
    "OS_APPLICATION_CREDENTIAL_NAME": credential_name,
    "OS_APPLICATION_CREDENTIAL_SECRET": secret,
    "OS_REGION_NAME": region,
    "MANAGEMENT_CLOUD_USER_NAME": principal_name,
    "MANAGEMENT_CLOUD_ROLE_NAME": role_name,
    "MANAGEMENT_CLOUD_PROJECT_ID": project_id,
    "MANAGEMENT_CLOUD_USER_ID": user_id,
    "MANAGEMENT_CLOUD_USER_DOMAIN_ID": user_domain_id,
}
if cacert:
    environment["OS_CACERT"] = cacert
text = "\n".join(f"{key}={shlex.quote(value)}" for key, value in environment.items()) + "\n"
Path(output).write_text(text)
PY
  chmod 0600 "$credential_staging"
  if ! ln "$credential_staging" "$credentials_file"; then
    fail "Credential file appeared during creation or could not be published: $credentials_file"
  fi
  cleanup_credential_file_created=1
  rm -f -- "$credential_staging"
  cleanup_credential_staging=
  password=
  cleanup_completed=1
  printf 'Created dedicated OpenStack user %s with role %s in project %s.\n' \
    "$principal_name" "$principal_role" "$project_id"
  printf 'Created restricted application credential %s for that non-admin user.\n' "$credential_name"
  printf 'Credential environment: %s\n' "$credentials_file"
  printf 'The secret was not printed and will not be regenerated automatically.\n'
}

show_status() {
  require_openstack
  [[ -f $credentials_file ]] || fail "Credential environment is missing: $credentials_file"
  [[ $(stat -c '%a' "$credentials_file") == 600 ]] || fail 'Credential environment must have mode 0600.'
  python3 - "$credentials_file" <<'PY'
import sys
from pathlib import Path

required = {
    "OS_AUTH_TYPE",
    "OS_AUTH_URL",
    "OS_APPLICATION_CREDENTIAL_ID",
    "OS_APPLICATION_CREDENTIAL_NAME",
    "OS_APPLICATION_CREDENTIAL_SECRET",
    "OS_REGION_NAME",
    "MANAGEMENT_CLOUD_USER_NAME",
    "MANAGEMENT_CLOUD_ROLE_NAME",
    "MANAGEMENT_CLOUD_PROJECT_ID",
    "MANAGEMENT_CLOUD_USER_ID",
    "MANAGEMENT_CLOUD_USER_DOMAIN_ID",
}
keys = {
    line.split("=", 1)[0]
    for line in Path(sys.argv[1]).read_text().splitlines()
    if line and not line.startswith("#") and "=" in line
}
missing = sorted(required - keys)
if missing:
    raise SystemExit("ERROR: credential environment is missing: " + ", ".join(missing))
print("Credential file structure and mode are valid.")
PY
  local token_file user_json role_json
  local saved_credential_name saved_user_name saved_role saved_project_id saved_user_id saved_domain_id
  local -a metadata
  token_file=$(mktemp "${TMPDIR:-/tmp}/openstack-management-status.XXXXXX")
  trap 'rm -f -- "$token_file"' EXIT
  (
    set -a
    source "$credentials_file"
    set +a
    unset OS_CLOUD OS_CLIENT_CONFIG_FILE OS_USERNAME OS_PASSWORD OS_PROJECT_NAME OS_PROJECT_ID OS_TOKEN
    "$openstack_bin" token issue -f json >"$token_file"
  )
  mapfile -t metadata < <(python3 - "$credentials_file" <<'PY'
import shlex
import sys
from pathlib import Path

wanted = (
    "OS_APPLICATION_CREDENTIAL_NAME",
    "MANAGEMENT_CLOUD_USER_NAME",
    "MANAGEMENT_CLOUD_ROLE_NAME",
    "MANAGEMENT_CLOUD_PROJECT_ID",
    "MANAGEMENT_CLOUD_USER_ID",
    "MANAGEMENT_CLOUD_USER_DOMAIN_ID",
)
values = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, raw = line.split("=", 1)
    parsed = shlex.split(raw)
    if len(parsed) != 1:
        raise SystemExit(f"ERROR: invalid value for {key} in credential environment")
    values[key] = parsed[0]
for key in wanted:
    value = values.get(key, "")
    if not value or any(character in value for character in "\n\r\0"):
        raise SystemExit(f"ERROR: missing or unsafe {key} in credential environment")
    print(value)
PY
  )
  (( ${#metadata[@]} == 6 )) || fail 'Could not read saved management credential metadata.'
  saved_credential_name=${metadata[0]}
  saved_user_name=${metadata[1]}
  saved_role=${metadata[2]}
  saved_project_id=${metadata[3]}
  saved_user_id=${metadata[4]}
  saved_domain_id=${metadata[5]}
  [[ $saved_role == member ]] || fail 'Saved management credential role must be member.'

  python3 - "$token_file" "$saved_project_id" "$saved_user_id" <<'PY'
import json
import sys

token = {str(key).lower().replace(" ", "_"): value for key, value in json.load(open(sys.argv[1])).items()}
expected_project, expected_user = sys.argv[2:]
if str(token.get("project_id", "")) != expected_project:
    raise SystemExit("ERROR: application credential token uses an unexpected project")
if str(token.get("user_id", "")) != expected_user:
    raise SystemExit("ERROR: application credential token uses an unexpected user")
PY
  user_json=$(OS_CLIENT_CONFIG_FILE="$clouds_file" OS_CLOUD="$cloud_name" \
    "$openstack_bin" user show "$saved_user_id" -f json)
  USER_JSON="$user_json" python3 - "$saved_user_name" "$saved_domain_id" <<'PY'
import json
import os
import sys

user = {
    str(key).lower().replace(" ", "_"): value
    for key, value in json.loads(os.environ["USER_JSON"]).items()
}
expected_name, expected_domain = sys.argv[1:]
if str(user.get("name", "")) != expected_name or str(user.get("domain_id", "")) != expected_domain:
    raise SystemExit("ERROR: saved management user metadata does not match OpenStack")
enabled = user.get("enabled", user.get("is_enabled"))
if str(enabled).lower() not in {"true", "1"}:
    raise SystemExit("ERROR: saved management user is disabled")
PY
  role_json=$(OS_CLIENT_CONFIG_FILE="$clouds_file" OS_CLOUD="$cloud_name" \
    "$openstack_bin" role assignment list \
      --user "$saved_user_id" --project "$saved_project_id" --names -f json)
  ROLE_JSON="$role_json" python3 - "$saved_role" <<'PY'
import json
import os
import sys

rows = json.loads(os.environ["ROLE_JSON"])
roles = {
    str(row.get("Role", row.get("role", ""))).split("@", 1)[0]
    for row in rows
}
expected = sys.argv[1]
if len(rows) != 1 or roles != {expected}:
    raise SystemExit(
        f"ERROR: management user must have exactly one {expected!r} role assignment; "
        f"found {len(rows)} assignment(s) with roles {sorted(roles)}"
    )
PY
  rm -f -- "$token_file"
  trap - EXIT
  printf 'Dedicated application credential authentication and metadata verified: %s\n' \
    "$saved_credential_name"
}

case "$command_name" in
  help)
    cat <<'HELP'
Usage: scripts/management-kubernetes-cloud.sh COMMAND

  create-credential  create a dedicated member user and save its application credential once
  status             verify the saved file and OpenStack credential metadata

Set OS_CLIENT_CONFIG_FILE and OS_CLOUD to an operator-readable admin cloud.
create-credential prints the exact MANAGEMENT_CLOUD_CONFIRM value before it
creates a non-admin user in the current project. No command prints the secret,
rotates credentials, resets users, or deletes existing resources. A failed
creation attempt rolls back only the dedicated user created by that attempt.
HELP
    ;;
  create-credential)
    create_credential
    ;;
  status)
    show_status
    ;;
  *)
    fail "Unknown command: $command_name"
    ;;
esac
