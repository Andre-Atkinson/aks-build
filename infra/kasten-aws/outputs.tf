output "profile_name" {
  description = "Name of the K10 Location Profile pointing at the shared Azure Blob container"
  value       = "azureblob"
}

output "ebs_volume_snapshot_class" {
  value = "csi-ebs-vsc"
}

output "ebs_storage_class" {
  value = "ebs-gp3"
}
