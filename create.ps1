#vars
##Change these based on what you need to install.
$kubectl = 0
$helm = 0
$AZ = 0
$terraform = 0

#Check to see if script is running with Admin privileges
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please relaunch Powershell as admin" -BackgroundColor Red
    Write-Host "Press any key to continue..."
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    exit;
}

#download Helm and add to environment variables
#download the kubectl V1.21.7 and add to the system environment variables
if ($kubectl -eq 1) {
    new-item  -path "C:\kubectl" -ItemType Directory -Force
    write-host "Downloading Kubectl" -ForegroundColor Green
    Invoke-WebRequest -OutFile "c:\users\$env:UserName\Downloads\kubectl.exe" -Uri "https://dl.k8s.io/release/v1.21.7/bin/windows/amd64/kubectl.exe" -UseBasicParsing
    Copy-Item "c:\users\$env:UserName\Downloads\kubectl.exe" -Destination "C:\kubectl"


    $oldPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    if ($oldPath.Split(';') -inotcontains 'C:\kubectl') {
 `
            [Environment]::SetEnvironmentVariable('Path', $('{0};C:\kubectl' -f $oldPath), [EnvironmentVariableTarget]::Machine) `

    }
    Start-Sleep 2
}
if ($helm -eq 1) {
    new-item  -path "C:\helm" -ItemType Directory -Force
    write-host "Downloading Helm" -ForegroundColor Green
    Invoke-WebRequest -OutFile "C:\helm\helmzip.zip" -Uri 'https://get.helm.sh/helm-v3.7.1-windows-amd64.zip' -UseBasicParsing
    Get-ChildItem 'C:\helm\' -Filter *.zip | Expand-Archive -DestinationPath 'C:\helm\' -Force
    Copy-Item "C:\helm\windows-amd64\helm.exe" -Destination "C:\helm"
    Remove-Item "C:\helm\helmzip.zip"
    Remove-Item "C:\helm\windows-amd64" -Recurse

    $oldPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    if ($oldPath.Split(';') -inotcontains 'C:\helm') {
 `
            [Environment]::SetEnvironmentVariable('Path', $('{0};C:\helm' -f $oldPath), [EnvironmentVariableTarget]::Machine) `

    }
}

if ($terraform -eq 1) {
    new-item  -path "C:\terraform" -ItemType Directory -Force
    write-host "Downloading Terraform" -ForegroundColor Green
    Invoke-WebRequest -OutFile "C:\terraform\terra.zip" -Uri 'https://releases.hashicorp.com/terraform/1.1.3/terraform_1.1.3_windows_amd64.zip' -UseBasicParsing
    Get-ChildItem 'C:\terraform\' -Filter *.zip | Expand-Archive -DestinationPath 'C:\terraform' -Force
    Remove-Item "C:\terraform\terra.zip"

    $oldPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    if ($oldPath.Split(';') -inotcontains 'C:\helm') {
 `
            [Environment]::SetEnvironmentVariable('Path', $('{0};C:\helm' -f $oldPath), [EnvironmentVariableTarget]::Machine) `

    }
}

#download Azure CLI and add to environment variables
if ($AZ -eq 1){
$ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows `
 -OutFile .\AzureCLI.msi; Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'; Remove-Item .\AzureCLI.msi

 $oldPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
 if ($oldPath.Split(';') -inotcontains 'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin') {
`
         [Environment]::SetEnvironmentVariable('Path', $('{0};C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin' -f $oldPath), [EnvironmentVariableTarget]::Machine) `

 }
}
 #Refresh path variable to allow Helm/Kubectl to work.
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

#Log into Azure CLI
az login

#Create Service Principal to use for K8s
write-host "Creating Service Principal to use for K8s" -ForegroundColor Green
az ad sp create-for-rbac --name "k8s" --skip-assignment | out-file sp.txt
Start-Sleep 5
$secrets=Get-Content .\sp.txt | ConvertFrom-Json
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

Clear-Host
Write-Host "Please log into the Kasten Dashboard using the token below `n" -ForegroundColor blue
Write-Host '#########################################################################'  -ForegroundColor Green
Write-Host ([Text.Encoding]::Utf8.GetString([Convert]::FromBase64String($k10token.data.token))) -ForegroundColor Green
Write-Host '#########################################################################'  -ForegroundColor Green
