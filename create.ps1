param (
    [Parameter(Mandatory = $true)]
    [string]$subscription
)

#Variables
$randomNumber = Get-Random -Minimum 10000 -Maximum 99999
$randomNumber | Out-File -FilePath "randomnumber.txt"

#Check to see if script is running with Admin privileges
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please relaunch Powershell as admin" -BackgroundColor Red
    Write-Host "Press any key to continue..."
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    exit;
}

#Add modules
try {
    $azureAdModule = Get-Module -Name Az -ListAvailable

    if ($null -eq $azureAdModule) {
        Write-Host "Installing AzureAD PowerShell module" -ForegroundColor Green
        Install-Module -Name Az -Repository PSGallery -Force
        Import-Module -Name Az -Force
        Update-AzConfig -EnableLoginByWam $false -confirm:$false
        Update-AzConfig -LoginExperienceV2 Off -Confirm:$false
    }
    else {
        Write-Host "AzureAD module is already installed" -ForegroundColor Green
        Import-Module -Name Az -Force
        Update-AzConfig -EnableLoginByWam $false -confirm:$false
        Update-AzConfig -LoginExperienceV2 Off -Confirm:$false
    }
}
catch {
    Write-Host "An error occurred: $_" -ForegroundColor Red
}


#test if Kubectl is installed, if not install it and add it add it to environment variables.
try {
    kubectl | Out-Null
    Write-Host "Kubectl is installed, moving on" -ForegroundColor Green
}
catch {
    Write-Host "Kubectl is not installed and will be installed now."
    new-item  -path "C:\kubectl" -ItemType Directory -Force
    write-host "Downloading Kubectl" -ForegroundColor Green
    Invoke-WebRequest -OutFile "C:\kubectl\kubectl.exe" -Uri "https://dl.k8s.io/release/v1.33.0/bin/windows/amd64/kubectl.exe" -UseBasicParsing
    
    $oldPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    if ($oldPath.Split(';') -inotcontains 'C:\kubectl') {
 `
            [Environment]::SetEnvironmentVariable('Path', $('{0};C:\kubectl' -f $oldPath), [EnvironmentVariableTarget]::Machine) `
    
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

#Test if Helm is installed
try {
    helm | Out-Null
    Write-Host "helm is installed, moving on" -ForegroundColor Green
}
catch {
    Write-Host "helm is not installed and will be installed now."
    new-item  -path "C:\helm" -ItemType Directory -Force
    write-host "Downloading Helm" -ForegroundColor Green
    Invoke-WebRequest -OutFile "C:\helm\helmzip.zip" -Uri 'https://get.helm.sh/helm-v3.17.3-windows-amd64.zip' -UseBasicParsing
    Get-ChildItem 'C:\helm\' -Filter *.zip | Expand-Archive -DestinationPath 'C:\helm\' -Force
    Copy-Item "C:\helm\windows-amd64\helm.exe" -Destination "C:\helm"
    Remove-Item "C:\helm\helmzip.zip"
    Remove-Item "C:\helm\windows-amd64" -Recurse

    $oldPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    if ($oldPath.Split(';') -inotcontains 'C:\helm') {
 `
            [Environment]::SetEnvironmentVariable('Path', $('{0};C:\helm' -f $oldPath), [EnvironmentVariableTarget]::Machine) `

    }

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

#Test if Terraform is installed
try {
    terraform | Out-Null
    Write-Host "Terraform is installed, moving on" -ForegroundColor Green
}
catch {
    Write-Host "Terraform is not installed and will be installed now."
    new-item  -path "C:\Terraform" -ItemType Directory -Force
    write-host "Downloading Terraform" -ForegroundColor Green
    Invoke-WebRequest -OutFile "C:\terraform\terraform.zip" -Uri 'https://releases.hashicorp.com/terraform/1.11.4/terraform_1.11.4_windows_amd64.zip' -UseBasicParsing
    Get-ChildItem 'C:\terraform\' -Filter *.zip | Expand-Archive -DestinationPath 'C:\terraform\' -Force
    Copy-Item "C:\terraform\terraform_1.11.4_windows_amd64\terraform.exe" -Destination "C:\helm"
    Remove-Item "C:\terraform\terraform.zip"
    Remove-Item "C:\terraform\terraform_1.11.4_windows_amd64" -Recurse

    $oldPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    if ($oldPath.Split(';') -inotcontains 'C:\terraform') {
 `
            [Environment]::SetEnvironmentVariable('Path', $('{0};C:\terraform' -f $oldPath), [EnvironmentVariableTarget]::Machine) `

    }

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

#Connect to Azure Account
try {
    # Connect to Azure Account
    Connect-AzAccount -Subscription "$subscription"

    # Set Azure context to the specified subscription
    Set-AzContext -Subscription "$subscription"

    # Update Azure configuration for default subscription
    Update-AzConfig -DefaultSubscriptionForLogin "$subscription"

}
catch {
    Write-Host "Error occurred while connecting to Azure or setting the context: $($_.Exception.Message)" -ForegroundColor Red
    exit 1  # Exit the script with a non-zero status code
}

try {
    Write-Host "Creating Service Principal to use for K8s" -ForegroundColor Green

    $sp = New-AzADServicePrincipal -DisplayName "k10demo_$randomNumber" -Role "Contributor"| Select-Object *
    $sp | ConvertTo-Json | Out-File -FilePath "sp.txt"

}
catch {
    Write-Host "Error occurred while creating the Service Principal: $($_.Exception.Message)" -ForegroundColor Red
    exit 1  # Exit the script with a non-zero status code
}


Start-Sleep 5
$randomNumber = get-content .\randomnumber.txt
$secrets = Get-Content .\sp.txt | ConvertFrom-Json
Set-Item -Path env:TF_VAR_username -Value "$env:USERNAME"
Set-Item -Path env:TF_VAR_appId -Value $secrets.appId
Set-Item -Path env:TF_VAR_password -Value $secrets.PasswordCredentials[0].SecretText #$secrets.password
Set-Item -Path env:TF_VAR_tenant -Value $secrets.AppOwnerOrganizationId
Set-Item -Path env:TF_VAR_subscription -Value $subscription
Set-Item -Path env:TF_VAR_randomNumber -Value $randomNumber


#Create Cluster
write-host "Creating Kubernetes cluster" -ForegroundColor Green
Set-Location '.\1 Cluster_setup'
terraform init
terraform apply --auto-approve

#Configure kubectl
$resource = terraform output -json | ConvertFrom-Json
Import-AzAksCredential -ResourceGroupName $resource.resource_group_name.value -Name $resource.kubernetes_cluster_name.value -Force
Set-Location ..
start-sleep 30

kubectl config use-context $resource.kubernetes_cluster_name.value

#Create snapshotclass
write-host "Adding Snapshot class" -ForegroundColor Green
$yaml = @"
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  annotations:
    k10.kasten.io/is-snapshot-class: "true"
  name: csi-azuredisk-vsc
driver: disk.csi.azure.com
deletionPolicy: Delete
parameters:
  incremental: "true"
"@
# Save the YAML to a temporary file
$yamlPath = [System.IO.Path]::GetTempFileName() + ".yaml"
$yaml | Set-Content -Path $yamlPath
# Apply the YAML configuration using kubectl
kubectl apply -f $yamlPath
# Remove the temporary file
Remove-Item $yamlPath

#install K10 
write-host "Installing Kasten" -ForegroundColor Green
Set-Location '.\2 kasten'
terraform init
terraform apply --auto-approve
Set-Location ..

#wait for pods to come up
$ready = kubectl get pod -n kasten-io --selector=component=catalog -o=jsonpath='{.items[*].status.phase}'
do {
    Write-Host "Waiting for pods to be ready" -ForegroundColor Green
    start-sleep 10
    $ready = kubectl get pod -n kasten-io --selector=component=catalog -o=jsonpath='{.items[*].status.phase}'
} while ($ready -notlike "Running")
Write-Host "Pods are ready, moving on" -ForegroundColor Green

#Get K10 secret and extract login token
$yaml = @"
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: k10-k10-token
  namespace: kasten-io
  annotations:
    kubernetes.io/service-account.name: "k10-k10"
"@
# Save the YAML to a temporary file
$yamlPath = [System.IO.Path]::GetTempFileName() + ".yaml"
$yaml | Set-Content -Path $yamlPath
# Apply the YAML configuration using kubectl
kubectl apply -f $yamlPath
# Remove the temporary file
Remove-Item $yamlPath

$secret = kubectl get secrets -n kasten-io | select-string -Pattern "k10-k10-token" | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }
$k10token = kubectl -n kasten-io -ojson get secret $secret | convertfrom-json | Select-Object data

#Get Azure Storage Account
$storageAccount = Get-AzStorageAccount -ResourceGroupName "$($resource.resource_group_name.value)" -Name "$($resource.storageaccount_name.value)"
$storageAccountKeys = Get-AzStorageAccountKey -ResourceGroupName $storageAccount.ResourceGroupName -Name $storageAccount.StorageAccountName; $storageAccountKey = $storageAccountKeys[0].Value

# Create a Azure Blob Storage profile secret
kubectl create secret generic k10-azure-secret `
    --namespace kasten-io `
    --type secrets.kanister.io/azure `
    --from-literal=azure_storage_account_id="$($storageAccount.StorageAccountName)" `
    --from-literal=azure_storage_environment="AzurePublicCloud" `
    --from-literal=azure_storage_key=$($storageAccountKey)

# Create the Azure Blob Storage profile
$yaml = @"
kind: Profile
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: azureblob
  namespace: kasten-io
spec:
  locationSpec:
    type: ObjectStore
    objectStore:
      name: $($resource.storagecontainer_name.value)
      objectStoreType: AZ
      region: ap-southeast-2
    credential:
      secretType: AzStorageAccount
      secret:
        apiVersion: v1
        kind: secret
        name: k10-azure-secret
        namespace: kasten-io
  type: Location
"@

# Save the YAML to a temporary file
$yamlPath = [System.IO.Path]::GetTempFileName() + ".yaml"
$yaml | Set-Content -Path $yamlPath

# Apply the YAML configuration using kubectl
kubectl apply -f $yamlPath
# Remove the temporary file
Remove-Item $yamlPath

#Create DNS records for Kasten
$k10ip = kubectl get service -n kasten-io gateway-ext -o=jsonpath='{.status.loadBalancer.ingress[0].ip}'
$k10 = get-azpublicipaddress | Where-Object { $_.IpAddress -eq "$k10ip" }
$k10.DnsSettings = @{"DomainNameLabel" = "k10demo-$randomNumber" }
Set-AzPublicIpAddress -PublicIpAddress $k10
$k10 = get-azpublicipaddress | Where-Object { $_.IpAddress -eq "$k10ip" }
$k10fqdn = $k10.DnsSettings.Fqdn


Write-Host "Kasten dashboard is now available at http://$k10fqdn/k10/" -ForegroundColor Green
Write-Host "Please log into the Kasten Dashboard using the token below (Hashes not included) `n" -ForegroundColor blue
Write-Host '#########################################################################'  -ForegroundColor red
Write-Host ([Text.Encoding]::Utf8.GetString([Convert]::FromBase64String($k10token.data.token))) -ForegroundColor Green
Write-Host '#########################################################################'  -ForegroundColor red