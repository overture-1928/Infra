#!/usr/bin/env python3
"""Render one workload's Terraform instances as a private Ansible inventory."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path

import yaml


ALLOWED_SETTINGS = {
    "address_source",
    "ansible_port",
    "ansible_ssh_common_args",
    "ansible_ssh_private_key_file",
    "ansible_user",
    "group_vars",
    "host_vars",
}
RESERVED_GROUP_VARS = {"workload_name"}
RESERVED_HOST_VARS = {
    "ansible_host",
    "openstack_instance_id",
    "terraform_instance_key",
}


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def load_mapping(path: Path, label: str) -> dict:
    try:
        value = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as exc:
        fail(f"cannot read {label} {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a YAML mapping: {path}")
    return value


def require_optional_string(value: object, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        fail(f"{field} must be null or a non-empty string")
    return value


def sorted_addresses(value: object, instance_key: str) -> list[str]:
    if not isinstance(value, list):
        fail(f"instances.{instance_key}.fixed_ips must be a list")
    addresses: list[tuple[ipaddress.IPv4Address | ipaddress.IPv6Address, str]] = []
    for raw in value:
        if not isinstance(raw, str):
            fail(f"instances.{instance_key}.fixed_ips entries must be strings")
        try:
            parsed = ipaddress.ip_address(raw)
        except ValueError:
            fail(f"instances.{instance_key}.fixed_ips contains an invalid address: {raw}")
        addresses.append((parsed, raw))
    return [raw for _, raw in sorted(addresses, key=lambda item: (item[0].version, int(item[0])))]


def select_address(instance: dict, instance_key: str, source: str) -> str:
    floating = instance.get("floating_ip")
    if floating is not None:
        if not isinstance(floating, str) or not floating.strip():
            fail(f"instances.{instance_key}.floating_ip must be null or a non-empty string")
        try:
            ipaddress.ip_address(floating)
        except ValueError:
            fail(f"instances.{instance_key}.floating_ip is invalid: {floating}")

    fixed = sorted_addresses(instance.get("fixed_ips"), instance_key)
    if source == "floating":
        if floating is None:
            fail(f"instances.{instance_key} has no Floating IP")
        return floating
    if source == "fixed":
        if not fixed:
            fail(f"instances.{instance_key} has no fixed IP")
        return fixed[0]
    if floating is not None:
        return floating
    if fixed:
        return fixed[0]
    fail(f"instances.{instance_key} has no usable address")


def private_settings(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        fail(f"workload Ansible settings are missing or are a symbolic link: {path}")
    mode = path.stat().st_mode & 0o777
    if mode != 0o600:
        fail(f"workload Ansible settings must use mode 0600: {path} (found {mode:o})")
    settings = load_mapping(path, "workload Ansible settings")
    unknown = sorted(set(settings) - ALLOWED_SETTINGS)
    if unknown:
        fail(f"unknown workload Ansible setting(s): {', '.join(unknown)}")
    return settings


def render(stack: str, instances: dict, settings: dict) -> dict:
    source = settings.get("address_source", "auto")
    if source not in {"auto", "fixed", "floating"}:
        fail("address_source must be auto, fixed, or floating")

    ansible_user = settings.get("ansible_user", "ubuntu")
    if not isinstance(ansible_user, str) or not ansible_user.strip():
        fail("ansible_user must be a non-empty string")
    ansible_port = settings.get("ansible_port", 22)
    if isinstance(ansible_port, bool) or not isinstance(ansible_port, int) or not 1 <= ansible_port <= 65535:
        fail("ansible_port must be an integer from 1 to 65535")

    private_key = require_optional_string(
        settings.get("ansible_ssh_private_key_file"), "ansible_ssh_private_key_file"
    )
    if private_key is not None:
        key_path = Path(private_key)
        if not key_path.is_absolute():
            fail("ansible_ssh_private_key_file must be an absolute path")
        if not key_path.is_file() or not os.access(key_path, os.R_OK):
            fail(f"ansible_ssh_private_key_file is not a readable file: {key_path}")
    common_args = require_optional_string(
        settings.get("ansible_ssh_common_args"), "ansible_ssh_common_args"
    )

    group_vars = settings.get("group_vars", {})
    host_vars = settings.get("host_vars", {})
    if not isinstance(group_vars, dict):
        fail("group_vars must be a mapping")
    if not isinstance(host_vars, dict):
        fail("host_vars must be a mapping keyed by Terraform instance key")
    forbidden_group = sorted(set(group_vars) & RESERVED_GROUP_VARS)
    if forbidden_group:
        fail(f"group_vars cannot override reserved variable(s): {', '.join(forbidden_group)}")

    hosts: dict[str, dict] = {}
    consumed_host_vars: set[str] = set()
    for instance_key in sorted(instances):
        instance = instances[instance_key]
        if not isinstance(instance_key, str) or not instance_key:
            fail("Terraform instance keys must be non-empty strings")
        if not isinstance(instance, dict):
            fail(f"instances.{instance_key} must be a mapping")
        instance_name = instance.get("instance_name")
        instance_id = instance.get("instance_id")
        if not isinstance(instance_name, str) or not instance_name:
            fail(f"instances.{instance_key}.instance_name must be a non-empty string")
        if not isinstance(instance_id, str) or not instance_id:
            fail(f"instances.{instance_key}.instance_id must be a non-empty string")
        if instance_name in hosts:
            fail(f"duplicate OpenStack instance name in Terraform output: {instance_name}")

        extra = host_vars.get(instance_key, {})
        if not isinstance(extra, dict):
            fail(f"host_vars.{instance_key} must be a mapping")
        forbidden_host = sorted(set(extra) & RESERVED_HOST_VARS)
        if forbidden_host:
            fail(
                f"host_vars.{instance_key} cannot override reserved variable(s): "
                + ", ".join(forbidden_host)
            )
        consumed_host_vars.add(instance_key)
        hosts[instance_name] = {
            "ansible_host": select_address(instance, instance_key, source),
            "openstack_instance_id": instance_id,
            "terraform_instance_key": instance_key,
            **extra,
        }

    if not hosts:
        fail("Terraform output contains no workload instances")
    unknown_host_vars = sorted(set(host_vars) - consumed_host_vars)
    if unknown_host_vars:
        fail(f"host_vars contains unknown Terraform instance key(s): {', '.join(unknown_host_vars)}")

    connection_vars: dict[str, object] = {
        "workload_name": stack,
        "ansible_user": ansible_user,
        "ansible_port": ansible_port,
        **group_vars,
    }
    if private_key is not None:
        connection_vars["ansible_ssh_private_key_file"] = private_key
    if common_args is not None:
        connection_vars["ansible_ssh_common_args"] = common_args

    return {
        "all": {
            "children": {
                "workload": {
                    "hosts": hosts,
                    "vars": connection_vars,
                }
            }
        }
    }


def atomic_write(path: Path, value: dict) -> None:
    if path.is_symlink():
        fail(f"refusing to replace symbolic-link inventory: {path}")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink() or not path.parent.is_dir():
        fail(f"inventory output parent must be a real directory: {path.parent}")
    path.parent.chmod(0o700)
    temporary = path.parent / f".{path.name}.tmp.{os.getpid()}"
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            os.chmod(temporary, 0o600)
            yaml.safe_dump(value, handle, sort_keys=False)
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack", required=True)
    parser.add_argument("--instances-json", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    try:
        instances = json.loads(args.instances_json.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read Terraform instances JSON {args.instances_json}: {exc}")
    if not isinstance(instances, dict):
        fail("Terraform instances output must be a JSON object")
    inventory = render(args.stack, instances, private_settings(args.settings))
    atomic_write(args.output, inventory)
    print(f"Rendered {len(inventory['all']['children']['workload']['hosts'])} host(s): {args.output}")


if __name__ == "__main__":
    main()
