#### Change parameters here #####
$TenantID=""
# xlsx file with TagName and TagValue columns 
$TagFile = "C:\_repo\Azure\Scripts\Policies\Tags\Tags-RGs.xlsx"
# Log file
$LogFile = "C:\_repo\Azure\Scripts\Policies\Tags\Create-Policies.log"
################################

# Set the column names
$SubscriptionNameColumn = "SubscriptionName"
$resourceGroupNameColumn = "ResourceGroupName"
$tagNameColumn = "TagName"
$tagValueColumn = "TagValue"

# Start logging
Start-Transcript -Path $LogFile
Write-Host "Script Started" -ForegroundColor Green

# Import the ImportExcel module
if (-not (Get-Module -Name ImportExcel -ListAvailable)) {
    Install-Module -Name ImportExcel -Scope CurrentUser
}
Import-Module -Name ImportExcel

# Login to Azure
Connect-AzAccount -Tenant $TenantID -WarningAction SilentlyContinue

Write-Host "Reading Excel file..." -ForegroundColor Green
# Read xls file with TagName and TagValue columns and create a policy for each row in the file
$TagData = Import-Excel -Path $TagFile

# Loop through the data and apply the tags to the resource groups
foreach ($row in $TagData) {
    $subscriptionName=$row.$SubscriptionNameColumn
    $resourceGroupName = $row.$resourceGroupNameColumn
    $tagName = $row.$tagNameColumn
    $tagValue = $row.$tagValueColumn
    
    Write-Host "Applying tag '$tagName' with value '$tagValue' to resource group '$resourceGroupName' on the subscription '$subscriptionName'..." -ForegroundColor Green
    
    # Get the subscription ID and Set the context to the subscription
    $SubscriptionID = (Get-AzSubscription -SubscriptionName $SubscriptionName -TenantId $TenantID).Id
    Set-AzContext -Subscription $SubscriptionID -Tenant $TenantID

    # Get the resource group
    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    
    # Check if the resource group was found
    if ($null -ne $resourceGroup) {
        # Apply the tag to the resource group
        $tags = $resourceGroup.Tags
        $tags[$tagName] = $tagValue
        Set-AzResourceGroup -ResourceId $resourceGroup.ResourceId -Tag $tags
        Write-Host "Tag applied successfully." -ForegroundColor Green
    } else {
        Write-Host "Resource group not found." -ForegroundColor Red
    }
}

Write-Host "Script finished" -ForegroundColor Green

# Stop logging
Stop-Transcript