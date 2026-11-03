variable "cloud_name" {
  description = "clouds.yaml entry used by the OpenStack provider."
  type        = string
  default     = "admin"
}

variable "enable_resources" {
  description = "Safety switch. No Neutron or compute resources are created while false."
  type        = bool
  default     = false
}

variable "workload_name" {
  description = "Short service name injected by the workload wrapper."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.workload_name))
    error_message = "workload_name must contain 1-63 lowercase letters, numbers or hyphens."
  }
}

variable "external_network_id" {
  description = "UUID of the existing Neutron external network used by the workload router."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.external_network_id))
    error_message = "external_network_id must be an OpenStack UUID."
  }
}

variable "web_cidr" {
  description = "IPv4 CIDR for the Neutron web subnet."
  type        = string
  default     = "10.30.10.0/24"

  validation {
    condition     = can(cidrhost(var.web_cidr, 0)) && !strcontains(var.web_cidr, ":")
    error_message = "web_cidr must be an IPv4 CIDR."
  }
}

variable "web_gateway" {
  description = "Gateway address for the Neutron web subnet."
  type        = string
  default     = "10.30.10.1"
}

variable "application_cidr" {
  description = "IPv4 CIDR for the Neutron application subnet."
  type        = string
  default     = "10.30.20.0/24"

  validation {
    condition     = can(cidrhost(var.application_cidr, 0)) && !strcontains(var.application_cidr, ":")
    error_message = "application_cidr must be an IPv4 CIDR."
  }
}

variable "application_gateway" {
  description = "Gateway address for the Neutron application subnet."
  type        = string
  default     = "10.30.20.1"
}

variable "database_cidr" {
  description = "IPv4 CIDR for the Neutron database subnet."
  type        = string
  default     = "10.30.30.0/24"

  validation {
    condition     = can(cidrhost(var.database_cidr, 0)) && !strcontains(var.database_cidr, ":")
    error_message = "database_cidr must be an IPv4 CIDR."
  }
}

variable "database_gateway" {
  description = "Gateway address for the Neutron database subnet."
  type        = string
  default     = "10.30.30.1"
}

variable "dns_nameservers" {
  description = "DNS servers advertised by the three Neutron subnets."
  type        = list(string)
  default     = []
}

variable "admin_cidr" {
  description = "Trusted operator CIDR allowed to SSH to all three tiers."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && !strcontains(var.admin_cidr, ":")
    error_message = "admin_cidr must be an IPv4 CIDR."
  }
}

variable "ingress_cidrs" {
  description = "CIDRs containing the reverse proxy, Octavia members or clients allowed to reach the web tier."
  type        = set(string)

  validation {
    condition = length(var.ingress_cidrs) > 0 && alltrue([
      for cidr in var.ingress_cidrs : can(cidrhost(cidr, 0)) && !strcontains(cidr, ":")
    ])
    error_message = "ingress_cidrs must contain at least one IPv4 CIDR."
  }
}

variable "web_ports" {
  description = "TCP ports exposed by the web tier to ingress_cidrs."
  type        = set(number)
  default     = [80, 443]

  validation {
    condition     = length(var.web_ports) > 0 && alltrue([for port in var.web_ports : port >= 1 && port <= 65535 && floor(port) == port])
    error_message = "web_ports must contain valid TCP port numbers."
  }
}

variable "application_ports" {
  description = "TCP ports allowed from the web security group to the application tier."
  type        = set(number)
  default     = [8080]

  validation {
    condition     = length(var.application_ports) > 0 && alltrue([for port in var.application_ports : port >= 1 && port <= 65535 && floor(port) == port])
    error_message = "application_ports must contain valid TCP port numbers."
  }
}

variable "database_ports" {
  description = "TCP ports allowed from the application security group to the database tier."
  type        = set(number)
  default     = [5432]

  validation {
    condition     = length(var.database_ports) > 0 && alltrue([for port in var.database_ports : port >= 1 && port <= 65535 && floor(port) == port])
    error_message = "database_ports must contain valid TCP port numbers."
  }
}

variable "image_id" {
  description = "Glance image UUID used by all three tiers."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.image_id))
    error_message = "image_id must be an OpenStack UUID."
  }
}

variable "web_flavor_id" {
  description = "Default Nova flavor ID for web instances."
  type        = string

  validation {
    condition     = length(trimspace(var.web_flavor_id)) > 0
    error_message = "web_flavor_id must not be empty."
  }
}

variable "application_flavor_id" {
  description = "Default Nova flavor ID for application instances."
  type        = string

  validation {
    condition     = length(trimspace(var.application_flavor_id)) > 0
    error_message = "application_flavor_id must not be empty."
  }
}

variable "database_flavor_id" {
  description = "Default Nova flavor ID for database instances."
  type        = string

  validation {
    condition     = length(trimspace(var.database_flavor_id)) > 0
    error_message = "database_flavor_id must not be empty."
  }
}

variable "key_pair" {
  description = "Existing Nova key-pair name used by every instance."
  type        = string

  validation {
    condition     = length(trimspace(var.key_pair)) > 0
    error_message = "key_pair must not be empty."
  }
}

variable "root_volume_type" {
  description = "Cinder volume type for VM boot volumes."
  type        = string
  default     = "ceph-rbd"
}

variable "database_data_volume_type" {
  description = "Cinder volume type for separately protected database data volumes."
  type        = string
  default     = "ceph-rbd"
}

variable "web_instances" {
  description = "Web tier instances keyed by a stable name."
  type = map(object({
    fixed_ip         = optional(string)
    flavor_id        = optional(string)
    root_volume_size = optional(number, 20)
    ha_enabled       = optional(bool, true)
    metadata         = optional(map(string), {})
  }))
  default = {}
}

variable "application_instances" {
  description = "Application tier instances keyed by a stable name."
  type = map(object({
    fixed_ip         = optional(string)
    flavor_id        = optional(string)
    root_volume_size = optional(number, 30)
    ha_enabled       = optional(bool, true)
    metadata         = optional(map(string), {})
  }))
  default = {}
}

variable "database_instances" {
  description = "Database tier instances and their separate durable data volumes."
  type = map(object({
    fixed_ip         = optional(string)
    flavor_id        = optional(string)
    root_volume_size = optional(number, 30)
    data_volume_size = number
    data_volume_type = optional(string)
    ha_enabled       = optional(bool, true)
    metadata         = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for instance in values(var.database_instances) : instance.data_volume_size >= 10 && floor(instance.data_volume_size) == instance.data_volume_size
    ])
    error_message = "Every database data volume must be at least 10 GiB and use a whole GiB size."
  }
}
