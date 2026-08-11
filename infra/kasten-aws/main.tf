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

# EKS does not ship the CSI external-snapshotter CRDs/controller by default
# (unlike AKS). Community chart that installs both - verify it still resolves
# before relying on it; the upstream alternative is applying the
# kubernetes-csi/external-snapshotter release manifests directly.
resource "helm_release" "snapshot_controller" {
  name             = "snapshot-controller"
  create_namespace = true
  namespace        = "kube-system"
  repository       = "https://piraeus.io/helm-charts/"
  chart            = "snapshot-controller"
}

resource "kubernetes_manifest" "ebs_vsc" {
  manifest = {
    apiVersion = "snapshot.storage.k8s.io/v1"
    kind       = "VolumeSnapshotClass"
    metadata = {
      name = "csi-ebs-vsc"
      annotations = {
        "k10.kasten.io/is-snapshot-class" = "true"
      }
    }
    driver         = "ebs.csi.aws.com"
    deletionPolicy = "Delete"
  }

  depends_on = [helm_release.snapshot_controller]
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

  depends_on = [kubernetes_manifest.ebs_vsc]
}

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
