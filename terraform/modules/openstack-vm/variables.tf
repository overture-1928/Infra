variable "name" {
  description = "Stable OpenStack name for the port, root volume and instance."
  type        = string

  validation {
    condition     = length(trimspace(var.name)) > 0 && length(var.name) <= 250
    error_message = "name must contain 1-250 characters so the -root volume suffix fits OpenStack's 255-character limit."
  }
}

variable "network_id" {
  description = "UUID of the Neutron network connected to the instance."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.network_id))
    error_message = "network_id must be an OpenStack UUID."
  }
}

variable "subnet_id" {
  description = "UUID of the Neutron subnet used by the instance port."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subnet_id))
    error_message = "subnet_id must be an OpenStack UUID."
  }
}

variable "image_id" {
  description = "UUID of the Glance image copied into the boot volume."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.image_id))
    error_message = "image_id must be an OpenStack UUID."
  }
}

variable "flavor_id" {
  description = "ID of the Nova flavor assigned to the instance. IDs may be numeric strings or UUIDs."
  type        = string

  validation {
    condition     = length(trimspace(var.flavor_id)) > 0
    error_message = "flavor_id must not be empty."
  }
}

variable "security_group_ids" {
  description = "Security-group UUIDs applied to the Neutron port."
  type        = set(string)
  default     = []

  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "security_group_ids must contain at least one Neutron security-group UUID."
  }

  validation {
    condition = alltrue([
      for id in var.security_group_ids :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "Every security_group_ids entry must be an OpenStack UUID."
  }
}

variable "root_volume_size" {
  description = "Boot volume size in GiB."
  type        = number

  validation {
    condition     = var.root_volume_size >= 1 && floor(var.root_volume_size) == var.root_volume_size
    error_message = "root_volume_size must be a positive whole number of GiB."
  }
}

variable "root_volume_type" {
  description = "Optional Cinder volume type. Null uses the cloud default."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.root_volume_type == null ? true : length(trimspace(var.root_volume_type)) > 0
    error_message = "root_volume_type must be null or a non-empty name."
  }
}

variable "key_pair" {
  description = "Optional existing Nova key-pair name."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.key_pair == null ? true : length(trimspace(var.key_pair)) > 0
    error_message = "key_pair must be null or a non-empty name."
  }
}

variable "fixed_ip" {
  description = "Optional fixed IPv4 or IPv6 address in subnet_id. Neutron allocates one when null."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.fixed_ip == null ? true : (
      can(cidrhost("${var.fixed_ip}/32", 0)) ||
      can(cidrhost("${var.fixed_ip}/128", 0))
    )
    error_message = "fixed_ip must be null or an IPv4/IPv6 address."
  }
}

variable "user_data" {
  description = "Optional cloud-init user data. Store secrets outside Terraform because user data is recorded in state."
  type        = string
  default     = null
  nullable    = true
  sensitive   = true
}

variable "server_group_id" {
  description = "Optional Nova server-group UUID used as a scheduler hint."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.server_group_id == null ? true : can(regex(
      "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
      var.server_group_id,
    ))
    error_message = "server_group_id must be null or an OpenStack UUID."
  }
}

variable "floating_ip_pool" {
  description = "Optional external Neutron network name. A Floating IP is created only when set."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.floating_ip_pool == null ? true : length(trimspace(var.floating_ip_pool)) > 0
    error_message = "floating_ip_pool must be null or a non-empty external network name."
  }
}

variable "floating_ip_subnet_id" {
  description = "Optional UUID of the external subnet from which to allocate the Floating IP."
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

variable "floating_ip_address" {
  description = "Optional preselected Floating IP address. Null asks Neutron to allocate one."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.floating_ip_address == null ? true : (
      can(cidrhost("${var.floating_ip_address}/32", 0)) ||
      can(cidrhost("${var.floating_ip_address}/128", 0))
    )
    error_message = "floating_ip_address must be null or an IPv4/IPv6 address."
  }
}

variable "config_drive" {
  description = "Attach a Nova config drive for metadata and user data."
  type        = bool
  default     = true
}

variable "metadata" {
  description = "Nova instance metadata."
  type        = map(string)
  default     = {}
}
