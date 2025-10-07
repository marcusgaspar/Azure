<#
.SYNOPSIS
  Lê a aba "Resources and Tags" de um .xlsx e aplica tags (colunas BMDB_*) a cada recurso do Azure.

.DESCRIPTION
  - Para cada linha: identifica o recurso pelo Resource Group (coluna RG) e nome do recurso.
  - O nome do recurso é obtido, nesta ordem: ResourceName -> BMDB_ServerName -> BMDB_InstanceName.
  - Todas as colunas que começam com "BMDB_" viram tags (nome da coluna = nome da tag).
  - Por padrão, valores vazios/N/A são ignorados (não escreve a tag).
    Use -RemoveWhenBlank para REMOVER a tag quando a célula estiver vazia ou "N/A".
  - Usa Update-AzTag -Operation Merge (mescla com tags existentes).
  - Alterna de assinatura via coluna "Subscription" (nome ou GUID), quando presente.
  - Gera um sumário ao final.
  - Antes de rodar, verifique as variáveis $TenantID e $SubscriptionID 

.PARAMETER ExcelPath
  Caminho do arquivo .xlsx

.PARAMETER SheetName
  Nome da aba (default: 'Resources and Tags')

.PARAMETER Apply
  Executa de fato as alterações. Se omitido, roda em modo simulação (não chama Update-AzTag).

.PARAMETER RemoveWhenBlank
  Quando informado, se a célula da tag estiver vazia/N/A, remove a tag do recurso (Operation Delete na chave específica).

.PARAMETER VerboseLog
  Mostra detalhes de logging (ex.: ResourceId/ResourceType encontrados).

.EXAMPLE
  # Simulação (não altera nada; mostra o que faria):
  .\Apply-Tag-to-Resource.ps1 -ExcelPath .\Tags_Resources.xlsx

.EXAMPLE
  # Aplicar de verdade:
  .\Apply-Tag-to-Resource.ps1 -ExcelPath .\Tags_Resources.xlsx -Apply

.EXAMPLE
  # Aplicar e remover tags quando a célula estiver vazia:
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

