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

if ($TenantID -eq $null -or $TenantID -eq "") {
    Write-Host "Tenant ID is null. Add the Azure AD Tenant Id to the TenantID variable." -ForegroundColor Red
    exit 
} else {
    # Continue with the script
}

# Import the ImportExcel module
if (-not (Get-Module -Name ImportExcel -ListAvailable)) {
    Install-Module -Name ImportExcel -Scope CurrentUser
}
Import-Module -Name ImportExcel

if (-not (Get-Module -Name Az -ListAvailable)) {
    Install-Module -Name Az -Repository PSGallery -Force
}

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
        
    if ($null -eq $tagName -or $null -eq $tagValue) {
        Write-Host "Skipping row because tagName or tagValue is null." -ForegroundColor Yellow
        continue
    }

    Write-Host "Applying tag '$tagName' with value '$tagValue' to resource group '$resourceGroupName' on the subscription '$subscriptionName'..." -ForegroundColor Green

    # Get the subscription ID and Set the context to the subscription
    $Subscription = Get-AzSubscription -SubscriptionName $SubscriptionName -TenantId $TenantID -ErrorAction SilentlyContinue
    if ($null -ne $Subscription) {
        $SubscriptionID = $Subscription.Id
        Set-AzContext -Subscription $SubscriptionID -Tenant $TenantID
    } else {
        Write-Host "Subscription Name $SubscriptionName not found. Skipping..." -ForegroundColor Yellow
        continue
    }    

    # Get the resource group
    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    
    # Check if the resource group was found
    if ($null -ne $resourceGroup) {
        # Apply the tag to the resource group
        if ($null -eq $resourceGroup.Tags) {
            $tags = @{}
        } else {
            $tags = $resourceGroup.Tags
        }
        $tags[$tagName] = $tagValue

        Set-AzResourceGroup -ResourceId $resourceGroup.ResourceId -Tag $tags
        Write-Host "Tag applied successfully." -ForegroundColor Green
    } else {
        Write-Host "Resource group $resourceGroupName not found. Skipping..." -ForegroundColor Yellow
        continue
    }
}

Write-Host "Script finished" -ForegroundColor Green

# Stop logging
Stop-Transcript