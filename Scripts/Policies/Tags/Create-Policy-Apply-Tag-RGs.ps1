#### Change parameters here #####
$SubscriptionID=""
$TenantID=""
$Location="eastus"
# xlsx file with TagName and TagValue columns 
$TagFile = "C:\_repo\Azure\Scripts\Policies\Tags\Tags-RGs.xlsx"
# Log file
$LogFile = "C:\_repo\Azure\Scripts\Policies\Tags\Create-Policies.log"
################################

$PolicyNamePrefix="TagRG"
$PolicyDescription="Adds or replaces the specified tag and value when any resource group is created or updated. Existing resource groups can be remediated by triggering a remediation task."
$PolicyDefinitionId="d157c373-a6c4-483d-aaad-570756956268"

$RemediationNamePrefix="remediation-task"

# Start logging
Start-Transcript -Path $LogFile
Write-Host "Script Started" -ForegroundColor Green

if (-not (Get-Module -Name ImportExcel -ListAvailable)) {
    Install-Module -Name ImportExcel -Scope CurrentUser
}

# Login to Azure
Connect-AzAccount -Tenant $TenantID -Subscription $SubscriptionID

Write-Host "Reading Excel file..." -ForegroundColor Green
# Read xls file with TagName and TagValue columns and create a policy for each row in the file
# Import the Excel file
$TagData = Import-Excel -Path $TagFile

# Loop through each row and create a policy
foreach ($row in $TagData) {
    $TagName = $row.TagName
    $TagValue = $row.TagValue
    $SubscriptionName=$row.SubscriptionName
    $RGName=$row.ResourceGroupName
    $SubscriptionNameShort=$SubscriptionName.Substring(0,4)
    $PolicyName="$PolicyNamePrefix-$SubscriptionNameShort-$RGName-$TagName"
    $datetimestring=Get-Date -Format "yyyyMMddHHmmss"
    $RemediationName="$RemediationNamePrefix-$datetimestring"

    # Get the subscription ID
    $SubscriptionID = (Get-AzSubscription -SubscriptionName $SubscriptionName).Id
    
    # Get the RG resource ID
    $RGReourceId = (Get-AzResourceGroup -Name $RGName).ResourceId

    # Create the policy using the tag name and value
    $PolicyParamTag = @{tagName = @{value = $TagName}; tagValue = @{value = $TagValue}}
    $PolicyParamTagJson = $PolicyParamTag | ConvertTo-Json

    Write-Host "Creating new PolicyAssignment..." -ForegroundColor Green
    # Create the policy assignment    
    $PolicyScope=$RGReourceId
    $Policy = Get-AzPolicyDefinition -Name $PolicyDefinitionId
        
    $PolicyAssignment = New-AzPolicyAssignment -Name $PolicyName -DisplayName $PolicyName -Description $PolicyDescription -Scope $PolicyScope -PolicyDefinition $Policy -PolicyParameter $PolicyParamTagJson -Location $Location -AssignIdentity
    $PolicyAssignmentId = $PolicyAssignment.PolicyAssignmentId

    $Principal = $null
    while ($true){
        # Get the Azure AD application with the specified name
        $PrincipalID=$PolicyAssignment.Identity.principalId
        Write-Host "Checking if Service Principal was already created..." -ForegroundColor Green
        $Principal = Get-AzADServicePrincipal -ObjectId $PrincipalID
                
        # Check if the application was found
        if ($null -ne $Principal) {
            $PrincipalID=$Principal.Id
            Write-Host "The $PrincipalID service principal exists."

            Write-Host "Creating new RoleAssignment..." -ForegroundColor Green            
            try {
                # Create Role Assignment to Grant Contributor role to the Policy system assigned identity on the scope of subscription
                # It is required by Remediation Task to apply the Tags on the resources
                New-AzRoleAssignment -ErrorAction Stop -ObjectId $PrincipalID -RoleDefinitionName Contributor -Scope $PolicyScope 
                break
            }
            catch {
                Write-Host "Error creating role assignment: $_" -ForegroundColor Red
                Write-Host "Retrying in 10 seconds..."
                Start-Sleep -Seconds 10
            }            
        } else {
            Write-Host "The service principal $PrincipalID does not exist. Waiting for 10 seconds..."
            Start-Sleep -Seconds 10
        }
    }
   
    Write-Host "Creating new Policy Remediation Task..." -ForegroundColor Green
    # Create the remediation task
    Start-AzPolicyRemediation -Name $RemediationName -PolicyAssignmentId $PolicyAssignmentId -ResourceDiscoveryMode ReEvaluateCompliance -Scope $PolicyScope

}   

Write-Host "Script finished" -ForegroundColor Green

# Stop logging
Stop-Transcript