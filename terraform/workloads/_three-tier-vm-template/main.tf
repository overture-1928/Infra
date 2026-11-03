locals {
  web_instances         = var.enable_resources ? var.web_instances : {}
  application_instances = var.enable_resources ? var.application_instances : {}
  database_instances    = var.enable_resources ? var.database_instances : {}

  web_ingress_rules = {
    for pair in setproduct(var.ingress_cidrs, var.web_ports) :
    "${pair[0]}:${pair[1]}" => { cidr = pair[0], port = pair[1] }
  }
  application_ingress_rules = {
    for port in var.application_ports : tostring(port) => port
  }
  database_ingress_rules = {
    for port in var.database_ports : tostring(port) => port
  }
}

check "tier_population" {
  assert {
    condition = !var.enable_resources || (
      length(var.web_instances) > 0 &&
      length(var.application_instances) > 0 &&
      length(var.database_instances) > 0
    )
    error_message = "An enabled three-tier stack requires at least one web, application and database instance."
  }
}

check "gateway_membership" {
  assert {
    condition = (
      cidrcontains(var.web_cidr, var.web_gateway) &&
      cidrcontains(var.application_cidr, var.application_gateway) &&
      cidrcontains(var.database_cidr, var.database_gateway)
    )
    error_message = "Every tier gateway must belong to its tier CIDR."
  }
}

check "non_overlapping_tier_cidrs" {
  assert {
    condition = (
      !cidrcontains(var.web_cidr, cidrhost(var.application_cidr, 0)) &&
      !cidrcontains(var.application_cidr, cidrhost(var.web_cidr, 0)) &&
      !cidrcontains(var.web_cidr, cidrhost(var.database_cidr, 0)) &&
      !cidrcontains(var.database_cidr, cidrhost(var.web_cidr, 0)) &&
      !cidrcontains(var.application_cidr, cidrhost(var.database_cidr, 0)) &&
      !cidrcontains(var.database_cidr, cidrhost(var.application_cidr, 0))
    )
    error_message = "Web, application and database CIDRs must not overlap."
  }
}

check "fixed_ip_membership" {
  assert {
    condition = (
      alltrue([for instance in values(var.web_instances) : instance.fixed_ip == null ? true : cidrcontains(var.web_cidr, instance.fixed_ip)]) &&
      alltrue([for instance in values(var.application_instances) : instance.fixed_ip == null ? true : cidrcontains(var.application_cidr, instance.fixed_ip)]) &&
      alltrue([for instance in values(var.database_instances) : instance.fixed_ip == null ? true : cidrcontains(var.database_cidr, instance.fixed_ip)])
    )
    error_message = "Every fixed IP must belong to the CIDR of its tier."
  }
}

resource "openstack_networking_router_v2" "this" {
  count = var.enable_resources ? 1 : 0

  name                = "${var.workload_name}-router"
  admin_state_up      = true
  external_network_id = var.external_network_id
  enable_snat         = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_networking_network_v2" "web" {
  count = var.enable_resources ? 1 : 0

  name           = "${var.workload_name}-web"
  admin_state_up = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_networking_network_v2" "application" {
  count = var.enable_resources ? 1 : 0

  name           = "${var.workload_name}-application"
  admin_state_up = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_networking_network_v2" "database" {
  count = var.enable_resources ? 1 : 0

  name           = "${var.workload_name}-database"
  admin_state_up = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_networking_subnet_v2" "web" {
  count = var.enable_resources ? 1 : 0

  name            = "${var.workload_name}-web"
  network_id      = openstack_networking_network_v2.web[0].id
  cidr            = var.web_cidr
  gateway_ip      = var.web_gateway
  dns_nameservers = var.dns_nameservers
  ip_version      = 4

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_networking_subnet_v2" "application" {
  count = var.enable_resources ? 1 : 0

  name            = "${var.workload_name}-application"
  network_id      = openstack_networking_network_v2.application[0].id
  cidr            = var.application_cidr
  gateway_ip      = var.application_gateway
  dns_nameservers = var.dns_nameservers
  ip_version      = 4

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_networking_subnet_v2" "database" {
  count = var.enable_resources ? 1 : 0

  name            = "${var.workload_name}-database"
  network_id      = openstack_networking_network_v2.database[0].id
  cidr            = var.database_cidr
  gateway_ip      = var.database_gateway
  dns_nameservers = var.dns_nameservers
  ip_version      = 4

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_networking_router_interface_v2" "web" {
  count = var.enable_resources ? 1 : 0

  router_id = openstack_networking_router_v2.this[0].id
  subnet_id = openstack_networking_subnet_v2.web[0].id
}

