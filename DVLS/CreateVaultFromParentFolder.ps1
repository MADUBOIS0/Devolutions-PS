<#
.SYNOPSIS
    Creates dedicated vaults from the first-level folders of a source vault.
.DESCRIPTION
    Connects to a Devolutions Server instance via the Devolutions.PowerShell module, enumerates the first-level folders
    of the specified source vault and, for each folder, creates a destination vault with the same name (if necessary)
    before copying the folder structure and entries into that new vault.
.PARAMETER DVLSUri
    Base URI of the Devolutions Server instance (for example, https://dvls.contoso.com).
.PARAMETER AppKey
    Application key that has permission to administer vaults.
.PARAMETER AppSecret
    Secret associated with the application key.
.PARAMETER SourceVaultName
    Name of the vault whose first-level folders should be exported. Defaults to Default.
.PARAMETER SkipExistingVaults
    Skip folders whose corresponding destination vault already exists.
.EXAMPLE
    .\CreateVaultFromParentFolder.ps1 -DVLSUri "https://dvls.contoso.com" -AppKey "my-app-key" -AppSecret "my-app-secret" -SourceVaultName "Default"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DVLSUri,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AppKey,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AppSecret,
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SourceVaultName = 'Default',
    [Parameter()]
    [switch]$SkipExistingVaults
)

Import-Module Devolutions.PowerShell -RequiredVersion 2025.2.6 -ErrorAction Stop

function Connect-DVLSWithAppKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUri,
        [Parameter(Mandatory = $true)]
        [string]$AppKey,
        [Parameter(Mandatory = $true)]
        [string]$AppSecret
    )

    [securestring]$secureSecret = ConvertTo-SecureString -String $AppSecret -AsPlainText -Force
    [pscredential]$credential = New-Object System.Management.Automation.PSCredential ($AppKey, $secureSecret)
    return New-DSSession -BaseUri $BaseUri -AsApplication -Credential $credential
}

function Resolve-DSResponse {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][psobject]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $current = $InputObject
    while ($null -ne $current -and $current -isnot [string]) {
        $next = $null
        foreach ($propName in @('Data', 'data', 'Value', 'value')) {
            if ($current.PSObject.Properties[$propName]) {
                $candidate = $current.$propName
                if ($null -ne $candidate) {
                    $next = $candidate
                    break
                }
            }
        }

        if ($null -eq $next) {
            break
        }

        $current = $next
    }

    return $current
}

function ConvertTo-DSArray {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $list.Add($item)
        }
        return $list.ToArray()
    }

    return @($Value)
}

function ConvertTo-DSGuid {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return [Guid]::Empty
    }

    if ($Value -is [Guid]) {
        return [Guid]$Value
    }

    $stringValue = $Value.ToString()
    if ([string]::IsNullOrWhiteSpace($stringValue)) {
        return [Guid]::Empty
    }

    $parsed = [Guid]::Empty
    if ([Guid]::TryParse($stringValue, [ref]$parsed)) {
        return $parsed
    }

    return [Guid]::Empty
}

function Get-DSObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Object,
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function Get-VaultId {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Vault
    )

    foreach ($candidateNames in @(
            @('ID', 'Id', 'VaultID', 'VaultId'),
            @('IDString', 'IdString'),
            @('RepositoryID', 'RepositoryId')
        )) {
        $value = Get-DSObjectProperty -Object $Vault -Names $candidateNames
        $guid = ConvertTo-DSGuid -Value $value
        if ($guid -ne [Guid]::Empty) {
            return $guid
        }
    }

    return [Guid]::Empty
}

function Get-DSRootSessionWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Guid]$VaultId,
        [Parameter()]
        [int]$MaxAttempts = 10,
        [Parameter()]
        [int]$DelaySeconds = 1
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Get-DSRootSession -VaultID $VaultId -ErrorAction Stop
            $rootSession = Resolve-DSResponse $response
            if ($null -ne $rootSession) {
                return $rootSession
            }

            Write-Verbose "Root session for vault $VaultId returned no data on attempt $attempt."
        } catch {
            Write-Verbose "Attempt $attempt to retrieve root session for vault $VaultId failed: $($_.Exception.Message)"
            if ($attempt -eq $MaxAttempts) {
                throw
            }
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    throw "Unable to retrieve root session for vault $VaultId after $MaxAttempts attempts."
}

