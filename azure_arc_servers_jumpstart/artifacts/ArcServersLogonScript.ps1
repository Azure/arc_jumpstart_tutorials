$ErrorActionPreference = $env:ErrorActionPreference
$Env:ArcBoxDir = "C:\ArcBox"
$Env:ArcBoxLogsDir = "$Env:ArcBoxDir\Logs"
$Env:ArcBoxVMDir = "F:\Virtual Machines"
$Env:ArcBoxIconDir = "$Env:ArcBoxDir\Icons"
$Env:ArcBoxDscDir = "$Env:ArcBoxDir\DSC"
$agentScript = "$Env:ArcBoxDir\agentScript"

# Set variables to execute remote powershell scripts on guest VMs
$nestedVMArcBoxDir = $Env:ArcBoxDir
$tenantId = $env:spnTenantId
$subscriptionId = $env:subscriptionId
$azureLocation = $env:azureLocation
$resourceGroup = $env:resourceGroup
$changeTrackingDCR = $env:changeTrackingDCR
$vmInsightsDCR = $env:vmInsightsDCR

# Moved VHD storage account details here to keep only in place to prevent duplicates.
$vhdSourceFolder = "https://jumpstartprodsg.blob.core.windows.net/arcbox/prod/*"

# Archive exising log file and crate new one
$logFilePath = "$Env:ArcBoxLogsDir\ArcServersLogonScript.log"
if ([System.IO.File]::Exists($logFilePath)) {
    $archivefile = "$Env:ArcBoxLogsDir\ArcServersLogonScript-" + (Get-Date -Format "yyyyMMddHHmmss")
    Rename-Item -Path $logFilePath -NewName $archivefile -Force
}

Start-Transcript -Path $logFilePath -Force -ErrorAction SilentlyContinue

# Remove registry keys that are used to automatically logon the user (only used for first-time setup)
$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$keys = @("AutoAdminLogon", "DefaultUserName", "DefaultPassword")

foreach ($key in $keys) {
    try {
        $property = Get-ItemProperty -Path $registryPath -Name $key -ErrorAction Stop
        Remove-ItemProperty -Path $registryPath -Name $key
        Write-Host "Removed registry key that are used to automatically logon the user: $key"
    }
    catch {
        Write-Verbose "Key $key does not exist."
    }
}


