variable "cloud_name" {
  description = "clouds.yaml entry used by the OpenStack provider."
  type        = string
  default     = "admin"
}

variable "enable_instances" {
  description = "Safety switch. No security group, rule or instance is created while false."
  type        = bool
  default     = false
}

variable "workload_name" {
  description = "Short service name used for workload-owned OpenStack resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.workload_name))
    error_message = "workload_name must contain 1-63 lowercase letters, numbers or hyphens and start with a letter or number."
  }
}

variable "network_id" {
  description = "UUID of the existing tenant network shared with this workload."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.network_id))
    error_message = "network_id must be an OpenStack UUID."
  }
}

variable "subnet_id" {
  description = "UUID of the existing tenant subnet shared with this workload."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subnet_id))
    error_message = "subnet_id must be an OpenStack UUID."
  }
}

variable "image_id" {
  description = "UUID of the existing Glance image used for boot volumes."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.image_id))
    error_message = "image_id must be an OpenStack UUID."
  }
}

variable "flavor_id" {
  description = "ID of an existing default Nova flavor. Set null when managed_flavor creates it."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.flavor_id == null ? true : length(trimspace(var.flavor_id)) > 0
    error_message = "flavor_id must be null or non-empty."
  }
}

variable "managed_flavor" {
  description = "Optional private flavor created by this stack, including PCI and aggregate extra specs."
  type = object({
    name        = string
    ram         = number
    vcpus       = number
    disk        = number
    is_public   = optional(bool, false)
    extra_specs = optional(map(string), {})
  })
  default  = null
  nullable = true

  validation {
    condition = var.managed_flavor == null ? true : (
      length(trimspace(var.managed_flavor.name)) > 0 &&
      var.managed_flavor.ram >= 512 &&
      var.managed_flavor.vcpus >= 1 &&
      var.managed_flavor.disk >= 0
    )
    error_message = "managed_flavor requires a name, at least 512 MiB RAM, one vCPU and a non-negative disk size."
  }
}

variable "host_aggregate" {
  description = "Optional Nova host aggregate created with the managed flavor, for example cloud01-local."
  type = object({
    name     = string
    zone     = optional(string)
    hosts    = set(string)
    metadata = map(string)
  })
  default  = null
  nullable = true

  validation {
    condition = var.host_aggregate == null ? true : (
      length(trimspace(var.host_aggregate.name)) > 0 &&
      length(var.host_aggregate.hosts) > 0 &&
      length(var.host_aggregate.metadata) > 0
    )
    error_message = "host_aggregate requires a name, at least one Nova hostname and metadata."
  }
}

variable "ssh_ingress_cidr" {
  description = "Optional operator CIDR allowed to reach TCP/22."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.ssh_ingress_cidr == null ? true : can(cidrhost(var.ssh_ingress_cidr, 0))
    error_message = "ssh_ingress_cidr must be null or an IPv4/IPv6 CIDR."
  }
}

variable "internal_ingress_cidr" {
  description = "Optional trusted tenant CIDR allowed to reach all instance ports."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.internal_ingress_cidr == null ? true : can(cidrhost(var.internal_ingress_cidr, 0))
    error_message = "internal_ingress_cidr must be null or an IPv4/IPv6 CIDR."
  }
}

variable "additional_ingress_rules" {
  description = "Named workload-specific ingress rules added to the workload security group."
  type = map(object({
    ethertype        = optional(string, "IPv4")
    protocol         = optional(string)
    port_range_min   = optional(number)
    port_range_max   = optional(number)
    remote_ip_prefix = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for rule in values(var.additional_ingress_rules) :
      contains(["IPv4", "IPv6"], rule.ethertype) &&
      can(cidrhost(rule.remote_ip_prefix, 0)) &&
      rule.ethertype == (strcontains(rule.remote_ip_prefix, ":") ? "IPv6" : "IPv4") &&
      (rule.protocol == null ?
        rule.port_range_min == null && rule.port_range_max == null :
        length(trimspace(rule.protocol)) > 0
      ) &&
      (
        rule.port_range_min == null && rule.port_range_max == null ? true :
        rule.port_range_min != null && rule.port_range_max != null &&
        rule.port_range_min >= 0 && rule.port_range_max <= 65535 &&
        rule.port_range_min <= rule.port_range_max
      )
    ])
    error_message = "Additional rules need a CIDR matching ethertype, a protocol when ports are set, and either no ports or a complete 0-65535 port range."
  }
}

