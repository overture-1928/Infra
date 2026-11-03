terraform {
  required_version = "= 1.17.1"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "3.4.0"
    }
  }
}
