locals {
  nodes                   = var.enable_resources ? var.kubernetes_nodes : {}
  kubernetes_internal_vip = cidrhost(var.tenant_cidr, var.kubernetes_api_host_number)
  router_external_ip      = cidrhost(var.external_cidr, 2)
}

data "openstack_images_image_v2" "ubuntu" {
  count       = var.enable_resources ? 1 : 0
  name        = var.image_name
  most_recent = true
}

resource "openstack_compute_keypair_v2" "operator" {
  count      = var.enable_resources ? 1 : 0
  name       = "operator"
  public_key = trimspace(var.ssh_public_key)
}

resource "openstack_compute_flavor_v2" "kubernetes" {
  count     = var.enable_resources ? 1 : 0
  name      = "kubernetes.medium"
  ram       = 8192
  vcpus     = 4
  disk      = 0
  is_public = false
}

resource "openstack_blockstorage_volume_type_v3" "ceph" {
  count = var.enable_resources ? 1 : 0
  name  = "ceph"
  extra_specs = {
    volume_backend_name = "ceph-rbd"
  }
}

resource "openstack_compute_servergroup_v2" "kubernetes_control" {
  count = var.enable_resources ? 1 : 0
  name  = "kubernetes-control-plane"
  # Spread normally, but permit an evacuated control-plane VM to share one of
  # the two surviving computes after a physical host failure.
  policies = ["soft-anti-affinity"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_compute_servergroup_v2" "kubernetes_workers" {
  count    = var.enable_resources ? 1 : 0
  name     = "kubernetes-workers"
  policies = ["soft-anti-affinity"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_networking_network_v2" "public" {
  count          = var.enable_resources ? 1 : 0
  name           = "public"
  admin_state_up = true
  external       = true
  shared         = true

  segments {
    network_type     = "flat"
    physical_network = "physnet1"
  }
}

resource "openstack_networking_subnet_v2" "public" {
  count           = var.enable_resources ? 1 : 0
  name            = "public-vlan10"
  network_id      = openstack_networking_network_v2.public[0].id
  cidr            = var.external_cidr
  ip_version      = 4
  gateway_ip      = var.external_gateway
  enable_dhcp     = false
  dns_nameservers = var.external_dns

  allocation_pool {
    start = var.floating_ip_pool.start
    end   = var.floating_ip_pool.end
  }
}

resource "openstack_networking_network_v2" "kubernetes" {
  count          = var.enable_resources ? 1 : 0
  name           = "kubernetes"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "kubernetes" {
  count           = var.enable_resources ? 1 : 0
  name            = "kubernetes-subnet"
  network_id      = openstack_networking_network_v2.kubernetes[0].id
  cidr            = var.tenant_cidr
  ip_version      = 4
  gateway_ip      = var.tenant_gateway
  enable_dhcp     = true
  dns_nameservers = var.external_dns

  allocation_pool {
    start = cidrhost(var.tenant_cidr, 2)
    end   = cidrhost(var.tenant_cidr, var.kubernetes_api_host_number - 1)
  }

  allocation_pool {
    start = cidrhost(var.tenant_cidr, var.kubernetes_api_host_number + 1)
    end   = cidrhost(var.tenant_cidr, -2)
  }
}

resource "openstack_networking_router_v2" "kubernetes" {
  count               = var.enable_resources ? 1 : 0
  name                = "kubernetes-router"
  admin_state_up      = true
  external_network_id = openstack_networking_network_v2.public[0].id

  external_fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.public[0].id
    ip_address = local.router_external_ip
  }
}

resource "openstack_networking_router_interface_v2" "kubernetes" {
  count     = var.enable_resources ? 1 : 0
  router_id = openstack_networking_router_v2.kubernetes[0].id
  subnet_id = openstack_networking_subnet_v2.kubernetes[0].id
}

resource "openstack_networking_secgroup_v2" "kubernetes" {
  count       = var.enable_resources ? 1 : 0
  name        = "kubernetes-nodes"
  description = "Kubernetes node ingress managed by Terraform"
}

# OVN requires an unbound Neutron port for a movable VM VIP. This reserves the
# kube-vip address and lets Neutron mark its logical switch port as virtual.
resource "openstack_networking_port_v2" "kubernetes_api_vip" {
  count              = var.enable_resources ? 1 : 0
  name               = "kubernetes-api-vip"
  network_id         = openstack_networking_network_v2.kubernetes[0].id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.kubernetes[0].id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.kubernetes[0].id
    ip_address = local.kubernetes_internal_vip
  }
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  count             = var.enable_resources ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.admin_cidr
  security_group_id = openstack_networking_secgroup_v2.kubernetes[0].id
}

resource "openstack_networking_secgroup_rule_v2" "kube_api" {
  count             = var.enable_resources ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = var.admin_cidr
  security_group_id = openstack_networking_secgroup_v2.kubernetes[0].id
}

resource "openstack_networking_secgroup_rule_v2" "http" {
  count             = var.enable_resources ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.kubernetes[0].id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  count             = var.enable_resources ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.kubernetes[0].id
}

resource "openstack_networking_secgroup_rule_v2" "icmp" {
  count             = var.enable_resources ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = var.admin_cidr
  security_group_id = openstack_networking_secgroup_v2.kubernetes[0].id
}

resource "openstack_networking_secgroup_rule_v2" "cluster_internal" {
  count             = var.enable_resources ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.kubernetes[0].id
  security_group_id = openstack_networking_secgroup_v2.kubernetes[0].id
}

resource "openstack_networking_port_v2" "kubernetes" {
  for_each           = local.nodes
  name               = each.key
  network_id         = openstack_networking_network_v2.kubernetes[0].id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.kubernetes[0].id]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.kubernetes[0].id
    ip_address = each.value.fixed_ip
  }

  dynamic "allowed_address_pairs" {
    for_each = contains(each.value.roles, "control_plane") ? [true] : []
    content {
      ip_address = local.kubernetes_internal_vip
    }
  }

  depends_on = [openstack_networking_port_v2.kubernetes_api_vip]
}

