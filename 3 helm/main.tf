terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = "C:\\Users\\${var.username}\\.kube\\config"
  }
}

resource "helm_release" "k10" {
  name       = "k10"
  create_namespace = true
  namespace = "kasten-io"
  repository = "https://charts.kasten.io/"
  chart      = "k10"
  version    = "5.0.4"

  set {
    name  = "secrets.azureTenantId"
    value = var.tenant
  }
  set {
    name  = "secrets.azureClientId"
    value = var.appId
  }
  set {
    name  = "secrets.azureClientSecret"
    value = var.password
  }
  set {
    name  = "externalGateway.create"
    value = true
  }
  set {
    name  = "auth.tokenAuth.enabled"
    value = true
  }
  set {
    name  = "eula.accept"
    value = true
  }
  set {
    name  = "eula.company"
    value = "Company"
  }
  set {
    name  = "eula.email"
    value = "a@a.com"
  }
}

resource "helm_release" "pacman" {
  name       = "pacman"
  create_namespace = true
  namespace = "pacman"
  repository = "https://saintdle.github.io/helm-charts/"
  chart      = "pacman"
}