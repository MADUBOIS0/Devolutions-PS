<#
.SYNOPSIS
    Export a list of Devolutions Server users with activity-based status.
.DESCRIPTION
    Authenticates with Devolutions Server using DS cmdlets, pulls all users,
    exports activity logs, and derives:
      - Last entry opened date
      - Whether the user ever opened an RDP session
      - Active/Inactive status based on last entry open within a threshold
.PARAMETER BaseUri
    DVLS base URI (e.g., https://dvls.company.local).
.PARAMETER ExportPath
    CSV output path for the user activity report.
.PARAMETER AppKey
    Application key (username) for DVLS application authentication.
.PARAMETER AppSecret
    Application secret (password) for DVLS application authentication.
.PARAMETER Credential
    PSCredential for DVLS user authentication.
.PARAMETER WindowsAuthentication
    Use Windows authentication for DVLS.
.PARAMETER VaultId
    Optional Vault ID to scope activity logs.
.PARAMETER InactiveThresholdDays
    Number of days without entry opens to consider a user inactive.
.PARAMETER ActivityLookbackDays
    Number of days of activity logs to export (limits how far back last opens can be found).
.PARAMETER RelaxedUserMatching
    When set (default), match users by domainless and email-prefix variants.
.PARAMETER KeepActivityLogCsv
    When set, keeps the exported activity log CSV instead of deleting it.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$BaseUri,

    [string]$ExportPath = "C:\Temp\ActiveUsers.csv",

    [string]$AppKey,
    [string]$AppSecret,

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$WindowsAuthentication,

    [guid]$VaultId,

    [int]$InactiveThresholdDays = 365,

    [int]$ActivityLookbackDays = 3650,

    [bool]$RelaxedUserMatching = $true,

    [switch]$KeepActivityLogCsv
)

Set-StrictMode -Version Latest

function Get-FirstPropertyValue {
    param (
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value -and $value -ne "") {
                return $value
            }
        }
    }

    return $null
}

function Get-LogFieldValue {
    param (
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Row.PSObject.Properties.Name -contains $name) {
            return $Row.$name
        }
    }

    return $null
}

function Convert-LogDate {
    param ([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return (Get-Date -Date $Value)
    } catch {
        return $null
    }
}

function Get-NameVariants {
    param (
        [string]$Value,
        [switch]$Relaxed
    )

    $results = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $results
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
        [void]$results.Add($normalized)
    }

    if ($Relaxed) {
        if ($normalized -match "\\") {
            $domainless = $normalized.Split("\\")[-1]
            if (-not [string]::IsNullOrWhiteSpace($domainless)) {
                [void]$results.Add($domainless)
            }
        }

        if ($normalized -match "@") {
            $prefix = $normalized.Split("@")[0]
            if (-not [string]::IsNullOrWhiteSpace($prefix)) {
                [void]$results.Add($prefix)
            }
        }
    }

    return $results
}

function Get-UserKeys {
    param (
        [Parameter(Mandatory = $true)]$User,
        [switch]$Relaxed
    )

    $keys = New-Object System.Collections.Generic.HashSet[string]
    $candidateNames = @(
        "UserName",
        "Login",
        "Name",
        "Email",
        "DisplayName"
    )

    foreach ($candidate in $candidateNames) {
        if ($User.PSObject.Properties.Name -contains $candidate) {
            $value = $User.$candidate
            foreach ($variant in (Get-NameVariants -Value $value -Relaxed:$Relaxed)) {
                [void]$keys.Add($variant)
            }
        }
    }

    return $keys
}