resource "openstack_blockstorage_volume_v3" "kubernetes" {
  for_each    = local.nodes
  name        = "${each.key}-root"
  size        = each.value.volume_size
  image_id    = data.openstack_images_image_v2.ubuntu[0].id
  volume_type = openstack_blockstorage_volume_type_v3.ceph[0].name

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_compute_instance_v2" "kubernetes" {
  for_each        = local.nodes
  name            = each.key
  flavor_id       = openstack_compute_flavor_v2.kubernetes[0].id
  key_pair        = openstack_compute_keypair_v2.operator[0].name
  config_drive    = true
  security_groups = []

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.kubernetes[each.key].id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = false
  }

  network {
    port = openstack_networking_port_v2.kubernetes[each.key].id
  }

  scheduler_hints {
    group = contains(each.value.roles, "control_plane") || contains(each.value.roles, "etcd") ? openstack_compute_servergroup_v2.kubernetes_control[0].id : openstack_compute_servergroup_v2.kubernetes_workers[0].id
  }

  metadata = {
    HA_Enabled      = "True"
    kubespray_roles = join(",", sort(tolist(each.value.roles)))
    inventory_order = tostring(each.value.inventory_order)
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [openstack_networking_router_interface_v2.kubernetes]
}

resource "openstack_networking_floatingip_v2" "kubernetes" {
  for_each   = local.nodes
  pool       = openstack_networking_network_v2.public[0].name
  subnet_id  = openstack_networking_subnet_v2.public[0].id
  address    = each.value.floating_ip
  port_id    = openstack_networking_port_v2.kubernetes[each.key].id
  depends_on = [openstack_compute_instance_v2.kubernetes]
}
