<#
.SYNOPSIS
  Load credentials from a local DPAPI-encrypted store for RDM injection (no BeyondTrust).

.DESCRIPTION
  Mirrors the output contract of the BeyondTrust script by populating a `$Result` hashtable
  with Username, Password, Domain, Cancel, and ErrorMessage. Username resolution is done via
  a CSV mapping that links Windows usernames to target ("vault") usernames. Credentials are
  stored per target username as PSCredential objects exported via Export-Clixml.

.CONFIGURATION
  All credential mapping and storage is under `C:\CredentialMapping`:
  - CSV mapping file: `C:\CredentialMapping\vault-username-mapping.csv`
    Columns required: WindowsUsername,VaultUsername
  - Local credential files: `C:\CredentialMapping\LocalCredentials\<VaultUsername>.xml`
    Each file is an Export-Clixml of a PSCredential, encrypted with DPAPI for the current user.

.PARAMETER AccountName
  Windows username used to look up the mapped vault username (defaults to current user).

.PARAMETER AccountDomain
  Domain to report back to the caller if `$VaultDomain` is not explicitly set.

.PARAMETER TargetUsername
  Optional override that bypasses the mapping CSV and uses this vault username directly.
#>

# ----- Parameters -----
param(
  [string]$AccountName = $env:USERNAME,
  [string]$AccountDomain = $env:USERDOMAIN,
  [string]$TargetUsername
)

# ----- Runtime preferences and TLS (for parity; no network calls here) -----
$ErrorActionPreference = "Stop"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# ----- Result object expected by RDM -----
$Result = @{
  Username     = $null
  Password     = $null
  Domain       = $null
  Cancel       = $false
  ErrorMessage = $null
}

# ----- Static configuration: local mapping root -----
$CredentialRoot      = 'C:\CredentialMapping'
$MappingCsvPath      = Join-Path $CredentialRoot 'vault-username-mapping.csv'
$CredentialStorePath = Join-Path $CredentialRoot 'LocalCredentials'

# If you want to force a vault domain, set it here; otherwise the caller's AccountDomain is used.
$VaultDomain = ''

# ----- Function: Map Windows username -> Vault username via CSV -----
function Get-MappedVaultUsername {
  param([string]$windowsUsername)
  if (-not (Test-Path -LiteralPath $MappingCsvPath)) {
    throw "Mapping CSV file not found: $MappingCsvPath"
  }
  $mappings = Import-Csv -Path $MappingCsvPath
  $mapping = $mappings | Where-Object { $_.WindowsUsername -eq $windowsUsername }
  if ($mapping) { return $mapping.VaultUsername } else { return $null }
}

# ----- Function: Load PSCredential from local store for a given vault username -----
function Get-LocalCredentialObject {
  param([string]$key)
  if (-not (Test-Path -LiteralPath $CredentialStorePath)) {
    throw "Credential store not found: $CredentialStorePath"
  }
  $candidate = Join-Path $CredentialStorePath ("{0}.xml" -f $key)
  if (-not (Test-Path -LiteralPath $candidate)) {
    throw "Credential file not found for '$key': $candidate"
  }
  $obj = Import-Clixml -Path $candidate
  if ($null -eq $obj -or -not ($obj -is [System.Management.Automation.PSCredential])) {
    throw "Invalid credential object in: $candidate"
  }
  return $obj
}

# ----- Main flow -----
try {
  # 1) Resolve effective vault username (TargetUsername override -> CSV mapping)
  $effectiveUsername = if ($TargetUsername) { $TargetUsername } else { Get-MappedVaultUsername -windowsUsername $AccountName }
  if (-not $effectiveUsername) { throw "No mapping found for user '$AccountName'." }

  # 2) Load credential for the effective vault username
  $cred = Get-LocalCredentialObject -key $effectiveUsername
  $password = $cred.GetNetworkCredential().Password
  if (-not $password) { throw "Password missing for '$effectiveUsername'." }

  # 3) Populate RDM result object
  $Result.Username = $cred.UserName
  $Result.Password = $password
  $Result.Domain   = if ($VaultDomain) { $VaultDomain } else { $AccountDomain }
}
catch {
  $Result.Cancel = $true
  $Result.ErrorMessage = $_.Exception.Message
}
