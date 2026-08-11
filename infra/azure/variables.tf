variable "subscription_id" {
  description = "Azure subscription ID to deploy into"
  type        = string
}

variable "location" {
  description = "Azure region for the resource group, storage account, and AKS cluster"
  type        = string
  default     = "Australia East"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes minor version (kept aligned with the EKS build in infra/aws)"
  type        = string
  default     = "1.33"
}

variable "node_count" {
  description = "Kept small - this cluster is meant to be created, demoed, and destroyed the same session"
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "Burstable B-series: enough headroom for K10 + the demo app, notably cheaper than general-purpose D-series for a short-lived cluster"
  type        = string
  default     = "Standard_B2ms"
}
