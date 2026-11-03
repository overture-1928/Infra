#!/usr/bin/env bash
set -euo pipefail

umask 077

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$repo_dir/config/versions.env"

terraform_bin=${TERRAFORM_BIN:-$repo_dir/.cache/terraform/bin/terraform}
workloads_dir="$repo_dir/terraform/workloads"
template_dir="$workloads_dir/_template"
cache_dir="$repo_dir/.cache/terraform/workloads"
template_files=(
  .terraform.lock.hcl
  README.md
  main.tf
  outputs.tf
  providers.tf
  terraform.tfvars.example
  variables.tf
  versions.tf
)

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
Usage: scripts/internal/terraform-workload.sh COMMAND [STACK]

  new STACK      copy terraform/workloads/_template into a new workload stack
  plan STACK     initialize the stack and save a reviewable Terraform plan
  show STACK     show the saved plan and its SHA-256 confirmation value
  apply STACK    apply the exact saved plan serially (confirmation required)
  output STACK   show outputs from the stack's Terraform state
  help           show this help

STACK must be 1-63 characters and match ^[a-z0-9][a-z0-9-]{0,62}$;
_template cannot be operated on.
OpenStack credentials are read from OS_CLIENT_CONFIG_FILE, which defaults to
/etc/kolla/clouds.yaml.
Terraform ambient arguments, TF_VAR inputs, custom TF_DATA_DIR and non-default
workspaces are rejected; edit the stack files and terraform.tfvars instead.

After reviewing `plan` or `show`, apply with the exact value they print:
  TERRAFORM_WORKLOAD_APPLY_CONFIRM='APPLY-TERRAFORM-WORKLOAD:<stack>:<sha256>' \
    scripts/internal/terraform-workload.sh apply <stack>

Saved plans:    .cache/terraform/workloads/<stack>.tfplan
Plan context:   .cache/terraform/workloads/<stack>.tfplan.context.json
Default state:  terraform/workloads/<stack>/terraform.tfstate
HELP
}