# Configurar aqui o Tenant ID e Subscription ID
$TenantID=""
$SubscriptionID=""

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Module {
  param([Parameter(Mandatory=$true)][string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    Write-Host "Instalando módulo '$Name' (escopo usuário)..." -ForegroundColor Yellow
    Install-Module -Name $Name -Scope CurrentUser -Force -Repository PSGallery
  }
  Import-Module $Name -ErrorAction Stop | Out-Null
}

function Get-CellString {
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  $s = [string]$Value
  # Normalizar quebras de linha e espaços
  $s = $s -replace '\r?\n',' '
  $s = $s.Trim()

  # Se valor vier como link do Excel exportado p/ markdown (ex.: [user@vale.com](mailto:user@vale.com))
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

# Checagens iniciais
if (-not (Test-Path -Path $ExcelPath -PathType Leaf)) {
  throw "Arquivo não encontrado: $ExcelPath"
}

# Módulos necessários (compatíveis com PS7)
Ensure-Module Az.Accounts
Ensure-Module Az.Resources
Ensure-Module ImportExcel

## Autenticação (se necessário)
#try {
#  if (-not (Get-AzContext)) {
#    Connect-AzAccount -ErrorAction Stop | Out-Null
#  }
#} catch {
#  Connect-AzAccount -ErrorAction Stop | Out-Null
#}

Connect-AzAccount -Tenant $TenantID -Subscription $SubscriptionID -ErrorAction Stop

# Ler planilha
Write-Host "Lendo '$ExcelPath', aba '$SheetName'..." -ForegroundColor Cyan
$rows = Import-Excel -Path $ExcelPath -WorksheetName $SheetName -ErrorAction Stop

if (-not $rows -or $rows.Count -eq 0) {
  throw "A aba '$SheetName' não contém linhas."
}

# Descobrir colunas de tags (BMDB_*)
# Usando as propriedades do primeiro objeto
$first = $rows | Select-Object -First 1
$bmdbColumns = $first.PSObject.Properties.Name | Where-Object { $_ -like 'BMDB_*' } | Sort-Object

if (-not $bmdbColumns -or $bmdbColumns.Count -eq 0) {
  throw "Não foram encontradas colunas iniciando com 'BMDB_' na aba '$SheetName'."
}

$whatIf = -not $Apply
if ($whatIf) { Write-Host "Executando em modo de SIMULAÇÃO. Use -Apply para efetivar." -ForegroundColor Yellow }

# Resultados
$results = [System.Collections.Generic.List[object]]::new()
$lineNumber = 1

foreach ($row in $rows) {
  $lineNumber++

  # Extrair ResourceGroup e Subscription
  $rg           = Get-CellString $row.PSObject.Properties['RG'].Value
  $subscription = $null
  if ($row.PSObject.Properties['Subscription']) {
    $subscription = Get-CellString $row.PSObject.Properties['Subscription'].Value
  }

  # Resolver nome do recurso
  $resourceName = $null
  foreach ($candidate in @('ResourceName','BMDB_ServerName','BMDB_InstanceName')) {
    if ($row.PSObject.Properties[$candidate]) {
      $resourceName = Get-CellString $row.PSObject.Properties[$candidate].Value
    }
    if ($resourceName) { break }
  }

  if ([string]::IsNullOrWhiteSpace($rg) -or [string]::IsNullOrWhiteSpace($resourceName)) {
    $msg = "Linha $lineNumber : RG ou Nome do recurso ausente. RG='$rg' Recurso='$resourceName'. Linha ignorada."
    Write-Warning $msg
    $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='Skipped'; Detail='Missing RG/ResourceName' })
    continue
  }

  # Contexto de assinatura (quando fornecida)
  if ($subscription) {
    try {
      Set-AzContext -Subscription $subscription -ErrorAction Stop | Out-Null
    } catch {
      Write-Warning "Linha $lineNumber : Não foi possível selecionar a assinatura '$subscription'. Erro: $($_.Exception.Message)"
      $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='Failed'; Detail='Invalid subscription' })
      continue
    }
  }

  # Localizar o recurso
  $res = $null
  try {
    $matchSet = Get-AzResource -ResourceGroupName $rg -Name $resourceName -ErrorAction SilentlyContinue
    if (-not $matchSet) {
      # Tentativa com wildcard (pode haver sufixo)
      $matchSet = Get-AzResource -ResourceGroupName $rg -Name "$resourceName*" -ErrorAction SilentlyContinue
    }
  } catch {
    $matchSet = $null
  }

  if (-not $matchSet) {
    Write-Warning "Linha $lineNumber : Recurso '$resourceName' não encontrado no RG '$rg'."
    $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='NotFound'; Detail='Resource not found' })
    continue
  }

  if (@($matchSet).Count -gt 1) {
    # Tentar match exato (case-insensitive)
    $exact = $matchSet | Where-Object { $_.Name -ieq $resourceName }
    if ($exact.Count -eq 1) {
      $res = $exact
    } else {
      $names = ($matchSet | Select-Object -ExpandProperty Name) -join ', '
      Write-Warning "Linha $lineNumber : Vários recursos encontrados para '$resourceName' no RG '$rg': $names"
      $results.Add([pscustomobject]@{ Line=$lineNumber; ResourceGroup=$rg; ResourceName=$resourceName; Subscription=$subscription; Status='Ambiguous'; Detail=$names })
      continue
    }
  } else {
    $res = $matchSet
  }

  if ($VerboseLog) {
    Write-Host "[$lineNumber] Recurso: $($res.ResourceType) Name='$($res.Name)' RG='$rg' ID=$($res.ResourceId)" -ForegroundColor DarkGray
  }

  # Montar dicionário de tags a aplicar/remover
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
    # Azure tag keys/values: normalização leve (trim já aplicado no Get-CellString)
    $toAddOrUpdate[$col] = $val
  }

  # Executar ou simular
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
          Write-Host "WhatIf [$lineNumber]: DELETE tag '$k' em '$($res.Name)'" -ForegroundColor Yellow
        } else {
          # Remove apenas a chave específica
          Update-AzTag -ResourceId $res.ResourceId -Tag @{$k=$null} -Operation Delete -ErrorAction Stop | Out-Null
        }
      }
      $ops += "Deleted: " + ($toDelete -join ', ')
    }

    $detail = if (@($ops).Count -gt 0) { $ops -join ' | ' } else { 'No-op (sem mudanças)' }
    $results.Add([pscustomobject]@{
      Line=$lineNumber; ResourceGroup=$rg; ResourceName=$res.Name; Subscription=$subscription;
      Status= ($whatIf ? 'WhatIf' : 'Success'); Detail=$detail
    })

  } catch {
    Write-Warning "Linha $lineNumber : Falha ao atualizar tags no recurso '$($res.Name)'. Erro: $($_.Exception.Message)"
    $results.Add([pscustomobject]@{
      Line=$lineNumber; ResourceGroup=$rg; ResourceName=$res.Name; Subscription=$subscription;
      Status='Failed'; Detail=$_.Exception.Message
    })
  }
}

# Sumário
Write-Host ""
Write-Host "===== SUMÁRIO =====" -ForegroundColor Cyan
$results | Group-Object Status | ForEach-Object {
  "{0}: {1}" -f $_.Name, $_.Count
} | Write-Host

Write-Host ""
$results | Sort-Object Line | Format-Table -AutoSize