function Normalize-GroupPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $normalized = $Path.Replace('/', '\\').Trim()
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '\\+', '\\')
    return $normalized.Trim('\\')
}

function Test-IsPathUnderRoot {
    param(
        [string]$CandidatePath,
        [string]$PrimaryRoot,
        [string]$AlternateRoot
    )

    $candidateNormalized = Normalize-GroupPath -Path $CandidatePath
    if ([string]::IsNullOrEmpty($candidateNormalized)) {
        return $false
    }

    foreach ($rootCandidate in @($PrimaryRoot, $AlternateRoot)) {
        if ([string]::IsNullOrEmpty($rootCandidate)) {
            continue
        }

        $normalizedRoot = Normalize-GroupPath -Path $rootCandidate
        if ([string]::IsNullOrEmpty($normalizedRoot)) {
            continue
        }

        if ($candidateNormalized.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        $prefix = [System.String]::Concat($normalizedRoot, '\\')
        if ($candidateNormalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Resolve-RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath,
        [string[]]$RootCandidates
    )

    $normalizedFull = Normalize-GroupPath -Path $FullPath
    if ([string]::IsNullOrEmpty($normalizedFull)) {
        return ''
    }

    if ($RootCandidates) {
        foreach ($candidateRoot in $RootCandidates | Where-Object { -not [string]::IsNullOrEmpty($_) }) {
            $normalizedRoot = Normalize-GroupPath -Path $candidateRoot
            if ([string]::IsNullOrEmpty($normalizedRoot)) {
                continue
            }

            if ($normalizedFull.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                return ''
            }

            $prefix = [System.String]::Concat($normalizedRoot, '\\')
            if ($normalizedFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $normalizedFull.Substring($prefix.Length)
            }
        }
    }

    return $normalizedFull
}

function Get-FolderFullPath {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Folder
    )

    $groupValue = Get-DSObjectProperty -Object $Folder -Names @('Group', 'GroupPath', 'Parent', 'ParentGroup', 'ParentPath')
    $groupPath = Normalize-GroupPath -Path $groupValue
    $name = Get-DSObjectProperty -Object $Folder -Names @('Name', 'FolderName')

    if ([string]::IsNullOrEmpty($name)) {
        return $groupPath
    }

    if ([string]::IsNullOrEmpty($groupPath)) {
        return Normalize-GroupPath -Path $name
    }

    return Normalize-GroupPath -Path ([System.String]::Concat($groupPath, '\\', $name))
}

function Get-FolderId {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Folder
    )

    $value = Get-DSObjectProperty -Object $Folder -Names @('ID', 'Id', 'FolderID', 'FolderId')
    $guid = ConvertTo-DSGuid -Value $value
    if ($guid -eq [Guid]::Empty) {
        throw "Unable to resolve folder identifier."
    }

    return $guid
}

function Get-EntryGroupPath {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Entry
    )

    $groupValue = Get-DSObjectProperty -Object $Entry -Names @('Group', 'GroupName', 'GroupPath')
    return Normalize-GroupPath -Path $groupValue
}

function Get-EntryName {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Entry
    )

    $value = Get-DSObjectProperty -Object $Entry -Names @('Name')
    return [string]$value
}

function Get-EntryConnectionType {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Entry
    )

    $value = Get-DSObjectProperty -Object $Entry -Names @('ConnectionType', 'ConnectionTypeString', 'ConnexionTypeString')
    if ($null -eq $value) {
        return ''
    }

    return [string]$value
}

function Get-EntryId {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Entry
    )

    $value = Get-DSObjectProperty -Object $Entry -Names @('ID', 'Id', 'EntryID', 'EntryId')
    $guid = ConvertTo-DSGuid -Value $value
    if ($guid -eq [Guid]::Empty) {
        throw "Unable to resolve entry identifier."
    }

    return $guid
}

function Get-EntryParentId {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Entry
    )

    $value = Get-DSObjectProperty -Object $Entry -Names @('ParentID', 'ParentId', 'FolderID', 'FolderId')
    return ConvertTo-DSGuid -Value $value
}

