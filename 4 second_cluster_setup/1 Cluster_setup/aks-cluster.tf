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

data "azurerm_resource_group" "default" {
  name     = "demo-aks-rg"
}

resource "random_integer" "random" {
  min = 1
  max = 500000
}

resource "azurerm_kubernetes_cluster" "default" {
  name                = "demo-aks-dev"
  location            = data.azurerm_resource_group.default.location
  resource_group_name = data.azurerm_resource_group.default.name
  dns_prefix          = "demo-k8s-dev"
  kubernetes_version  = 1.23


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