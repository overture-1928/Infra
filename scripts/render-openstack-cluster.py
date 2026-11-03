#!/usr/bin/env python3
"""Validate one topology file and render Ansible, Kolla and Ceph inputs."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import yaml


ROLES = ("control", "network", "compute", "monitoring", "storage")
MAC_RE = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$", re.IGNORECASE)


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def load_yaml(path: Path) -> dict:
    try:
        data = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as exc:
        fail(f"cannot read {path}: {exc}")
    if not isinstance(data, dict):
        fail(f"{path} must contain a YAML mapping")
    return data


def enabled_nodes(config: dict) -> dict[str, dict]:
    nodes = config.get("nodes")
    if not isinstance(nodes, dict) or not nodes:
        fail("nodes must be a non-empty mapping")
    return {name: values for name, values in nodes.items() if values.get("enabled") is True}


def validate_platform(cluster: dict, node_count: int) -> dict:
    platform = cluster.get("platform", {})
    if not isinstance(platform, dict):
        fail("cluster.platform must be a mapping")

    magnum = platform.get("magnum_capi", {})
    containers = platform.get("container_service", {})
    if not isinstance(magnum, dict):
        fail("cluster.platform.magnum_capi must be a mapping")
    if not isinstance(containers, dict):
        fail("cluster.platform.container_service must be a mapping")

    magnum_enabled = magnum.get("enabled", False)
    hosted_control_plane = magnum.get("hosted_control_plane", False)
    container_enabled = containers.get("enabled", False)
    for path, value in (
        ("magnum_capi.enabled", magnum_enabled),
        ("magnum_capi.hosted_control_plane", hosted_control_plane),
        ("container_service.enabled", container_enabled),
    ):
        if not isinstance(value, bool):
            fail(f"cluster.platform.{path} must be true or false")

    provider = containers.get("provider", "kubernetes")
    if provider == "zun":
        fail("Zun is unsupported by Kolla-Ansible 2026.2; use container_service.provider=kubernetes")
    if provider != "kubernetes":
        fail("cluster.platform.container_service.provider must be kubernetes")
    if container_enabled:
        fail(
            "cluster.platform.container_service.enabled=true is not implemented; "
            "keep it false until the Kubernetes container API is available"
        )
    if hosted_control_plane and not magnum_enabled:
        fail("hosted_control_plane requires magnum_capi.enabled=true")

    enabled = magnum_enabled
    if enabled and node_count < 3:
        fail("managed platform services require at least three enabled physical nodes")
    if enabled and cluster.get("storage_backend") != "ceph":
        fail("managed platform services require cluster.storage_backend=ceph")
    if enabled and cluster.get("ceph", {}).get("enabled") is not True:
        fail("managed platform services require cluster.ceph.enabled=true")

    return {
        "magnum_capi": {
            "enabled": magnum_enabled,
            "hosted_control_plane": hosted_control_plane,
        },
        "container_service": {
            "enabled": container_enabled,
            "provider": provider,
        },
    }


def validate(config: dict) -> tuple[dict, dict[str, dict], dict[str, list[str]], dict]:
    if config.get("schema_version") != 1:
        fail("schema_version must be 1")
    cluster = config.get("cluster")
    if not isinstance(cluster, dict):
        fail("cluster must be a mapping")
    nodes = enabled_nodes(config)
    if len(nodes) == 2:
        fail("two enabled nodes do not provide controller quorum; use one node or at least three")

    backend = cluster.get("storage_backend")
    if backend not in {"lvm", "ceph"}:
        fail("cluster.storage_backend must be lvm or ceph")
    try:
        vip = ipaddress.ip_address(cluster["api_vip"])
    except (KeyError, ValueError) as exc:
        fail(f"cluster.api_vip is invalid: {exc}")
    timezone = cluster.get("timezone", "Asia/Seoul")
    if not isinstance(timezone, str) or not timezone:
        fail("cluster.timezone must be a non-empty IANA timezone")
    try:
        ZoneInfo(timezone)
    except ZoneInfoNotFoundError:
        fail("cluster.timezone must be a valid IANA timezone")
    cluster["timezone"] = timezone

    role_hosts = {role: [] for role in ROLES}
    addresses: set[ipaddress._BaseAddress] = set()
    macs: set[str] = set()
    local_hosts: list[str] = []
    for name, node in nodes.items():
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
            fail(f"invalid node name: {name}")
        for field in (
            "ansible_host",
            "ansible_user",
            "management_interface",
            "management_mac",
            "management_address",
            "management_gateway",
            "neutron_external_interface",
            "neutron_external_vlan_id",
            "os_disk_serial",
            "roles",
        ):
            if field not in node:
                fail(f"{name}.{field} is required")
        if any("REPLACE" in str(node[field]) for field in ("management_mac", "os_disk_serial")):
            fail(f"replace hardware placeholders before enabling {name}")
        mac = str(node["management_mac"]).lower()
        if not MAC_RE.fullmatch(mac):
            fail(f"{name}.management_mac is invalid")
        if mac in macs:
            fail(f"duplicate management MAC: {mac}")
        macs.add(mac)
        try:
            interface = ipaddress.ip_interface(node["management_address"])
            gateway = ipaddress.ip_address(node["management_gateway"])
        except ValueError as exc:
            fail(f"invalid address on {name}: {exc}")
        if interface.ip in addresses:
            fail(f"duplicate management address: {interface.ip}")
        if gateway not in interface.network:
            fail(f"{name} management gateway is outside its subnet")
        addresses.add(interface.ip)
        node_roles = node["roles"]
        if not isinstance(node_roles, list) or not node_roles:
            fail(f"{name}.roles must be a non-empty list")
        unknown = sorted(set(node_roles) - set(ROLES))
        if unknown:
            fail(f"{name} has unknown roles: {', '.join(unknown)}")
        for role in set(node_roles):
            role_hosts[role].append(name)
        connection = node.get("connection", "ssh")
        if connection not in {"local", "ssh"}:
            fail(f"{name}.connection must be local or ssh")
        if connection == "local":
            local_hosts.append(name)
    if vip in addresses:
        fail("cluster.api_vip must not equal a node management address")
    if local_hosts != ["cloud01"]:
        fail("cloud01 must be the only local deployment host")
    for role in ROLES:
        if not role_hosts[role]:
            fail(f"at least one enabled node must have the {role} role")
        role_hosts[role].sort()
    controls = len(role_hosts["control"])
    if controls != 1 and (controls < 3 or controls % 2 == 0):
        fail("control role count must be one or an odd number of at least three")
    if len(nodes) >= 3 and controls < 3:
        fail("a three-or-more-node topology requires at least three controllers")
    if len(nodes) >= 3 and len(role_hosts["network"]) < 3:
        fail("a three-or-more-node topology requires at least three network nodes")
    if backend == "lvm" and role_hosts["storage"] != ["cloud01"]:
        fail("the reviewed LVM topology permits only cloud01 in the storage group")

    ceph = cluster.get("ceph", {})
    if backend == "ceph":
        if ceph.get("enabled") is not True:
            fail("Ceph backend requires cluster.ceph.enabled=true")
        pool_device_class = ceph.get("openstack_pool_device_class")
        if pool_device_class not in {"hdd", "ssd", "nvme"}:
            fail(
                "cluster.ceph.openstack_pool_device_class must be hdd, ssd or nvme"
            )
        osd_hosts = [name for name, node in nodes.items() if node.get("ceph_osd_devices")]
        if len(osd_hosts) < 3:
            fail("Ceph requires explicit OSD devices on at least three enabled nodes")
        all_devices = []
        class_hosts: dict[str, set[str]] = {}
        for name in osd_hosts:
            for device in nodes[name]["ceph_osd_devices"]:
                if not isinstance(device, dict):
                    fail(f"{name}.ceph_osd_devices entries must be mappings")
                required = {"by_id", "serial", "min_size_bytes", "device_class"}
                if not required <= set(device):
                    fail(f"{name} Ceph device requires: {', '.join(sorted(required))}")
                if not str(device["by_id"]).startswith("/dev/disk/by-id/"):
                    fail(f"{name} Ceph device must use /dev/disk/by-id")
                if "REPLACE" in str(device) or int(device["min_size_bytes"]) <= 0:
                    fail(f"replace and review every Ceph device field on {name}")
                if device["device_class"] not in {"hdd", "ssd", "nvme"}:
                    fail(f"invalid Ceph device class on {name}")
                class_hosts.setdefault(device["device_class"], set()).add(name)
                all_devices.append(device["by_id"])
        if len(all_devices) != len(set(all_devices)):
            fail("Ceph OSD device paths must be unique")
        for device_class, hosts in sorted(class_hosts.items()):
            if len(hosts) < 3:
                fail(
                    f"Ceph device class {device_class} requires devices on at least "
                    "three enabled nodes"
                )
        if len(class_hosts.get(pool_device_class, set())) < 3:
            fail(
                "cluster.ceph.openstack_pool_device_class must exist on at least "
                "three enabled nodes"
            )
        if ceph.get("bootstrap_host") not in nodes:
            fail("Ceph bootstrap_host must be enabled")
    elif ceph.get("enabled") is True:
        fail("set storage_backend=ceph before enabling Ceph")
    platform = validate_platform(cluster, len(nodes))
    return cluster, nodes, role_hosts, platform


def kolla_host_line(name: str, node: dict, private_key: str) -> str:
    values = [name]
    if node.get("connection", "ssh") == "local":
        values.append("ansible_connection=local")
    else:
        values.extend(
            [
                f"ansible_host={node['ansible_host']}",
                f"ansible_user={node['ansible_user']}",
                "ansible_become=true",
                f"ansible_private_key_file={private_key}",
            ]
        )
    values.extend(
        [
            f"network_interface={node['management_interface']}",
            f"api_interface={node['management_interface']}",
            f"tunnel_interface={node['management_interface']}",
            f"neutron_external_interface={node['neutron_external_interface']}",
        ]
    )
    return " ".join(values)


def render_ansible(cluster: dict, nodes: dict[str, dict], role_hosts: dict[str, list[str]]) -> dict:
    hosts = {}
    cluster_hosts = {
        name: str(ipaddress.ip_interface(node["management_address"]).ip)
        for name, node in nodes.items()
    }
    for name, node in nodes.items():
        values = {
            "ansible_host": node["ansible_host"],
            "ansible_user": node["ansible_user"],
            "ansible_become": True,
            "management_interface": node["management_interface"],
            "management_mac": node["management_mac"],
            "management_address": node["management_address"],
            "management_gateway": node["management_gateway"],
            "management_dns": node.get("management_dns", []),
            "neutron_external_interface": node["neutron_external_interface"],
            "neutron_external_vlan_id": node["neutron_external_vlan_id"],
            "enable_iommu": True,
            "openstack_roles": node["roles"],
            "openstack_cluster_hosts": cluster_hosts,
            "openstack_api_vip": cluster["api_vip"],
            "timezone": cluster["timezone"],
            "require_docker_mount": node.get("require_docker_mount", True),
            "local_lvm_storage": cluster["storage_backend"] == "lvm" and name in role_hosts["storage"],
            "ceph_osd_devices": node.get("ceph_osd_devices", []),
        }
        if node.get("connection", "ssh") == "local":
            values["ansible_connection"] = "local"
        else:
            values["ansible_ssh_private_key_file"] = cluster["ssh_private_key"]
        hosts[name] = values
    children = {"openstack_hosts": {"hosts": {name: {} for name in nodes}}}
    for role, names in role_hosts.items():
        children[role] = {"hosts": {name: {} for name in names}}
    return {"all": {"hosts": hosts, "children": children}}


def render_kolla(cluster: dict, nodes: dict[str, dict], role_hosts: dict[str, list[str]]) -> str:
    lines = ["# Generated by scripts/render-openstack-cluster.py; do not edit."]
    for role in ROLES:
        lines.append(f"\n[{role}]")
        for name in role_hosts[role]:
            lines.append(kolla_host_line(name, nodes[name], cluster["ssh_private_key"]))
    lines.extend(["", "[deployment]", "localhost ansible_connection=local", ""])
    return "\n".join(lines)


def render_globals(base: dict, cluster: dict, platform: dict) -> dict:
    result = dict(base)
    result["kolla_internal_vip_address"] = str(cluster["api_vip"])
    result["kolla_external_vip_address"] = str(cluster["api_vip"])
    if cluster["storage_backend"] == "ceph":
        result.update(
            {
                "enable_cinder_backend_lvm": "no",
                "enable_cinder_backend_iscsi": "no",
                "cinder_backend_ceph": "yes",
                "glance_backend_file": "no",
                "glance_backend_ceph": "yes",
                "nova_backend_ceph": "yes",
                "cinder_backends": [],
                "cinder_ceph_backends": [
                    {
                        "name": "ceph-rbd",
                        "backend_name": "ceph-rbd",
                        "cluster": "ceph",
                        "user": "cinder",
                        "pool": "volumes",
                        "enabled": True,
                    }
                ],
            }
        )
    if platform["magnum_capi"]["enabled"]:
        result.update(
            {
                "enable_barbican": "yes",
                "enable_octavia": "yes",
                "enable_magnum": "yes",
                "octavia_provider_drivers": "ovn:OVN provider",
                "octavia_provider_agents": "ovn",
                "octavia_auto_configure": "no",
            }
        )
    return result


def render_ceph_plan(cluster: dict, nodes: dict[str, dict]) -> dict:
    ceph = cluster.get("ceph", {})
    return {
        "enabled": ceph.get("enabled", False),
        "bootstrap_host": ceph.get("bootstrap_host", "cloud01"),
        "public_network": ceph.get("public_network", ""),
        "cluster_network": ceph.get("cluster_network", ""),
        "osd_memory_target_ratio": ceph.get("osd_memory_target_ratio", 0.2),
        "openstack_pool_device_class": ceph.get("openstack_pool_device_class", ""),
        "hosts": {
            name: {
                "address": node.get("ceph_address", node["ansible_host"]),
                "osd_devices": node.get("ceph_osd_devices", []),
            }
            for name, node in nodes.items()
        },
    }


def render_ceph_specs(plan: dict) -> tuple[list[dict], str, str]:
    specs = []
    manifest_lines = []
    for host, values in sorted(plan["hosts"].items()):
        for index, device in enumerate(values["osd_devices"], start=1):
            specs.append(
                {
                    "service_type": "osd",
                    "service_id": f"openstack-{host}-{index}",
                    "placement": {"hosts": [host]},
                    "crush_device_class": device["device_class"],
                    "spec": {"data_devices": {"paths": [device["by_id"]]}},
                }
            )
            manifest_lines.append(
                "|".join(
                    [
                        host,
                        device["by_id"],
                        str(device["serial"]),
                        str(device["min_size_bytes"]),
                        device["device_class"],
                    ]
                )
            )
    manifest = "\n".join(manifest_lines) + ("\n" if manifest_lines else "")
    digest = hashlib.sha256(manifest.encode()).hexdigest()
    return specs, manifest, digest


def main() -> None:
    repo = Path(__file__).resolve().parent.parent
    configured_path = os.environ.get("OPENSTACK_CLUSTER_CONFIG")
    default_config = Path(configured_path) if configured_path else repo / "inventory/openstack-cluster.local.yml"
    if not configured_path and not default_config.exists():
        default_config = repo / "inventory/openstack-cluster.yml"
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=default_config)
    parser.add_argument("--output-dir", type=Path, default=repo / ".cache/cluster")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()

    config = load_yaml(args.config)
    cluster, nodes, role_hosts, platform = validate(config)
    if args.validate_only:
        print(f"Validated {len(nodes)} enabled node(s) from {args.config}")
        return

    args.output_dir.mkdir(parents=True, exist_ok=True)
    ansible_output = args.output_dir / "ansible-inventory.yml"
    ansible_output.write_text(yaml.safe_dump(render_ansible(cluster, nodes, role_hosts), sort_keys=False))
    kolla_local = repo / "kolla/inventory/multinode.local"
    kolla_local.write_text(render_kolla(cluster, nodes, role_hosts))
    globals_output = repo / "kolla/generated/globals.yml"
    globals_output.parent.mkdir(parents=True, exist_ok=True)
    globals_output.write_text(
        yaml.safe_dump(
            render_globals(load_yaml(repo / "kolla/globals.yml"), cluster, platform),
            sort_keys=False,
        )
    )
    plan = {
        "config": str(args.config),
        "api_vip": str(cluster["api_vip"]),
        "node_count": len(nodes),
        "storage_backend": cluster["storage_backend"],
        "platform": platform,
        "roles": role_hosts,
        "nodes": nodes,
    }
    (args.output_dir / "cluster-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    ceph_plan = {
        "config": str(args.config),
        **render_ceph_plan(cluster, nodes),
    }
    (args.output_dir / "ceph-plan.json").write_text(json.dumps(ceph_plan, indent=2) + "\n")
    specs, manifest, digest = render_ceph_specs(ceph_plan)
    (args.output_dir / "ceph-osd-spec.yml").write_text(yaml.safe_dump_all(specs, sort_keys=False))
    (args.output_dir / "ceph-osd-manifest.txt").write_text(manifest)
    (args.output_dir / "ceph-osd-manifest.sha256").write_text(digest + "\n")
    print(f"Rendered {len(nodes)} node(s) from {args.config}")
    print(f"Ansible inventory: {ansible_output}")
    print(f"Kolla primary inventory: {kolla_local}")
    print(f"Kolla globals: {globals_output}")


if __name__ == "__main__":
    main()