function Get-ParentPath {
    param(
        [string]$Path
    )

    $normalized = Normalize-GroupPath -Path $Path
    if ([string]::IsNullOrEmpty($normalized)) {
        return ''
    }

    $separatorIndex = $normalized.LastIndexOf('\\')
    if ($separatorIndex -lt 0) {
        return ''
    }

    return $normalized.Substring(0, $separatorIndex)
}

function Get-DestinationFolderIdByRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Guid]$DestinationVaultId,
        [Parameter(Mandatory = $true)]
        [string[]]$DestinationRootPathCandidates,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $foldersResponse = Get-DSFolders -VaultID $DestinationVaultId -IncludeSubFolders -ErrorAction Stop
    $folders = ConvertTo-DSArray (Resolve-DSResponse $foldersResponse)
    foreach ($folder in $folders) {
        if ($null -eq $folder) {
            continue
        }

        $existingPath = Get-FolderFullPath -Folder $folder
        $relativeExisting = Resolve-RelativePath -FullPath $existingPath -RootCandidates $DestinationRootPathCandidates
        $relativeExistingValue = if ($null -eq $relativeExisting) { '' } else { $relativeExisting }
        if ($relativeExistingValue -eq $RelativePath) {
            try {
                return Get-FolderId -Folder $folder
            } catch {
                continue
            }
        }
    }

    return [Guid]::Empty
}

function Set-PropertyIfWritable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Object,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName,
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $prop) {
        return
    }

    if ($prop.IsSettable) {
        $prop.Value = $Value
    }
}

function Ensure-DestinationFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,
        [Parameter(Mandatory = $true)]
        [Hashtable]$DestinationFolderMap,
        [Parameter(Mandatory = $true)]
        [psobject]$DestinationVault,
        [Parameter(Mandatory = $true)]
        [Guid]$DestinationVaultId,
        [Parameter(Mandatory = $true)]
        [string[]]$DestinationRootPathCandidates,
        [Parameter()]
        [string]$DestinationVaultName
    )

    if ([string]::IsNullOrEmpty($RelativePath)) {
        return [Guid]$DestinationFolderMap['']
    }

    if ($DestinationFolderMap.ContainsKey($RelativePath)) {
        return [Guid]$DestinationFolderMap[$RelativePath]
    }

    $parentPath = Get-ParentPath -Path $RelativePath
    $folderName = ($RelativePath.Split('\\') | Select-Object -Last 1)

    $newFolderParameters = @{
        VaultID = $DestinationVaultId
        Name    = $folderName
    }

    if (-not [string]::IsNullOrEmpty($parentPath)) {
        $newFolderParameters['Group'] = $parentPath
    }

    $vaultName = if (-not [string]::IsNullOrWhiteSpace($DestinationVaultName)) {
        $DestinationVaultName
    } else {
        Get-DSObjectProperty -Object $DestinationVault -Names @('Name', 'DisplayName')
    }

    if ([string]::IsNullOrWhiteSpace($vaultName)) {
        $vaultName = $DestinationVaultId.ToString()
    }

    if ($PSCmdlet.ShouldProcess("Vault '$vaultName'", "Create folder '$RelativePath'")) {
        try {
            $createdFolderResponse = New-DSFolder @newFolderParameters -ErrorAction Stop
            $createdFolder = Resolve-DSResponse $createdFolderResponse
            $createdId = [Guid]::Empty
            if ($createdFolder) {
                try {
                    $createdId = Get-FolderId -Folder $createdFolder
                } catch {
                    $createdId = [Guid]::Empty
                }
            }

            if ($createdId -eq [Guid]::Empty) {
                $createdId = Get-DestinationFolderIdByRelativePath -DestinationVaultId $DestinationVaultId -DestinationRootPathCandidates $DestinationRootPathCandidates -RelativePath $RelativePath
            }

            if ($createdId -eq [Guid]::Empty) {
                throw "Unable to resolve folder identifier."
            }

            $DestinationFolderMap[$RelativePath] = $createdId
            return $createdId
        } catch {
            $existingId = Get-DestinationFolderIdByRelativePath -DestinationVaultId $DestinationVaultId -DestinationRootPathCandidates $DestinationRootPathCandidates -RelativePath $RelativePath
            if ($existingId -ne [Guid]::Empty) {
                $DestinationFolderMap[$RelativePath] = $existingId
                Write-Verbose "Folder '$RelativePath' already exists in vault '$vaultName'. Reusing existing folder ID."
                return $existingId
            }

            throw "Folder '$RelativePath' could not be created: $($_.Exception.Message)"
        }
    }

    throw "Folder '$RelativePath' creation was cancelled."
}

