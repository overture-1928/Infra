locals {
  enabled_instances = var.enable_instances ? var.instances : {}
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
  flavor_id  = each.value.flavor_id == null ? var.flavor_id : each.value.flavor_id
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
