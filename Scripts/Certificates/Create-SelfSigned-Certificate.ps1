# Source: https://docs.microsoft.com/en-us/azure/application-gateway/create-ssl-portal
# Use New-SelfSignedCertificate to create a self-signed certificate. 
# You upload the certificate to the Azure portal when you create the listener for the application gateway.

# Variables
$dnsName = "www.contoso.com"
$pfxFilePath = "c:\Temp\AppGtwCert.pfx"
#  Make sure your password is 4 - 12 characters long
$pwd = "<password>"

# Create SelfSigned Certificate
New-SelfSignedCertificate `
  -certstorelocation cert:\localmachine\my `
  -dnsname $dnsName

# Save the Thumbprint
$thumbPrint = Get-ChildItem -Path Cert:\LocalMachine\My | 
Where-Object {$_.Subject -match $dnsName} | 
Select-Object -ExpandProperty Thumbprint

$pwd = ConvertTo-SecureString -String $pwd -Force -AsPlainText

# Export Certificate
Export-PfxCertificate `
  -cert cert:\localMachine\my\$thumbPrint `
  -FilePath $pfxFilePath `
  -Password $pwd