function Resolve-ConnectionInfoEntity {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$EntryDetails
    )

    $resolved = Resolve-DSResponse $EntryDetails
    if ($null -eq $resolved) {
        return $null
    }

    if ($resolved.PSObject.Properties['ConnectionInfo']) {
        return $resolved.ConnectionInfo
    }

    if ($resolved.PSObject.TypeNames -contains 'Devolutions.RemoteDesktopManager.Business.Entities.ConnectionInfoEntity') {
        return $resolved
    }

    if ($resolved.PSObject.Properties['Connection']) {
        return $resolved.Connection
    }

    return $resolved
}

function Get-DSEntryDetailsWithFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Guid]$VaultId,
        [Parameter(Mandatory = $true)]
        [Guid]$EntryId,
        [Parameter(Mandatory = $true)]
        [string]$EntryName
    )

    $attempts = @(
        @{ Description = "Get-DSEntry -VaultID -EntryId -AsRDMConnection"; ScriptBlock = { Get-DSEntry -VaultID $VaultId -EntryId $EntryId -AsRDMConnection -ErrorAction Stop } },
        @{ Description = "Get-DSEntry -VaultID -EntryId"; ScriptBlock = { Get-DSEntry -VaultID $VaultId -EntryId $EntryId -ErrorAction Stop } },
        @{ Description = "Get-DSEntry -EntryId -SearchAllVaults -AsRDMConnection"; ScriptBlock = { Get-DSEntry -EntryId $EntryId -SearchAllVaults -AsRDMConnection -ErrorAction Stop } },
        @{ Description = "Get-DSEntry -EntryId -SearchAllVaults"; ScriptBlock = { Get-DSEntry -EntryId $EntryId -SearchAllVaults -ErrorAction Stop } }
    )

    foreach ($attempt in $attempts) {
        try {
            $response = & $attempt.ScriptBlock
            if ($null -ne $response) {
                return $response
            }
        } catch {
            Write-Verbose "Entry '$EntryName': $($attempt.Description) failed: $($_.Exception.Message)"
        }
    }

    return $null
}

