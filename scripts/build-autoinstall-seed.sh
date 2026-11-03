#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
node_name=${1:-cloud01}
generated_dir="$repo_dir/ubuntu-autoinstall/generated/$node_name"
user_data="$generated_dir/user-data"
meta_data="$generated_dir/meta-data"
output=${2:-$generated_dir/$node_name-autoinstall-seed.iso}

[[ -f $user_data && -f $meta_data ]] || {
  echo "Run scripts/render-ubuntu-autoinstall.sh $node_name first." >&2
  exit 1
}
mkdir -p "$(dirname -- "$output")"

if command -v cloud-localds >/dev/null; then
  cloud-localds "$output" "$user_data" "$meta_data"
elif command -v genisoimage >/dev/null; then
  genisoimage -quiet -output "$output" -volid CIDATA -joliet -rock \
    "$user_data" "$meta_data"
else
  echo 'Install cloud-image-utils or genisoimage to build the NoCloud seed ISO.' >&2
  exit 1
fi

sha256sum "$output" >"$output.sha256"
echo "Created $output"
echo 'Boot the Ubuntu Server 24.04 ISO with this CIDATA seed attached.'
