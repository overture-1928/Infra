locals {
  enabled_instances = var.enable_instances ? var.instances : {}
  default_flavor_id = var.managed_flavor == null ? var.flavor_id : try(openstack_compute_flavor_v2.workload[0].id, null)
}

check "flavor_source" {
  assert {
    condition = (
      !var.enable_instances ||
      var.managed_flavor != null ||
      var.flavor_id != null ||
      alltrue([for instance in values(var.instances) : instance.flavor_id != null])
    )
    error_message = "Set flavor_id, managed_flavor, or a flavor_id override on every enabled instance."
  }

  assert {
    condition     = var.managed_flavor == null || var.flavor_id == null
    error_message = "Set only one default flavor source: flavor_id or managed_flavor."
  }

  assert {
    condition     = var.host_aggregate == null || var.managed_flavor != null
    error_message = "host_aggregate is supported together with managed_flavor."
  }
}

resource "openstack_compute_aggregate_v2" "workload" {
  count = var.enable_instances && var.host_aggregate != null ? 1 : 0

  name     = var.host_aggregate.name
  zone     = var.host_aggregate.zone
  hosts    = sort(tolist(var.host_aggregate.hosts))
  metadata = var.host_aggregate.metadata

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_compute_flavor_v2" "workload" {
  count = var.enable_instances && var.managed_flavor != null ? 1 : 0

  name        = var.managed_flavor.name
  ram         = var.managed_flavor.ram
  vcpus       = var.managed_flavor.vcpus
  disk        = var.managed_flavor.disk
  is_public   = var.managed_flavor.is_public
  extra_specs = var.managed_flavor.extra_specs

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [openstack_compute_aggregate_v2.workload]
}

resource "openstack_networking_secgroup_v2" "workload" {
  count = var.enable_instances ? 1 : 0

  name        = "${var.workload_name}-instances"
  description = "Ingress managed by the ${var.workload_name} Terraform workload root"
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  count = var.enable_instances && var.ssh_ingress_cidr != null ? 1 : 0

  direction         = "ingress"
  ethertype         = strcontains(var.ssh_ingress_cidr == null ? "" : var.ssh_ingress_cidr, ":") ? "IPv6" : "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.ssh_ingress_cidr
  security_group_id = openstack_networking_secgroup_v2.workload[0].id
}

resource "openstack_networking_secgroup_rule_v2" "internal" {
  count = var.enable_instances && var.internal_ingress_cidr != null ? 1 : 0

  direction         = "ingress"
  ethertype         = strcontains(var.internal_ingress_cidr == null ? "" : var.internal_ingress_cidr, ":") ? "IPv6" : "IPv4"
  remote_ip_prefix  = var.internal_ingress_cidr
  security_group_id = openstack_networking_secgroup_v2.workload[0].id
}

resource "openstack_networking_secgroup_rule_v2" "additional" {
  for_each = var.enable_instances ? var.additional_ingress_rules : {}

  direction         = "ingress"
  ethertype         = each.value.ethertype
  protocol          = each.value.protocol
  port_range_min    = each.value.port_range_min
  port_range_max    = each.value.port_range_max
  remote_ip_prefix  = each.value.remote_ip_prefix
  security_group_id = openstack_networking_secgroup_v2.workload[0].id
}

module "instance" {
  source   = "../../modules/openstack-vm"
  for_each = local.enabled_instances

  name       = "${var.workload_name}-${each.key}"
  network_id = var.network_id
  subnet_id  = var.subnet_id
  image_id   = each.value.image_id == null ? var.image_id : each.value.image_id
  flavor_id  = each.value.flavor_id == null ? local.default_flavor_id : each.value.flavor_id
  security_group_ids = setunion(
    var.additional_security_group_ids,
    toset([openstack_networking_secgroup_v2.workload[0].id]),
  )

  root_volume_size = each.value.root_volume_size
  root_volume_type = each.value.root_volume_type
  fixed_ip         = each.value.fixed_ip
  key_pair         = each.value.key_pair
  user_data        = each.value.user_data
  server_group_id  = each.value.server_group_id
  config_drive     = each.value.config_drive
  metadata         = merge(each.value.metadata, { workload = var.workload_name })

  floating_ip_pool      = each.value.associate_floating_ip ? var.floating_ip_pool : null
  floating_ip_subnet_id = each.value.associate_floating_ip ? var.floating_ip_subnet_id : null
  floating_ip_address   = each.value.associate_floating_ip ? each.value.floating_ip_address : null

  depends_on = [
    openstack_networking_secgroup_rule_v2.ssh,
    openstack_networking_secgroup_rule_v2.internal,
    openstack_networking_secgroup_rule_v2.additional,
  ]
}
