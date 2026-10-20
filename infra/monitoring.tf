resource "azurerm_log_analytics_workspace" "dvwa" {
  count = var.enable_monitoring ? 1 : 0

  name                       = "log-dvwa-test-server"
  location                   = azurerm_resource_group.dvwa.location
  resource_group_name        = azurerm_resource_group.dvwa.name
  sku                        = "PerGB2018"
  retention_in_days          = var.log_retention_days
  daily_quota_gb             = 1
  internet_ingestion_enabled = true
  internet_query_enabled     = true
  tags                       = local.tags
}

resource "azurerm_monitor_data_collection_rule" "dvwa" {
  count = var.enable_monitoring ? 1 : 0

  name                = "dcr-dvwa-test-server"
  location            = azurerm_resource_group.dvwa.location
  resource_group_name = azurerm_resource_group.dvwa.name
  kind                = "Linux"
  tags                = local.tags

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.dvwa[0].id
      name                  = "dvwa-law"
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["dvwa-law"]
  }

  data_flow {
    streams      = ["Microsoft-Perf"]
    destinations = ["dvwa-law"]
  }

  data_sources {
    syslog {
      facility_names = ["*"]
      log_levels     = ["*"]
      name           = "dvwa-syslog"
      streams        = ["Microsoft-Syslog"]
    }

    performance_counter {
      counter_specifiers = [
        "\\Processor(*)\\% Processor Time",
        "\\Memory(*)\\% Used Memory",
        "\\Logical Disk(*)\\% Used Space",
        "\\Network(*)\\Total Bytes Transmitted",
        "\\Network(*)\\Total Bytes Received",
      ]
      name                          = "dvwa-performance"
      sampling_frequency_in_seconds = 60
      streams                       = ["Microsoft-Perf"]
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "dvwa" {
  count = var.vm_deployed && var.enable_monitoring ? 1 : 0

  name                    = "dcra-dvwa-test-server"
  target_resource_id      = azurerm_linux_virtual_machine.dvwa[0].id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.dvwa[0].id
}

resource "azurerm_virtual_machine_extension" "azure_monitor" {
  count = var.vm_deployed && var.enable_monitoring ? 1 : 0

  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.dvwa[0].id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true

  tags = local.tags
}
