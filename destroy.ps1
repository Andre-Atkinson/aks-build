param (
    [Parameter(Mandatory = $true)]
    [string]$subscription
)
#get AppID details
$secrets = Get-Content .\sp.txt | ConvertFrom-Json
$randomNumber = get-content .\randomnumber.txt
Set-Item -Path env:TF_VAR_username -Value "$env:USERNAME"
Set-Item -Path env:TF_VAR_appId -Value $secrets.appId
Set-Item -Path env:TF_VAR_password -Value $secrets.PasswordCredentials[0].SecretText #$secrets.password
Set-Item -Path env:TF_VAR_tenant -Value $secrets.AppOwnerOrganizationId
Set-Item -Path env:TF_VAR_subscription -Value $subscription
Set-Item -Path env:TF_VAR_randomNumber -Value $randomNumber

#Delete Cluster
write-host "Destroy first Azure resources and First cluster" -ForegroundColor Green
Set-Location '.\1 Cluster_setup'
terraform init
terraform destroy --auto-approve
Set-Location ..

#Delete SP
write-host "Deleting Service Principal Account." -ForegroundColor Green
Get-AzADApplication | Where-Object { $_.DisplayName -contains $($secrets.AppDisplayName) } | Remove-AzADApplication
Remove-Item sp.txt
Remove-Item randomnumber.txt