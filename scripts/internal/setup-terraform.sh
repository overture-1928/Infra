#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$repo_dir/config/versions.env"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for command_name in curl python3 sha256sum unzip; do
  command -v "$command_name" >/dev/null || fail "$command_name is required to install Terraform."
done

case $(uname -m) in
  x86_64)
    terraform_arch=amd64
    archive_sha256=$TERRAFORM_LINUX_AMD64_SHA256
    ;;
  aarch64|arm64)
    terraform_arch=arm64
    archive_sha256=$TERRAFORM_LINUX_ARM64_SHA256
    ;;
  *)
    fail "Unsupported Terraform architecture: $(uname -m)"
    ;;
esac

install_dir="$repo_dir/.cache/terraform/bin"
download_dir="$repo_dir/.cache/terraform/downloads"
terraform_bin="$install_dir/terraform"
archive_name="terraform_${TERRAFORM_CLI_VERSION}_linux_${terraform_arch}.zip"
archive="$download_dir/$archive_name"
download_base=${TERRAFORM_DOWNLOAD_BASE_URL:-https://releases.hashicorp.com/terraform}

terraform_version() {
  "$1" version -json 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || true
}

if [[ -x $terraform_bin && $(terraform_version "$terraform_bin") == "$TERRAFORM_CLI_VERSION" ]]; then
  echo "Terraform $TERRAFORM_CLI_VERSION is ready at $terraform_bin."
  exit 0
fi

mkdir -p "$install_dir" "$download_dir"
if [[ -f $archive ]] && ! printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum -c - >/dev/null 2>&1; then
  rm -f -- "$archive"
fi
if [[ ! -f $archive ]]; then
  partial_archive="${archive}.partial.$$"
  trap 'rm -f -- "${partial_archive:-}" "${partial_bin:-}"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 \
    "$download_base/$TERRAFORM_CLI_VERSION/$archive_name" \
    --output "$partial_archive"
  printf '%s  %s\n' "$archive_sha256" "$partial_archive" | sha256sum -c - >/dev/null
  mv -f -- "$partial_archive" "$archive"
fi

printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum -c - >/dev/null
partial_bin="${terraform_bin}.partial.$$"
unzip -p "$archive" terraform >"$partial_bin"
chmod 0755 "$partial_bin"
[[ $(terraform_version "$partial_bin") == "$TERRAFORM_CLI_VERSION" ]] || \
  fail "The downloaded Terraform binary is not version $TERRAFORM_CLI_VERSION."
mv -f -- "$partial_bin" "$terraform_bin"
trap - EXIT

echo "Terraform $TERRAFORM_CLI_VERSION is ready at $terraform_bin."