function Test-OpenMessage {
    param ([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    if ($Message -match "(?i)\\bclose") {
        return $false
    }

    return ($Message -match "(?i)\\bopen")
}

function Test-RdpConnectionType {
    param ([string]$ConnectionType)

    if ([string]::IsNullOrWhiteSpace($ConnectionType)) {
        return $false
    }

    return ($ConnectionType -match "(?i)rdp")
}

if (-not (Get-Command -Name New-DSSession -ErrorAction SilentlyContinue)) {
    throw "New-DSSession cmdlet not found. Ensure the Devolutions.PowerShell module is installed and imported."
}

if (-not (Get-Command -Name Export-RDMActivityLogsReport -ErrorAction SilentlyContinue)) {
    throw "Export-RDMActivityLogsReport cmdlet not found. Ensure the Devolutions.PowerShell module is installed and imported."
}

$session = $null
if ($WindowsAuthentication) {
    $session = New-DSSession -BaseUri $BaseUri -WindowsAuthentication
} elseif ($AppKey -and $AppSecret) {
    $secureSecret = ConvertTo-SecureString $AppSecret -AsPlainText -Force
    $appCredential = New-Object System.Management.Automation.PSCredential ($AppKey, $secureSecret)
    $session = New-DSSession -BaseUri $BaseUri -Credential $appCredential -AsApplication
} elseif ($Credential) {
    $session = New-DSSession -BaseUri $BaseUri -Credential $Credential
} else {
    throw "Provide -Credential, -WindowsAuthentication, or -AppKey/-AppSecret for DS authentication."
}

Write-Verbose "Connected to Devolutions Server at $BaseUri."

$users = Get-DSUser -All
if ($users -and $users.PSObject.Properties.Name -contains "Data") {
    $users = $users.Data
}

if (-not $users) {
    Write-Host "No users returned from Get-DSUser."
    return
}

if (-not ($users -is [System.Collections.IEnumerable])) {
    $users = @($users)
}

$now = Get-Date
$lookbackStart = $now.AddDays(-1 * $ActivityLookbackDays)
$activityLogPath = Join-Path $env:TEMP ("RDMActivityLogs_{0:yyyyMMddHHmmss}.csv" -f $now)

$exportParams = @{
    Type   = "Csv"
    Path   = $activityLogPath
    After  = $lookbackStart
    Before = $now
}

if ($VaultId -and $VaultId -ne [guid]::Empty) {
    $exportParams.VaultID = $VaultId
}

Export-RDMActivityLogsReport @exportParams

if (-not (Test-Path -LiteralPath $activityLogPath)) {
    throw "Activity log export failed. No CSV found at $activityLogPath."
}

$logs = Import-Csv -Path $activityLogPath

$lastOpenByUser = @{}
$lastRdpByUser = @{}

foreach ($row in $logs) {
    $rawUser = Get-LogFieldValue -Row $row -Names @("User", "UserName", "Username", "User Name", "Login")
    $message = Get-LogFieldValue -Row $row -Names @("Message")
    $connectionType = Get-LogFieldValue -Row $row -Names @("Connection Type", "ConnectionType", "Entry Type")
    $logDateRaw = Get-LogFieldValue -Row $row -Names @("Log Date", "LogDate", "Date", "Date/Time", "Date Time")
    $logDate = Convert-LogDate -Value $logDateRaw

    if (-not $logDate) {
        continue
    }

    $userKeys = Get-NameVariants -Value $rawUser -Relaxed:$RelaxedUserMatching
    if ($userKeys.Count -eq 0) {
        continue
    }

    $isOpen = Test-OpenMessage -Message $message
    $isRdp = $isOpen -and (Test-RdpConnectionType -ConnectionType $connectionType)

    foreach ($key in $userKeys) {
        if ($isOpen) {
            if (-not $lastOpenByUser.ContainsKey($key) -or $logDate -gt $lastOpenByUser[$key]) {
                $lastOpenByUser[$key] = $logDate
            }
        }

        if ($isRdp) {
            if (-not $lastRdpByUser.ContainsKey($key) -or $logDate -gt $lastRdpByUser[$key]) {
                $lastRdpByUser[$key] = $logDate
            }
        }
    }
}

$inactiveCutoff = $now.AddDays(-1 * $InactiveThresholdDays)
$results = New-Object System.Collections.Generic.List[object]

foreach ($user in $users) {
    $userKeys = Get-UserKeys -User $user -Relaxed:$RelaxedUserMatching
    $lastOpen = $null
    $lastRdp = $null

    foreach ($key in $userKeys) {
        if ($lastOpenByUser.ContainsKey($key)) {
            if (-not $lastOpen -or $lastOpenByUser[$key] -gt $lastOpen) {
                $lastOpen = $lastOpenByUser[$key]
            }
        }

        if ($lastRdpByUser.ContainsKey($key)) {
            if (-not $lastRdp -or $lastRdpByUser[$key] -gt $lastRdp) {
                $lastRdp = $lastRdpByUser[$key]
            }
        }
    }

    $status = if (-not $lastOpen -or $lastOpen -lt $inactiveCutoff) { "Inactive" } else { "Active" }
    $rdmActive = $null -ne $lastRdp

    $results.Add([pscustomobject][ordered]@{
        UserName           = (Get-FirstPropertyValue -Object $user -Names @("UserName", "Login", "Name"))
        DisplayName        = (Get-FirstPropertyValue -Object $user -Names @("DisplayName", "FullName", "Name"))
        Email              = (Get-FirstPropertyValue -Object $user -Names @("Email", "EmailAddress"))
        Enabled            = (Get-FirstPropertyValue -Object $user -Names @("Enabled", "IsEnabled", "Active"))
        LastEntryOpen      = $lastOpen
        LastRdpSessionOpen = $lastRdp
        IsActiveRdmUser    = $rdmActive
        Status             = $status
    }) | Out-Null
}

$exportDirectory = Split-Path -Path $ExportPath -Parent
if (-not (Test-Path -LiteralPath $exportDirectory)) {
    New-Item -ItemType Directory -Path $exportDirectory -Force | Out-Null
}

$results | Sort-Object -Property Status, UserName | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Host "Exported $($results.Count) users to $ExportPath."

if (-not $KeepActivityLogCsv) {
    Remove-Item -LiteralPath $activityLogPath -ErrorAction SilentlyContinue
} else {
    Write-Host "Activity log CSV kept at $activityLogPath."
}