resource "openstack_networking_router_interface_v2" "application" {
  count = var.enable_resources ? 1 : 0

  router_id = openstack_networking_router_v2.this[0].id
  subnet_id = openstack_networking_subnet_v2.application[0].id
}

resource "openstack_networking_router_interface_v2" "database" {
  count = var.enable_resources ? 1 : 0

  router_id = openstack_networking_router_v2.this[0].id
  subnet_id = openstack_networking_subnet_v2.database[0].id
}

resource "openstack_networking_secgroup_v2" "web" {
  count = var.enable_resources ? 1 : 0

  name        = "${var.workload_name}-web"
  description = "Ingress tier for ${var.workload_name}"
}

resource "openstack_networking_secgroup_v2" "application" {
  count = var.enable_resources ? 1 : 0

  name        = "${var.workload_name}-application"
  description = "Application tier for ${var.workload_name}"
}

resource "openstack_networking_secgroup_v2" "database" {
  count = var.enable_resources ? 1 : 0

  name        = "${var.workload_name}-database"
  description = "Database tier for ${var.workload_name}"
}

resource "openstack_networking_secgroup_rule_v2" "web_ssh" {
  count = var.enable_resources ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.admin_cidr
  security_group_id = openstack_networking_secgroup_v2.web[0].id
}

resource "openstack_networking_secgroup_rule_v2" "application_ssh" {
  count = var.enable_resources ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.admin_cidr
  security_group_id = openstack_networking_secgroup_v2.application[0].id
}

resource "openstack_networking_secgroup_rule_v2" "database_ssh" {
  count = var.enable_resources ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.admin_cidr
  security_group_id = openstack_networking_secgroup_v2.database[0].id
}

resource "openstack_networking_secgroup_rule_v2" "web_ingress" {
  for_each = var.enable_resources ? local.web_ingress_rules : {}

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value.port
  port_range_max    = each.value.port
  remote_ip_prefix  = each.value.cidr
  security_group_id = openstack_networking_secgroup_v2.web[0].id
}

resource "openstack_networking_secgroup_rule_v2" "application_from_web" {
  for_each = var.enable_resources ? local.application_ingress_rules : {}

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value
  port_range_max    = each.value
  remote_group_id   = openstack_networking_secgroup_v2.web[0].id
  security_group_id = openstack_networking_secgroup_v2.application[0].id
}

resource "openstack_networking_secgroup_rule_v2" "database_from_application" {
  for_each = var.enable_resources ? local.database_ingress_rules : {}

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value
  port_range_max    = each.value
  remote_group_id   = openstack_networking_secgroup_v2.application[0].id
  security_group_id = openstack_networking_secgroup_v2.database[0].id
}

resource "openstack_networking_secgroup_rule_v2" "web_internal" {
  count = var.enable_resources ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.web[0].id
  security_group_id = openstack_networking_secgroup_v2.web[0].id
}

resource "openstack_networking_secgroup_rule_v2" "application_internal" {
  count = var.enable_resources ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.application[0].id
  security_group_id = openstack_networking_secgroup_v2.application[0].id
}

resource "openstack_networking_secgroup_rule_v2" "database_internal" {
  count = var.enable_resources ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.database[0].id
  security_group_id = openstack_networking_secgroup_v2.database[0].id
}

