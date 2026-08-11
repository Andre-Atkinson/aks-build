terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = var.kube_config_path
  }
}

provider "kubernetes" {
  config_path = var.kube_config_path
}

resource "kubernetes_manifest" "azure_disk_vsc" {
  manifest = {
    apiVersion = "snapshot.storage.k8s.io/v1"
    kind       = "VolumeSnapshotClass"
    metadata = {
      name = "csi-azuredisk-vsc"
      annotations = {
        "k10.kasten.io/is-snapshot-class" = "true"
      }
    }
    driver         = "disk.csi.azure.com"
    deletionPolicy = "Delete"
    parameters = {
      incremental = "true"
    }
  }
}

resource "helm_release" "k10" {
  name             = "k10"
  create_namespace = true
  namespace        = "kasten-io"
  repository       = "https://charts.kasten.io/"
  chart            = "k10"
  version          = var.k10_version

  set {
    name  = "externalGateway.create"
    value = var.expose_dashboard
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
    value = "andre.atkinson@veeam.com"
  }
}

# Shared blob container that both the AKS and EKS K10 instances read/write
# for the export -> import DR workflow.
resource "kubernetes_secret" "azure_blob" {
  metadata {
    name      = "k10-azure-secret"
    namespace = "kasten-io"
  }
  type = "secrets.kanister.io/azure"
  data = {
    azure_storage_account_id  = var.storage_account_name
    azure_storage_environment = "AzurePublicCloud"
    azure_storage_key         = var.storage_account_key
  }

  depends_on = [helm_release.k10]
}

resource "kubernetes_manifest" "azure_blob_profile" {
  manifest = {
    apiVersion = "config.kio.kasten.io/v1alpha1"
    kind       = "Profile"
    metadata = {
      name      = "azureblob"
      namespace = "kasten-io"
    }
    spec = {
      type = "Location"
      locationSpec = {
        type = "ObjectStore"
        objectStore = {
          name            = var.storage_container_name
          objectStoreType = "AZ"
        }
        credential = {
          secretType = "AzStorageAccount"
          secret = {
            apiVersion = "v1"
            kind       = "secret"
            name       = kubernetes_secret.azure_blob.metadata[0].name
            namespace  = "kasten-io"
          }
        }
      }
    }
  }

  depends_on = [kubernetes_secret.azure_blob]
}
