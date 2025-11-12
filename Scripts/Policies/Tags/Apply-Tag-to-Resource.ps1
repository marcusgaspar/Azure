<#
.SYNOPSIS
  Reads the "Resources and Tags" tab from an .xlsx file and applies tags (BMDB_* columns) to each Azure resource.

.DESCRIPTION
  - For each row: identifies the resource by Resource Group (RG column) and resource name.
  - If ResourceID column is present and populated, uses it for exact resource identification (recommended for resources with duplicate names).
  - Otherwise, falls back to name-based lookup: ResourceName -> BMDB_ServerName -> BMDB_InstanceName.
  - All columns starting with "BMDB_" become tags (column name = tag name).
  - By default, empty/N/A values are ignored (doesn't write the tag).
    Use -RemoveWhenBlank to REMOVE the tag when the cell is empty or "N/A".
  - Uses Update-AzTag -Operation Merge (merges with existing tags).
  - Switches subscription via "Subscription" column (name or GUID), when present.
  - Generates a summary at the end.
  - Before running, check the $TenantID and $SubscriptionID variables

.PARAMETER ExcelPath
  Path to the .xlsx file

.PARAMETER SheetName
  Tab name (default: 'Resources and Tags')

.PARAMETER Apply
  Actually executes the changes. If omitted, runs in simulation mode (doesn't call Update-AzTag).

.PARAMETER RemoveWhenBlank
  When specified, if the tag cell is empty/N/A, removes the tag from the resource (Operation Delete on the specific key).

.PARAMETER VerboseLog
  Shows logging details (e.g.: ResourceId/ResourceType found).

.EXAMPLE
  # Simulation (doesn't change anything; shows what it would do):
  .\Apply-Tag-to-Resource.ps1 -ExcelPath .\Tags_Resources.xlsx

.EXAMPLE
  # Actually apply:
  .\Apply-Tag-to-Resource.ps1 -ExcelPath .\Tags_Resources.xlsx -Apply

.EXAMPLE
  # Apply and remove tags when cell is empty:
  .\Apply-Tag-to-Resource.ps1 -ExcelPath .\Tags_Resources.xlsx -Apply -RemoveWhenBlank
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$ExcelPath,

  [string]$SheetName = 'Resources and Tags',

  [switch]$Apply,
  [switch]$RemoveWhenBlank,
  [switch]$VerboseLog
)

# Configure the Tenant ID and Subscription ID here
$TenantID=""
$SubscriptionID="" 

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Module {
  param([Parameter(Mandatory=$true)][string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    Write-Host "Installing module '$Name' (current user scope)..." -ForegroundColor Yellow
    Install-Module -Name $Name -Scope CurrentUser -Force -Repository PSGallery
  }
  Import-Module $Name -ErrorAction Stop | Out-Null
}

function Get-CellString {
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  $s = [string]$Value
  # Normalize line breaks and spaces
  $s = $s -replace '\r?\n',' '
  $s = $s.Trim()

  # If value comes as Excel exported link to markdown (e.g.: [user@vale.com](mailto:user@vale.com))
  if ($s -match '^\[(?<txt>[^\]]+)\]\(mailto:[^\)]+\)$') {
    return $Matches['txt']
  }
  return $s
}

function Is-BlankOrNA {
  param([string]$s)
  if ([string]::IsNullOrWhiteSpace($s)) { return $true }
  return @('N/A','N/a','n/a','NA','#N/A') -contains $s
}

# Initial checks
if (-not (Test-Path -Path $ExcelPath -PathType Leaf)) {
  throw "File not found: $ExcelPath"
}

# Required modules (compatible with PS7)
Ensure-Module Az.Accounts
Ensure-Module Az.Resources
Ensure-Module ImportExcel

## Authentication (if needed)
#try {
#  if (-not (Get-AzContext)) {
#    Connect-AzAccount -ErrorAction Stop | Out-Null
#  }
#} catch {
#  Connect-AzAccount -ErrorAction Stop | Out-Null
#}

Connect-AzAccount -Tenant $TenantID -Subscription $SubscriptionID -ErrorAction Stop

# Read spreadsheet
Write-Host "Reading '$ExcelPath', tab '$SheetName'..." -ForegroundColor Cyan
$rows = Import-Excel -Path $ExcelPath -WorksheetName $SheetName -ErrorAction Stop

if (-not $rows -or $rows.Count -eq 0) {
  throw "The tab '$SheetName' contains no rows."
}

# Discover tag columns (BMDB_*)
# Using properties from the first object
$first = $rows | Select-Object -First 1
$bmdbColumns = $first.PSObject.Properties.Name | Where-Object { $_ -like 'BMDB_*' } | Sort-Object

if (-not $bmdbColumns -or $bmdbColumns.Count -eq 0) {
  throw "No columns starting with 'BMDB_' were found in tab '$SheetName'."
}

$whatIf = -not $Apply
if ($whatIf) { Write-Host "Running in SIMULATION mode. Use -Apply to make changes." -ForegroundColor Yellow }

# Results
$results = [System.Collections.Generic.List[object]]::new()
$lineNumber = 1

foreach ($row in $rows) {
  $lineNumber++

  # Extract ResourceGroup, Subscription, and ResourceID
  $rg           = Get-CellString $row.PSObject.Properties['RG'].Value
  $subscription = $null
  if ($row.PSObject.Properties['Subscription']) {
    $subscription = Get-CellString $row.PSObject.Properties['Subscription'].Value
  }
  
  $resourceId = $null
  if ($row.PSObject.Properties['ResourceID']) {
    $resourceId = Get-CellString $row.PSObject.Properties['ResourceID'].Value
  }

  # Resolve resource name
  $resourceName = $null
  foreach ($candidate in @('ResourceName','BMDB_ServerName','BMDB_InstanceName')) {
    if ($row.PSObject.Properties[$candidate]) {
      $resourceName = Get-CellString $row.PSObject.Properties[$candidate].Value
    }
    if ($resourceName) { break }
  }

  if ([string]::IsNullOrWhiteSpace($rg) -or [string]::IsNullOrWhiteSpace($resourceName)) {
    $msg = "Line $lineNumber : RG or Resource name missing. RG='$rg' Resource='$resourceName'. Line skipped."
    Write-Warning $msg
    $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='Skipped'; Detail='Missing RG/ResourceName' })
    continue
  }

  # Subscription context (when provided)
  if ($subscription) {
    try {
      Set-AzContext -Subscription $subscription -ErrorAction Stop | Out-Null
    } catch {
      Write-Warning "Line $lineNumber : Could not select subscription '$subscription'. Error: $($_.Exception.Message)"
      $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='Failed'; Detail='Invalid subscription' })
      continue
    }
  }

  # Locate the resource
  $res = $null
  
  # If ResourceID is provided, use it directly for exact identification
  if (-not [string]::IsNullOrWhiteSpace($resourceId)) {
    try {
      $res = Get-AzResource -ResourceId $resourceId -ErrorAction SilentlyContinue
      if (-not $res) {
        Write-Warning "Line $lineNumber : Resource with ID '$resourceId' not found."
        $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='NotFound'; Detail='ResourceID not found' })
        continue
      }
      if ($VerboseLog) {
        Write-Host "[$lineNumber] Found resource by ResourceID: '$resourceId'" -ForegroundColor DarkGreen
      }
    } catch {
      Write-Warning "Line $lineNumber : Error accessing resource with ID '$resourceId'. Error: $($_.Exception.Message)"
      $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='Failed'; Detail='Error accessing ResourceID' })
      continue
    }
  } else {
    # Fall back to name-based lookup if no ResourceID is provided
    try {
      $matchSet = Get-AzResource -ResourceGroupName $rg -Name $resourceName -ErrorAction SilentlyContinue
      if (-not $matchSet) {
        # Attempt with wildcard (there may be a suffix)
        $matchSet = Get-AzResource -ResourceGroupName $rg -Name "$resourceName*" -ErrorAction SilentlyContinue
      }
    } catch {
      $matchSet = $null
    }

    if (-not $matchSet) {
      Write-Warning "Line $lineNumber : Resource '$resourceName' not found in RG '$rg'."
      $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='NotFound'; Detail='Resource not found' })
      continue
    }

    if (@($matchSet).Count -gt 1) {
      # Try exact match (case-insensitive)
      $exact = $matchSet | Where-Object { $_.Name -ieq $resourceName }
      if ($exact.Count -eq 1) {
        $res = $exact
      } else {
        $names = ($matchSet | Select-Object -ExpandProperty Name) -join ', '
        $resourceIds = ($matchSet | Select-Object -ExpandProperty ResourceId) -join ', '
        Write-Warning "Line $lineNumber : Multiple resources found for '$resourceName' in RG '$rg': $names"
        Write-Warning "Consider adding ResourceID column to uniquely identify resources. ResourceIDs: $resourceIds"
        $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='Ambiguous'; Detail="Multiple matches: $names" })
        continue
      }
    } else {
      $res = $matchSet
    }
  }

  if ($VerboseLog) {
    Write-Host "[$lineNumber] Resource: $($res.ResourceType) Name='$($res.Name)' RG='$rg' ID=$($res.ResourceId)" -ForegroundColor DarkGray
  }

  # Build dictionary of tags to apply/remove
  $toAddOrUpdate = @{}
  $toDelete = @()

  foreach ($col in $bmdbColumns) {
    $prop = $row.PSObject.Properties[$col]
    if (-not $prop) { continue }
    $val = Get-CellString $prop.Value
    if (Is-BlankOrNA $val) {
      if ($RemoveWhenBlank) { $toDelete += $col }
      continue
    }
    # Azure tag keys/values: light normalization (trim already applied in Get-CellString)
    $toAddOrUpdate[$col] = $val
  }

  # Execute or simulate
  try {
    $ops = @()

    if (@($toAddOrUpdate).Count -gt 0) {
      if ($whatIf) {
        Write-Host "WhatIf [$lineNumber]: MERGE tags { $($toAddOrUpdate.Keys -join ', ') } em '$($res.Name)'" -ForegroundColor Yellow
      } else {
        Update-AzTag -ResourceId $res.ResourceId -Tag $toAddOrUpdate -Operation Merge -ErrorAction Stop | Out-Null
      }
      $ops += "Merged: " + ($toAddOrUpdate.Keys -join ', ')
    }

    if (@($toDelete).Count -gt 0) {
      foreach ($k in $toDelete) {
        if ($whatIf) {
          Write-Host "WhatIf [$lineNumber]: DELETE tag '$k' on '$($res.Name)'" -ForegroundColor Yellow
        } else {
          # Remove only the specific key
          Update-AzTag -ResourceId $res.ResourceId -Tag @{$k=$null} -Operation Delete -ErrorAction Stop | Out-Null
        }
      }
      $ops += "Deleted: " + ($toDelete -join ', ')
    }

    $detail = if (@($ops).Count -gt 0) { $ops -join ' | ' } else { 'No-op (no changes)' }
    $results.Add([pscustomobject]@{
      Line=$lineNumber; ResourceGroup=$rg; ResourceName=$res.Name; Subscription=$subscription;
      Status= ($whatIf ? 'WhatIf' : 'Success'); Detail=$detail
    })

  } catch {
    Write-Warning "Line $lineNumber : Failed to update tags on resource '$($res.Name)'. Error: $($_.Exception.Message)"
    $results.Add([pscustomobject]@{
      Line=$lineNumber; ResourceGroup=$rg; ResourceName=$res.Name; Subscription=$subscription;
      Status='Failed'; Detail=$_.Exception.Message
    })
  }
}

# Summary
Write-Host ""
Write-Host "===== SUMMARY =====" -ForegroundColor Cyan
$results | Group-Object Status | ForEach-Object {
  "{0}: {1}" -f $_.Name, $_.Count
} | Write-Host

Write-Host ""
$results | Sort-Object Line | Format-Table -AutoSize