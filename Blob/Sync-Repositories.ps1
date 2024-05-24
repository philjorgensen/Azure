<#
.SYNOPSIS
  Syncs an on-prem Update Retriever repository to an Azure blob container using Azcopy.
.DESCRIPTION
  Prior to sync, the script recursively searches through the repository and parses through Bios xml's,
  which are altered to support silent Bios installation and not force the device to reboot after the update.
.PARAMETER RepositoryPath
  The on-prem Update Retriever repository path should be entered. Either a local drive or UNC path.
.EXAMPLE
  .\Sync-Repositories.ps1 -RepositoryPath "D:\Lenovo\Updates" -BlobPath "https://storageaccount.blob.core.windows.net/container/
.EXAMPLE
  .\Sync-Repositories.ps1 -RepositoryPath "\\server fqdn\share\Updates" -BlobPath "https://storageaccount.blob.core.windows.net/container/
.NOTES
Author: Philip Jorgensen
Created: 2-16-2022

  This script uses an Azure Service Principal for authentication. The Azure Service Principal variables should be
  set to match your environment's Service Principal or another method of authentication can be used if desired.

  The Azure Storage Account variables should be set to match your environment.

  The Az PowerShell module will be installed if not found on the system script is executed on.

  AzCopy will be downloaded to the TEMP directory and moved to ProgramData.

#>

param (
	[Parameter(Mandatory,
		HelpMessage = "Specify the local drive or UNC path to the Update Retriever repository...")]
	[string]$RepositoryPath,
	[Parameter(Mandatory,
		HelpMessage = "Specify the URL of the Blob Container to upload content to...")]
	[string]$BlobPath
)

# Set Azure Service Principal variables
$azureAppId = ""
$azureAppIdPasswordFilePath = ""
$azureAppCred = (New-Object System.Management.Automation.PSCredential $azureAppId, (Get-Content -Path $azureAppIdPasswordFilePath | ConvertTo-SecureString))
$subscriptionId = ""
$tenantId = ""

# Set Azure Storage Account variables
$storageAccountRG = ""
$storageAccountName = ""

########################################################################################
Clear-Host

# Check if Az module is installed
$installedModules = Get-InstalledModule
try {
	Write-Host "Checking for Az Module..." -ForegroundColor Green
	if ($null -eq $installedModules -or $installedModules.Name -notcontains "Az.Storage") {    
    	
		# Update Az Module if needed
		Write-Host "Installing Az.Storage module..." -ForegroundColor Green
		Set-PSRepository -Name PsGallery -InstallationPolicy Trusted
		Install-Module -Name Az.Storage -Repository PSGallery -Force -AllowClobber
		Import-Module -Name Az.Storage -ErrorAction Stop -Verbose:$false
	}
	else {
		Write-Host "Importing Az.Storage Module..." -ForegroundColor Green
		Import-Module -Name Az.Storage -ErrorAction Stop -Verbose:$false
	}
}
catch [System.Exception] {
	Write-Warning -Message "Error: $($_.Exception.Message)"
	Break
}

# Connect to Azure
Write-Host "Logging on to Azure..." -ForegroundColor Green
Connect-AzAccount -ServicePrincipal -SubscriptionId $subscriptionId -TenantId $tenantId -Credential $azureAppCred

# Generate SAS token
# Valid for 1 hour by default (3600 seconds). Increase for initial sync.
$storageContext = (Get-AzStorageAccount -ResourceGroupName $storageAccountRG -AccountName $storageAccountName).Context
$SasToken = New-AzStorageAccountSASToken -Context $storageContext `
	-Service Blob, File, Table, Queue `
	-ResourceType Service, Container, Object `
	-Permission racwdlup `
	-ExpiryTime(Get-Date).AddSeconds(7200)

# Alter XML package descriptors if the Update Retriever repository is not a cloud repo
if (!(Get-Content -Path (Join-Path -Path $RepositoryPath -ChildPath "database.xml") | Select-String -SimpleMatch 'cloud="True"')) {
	Write-Host "Setting BIOS package XMLs for silent installation..." -ForegroundColor Green
	Get-ChildItem -Path $RepositoryPath -Recurse -Include *.xml |
	ForEach-Object { if (Get-Content $_ | Select-String -Pattern 'BIOS Update', 'EC Update') `
		{
			(Get-Content $_ | ForEach-Object { 
				$_  -replace 'winuptp.exe -r', 'winuptp.exe -s' `
					-replace 'Reboot type="1"', 'Reboot type="3"' `
					-replace 'Reboot type="5"', 'Reboot type="3"' 
			})
			| Set-Content $_
		}
	}
}

# Download AzCopy
Write-Host "Downloading the latest version of AzCopy..." -ForegroundColor Green
Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile (Join-Path -Path $env:ProgramData -ChildPath AzCopy.zip) -UseBasicParsing
 
# Expand Archive
Expand-Archive -Path (Join-Path -Path $env:ProgramData -ChildPath AzCopy.zip) -DestinationPath (Join-Path -Path $env:ProgramData -ChildPath AzCopy) -Force -Verbose:$true
 
# Move AzCopy to ProgramData
Get-ChildItem -Path (Join-Path -Path $env:ProgramData -ChildPath "AzCopy\*\azcopy.exe") | Move-Item -Destination $env:ProgramData -Force
 
# Add azcopy to Windows environment path
[System.Environment]::SetEnvironmentVariable('PATH', $env:PATH + ';C:\ProgramData\')

azcopy.exe -v

Write-Host "Syncing repositories..." -ForegroundColor Green
azcopy.exe sync $RepositoryPath ($BlobPath + "?" + $SasToken) --delete-destination true

# Disconnect Azure Account
Write-Host "Disconnecting from Azure..." -ForegroundColor Green
Disconnect-AzAccount