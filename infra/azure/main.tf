terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Auth comes from `az login` (Azure CLI credential chain) - no service principal
# secrets are created or stored by this build.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name = "k10dr${random_id.suffix.hex}"
}

resource "azurerm_resource_group" "default" {
  name     = local.name
  location = var.location

  tags = {
    environment = "k10-dr-demo"
  }
}

resource "azurerm_storage_account" "default" {
  name                     = local.name
  resource_group_name      = azurerm_resource_group.default.name
  location                 = azurerm_resource_group.default.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Shared export/import location for Kasten K10 on both AKS and EKS.
resource "azurerm_storage_container" "default" {
  name                  = local.name
  storage_account_name  = azurerm_storage_account.default.name
  container_access_type = "private"
}

resource "azurerm_kubernetes_cluster" "default" {
  name                = local.name
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name

  dns_prefix         = local.name
  kubernetes_version = var.kubernetes_version

  default_node_pool {
    name            = "default"
    node_count      = var.node_count
    vm_size         = var.node_vm_size
    os_disk_size_gb = 30
  }

  identity {
    type = "SystemAssigned"
  }

  role_based_access_control_enabled = true

  tags = {
    environment = "k10-dr-demo"
  }
}
