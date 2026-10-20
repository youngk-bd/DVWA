output "subscription" {
  description = "Subscription selected by the provider safety check."
  value = {
    id   = data.azurerm_subscription.current.subscription_id
    name = data.azurerm_subscription.current.display_name
  }
}

output "resource_group" {
  description = "Resource group containing the entire deployment."
  value = {
    id       = azurerm_resource_group.dvwa.id
    name     = azurerm_resource_group.dvwa.name
    location = azurerm_resource_group.dvwa.location
  }
}

output "private_endpoint" {
  description = "Private-only application endpoint. Null while vm_deployed is false."
  value = var.vm_deployed ? {
    ip  = local.vm_private_ip
    url = "http://dvwa.${azurerm_private_dns_zone.dvwa.name}"
  } : null
}

output "network" {
  description = "Network IDs used to establish approved private routing and access."
  value = {
    vnet_id           = azurerm_virtual_network.dvwa.id
    vm_subnet_id      = azurerm_subnet.vm.id
    server_asg_id     = azurerm_application_security_group.server.id
    private_dns_zone  = azurerm_private_dns_zone.dvwa.id
    approved_peerings = { for name, peering in azurerm_virtual_network_peering.approved_consumers : name => peering.id }
  }
}

output "vm" {
  description = "VM identity. Null while vm_deployed is false."
  value = var.vm_deployed ? {
    id   = azurerm_linux_virtual_machine.dvwa[0].id
    name = azurerm_linux_virtual_machine.dvwa[0].name
  } : null
}

output "outbound_only_public_ip" {
  description = "NAT egress address for downstream allowlisting. It has no inbound mapping to the VM."
  value       = var.vm_deployed && var.nat_gateway_enabled ? azurerm_public_ip.nat[0].ip_address : null
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID, or null when monitoring is disabled."
  value       = var.enable_monitoring ? azurerm_log_analytics_workspace.dvwa[0].id : null
}

output "power_commands" {
  description = "Operational start/deallocate commands. They apply only while vm_deployed is true."
  value = {
    activate   = "az vm start --subscription ${data.azurerm_subscription.current.subscription_id} --resource-group ${local.resource_group_name} --name ${local.vm_name}"
    deactivate = "az vm deallocate --subscription ${data.azurerm_subscription.current.subscription_id} --resource-group ${local.resource_group_name} --name ${local.vm_name}"
  }
}
