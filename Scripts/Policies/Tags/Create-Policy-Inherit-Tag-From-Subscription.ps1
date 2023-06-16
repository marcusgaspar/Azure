#### Change parameters here #####
$TenantID="" 
$Location="eastus"
# xlsx file with TagName and TagValue columns 
$TagFile = "C:\_repo\Azure\Scripts\Policies\Tags\Tags-Subscriptions.xlsx"
# Log file
$LogFile = "C:\_repo\Azure\Scripts\Policies\Tags\Create-Policies.log"
# Set the path to the custom policy JSON file
$PolicyJsonPath = "C:\_repo\Azure\Scripts\Policies\Tags\Custom-Policy-Inherit-a-tag-from-the-subscription.json"
################################

$PolicyNamePrefix="Inherit Tag from"
# Name of the new Custom Policy Definition based on the Default Policy Definition ("Inherit a tag from the subscription")
$PolicyDefinitionName = "Inherit a tag from the subscription (RGs and Resources)"
$PolicyDefinitionDescription="Adds or replaces the specified tag and value from the containing subscription when any Resource Group or resource is created or updated. Existing resources can be remediated by triggering a remediation task."

$RemediationNamePrefix="remediation-task"

# Start logging
Start-Transcript -Path $LogFile
Write-Host "Script Started" -ForegroundColor Green

if (-not (Get-Module -Name ImportExcel -ListAvailable)) {
    Install-Module -Name ImportExcel -Scope CurrentUser
}

if (-not (Get-Module -Name Az -ListAvailable)) {
    Install-Module -Name Az -Scope CurrentUser
}

# Login to Azure
Connect-AzAccount -Tenant $TenantID

# Read xls file with TagName and TagValue columns and create a policy for each row in the file
# Import the Excel file
$TagData = Import-Excel -Path $TagFile

# Create new Custom Policy Definition based on the Default Policy Definition ("Inherit a tag from the subscription")
$PolicyDefinitionDisplayName = $PolicyDefinitionName
$PolicyDefinition = New-AzPolicyDefinition -Name $PolicyDefinitionName -DisplayName $PolicyDefinitionDisplayName -Description $PolicyDefinitionDescription -Policy $PolicyJsonPath -Metadata '{"category":"Tags"}'
$PolicyDefinitionId= $PolicyDefinition.ResourceId

# Loop through each row and create a policy
foreach ($row in $TagData) {
    $TagName = $row.TagName
    
    $SubscriptionName=$row.SubscriptionName
    $PolicyName="$PolicyNamePrefix-$SubscriptionName-$TagName"
    $datetimestring=Get-Date -Format "yyyyMMddHHmmss"
    $RemediationName="$RemediationNamePrefix-$datetimestring"

    #Get the subscription ID
    $SubscriptionID = (Get-AzSubscription -SubscriptionName $SubscriptionName -TenantId $TenantID).Id
    Set-AzContext -Subscription $SubscriptionID -Tenant $TenantID
    $PolicyScope="/subscriptions/$SubscriptionID"

    # Create the policy using the tag name and value
    $PolicyParamTag = @{tagName = @{value = $TagName}}
    $PolicyParamTagJson = $PolicyParamTag | ConvertTo-Json

    # Create the policy assignment
    $PolicyAssignmentId="/subscriptions/$SubscriptionID/providers/Microsoft.Authorization/policyAssignments/$PolicyName"
    $Policy = Get-AzPolicyDefinition -Id $PolicyDefinitionId
    $PolicyAssignment = New-AzPolicyAssignment -Name $PolicyName -DisplayName $PolicyName -Description $PolicyDefinitionDescription -Scope $PolicyScope -PolicyDefinition $Policy -PolicyParameter $PolicyParamTagJson -Location $Location -AssignIdentity

    $Principal = $null
    while ($true){
        # Get the Azure AD application with the specified name
        $Principal = Get-AzADServicePrincipal -ObjectId $PolicyAssignment.Identity.principalId

        # Check if the application was found
        if ($null -ne $Principal) {
            Write-Host "The $Principal application exists."
            break
        } else {
            Write-Host "The $Principal application does not exist. Waiting for 10 seconds..."
            Start-Sleep -Seconds 10
        }
    }
    
    # Create Role Assignment to Grant Contributor role to the Policy system assigned identity on the scope of subscription
    # It is required by Remediation Task to apply the Tags on the resources
    New-AzRoleAssignment -ObjectId $Principal -RoleDefinitionName Contributor -Scope $PolicyScope 
    
    # Create the remediation task
    Start-AzPolicyRemediation -Name $RemediationName -PolicyAssignmentId  $PolicyAssignmentId -ResourceDiscoveryMode ReEvaluateCompliance -Scope $PolicyScope

}   

Write-Host "Script finished" -ForegroundColor Green

# Stop logging
Stop-Transcript
