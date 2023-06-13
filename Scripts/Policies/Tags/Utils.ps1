Get-AzPolicyRemediation | Where-Object {$_.ProvisioningState -ne "Succeeded"} 

Get-AzPolicyRemediation | Where-Object {$_.ProvisioningState -eq "Evaluating"} | Stop-AzPolicyRemediation