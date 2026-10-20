locals {
  resource_group_name = "rg-test-server-dvwa"
  vm_name             = "vm-test-server-dvwa"
  vm_private_ip       = cidrhost(var.vm_subnet_address_prefix, var.vm_private_ip_host_number)

  mandatory_tags = {
    environment         = "non-prod"
    managed-by          = "terraform"
    security-boundary   = "isolated"
    workload            = "dvwa-test-server"
    data-classification = "security-test"
  }

  tags = merge(var.tags, local.mandatory_tags)
}

resource "azurerm_resource_group" "dvwa" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags

  lifecycle {
    precondition {
      condition     = data.azurerm_subscription.current.display_name == "BYTEDEFENSE_INFRA_NON_PROD"
      error_message = "Refusing to deploy: the authenticated subscription must be BYTEDEFENSE_INFRA_NON_PROD."
    }
  }
}
