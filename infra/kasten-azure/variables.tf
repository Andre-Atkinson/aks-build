variable "kube_config_path" {
  description = "Path to the kubeconfig file for the AKS cluster (written by orchestrator/create.py from infra/azure's terraform output)"
  type        = string
}

variable "k10_version" {
  description = "Kasten K10 helm chart version. Check `helm search repo kasten/k10` for the current release before pinning."
  type        = string
  default     = "9.0.2"
}

variable "expose_dashboard" {
  description = "Create a public LoadBalancer Service for the K10 dashboard. Leave false and use `kubectl port-forward` unless you specifically need external access."
  type        = bool
  default     = false
}

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
