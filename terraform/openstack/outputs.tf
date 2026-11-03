output "kubernetes_nodes" {
  description = "Addresses consumed by the Kubespray inventory renderer."
  value = {
    for name, node in local.nodes : name => {
      fixed_ip        = node.fixed_ip
      floating_ip     = openstack_networking_floatingip_v2.kubernetes[name].address
      roles           = sort(tolist(node.roles))
      inventory_order = node.inventory_order
    }
  }
}

output "kubernetes_api" {
  description = "Internal kube-vip, HA management endpoint and ordered bootstrap addresses."
  value = {
    internal_vip        = local.kubernetes_internal_vip
    management_api      = var.management_api_address
    network_id          = try(openstack_networking_network_v2.kubernetes[0].id, null)
    subnet_id           = try(openstack_networking_subnet_v2.kubernetes[0].id, null)
    vip_port_id         = try(openstack_networking_port_v2.kubernetes_api_vip[0].id, null)
    floating_network_id = try(openstack_networking_network_v2.public[0].id, null)
    control_plane_floating_ips = [
      for item in sort([
        for name, node in local.nodes : format("%09d|%s", node.inventory_order, name)
        if contains(node.roles, "control_plane")
      ]) : openstack_networking_floatingip_v2.kubernetes[split("|", item)[1]].address
    ]
  }
}

output "skyline_url" {
  description = "Skyline console URL on the management API VIP."
  value       = "http://${var.management_api_address}:9999"
}
