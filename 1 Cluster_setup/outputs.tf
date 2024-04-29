output "resource_group_name" {
  value = azurerm_resource_group.default.name
}

output "kubernetes_cluster_name" {
  value = azurerm_kubernetes_cluster.default.name
}

output "storageaccount_name" {
  value = azurerm_storage_account.default.name
}

output "storagecontainer_name" {
  value = azurerm_storage_container.default.name
}