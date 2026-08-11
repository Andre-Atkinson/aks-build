output "resource_group_name" {
  value = azurerm_resource_group.default.name
}

output "kubernetes_cluster_name" {
  value = azurerm_kubernetes_cluster.default.name
}

output "storage_account_name" {
  value = azurerm_storage_account.default.name
}

output "storage_container_name" {
  value = azurerm_storage_container.default.name
}

output "kube_config" {
  value     = azurerm_kubernetes_cluster.default.kube_config_raw
  sensitive = true
}
