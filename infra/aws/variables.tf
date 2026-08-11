variable "region" {
  description = "AWS region to deploy the EKS cluster into"
  type        = string
  default     = "ap-southeast-2"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version (kept aligned with the AKS build in infra/azure)"
  type        = string
  default     = "1.33"
}

variable "node_instance_type" {
  description = "Burstable t3: matches infra/azure's B-series choice - cheaper than m5.large for a short-lived demo cluster"
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  description = "Kept small - this cluster is meant to be created, demoed, and destroyed the same session"
  type        = number
  default     = 2
}
