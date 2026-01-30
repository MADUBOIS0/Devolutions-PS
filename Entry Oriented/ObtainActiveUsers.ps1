<#
.SYNOPSIS
    Export a list of RDM users with activity-based status.
.DESCRIPTION
    Uses RDM cmdlets only. Selects an existing RDM data source, pulls all users,
    exports activity logs, and derives:
      - Last activity on an entry
      - Whether the user ever opened an RDP session
      - Active/Inactive status based on last entry open within a threshold
.PARAMETER DataSourceName
    Name of the RDM data source to connect to.
.PARAMETER ExportPath
    CSV output path for the user activity report.
.PARAMETER VaultId
    Optional Vault ID to scope activity logs.
.PARAMETER InactiveThresholdDays
    Number of days without entry activity to consider a user inactive.
.PARAMETER ActivityLookbackDays
    Number of days of activity logs to export (limits how far back last opens can be found).
.PARAMETER RelaxedUserMatching
    When set (default), match users by domainless and email-prefix variants.
.PARAMETER KeepActivityLogCsv
    When set, keeps the exported activity log CSV instead of deleting it.
#>
[CmdletBinding()]
param (
    [string]$DataSourceName,

    [string]$ExportPath = "C:\Temp\ActiveUsers.csv",

    [guid]$VaultId,

    [int]$InactiveThresholdDays = 365,

    [int]$ActivityLookbackDays = 3650,

    [bool]$RelaxedUserMatching = $true,

    [bool]$TreatEntryActivityAsOpen = $true,

    [switch]$KeepActivityLogCsv
)

Set-StrictMode -Version Latest

if ($PSBoundParameters.Count -eq 0) {
    $DataSourceName = Read-Host "Data source name"

    $exportInput = Read-Host ("Export path [{0}]" -f $ExportPath)
    if (-not [string]::IsNullOrWhiteSpace($exportInput)) {
        $ExportPath = $exportInput
    }
} elseif ([string]::IsNullOrWhiteSpace($DataSourceName)) {
    $DataSourceName = Read-Host "Data source name"
}

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

function Resolve-LogColumns {
    param (
        [Parameter(Mandatory = $true)][string[]]$Headers,
        [Parameter(Mandatory = $true)][string[]]$IncludePatterns,
        [string[]]$ExcludePatterns = @()
    )

    $columns = New-Object System.Collections.Generic.List[string]
    foreach ($header in $Headers) {
        if ([string]::IsNullOrWhiteSpace($header)) {
            continue
        }

        $candidate = $header.ToLowerInvariant()
        $isExcluded = $false
        foreach ($pattern in $ExcludePatterns) {
            if ($candidate -match $pattern) {
                $isExcluded = $true
                break
            }
        }
        if ($isExcluded) {
            continue
        }

        foreach ($pattern in $IncludePatterns) {
            if ($candidate -match $pattern) {
                [void]$columns.Add($header)
                break
            }
        }
    }

    return ,($columns.ToArray())
}

function Get-LogFieldValueWithFallback {
    param (
        [Parameter(Mandatory = $true)]$Row,
        [string[]]$PreferredNames,
        [string[]]$FallbackNames
    )

    $names = $PreferredNames
    if (-not $names -or @($names).Count -eq 0) {
        $names = $FallbackNames
    }

    if (-not $names -or @($names).Count -eq 0) {
        return $null
    }

    return (Get-LogFieldValue -Row $Row -Names $names)
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

    return ,($results.ToArray())
}

function Get-UserKeys {
    param (
        [Parameter(Mandatory = $true)]$User,
        [switch]$Relaxed
    )

    $keys = New-Object System.Collections.Generic.HashSet[string]
    $candidateNames = @(
        "UserName",
        "Username",
        "User",
        "Login",
        "Name",
        "Email",
        "EmailAddress",
        "UserPrincipalName",
        "UPN",
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

    return ,([string[]]$keys)
}

function Get-UserIdValue {
    param ([Parameter(Mandatory = $true)]$User)

    $idValue = Get-FirstPropertyValue -Object $User -Names @("ID", "Id", "UserID", "UserId", "UserGuid", "Guid")
    if ($null -eq $idValue) {
        return $null
    }

    $idString = $idValue.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($idString)) {
        return $null
    }

    return $idString.ToLowerInvariant()
}

