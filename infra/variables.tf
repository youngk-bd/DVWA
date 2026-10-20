variable "subscription_id" {
  description = "Azure subscription ID. Prefer setting ARM_SUBSCRIPTION_ID; leave this null in that case."
  type        = string
  default     = null
  nullable    = true
}

variable "location" {
  description = "Azure region for every resource in this stack."
  type        = string
  default     = "eastus2"
}

variable "vm_deployed" {
  description = "When false, remove compute, NIC, extensions, DNS record, and NAT while retaining the data disk and private network."
  type        = bool
  default     = true
}

variable "vm_size" {
  description = "Azure VM SKU."
  type        = string
  default     = "Standard_D2s_v7"
}

variable "availability_zone" {
  description = "Optional availability zone. Leave null where the selected VM SKU or region is not zonal."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.availability_zone == null || contains(["1", "2", "3"], var.availability_zone)
    error_message = "availability_zone must be null, 1, 2, or 3."
  }
}

variable "admin_username" {
  description = "Local break-glass administrator name. Password authentication is disabled."
  type        = string
  default     = "azureadmin"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_username))
    error_message = "admin_username must be a valid lowercase Linux account name."
  }
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key for break-glass access. Supply with TF_VAR_admin_ssh_public_key."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) ", trimspace(var.admin_ssh_public_key)))
    error_message = "admin_ssh_public_key must be a supported OpenSSH public key."
  }
}

variable "vm_admin_principal_ids" {
  description = "Microsoft Entra object IDs granted Virtual Machine Administrator Login at VM scope."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.vm_admin_principal_ids : can(regex("^[0-9a-fA-F-]{36}$", id))])
    error_message = "Every VM administrator principal ID must be a GUID."
  }
}

variable "vnet_address_space" {
  description = "Address space for the isolated DVWA VNet."
  type        = list(string)
  default     = ["10.70.0.0/16"]

  validation {
    condition     = length(var.vnet_address_space) > 0 && alltrue([for cidr in var.vnet_address_space : can(cidrnetmask(cidr))])
    error_message = "vnet_address_space must contain valid CIDR blocks."
  }
}

variable "vm_subnet_address_prefix" {
  description = "CIDR for the private VM subnet."
  type        = string
  default     = "10.70.1.0/24"

  validation {
    condition     = can(cidrnetmask(var.vm_subnet_address_prefix))
    error_message = "vm_subnet_address_prefix must be a valid CIDR block."
  }
}

variable "vm_private_ip_host_number" {
  description = "Host number inside vm_subnet_address_prefix used for the VM's fixed private address."
  type        = number
  default     = 10

  validation {
    condition     = var.vm_private_ip_host_number >= 5 && floor(var.vm_private_ip_host_number) == var.vm_private_ip_host_number
    error_message = "vm_private_ip_host_number must be an integer of at least 5 (Azure reserves the first four addresses)."
  }
}

variable "application_allowed_source_cidrs" {
  description = "Only these routed source CIDRs may reach DVWA over TCP/80. Empty means no application access."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.application_allowed_source_cidrs :
      can(cidrnetmask(cidr)) && !contains(["0.0.0.0/0", "::/0"], cidr)
    ])
    error_message = "Application sources must be valid, scoped CIDRs; Internet-wide CIDRs are prohibited."
  }
}

variable "application_allowed_source_asg_ids" {
  description = "Application Security Group IDs in this VNet allowed to reach DVWA over TCP/80."
  type        = set(string)
  default     = []
}

variable "ssh_allowed_source_cidrs" {
  description = "Only these routed source CIDRs may reach SSH. Empty means SSH is closed. Entra RBAC is also required."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.ssh_allowed_source_cidrs :
      can(cidrnetmask(cidr)) && !contains(["0.0.0.0/0", "::/0"], cidr)
    ])
    error_message = "SSH sources must be valid, scoped CIDRs; Internet-wide CIDRs are prohibited."
  }
}

