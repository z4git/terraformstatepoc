provider "azurerm" {
  features {}

  subscription_id = var.subscription_id

  # Shared keys are disabled on the state account, so data-plane calls must use Entra ID.
  storage_use_azuread = true
}
