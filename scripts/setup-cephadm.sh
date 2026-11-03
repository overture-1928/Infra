#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/config/versions.env"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Run this script through sudo on the Ceph bootstrap host.'
for command_name in curl grep install sha256sum; do
  command -v "$command_name" >/dev/null || fail "$command_name is required to install cephadm."
done
[[ $CEPH_IMAGE == *":v${CEPHADM_VERSION}" ]] || \
  fail "CEPH_IMAGE and CEPHADM_VERSION must select the same exact release."

destination=/usr/local/sbin/cephadm
if [[ -x $destination ]] && \
   printf '%s  %s\n' "$CEPHADM_SHA256" "$destination" | sha256sum -c - >/dev/null 2>&1; then
  echo "cephadm $CEPHADM_VERSION is ready at $destination."
  exit 0
fi

staging=$(mktemp /tmp/cephadm.XXXXXX)
trap 'rm -f -- "$staging"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "https://download.ceph.com/rpm-${CEPHADM_VERSION}/el9/noarch/cephadm" \
  --output "$staging"
printf '%s  %s\n' "$CEPHADM_SHA256" "$staging" | sha256sum -c - >/dev/null
install -o root -g root -m 0755 "$staging" "$destination"
printf '%s  %s\n' "$CEPHADM_SHA256" "$destination" | sha256sum -c - >/dev/null
"$destination" version | grep -F "$CEPHADM_VERSION" >/dev/null || \
  fail "Installed cephadm does not report version $CEPHADM_VERSION."

echo "cephadm $CEPHADM_VERSION is ready at $destination."
