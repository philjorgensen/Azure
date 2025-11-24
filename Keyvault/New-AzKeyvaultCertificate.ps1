# Define variables
$AppId = "00000000-0000-0000-0000-000000000000"
$Secret = ConvertTo-SecureString "your-client-secret-here" -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($AppId, $Secret)

$keyVaultName = "keyvault-name"
$Name = "certificate-name"

# Replace with your actual tenant ID
Connect-AzAccount -ServicePrincipal -Tenant "tenant-guid" -Credential $Credential

# Certificate policy – customize as needed
$policySplat = @{
    SubjectName       = "CN=Contoso BIOS Root CA 2025, O=Contoso Corp, C=US"
    IssuerName        = "Self"
    ValidityInMonths  = 12
    SecretContentType = "application/x-pem-file"
    KeyType           = "RSA"
    KeySize           = 2048
    ReuseKeyOnRenewal = $true
    KeyUsage          = @('digitalSignature', 'dataEncipherment')
}

$certificatePolicy = New-AzKeyVaultCertificatePolicy @policySplat

Add-AzKeyVaultCertificate -VaultName $keyVaultName -Name $Name -CertificatePolicy $certificatePolicy

Write-Host "Certificate creation triggered. Waiting 10 seconds for completion..."
Start-Sleep -Seconds 10

# Retrieve the certificate from Key Vault
$cert = Get-AzKeyVaultCertificate -VaultName $keyVaultName -Name $Name

# Export only the public cert as PEM
$pemBytes = $cert.Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$pemBase64 = [Convert]::ToBase64String($pemBytes)

$pemFormatted = @"
-----BEGIN CERTIFICATE-----
$pemBase64
-----END CERTIFICATE-----
"@

# Save to temp (or copy this output manually)
$pemPath = "$env:TEMP\$certificateName.pem"
$pemFormatted | Set-Content -Path $pemPath
Write-Host "Certificate saved to: $pemPath"