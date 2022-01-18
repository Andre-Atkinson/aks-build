#get AppID details
$secrets = Get-Content .\sp.txt | ConvertFrom-Json
Set-Item -Path env:TF_VAR_username -Value "$env:USERNAME"
Set-Item -Path env:TF_VAR_appId -Value $secrets.appId
Set-Item -Path env:TF_VAR_password -Value $secrets.password
Set-Item -Path env:TF_VAR_tenant -Value $secrets.tenant

#Delete K10 
write-host "Deleting Kasten and Pacman" -ForegroundColor Green
Set-Location '.\3 helm'
terraform init
terraform destroy --auto-approve
Set-Location ..

#Delete Cluster
write-host "Deleting Kubernetes cluster" -ForegroundColor Green
Set-Location '.\1 Cluster_setup'
terraform init
terraform destroy --auto-approve
Set-Location ..

#Delete SP
write-host "Deleting Service Principal Account." -ForegroundColor Green
az ad sp delete --id $env:TF_VAR_appId
Remove-Item sp.txt