################################################
# Setup Hyper-V server before deploying VMs for each flavor
################################################
# Install and configure DHCP service (used by Hyper-V nested VMs)
Write-Host "Configuring DHCP Service"
$dnsClient = Get-DnsClient | Where-Object { $_.InterfaceAlias -eq "Ethernet" }
$dhcpScope = Get-DhcpServerv4Scope
if ($dhcpScope.Name -ne "ArcBox") {
    Add-DhcpServerv4Scope -Name "ArcBox" `
        -StartRange 10.10.1.100 `
        -EndRange 10.10.1.200 `
        -SubnetMask 255.255.255.0 `
        -LeaseDuration 1.00:00:00 `
        -State Active
}

$dhcpOptions = Get-DhcpServerv4OptionValue
if ($dhcpOptions.Count -lt 3) {
    Set-DhcpServerv4OptionValue -ComputerName localhost `
        -DnsDomain $dnsClient.ConnectionSpecificSuffix `
        -DnsServer 168.63.129.16, 10.16.2.100 `
        -Router 10.10.1.1 `
        -Force
}

# Create the NAT network
Write-Host "Creating Internal NAT"
$natName = "InternalNat"
$netNat = Get-NetNat
if ($netNat.Name -ne $natName) {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 10.10.1.0/24
}

Write-Host "Creating VM Credentials"
# Hard-coded username and password for the nested VMs
$nestedWindowsUsername = "Administrator"
$nestedWindowsPassword = "JS123!!"

# Create Windows credential object
$secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force
$winCreds = New-Object System.Management.Automation.PSCredential ($nestedWindowsUsername, $secWindowsPassword)

# Creating Hyper-V Manager desktop shortcut
Write-Host "Creating Hyper-V Shortcut"
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -Destination "C:\Users\All Users\Desktop" -Force

$cliDir = New-Item -Path "$Env:ArcBoxDir\.cli\" -Name ".servers" -ItemType Directory -Force
if (-not $($cliDir.Parent.Attributes.HasFlag([System.IO.FileAttributes]::Hidden))) {
    $folder = Get-Item $cliDir.Parent.FullName -ErrorAction SilentlyContinue
    $folder.Attributes += [System.IO.FileAttributes]::Hidden
}

# Install Azure CLI extensions
Write-Header "Az CLI extensions"

az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors

@("ssh", "log-analytics-solution", "connectedmachine", "monitor-control-service") |
ForEach-Object -Parallel {
    az extension add --name $PSItem --yes --only-show-errors
}

# Required for CLI commands
Write-Header "Az CLI Login"
az login --identity
az account set -s $subscriptionId

Write-Header "Az PowerShell Login"
Connect-AzAccount -Identity -Tenant $tenantId -Subscription $subscriptionId

# Enable defender for cloud for SQL Server
# Get workspace information
$workspaceResourceID = (az monitor log-analytics workspace show --resource-group $resourceGroup --workspace-name $Env:workspaceName --query "id" -o tsv)

# Before deploying ArcBox SQL set resource group tag ArcSQLServerExtensionDeployment=Disabled to opt out of automatic SQL onboarding
#az tag create --resource-id "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup" --tags ArcSQLServerExtensionDeployment=Disabled

$vhdImageToDownload = "ArcBox-SQL-DEV.vhdx"
if ($Env:sqlServerEdition -eq "Standard") {
    $vhdImageToDownload = "ArcBox-SQL-STD.vhdx"
}
elseif ($Env:sqlServerEdition -eq "Enterprise") {
    $vhdImageToDownload = "ArcBox-SQL-ENT.vhdx"
}

# Create the nested VMs if not already created
Write-Header "Create Hyper-V VMs"

# Onboard nested Windows and Linux VMs to Azure Arc
Write-Header "Fetching Nested VMs"

$SQLvmvhdPath = "$Env:ArcBoxVMDir\ArcBox-SQL.vhdx"
$SQLvmName = "ArcBox-SQL"
        
$Win2k25vmName = "ArcBox-Win2K25"
$win2k25vmvhdPath = "${Env:ArcBoxVMDir}\ArcBox-Win2K25.vhdx"

$Win2k22vmName = "ArcBox-Win2K22"
$Win2k22vmvhdPath = "${Env:ArcBoxVMDir}\ArcBox-Win2K22.vhdx"

$Ubuntu01vmName = "ArcBox-Ubuntu-01"
$Ubuntu01vmvhdPath = "${Env:ArcBoxVMDir}\ArcBox-Ubuntu-01.vhdx"

$Ubuntu02vmName = "ArcBox-Ubuntu-02"
$Ubuntu02vmvhdPath = "${Env:ArcBoxVMDir}\ArcBox-Ubuntu-02.vhdx"

$ProxyvmName = "ArcBox-Proxy"
$ProxyvmvhdPath = "${Env:ArcBoxVMDir}\ArcBox-Proxy.vhdx"

# Verify if VHD files already downloaded especially when re-running this script
if (!(Test-Path $SQLvmvhdPath) -and !((Test-Path $win2k25vmvhdPath) -and (Test-Path $Win2k22vmvhdPath) -and (Test-Path $Ubuntu01vmvhdPath) -and (Test-Path $Ubuntu02vmvhdPath))) {
    <# Action when all if and elseif conditions are false #>
    $Env:AZCOPY_BUFFER_GB = 8
    Write-Output "Downloading nested VMs VHDX files. This can take some time, hold tight..."
    azcopy cp $vhdSourceFolder $Env:ArcBoxVMDir --include-pattern "$vhdImageToDownload;ArcBox-Win2K25.vhdx;ArcBox-Win2K22.vhdx;ArcBox-Ubuntu-01.vhdx;ArcBox-Ubuntu-02.vhdx;" --recursive=true --check-length=false --log-level=ERROR
    # Rename SQL VHD file
    Rename-Item -Path "$Env:ArcBoxVMDir\$vhdImageToDownload" -NewName  $SQLvmvhdPath -Force
    # Copy the ubuntu-02.vhdx to Proxy.vhdx
    Write-Host "Creating proxy VHDX file"
    Copy-Item -Path "$Env:ArcBoxVMDir\ArcBox-Ubuntu-02.vhdx" -Destination $ProxyvmvhdPath -Force
}

# Create the nested VMs if not already created
Write-Header "Create Hyper-V VMs"
$serversDscConfigurationFile = "$Env:ArcBoxDscDir\virtual_machines_itpro.dsc.yml"
#(Get-Content -Path $serversDscConfigurationFile) -replace 'namingPrefixStage', $namingPrefix | Set-Content -Path $serversDscConfigurationFile
(Get-Content -Path $serversDscConfigurationFile) | Set-Content -Path $serversDscConfigurationFile
winget configure --file C:\ArcBox\DSC\virtual_machines_itpro.dsc.yml --accept-configuration-agreements --disable-interactivity

Set-VM -Name $Win2k25vmName -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name $Win2k22vmName -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name $Ubuntu01vmName -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name $Ubuntu02vmName -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name $SQLvmName -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VM -Name $ProxyvmName -AutomaticStartAction Start -AutomaticStopAction ShutDown

Start-Sleep -seconds 15

# Start all the VMs
Write-Host "Starting VMs"
Start-VM -Name $Win2k25vmName
Start-VM -Name $Win2k22vmName
Start-VM -Name $Ubuntu01vmName
Start-VM -Name $Ubuntu02vmName
Start-VM -Name $SQLvmName
Start-VM -Name $ProxyvmName

Start-Sleep -seconds 15


Write-Header "Creating VM Credentials"
# Hard-coded username and password for the nested VMs
$nestedLinuxUsername = "jumpstart"

# Restarting Windows VM Network Adapters
Write-Header "Restarting Network Adapters"
Start-Sleep -Seconds 5
Invoke-Command -VMName $Win2k25vmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
Invoke-Command -VMName $Win2k22vmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
Invoke-Command -VMName $SQLvmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
Start-Sleep -Seconds 10

# Getting the Ubuntu nested VM IP address
$Ubuntu01VmIp = Get-VM -Name $Ubuntu01vmName | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses | Select-Object -Index 0
$Ubuntu02VmIp = Get-VM -Name $Ubuntu02vmName | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses | Select-Object -Index 0
$ProxyVmIp = Get-VM -Name $ProxyvmName | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses | Select-Object -Index 0

#Reserve IP address for proxy so it does not change
Get-DhcpServerv4Lease -IPAddress $ProxyVmIp| Add-DhcpServerv4Reservation

# Configuring SSH for accessing Linux VMs
Write-Output "Generating SSH key for accessing nested Linux VMs"

$null = New-Item -Path ~ -Name .ssh -ItemType Directory
ssh-keygen -t rsa -N '' -f $Env:USERPROFILE\.ssh\id_rsa

Copy-Item -Path "$Env:USERPROFILE\.ssh\id_rsa.pub" -Destination "$Env:TEMP\authorized_keys"

# Automatically accept unseen keys but will refuse connections for changed or invalid hostkeys.
Add-Content -Path "$Env:USERPROFILE\.ssh\config" -Value "StrictHostKeyChecking=accept-new"

# Running twice due to a race condition where the target file is sometimes empty
Get-VM *Ubuntu* | Copy-VMFile -SourcePath "$($Env:TEMP)\authorized_keys" -DestinationPath "/home/$nestedLinuxUsername/.ssh/" -FileSource Host -Force -CreateFullPath
Get-VM *Ubuntu* | Copy-VMFile -SourcePath "$($Env:TEMP)\authorized_keys" -DestinationPath "/home/$nestedLinuxUsername/.ssh/" -FileSource Host -Force -CreateFullPath
Get-VM *Proxy* | Copy-VMFile -SourcePath "$($Env:TEMP)\authorized_keys" -DestinationPath "/home/$nestedLinuxUsername/.ssh/" -FileSource Host -Force -CreateFullPath

# Remove the authorized_keys file from the local machine
Remove-Item -Path "$($Env:TEMP)\authorized_keys"
    
# Copy installation script to nested Windows VMs
Write-Output "Transferring installation script to nested Windows VMs..."
Copy-VMFile $Win2k25vmName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force
    
# Update Linux VM onboarding script connect toAzure Arc, get new token as it might have been expired by the time execution reached this line.
$accessToken = ConvertFrom-SecureString ((Get-AzAccessToken -AsSecureString).Token) -AsPlainText
        (Get-Content -path "$agentScript\installArcAgentUbuntu.sh" -Raw) -replace '\$accessToken', "'$accessToken'" -replace '\$resourceGroup', "'$resourceGroup'" -replace '\$spnTenantId', "'$tenantId'" -replace '\$azureLocation', "'$Env:azureLocation'" -replace '\$subscriptionId', "'$subscriptionId'" | Set-Content -Path "$agentScript\installArcAgentModifiedUbuntu.sh"

# Copy installation script to nested Linux VMs
Write-Output "Transferring installation script to nested Linux VMs..."

#WorkshopPlus: only ubuntu-01 is onboarded
Get-VM *Ubuntu-01* | Copy-VMFile -SourcePath "$agentScript\installArcAgentModifiedUbuntu.sh" -DestinationPath "/home/$nestedLinuxUsername" -FileSource Host -Force

#Installing Squid proxy on the Proxy VM
Write-Output "Installing Squid proxy on the Proxy VM"

$ProxySessions = New-PSSession -HostName $ProxyVmIp -KeyFilePath "$Env:USERPROFILE\.ssh\id_rsa" -UserName $nestedLinuxUsername
Invoke-JSSudoCommand -Session $ProxySessions -Command 'sudo hostnamectl set-hostname "proxy"'
Invoke-JSSudoCommand -Session $ProxySessions -Command "sudo apt-get update"
Invoke-JSSudoCommand -Session $ProxySessions -Command "sudo apt-get install squid -y"
#Copy the squid config file to the proxy vm
Invoke-JSSudoCommand -Session $ProxySessions -Command "sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.default"
Invoke-JSSudoCommand -Session $ProxySessions -Command "sudo rm /etc/squid/squid.conf"
Get-VM *Proxy* | Copy-VMFile -SourcePath "$Env:ArcBoxDir\squid.conf" -DestinationPath "/etc/squid" -FileSource Host -Force
Get-VM *Proxy* | Copy-VMFile -SourcePath "$Env:ArcBoxDir\whitelist.txt" -DestinationPath "/etc/squid" -FileSource Host -Force

Write-Header "Onboarding Arc-enabled servers"

# Onboarding the nested VMs as Azure Arc-enabled servers
Write-Output "Onboarding the nested Windows VMs as Azure Arc-enabled servers"

Invoke-Command -VMName $Win2k25vmName -ScriptBlock { powershell -File $Using:nestedVMArcBoxDir\installArcAgent.ps1 -accessToken $using:accessToken, -spnTenantId $Using:tenantId, -subscriptionId $Using:subscriptionId, -resourceGroup $Using:resourceGroup, -azureLocation $Using:azureLocation } -Credential $winCreds

Write-Output "Onboarding the nested Linux VMs as an Azure Arc-enabled servers"
$UbuntuSessions = New-PSSession -HostName $Ubuntu01VmIp -KeyFilePath "$Env:USERPROFILE\.ssh\id_rsa" -UserName $nestedLinuxUsername
Invoke-JSSudoCommand -Session $UbuntuSessions -Command "sh /home/$nestedLinuxUsername/installArcAgentModifiedUbuntu.sh"

#WorkshopPlus: adding DCRs and extensins for 2025 and Ubuntu-1
Write-Host "Assigning Data collection rules to Arc-enabled machines"
$windowsArcMachine = (Get-AzConnectedMachine -ResourceGroupName $resourceGroup -Name $Win2k25vmName).Id
$linuxArcMachine = (Get-AzConnectedMachine -ResourceGroupName $resourceGroup -Name $Ubuntu01vmName).Id
az monitor data-collection rule association create --name "vmInsighitsWindows" --rule-id $vmInsightsDCR --resource $windowsArcMachine --only-show-errors
az monitor data-collection rule association create --name "vmInsighitsLinux" --rule-id $vmInsightsDCR --resource $LinuxArcMachine --only-show-errors
az monitor data-collection rule association create --name "changeTrackingWindows" --rule-id $changeTrackingDCR --resource $windowsArcMachine --only-show-errors
az monitor data-collection rule association create --name "changeTrackingLinux" --rule-id $changeTrackingDCR --resource $LinuxArcMachine --only-show-errors

Write-Host "Installing the AMA agent on the Arc-enabled machines"
az connectedmachine extension create --name AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor --type AzureMonitorWindowsAgent --machine-name $Win2k25vmName --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade true --no-wait
az connectedmachine extension create --name AzureMonitorLinuxAgent --publisher Microsoft.Azure.Monitor --type AzureMonitorLinuxAgent --machine-name $Ubuntu01vmName --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade true --no-wait

Write-Host "Installing the changeTracking agent on the Arc-enabled machines"
az connectedmachine extension create --name ChangeTracking-Windows --publisher Microsoft.Azure.ChangeTrackingAndInventory --type-handler-version 2.20 --type ChangeTracking-Windows --machine-name $Win2k25vmName --resource-group $resourceGroup  --location $azureLocation --enable-auto-upgrade --no-wait
#removing CT extensin from Ubuntu machine because of compatibility issues
#az connectedmachine extension create --name ChangeTracking-Linux --publisher Microsoft.Azure.ChangeTrackingAndInventory --type-handler-version 2.20 --type ChangeTracking-Linux --machine-name $Ubuntu01vmName --resource-group $resourceGroup  --location $azureLocation --enable-auto-upgrade --no-wait

Write-Host "Installing the Azure Update Manager agent on the Arc-enabled machines"
az connectedmachine assess-patches --resource-group $resourceGroup --name $Win2k25vmName --no-wait
az connectedmachine assess-patches --resource-group $resourceGroup --name $Ubuntu01vmName --no-wait
Write-Host "Installing the dependencyAgent extension on the Arc-enabled windows machine"
$dependencyAgentSetting = '{\"enableAMA\":\"true\"}'
az connectedmachine extension create --name DependencyAgent --publisher Microsoft.Azure.Monitoring.DependencyAgent --type-handler-version 9.10 --type DependencyAgentWindows --machine-name $Win2k25vmName --settings $dependencyAgentSetting --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade --no-wait

#az connectedmachine extension create --name MDE.Windows --machine-name $machine.name $Win2k25vmName --resource-group $resourceGroup --publisher "Microsoft.Azure.Security" --type "MDE.Windows" --type-handler-version "1.0" --location $azureLocation --enable-auto-upgrade --no-wait

# Removing the LogonScript Scheduled Task so it won't run on next reboot
Write-Header "Removing Logon Task"
if ($null -ne (Get-ScheduledTask -TaskName "ArcServersLogonScript" -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskName "ArcServersLogonScript" -Confirm:$false
}

#Changing to Jumpstart ArcBox wallpaper
Write-Header "Changing wallpaper"

# bmp file is required for BGInfo
Convert-JSImageToBitMap -SourceFilePath "$Env:ArcBoxDir\wallpaper.png" -DestinationFilePath "$Env:ArcBoxDir\wallpaper.bmp"

Set-JSDesktopBackground -ImagePath "$Env:ArcBoxDir\wallpaper.bmp"

Write-Header "Creating deployment logs bundle"

$RandomString = -join ((48..57) + (97..122) | Get-Random -Count 6 | % { [char]$_ })
$LogsBundleTempDirectory = "$Env:windir\TEMP\LogsBundle-$RandomString"
$null = New-Item -Path $LogsBundleTempDirectory -ItemType Directory -Force

#required to avoid "file is being used by another process" error when compressing the logs
Copy-Item -Path "$Env:ArcBoxLogsDir\*.log" -Destination $LogsBundleTempDirectory -Force -PassThru
Compress-Archive -Path "$LogsBundleTempDirectory\*.log" -DestinationPath "$Env:ArcBoxLogsDir\LogsBundle-$RandomString.zip" -PassThru

Stop-Transcript
