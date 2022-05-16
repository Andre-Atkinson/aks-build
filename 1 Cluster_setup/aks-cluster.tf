terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
    }
    random = {
      source = "hashicorp/random"
      version = "3.1.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "random_integer" "random" {
  min = 1
  max = 500000
}

resource "azurerm_resource_group" "default" {
  name     = "demo-aks-rg"
  location = "Australia East"

  tags = {
    environment = "Demo"
  }
}

resource "azurerm_virtual_network" "default" {
  name                = "demo-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name

    tags = {
    environment = "Demo"
  }
}

resource "azurerm_subnet" "default" {
  name                 = "demo-subnet"
  resource_group_name  = azurerm_resource_group.default.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_storage_account" "default" {
  name                     = "k10demobackup${random_integer.random.result}"
  resource_group_name      = azurerm_resource_group.default.name
  location                 = azurerm_resource_group.default.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "default" {
  name                  = "k10${random_integer.random.result}"
  storage_account_name  = azurerm_storage_account.default.name
  container_access_type = "private"
}

resource "azurerm_kubernetes_cluster" "default" {
  name                = "demo-aks"
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  dns_prefix          = "demo-k8s"


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
    environment = "Demo"
  }
}