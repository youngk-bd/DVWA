locals {
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    container_internet_access_enabled = var.container_internet_access_enabled
    dvwa_image                        = var.dvwa_image
    dvwa_security_level               = var.dvwa_security_level
    mariadb_image                     = var.mariadb_image
    storage_script_base64             = filebase64("${path.module}/guest/prepare-storage.sh")
    bootstrap_script_base64           = filebase64("${path.module}/guest/bootstrap.sh")
    verify_script_base64              = filebase64("${path.module}/guest/verify.sh")
  })
}

resource "azurerm_managed_disk" "data" {
  name                          = "disk-dvwa-data"
  location                      = azurerm_resource_group.dvwa.location
  resource_group_name           = azurerm_resource_group.dvwa.name
  storage_account_type          = "StandardSSD_LRS"
  create_option                 = "Empty"
  disk_size_gb                  = var.data_disk_size_gb
  zone                          = var.availability_zone
  network_access_policy         = "DenyAll"
  public_network_access_enabled = false
  tags                          = merge(local.tags, { persistence = "retain-while-compute-disabled" })
}

resource "azurerm_network_interface" "vm" {
  count = var.vm_deployed ? 1 : 0

  name                           = "nic-dvwa-vm"
  location                       = azurerm_resource_group.dvwa.location
  resource_group_name            = azurerm_resource_group.dvwa.name
  accelerated_networking_enabled = false
  ip_forwarding_enabled          = false
  tags                           = local.tags

  ip_configuration {
    name                          = "private"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.vm_private_ip
  }
}

resource "azurerm_network_interface_application_security_group_association" "server" {
  count = var.vm_deployed ? 1 : 0

  network_interface_id          = azurerm_network_interface.vm[0].id
  application_security_group_id = azurerm_application_security_group.server.id
}

resource "azurerm_linux_virtual_machine" "dvwa" {
  count = var.vm_deployed ? 1 : 0

  name                            = local.vm_name
  computer_name                   = "dvwa"
  location                        = azurerm_resource_group.dvwa.location
  resource_group_name             = azurerm_resource_group.dvwa.name
  size                            = var.vm_size
  zone                            = var.availability_zone
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm[0].id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  encryption_at_host_enabled      = var.encryption_at_host_enabled
  patch_assessment_mode           = "AutomaticByPlatform"
  patch_mode                      = "AutomaticByPlatform"

  custom_data = base64encode(local.cloud_init)

  admin_ssh_key {
    username   = var.admin_username
    public_key = trimspace(var.admin_ssh_public_key)
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "disk-dvwa-os"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = 32
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {}

  tags = local.tags

  depends_on = [
    azurerm_network_interface_application_security_group_association.server,
    azurerm_subnet_network_security_group_association.vm,
    azurerm_subnet_nat_gateway_association.vm,
  ]
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  count = var.vm_deployed ? 1 : 0

  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.dvwa[0].id
  lun                = 10
  caching            = "None"
}

resource "azurerm_virtual_machine_extension" "entra_ssh" {
  count = var.vm_deployed ? 1 : 0

  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.dvwa[0].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true

  tags = local.tags
}

resource "azurerm_role_assignment" "vm_admin" {
  for_each = var.vm_deployed ? var.vm_admin_principal_ids : toset([])

  scope                = azurerm_linux_virtual_machine.dvwa[0].id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = each.value
}
