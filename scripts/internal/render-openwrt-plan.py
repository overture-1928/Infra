#!/usr/bin/env python3
"""Validate an OpenWrt router and render a reviewable, guarded UCI plan."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
from pathlib import Path
from typing import Any

import yaml


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
UCI_VALUE_RE = re.compile(r"^[A-Za-z0-9_.:/,*+-]+$")
UCI_SECTION_REF_RE = re.compile(r"^(?:[A-Za-z0-9_-]+|@[A-Za-z0-9_-]+\[[0-9]+\])$")
MANAGED_BRIDGE_VLANS = {"os_management_vlan", "os_provider_vlan"}
CONFIRMATION_BOARD_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9,._/+@-]*$")
PORT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,30}$")


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        value = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as exc:
        fail(f"cannot read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path} must contain a YAML mapping")
    return value


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path} must contain a JSON object")
    return value


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    try:
        return sha256_bytes(path.read_bytes())
    except OSError as exc:
        fail(f"cannot hash {path}: {exc}")


def canonical_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return sha256_bytes(encoded)


def contains_replace(value: Any) -> bool:
    if isinstance(value, dict):
        return any(contains_replace(key) or contains_replace(item) for key, item in value.items())
    if isinstance(value, (list, tuple)):
        return any(contains_replace(item) for item in value)
    return "REPLACE" in str(value).upper()


def require_mapping(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{path} must be a mapping")
    return value


def require_list(value: Any, path: str) -> list[Any]:
    if not isinstance(value, list):
        fail(f"{path} must be a list")
    return value


def require_string(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{path} must be a non-empty string")
    return value.strip()


def require_bool(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{path} must be true or false")
    return value


def require_int(value: Any, path: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        fail(f"{path} must be an integer from {minimum} through {maximum}")
    return value


def require_uci_value(value: Any, path: str) -> str:
    result = require_string(value, path)
    if not UCI_VALUE_RE.fullmatch(result) or "'" in result:
        fail(f"{path} contains characters that are unsafe for UCI")
    return result


def require_uci_section_ref(value: Any, path: str) -> str:
    result = require_string(value, path)
    if not UCI_SECTION_REF_RE.fullmatch(result):
        fail(f"{path} is not a safe UCI section reference")
    return result


def parse_network(value: Any, path: str) -> ipaddress.IPv4Network:
    try:
        network = ipaddress.ip_network(str(value), strict=True)
    except ValueError as exc:
        fail(f"{path} is invalid: {exc}")
    if not isinstance(network, ipaddress.IPv4Network):
        fail(f"{path} must be an IPv4 network")
    return network


def parse_interface(value: Any, path: str) -> ipaddress.IPv4Interface:
    try:
        interface = ipaddress.ip_interface(str(value))
    except ValueError as exc:
        fail(f"{path} is invalid: {exc}")
    if not isinstance(interface, ipaddress.IPv4Interface):
        fail(f"{path} must be an IPv4 interface")
    return interface


def parse_address(value: Any, path: str) -> ipaddress.IPv4Address:
    try:
        address = ipaddress.ip_address(str(value))
    except ValueError as exc:
        fail(f"{path} is invalid: {exc}")
    if not isinstance(address, ipaddress.IPv4Address):
        fail(f"{path} must be an IPv4 address")
    return address


def require_host_address(address: ipaddress.IPv4Address, network: ipaddress.IPv4Network, path: str) -> None:
    if address not in network or address in {network.network_address, network.broadcast_address}:
        fail(f"{path} must be a usable address in {network}")


def select_cluster_config(repo: Path, explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit
    configured = os.environ.get("OPENSTACK_CLUSTER_CONFIG")
    if configured:
        return Path(configured)
    local = repo / "inventory/openstack-cluster.local.yml"
    return local if local.exists() else repo / "inventory/openstack-cluster.yml"


def single_router(inventory: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    all_group = require_mapping(inventory.get("all"), "all")
    defaults = all_group.get("vars", {})
    if not isinstance(defaults, dict):
        fail("all.vars must be a mapping")
    if defaults.get("openwrt_schema_version") != 1:
        fail("all.vars.openwrt_schema_version must be 1")
    children = require_mapping(all_group.get("children"), "all.children")
    openwrt_group = require_mapping(children.get("openwrt"), "all.children.openwrt")
    group_defaults = openwrt_group.get("vars", {})
    if not isinstance(group_defaults, dict):
        fail("all.children.openwrt.vars must be a mapping")
    hosts = require_mapping(openwrt_group.get("hosts"), "all.children.openwrt.hosts")
    if len(hosts) != 1:
        fail("OpenWrt inventory must declare exactly one router")
    name, host_values = next(iter(hosts.items()))
    if not re.fullmatch(r"[a-z][a-z0-9_-]*", str(name)):
        fail("router inventory name must contain lowercase letters, numbers, _ or -")
    host = dict(defaults)
    host.update(group_defaults)
    host.update(require_mapping(host_values, f"all.hosts.{name}"))
    if host.get("enabled") is not True:
        fail("router enabled must be true before a plan can be rendered")
    if contains_replace(host):
        fail("replace every REPLACE value in the enabled router inventory")
    return str(name), host


def discovery_fields(discovery: dict[str, Any]) -> dict[str, Any]:
    if discovery.get("schema_version") != 1:
        fail("discovery.schema_version must be 1")
    release = require_mapping(discovery.get("release"), "discovery.release")
    capabilities = require_mapping(discovery.get("capabilities"), "discovery.capabilities")
    configs = require_mapping(discovery.get("configs"), "discovery.configs")
    dsa = require_mapping(discovery.get("dsa"), "discovery.dsa")
    firewall = require_mapping(discovery.get("firewall"), "discovery.firewall")

    root_key = discovery.get("root_ssh_key_configured")
    if root_key is None and isinstance(discovery.get("ssh"), dict):
        root_key = discovery["ssh"].get("root_ssh_key_configured")
    rollback_guard = require_mapping(
        discovery.get("rollback_guard"), "discovery.rollback_guard"
    )
    guard_armed = require_bool(
        rollback_guard.get("armed"), "discovery.rollback_guard.armed"
    )
    guard_change_id = str(rollback_guard.get("change_id", ""))
    if guard_armed:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", guard_change_id):
            fail("the armed OpenWrt rollback guard has an invalid change ID")
        fail(
            f"OpenWrt rollback guard {guard_change_id} is armed; preserve the existing plan and confirm or roll it back"
        )

    hashes: dict[str, str] = {}
    for name in ("network", "firewall", "dhcp"):
        value = str(configs.get(f"{name}_sha256", "")).lower()
        if not SHA256_RE.fullmatch(value):
            fail(f"discovery.configs.{name}_sha256 must be a lowercase SHA-256 digest")
        hashes[name] = value
    pending_changes = require_mapping(
        configs.get("pending_changes"), "discovery.configs.pending_changes"
    )
    for name in ("network", "firewall", "dhcp"):
        if require_bool(
            pending_changes.get(name), f"discovery.configs.pending_changes.{name}"
        ):
            fail(f"OpenWrt has uncommitted UCI changes in {name}")

    bridge_values = dsa.get("bridges")
    if bridge_values is None:
        bridge_values = [require_mapping(dsa.get("bridge"), "discovery.dsa.bridge")]
    bridges: list[dict[str, Any]] = []
    for index, item in enumerate(require_list(bridge_values, "discovery.dsa.bridges")):
        bridge = require_mapping(item, f"discovery.dsa.bridges[{index}]")
        ports = [
            require_uci_value(port, f"discovery.dsa.bridges[{index}].ports[]")
            for port in require_list(
                bridge.get("ports"), f"discovery.dsa.bridges[{index}].ports"
            )
        ]
        if len(ports) != len(set(ports)):
            fail(f"discovery.dsa.bridges[{index}].ports must be unique")
        bridges.append(
            {
                "section": require_uci_section_ref(
                    bridge.get("section"), f"discovery.dsa.bridges[{index}].section"
                ),
                "name": require_uci_value(
                    bridge.get("name"), f"discovery.dsa.bridges[{index}].name"
                ),
                "ports": ports,
            }
        )
    if not bridges or len({bridge["section"] for bridge in bridges}) != len(bridges):
        fail("discovery.dsa.bridges must contain unique bridge sections")

    bridge_vlans = require_list(dsa.get("bridge_vlans", []), "discovery.dsa.bridge_vlans")
    normalized_vlans: list[dict[str, Any]] = []
    for index, item in enumerate(bridge_vlans):
        entry = require_mapping(item, f"discovery.dsa.bridge_vlans[{index}]")
        vlan = entry.get("vlan")
        if isinstance(vlan, str) and vlan.isdigit():
            vlan = int(vlan)
        normalized_vlans.append(
            {
                "section": require_uci_section_ref(entry.get("section"), f"discovery.dsa.bridge_vlans[{index}].section"),
                "device": require_uci_value(entry.get("device"), f"discovery.dsa.bridge_vlans[{index}].device"),
                "vlan": require_int(vlan, f"discovery.dsa.bridge_vlans[{index}].vlan", 1, 4094),
                "ports": [str(port) for port in require_list(entry.get("ports", []), f"discovery.dsa.bridge_vlans[{index}].ports")],
            }
        )
    if len({item["section"] for item in normalized_vlans}) != len(normalized_vlans):
        fail("discovery.dsa.bridge_vlans contains duplicate section names")

    zones = require_list(firewall.get("zones"), "discovery.firewall.zones")
    normalized_zones: list[dict[str, Any]] = []
    for index, item in enumerate(zones):
        zone = require_mapping(item, f"discovery.firewall.zones[{index}]")
        normalized_zones.append(
            {
                "section": require_uci_section_ref(
                    zone.get("section"), f"discovery.firewall.zones[{index}].section"
                ),
                "name": require_uci_value(
                    zone.get("name"), f"discovery.firewall.zones[{index}].name"
                ),
                "masq": zone.get("masq", False),
            }
        )

    return {
        "inventory_hostname": require_string(discovery.get("inventory_hostname"), "discovery.inventory_hostname"),
        "board_name": require_string(discovery.get("board_name"), "discovery.board_name"),
        "release_target": require_string(release.get("target"), "discovery.release.target"),
        "release_version": require_string(release.get("version"), "discovery.release.version"),
        "dsa": require_bool(capabilities.get("dsa"), "discovery.capabilities.dsa"),
        "fw4": require_bool(capabilities.get("fw4"), "discovery.capabilities.fw4"),
        "dsa_evidence": require_string(
            capabilities.get("dsa_evidence"), "discovery.capabilities.dsa_evidence"
        ),
        "root_ssh_key_configured": require_bool(root_key, "discovery.root_ssh_key_configured"),
        "rollback_guard": {"armed": False, "change_id": guard_change_id},
        "config_hashes": hashes,
        "pending_changes": {name: False for name in ("network", "firewall", "dhcp")},
        "bridges": bridges,
        "bridge_vlans": normalized_vlans,
        "zones": normalized_zones,
        "network_uci": [
            require_string(line, "discovery.uci.network[]")
            for line in require_list(
                require_mapping(discovery.get("uci"), "discovery.uci").get("network"),
                "discovery.uci.network",
            )
        ],
        "dhcp_uci": [
            require_string(line, "discovery.uci.dhcp[]")
            for line in require_list(
                require_mapping(discovery.get("uci"), "discovery.uci").get("dhcp"),
                "discovery.uci.dhcp",
            )
        ],
    }


def validate_hardware(router: dict[str, Any], discovered: dict[str, Any]) -> dict[str, Any]:
    if router.get("ansible_user") != "root":
        fail("the OpenWrt Ansible user must be root")
    private_key = Path(require_string(router.get("ansible_ssh_private_key_file"), "ansible_ssh_private_key_file"))
    if not private_key.is_absolute():
        fail("ansible_ssh_private_key_file must be an absolute path")
    if router.get("require_root_ssh_key") is not True:
        fail("require_root_ssh_key must be true")
    if not discovered["root_ssh_key_configured"]:
        fail("OpenWrt root does not have a discovered SSH authorized key")
    if router.get("physical_console_available") is not True:
        fail("physical_console_available must be true for the first guarded DSA change")

    expected = require_mapping(router.get("expected"), "expected")
    expected_release = require_mapping(expected.get("release"), "expected.release")
    expected_capabilities = require_mapping(expected.get("capabilities"), "expected.capabilities")
    comparisons = (
        ("board_name", require_string(expected.get("board_name"), "expected.board_name"), discovered["board_name"]),
        ("release.target", require_string(expected_release.get("target"), "expected.release.target"), discovered["release_target"]),
        ("release.version", require_string(expected_release.get("version"), "expected.release.version"), discovered["release_version"]),
    )
    for path, expected_value, actual_value in comparisons:
        if expected_value != actual_value:
            fail(f"{path} mismatch: inventory={expected_value!r}, discovered={actual_value!r}")
    if not CONFIRMATION_BOARD_RE.fullmatch(discovered["board_name"]):
        fail("board_name cannot be represented safely in the confirmation token")
    for capability in ("dsa", "fw4"):
        if expected_capabilities.get(capability) is not True:
            fail(f"expected.capabilities.{capability} must be true")
        if discovered[capability] is not True:
            fail(f"the router does not provide required {capability} support")
    if discovered["dsa_evidence"] in {"none", "swconfig-present"}:
        fail("discovery does not contain positive DSA evidence")

    return {
        "private_key_file": str(private_key),
        "board_name": discovered["board_name"],
        "release": {"target": discovered["release_target"], "version": discovered["release_version"]},
        "capabilities": {
            "dsa": True,
            "fw4": True,
            "dsa_evidence": discovered["dsa_evidence"],
        },
    }


def management_dhcp_pool(
    discovered: dict[str, Any], management: ipaddress.IPv4Network
) -> tuple[ipaddress.IPv4Address, ipaddress.IPv4Address] | None:
    sections: dict[str, dict[str, str]] = {}
    types: dict[str, str] = {}
    for line in discovered["dhcp_uci"]:
        match = re.fullmatch(r"dhcp\.([A-Za-z0-9_-]+)(?:\.([A-Za-z0-9_-]+))?=(.*)", line)
        if not match:
            fail(f"discovery.uci.dhcp contains an unrecognized line: {line!r}")
        section, option, raw_value = match.groups()
        value = raw_value.strip()
        if len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1]
        if option is None:
            types[section] = value
        else:
            sections.setdefault(section, {})[option] = value

    lan_sections = [
        values
        for section, values in sections.items()
        if types.get(section) == "dhcp" and values.get("interface") == "lan"
    ]
    if len(lan_sections) > 1:
        fail("discovery contains more than one DHCP section for the lan interface")
    if not lan_sections:
        return None
    values = lan_sections[0]
    if values.get("ignore", "0") == "1" or values.get("dynamicdhcp", "1") == "0":
        return None

    start_text = values.get("start", "100")
    limit_text = values.get("limit", "150")
    try:
        limit = int(limit_text)
        if limit <= 0:
            raise ValueError
        if start_text.isdigit():
            start = ipaddress.IPv4Address(int(management.network_address) + int(start_text))
        else:
            start = parse_address(start_text, "OpenWrt lan DHCP start")
        end = ipaddress.IPv4Address(int(start) + limit - 1)
    except (ValueError, ipaddress.AddressValueError):
        fail("OpenWrt lan DHCP start/limit cannot be converted to a safe IPv4 pool")
    require_host_address(start, management, "OpenWrt lan DHCP pool start")
    require_host_address(end, management, "OpenWrt lan DHCP pool end")
    return start, end


def validate_networks(
    router: dict[str, Any],
    plan: dict[str, Any],
    cluster_config: dict[str, Any],
    discovered: dict[str, Any],
) -> dict[str, Any]:
    plan_host = require_mapping(plan.get("host"), "openstack plan host")
    openstack = require_mapping(plan.get("openstack"), "openstack plan openstack")
    kubernetes = require_mapping(plan.get("kubernetes"), "openstack plan kubernetes")
    cluster = require_mapping(cluster_config.get("cluster"), "cluster config cluster")
    nodes = require_mapping(cluster_config.get("nodes"), "cluster config nodes")
    enabled_nodes = {
        name: require_mapping(values, f"nodes.{name}")
        for name, values in nodes.items()
        if isinstance(values, dict) and values.get("enabled") is True
    }
    if len(enabled_nodes) < 3:
        fail("cluster config must contain at least three enabled nodes")
    if openstack.get("deployment") != "fresh-three-node-ceph":
        fail("openstack.deployment must be fresh-three-node-ceph")
    if cluster.get("storage_backend") != "ceph":
        fail("cluster.storage_backend must be ceph")
    ceph = require_mapping(cluster.get("ceph"), "cluster config cluster.ceph")
    if ceph.get("enabled") is not True:
        fail("cluster.ceph.enabled must be true")
    if kubernetes.get("initial_nodes") != 3:
        fail("kubernetes.initial_nodes must be 3")
    for name, values in enabled_nodes.items():
        if contains_replace(values):
            fail(f"enabled node {name} still contains a REPLACE value")

    management_interface = parse_interface(plan_host.get("management_address"), "host.management_address")
    management = management_interface.network
    external = parse_network(openstack.get("external_cidr"), "openstack.external_cidr")
    tenant = parse_network(openstack.get("tenant_cidr"), "openstack.tenant_cidr")
    networks = (("management", management), ("provider", external), ("tenant", tenant))
    for index, (left_name, left) in enumerate(networks):
        for right_name, right in networks[index + 1 :]:
            if left.overlaps(right):
                fail(f"{left_name} {left} overlaps {right_name} {right}")

    management_gateway = parse_address(plan_host.get("management_gateway"), "host.management_gateway")
    external_gateway = parse_address(openstack.get("external_gateway"), "openstack.external_gateway")
    tenant_gateway = parse_address(openstack.get("tenant_gateway"), "openstack.tenant_gateway")
    require_host_address(management_gateway, management, "host.management_gateway")
    require_host_address(external_gateway, external, "openstack.external_gateway")
    require_host_address(tenant_gateway, tenant, "openstack.tenant_gateway")

    external_vlan = require_int(openstack.get("external_vlan"), "openstack.external_vlan", 1, 4094)
    api_vip = parse_address(openstack.get("api_vip"), "openstack.api_vip")
    require_host_address(api_vip, management, "openstack.api_vip")
    if str(cluster.get("api_vip")) != str(api_vip):
        fail("cluster.api_vip does not match openstack plan openstack.api_vip")
    if str(plan_host.get("management_gateway")) != str(management_gateway):
        fail("openstack plan management gateway is not canonical")

    pool = require_mapping(openstack.get("floating_ip_pool"), "openstack.floating_ip_pool")
    pool_start = parse_address(pool.get("start"), "openstack.floating_ip_pool.start")
    pool_end = parse_address(pool.get("end"), "openstack.floating_ip_pool.end")
    require_host_address(pool_start, external, "openstack.floating_ip_pool.start")
    require_host_address(pool_end, external, "openstack.floating_ip_pool.end")
    if int(pool_start) > int(pool_end):
        fail("floating IP pool start must not be greater than its end")
    if int(pool_start) <= int(external_gateway) <= int(pool_end):
        fail("the provider gateway must be outside the floating IP pool")

    router_host = parse_address(router.get("ansible_host"), "ansible_host")
    if router_host != management_gateway:
        fail("router ansible_host must equal the management gateway")
    router_networks = require_mapping(router.get("networks"), "networks")
    declared_management = require_mapping(router_networks.get("management"), "networks.management")
    declared_provider = require_mapping(router_networks.get("provider"), "networks.provider")

    declarations = (
        ("networks.management.cidr", str(declared_management.get("cidr")), str(management)),
        ("networks.management.gateway", str(declared_management.get("gateway")), str(management_gateway)),
        ("networks.provider.cidr", str(declared_provider.get("cidr")), str(external)),
        ("networks.provider.gateway", str(declared_provider.get("gateway")), str(external_gateway)),
    )
    for path, declared, planned in declarations:
        if declared != planned:
            fail(f"{path}={declared!r} does not match OpenStack plan value {planned!r}")
    if declared_provider.get("vlan_id") != external_vlan:
        fail("networks.provider.vlan_id does not match openstack.external_vlan")
    native_vlan = require_int(declared_management.get("vlan_id"), "networks.management.vlan_id", 1, 4094)
    if native_vlan == external_vlan:
        fail("management and provider VLAN IDs must differ")

    declared_pool = require_mapping(declared_provider.get("floating_ip_pool"), "networks.provider.floating_ip_pool")
    if str(declared_pool.get("start")) != str(pool_start) or str(declared_pool.get("end")) != str(pool_end):
        fail("networks.provider.floating_ip_pool does not match the OpenStack plan")
    plan_node_name = str(plan_host.get("name", ""))
    if plan_node_name not in enabled_nodes:
        fail("openstack plan host.name must identify an enabled cluster node")
    if str(enabled_nodes[plan_node_name].get("management_address")) != str(management_interface):
        fail("openstack plan host management address does not match the selected cluster config")
    for name, node in enabled_nodes.items():
        node_interface = parse_interface(node.get("management_address"), f"nodes.{name}.management_address")
        if node_interface.network != management:
            fail(f"nodes.{name}.management_address is outside the planned management network")
        if str(node.get("management_gateway")) != str(management_gateway):
            fail(f"nodes.{name}.management_gateway does not match the OpenStack plan")
        if node.get("neutron_external_vlan_id") != external_vlan:
            fail(f"nodes.{name}.neutron_external_vlan_id does not match the OpenStack plan")
        if str(node.get("neutron_external_interface")) != str(openstack.get("external_interface")):
            fail(f"nodes.{name}.neutron_external_interface does not match the OpenStack plan")
        suffix = str(node.get("neutron_external_interface", "")).rsplit(".", 1)
        if len(suffix) != 2 or not suffix[1].isdigit() or int(suffix[1]) != external_vlan:
            fail(f"nodes.{name}.neutron_external_interface does not carry the planned VLAN")

    dhcp_pool = management_dhcp_pool(discovered, management)
    if dhcp_pool is not None:
        dhcp_start, dhcp_end = dhcp_pool
        reserved = {"OpenStack API VIP": api_vip, "management gateway": management_gateway}
        reserved.update(
            {
                f"{name} management address": ipaddress.ip_interface(node["management_address"]).ip
                for name, node in enabled_nodes.items()
            }
        )
        conflicts = [
            f"{name} {address}"
            for name, address in reserved.items()
            if int(dhcp_start) <= int(address) <= int(dhcp_end)
        ]
        if conflicts:
            fail(
                f"OpenWrt lan DHCP pool {dhcp_start}-{dhcp_end} overlaps reserved management addresses: "
                + ", ".join(conflicts)
            )

    declared_probes = declared_provider.get("probe_addresses")
    if declared_probes is None:
        fail("networks.provider.probe_addresses must map every enabled node to a unique address")
    declared_probes = require_mapping(declared_probes, "networks.provider.probe_addresses")
    deployed_nodes = [
        require_string(name, "networks.provider.deployed_nodes[]")
        for name in require_list(
            declared_provider.get("deployed_nodes", []), "networks.provider.deployed_nodes"
        )
    ]
    if len(deployed_nodes) != len(set(deployed_nodes)):
        fail("networks.provider.deployed_nodes must be unique")
    probe_nodes = set(declared_probes)
    deployed_node_set = set(deployed_nodes)
    if not probe_nodes:
        fail("networks.provider.probe_addresses must contain at least one newly prepared node")
    if probe_nodes & deployed_node_set:
        fail("provider probe nodes and already deployed nodes must be disjoint")
    if probe_nodes | deployed_node_set != set(enabled_nodes):
        fail("provider probe nodes plus deployed_nodes must contain exactly the enabled nodes")
    probes: dict[str, dict[str, str]] = {}
    deployed: dict[str, dict[str, str]] = {}
    probe_addresses: set[ipaddress.IPv4Address] = set()
    for name in sorted(probe_nodes):
        node = enabled_nodes[name]
        probe = parse_address(declared_probes[name], f"networks.provider.probe_addresses.{name}")
        require_host_address(probe, external, f"networks.provider.probe_addresses.{name}")
        if int(pool_start) <= int(probe) <= int(pool_end):
            fail(f"provider probe address for {name} must be outside the floating IP pool")
        if probe == external_gateway:
            fail(f"provider probe address for {name} must differ from the provider gateway")
        if probe in probe_addresses:
            fail("provider probe addresses must be unique")
        probe_addresses.add(probe)
        probes[name] = {
            "interface": str(node["neutron_external_interface"]),
            "temporary_cidr": f"{probe}/{external.prefixlen}",
            "gateway": str(external_gateway),
        }
    for name in sorted(deployed_node_set):
        deployed[name] = {
            "interface": str(enabled_nodes[name]["neutron_external_interface"]),
        }

    kubernetes_api_vip = parse_address(kubernetes.get("api_vip"), "kubernetes.api_vip")
    require_host_address(kubernetes_api_vip, tenant, "kubernetes.api_vip")

    primary_probe_name = sorted(probes)[0]
    return {
        "management": {
            "vlan_id": native_vlan,
            "cidr": str(management),
            "gateway": str(management_gateway),
            "api_vip": str(api_vip),
            "dhcp_dynamic_pool": (
                {"start": str(dhcp_pool[0]), "end": str(dhcp_pool[1])}
                if dhcp_pool is not None
                else None
            ),
        },
        "provider": {
            "vlan_id": external_vlan,
            "cidr": str(external),
            "gateway": str(external_gateway),
            "floating_ip_pool": {"start": str(pool_start), "end": str(pool_end)},
            "probe_address": str(
                parse_interface(probes[primary_probe_name]["temporary_cidr"], "provider probe").ip
            ),
            "temporary_cidr": probes[primary_probe_name]["temporary_cidr"],
            "probes": probes,
            "deployed": deployed,
            "deployed_nodes_without_temporary_probe": sorted(deployed_node_set),
        },
        "tenant": {"cidr": str(tenant), "gateway": str(tenant_gateway)},
    }


def validate_bridge(router: dict[str, Any], discovered: dict[str, Any], networks: dict[str, Any]) -> dict[str, Any]:
    desired = require_mapping(router.get("dsa_bridge"), "dsa_bridge")
    expected = {
        "section": require_uci_section_ref(desired.get("section"), "dsa_bridge.section"),
        "name": require_uci_value(desired.get("name"), "dsa_bridge.name"),
        "ports": [require_uci_value(port, "dsa_bridge.ports[]") for port in require_list(desired.get("ports"), "dsa_bridge.ports")],
        "management_ports": [require_uci_value(port, "dsa_bridge.management_ports[]") for port in require_list(desired.get("management_ports"), "dsa_bridge.management_ports")],
        "provider_tagged_ports": [require_uci_value(port, "dsa_bridge.provider_tagged_ports[]") for port in require_list(desired.get("provider_tagged_ports"), "dsa_bridge.provider_tagged_ports")],
    }
    for key in ("ports", "management_ports", "provider_tagged_ports"):
        values = expected[key]
        if not values or len(values) != len(set(values)):
            fail(f"dsa_bridge.{key} must be non-empty and unique")
        if any(not PORT_RE.fullmatch(value) for value in values):
            fail(f"dsa_bridge.{key} contains an invalid DSA port name")
    matching_bridges = [
        bridge for bridge in discovered["bridges"] if bridge["section"] == expected["section"]
    ]
    if len(matching_bridges) != 1:
        fail("dsa_bridge.section must select exactly one discovered DSA bridge")
    discovered_bridge = matching_bridges[0]
    if expected["name"] != discovered_bridge["name"]:
        fail("the discovered DSA bridge name does not exactly match dsa_bridge.name")
    if set(expected["ports"]) != set(discovered_bridge["ports"]):
        fail("the discovered DSA bridge ports do not exactly match dsa_bridge.ports")
    if set(expected["management_ports"]) != set(expected["ports"]):
        fail("dsa_bridge.management_ports must contain every current bridge port")
    if not set(expected["provider_tagged_ports"]) <= set(expected["management_ports"]):
        fail("dsa_bridge.provider_tagged_ports must be a subset of management_ports")
    if "network.lan=interface" not in discovered["network_uci"]:
        fail("the discovered UCI configuration does not contain the named lan interface")

    uci_values: dict[str, str] = {}
    for line in discovered["network_uci"]:
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1]
        uci_values[key] = value
    native_device = f"{expected['name']}.{networks['management']['vlan_id']}"
    lan_device = uci_values.get("network.lan.device")
    if lan_device not in {expected["name"], native_device}:
        fail("the discovered lan interface must use the selected DSA bridge or its managed VLAN")
    if uci_values.get("network.lan.proto") != "static":
        fail("the discovered lan interface must use a static address")
    management_network = ipaddress.ip_network(networks["management"]["cidr"])
    management_gateway = ipaddress.ip_address(networks["management"]["gateway"])
    lan_ip_text = uci_values.get("network.lan.ipaddr", "")
    if "/" in lan_ip_text:
        try:
            lan_interface = ipaddress.ip_interface(lan_ip_text)
        except ValueError as exc:
            fail(f"the discovered lan address is invalid: {exc}")
        if lan_interface.ip != management_gateway or lan_interface.network != management_network:
            fail("the discovered lan address does not match the management gateway and CIDR")
    else:
        if lan_ip_text != str(management_gateway):
            fail("the discovered lan address does not match the management gateway")
        if uci_values.get("network.lan.netmask") != str(management_network.netmask):
            fail("the discovered lan netmask does not match the management CIDR")

    desired_vlans = {networks["management"]["vlan_id"], networks["provider"]["vlan_id"]}
    managed_vlans = {
        item["section"]: item
        for item in discovered["bridge_vlans"]
        if item["section"] in MANAGED_BRIDGE_VLANS
    }
    if lan_device == expected["name"]:
        if managed_vlans:
            fail("managed bridge VLAN sections exist while lan still uses the unfiltered bridge")
    else:
        if set(managed_vlans) != MANAGED_BRIDGE_VLANS:
            fail("the managed lan VLAN device requires both managed bridge VLAN sections")
        required_managed_vlans = {
            "os_management_vlan": {
                "device": expected["name"],
                "vlan": networks["management"]["vlan_id"],
            },
            "os_provider_vlan": {
                "device": expected["name"],
                "vlan": networks["provider"]["vlan_id"],
            },
        }
        for section, wanted in required_managed_vlans.items():
            actual = managed_vlans[section]
            if actual["device"] != wanted["device"] or actual["vlan"] != wanted["vlan"]:
                fail(f"managed bridge VLAN section {section} does not match the inventory")
            actual_ports = actual["ports"]
            if not actual_ports or len(actual_ports) != len(set(actual_ports)):
                fail(f"managed bridge VLAN section {section} has invalid ports")
        expected_management_ports = {
            f"{port}:u*" for port in expected["management_ports"]
        }
        if set(managed_vlans["os_management_vlan"]["ports"]) != expected_management_ports:
            fail("managed bridge VLAN section os_management_vlan ports do not match the inventory")
        desired_provider_ports = {
            f"{port}:t" for port in expected["provider_tagged_ports"]
        }
        current_provider_ports = set(managed_vlans["os_provider_vlan"]["ports"])
        if not current_provider_ports <= desired_provider_ports:
            fail("managed bridge VLAN section os_provider_vlan has ports outside the inventory")
    for existing in discovered["bridge_vlans"]:
        if existing["section"] in MANAGED_BRIDGE_VLANS:
            continue
        if existing["device"] == expected["name"] and existing["vlan"] in desired_vlans:
            fail(
                f"unmanaged bridge-vlan section {existing['section']} conflicts with "
                f"{expected['name']} VLAN {existing['vlan']}"
            )

    lan_zones = [zone for zone in discovered["zones"] if zone.get("name") == "lan"]
    if len(lan_zones) != 1:
        fail("the discovered firewall must contain exactly one lan zone")
    wan_zones = [zone for zone in discovered["zones"] if zone.get("name") == "wan"]
    if len(wan_zones) != 1:
        fail("the discovered firewall must contain exactly one wan zone")
    masq = wan_zones[0].get("masq")
    if masq not in (True, 1, "1", "true", "yes", "on"):
        fail("the discovered wan firewall zone must have masquerading enabled")
    provider_zones = [zone for zone in discovered["zones"] if zone.get("name") == "os_provider"]
    if len(provider_zones) > 1 or any(
        zone.get("section") != "os_provider_zone" for zone in provider_zones
    ):
        fail("an unmanaged or duplicate os_provider firewall zone already exists")
    return expected


def uci_quote(value: Any) -> str:
    text = require_uci_value(str(value), "rendered UCI value")
    return f"'{text}'"


def render_uci_batch(bridge: dict[str, Any], networks: dict[str, Any]) -> str:
    management = networks["management"]
    provider = networks["provider"]
    native_device = f"{bridge['name']}.{management['vlan_id']}"
    provider_device = f"{bridge['name']}.{provider['vlan_id']}"
    provider_network = ipaddress.ip_network(provider["cidr"])
    lines = [
        "# Generated by scripts/internal/render-openwrt-plan.py; review before uci -q batch.",
        "delete network.os_management_vlan",
        "set network.os_management_vlan=bridge-vlan",
        f"set network.os_management_vlan.device={uci_quote(bridge['name'])}",
        f"set network.os_management_vlan.vlan={uci_quote(management['vlan_id'])}",
    ]
    lines.extend(
        f"add_list network.os_management_vlan.ports={uci_quote(port + ':u*')}"
        for port in bridge["management_ports"]
    )
    lines.extend(
        [
            "delete network.os_provider_vlan",
            "set network.os_provider_vlan=bridge-vlan",
            f"set network.os_provider_vlan.device={uci_quote(bridge['name'])}",
            f"set network.os_provider_vlan.vlan={uci_quote(provider['vlan_id'])}",
        ]
    )
    lines.extend(
        f"add_list network.os_provider_vlan.ports={uci_quote(port + ':t')}"
        for port in bridge["provider_tagged_ports"]
    )
    lines.extend(
        [
            f"set network.lan.device={uci_quote(native_device)}",
            "delete network.os_provider",
            "set network.os_provider=interface",
            f"set network.os_provider.device={uci_quote(provider_device)}",
            "set network.os_provider.proto='static'",
            f"set network.os_provider.ipaddr={uci_quote(provider['gateway'])}",
            f"set network.os_provider.netmask={uci_quote(provider_network.netmask)}",
            "delete dhcp.os_provider",
            "set dhcp.os_provider=dhcp",
            "set dhcp.os_provider.interface='os_provider'",
            "set dhcp.os_provider.ignore='1'",
            "set dhcp.os_provider.dhcpv4='disabled'",
            "set dhcp.os_provider.dhcpv6='disabled'",
            "set dhcp.os_provider.ra='disabled'",
            "set dhcp.os_provider.ndp='disabled'",
            "delete firewall.os_provider_zone",
            "set firewall.os_provider_zone=zone",
            "set firewall.os_provider_zone.name='os_provider'",
            "add_list firewall.os_provider_zone.network='os_provider'",
            "set firewall.os_provider_zone.input='REJECT'",
            "set firewall.os_provider_zone.output='ACCEPT'",
            "set firewall.os_provider_zone.forward='REJECT'",
            "delete firewall.os_provider_to_wan",
            "set firewall.os_provider_to_wan=forwarding",
            "set firewall.os_provider_to_wan.src='os_provider'",
            "set firewall.os_provider_to_wan.dest='wan'",
            "delete firewall.lan_to_os_provider",
            "set firewall.lan_to_os_provider=forwarding",
            "set firewall.lan_to_os_provider.src='lan'",
            "set firewall.lan_to_os_provider.dest='os_provider'",
            "delete firewall.os_provider_to_lan_reject",
            "set firewall.os_provider_to_lan_reject=rule",
            "set firewall.os_provider_to_lan_reject.name='Reject-OpenStack-Provider-to-LAN'",
            "set firewall.os_provider_to_lan_reject.src='os_provider'",
            "set firewall.os_provider_to_lan_reject.dest='lan'",
            "set firewall.os_provider_to_lan_reject.proto='all'",
            "set firewall.os_provider_to_lan_reject.target='REJECT'",
            "delete firewall.os_provider_dns",
            "set firewall.os_provider_dns=rule",
            "set firewall.os_provider_dns.name='Allow-OpenStack-Provider-DNS'",
            "set firewall.os_provider_dns.src='os_provider'",
            "set firewall.os_provider_dns.proto='tcp udp'",
            "set firewall.os_provider_dns.dest_port='53'",
            "set firewall.os_provider_dns.family='ipv4'",
            "set firewall.os_provider_dns.target='ACCEPT'",
            "delete firewall.os_provider_icmp_echo",
            "set firewall.os_provider_icmp_echo=rule",
            "set firewall.os_provider_icmp_echo.name='Allow-OpenStack-Provider-ICMP-Echo'",
            "set firewall.os_provider_icmp_echo.src='os_provider'",
            "set firewall.os_provider_icmp_echo.proto='icmp'",
            "set firewall.os_provider_icmp_echo.icmp_type='echo-request'",
            "set firewall.os_provider_icmp_echo.family='ipv4'",
            "set firewall.os_provider_icmp_echo.target='ACCEPT'",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    repo = Path(__file__).resolve().parent.parent.parent
    local_openstack_plan = repo / "inventory/openstack-plan.local.yml"
    default_openstack_plan = (
        local_openstack_plan
        if local_openstack_plan.exists()
        else repo / "inventory/openstack-plan.yml"
    )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, default=repo / "inventory/openwrt-router.local.yml")
    parser.add_argument("--openstack-plan", type=Path, default=default_openstack_plan)
    parser.add_argument("--cluster-config", type=Path)
    parser.add_argument("--discovery", type=Path, default=repo / ".cache/openwrt/discovery.json")
    parser.add_argument("--output-dir", type=Path, default=repo / ".cache/openwrt")
    args = parser.parse_args()
    cluster_path = select_cluster_config(repo, args.cluster_config)

    inventory = load_yaml(args.inventory)
    openstack_plan = load_yaml(args.openstack_plan)
    cluster_config = load_yaml(cluster_path)
    discovery_document = load_json(args.discovery)
    router_name, router = single_router(inventory)
    discovered = discovery_fields(discovery_document)
    if discovered["inventory_hostname"] != router_name:
        fail("discovery.inventory_hostname does not match the selected router inventory")
    hardware = validate_hardware(router, discovered)
    networks = validate_networks(router, openstack_plan, cluster_config, discovered)
    bridge = validate_bridge(router, discovered, networks)
    batch = render_uci_batch(bridge, networks)
    batch_hash = sha256_bytes(batch.encode())

    source_paths = {
        "router_inventory": args.inventory,
        "openstack_plan": args.openstack_plan,
        "cluster_config": cluster_path,
        "discovery": args.discovery,
    }
    provenance = {
        name: {"path": str(path.resolve()), "sha256": sha256_file(path)}
        for name, path in source_paths.items()
    }
    preconditions = {
        "network_sha256": discovered["config_hashes"]["network"],
        "firewall_sha256": discovered["config_hashes"]["firewall"],
        "dhcp_sha256": discovered["config_hashes"]["dhcp"],
    }
    preconditions["configs"] = {
        "network_sha256": preconditions["network_sha256"],
        "firewall_sha256": preconditions["firewall_sha256"],
        "dhcp_sha256": preconditions["dhcp_sha256"],
    }
    router_port = require_int(router.get("ansible_port", 22), "ansible_port", 1, 65535)
    timeouts = require_mapping(router.get("timeouts", {}), "timeouts")
    timeout_values = {
        "rollback_seconds": require_int(timeouts.get("rollback_seconds", 180), "timeouts.rollback_seconds", 120, 1800),
        "ssh_return_seconds": require_int(timeouts.get("ssh_return_seconds", 120), "timeouts.ssh_return_seconds", 30, 900),
    }
    if timeout_values["ssh_return_seconds"] > timeout_values["rollback_seconds"]:
        fail("timeouts.ssh_return_seconds must not exceed rollback_seconds")
    digest_material = {
        "schema_version": 1,
        "source_sha256": {name: values["sha256"] for name, values in provenance.items()},
        "preconditions": preconditions,
        "router": {
            "name": router_name,
            "host": str(router["ansible_host"]),
            "user": "root",
            "port": router_port,
            "board_name": hardware["board_name"],
            "release": hardware["release"],
            "capabilities": hardware["capabilities"],
        },
        "bridge": bridge,
        "networks": networks,
        "uci_batch_sha256": batch_hash,
    }
    digest = canonical_digest(digest_material)
    change_id = f"openwrt-{digest[:24]}"
    ports_token = ",".join(bridge["provider_tagged_ports"])
    apply_confirmation = (
        f"APPLY-OPENWRT:{hardware['board_name']}:{ports_token}:"
        f"vlan{networks['provider']['vlan_id']}:{digest}"
    )
    rollback_confirmation = (
        f"ROLLBACK-OPENWRT:{hardware['board_name']}:{ports_token}:"
        f"vlan{networks['provider']['vlan_id']}:{digest}"
    )
    confirm_confirmation = f"CONFIRM-OPENWRT:{change_id}:{digest}"
    provider_network = ipaddress.ip_network(networks["provider"]["cidr"])
    verification = {
        "uci_equals": {
            "network.os_management_vlan.device": bridge["name"],
            "network.os_management_vlan.vlan": str(networks["management"]["vlan_id"]),
            "network.os_management_vlan.ports": " ".join(
                f"{port}:u*" for port in bridge["management_ports"]
            ),
            "network.os_provider_vlan.device": bridge["name"],
            "network.os_provider_vlan.vlan": str(networks["provider"]["vlan_id"]),
            "network.os_provider_vlan.ports": " ".join(
                f"{port}:t" for port in bridge["provider_tagged_ports"]
            ),
            "network.lan.device": f"{bridge['name']}.{networks['management']['vlan_id']}",
            "network.os_provider.device": f"{bridge['name']}.{networks['provider']['vlan_id']}",
            "network.os_provider.proto": "static",
            "network.os_provider.ipaddr": networks["provider"]["gateway"],
            "network.os_provider.netmask": str(provider_network.netmask),
            "dhcp.os_provider.interface": "os_provider",
            "dhcp.os_provider.ignore": "1",
            "dhcp.os_provider.dhcpv4": "disabled",
            "dhcp.os_provider.dhcpv6": "disabled",
            "dhcp.os_provider.ra": "disabled",
            "dhcp.os_provider.ndp": "disabled",
            "firewall.os_provider_zone.name": "os_provider",
            "firewall.os_provider_zone.network": "os_provider",
            "firewall.os_provider_zone.input": "REJECT",
            "firewall.os_provider_zone.output": "ACCEPT",
            "firewall.os_provider_zone.forward": "REJECT",
            "firewall.os_provider_to_wan.src": "os_provider",
            "firewall.os_provider_to_wan.dest": "wan",
            "firewall.lan_to_os_provider.src": "lan",
            "firewall.lan_to_os_provider.dest": "os_provider",
            "firewall.os_provider_to_lan_reject.target": "REJECT",
            "firewall.os_provider_dns.dest_port": "53",
            "firewall.os_provider_dns.target": "ACCEPT",
            "firewall.os_provider_icmp_echo.icmp_type": "echo-request",
            "firewall.os_provider_icmp_echo.target": "ACCEPT",
        },
        "interfaces_up": ["lan", "os_provider"],
        "router_ping_targets": sorted(
            str(ipaddress.ip_interface(node["management_address"]).ip)
            for node in require_mapping(cluster_config["nodes"], "cluster config nodes").values()
            if isinstance(node, dict) and node.get("enabled") is True
        ),
    }
    plan = {
        "schema_version": 1,
        "change_id": change_id,
        "digest": digest,
        "provenance": provenance,
        "preconditions": preconditions,
        "router": {
            "name": router_name,
            "host": str(router["ansible_host"]),
            "user": "root",
            "port": router_port,
            "private_key_file": hardware["private_key_file"],
            "board_name": hardware["board_name"],
            "release": hardware["release"],
            "capabilities": hardware["capabilities"],
        },
        "bridge": bridge,
        "management": networks["management"],
        "provider": networks["provider"],
        "tenant": networks["tenant"],
        "preflight": {
            "require_root_ssh_key": True,
            "require_physical_console": True,
            "require_dsa": True,
            "require_fw4": True,
            "require_wan_masquerade": True,
        },
        "uci_batch": {"path": str((args.output_dir / "uci.batch").resolve()), "sha256": batch_hash},
        "artifacts": {"uci_batch_sha256": batch_hash},
        "confirmations": {
            "apply": apply_confirmation,
            "confirm": confirm_confirmation,
            "rollback": rollback_confirmation,
        },
        "verification": verification,
        "timeouts": timeout_values,
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "uci.batch").write_text(batch)
    (args.output_dir / "plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    print(f"Rendered OpenWrt plan for {router_name} ({hardware['board_name']})")
    print(f"Plan: {args.output_dir / 'plan.json'}")
    print(f"UCI batch: {args.output_dir / 'uci.batch'}")
    print(f"Required confirmation: {apply_confirmation}")


if __name__ == "__main__":
    main()
