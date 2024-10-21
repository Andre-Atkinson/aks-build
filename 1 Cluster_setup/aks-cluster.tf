terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

provider "azurerm" {
  features {}

  client_id       = var.appId
  client_secret   = var.password
  tenant_id       = var.tenant
  subscription_id = var.subscription

}

resource "azurerm_resource_group" "default" {
  name     = "k10demobackup${var.randomNumber}"
  location = "Australia East"

  tags = {
    environment = "Demo"
  }
}

resource "azurerm_storage_account" "default" {
  name                     = "k10demobackup${var.randomNumber}"
  resource_group_name      = azurerm_resource_group.default.name
  location                 = azurerm_resource_group.default.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "default" {
  name                  = "k10demobackup${var.randomNumber}"
  storage_account_name  = azurerm_storage_account.default.name
  container_access_type = "private"
}

resource "azurerm_kubernetes_cluster" "default" {
  name                = "k10demobackup${var.randomNumber}"
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  
  dns_prefix          = "k10demobackup${var.randomNumber}"
  kubernetes_version  = 1.29


  default_node_pool {
    name            = "default"
    node_count      = 2
    vm_size         = "Standard_D2_v2"
    os_disk_size_gb = 30
  }

  service_principal {
    client_id     = var.appId
    client_secret = var.password
  }

  role_based_access_control_enabled = true

  tags = {
    environment = "k10demobackup${var.randomNumber}"
  }
}