output "instance_id" {
  description = "Nova instance UUID."
  value       = openstack_compute_instance_v2.this.id
}

output "instance_name" {
  description = "Nova instance name."
  value       = openstack_compute_instance_v2.this.name
}

output "port_id" {
  description = "Neutron port UUID."
  value       = openstack_networking_port_v2.this.id
}

output "fixed_ips" {
  description = "Addresses assigned to the Neutron port."
  value       = openstack_networking_port_v2.this.all_fixed_ips
}

output "root_volume_id" {
  description = "Durable Cinder boot-volume UUID."
  value       = openstack_blockstorage_volume_v3.root.id
}

output "floating_ip" {
  description = "Associated Floating IP address, or null when disabled."
  value       = try(openstack_networking_floatingip_v2.this[0].address, null)
}
