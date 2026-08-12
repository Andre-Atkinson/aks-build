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

# The aws-ebs-csi-driver EKS addon installs the driver but does not create a
# default StorageClass for it - without this, PVCs restored here (via the
# TransformSet's storageClassName rewrite) have nothing to bind to.
resource "kubernetes_storage_class" "ebs_gp3" {
  metadata {
    name = "ebs-gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"
  parameters = {
    type = "gp3"
  }
}

# The "csi-ebs-vsc" VolumeSnapshotClass is created by
# orchestrator/k10_client.py after this apply finishes, not here - its CRD
# comes from helm_release.snapshot_controller in this SAME apply, so
# Terraform's kubernetes_manifest (which validates against the live CRD
# schema at PLAN time, before anything in this apply has actually run) would
# fail the same way the Profile resource below did on the first real run.
# See infra/kasten-azure/main.tf's comment for the full explanation.

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

  depends_on = [kubernetes_storage_class.ebs_gp3, helm_release.snapshot_controller]
}

# The "azureblob" Location Profile (and its backing Secret) is created by
# orchestrator/k10_client.py after this apply finishes - see
# infra/kasten-azure/main.tf's comment for why.
