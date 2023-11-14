# Get Private link endpoints resolution URLs for Azure Arc enabled servers

$PEname="Arc-PE-demo"
$ResourceGroup="Azure-RG"

$privateDnsZoneConfigs = (az network private-endpoint dns-zone-group list --endpoint-name $PEname --resource-group $ResourceGroup -o json --query [0].privateDnsZoneConfigs) | ConvertFrom-Json | Select-Object -Property name, recordSets

foreach ($config in $privateDnsZoneConfigs) {
    $recordSets = $config.recordSets
   
    foreach ($recordSet in $recordSets) {
        $fqdn = $recordSet[0].fqdn
        $ipAddress = $recordSet[0].ipAddresses[0]

        # Print the fqdn and ipAddress
        $hostfile += "$ipAddress $fqdn`n"        
    }    
}
Write-Host $hostfile

