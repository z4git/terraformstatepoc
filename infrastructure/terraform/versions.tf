terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Partial configuration: supply the rest with -backend-config=<file>.tfbackend (see backend.tfbackend.example).
  backend "azurerm" {
    use_azuread_auth = true
  }
}
