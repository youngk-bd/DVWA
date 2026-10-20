provider "azurerm" {
  features {}

  # Prefer ARM_SUBSCRIPTION_ID. This optional variable is useful in CI systems
  # that map all inputs to TF_VAR_* environment variables.
  subscription_id = var.subscription_id
}

data "azurerm_subscription" "current" {}