resource "openstack_compute_servergroup_v2" "web" {
  count = var.enable_resources ? 1 : 0

  name     = "${var.workload_name}-web"
  policies = ["soft-anti-affinity"]
}

resource "openstack_compute_servergroup_v2" "application" {
  count = var.enable_resources ? 1 : 0

  name     = "${var.workload_name}-application"
  policies = ["soft-anti-affinity"]
}

resource "openstack_compute_servergroup_v2" "database" {
  count = var.enable_resources ? 1 : 0

  name     = "${var.workload_name}-database"
  policies = ["soft-anti-affinity"]
}

module "web" {
  source   = "../../modules/openstack-vm"
  for_each = local.web_instances

  name               = "${var.workload_name}-web-${each.key}"
  network_id         = openstack_networking_network_v2.web[0].id
  subnet_id          = openstack_networking_subnet_v2.web[0].id
  image_id           = var.image_id
  flavor_id          = each.value.flavor_id == null ? var.web_flavor_id : each.value.flavor_id
  security_group_ids = toset([openstack_networking_secgroup_v2.web[0].id])
  root_volume_size   = each.value.root_volume_size
  root_volume_type   = var.root_volume_type
  fixed_ip           = each.value.fixed_ip
  key_pair           = var.key_pair
  server_group_id    = openstack_compute_servergroup_v2.web[0].id
  metadata = merge(each.value.metadata, {
    tier       = "web"
    HA_Enabled = each.value.ha_enabled ? "True" : "False"
  })

  depends_on = [openstack_networking_router_interface_v2.web]
}

module "application" {
  source   = "../../modules/openstack-vm"
  for_each = local.application_instances

  name               = "${var.workload_name}-application-${each.key}"
  network_id         = openstack_networking_network_v2.application[0].id
  subnet_id          = openstack_networking_subnet_v2.application[0].id
  image_id           = var.image_id
  flavor_id          = each.value.flavor_id == null ? var.application_flavor_id : each.value.flavor_id
  security_group_ids = toset([openstack_networking_secgroup_v2.application[0].id])
  root_volume_size   = each.value.root_volume_size
  root_volume_type   = var.root_volume_type
  fixed_ip           = each.value.fixed_ip
  key_pair           = var.key_pair
  server_group_id    = openstack_compute_servergroup_v2.application[0].id
  metadata = merge(each.value.metadata, {
    tier       = "application"
    HA_Enabled = each.value.ha_enabled ? "True" : "False"
  })

  depends_on = [openstack_networking_router_interface_v2.application]
}

module "database" {
  source   = "../../modules/openstack-vm"
  for_each = local.database_instances

  name               = "${var.workload_name}-database-${each.key}"
  network_id         = openstack_networking_network_v2.database[0].id
  subnet_id          = openstack_networking_subnet_v2.database[0].id
  image_id           = var.image_id
  flavor_id          = each.value.flavor_id == null ? var.database_flavor_id : each.value.flavor_id
  security_group_ids = toset([openstack_networking_secgroup_v2.database[0].id])
  root_volume_size   = each.value.root_volume_size
  root_volume_type   = var.root_volume_type
  fixed_ip           = each.value.fixed_ip
  key_pair           = var.key_pair
  server_group_id    = openstack_compute_servergroup_v2.database[0].id
  metadata = merge(each.value.metadata, {
    tier       = "database"
    HA_Enabled = each.value.ha_enabled ? "True" : "False"
  })

  depends_on = [openstack_networking_router_interface_v2.database]
}

resource "openstack_blockstorage_volume_v3" "database_data" {
  for_each = local.database_instances

  name        = "${var.workload_name}-database-${each.key}-data"
  size        = each.value.data_volume_size
  volume_type = each.value.data_volume_type == null ? var.database_data_volume_type : each.value.data_volume_type

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_compute_volume_attach_v2" "database_data" {
  for_each = local.database_instances

  instance_id = module.database[each.key].instance_id
  volume_id   = openstack_blockstorage_volume_v3.database_data[each.key].id
}
