#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$repo_dir/config/versions.env"

for cmd in curl git python3 sha256sum; do
  command -v "$cmd" >/dev/null || { echo "$cmd is required on the controller." >&2; exit 1; }
done

architecture=$(uname -m)
case "$architecture" in
  x86_64)
    download_arch=amd64
    kubectl_sha256=$KUBECTL_LINUX_AMD64_SHA256
    ;;
  aarch64|arm64)
    download_arch=arm64
    kubectl_sha256=$KUBECTL_LINUX_ARM64_SHA256
    ;;
  *)
    echo "Unsupported architecture for kubectl: $architecture" >&2
    exit 1
    ;;
esac
kubectl_dir="$repo_dir/.cache/kubernetes/bin"
kubectl_bin="$kubectl_dir/kubectl-${KUBECTL_VERSION}-${download_arch}"
mkdir -p "$kubectl_dir"
if [[ ! -f $kubectl_bin ]]; then
  staging="${kubectl_bin}.partial.$$"
  curl -fL \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${download_arch}/kubectl" \
    -o "$staging"
  chmod 0755 "$staging"
  mv -f "$staging" "$kubectl_bin"
fi
printf '%s  %s\n' "$kubectl_sha256" "$kubectl_bin" | sha256sum -c - >/dev/null

cache_dir="$repo_dir/.cache/kubespray"
venv_dir="$repo_dir/.cache/kubespray-venv"

if [[ ! -d $cache_dir/.git ]]; then
  mkdir -p "$(dirname -- "$cache_dir")"
  git clone --branch "$KUBESPRAY_VERSION" --depth 1 \
    https://github.com/kubernetes-sigs/kubespray.git "$cache_dir"
fi

current_tag=$(git -C "$cache_dir" describe --tags --exact-match 2>/dev/null || true)
if [[ $current_tag != "$KUBESPRAY_VERSION" ]]; then
  git -C "$cache_dir" fetch --depth 1 origin "refs/tags/$KUBESPRAY_VERSION:refs/tags/$KUBESPRAY_VERSION"
  git -C "$cache_dir" checkout --detach "$KUBESPRAY_VERSION"
fi

if [[ ! -x $venv_dir/bin/python ]]; then
  python3 -m venv "$venv_dir"
fi
"$venv_dir/bin/python" -m pip install --disable-pip-version-check -r "$cache_dir/requirements.txt"

echo "Kubespray $KUBESPRAY_VERSION is ready in $cache_dir."
echo "kubectl $KUBECTL_VERSION is ready at $kubectl_bin."
