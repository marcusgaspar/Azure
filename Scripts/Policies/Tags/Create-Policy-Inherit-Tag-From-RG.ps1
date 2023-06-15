#### Change parameters here #####
$SubscriptionID="50e6fbdc-6729-4bbc-9cdb-7fc8b7b32311"
$TenantID="16b3c013-d300-468d-ac64-7eda0820b6d3"
$Location="eastus"
# xlsx file with TagName and TagValue columns 
$TagFile = "C:\_repo\Azure\Scripts\Policies\Tags\Tags-Subscriptions.xlsx"
# Log file
$LogFile = "C:\_repo\Azure\Scripts\Policies\Tags\Create-Policies.log"
################################

$PolicyNamePrefix="InheritTagRG"
$PolicyDefinitionDescription="Adds or replaces the specified tag and value from the parent resource group when any resource is created or updated. Existing resources can be remediated by triggering a remediation task."
$PolicyScope="/subscriptions/$SubscriptionID"
$PolicyDefinitionId="cd3aa116-8754-49c9-a813-ad46512ece54"

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
    
    $SubscriptionName=$row.SubscriptionName
    $PolicyName="$PolicyNamePrefix-$SubscriptionName-$TagName"
    $datetimestring=Get-Date -Format "yyyyMMddHHmmss"
    $RemediationName="$RemediationNamePrefix-$datetimestring"

    #Get the subscription ID
    $SubscriptionID = (Get-AzSubscription -SubscriptionName $SubscriptionName).Id
    
    # Create the policy using the tag name and value
    $PolicyParamTag = @{tagName = @{value = $TagName}}
    $PolicyParamTagJson = $PolicyParamTag | ConvertTo-Json
    
    Write-Host "Creating new PolicyAssignment..." -ForegroundColor Green
    # Create the policy assignment
    $Policy = Get-AzPolicyDefinition -Name $PolicyDefinitionId
    
    $PolicyAssignment = New-AzPolicyAssignment -Name $PolicyName -DisplayName $PolicyName -Description $PolicyDefinitionDescription -Scope $PolicyScope -PolicyDefinition $Policy -PolicyParameter $PolicyParamTagJson -Location $Location -AssignIdentity
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
    Start-AzPolicyRemediation -Name $RemediationName -PolicyAssignmentId  $PolicyAssignmentId -ResourceDiscoveryMode ReEvaluateCompliance -Scope $PolicyScope

}   

Write-Host "Script finished" -ForegroundColor Green

# Stop logging
Stop-Transcript
