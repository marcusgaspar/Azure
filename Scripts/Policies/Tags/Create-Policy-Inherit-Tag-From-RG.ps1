#### Change parameters here #####
$TenantID=""
$Location="eastus"
# xlsx file with SubscriptionName and TagName 
$TagFileSubs = "C:\_repo\Azure\Scripts\Policies\Tags\Tags-Subscriptions.xlsx"
# xlsx file with ManagementGroupName and TagName 
$TagFileMG = "C:\_repo\Azure\Scripts\Policies\Tags\Tags-MGs.xlsx"
# Log file
$LogFile = "C:\_repo\Azure\Scripts\Policies\Tags\Create-Policies.log"
# Apply to Management Groups (MG) or Subscriptions (S)
$ScopeType = "MG"

# Set the column names
$SubscriptionNameColumn = "SubscriptionName"
$MGIdColumn = "ManagementGroupId"
$tagNameColumn = "TagName"
################################

$PolicyNamePrefix="InheritTagRG"
$PolicyDefinitionDescription="Adds or replaces the specified tag and value from the parent resource group when any resource is created or updated. Existing resources can be remediated by triggering a remediation task."
$PolicyDefinitionId="cd3aa116-8754-49c9-a813-ad46512ece54"

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
Connect-AzAccount -Tenant $TenantID -WarningAction SilentlyContinue

Write-Host "Reading Excel file..." -ForegroundColor Green
# Read xls file with TagName and TagValue columns and create a policy for each row in the file
# Import the Excel file
if ($ScopeType -eq "MG") {
    Write-Host "Reading Management Groups Excel file..." -ForegroundColor Green
    $TagData = Import-Excel -Path $TagFileMG
} elseif ($ScopeType -eq "S") {
    Write-Host "Reading Subscription Excel file..." -ForegroundColor Green
    $TagData = Import-Excel -Path $TagFileSubs
} else {
    Write-Host "Invalid ScopeType parameter. Valid values are MG or S" -ForegroundColor Red
    exit
}

# Loop through each row and create a policy
foreach ($row in $TagData) {
    $TagName = $row.$tagNameColumn    
            
    $datetimestring=Get-Date -Format "yyyyMMddHHmmss"
    $RemediationName="$RemediationNamePrefix-$datetimestring"

    if ($ScopeType -eq "MG") {
        # Get the management group ID
        $MGId=$row.$MGIdColumn
        Write-Host "Getting Management Group ID of $MGId ..." -ForegroundColor Green        
        $ManagementGroup = Get-AzManagementGroup -GroupName $MGId -ErrorAction SilentlyContinue
        if ($null -eq $ManagementGroup) {
            Write-Host "Management Group $MGId does not exist. Skipping..." -ForegroundColor Yellow
            continue
        }
        $ManagementGroupID = $ManagementGroup.Id
        # Policy name is limited to 24 characters in MG scope. 
        # Policy name is internal use only. The Portal uses the DisplayName 
        # https://github.com/Azure/azure-powershell/issues/9464
        $PolicyName="InheritTag$datetimestring"
        $PolicyDisplayName="$PolicyNamePrefix-$MGId-$TagName"
        $PolicyScope=$ManagementGroupID
        $ResourceDiscoveryMode="ExistingNonCompliant"
    } elseif ($ScopeType -eq "S") {
        #Get the subscription ID
        $SubscriptionName=$row.$SubscriptionNameColumn
        Write-Host "Getting Subscription ID of $SubscriptionName ..." -ForegroundColor Green
        $Subscription = Get-AzSubscription -SubscriptionName $SubscriptionName -TenantId $TenantID -ErrorAction SilentlyContinue
        if ($null -eq $Subscription) {
            Write-Host "Subscription $Subscription does not exist. Skipping..." -ForegroundColor Yellow
            continue
        }
        $SubscriptionID = $Subscription.Id
        # Policy name is limited to 64 characters in Subscription scope. 
        # Policy name is internal use only. The Portal uses the DisplayName 
        # https://github.com/Azure/azure-powershell/issues/9464
        $PolicyName="InheritTag$datetimestring"        
        $PolicyDisplayName="$PolicyNamePrefix-$SubscriptionName-$TagName"
        $PolicyScope="/subscriptions/$SubscriptionID"
        $ResourceDiscoveryMode="ReEvaluateCompliance"
    } else {
        Write-Host "Invalid ScopeType parameter. Valid values are MG or S" -ForegroundColor Red
        exit
    } 

    # Create the policy using the tag name and value
    $PolicyParamTag = @{tagName = @{value = $TagName}}
    $PolicyParamTagJson = $PolicyParamTag | ConvertTo-Json
    
    Write-Host "Checking PolicyAssignment $PolicyDisplayName already exists ..." -ForegroundColor Green
    $PolicyAssignment = Get-AzPolicyAssignment -Scope $PolicyScope | Where-Object {$_.Properties.DisplayName -eq $PolicyDisplayName}

    if ($null -ne $PolicyAssignment) {
        Write-Host "PolicyAssignment $PolicyName already exists. Skipping..." -ForegroundColor Yellow
        continue
    } else {
        Write-Host "Creating new PolicyAssignment..." -ForegroundColor Green
        # Create the policy assignment
        $Policy = Get-AzPolicyDefinition -Name $PolicyDefinitionId
            
        $PolicyAssignment = New-AzPolicyAssignment -Name $PolicyName -DisplayName $PolicyDisplayName -Description $PolicyDefinitionDescription -Scope $PolicyScope -PolicyDefinition $Policy -PolicyParameter $PolicyParamTagJson -Location $Location -AssignIdentity
        if ($null -eq $PolicyAssignment) {
            Write-Host "Error on creating PolicyAssignment $PolicyName. Skipping..." -ForegroundColor Red
            continue
        } else {
            $PolicyAssignmentId = $PolicyAssignment.PolicyAssignmentId
        }        
    }

    $Principal = $null
    while ($true){
        # Get the Azure AD application with the specified name
        $PrincipalID=$PolicyAssignment.Identity.principalId
        Write-Host "Checking if Service Principal was already created..." -ForegroundColor Green
        $Principal = Get-AzADServicePrincipal -ObjectId $PrincipalID -ErrorAction SilentlyContinue

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
    Start-AzPolicyRemediation -Name $RemediationName -PolicyAssignmentId  $PolicyAssignmentId -ResourceDiscoveryMode $ResourceDiscoveryMode -Scope $PolicyScope

}   

Write-Host "Script finished" -ForegroundColor Green

# Stop logging
Stop-Transcript
