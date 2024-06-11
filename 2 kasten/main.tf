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
  version    = "7.0.0"

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
    value = "Veeam"
  }
  set {
    name  = "eula.email"
    value = "a.a@veeam.com"
  }
}

# Deploy Wordpress
resource "helm_release" "wordpress" {
  name       = "my-release"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "wordpress"
  namespace  = "wordpress"

  create_namespace = true

  set {
    name  = "wordpressUsername"
    value = "admin"
  }

  set {
    name  = "wordpressPassword"
    value = "password"
  }

  set {
    name  = "mariadb.auth.rootPassword"
    value = "secretpassword"
  }
}