variable "ssh_allowed_source_asg_ids" {
  description = "Application Security Group IDs in this VNet allowed to reach SSH. Entra RBAC is also required."
  type        = set(string)
  default     = []
}

variable "allowed_private_egress_cidrs" {
  description = "Optional private detector/sink CIDRs the VM may initiate TCP connections to."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.allowed_private_egress_cidrs :
      can(cidrnetmask(cidr)) && !contains(["0.0.0.0/0", "::/0"], cidr)
    ])
    error_message = "Private egress destinations must be valid, scoped CIDRs."
  }
}

variable "allowed_private_egress_ports" {
  description = "TCP destination ports permitted to allowed_private_egress_cidrs."
  type        = set(string)
  default     = ["443"]

  validation {
    condition = length(var.allowed_private_egress_ports) > 0 && alltrue([
      for port in var.allowed_private_egress_ports : can(regex("^([1-9][0-9]{0,4})(-([1-9][0-9]{0,4}))?$", port))
    ])
    error_message = "Private egress ports must be NSG port numbers or ranges."
  }
}

variable "nat_gateway_enabled" {
  description = "Create explicit outbound-only internet connectivity for host bootstrap, updates, and extensions."
  type        = bool
  default     = true
}

variable "internet_bootstrap_egress_enabled" {
  description = "Allow host TCP/80 and TCP/443 to Internet through NAT for apt and container image pulls."
  type        = bool
  default     = true
}

variable "container_internet_access_enabled" {
  description = "Allow the intentionally vulnerable DVWA container to initiate internet traffic. Keep false unless a test explicitly needs it."
  type        = bool
  default     = false
}

variable "private_dns_zone_name" {
  description = "Private-only DNS zone linked to the DVWA VNet."
  type        = string
  default     = "dvwa.internal"
}

variable "additional_private_dns_vnet_links" {
  description = "Map of link name to consumer VNet ID for private DNS resolution. Network routing/peering must already exist."
  type        = map(string)
  default     = {}
}

variable "approved_remote_vnet_ids" {
  description = "Map of peering name to approved consumer VNet ID. This creates only the peering owned by the DVWA VNet; the consumer must manage its reciprocal peering."
  type        = map(string)
  default     = {}
}

variable "os_disk_storage_account_type" {
  description = "Managed OS disk storage type."
  type        = string
  default     = "Premium_LRS"

  validation {
    condition     = contains(["Premium_LRS", "Premium_ZRS", "StandardSSD_LRS", "StandardSSD_ZRS", "Standard_LRS"], var.os_disk_storage_account_type)
    error_message = "Unsupported OS disk storage account type."
  }
}

variable "encryption_at_host_enabled" {
  description = "Enable end-to-end host encryption after registering Microsoft.Compute/EncryptionAtHost and verifying VM SKU support."
  type        = bool
  default     = false
}

variable "data_disk_size_gb" {
  description = "Persistent DVWA database/data disk size. This disk remains when vm_deployed is false."
  type        = number
  default     = 32

  validation {
    condition     = var.data_disk_size_gb >= 16
    error_message = "data_disk_size_gb must be at least 16 GiB."
  }
}

variable "dvwa_image" {
  description = "DVWA OCI image. Pin to an approved sha256 digest for repeatable deployments."
  type        = string
  default     = "ghcr.io/digininja/dvwa:latest"
}

variable "mariadb_image" {
  description = "MariaDB OCI image. Pin to an approved sha256 digest for repeatable deployments."
  type        = string
  default     = "docker.io/library/mariadb:10.11"
}

variable "dvwa_security_level" {
  description = "Default DVWA exercise security level."
  type        = string
  default     = "low"

  validation {
    condition     = contains(["low", "medium", "high", "impossible"], var.dvwa_security_level)
    error_message = "dvwa_security_level must be low, medium, high, or impossible."
  }
}

variable "enable_monitoring" {
  description = "Install Azure Monitor Agent and collect syslog/performance data in a dedicated Log Analytics workspace."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "tags" {
  description = "Additional tags merged with mandatory workload tags."
  type        = map(string)
  default     = {}
}
