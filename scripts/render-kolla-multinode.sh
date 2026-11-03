#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
venv_dir="$repo_dir/.cache/kolla-venv"
source_inventory=${1:-$repo_dir/kolla/inventory/multinode.local}
output="$repo_dir/kolla/generated/multinode"
globals_file="$repo_dir/kolla/generated/globals.yml"

[[ -x $venv_dir/bin/python ]] || {
  echo 'Run scripts/openstack.sh setup first.' >&2
  exit 1
}
[[ -f $source_inventory ]] || {
  echo "Copy kolla/inventory/multinode.example to $source_inventory and review it first." >&2
  exit 1
}
[[ -f $globals_file ]] || {
  echo 'Run scripts/render-openstack-cluster.py before rendering the Kolla inventory.' >&2
  exit 1
}
kolla_share=$(find -L "$venv_dir" -type d -path '*/share/kolla-ansible' -print -quit)
template="$kolla_share/ansible/inventory/multinode"
[[ -f $template ]] || { echo 'Official Kolla multinode inventory was not found.' >&2; exit 1; }
mkdir -p "$(dirname -- "$output")"

KOLLA_TEMPLATE="$template" KOLLA_PRIMARY="$source_inventory" \
KOLLA_GLOBALS="$globals_file" KOLLA_OUTPUT="$output" \
python3 - <<'PY'
import configparser
import os
from pathlib import Path

import yaml

primary_groups = ["control", "network", "compute", "monitoring", "storage", "deployment"]
source = Path(os.environ["KOLLA_PRIMARY"]).read_text()
parser = configparser.ConfigParser(allow_no_value=True, delimiters=("="), strict=False)
parser.optionxform = str
parser.read_string(source)
for group in primary_groups:
    if not parser.has_section(group) or not list(parser.items(group, raw=True)):
        raise SystemExit(f"required non-empty group missing: {group}")

lines = Path(os.environ["KOLLA_TEMPLATE"]).read_text().splitlines()
replacements = {}
for group in primary_groups:
    block = []
    in_group = False
    for line in source.splitlines():
        if line.strip() == f"[{group}]":
            in_group = True
            continue
        if in_group and line.startswith("["):
            break
        if in_group and line.strip() and not line.lstrip().startswith("#"):
            block.append(line)
    replacements[group] = block

result = []
i = 0
while i < len(lines):
    line = lines[i]
    result.append(line)
    if line.startswith("[") and line.endswith("]"):
        group = line[1:-1]
        if group in replacements:
            i += 1
            while i < len(lines) and not (lines[i].startswith("[") and lines[i].endswith("]")):
                i += 1
            result.extend(replacements[group])
            result.append("")
            continue
    i += 1
Path(os.environ["KOLLA_OUTPUT"]).write_text("\n".join(result) + "\n")
PY

echo "Rendered $output from the official pinned Kolla inventory."
