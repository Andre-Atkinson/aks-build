#Check to see if script is running with Admin privileges
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please relaunch Powershell as admin" -BackgroundColor Red
    Write-Host "Press any key to continue..."
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    exit;
}

#Add modules
if (!(Get-Module -Name AZ -ListAvailable)) {
    write-host "Installing Azure Powershell module" -ForegroundColor Green
    Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
    Import-Module -Name Az    
}

#Log into Azure CLI
az login
#Connect-AzAccount

#Create Service Principal to use for K8s
write-host "Creating Service Principal to use for K8s" -ForegroundColor Green
az ad sp create-for-rbac --name "k8s" --skip-assignment | out-file sp.txt
Start-Sleep 5
$secrets = Get-Content .\sp.txt | ConvertFrom-Json
Set-Item -Path env:TF_VAR_username -Value "$env:USERNAME"
Set-Item -Path env:TF_VAR_appId -Value $secrets.appId
Set-Item -Path env:TF_VAR_password -Value $secrets.password
Set-Item -Path env:TF_VAR_tenant -Value $secrets.tenant

#Create Cluster
write-host "Creating Kubernetes cluster" -ForegroundColor Green
Set-Location '.\1 Cluster_setup'
terraform init
terraform apply --auto-approve

#Configure kubectl
az aks get-credentials --resource-group $(terraform output -raw resource_group_name) --name $(terraform output -raw kubernetes_cluster_name)
Set-Location ..
start-sleep 30

#Create snapshotclass
write-host "Adding Snapshot class" -ForegroundColor Green
Set-Location '.\2 Snapshot'
kubectl apply -f snapshotclass.yaml
Set-Location ..
start-sleep 10

#install K10 
write-host "Installing Kasten" -ForegroundColor Green
Set-Location '.\3 helm'
terraform init
terraform apply --auto-approve
Set-Location ..

#wait for pods to come up
$ready = kubectl get pod -n kasten-io --selector=component=catalog -o=jsonpath='{.items[*].status.phase}'
do {
    Write-Host "Waiting for pods to be ready" -ForegroundColor Green
    start-sleep 20
    $ready = kubectl get pod -n kasten-io --selector=component=catalog -o=jsonpath='{.items[*].status.phase}'
} while ($ready -notlike "Running")
Write-Host "Pods are ready, moving on" -ForegroundColor Green

#Get K10 secret and extract login token
$secret = kubectl get secrets -n kasten-io | select-string -Pattern "k10-k10-token-\w*" | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }
$k10token = kubectl -n kasten-io -ojson get secret $secret | convertfrom-json | Select-Object data

#Create DNS records for Pacman
$randint = Get-Random -Maximum 5000
$pacmanip = kubectl get service -n pacman pacman -o=jsonpath='{.status.loadBalancer.ingress[0].ip}'
$pacman = get-azpublicipaddress | Where-Object { $_.IpAddress -eq "$pacmanip" }
$pacman.DnsSettings = @{"DomainNameLabel" = "k10pacmandemo$randint" }
Set-AzPublicIpAddress -PublicIpAddress $pacman
$pacman = get-azpublicipaddress | Where-Object { $_.IpAddress -eq "$pacmanip" }
$pacmanfqdn = $pacman.DnsSettings.Fqdn

#Create DNS records for Kasten
$k10ip = kubectl get service -n kasten-io gateway-ext -o=jsonpath='{.status.loadBalancer.ingress[0].ip}'
$k10 = get-azpublicipaddress | Where-Object { $_.IpAddress -eq "$k10ip" }
$k10.DnsSettings = @{"DomainNameLabel" = "k10kastendemo$randint" }
Set-AzPublicIpAddress -PublicIpAddress $k10
$k10 = get-azpublicipaddress | Where-Object { $_.IpAddress -eq "$k10ip" }
$k10fqdn = $k10.DnsSettings.Fqdn

Clear-Host
Write-Host "Pacman is now available at http://$pacmanfqdn" -ForegroundColor Green
Write-Host "Kasten dashboard is now available at http://$k10fqdn/k10/" -ForegroundColor Green
Write-Host "Please log into the Kasten Dashboard using the token below (Hashes not included) `n" -ForegroundColor blue
Write-Host '#########################################################################'  -ForegroundColor red
Write-Host ([Text.Encoding]::Utf8.GetString([Convert]::FromBase64String($k10token.data.token))) -ForegroundColor Green
Write-Host '#########################################################################'  -ForegroundColor red