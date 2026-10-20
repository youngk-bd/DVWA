mock_provider "azurerm" {
  override_data {
    target = data.azurerm_subscription.current
    values = {
      display_name    = "BYTEDEFENSE_INFRA_NON_PROD"
      subscription_id = "00000000-0000-0000-0000-000000000001"
    }
  }
}

variables {
  admin_ssh_public_key               = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINOkakOi2wFpVcgCXV0kkrKCCKZmzI7Y/mHwMk+DC6EH terraform-test"
  application_allowed_source_cidrs   = []
  application_allowed_source_asg_ids = []
  ssh_allowed_source_cidrs           = []
  ssh_allowed_source_asg_ids         = []
  approved_remote_vnet_ids           = {}
  additional_private_dns_vnet_links  = {}
}

run "secure_defaults" {
  command = plan

  assert {
    condition     = azurerm_resource_group.dvwa.name == "rg-test-server-dvwa"
    error_message = "The deployment must use the fixed resource group."
  }

  assert {
    condition     = length(azurerm_network_security_rule.application_from_cidrs) == 0 && length(azurerm_network_security_rule.application_from_asgs) == 0
    error_message = "Default application ingress must be closed."
  }

  assert {
    condition     = length(azurerm_network_security_rule.ssh_from_cidrs) == 0 && length(azurerm_network_security_rule.ssh_from_asgs) == 0
    error_message = "Default SSH ingress must be closed."
  }

  assert {
    condition     = azurerm_subnet.vm.default_outbound_access_enabled == false
    error_message = "The VM subnet must disable Azure default outbound access."
  }

  assert {
    condition     = azurerm_managed_disk.data.network_access_policy == "DenyAll" && !azurerm_managed_disk.data.public_network_access_enabled
    error_message = "The persistent data disk must prohibit public import/export access."
  }

  assert {
    condition     = azurerm_network_interface.vm[0].ip_configuration[0].private_ip_address_allocation == "Static" && azurerm_network_interface.vm[0].ip_configuration[0].public_ip_address_id == null
    error_message = "The VM NIC must use only a fixed private address."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.dvwa[0].disable_password_authentication && azurerm_linux_virtual_machine.dvwa[0].secure_boot_enabled && azurerm_linux_virtual_machine.dvwa[0].vtpm_enabled
    error_message = "Password authentication must be disabled and Trusted Launch controls enabled."
  }

  assert {
    condition     = can(yamldecode(local.cloud_init))
    error_message = "Rendered cloud-init must remain valid YAML."
  }

  assert {
    condition = can(yamldecode(
      yamldecode(local.cloud_init).write_files[0].content
    ))
    error_message = "The Compose document embedded in cloud-init must remain valid YAML."
  }

  assert {
    condition = yamldecode(
      yamldecode(local.cloud_init).write_files[0].content
    ).networks.backend.internal == true
    error_message = "The vulnerable containers must have an internal-only Docker network by default."
  }

  assert {
    condition = yamldecode(
      yamldecode(local.cloud_init).write_files[0].content
    ).services.dvwa.networks.backend.ipv4_address == "172.30.0.10"
    error_message = "The internal-only DVWA container address must remain stable for the host TCP proxy."
  }

  assert {
    condition = length([
      for file in yamldecode(local.cloud_init).write_files : file.path
      if file.path == "/etc/systemd/system/dvwa-proxy.service" && strcontains(file.content, "172.30.0.10:80")
    ]) == 1
    error_message = "Cloud-init must proxy the VM private listener to the internal-only DVWA container."
  }

  assert {
    condition     = yamldecode(local.cloud_init).runcmd == [["/usr/local/sbin/dvwa-bootstrap"]]
    error_message = "Bootstrap must use one fail-fast command so disk failures cannot fall through."
  }

  assert {
    condition = length([
      for file in yamldecode(local.cloud_init).write_files : file.path
      if(file.path == "/etc/systemd/system/dvwa.service" || file.path == "/etc/systemd/system/docker.service.d/dvwa-storage.conf") &&
      strcontains(file.content, "RequiresMountsFor=/opt/dvwa") &&
      strcontains(file.content, "ExecStartPre=/usr/bin/mountpoint -q /opt/dvwa")
    ]) == 2
    error_message = "Both Docker autostart and the DVWA service must require the data mount."
  }
}

run "compute_removed" {
  command = plan

  variables {
    vm_deployed = false
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.dvwa) == 0 && length(azurerm_network_interface.vm) == 0
    error_message = "vm_deployed=false must remove compute and its NIC."
  }

  assert {
    condition     = length(azurerm_public_ip.nat) == 0 && length(azurerm_nat_gateway.vm) == 0
    error_message = "vm_deployed=false must remove outbound NAT assets."
  }

  assert {
    condition     = azurerm_managed_disk.data.name == "disk-dvwa-data"
    error_message = "The persistent data disk must remain while compute is removed."
  }
}
