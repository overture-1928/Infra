resource "openstack_networking_port_v2" "this" {
  name               = var.name
  network_id         = var.network_id
  admin_state_up     = true
  security_group_ids = sort(tolist(var.security_group_ids))

  fixed_ip {
    subnet_id  = var.subnet_id
    ip_address = var.fixed_ip
  }
}

resource "openstack_blockstorage_volume_v3" "root" {
  name        = "${var.name}-root"
  size        = var.root_volume_size
  image_id    = var.image_id
  volume_type = var.root_volume_type

  lifecycle {
    prevent_destroy = true
  }
}

# The pre-created Neutron port owns security groups. Setting Nova security_groups
# as well can cause the provider to remove or repeatedly reconcile port groups.
resource "openstack_compute_instance_v2" "this" {
  name         = var.name
  flavor_id    = var.flavor_id
  key_pair     = var.key_pair
  user_data    = var.user_data
  config_drive = var.config_drive
  metadata     = var.metadata

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.root.id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = false
  }

  network {
    port = openstack_networking_port_v2.this.id
  }

  dynamic "scheduler_hints" {
    for_each = var.server_group_id == null ? [] : [var.server_group_id]
    content {
      group = scheduler_hints.value
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "openstack_networking_floatingip_v2" "this" {
  count = var.floating_ip_pool == null ? 0 : 1

  pool      = var.floating_ip_pool
  subnet_id = var.floating_ip_subnet_id
  address   = var.floating_ip_address
  port_id   = openstack_networking_port_v2.this.id

  depends_on = [openstack_compute_instance_v2.this]
}
