variable "kube_config_path" {
  description = "Path to the kubeconfig file for the EKS cluster (written by orchestrator/create.py from `aws eks update-kubeconfig` / infra/aws's terraform output)"
  type        = string
}

variable "k10_version" {
  description = "Kasten K10 helm chart version - must match infra/kasten-azure's pin."
  type        = string
  default     = "9.0.2"
}

variable "expose_dashboard" {
  type    = bool
  default = false
}

# Same shared Azure Blob container used on the AKS side (infra/azure output),
# so EKS's K10 can read the restore points exported from AKS.
variable "storage_account_name" {
  type = string
}

variable "storage_account_key" {
  type      = string
  sensitive = true
}

variable "storage_container_name" {
  type = string
}
