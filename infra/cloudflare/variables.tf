variable "zone_id" {
  description = "Cloudflare zone ID to create the DNS record and load balancer in"
  type        = string
}

variable "hostname" {
  description = "Full hostname to create, e.g. veeamon-tour.example.com"
  type        = string
}

variable "aks_ip" {
  description = "External IP of the veeamon-tour Service on AKS"
  type        = string
}

variable "eks_ip" {
  description = "External IP (or hostname) of the veeamon-tour Service on EKS"
  type        = string
}
