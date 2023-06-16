Get-AzPolicyRemediation | Where-Object {$_.ProvisioningState -ne "Succeeded"} 

Get-AzPolicyRemediation | Where-Object {$_.ProvisioningState -eq "Evaluating"} | Stop-AzPolicyRemediation

Get-Module -Name Az -ListAvailable
Get-Module -Name Az.Resources -All

Get-InstalledModule -Name Az -AllVersions
Get-InstalledModule -Name Az 
Get-InstalledModule Azure -AllVersions


Update-Module -Name Az -Force


Install-Module -Name Az -Scope CurrentUser
Install-Module -Name Az 

Uninstall-Module -Name Az -AllVersions
Uninstall-Module -Name Az.Resources -AllVersions

Get-Module -Name Az -ListAvailable -OutVariable AzVersions
($AzVersions |
  ForEach-Object {
    Import-Clixml -Path (Join-Path -Path $_.ModuleBase -ChildPath PSGetModuleInfo.xml)
  }).Dependencies.Name | Sort-Object -Descending -Unique -OutVariable AzModules


