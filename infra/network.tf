resource "azurerm_virtual_network" "dvwa" {
  name                = "vnet-test-server-dvwa"
  location            = azurerm_resource_group.dvwa.location
  resource_group_name = azurerm_resource_group.dvwa.name
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "vm" {
  name                            = "snet-dvwa-vm"
  resource_group_name             = azurerm_resource_group.dvwa.name
  virtual_network_name            = azurerm_virtual_network.dvwa.name
  address_prefixes                = [var.vm_subnet_address_prefix]
  default_outbound_access_enabled = false
}

resource "azurerm_virtual_network_peering" "approved_consumers" {
  for_each = var.approved_remote_vnet_ids

  name                         = "peer-${each.key}"
  resource_group_name          = azurerm_resource_group.dvwa.name
  virtual_network_name         = azurerm_virtual_network.dvwa.name
  remote_virtual_network_id    = each.value
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_application_security_group" "server" {
  name                = "asg-dvwa-server"
  location            = azurerm_resource_group.dvwa.location
  resource_group_name = azurerm_resource_group.dvwa.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-dvwa-vm"
  location            = azurerm_resource_group.dvwa.location
  resource_group_name = azurerm_resource_group.dvwa.name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_network_security_rule" "application_from_cidrs" {
  count = length(var.application_allowed_source_cidrs) > 0 ? 1 : 0

  name                        = "Allow-HTTP-From-Approved-CIDRs"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefixes     = sort(tolist(var.application_allowed_source_cidrs))
  destination_address_prefix  = local.vm_private_ip
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "application_from_asgs" {
  count = length(var.application_allowed_source_asg_ids) > 0 ? 1 : 0

  name                                  = "Allow-HTTP-From-Approved-ASGs"
  priority                              = 110
  direction                             = "Inbound"
  access                                = "Allow"
  protocol                              = "Tcp"
  source_port_range                     = "*"
  destination_port_range                = "80"
  source_application_security_group_ids = sort(tolist(var.application_allowed_source_asg_ids))
  destination_address_prefix            = local.vm_private_ip
  resource_group_name                   = azurerm_resource_group.dvwa.name
  network_security_group_name           = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "ssh_from_cidrs" {
  count = length(var.ssh_allowed_source_cidrs) > 0 ? 1 : 0

  name                        = "Allow-SSH-From-Approved-CIDRs"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = sort(tolist(var.ssh_allowed_source_cidrs))
  destination_address_prefix  = local.vm_private_ip
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "ssh_from_asgs" {
  count = length(var.ssh_allowed_source_asg_ids) > 0 ? 1 : 0

  name                                  = "Allow-SSH-From-Approved-ASGs"
  priority                              = 130
  direction                             = "Inbound"
  access                                = "Allow"
  protocol                              = "Tcp"
  source_port_range                     = "*"
  destination_port_range                = "22"
  source_application_security_group_ids = sort(tolist(var.ssh_allowed_source_asg_ids))
  destination_address_prefix            = local.vm_private_ip
  resource_group_name                   = azurerm_resource_group.dvwa.name
  network_security_group_name           = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "deny_other_inbound" {
  name                        = "Deny-All-Other-Inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "azure_cloud" {
  name                        = "Allow-Azure-Cloud-HTTPS"
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.vm_private_ip
  destination_address_prefix  = "AzureCloud"
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "entra" {
  name                        = "Allow-Entra-HTTPS"
  priority                    = 130
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.vm_private_ip
  destination_address_prefix  = "AzureActiveDirectory"
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "azure_monitor" {
  name                        = "Allow-Azure-Monitor-HTTPS"
  priority                    = 140
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.vm_private_ip
  destination_address_prefix  = "AzureMonitor"
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "storage" {
  name                        = "Allow-Azure-Storage-HTTPS"
  priority                    = 150
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.vm_private_ip
  destination_address_prefix  = "Storage"
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "instance_metadata" {
  name                        = "Allow-Azure-Instance-Metadata"
  priority                    = 160
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = local.vm_private_ip
  destination_address_prefix  = "169.254.169.254/32"
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "approved_private_egress" {
  count = length(var.allowed_private_egress_cidrs) > 0 ? 1 : 0

  name                         = "Allow-Approved-Private-Egress"
  priority                     = 170
  direction                    = "Outbound"
  access                       = "Allow"
  protocol                     = "Tcp"
  source_port_range            = "*"
  destination_port_ranges      = sort(tolist(var.allowed_private_egress_ports))
  source_address_prefix        = local.vm_private_ip
  destination_address_prefixes = sort(tolist(var.allowed_private_egress_cidrs))
  resource_group_name          = azurerm_resource_group.dvwa.name
  network_security_group_name  = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "internet_bootstrap" {
  count = var.vm_deployed && var.nat_gateway_enabled && var.internet_bootstrap_egress_enabled ? 1 : 0

  name                        = "Allow-Bootstrap-Internet-Web"
  priority                    = 200
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443"]
  source_address_prefix       = local.vm_private_ip
  destination_address_prefix  = "Internet"
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "deny_other_outbound" {
  name                        = "Deny-All-Other-Outbound"
  priority                    = 4096
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.dvwa.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

# This address is outbound-only. NAT Gateway never creates an inbound path to
# the VM and the VM NIC itself has no public IP configuration.
resource "azurerm_public_ip" "nat" {
  count = var.vm_deployed && var.nat_gateway_enabled ? 1 : 0

  name                = "pip-dvwa-egress"
  location            = azurerm_resource_group.dvwa.location
  resource_group_name = azurerm_resource_group.dvwa.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.availability_zone == null ? null : [var.availability_zone]
  tags                = merge(local.tags, { purpose = "outbound-only" })
}

resource "azurerm_nat_gateway" "vm" {
  count = var.vm_deployed && var.nat_gateway_enabled ? 1 : 0

  name                    = "nat-dvwa-egress"
  location                = azurerm_resource_group.dvwa.location
  resource_group_name     = azurerm_resource_group.dvwa.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  zones                   = var.availability_zone == null ? [] : [var.availability_zone]
  tags                    = merge(local.tags, { purpose = "outbound-only" })
}

resource "azurerm_nat_gateway_public_ip_association" "vm" {
  count = var.vm_deployed && var.nat_gateway_enabled ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.vm[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "vm" {
  count = var.vm_deployed && var.nat_gateway_enabled ? 1 : 0

  subnet_id      = azurerm_subnet.vm.id
  nat_gateway_id = azurerm_nat_gateway.vm[0].id
}

resource "azurerm_private_dns_zone" "dvwa" {
  name                = var.private_dns_zone_name
  resource_group_name = azurerm_resource_group.dvwa.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "dvwa" {
  name                  = "link-dvwa-vnet"
  resource_group_name   = azurerm_resource_group.dvwa.name
  private_dns_zone_name = azurerm_private_dns_zone.dvwa.name
  virtual_network_id    = azurerm_virtual_network.dvwa.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "consumers" {
  for_each = var.additional_private_dns_vnet_links

  name                  = "link-${each.key}"
  resource_group_name   = azurerm_resource_group.dvwa.name
  private_dns_zone_name = azurerm_private_dns_zone.dvwa.name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_a_record" "dvwa" {
  count = var.vm_deployed ? 1 : 0

  name                = "dvwa"
  zone_name           = azurerm_private_dns_zone.dvwa.name
  resource_group_name = azurerm_resource_group.dvwa.name
  ttl                 = 60
  records             = [local.vm_private_ip]
  tags                = local.tags
}
