<#
.SYNOPSIS
  Syncs an on-prem Update Retriever repository to an Azure blob container using AzCopy.

.DESCRIPTION
  The script searches through the repository and modifies package XML descriptors to support silent BIOS/Firmware installation.
  It then syncs the repository to an Azure blob container using AzCopy.

.PARAMETER RepositoryPath
  The on-prem Update Retriever repository path (local drive or UNC path).

.PARAMETER BlobPath
  The Azure Blob container URL for syncing.

.EXAMPLE
  .\Sync-Repositories.ps1 -RepositoryPath "D:\Lenovo\Updates" -BlobPath "https://storageaccount.blob.core.windows.net/container/"

.NOTES
  Author: Philip Jorgensen
  Created: 2024-11-06

  This script uses an Azure Service Principal for authentication.
  The Azure Storage Account variables should be set to match your environment.
  The Az PowerShell module and AzCopy will be installed if not found on the system.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ })]
    [string]$RepositoryPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^https:\/\/.*\.blob\.core\.windows\.net\/.*")]
    [string]$BlobPath
)

#region FUNCTIONS
function Install-AzStorageModule
{
    if (-not (Get-Module -ListAvailable -Name Az.Storage))
    {
        Write-Host "Installing Az.Storage module..." -ForegroundColor Green
        Install-Module -Name Az.Storage -Force -AllowClobber -Scope AllUsers
    }
    Import-Module -Name Az.Storage -ErrorAction Stop
}

function Install-AzCopy
{
    try
    {
        # Install AzCopy from the Winget repository
        $azCopyCheck = Get-Command -Name azcopy.exe -ErrorAction SilentlyContinue
        if (-not $azCopyCheck)
        {
            Write-Host "Installing AzCopy..." -ForegroundColor Green
            Start-Process -FilePath "winget.exe" -ArgumentList "install Microsoft.Azure.AZCopy.10 --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -Wait
        }
    }
    catch
    {
        Write-Error "Failed to install or check AzCopy: $($_.Exception.Message)"
        Exit 1
    }
}
#endregion

# Call the functions
Install-AzStorageModule
Install-AzCopy

#region VARIABLES
$subscriptionId = ""
$tenantId = ""
$clientId = ""
$clientSecret = ""
$storageAccountRG = "" # Storage account resource group
$storageAccountName = "" # Storage account where blob container resides
#endregion

# Authenticate to Azure using the provided Service Principal
try
{
    $secureClientSecret = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
    $clientCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $clientId, $secureClientSecret
    $authSplat = @{
        ServicePrincipal = $true
        SubscriptionId   = $subscriptionId
        TenantId         = $tenantId
        Credential       = $clientCredential
    }
    Write-Host "Connecting to Azure..." -ForegroundColor Green
    Connect-AzAccount @authSplat
}
catch
{
    Write-Error "Authentication to Azure failed: $($_.Exception.Message)"
    Exit 1
}

# Generate SAS token
try
{
    Write-Host "Generating SAS token..." -ForegroundColor Green
    $storageContext = (Get-AzStorageAccount -ResourceGroupName $storageAccountRG -AccountName $storageAccountName).Context
    $sasTokenParamSplat = @{
        Context      = $storageContext
        Service      = "Blob, File, Table, Queue"
        ResourceType = "Service, Container, Object"
        Permission   = "racwdlup"
        ExpiryTime   = (Get-Date).AddSeconds(3600) # Valid for 1 hour (3600 seconds).
    }
    $sasToken = New-AzStorageAccountSASToken @sasTokenParamSplat
}
catch
{
    Write-Error "Failed to generate SAS token: $($_.Exception.Message)"
    Exit 1
}

# Modify XML package descriptors for silent installation and no forced reboot
$databasePath = Join-Path -Path $RepositoryPath -ChildPath "database.xml"

# Check if 'cloud="True"' exists in database.xml
if (Get-Content -Path $databasePath | Select-String -SimpleMatch 'cloud="True"')
{
    Write-Host "Repository is configured as Cloud. No XML modifications will be made." -ForegroundColor Yellow
}
else
{
    # If cloud="True" is not found, modify the XML files for silent installation
    Write-Host "Modifying package XMLs for silent installation and no forced reboot..." -ForegroundColor Cyan
    try
    {
        # Get all XML files in the repository
        $xmlFiles = Get-ChildItem -Path $RepositoryPath -Recurse -Include *.xml
        foreach ($file in $xmlFiles)
        {
            # Read the XML content
            $xmlContent = Get-Content -Path $file.FullName
            
            # Initialize $modifiedContent as the original $xmlContent at the start of the loop
            $modifiedContent = $xmlContent
            $biosUpdateFound = $false  # Flag to track if BIOS Update Utility is found
    
            # Check if the specific <Desc> tag exists and contains reboot type="5"
            if ($xmlContent -match 'BIOS Update Utility' -and ($xmlContent -match '<Reboot type="5" />'))
            {
                Write-Host "Found BIOS Update Utility tag in: $($file.FullName)" -ForegroundColor Yellow
                $biosUpdateFound = $true  # Set the flag
    
                # Modify Reboot type
                $modifiedContent = $modifiedContent -replace '<Reboot type="5" />', '<Reboot type="3" />'
            }
    
            # Separate check for firmware package and Reboot type="5"
            if ($xmlContent -match '<Reboot type="5" />')
            {
                # Only output if BIOS Update Utility was not found
                if (-not $biosUpdateFound)
                {
                    Write-Host "Found firmware package in: $($file.FullName)" -ForegroundColor Yellow
                }
    
                # Modify Reboot type="5" if BIOS Update Utility was not found or additional changes needed
                $modifiedContent = $modifiedContent -replace '<Reboot type="5" />', '<Reboot type="3" />'
            }
    
            # Convert to single strings for accurate comparison
            $originalContentStr = [string]::Join("`n", $xmlContent)
            $modifiedContentStr = [string]::Join("`n", $modifiedContent)
    
            # Write the modified content back to the XML file only if modifications were made
            if ($modifiedContentStr -ne $originalContentStr)
            {
                $modifiedContent | Set-Content $file.FullName
                Write-Host "Modified Reboot type in: $($file.FullName)" -ForegroundColor Green
            }
            else
            {
                Write-Host "No modifications needed for: $($file.FullName)" -ForegroundColor Cyan
            }
        }
    }
    catch
    {
        Write-Error -Message "Error processing XML files: $($_.Exception.Message)"
        Exit 1
    }
    
}

# Sync the repository to the blob container
try
{
    Write-Host "Syncing repositories..." -ForegroundColor Green
    Start-Process -FilePath "azcopy.exe" `
        -ArgumentList @(
        "sync", 
        $RepositoryPath, 
        "$($BlobPath)?$($sasToken)", 
        "--delete-destination=true", 
        "--log-level=INFO"
    ) `
        -NoNewWindow -Wait
}
catch
{
    Write-Error "Error during AzCopy sync: $($_.Exception.Message)"
    Exit 1
}

# Disconnect Azure Account
Write-Host "Disconnecting from Azure..." -ForegroundColor Green
Disconnect-AzAccount