function Copy-VaultFolderContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Guid]$SourceVaultId,
        [Parameter(Mandatory = $true)]
        [psobject]$RootFolder,
        [Parameter(Mandatory = $true)]
        [psobject[]]$AllFolders,
        [Parameter(Mandatory = $true)]
        [psobject[]]$AllEntries,
        [Parameter(Mandatory = $true)]
        [psobject]$DestinationVault,
        [Parameter(Mandatory = $true)]
        [Guid]$DestinationVaultId,
        [Parameter(Mandatory = $true)]
        [Guid]$DestinationRootId,
        [Parameter(Mandatory = $true)]
        [string[]]$DestinationRootPathCandidates,
        [Parameter(Mandatory = $true)]
        [string]$DestinationVaultName
    )

    $destinationVaultDisplayName = if ([string]::IsNullOrWhiteSpace($DestinationVaultName)) {
        $DestinationVaultId.ToString()
    } else {
        $DestinationVaultName
    }

    $rootFolderId = Get-FolderId -Folder $RootFolder
    $rootFolderName = Normalize-GroupPath -Path (Get-DSObjectProperty -Object $RootFolder -Names @('Name', 'FolderName'))
    if ([string]::IsNullOrEmpty($rootFolderName)) {
        throw "Folder name could not be resolved."
    }

    $rootFolderPath = Get-FolderFullPath -Folder $RootFolder
    if ([string]::IsNullOrEmpty($rootFolderPath)) {
        $rootFolderPath = $rootFolderName
    }

    $rootPathCandidates = @($rootFolderPath, $rootFolderName) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique

    $foldersToProcess = New-Object System.Collections.Generic.List[psobject]
    $foldersToProcess.Add($RootFolder) | Out-Null

    foreach ($candidate in $AllFolders) {
        if ($null -eq $candidate) {
            continue
        }

        $candidatePath = Get-FolderFullPath -Folder $candidate
        if (Test-IsPathUnderRoot -CandidatePath $candidatePath -PrimaryRoot $rootFolderPath -AlternateRoot $rootFolderName) {
            $foldersToProcess.Add($candidate) | Out-Null
        }
    }

    $folderIdSet = New-Object System.Collections.Generic.HashSet[string]
    $folderRelativePathMap = @{}
    foreach ($folder in $foldersToProcess) {
        try {
            $folderGuidValue = (Get-FolderId -Folder $folder).ToString()
            $folderIdSet.Add($folderGuidValue) | Out-Null
        } catch {
            continue
        }
    }

    $folderRelativePathMap[$rootFolderId.ToString()] = ''

    $destinationFolderMap = @{}
    $destinationFolderMap[''] = $DestinationRootId

    try {
        $existingDestinationFoldersResponse = Get-DSFolders -VaultID $DestinationVaultId -IncludeSubFolders -ErrorAction Stop
        $existingDestinationFolders = ConvertTo-DSArray (Resolve-DSResponse $existingDestinationFoldersResponse)
        foreach ($existing in $existingDestinationFolders) {
            if ($null -eq $existing) {
                continue
            }

            $existingPath = Get-FolderFullPath -Folder $existing
            $relativeExisting = Resolve-RelativePath -FullPath $existingPath -RootCandidates $DestinationRootPathCandidates
            $relativeExistingValue = if ($null -eq $relativeExisting) { '' } else { $relativeExisting }
            if ($destinationFolderMap.ContainsKey($relativeExistingValue)) {
                continue
            }

            try {
                $existingId = Get-FolderId -Folder $existing
                $destinationFolderMap[$relativeExistingValue] = $existingId
            } catch {
                Write-Verbose "Skipping destination folder preloading for path '$relativeExistingValue': $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Verbose "Destination folders in vault '$destinationVaultDisplayName' could not be preloaded: $($_.Exception.Message)"
    }

    $orderedFolders = $foldersToProcess | Sort-Object {
        $path = Get-FolderFullPath -Folder $_
        return (Normalize-GroupPath -Path $path).Split('\\').Length
    }

    foreach ($folder in $orderedFolders) {
        $currentFolderId = Get-FolderId -Folder $folder
        if ($currentFolderId -eq $rootFolderId) {
            continue
        }

        $folderPath = Get-FolderFullPath -Folder $folder
        $relativePath = Resolve-RelativePath -FullPath $folderPath -RootCandidates $rootPathCandidates
        if ($null -eq $relativePath) {
            continue
        }

        if ([string]::IsNullOrEmpty($relativePath)) {
            $folderRelativePathMap[$currentFolderId.ToString()] = ''
            continue
        }

        try {
            $createdFolderId = Ensure-DestinationFolder -RelativePath $relativePath -DestinationFolderMap $destinationFolderMap -DestinationVault $DestinationVault -DestinationVaultId $DestinationVaultId -DestinationRootPathCandidates $DestinationRootPathCandidates -DestinationVaultName $destinationVaultDisplayName
            $folderRelativePathMap[$currentFolderId.ToString()] = $relativePath
            $destinationFolderMap[$relativePath] = $createdFolderId
        } catch {
            Write-Warning "Unable to create folder '$relativePath' in vault '$destinationVaultDisplayName': $($_.Exception.Message)"
        }
    }

    $destinationEntryIndex = @{}
    try {
        $existingEntriesResponse = Get-DSEntry -VaultID $DestinationVaultId -All -ErrorAction Stop
        $existingEntries = ConvertTo-DSArray (Resolve-DSResponse $existingEntriesResponse)
        foreach ($existingEntry in $existingEntries) {
            if ($null -eq $existingEntry) {
                continue
            }

            $entryGroup = Get-EntryGroupPath -Entry $existingEntry
            $entryName = Get-EntryName -Entry $existingEntry
            if ([string]::IsNullOrEmpty($entryName)) {
                continue
            }

            $relativeGroup = Resolve-RelativePath -FullPath $entryGroup -RootCandidates $DestinationRootPathCandidates
            $relativeGroupValue = if ($null -eq $relativeGroup) { '' } else { $relativeGroup }
            $entryKey = if ([string]::IsNullOrEmpty($relativeGroupValue)) { $entryName } else { [System.String]::Concat($relativeGroupValue, '\\', $entryName) }
            $destinationEntryIndex[$entryKey.ToLowerInvariant()] = $true
        }
    } catch {
        Write-Verbose "Destination entries in vault '$destinationVaultDisplayName' could not be preloaded: $($_.Exception.Message)"
    }

    foreach ($entry in $AllEntries) {
        if ($null -eq $entry) {
            continue
        }

        $connectionType = Get-EntryConnectionType -Entry $entry
        if (-not [string]::IsNullOrEmpty($connectionType) -and $connectionType.ToLowerInvariant().Contains('folder')) {
            continue
        }

        $entryGroup = Get-EntryGroupPath -Entry $entry
        $entryParentId = Get-EntryParentId -Entry $entry
        $entryParentIdString = $entryParentId.ToString()

        $belongsToFolder = $folderIdSet.Contains($entryParentIdString)
        if (-not $belongsToFolder) {
            $belongsToFolder = Test-IsPathUnderRoot -CandidatePath $entryGroup -PrimaryRoot $rootFolderPath -AlternateRoot $rootFolderName
        }

        if (-not $belongsToFolder) {
            continue
        }

        $relativeGroup = ''
        if (-not [string]::IsNullOrEmpty($entryGroup)) {
            $relativeGroup = Resolve-RelativePath -FullPath $entryGroup -RootCandidates $rootPathCandidates
            if ($null -eq $relativeGroup) {
                $relativeGroup = ''
            }
        } elseif ($folderRelativePathMap.ContainsKey($entryParentIdString)) {
            $relativeGroup = $folderRelativePathMap[$entryParentIdString]
        }

        $entryName = Get-EntryName -Entry $entry
        if ([string]::IsNullOrEmpty($entryName)) {
            continue
        }

        $entryKey = if ([string]::IsNullOrEmpty($relativeGroup)) { $entryName } else { [System.String]::Concat($relativeGroup, '\\', $entryName) }
        $entryKeyLookup = $entryKey.ToLowerInvariant()

        if ($destinationEntryIndex.ContainsKey($entryKeyLookup)) {
            Write-Verbose "Entry '$entryKey' already exists in vault '$destinationVaultDisplayName'. Skipping."
            continue
        }

        try {
            $entryId = Get-EntryId -Entry $entry
        } catch {
            Write-Warning "Unable to resolve the identifier for entry '$entryName': $($_.Exception.Message)"
            continue
        }

        $entryDetailsResponse = Get-DSEntryDetailsWithFallback -VaultId $SourceVaultId -EntryId $entryId -EntryName $entryName
        if (-not $entryDetailsResponse) {
            Write-Warning "Unable to retrieve details for entry '$entryName' ($entryId): entry could not be found."
            continue
        }

        $connectionEntity = Resolve-ConnectionInfoEntity -EntryDetails $entryDetailsResponse
        if ($null -eq $connectionEntity) {
            Write-Warning "Unable to resolve connection entity for entry '$entryName'."
            continue
        }

        $entryClone = $null
        try {
            $cloneMethod = $connectionEntity.GetType().GetMethod('Clone', [System.Type[]]@())
            if ($cloneMethod) {
                $entryClone = $cloneMethod.Invoke($connectionEntity, @())
            }
        } catch {
            $entryClone = $null
        }

        if ($null -eq $entryClone) {
            $entryClone = $connectionEntity.psobject.Copy().BaseObject
        }

        $parentId = $DestinationRootId
        if (-not [string]::IsNullOrEmpty($relativeGroup)) {
            if (-not $destinationFolderMap.ContainsKey($relativeGroup)) {
                try {
                    $parentId = Ensure-DestinationFolder -RelativePath $relativeGroup -DestinationFolderMap $destinationFolderMap -DestinationVault $DestinationVault -DestinationVaultId $DestinationVaultId -DestinationRootPathCandidates $DestinationRootPathCandidates -DestinationVaultName $destinationVaultDisplayName
                } catch {
                    Write-Warning "Unable to create parent folder '$relativeGroup' in vault '$destinationVaultDisplayName': $($_.Exception.Message)"
                    continue
                }
            } else {
                $parentId = [Guid]$destinationFolderMap[$relativeGroup]
            }
        }

        $groupValue = if ([string]::IsNullOrEmpty($relativeGroup)) { $null } else { $relativeGroup }
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'RepositoryID' -Value $DestinationVaultId
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'RepositoryIDString' -Value $DestinationVaultId.ToString()
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'ParentID' -Value $parentId
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'ParentIDString' -Value $parentId.ToString()
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'ID' -Value ([Guid]::Empty)
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'IDString' -Value ([Guid]::Empty).ToString()
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'OriginalId' -Value ([Guid]::Empty)
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'Version' -Value 0
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'Group' -Value $groupValue
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'GroupMain' -Value $null
        Set-PropertyIfWritable -Object $entryClone -PropertyName 'SplittedGroupMain' -Value $null

        if ($PSCmdlet.ShouldProcess("Vault '$destinationVaultDisplayName'", "Copy entry '$entryKey'")) {
            try {
                New-DSEntryBase -FromRDMConnection $entryClone -ErrorAction Stop | Out-Null
                $destinationEntryIndex[$entryKeyLookup] = $true
            } catch {
                Write-Warning "Unable to copy entry '$entryKey' to vault '$destinationVaultDisplayName': $($_.Exception.Message)"
            }
        }
    }
}

$session = $null
try {
    $session = Connect-DVLSWithAppKey -BaseUri $DVLSUri -AppKey $AppKey -AppSecret $AppSecret

    $vaultsResponse = Get-DSVault -All -ErrorAction Stop
    $vaults = ConvertTo-DSArray (Resolve-DSResponse $vaultsResponse)
    $vaultLookup = @{}
    foreach ($vaultEntry in $vaults) {
        if ($null -eq $vaultEntry) {
            continue
        }

        $name = Get-DSObjectProperty -Object $vaultEntry -Names @('Name', 'DisplayName')
        if ($null -eq $name) {
            continue
        }

        if (-not $vaultLookup.ContainsKey($name)) {
            $vaultLookup[$name] = $vaultEntry
        }
    }

    if (-not $vaultLookup.ContainsKey($SourceVaultName)) {
        throw "Vault '$SourceVaultName' was not found."
    }

    $sourceVault = $vaultLookup[$SourceVaultName]
    $sourceVaultId = Get-VaultId -Vault $sourceVault
    if ($sourceVaultId -eq [Guid]::Empty) {
        throw "Unable to resolve identifier for source vault '$SourceVaultName'."
    }

    $rootFoldersResponse = Get-DSFolders -VaultID $sourceVaultId -ErrorAction Stop
    $rootFolders = ConvertTo-DSArray (Resolve-DSResponse $rootFoldersResponse)
    if (-not $rootFolders) {
        Write-Host "Vault '$SourceVaultName' does not contain any first-level folders to process." -ForegroundColor Yellow
        return
    }

    $allFoldersResponse = Get-DSFolders -VaultID $sourceVaultId -IncludeSubFolders -ErrorAction Stop
    $allFolders = ConvertTo-DSArray (Resolve-DSResponse $allFoldersResponse)
    $allEntriesResponse = Get-DSEntry -VaultID $sourceVaultId -All -ErrorAction Stop
    $allEntries = ConvertTo-DSArray (Resolve-DSResponse $allEntriesResponse)

    foreach ($rootFolder in $rootFolders) {
        if ($null -eq $rootFolder) {
            continue
        }

        $folderName = Get-DSObjectProperty -Object $rootFolder -Names @('Name', 'FolderName')
        if ([string]::IsNullOrWhiteSpace($folderName) -or $folderName -eq '[Root]') {
            continue
        }

        Write-Host "Processing folder '$folderName'..." -ForegroundColor Cyan

        $destinationVault = $null
        if ($vaultLookup.ContainsKey($folderName)) {
            $destinationVault = $vaultLookup[$folderName]
            if ($SkipExistingVaults) {
                Write-Verbose "Skipping folder '$folderName' because vault '$folderName' already exists and SkipExistingVaults is set."
                continue
            }
        } else {
            if ($PSCmdlet.ShouldProcess("Vault '$folderName'", 'Create vault')) {
                try {
                    $createdVaultResponse = New-DSVault -Name $folderName -ErrorAction Stop
                    $destinationVault = $null
                    if ($null -ne $createdVaultResponse) {
                        $destinationVault = Resolve-DSResponse $createdVaultResponse
                        if ($destinationVault -is [System.Collections.IEnumerable] -and $destinationVault -isnot [string]) {
                            $destinationVault = (ConvertTo-DSArray $destinationVault) | Select-Object -First 1
                        }
                    }
                    if (-not $destinationVault) {
                        $allVaultsResponse = Get-DSVault -All -ErrorAction Stop
                        $allVaults = ConvertTo-DSArray (Resolve-DSResponse $allVaultsResponse)
                        $destinationVault = $allVaults | Where-Object {
                            (Get-DSObjectProperty -Object $_ -Names @('Name', 'DisplayName')) -eq $folderName
                        } | Select-Object -First 1
                    }
                    if (-not $destinationVault) {
                        throw "New vault '$folderName' was created but its details could not be retrieved."
                    }
                    $destinationVaultIdTemp = Get-VaultId -Vault $destinationVault
                    if ($destinationVaultIdTemp -eq [Guid]::Empty) {
                        throw "Unable to resolve identifier for newly created vault '$folderName'."
                    }
                    $refreshedVaultResponse = Get-DSVault -VaultID $destinationVaultIdTemp -ErrorAction Stop
                    $destinationVault = Resolve-DSResponse $refreshedVaultResponse
                    if (-not $destinationVault) {
                        throw "Vault '$folderName' could not be reloaded after creation."
                    }
                    $vaultLookup[$folderName] = $destinationVault
                    Write-Verbose "Created vault '$folderName'."
                } catch {
                    Write-Warning "Unable to create vault '$folderName': $($_.Exception.Message)"
                    continue
                }
            } else {
                continue
            }
        }

        $destinationVaultIdResolved = Get-VaultId -Vault $destinationVault
        if ($destinationVaultIdResolved -eq [Guid]::Empty) {
            Write-Warning "Unable to resolve identifier for destination vault '$folderName'."
            continue
        }

        $destinationVaultDisplayName = Get-DSObjectProperty -Object $destinationVault -Names @('Name', 'DisplayName')
        if ([string]::IsNullOrWhiteSpace($destinationVaultDisplayName)) {
            $destinationVaultDisplayName = $folderName
        }
        if ([string]::IsNullOrWhiteSpace($destinationVaultDisplayName)) {
            $destinationVaultDisplayName = $destinationVaultIdResolved.ToString()
        }

        try {
            $destinationRoot = Get-DSRootSessionWithRetry -VaultID $destinationVaultIdResolved
        } catch {
            Write-Warning "Unable to retrieve root session for vault '$destinationVaultDisplayName': $($_.Exception.Message)"
            continue
        }

        if ($null -eq $destinationRoot) {
            Write-Warning "Root session for vault '$destinationVaultDisplayName' returned no data."
            continue
        }

        $destinationRootId = ConvertTo-DSGuid -Value (Get-DSObjectProperty -Object $destinationRoot -Names @('ID', 'Id'))
        if ($destinationRootId -eq [Guid]::Empty) {
            Write-Warning "Invalid root session identifier for vault '$destinationVaultDisplayName'."
            continue
        }

        $destinationRootPathCandidates = @()
        $destinationRootPathCandidates += Get-DSObjectProperty -Object $destinationVault -Names @('Name', 'DisplayName')
        $destinationRootPathCandidates += $destinationVaultDisplayName
        $destinationRootPathCandidates += Get-DSObjectProperty -Object $destinationRoot -Names @('Group', 'GroupPath', 'ParentGroup', 'ParentPath')
        $destinationRootPathCandidates += Get-DSObjectProperty -Object $destinationRoot -Names @('Name', 'FolderName')
        $destinationRootPathCandidates = $destinationRootPathCandidates | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique
        if (-not $destinationRootPathCandidates) {
            $destinationRootPathCandidates = @('')
        }

        try {
            Copy-VaultFolderContent -SourceVaultId $sourceVaultId -RootFolder $rootFolder -AllFolders $allFolders -AllEntries $allEntries -DestinationVault $destinationVault -DestinationVaultId $destinationVaultIdResolved -DestinationRootId $destinationRootId -DestinationRootPathCandidates $destinationRootPathCandidates -DestinationVaultName $destinationVaultDisplayName
            Write-Host "Completed folder '$folderName'." -ForegroundColor Green
        } catch {
            Write-Warning "Failed to copy folder '$folderName': $($_.Exception.Message)"
        }
    }
} catch {
    Write-Error $_
} finally {
    if ($session) {
        Close-DSSession | Out-Null
    }
}




