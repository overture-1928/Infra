output "security_group_id" {
  description = "Workload-owned security-group UUID, or null while disabled."
  value       = try(openstack_networking_secgroup_v2.workload[0].id, null)
}

output "instances" {
  description = "Stable identifiers and addresses for workload instances."
  value = {
    for name, instance in module.instance : name => {
      instance_id    = instance.instance_id
      instance_name  = instance.instance_name
      port_id        = instance.port_id
      fixed_ips      = instance.fixed_ips
      root_volume_id = instance.root_volume_id
      floating_ip    = instance.floating_ip
    }
  }
}