validate_stack_name() {
  local stack=$1
  [[ $stack != _template ]] || fail '_template is a source template and cannot be used as a workload stack.'
  [[ $stack =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || \
    fail "Invalid stack name '$stack'; expected 1-63 lowercase letters, numbers or hyphens, starting with a letter or number."
}

require_stack_argument() {
  local operation=$1
  shift
  [[ $# -eq 1 ]] || fail "Usage: scripts/internal/terraform-workload.sh $operation STACK"
  validate_stack_name "$1"
}

stack_path() {
  printf '%s/%s\n' "$workloads_dir" "$1"
}

plan_path() {
  printf '%s/%s.tfplan\n' "$cache_dir" "$1"
}

plan_context_path() {
  printf '%s/%s.tfplan.context.json\n' "$cache_dir" "$1"
}

require_stack() {
  local stack=$1
  local directory required_file tfvars_mode local_state forbidden_input terraform_data persisted_workspace
  directory=$(stack_path "$stack")
  [[ -d $directory && ! -L $directory ]] || \
    fail "Workload stack does not exist: $directory. Run workload-new first."
  for required_file in main.tf versions.tf providers.tf variables.tf outputs.tf .terraform.lock.hcl terraform.tfvars; do
    [[ -f $directory/$required_file && ! -L $directory/$required_file ]] || \
      fail "Workload stack file is missing or is a symbolic link: $directory/$required_file"
  done
  tfvars_mode=$(stat -c '%a' "$directory/terraform.tfvars")
  [[ $tfvars_mode == 600 ]] || \
    fail "Workload variables must use mode 0600: $directory/terraform.tfvars (found $tfvars_mode)."
  while IFS= read -r -d '' forbidden_input; do
    fail "Remove ignored Terraform auto-loaded or override input from the workload root: $forbidden_input"
  done < <(
    find "$directory" -maxdepth 1 \( -type f -o -type l \) \
      \( -name terraform.tfvars.json \
      -o -name '*.auto.tfvars' \
      -o -name '*.auto.tfvars.json' \
      -o -name override.tf \
      -o -name override.tf.json \
      -o -name '*_override.tf' \
      -o -name '*_override.tf.json' \) \
      -print0
  )
  terraform_data="$directory/.terraform"
  if [[ -e $terraform_data || -L $terraform_data ]]; then
    [[ -d $terraform_data && ! -L $terraform_data ]] || \
      fail "Terraform data path must be a real directory inside its workload root: $terraform_data"
    if [[ -e $terraform_data/terraform.tfstate || -L $terraform_data/terraform.tfstate ]]; then
      require_private_regular_file "$terraform_data/terraform.tfstate" \
        'Terraform backend metadata'
    fi
    if [[ -e $terraform_data/environment || -L $terraform_data/environment ]]; then
      [[ -f $terraform_data/environment && ! -L $terraform_data/environment ]] || \
        fail "Terraform workspace metadata must be a regular file: $terraform_data/environment"
      persisted_workspace=$(<"$terraform_data/environment")
      [[ $persisted_workspace == default ]] || \
        fail "Workload roots require Terraform's default workspace; found '$persisted_workspace' in $terraform_data/environment."
    fi
  fi
  for local_state in "$directory/terraform.tfstate" "$directory/terraform.tfstate.backup"; do
    if [[ -e $local_state || -L $local_state ]]; then
      require_private_regular_file "$local_state" 'Local Terraform state'
    fi
  done
}

require_terraform() {
  [[ -x $terraform_bin ]] || \
    fail 'Run scripts/cluster.sh setup to install the pinned Terraform CLI.'

  local actual
  actual=$(
    "$terraform_bin" version -json 2>/dev/null |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || true
  )
  [[ $actual == "$TERRAFORM_CLI_VERSION" ]] || \
    fail "Expected Terraform $TERRAFORM_CLI_VERSION at $terraform_bin; found ${actual:-unknown}."
}

reject_unsafe_terraform_environment() {
  local variable
  while IFS= read -r variable; do
    case "$variable" in
      TF_CLI_ARGS|TF_CLI_ARGS_*|TF_DATA_DIR|TF_REATTACH_PROVIDERS|TF_WORKSPACE|TF_VAR_*)
        fail "Unset $variable; workload commands use reviewed files, the default workspace and wrapper-controlled Terraform arguments."
        ;;
    esac
  done < <(compgen -e)
}

normalize_openstack_file_environment() {
  local variable value resolved
  for variable in OS_CACERT OS_CERT OS_KEY; do
    value=${!variable-}
    [[ -n $value ]] || continue
    [[ -f $value && -r $value ]] || \
      fail "$variable does not name a readable regular file: $value"
    resolved=$(readlink -f -- "$value") || fail "Could not resolve $variable: $value"
    [[ -f $resolved && -r $resolved ]] || \
      fail "$variable does not resolve to a readable regular file: $resolved"
    printf -v "$variable" '%s' "$resolved"
    export "$variable"
  done
}

prepare_terraform_environment() {
  local stack=$1
  local cloud_config

  reject_unsafe_terraform_environment
  require_stack "$stack"
  require_terraform
  cloud_config=${OS_CLIENT_CONFIG_FILE:-/etc/kolla/clouds.yaml}
  [[ -f $cloud_config && -r $cloud_config ]] || \
    fail "OpenStack cloud configuration is not readable: $cloud_config"
  cloud_config=$(readlink -f -- "$cloud_config") || \
    fail "Could not resolve OpenStack cloud configuration: $cloud_config"
  [[ -f $cloud_config && -r $cloud_config ]] || \
    fail "Resolved OpenStack cloud configuration is not readable: $cloud_config"
  export OS_CLIENT_CONFIG_FILE=$cloud_config
  normalize_openstack_file_environment
}

initialize_terraform() {
  local stack=$1 directory workspace
  directory=$(stack_path "$stack")

  "$terraform_bin" -chdir="$directory" init -input=false -lockfile=readonly
  require_stack "$stack"
  workspace=$("$terraform_bin" -chdir="$directory" workspace show)
  [[ $workspace == default ]] || \
    fail "Workload roots require Terraform's default workspace; found '$workspace' in $directory."
}

ensure_cache_directory() {
  local component
  for component in "$repo_dir/.cache" "$repo_dir/.cache/terraform" "$cache_dir"; do
    [[ ! -L $component ]] || fail "Workload cache path must not be a symbolic link: $component"
    if [[ -e $component ]]; then
      [[ -d $component ]] || fail "Workload cache path is not a directory: $component"
    else
      mkdir -m 0700 -- "$component"
    fi
  done
  chmod 0700 "$cache_dir"
}

acquire_workload_lock() {
  command -v flock >/dev/null 2>&1 || fail 'flock is required to serialize workload Terraform operations.'
  ensure_cache_directory
  exec 9<"$cache_dir"
  flock -n 9 || fail 'Another workload plan, show, apply or output operation holds the shared workload Terraform lock.'
}

require_private_regular_file() {
  local file=$1 label=$2 mode
  [[ -f $file && ! -L $file ]] || fail "$label is missing or is a symbolic link: $file"
  mode=$(stat -c '%a' "$file")
  [[ $mode == 600 ]] || fail "$label must use mode 0600: $file (found $mode)."
}

cloud_context_digest() {
  local stack=$1 directory
  directory=$(stack_path "$stack")
  python3 - "$OS_CLIENT_CONFIG_FILE" "$directory" <<'PY'
import hashlib
import os
import pathlib
import pwd
import sys

try:
    import yaml
except ImportError:
    raise SystemExit("python3-yaml is required to fingerprint OpenStack credential files")


digest = hashlib.sha256()
seen_files = set()


def add(label, value):
    label_bytes = label.encode("utf-8", "surrogateescape")
    value_bytes = value if isinstance(value, bytes) else value.encode("utf-8", "surrogateescape")
    digest.update(len(label_bytes).to_bytes(8, "big"))
    digest.update(label_bytes)
    digest.update(len(value_bytes).to_bytes(8, "big"))
    digest.update(value_bytes)


def add_file(label, raw_path, required=False):
    path = pathlib.Path(raw_path).expanduser()
    if not path.is_absolute():
        path = pathlib.Path.cwd() / path
    try:
        resolved = path.resolve(strict=True)
    except FileNotFoundError:
        if required:
            raise SystemExit(f"required OpenStack context file is missing: {path}")
        return None
    if not resolved.is_file():
        raise SystemExit(f"OpenStack context path is not a regular file: {resolved}")
    key = str(resolved)
    if key in seen_files:
        return resolved
    seen_files.add(key)
    add(f"{label}:path", key)
    add(f"{label}:content", resolved.read_bytes())
    return resolved


config = pathlib.Path(sys.argv[1]).resolve(strict=True)
stack_directory = pathlib.Path(sys.argv[2]).resolve(strict=True)
add_file("cloud-config", config, required=True)
config_documents = [config]

for name, value in sorted(os.environ.items()):
    if name.startswith("OS_"):
        add(f"environment:{name}", value)

try:
    user_config_directory = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir) / ".config/openstack"
except KeyError:
    user_config_directory = None

provider_search_directories = [stack_directory]
if user_config_directory is not None:
    provider_search_directories.append(user_config_directory)
provider_search_directories.append(pathlib.Path("/etc/openstack"))


def add_provider_discovered_file(label, filenames):
    for filename in filenames:
        for directory in provider_search_directories:
            candidate = directory / filename
            if candidate.exists():
                resolved = add_file(f"provider-{label}:{filename}", candidate, required=True)
                config_documents.append(resolved)
                return


add_provider_discovered_file("secure-config", ("secure.yaml", "secure.yml"))
add_provider_discovered_file("public-config", ("clouds-public.yaml", "clouds-public.yml"))

for variable in ("OS_CACERT", "OS_CERT", "OS_KEY"):
    value = os.environ.get(variable)
    if value:
        add_file(f"environment-file:{variable}", value, required=True)


credential_path_keys = {
    "cacert",
    "cert",
    "key",
    "client_cert",
    "client_key",
    "client_certificate",
    "client_private_key",
    "verify",
}


def add_referenced_files(value, source, key_path=()):
    if isinstance(value, dict):
        for raw_key, child in value.items():
            key = str(raw_key).lower().replace("-", "_")
            child_path = (*key_path, key)
            if key in credential_path_keys and isinstance(child, str):
                if key == "verify" and child.strip().lower() in {
                    "true", "false", "yes", "no", "1", "0"
                }:
                    continue
                referenced = pathlib.Path(child).expanduser()
                if not referenced.is_absolute():
                    location = ".".join(child_path)
                    raise SystemExit(
                        f"OpenStack credential file reference {location} in {source} must be absolute: {child}"
                    )
                add_file(
                    f"config-reference:{source.name}:{'.'.join(child_path)}",
                    referenced,
                    required=True,
                )
            add_referenced_files(child, source, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            add_referenced_files(child, source, (*key_path, str(index)))


for document_path in dict.fromkeys(config_documents):
    try:
        with document_path.open(encoding="utf-8") as handle:
            documents = list(yaml.safe_load_all(handle))
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        raise SystemExit(f"could not parse OpenStack context file {document_path}: {exc}")
    for document in documents:
        add_referenced_files(document, document_path)

print(digest.hexdigest())
PY
}

write_plan_context() {
  local output=$1 stack=$2 plan_digest=$3 cloud_digest=$4
  python3 - "$output" "$stack" "$plan_digest" "$cloud_digest" <<'PY'
import json
import os
import sys


path, stack, plan_digest, cloud_digest = sys.argv[1:]
payload = {
    "version": 1,
    "stack": stack,
    "plan_sha256": plan_digest,
    "cloud_context_sha256": cloud_digest,
}
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(path, flags, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

require_saved_plan() {
  local stack=$1 plan context
  plan=$(plan_path "$stack")
  context=$(plan_context_path "$stack")
  require_private_regular_file "$plan" 'Saved plan'
  require_private_regular_file "$context" 'Saved plan context'
}

verify_plan_context() {
  local stack=$1 plan context plan_digest cloud_digest
  plan=$(plan_path "$stack")
  context=$(plan_context_path "$stack")
  plan_digest=$(sha256_file "$plan")
  cloud_digest=$(cloud_context_digest "$stack")
  if ! python3 - "$context" "$stack" "$plan_digest" "$cloud_digest" <<'PY'
import json
import sys


path, stack, plan_digest, cloud_digest = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)

expected = {
    "version": 1,
    "stack": stack,
    "plan_sha256": plan_digest,
    "cloud_context_sha256": cloud_digest,
}
raise SystemExit(0 if payload == expected else 1)
PY
  then
    fail 'The saved plan does not match its plan context or the current OpenStack credential context; run workload-plan and review it again.'
  fi
}

sha256_file() {
  local file=$1 digest
  command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required.'
  read -r digest _ < <(sha256sum -- "$file")
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "Could not calculate SHA-256 for $file."
  printf '%s\n' "$digest"
}

print_confirmation() {
  local stack=$1 plan=$2 digest
  digest=$(sha256_file "$plan")
  printf 'Plan SHA-256: %s\n' "$digest"
  printf "Apply confirmation: TERRAFORM_WORKLOAD_APPLY_CONFIRM='APPLY-TERRAFORM-WORKLOAD:%s:%s'\n" \
    "$stack" "$digest"
}

new_stack() {
  local stack=$1 directory template_file cleanup_command
  directory=$(stack_path "$stack")

  [[ -d $template_dir && ! -L $template_dir ]] || \
    fail "Workload template is missing: $template_dir"
  [[ ! -e $directory && ! -L $directory ]] || fail "Workload stack already exists: $directory"
  for template_file in "${template_files[@]}"; do
    [[ -f $template_dir/$template_file && ! -L $template_dir/$template_file ]] || \
      fail "Required workload template file is missing or is a symbolic link: $template_dir/$template_file"
  done

  mkdir -p "$workloads_dir"
  mkdir "$directory"
  printf -v cleanup_command 'rm -rf -- %q' "$directory"
  trap "$cleanup_command" EXIT
  for template_file in "${template_files[@]}"; do
    if ! cp -p -- "$template_dir/$template_file" "$directory/$template_file"; then
      fail "Could not copy the workload template into $directory."
    fi
  done
  install -m 0600 "$directory/terraform.tfvars.example" "$directory/terraform.tfvars"
  trap - EXIT

  printf 'Created workload stack: %s\n' "$directory"
  printf 'Edit %s, then run scripts/cluster.sh workload-plan %s.\n' \
    "$directory/terraform.tfvars" "$stack"
}

plan_stack() {
  local stack=$1 directory plan context temporary_plan temporary_context cleanup_command
  local cloud_digest_before cloud_digest_after plan_digest
  directory=$(stack_path "$stack")
  plan=$(plan_path "$stack")
  context=$(plan_context_path "$stack")
  temporary_plan="$plan.tmp.$$"
  temporary_context="$context.tmp.$$"

  acquire_workload_lock
  prepare_terraform_environment "$stack"
  cloud_digest_before=$(cloud_context_digest "$stack")
  initialize_terraform "$stack"
  [[ $(cloud_context_digest "$stack") == "$cloud_digest_before" ]] || \
    fail 'The OpenStack credential context changed while Terraform was initializing; run workload-plan again.'
  rm -f -- "$temporary_plan" "$temporary_context"
  printf -v cleanup_command 'rm -f -- %q %q' "$temporary_plan" "$temporary_context"
  trap "$cleanup_command" EXIT
  "$terraform_bin" -chdir="$directory" \
    plan -input=false -lock=true -var="workload_name=$stack" -out="$temporary_plan"
  chmod 0600 "$temporary_plan"
  cloud_digest_after=$(cloud_context_digest "$stack")
  [[ $cloud_digest_after == "$cloud_digest_before" ]] || \
    fail 'The OpenStack credential context changed while Terraform was planning; run workload-plan again.'
  plan_digest=$(sha256_file "$temporary_plan")
  write_plan_context "$temporary_context" "$stack" "$plan_digest" "$cloud_digest_after"
  mv -f -- "$temporary_plan" "$plan"
  mv -f -- "$temporary_context" "$context"
  trap - EXIT

  printf 'Saved workload plan: %s\n' "$plan"
  printf 'Saved plan context: %s\n' "$context"
  print_confirmation "$stack" "$plan"
  flock -u 9
}

show_stack() {
  local stack=$1 directory plan
  directory=$(stack_path "$stack")
  plan=$(plan_path "$stack")

  acquire_workload_lock
  require_saved_plan "$stack"
  prepare_terraform_environment "$stack"
  verify_plan_context "$stack"
  initialize_terraform "$stack"
  verify_plan_context "$stack"
  "$terraform_bin" -chdir="$directory" show "$plan"
  verify_plan_context "$stack"
  print_confirmation "$stack" "$plan"
  flock -u 9
}

apply_stack() {
  local stack=$1 directory plan digest expected
  directory=$(stack_path "$stack")
  plan=$(plan_path "$stack")

  acquire_workload_lock
  require_stack "$stack"
  require_saved_plan "$stack"
  digest=$(sha256_file "$plan")
  expected="APPLY-TERRAFORM-WORKLOAD:$stack:$digest"
  [[ ${TERRAFORM_WORKLOAD_APPLY_CONFIRM:-} == "$expected" ]] || \
    fail "Set TERRAFORM_WORKLOAD_APPLY_CONFIRM='$expected' after reviewing workload-show."

  prepare_terraform_environment "$stack"
  verify_plan_context "$stack"
  initialize_terraform "$stack"
  verify_plan_context "$stack"
  [[ $(sha256_file "$plan") == "$digest" ]] || \
    fail 'The saved plan changed after confirmation; run workload-plan and review it again.'
  "$terraform_bin" -chdir="$directory" \
    apply -input=false -lock=true -parallelism=1 "$plan"
  require_stack "$stack"
  flock -u 9
}

output_stack() {
  local stack=$1 directory
  directory=$(stack_path "$stack")

  acquire_workload_lock
  require_stack "$stack"
  prepare_terraform_environment "$stack"
  initialize_terraform "$stack"
  "$terraform_bin" -chdir="$directory" output
  flock -u 9
}

command_name=${1:-help}
if [[ $# -gt 0 ]]; then
  shift
fi

case "$command_name" in
  help|-h|--help)
    [[ $# -eq 0 ]] || fail 'The help command takes no arguments.'
    usage
    ;;
  new)
    require_stack_argument new "$@"
    new_stack "$1"
    ;;
  plan)
    require_stack_argument plan "$@"
    plan_stack "$1"
    ;;
  show)
    require_stack_argument show "$@"
    show_stack "$1"
    ;;
  apply)
    require_stack_argument apply "$@"
    apply_stack "$1"
    ;;
  output)
    require_stack_argument output "$@"
    output_stack "$1"
    ;;
  *)
    fail "Unknown command: $command_name. Run scripts/internal/terraform-workload.sh help."
    ;;
esac