variable "additional_security_group_ids" {
  description = "Existing security-group UUIDs also applied to every workload port."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for id in var.additional_security_group_ids :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "Every additional_security_group_ids entry must be an OpenStack UUID."
  }
}

variable "floating_ip_pool" {
  description = "Optional external network name used by instances that request a Floating IP."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.floating_ip_pool == null ? true : length(trimspace(var.floating_ip_pool)) > 0
    error_message = "floating_ip_pool must be null or a non-empty external network name."
  }
}

variable "floating_ip_subnet_id" {
  description = "Optional external subnet UUID used for Floating IP allocation."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.floating_ip_subnet_id == null ? true : can(regex(
      "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
      var.floating_ip_subnet_id,
    ))
    error_message = "floating_ip_subnet_id must be null or an OpenStack UUID."
  }
}

variable "instances" {
  description = "Durable workload instances keyed by a stable OpenStack name."
  type = map(object({
    root_volume_size      = number
    root_volume_type      = optional(string)
    image_id              = optional(string)
    flavor_id             = optional(string)
    fixed_ip              = optional(string)
    key_pair              = optional(string)
    user_data             = optional(string)
    server_group_id       = optional(string)
    associate_floating_ip = optional(bool, false)
    floating_ip_address   = optional(string)
    config_drive          = optional(bool, true)
    metadata              = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, instance in var.instances :
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$", name)) &&
      length("${var.workload_name}-${name}") <= 250 &&
      instance.root_volume_size >= 1 &&
      floor(instance.root_volume_size) == instance.root_volume_size
    ])
    error_message = "Instance keys must be valid names, the prefixed name must fit 250 characters so -root stays within 255, and root_volume_size must be a positive whole number."
  }

  validation {
    condition = alltrue([
      for instance in values(var.instances) :
      (instance.image_id == null ? true : can(regex(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        instance.image_id,
      ))) &&
      (instance.flavor_id == null ? true : length(trimspace(instance.flavor_id)) > 0)
    ])
    error_message = "Every image_id override must be null or an OpenStack UUID, and every flavor_id override must be null or non-empty."
  }

  validation {
    condition = alltrue([
      for instance in values(var.instances) :
      instance.fixed_ip == null ? true : (
        can(cidrhost("${instance.fixed_ip}/32", 0)) ||
        can(cidrhost("${instance.fixed_ip}/128", 0))
      )
    ])
    error_message = "Every fixed_ip must be null or an IPv4/IPv6 address."
  }

  validation {
    condition = alltrue([
      for instance in values(var.instances) :
      instance.server_group_id == null ? true : can(regex(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        instance.server_group_id,
      ))
    ])
    error_message = "Every server_group_id must be null or an OpenStack UUID."
  }

  validation {
    condition = alltrue([
      for instance in values(var.instances) :
      !instance.associate_floating_ip || var.floating_ip_pool != null
    ])
    error_message = "floating_ip_pool is required when an instance sets associate_floating_ip to true."
  }

  validation {
    condition = alltrue([
      for instance in values(var.instances) :
      instance.associate_floating_ip || instance.floating_ip_address == null
    ])
    error_message = "floating_ip_address may be set only when associate_floating_ip is true."
  }

  validation {
    condition = length(compact([
      for instance in values(var.instances) : instance.fixed_ip
      ])) == length(toset(compact([
        for instance in values(var.instances) : instance.fixed_ip
    ])))
    error_message = "Every fixed_ip must be unique within the workload stack."
  }

  validation {
    condition = length(compact([
      for instance in values(var.instances) : instance.floating_ip_address
      ])) == length(toset(compact([
        for instance in values(var.instances) : instance.floating_ip_address
    ])))
    error_message = "Every floating_ip_address must be unique within the workload stack."
  }
}
