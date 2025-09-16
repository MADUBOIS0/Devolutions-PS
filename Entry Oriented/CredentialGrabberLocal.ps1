param(
  [string]$AccountName = $env:USERNAME,
  [string]$AccountDomain = $env:USERDOMAIN,
  [string]$TargetUsername
)

$ErrorActionPreference = "Stop"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$Result = @{
  Username    = $null
  Password    = $null
  Domain      = $null
  Cancel      = $false
  ErrorMessage= $null
}

$VaultDomain = ""
$MappingCsvPath = ""
$CredentialStorePath = Join-Path $PSScriptRoot 'LocalCredentials'

function Get-MappedVaultUsername {
  param([string]$windowsUsername)
  if (-not (Test-Path $MappingCsvPath)) { throw "Mapping CSV file not found: $MappingCsvPath" }
  $mappings = Import-Csv -Path $MappingCsvPath
  $mapping = $mappings | Where-Object { $_.WindowsUsername -eq $windowsUsername }
  if ($mapping) { return $mapping.VaultUsername } else { return $null }
}

function Get-LocalCredentialObject {
  param([string]$key)
  if (-not (Test-Path $CredentialStorePath)) { throw "Credential store not found: $CredentialStorePath" }
  $candidate = Join-Path $CredentialStorePath ("{0}.xml" -f $key)
  if (-not (Test-Path $candidate)) { throw "Credential file not found for '$key': $candidate" }
  $obj = Import-Clixml -Path $candidate
  if ($null -eq $obj -or -not ($obj -is [System.Management.Automation.PSCredential])) {
    throw "Invalid credential object in: $candidate"
  }
  return $obj
}

try {
  $effectiveUsername = if ($TargetUsername) { $TargetUsername } else { Get-MappedVaultUsername -windowsUsername $AccountName }
  if (-not $effectiveUsername) { throw "No mapping found for user '$AccountName'." }

  $cred = Get-LocalCredentialObject -key $effectiveUsername
  $password = $cred.GetNetworkCredential().Password
  if (-not $password) { throw "Password missing for '$effectiveUsername'." }

  $Result.Username = $cred.UserName
  $Result.Password = $password
  $Result.Domain   = if ($VaultDomain) { $VaultDomain } else { $AccountDomain }
}
catch {
  $Result.Cancel = $true
  $Result.ErrorMessage = $_.Exception.Message
}

