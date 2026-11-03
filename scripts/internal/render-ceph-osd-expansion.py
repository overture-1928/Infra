#!/usr/bin/env python3
"""Render a guarded Ceph OSD expansion from topology and an explicit change file."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from uuid import UUID

import yaml


PATH_RE = re.compile(r"^/dev/disk/by-id/[A-Za-z0-9._:+-]+$")
HOST_RE = re.compile(r"^[a-z][a-z0-9-]*$")
CHANGE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,47}$")
SERIAL_RE = re.compile(r"^[A-Za-z0-9._:+-]+$")
DEVICE_FIELDS = {"by_id", "serial", "min_size_bytes", "device_class"}


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def load_yaml(path: Path) -> dict:
    try:
        value = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as exc:
        fail(f"cannot read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path} must contain a YAML mapping")
    return value


def normalized_device(value: object, path: str) -> dict:
    if not isinstance(value, dict) or set(value) != DEVICE_FIELDS:
        fail(f"{path} must contain exactly: {', '.join(sorted(DEVICE_FIELDS))}")
    by_id = str(value["by_id"])
    serial = str(value["serial"])
    device_class = str(value["device_class"])
    try:
        minimum = int(value["min_size_bytes"])
    except (TypeError, ValueError):
        fail(f"{path}.min_size_bytes must be an integer")
    if not PATH_RE.fullmatch(by_id) or "REPLACE" in by_id.upper() or "EXAMPLE" in by_id.upper():
        fail(f"{path}.by_id must be a reviewed /dev/disk/by-id path")
    if not SERIAL_RE.fullmatch(serial) or "REPLACE" in serial.upper() or "EXAMPLE" in serial.upper():
        fail(f"{path}.serial must be the reviewed hardware serial")
    if minimum < 10 * 1024**3:
        fail(f"{path}.min_size_bytes must be at least 10 GiB")
    if device_class not in {"hdd", "ssd", "nvme"}:
        fail(f"{path}.device_class must be hdd, ssd or nvme")
    return {
        "by_id": by_id,
        "serial": serial,
        "min_size_bytes": minimum,
        "device_class": device_class,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--topology", type=Path, required=True)
    parser.add_argument("--change", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    topology = load_yaml(args.topology)
    change = load_yaml(args.change)
    if topology.get("schema_version") != 1:
        fail("topology.schema_version must be 1")
    if change.get("schema_version") != 1:
        fail("change.schema_version must be 1")

    cluster = topology.get("cluster")
    nodes = topology.get("nodes")
    if not isinstance(cluster, dict) or not isinstance(nodes, dict):
        fail("topology cluster and nodes must be mappings")
    if cluster.get("storage_backend") != "ceph":
        fail("topology cluster.storage_backend must be ceph")
    ceph = cluster.get("ceph")
    if not isinstance(ceph, dict) or ceph.get("enabled") is not True:
        fail("topology cluster.ceph.enabled must be true")
    try:
        public_network = ipaddress.ip_network(ceph["public_network"], strict=True)
    except (KeyError, ValueError) as exc:
        fail(f"topology Ceph public network is invalid: {exc}")

    change_id = str(change.get("change_id", ""))
    if not CHANGE_RE.fullmatch(change_id):
        fail("change_id must be 3-48 lowercase letters, numbers or hyphens")
    fsid_text = str(change.get("expected_fsid", ""))
    try:
        expected_fsid = str(UUID(fsid_text))
    except ValueError:
        fail("expected_fsid must be the current Ceph FSID UUID")
    try:
        expected_count = int(change["expected_current_osd_count"])
    except (KeyError, TypeError, ValueError):
        fail("expected_current_osd_count must be an integer")
    if expected_count < 3:
        fail("expected_current_osd_count must be at least 3")

    changes = change.get("devices")
    if not isinstance(changes, dict) or not changes:
        fail("devices must map at least three storage hosts to new devices")

    ssh_private_key = str(cluster.get("ssh_private_key", ""))
    if not ssh_private_key.startswith("/") or any(ch in ssh_private_key for ch in "\n\r\0"):
        fail("cluster.ssh_private_key must be an absolute path")

    ansible_hosts: dict[str, dict] = {}
    specs: list[dict] = []
    manifest_rows: list[str] = []
    seen_paths: set[str] = set()
    seen_serials: set[str] = set()
    class_hosts: dict[str, set[str]] = defaultdict(set)
    class_counts: dict[str, Counter] = defaultdict(Counter)
    normalized_changes: dict[str, list[dict]] = {}

    for host, values in sorted(changes.items()):
        if not HOST_RE.fullmatch(str(host)):
            fail(f"invalid host name in devices: {host}")
        node = nodes.get(host)
        if not isinstance(node, dict) or node.get("enabled") is not True:
            fail(f"devices.{host} must identify an enabled topology node")
        if "storage" not in node.get("roles", []):
            fail(f"devices.{host} must identify a storage-role node")
        if not isinstance(values, list) or not values:
            fail(f"devices.{host} must contain at least one device")

        topology_devices = [
            normalized_device(item, f"topology.nodes.{host}.ceph_osd_devices[{index}]")
            for index, item in enumerate(node.get("ceph_osd_devices", []))
        ]
        rendered_devices = []
        for index, value in enumerate(values, start=1):
            device = normalized_device(value, f"devices.{host}[{index}]")
            if device not in topology_devices:
                fail(
                    f"devices.{host}[{index}] is not an exact entry in "
                    f"topology.nodes.{host}.ceph_osd_devices"
                )
            if device["by_id"] in seen_paths:
                fail(f"duplicate expansion by-id: {device['by_id']}")
            if device["serial"] in seen_serials:
                fail(f"duplicate expansion serial: {device['serial']}")
            seen_paths.add(device["by_id"])
            seen_serials.add(device["serial"])
            device_class = device["device_class"]
            class_hosts[device_class].add(host)
            class_counts[device_class][host] += 1
            rendered_devices.append(device)
            manifest_rows.append(
                "|".join(
                    [
                        "device",
                        host,
                        device["by_id"],
                        device["serial"],
                        str(device["min_size_bytes"]),
                        device_class,
                    ]
                )
            )
            specs.append(
                {
                    "service_type": "osd",
                    "service_id": f"expand-{change_id}-{host}-{index}",
                    "placement": {"hosts": [host]},
                    "crush_device_class": device_class,
                    "spec": {"data_devices": {"paths": [device["by_id"]]}},
                }
            )
        normalized_changes[host] = rendered_devices

        address = str(node.get("ceph_address", ""))
        try:
            if ipaddress.ip_address(address) not in public_network:
                fail(f"{host}.ceph_address is outside {public_network}")
        except ValueError as exc:
            fail(f"{host}.ceph_address is invalid: {exc}")
        host_vars = {
            "ansible_host": node.get("ansible_host", address),
            "ansible_user": node.get("ansible_user"),
            "ansible_become": True,
            "ceph_address": address,
            "ceph_public_network": str(public_network),
            "ceph_cluster_network": str(ceph.get("cluster_network", "")),
            "ceph_osd_devices": rendered_devices,
        }
        connection = node.get("connection", "ssh")
        if connection == "local":
            host_vars["ansible_connection"] = "local"
        elif connection == "ssh":
            host_vars["ansible_ssh_private_key_file"] = ssh_private_key
        else:
            fail(f"{host}.connection must be local or ssh")
        ansible_hosts[host] = host_vars

    for device_class, hosts in sorted(class_hosts.items()):
        if len(hosts) < 3:
            fail(f"expansion class {device_class} must be added on at least three hosts")
        counts = set(class_counts[device_class].values())
        if len(counts) != 1:
            fail(f"expansion class {device_class} must add the same device count on every selected host")

    manifest_lines = [
        f"change_id|{change_id}",
        f"expected_fsid|{expected_fsid}",
        f"expected_current_osd_count|{expected_count}",
        *sorted(manifest_rows),
    ]
    manifest = "\n".join(manifest_lines) + "\n"
    digest = hashlib.sha256(manifest.encode()).hexdigest()
    metadata = {
        "change_id": change_id,
        "expected_fsid": expected_fsid,
        "expected_current_osd_count": expected_count,
        "expected_final_osd_count": expected_count + len(specs),
        "device_count": len(specs),
        "device_classes": sorted(class_hosts),
        "hosts": normalized_changes,
        "topology": str(args.topology.resolve()),
        "change": str(args.change.resolve()),
        "digest": digest,
    }
    inventory = {
        "all": {
            "hosts": ansible_hosts,
            "children": {"ceph_hosts": {"hosts": {host: {} for host in ansible_hosts}}},
        }
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (args.output_dir / "ansible-inventory.yml").write_text(yaml.safe_dump(inventory, sort_keys=False))
    (args.output_dir / "ceph-osd-spec.yml").write_text(yaml.safe_dump_all(specs, sort_keys=False))
    (args.output_dir / "manifest.txt").write_text(manifest)
    (args.output_dir / "manifest.sha256").write_text(digest + "\n")
    print(
        f"Rendered expansion {change_id}: {len(specs)} device(s) on "
        f"{len(ansible_hosts)} host(s); SHA256 {digest}"
    )


if __name__ == "__main__":
    main()
