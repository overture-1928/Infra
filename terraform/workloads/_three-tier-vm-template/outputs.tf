output "instances" {
  description = "Flat VM output consumed by the shared workload Ansible inventory renderer."
  value = merge(
    {
      for name, instance in module.web : "web-${name}" => {
        instance_id    = instance.instance_id
        instance_name  = instance.instance_name
        port_id        = instance.port_id
        fixed_ips      = instance.fixed_ips
        root_volume_id = instance.root_volume_id
        floating_ip    = instance.floating_ip
        data_volume_id = null
        tier           = "web"
      }
    },
    {
      for name, instance in module.application : "application-${name}" => {
        instance_id    = instance.instance_id
        instance_name  = instance.instance_name
        port_id        = instance.port_id
        fixed_ips      = instance.fixed_ips
        root_volume_id = instance.root_volume_id
        floating_ip    = instance.floating_ip
        data_volume_id = null
        tier           = "application"
      }
    },
    {
      for name, instance in module.database : "database-${name}" => {
        instance_id    = instance.instance_id
        instance_name  = instance.instance_name
        port_id        = instance.port_id
        fixed_ips      = instance.fixed_ips
        root_volume_id = instance.root_volume_id
        floating_ip    = instance.floating_ip
        data_volume_id = openstack_blockstorage_volume_v3.database_data[name].id
        tier           = "database"
      }
    },
  )
}

output "networks" {
  description = "Tier network and subnet IDs."
  value = var.enable_resources ? {
    web = {
      network_id = openstack_networking_network_v2.web[0].id
      subnet_id  = openstack_networking_subnet_v2.web[0].id
    }
    application = {
      network_id = openstack_networking_network_v2.application[0].id
      subnet_id  = openstack_networking_subnet_v2.application[0].id
    }
    database = {
      network_id = openstack_networking_network_v2.database[0].id
      subnet_id  = openstack_networking_subnet_v2.database[0].id
    }
  } : null
}

output "security_groups" {
  description = "Tier security-group IDs."
  value = var.enable_resources ? {
    web         = openstack_networking_secgroup_v2.web[0].id
    application = openstack_networking_secgroup_v2.application[0].id
    database    = openstack_networking_secgroup_v2.database[0].id
  } : null
}

output "router_id" {
  description = "Workload router ID, or null while disabled."
  value       = try(openstack_networking_router_v2.this[0].id, null)
}
