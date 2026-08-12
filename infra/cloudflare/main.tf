terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# CLOUDFLARE_API_TOKEN env var - not stored in this repo.
provider "cloudflare" {}

resource "cloudflare_load_balancer_monitor" "veeamon_tour" {
  account_id     = var.account_id
  type           = "http"
  path           = "/healthz"
  expected_codes = "200"
  interval       = 30
  timeout        = 5
  retries        = 2
}

resource "cloudflare_load_balancer_pool" "aks" {
  account_id = var.account_id
  name       = "veeamon-tour-aks"
  origins {
    name    = "aks"
    address = var.aks_ip
    enabled = true
  }
  monitor = cloudflare_load_balancer_monitor.veeamon_tour.id
}

resource "cloudflare_load_balancer_pool" "eks" {
  account_id = var.account_id
  name       = "veeamon-tour-eks"
  origins {
    name    = "eks"
    address = var.eks_ip
    enabled = true
  }
  monitor = cloudflare_load_balancer_monitor.veeamon_tour.id
}

# Failover steering, not round-robin: AKS is primary, EKS only takes traffic
# once AKS's health check fails - so the demo shows a clean before/after
# rather than random load spreading across both clusters.
resource "cloudflare_load_balancer" "veeamon_tour" {
  zone_id          = var.zone_id
  name             = var.hostname
  fallback_pool_id = cloudflare_load_balancer_pool.eks.id
  default_pool_ids = [cloudflare_load_balancer_pool.aks.id]
  steering_policy  = "off"
  proxied          = true
}