function Get-ActivityText {
    param (
        [Parameter(Mandatory = $true)]$Row,
        [string[]]$ColumnNames
    )

    $names = $ColumnNames
    if (-not $names -or @($names).Count -eq 0) {
        $names = @("Message", "Action", "Activity", "Event", "Event Type", "Operation", "Operation Type", "Category", "Details", "Description")
    }

    $values = @()
    foreach ($name in $names) {
        $value = Get-LogFieldValue -Row $Row -Names @($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values += $value.ToString()
        }
    }

    if (-not $values -or @($values).Count -eq 0) {
        return $null
    }

    return ($values -join " ")
}

function Test-OpenActivity {
    param ([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $positive = "(?i)\\b(open|launch|connect|start|run|execute)\\b"
    $negative = "(?i)\\b(close|disconnect|logout|logoff|log off|end|stop|terminate|failed|error)\\b"

    if ($Text -match $negative -and -not ($Text -match $positive)) {
        return $false
    }

    if ($Text -match $positive) {
        return $true
    }

    return $null
}

function Get-EntryActivityType {
    param (
        [string]$ActivityText,
        [string]$EntryName,
        [string]$EntryId,
        [string]$ConnectionType
    )

    $hasEntry = (-not [string]::IsNullOrWhiteSpace($EntryName)) -or (-not [string]::IsNullOrWhiteSpace($EntryId)) -or (-not [string]::IsNullOrWhiteSpace($ConnectionType))
    if (-not $hasEntry) {
        return $null
    }

    $text = ""
    if (-not [string]::IsNullOrWhiteSpace($ActivityText)) {
        $text = $ActivityText
    }

    # Password actions
    if ($text -match "(?i)password" -and $text -match "(?i)\\b(view|viewed|reveal|revealed|show|shown|copy|copied|checkout|check out|retrieve|retrieved|get|got)\\b") {
        return "Viewed Password"
    }

    if ($text -match "(?i)password" -and $text -match "(?i)\\b(update|updated|change|changed|rotate|rotated|reset|resetting|set|set to)\\b") {
        return "Changed Password"
    }

    # Folder actions
    if ($text -match "(?i)\\bfolder\\b" -and $text -match "(?i)\\b(create|created|add|added|new)\\b") {
        return "Created Folder"
    }

    if ($text -match "(?i)\\bfolder\\b" -and $text -match "(?i)\\b(rename|renamed|move|moved|edit|edited|modify|modified|update|updated)\\b") {
        return "Modified Folder"
    }

    if ($text -match "(?i)\\bfolder\\b" -and $text -match "(?i)\\b(delete|deleted|remove|removed)\\b") {
        return "Deleted Folder"
    }

    # Entry actions
    if ($text -match "(?i)\\b(create|created|add|added|new|import|imported)\\b") {
        return "Created Entry"
    }

    if ($text -match "(?i)\\b(update|updated|modify|modified|edit|edited|change|changed|rename|renamed|move|moved)\\b") {
        return "Modified Entry"
    }

    if ($text -match "(?i)\\b(delete|deleted|remove|removed)\\b") {
        return "Deleted Entry"
    }

    if ($text -match "(?i)\\b(open|opened|launch|launched|connect|connected|start|started|run|ran|execute|executed|view|viewed)\\b") {
        return "Opened Entry"
    }

    return "Entry Activity"
}

function Test-RdpConnectionType {
    param ([string]$ConnectionType)

    if ([string]::IsNullOrWhiteSpace($ConnectionType)) {
        return $false
    }

    return ($ConnectionType -match "(?i)rdp")
}

if (-not (Get-Command -Name Get-RDMDataSource -ErrorAction SilentlyContinue)) {
    throw "Get-RDMDataSource cmdlet not found. Ensure the Devolutions.PowerShell module is installed and imported."
}

if (-not (Get-Command -Name Set-RDMCurrentDataSource -ErrorAction SilentlyContinue)) {
    throw "Set-RDMCurrentDataSource cmdlet not found. Ensure the Devolutions.PowerShell module is installed and imported."
}

if (-not (Get-Command -Name Get-RDMUser -ErrorAction SilentlyContinue)) {
    throw "Get-RDMUser cmdlet not found. Ensure the Devolutions.PowerShell module is installed and imported."
}

if (-not (Get-Command -Name Export-RDMActivityLogsReport -ErrorAction SilentlyContinue)) {
    throw "Export-RDMActivityLogsReport cmdlet not found. Ensure the Devolutions.PowerShell module is installed and imported."
}

if ([string]::IsNullOrWhiteSpace($DataSourceName)) {
    throw "Data source name is required."
}

$ds = Get-RDMDataSource -Name $DataSourceName
if (-not $ds) {
    throw "Unable to locate the data source '$DataSourceName'."
}

Set-RDMCurrentDataSource $ds
Write-Verbose "Switched to data source '$DataSourceName'."

$users = Get-RDMUser
if ($users -and $users.PSObject.Properties.Name -contains "Data") {
    $users = $users.Data
}

if (-not $users) {
    Write-Host "No users returned from Get-RDMUser."
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
$logs = @($logs)

if ($logs.Count -eq 0) {
    Write-Warning "No activity logs were exported for the selected time range and data source."
}

$logHeaders = @()
if ($logs.Count -gt 0) {
    $logHeaders = @($logs[0].PSObject.Properties.Name)
}

$logColumnMap = [ordered]@{
    User = Resolve-LogColumns -Headers $logHeaders -IncludePatterns @("user(name)?", "login", "account", "actor", "performed by", "performedby") -ExcludePatterns @("user agent", "useragent")
    UserId = Resolve-LogColumns -Headers $logHeaders -IncludePatterns @("user id", "userid", "user guid", "userguid", "user uuid", "useruuid")
    Date = Resolve-LogColumns -Headers $logHeaders -IncludePatterns @("log date", "date time", "datetime", "timestamp", "date", "time", "utc") -ExcludePatterns @("created", "modified")
    Message = Resolve-LogColumns -Headers $logHeaders -IncludePatterns @("message", "action", "activity", "event", "operation", "category", "details", "description", "info")
    ConnectionType = Resolve-LogColumns -Headers $logHeaders -IncludePatterns @("connection type", "entry type", "session type", "protocol", "^type$") -ExcludePatterns @("operation type", "object type")
    EntryName = Resolve-LogColumns -Headers $logHeaders -IncludePatterns @("entry name", "session name", "^entry$", "^session$", "connection", "object", "item", "target", "resource", "name")
    EntryId = Resolve-LogColumns -Headers $logHeaders -IncludePatterns @("entry id", "session id", "entryid", "sessionid", "connectionid", "connection id", "object id", "resource id", "target id")
}

Write-Verbose ("Detected log columns: " + ($logHeaders -join ", "))
Write-Verbose ("User columns: " + ($logColumnMap.User -join ", "))
Write-Verbose ("UserId columns: " + ($logColumnMap.UserId -join ", "))
Write-Verbose ("Date columns: " + ($logColumnMap.Date -join ", "))
Write-Verbose ("Message columns: " + ($logColumnMap.Message -join ", "))
Write-Verbose ("Connection type columns: " + ($logColumnMap.ConnectionType -join ", "))
Write-Verbose ("Entry name columns: " + ($logColumnMap.EntryName -join ", "))
Write-Verbose ("Entry id columns: " + ($logColumnMap.EntryId -join ", "))

$lastOpenByUser = @{}
$lastRdpByUser = @{}
$lastOpenByUserId = @{}
$lastRdpByUserId = @{}
$lastEntryActivityByUser = @{}
$lastEntryActivityByUserId = @{}

foreach ($row in $logs) {
    $rawUser = Get-LogFieldValueWithFallback -Row $row -PreferredNames $logColumnMap.User -FallbackNames @("User", "UserName", "Username", "User Name", "Login", "User Login", "Account")
    $rawUserId = Get-LogFieldValueWithFallback -Row $row -PreferredNames $logColumnMap.UserId -FallbackNames @("User ID", "UserID", "User Id", "UserId", "User Guid", "UserGUID", "UserGuid")
    $message = Get-ActivityText -Row $row -ColumnNames $logColumnMap.Message
    $connectionType = Get-LogFieldValueWithFallback -Row $row -PreferredNames $logColumnMap.ConnectionType -FallbackNames @("Connection Type", "ConnectionType", "Entry Type")
    $logDateRaw = Get-LogFieldValueWithFallback -Row $row -PreferredNames $logColumnMap.Date -FallbackNames @("Log Date", "LogDate", "Date", "Date/Time", "Date Time", "Timestamp", "Time", "UTC Date", "Date UTC")
    $logDate = Convert-LogDate -Value $logDateRaw
    $entryName = Get-LogFieldValueWithFallback -Row $row -PreferredNames $logColumnMap.EntryName -FallbackNames @("Entry Name", "Session Name", "Entry", "Session", "Name")
    $entryId = Get-LogFieldValueWithFallback -Row $row -PreferredNames $logColumnMap.EntryId -FallbackNames @("Entry ID", "Session ID", "EntryId", "SessionId", "ConnectionID", "ConnectionId")

    if (-not $logDate) {
        continue
    }

    $normalizedUserId = $null
    if ($rawUserId) {
        $rawUserIdValue = $rawUserId.ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($rawUserIdValue)) {
            $normalizedUserId = $rawUserIdValue.ToLowerInvariant()
        }
    }

    $userKeys = Get-NameVariants -Value $rawUser -Relaxed:$RelaxedUserMatching
    if (-not $normalizedUserId -and (-not $userKeys -or @($userKeys).Count -eq 0)) {
        continue
    }

    $isOpenSignal = Test-OpenActivity -Text $message
    if ($null -ne $isOpenSignal) {
        $isOpen = $isOpenSignal
    } elseif ($TreatEntryActivityAsOpen) {
        $isOpen = (-not [string]::IsNullOrWhiteSpace($entryName)) -or (-not [string]::IsNullOrWhiteSpace($entryId))
    } else {
        $isOpen = $false
    }

    $isRdp = $isOpen -and (Test-RdpConnectionType -ConnectionType $connectionType)

    if ($normalizedUserId) {
        if ($isOpen) {
            if (-not $lastOpenByUserId.ContainsKey($normalizedUserId) -or $logDate -gt $lastOpenByUserId[$normalizedUserId]) {
                $lastOpenByUserId[$normalizedUserId] = $logDate
            }
        }

        if ($isRdp) {
            if (-not $lastRdpByUserId.ContainsKey($normalizedUserId) -or $logDate -gt $lastRdpByUserId[$normalizedUserId]) {
                $lastRdpByUserId[$normalizedUserId] = $logDate
            }
        }

        if (-not $lastEntryActivityByUserId.ContainsKey($normalizedUserId) -or $logDate -gt $lastEntryActivityByUserId[$normalizedUserId]) {
            $lastEntryActivityByUserId[$normalizedUserId] = $logDate
        }
    }

    foreach ($key in @($userKeys)) {
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

        if (-not $lastEntryActivityByUser.ContainsKey($key) -or $logDate -gt $lastEntryActivityByUser[$key]) {
            $lastEntryActivityByUser[$key] = $logDate
        }
    }
}

$inactiveCutoff = $now.AddDays(-1 * $InactiveThresholdDays)
$results = New-Object System.Collections.Generic.List[object]

foreach ($user in $users) {
    $userKeys = Get-UserKeys -User $user -Relaxed:$RelaxedUserMatching
    $userId = Get-UserIdValue -User $user
    $lastOpen = $null
    $lastRdp = $null
    $lastEntryActivity = $null

    if ($userId) {
        if ($lastOpenByUserId.ContainsKey($userId)) {
            $lastOpen = $lastOpenByUserId[$userId]
        }
        if ($lastRdpByUserId.ContainsKey($userId)) {
            $lastRdp = $lastRdpByUserId[$userId]
        }
        if ($lastEntryActivityByUserId.ContainsKey($userId)) {
            $lastEntryActivity = $lastEntryActivityByUserId[$userId]
        }
    }

    foreach ($key in @($userKeys)) {
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

        if ($lastEntryActivityByUser.ContainsKey($key)) {
            if (-not $lastEntryActivity -or $lastEntryActivityByUser[$key] -gt $lastEntryActivity) {
                $lastEntryActivity = $lastEntryActivityByUser[$key]
            }
        }
    }

    $status = if (-not $lastEntryActivity -or $lastEntryActivity -lt $inactiveCutoff) { "Inactive" } else { "Active" }
    $rdmActive = $null -ne $lastRdp

    $results.Add([pscustomobject][ordered]@{
        UserName           = (Get-FirstPropertyValue -Object $user -Names @("UserName", "Login", "Name"))
        DisplayName        = (Get-FirstPropertyValue -Object $user -Names @("DisplayName", "FullName", "Name"))
        Email              = (Get-FirstPropertyValue -Object $user -Names @("Email", "EmailAddress"))
        Enabled            = (Get-FirstPropertyValue -Object $user -Names @("Enabled", "IsEnabled", "Active"))
        LastActivityOnEntry = $lastEntryActivity
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
