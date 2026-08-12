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

# The "azureblob" Location Profile (and its backing Secret) is created by
# orchestrator/k10_client.py after this apply finishes, not here.
#
# Terraform's kubernetes_manifest resource validates a manifest's
# GroupVersionKind against the cluster's live CRD schema at PLAN time, not
# apply time - depends_on doesn't help, since that only orders execution,
# not this upfront schema lookup. Since the "Profile" CRD is installed by
# helm_release.k10 in this SAME apply, the CRD doesn't exist yet when the
# plan is computed, and this resource fails immediately with "API did not
# recognize GroupVersionKind from manifest (CRD may not be installed)" -
# confirmed on the first real run. The Kubernetes Python client has no such
# restriction (it just POSTs to the API server), so Profile/Secret creation
# moved there instead.
