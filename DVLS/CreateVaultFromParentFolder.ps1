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
    .\CreateVaultFromParentFolder.ps1 -DVLSUri 'https://dvls.contoso.com' -AppKey 'my-app-key' -AppSecret 'my-app-secret' -SourceVaultName 'Default'
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

function Normalize-GroupPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $normalized = $Path.Replace('/', '\').Trim()
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '\\+', '\')

    return $normalized.Trim('\')
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
        return $name
    }

    return "$groupPath\$name"
}

function Get-FolderId {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Folder
    )

    $value = Get-DSObjectProperty -Object $Folder -Names @('ID', 'Id', 'FolderID', 'FolderId')
    if ($null -eq $value -or [string]::IsNullOrEmpty($value.ToString())) {
        throw "Unable to resolve folder identifier."
    }

    return [Guid]$value
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

    $value = Get-DSObjectProperty -Object $Entry -Names @('ConnectionType', 'ConnexionTypeString')
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
    if ($null -eq $value -or [string]::IsNullOrEmpty($value.ToString())) {
        throw "Unable to resolve entry identifier."
    }

    return [Guid]$value
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath,
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $normalizedFull = Normalize-GroupPath -Path $FullPath
    $normalizedRoot = Normalize-GroupPath -Path $RootPath

    if ([string]::IsNullOrEmpty($normalizedRoot)) {
        return $normalizedFull
    }

    if ($normalizedFull -eq $normalizedRoot) {
        return ''
    }

    $prefix = "$normalizedRoot\"
    if ($normalizedFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedFull.Substring($prefix.Length)
    }

    return $null
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

function Ensure-DestinationFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,
        [Parameter(Mandatory = $true)]
        [Hashtable]$DestinationFolderMap,
        [Parameter(Mandatory = $true)]
        [psobject]$DestinationVault
    )

    if ([string]::IsNullOrEmpty($RelativePath)) {
        return [Guid]::Empty
    }

    if ($DestinationFolderMap.ContainsKey($RelativePath)) {
        return [Guid]$DestinationFolderMap[$RelativePath]
    }

    $parentPath = Get-ParentPath -Path $RelativePath
    $folderName = ($RelativePath.Split('\\') | Select-Object -Last 1)

    $newFolderParameters = @{
        VaultID = [Guid]$DestinationVault.ID
        Name    = $folderName
    }

    if (-not [string]::IsNullOrEmpty($parentPath)) {
        $newFolderParameters['Group'] = $parentPath
    }

    if ($PSCmdlet.ShouldProcess("Vault '$($DestinationVault.Name)'", "Create folder '$RelativePath'")) {
        $createdFolder = New-DSFolder @newFolderParameters -ErrorAction Stop
        if ($createdFolder -and $createdFolder.ID) {
            $DestinationFolderMap[$RelativePath] = [Guid]$createdFolder.ID
            return [Guid]$createdFolder.ID
        }
    }

    throw "Folder '$RelativePath' could not be created."
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
        [psobject]$DestinationVault
    )

    $rootFolderPath = Get-FolderFullPath -Folder $RootFolder
    if ([string]::IsNullOrEmpty($rootFolderPath)) {
        $name = Get-DSObjectProperty -Object $RootFolder -Names @('Name', 'FolderName')
        throw "Folder path for '$name' could not be resolved."
    }

    $foldersToProcess = New-Object System.Collections.Generic.List[psobject]
    $foldersToProcess.Add($RootFolder) | Out-Null

    foreach ($candidate in $AllFolders) {
        $candidatePath = Get-FolderFullPath -Folder $candidate
        if ([string]::IsNullOrEmpty($candidatePath)) {
            continue
        }

        if ($candidatePath -eq $rootFolderPath -or $candidatePath.StartsWith("$rootFolderPath\\", [System.StringComparison]::OrdinalIgnoreCase)) {
            $foldersToProcess.Add($candidate) | Out-Null
        }
    }

    $destinationFolderMap = @{}
    $destinationFolderMap[''] = [Guid]::Empty

    try {
        $existingDestinationFolders = Get-DSFolders -VaultID ([Guid]$DestinationVault.ID) -IncludeSubFolders -ErrorAction Stop
        foreach ($existing in $existingDestinationFolders) {
            $existingPath = Get-FolderFullPath -Folder $existing
            if ([string]::IsNullOrEmpty($existingPath)) {
                continue
            }

            $destinationFolderMap[$existingPath] = [Guid](Get-FolderId -Folder $existing)
        }
    } catch {
        Write-Verbose "Destination folders could not be preloaded: $($_.Exception.Message)"
    }

    $orderedFolders = $foldersToProcess | Sort-Object {
        $path = Get-FolderFullPath -Folder $_
        return (Normalize-GroupPath -Path $path).Length
    }

    foreach ($folder in $orderedFolders) {
        $folderPath = Get-FolderFullPath -Folder $folder
        if ($folderPath -eq $rootFolderPath) {
            continue
        }

        $relativePath = Get-RelativePath -FullPath $folderPath -RootPath $rootFolderPath
        if ($null -eq $relativePath) {
            continue
        }

        if ($destinationFolderMap.ContainsKey($relativePath)) {
            continue
        }

        try {
            $createdFolderId = Ensure-DestinationFolder -RelativePath $relativePath -DestinationFolderMap $destinationFolderMap -DestinationVault $DestinationVault
            $destinationFolderMap[$relativePath] = $createdFolderId
        } catch {
            Write-Warning "Unable to create folder '$relativePath' in vault '$($DestinationVault.Name)': $($_.Exception.Message)"
        }
    }

    $destinationEntryIndex = @{}
    try {
        $existingEntries = Get-DSEntry -VaultID ([Guid]$DestinationVault.ID) -All -ErrorAction Stop
        foreach ($existingEntry in $existingEntries) {
            $entryGroup = Get-EntryGroupPath -Entry $existingEntry
            $entryName = Get-EntryName -Entry $existingEntry
            if ([string]::IsNullOrEmpty($entryName)) {
                continue
            }

            $entryKey = if ([string]::IsNullOrEmpty($entryGroup)) { $entryName } else { "$entryGroup\\$entryName" }
            if (-not [string]::IsNullOrEmpty($entryKey)) {
                $destinationEntryIndex[$entryKey.ToLowerInvariant()] = $true
            }
        }
    } catch {
        Write-Verbose "Destination entries could not be preloaded: $($_.Exception.Message)"
    }

    foreach ($entry in $AllEntries) {
        $connectionType = Get-EntryConnectionType -Entry $entry
        if ($connectionType -eq 'Folder') {
            continue
        }

        $entryGroup = Get-EntryGroupPath -Entry $entry
        if ([string]::IsNullOrEmpty($entryGroup)) {
            continue
        }

        if ($entryGroup -ne $rootFolderPath -and -not $entryGroup.StartsWith("$rootFolderPath\\", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $relativeGroup = Get-RelativePath -FullPath $entryGroup -RootPath $rootFolderPath
        if ($null -eq $relativeGroup) {
            continue
        }

        $entryName = Get-EntryName -Entry $entry
        if ([string]::IsNullOrEmpty($entryName)) {
            continue
        }

        $entryKey = if ([string]::IsNullOrEmpty($relativeGroup)) { $entryName } else { "$relativeGroup\\$entryName" }
        $entryKeyLookup = $entryKey.ToLowerInvariant()

        if ($destinationEntryIndex.ContainsKey($entryKeyLookup)) {
            Write-Verbose "Entry '$entryKey' already exists in vault '$($DestinationVault.Name)'. Skipping."
            continue
        }

        try {
            $entryId = Get-EntryId -Entry $entry
        } catch {
            Write-Warning "Unable to resolve the identifier for entry '$entryName': $($_.Exception.Message)"
            continue
        }

        try {
            $entryDetails = Get-DSEntry -VaultID $SourceVaultId -EntryId $entryId -AsRDMConnection -ErrorAction Stop
        } catch {
            Write-Warning "Unable to retrieve details for entry '$entryName' ($entryId): $($_.Exception.Message)"
            continue
        }

        $entryClone = $entryDetails.Clone()
        $parentId = [Guid]::Empty

        if (-not [string]::IsNullOrEmpty($relativeGroup)) {
            if (-not $destinationFolderMap.ContainsKey($relativeGroup)) {
                try {
                    $parentId = Ensure-DestinationFolder -RelativePath $relativeGroup -DestinationFolderMap $destinationFolderMap -DestinationVault $DestinationVault
                } catch {
                    Write-Warning "Unable to create parent folder '$relativeGroup' in vault '$($DestinationVault.Name)': $($_.Exception.Message)"
                    continue
                }
            } else {
                $parentId = [Guid]$destinationFolderMap[$relativeGroup]
            }
        }

        $entryClone.RepositoryID = [Guid]$DestinationVault.ID
        $entryClone.ParentID = $parentId
        $entryClone.ID = [Guid]::Empty
        $entryClone.OriginalId = [Guid]::Empty
        $entryClone.Version = 0
        $entryClone.Group = if ([string]::IsNullOrEmpty($relativeGroup)) { $null } else { $relativeGroup }
        $entryClone.GroupMain = $null
        $entryClone.SplittedGroupMain = $null

        if ($PSCmdlet.ShouldProcess("Vault '$($DestinationVault.Name)'", "Copy entry '$entryKey'")) {
            try {
                New-DSEntryBase -FromRDMConnection $entryClone -ErrorAction Stop | Out-Null
                $destinationEntryIndex[$entryKeyLookup] = $true
            } catch {
                Write-Warning "Unable to copy entry '$entryKey' to vault '$($DestinationVault.Name)': $($_.Exception.Message)"
            }
        }
    }
}

$session = $null
try {
    $session = Connect-DVLSWithAppKey -BaseUri $DVLSUri -AppKey $AppKey -AppSecret $AppSecret

    $vaults = Get-DSVault -All -ErrorAction Stop
    $vaultLookup = @{}
    foreach ($vault in $vaults) {
        if ($null -ne $vault.Name -and -not $vaultLookup.ContainsKey($vault.Name)) {
            $vaultLookup[$vault.Name] = $vault
        }
    }

    if (-not $vaultLookup.ContainsKey($SourceVaultName)) {
        throw "Vault '$SourceVaultName' was not found."
    }

    $sourceVault = $vaultLookup[$SourceVaultName]
    $sourceVaultId = [Guid]$sourceVault.ID

    $rootFolders = Get-DSFolders -VaultID $sourceVaultId -ErrorAction Stop
    if (-not $rootFolders) {
        Write-Host "Vault '$SourceVaultName' does not contain any first-level folders to process." -ForegroundColor Yellow
        return
    }

    $allFolders = Get-DSFolders -VaultID $sourceVaultId -IncludeSubFolders -ErrorAction Stop
    $allEntries = Get-DSEntry -VaultID $sourceVaultId -All -ErrorAction Stop

    foreach ($rootFolder in $rootFolders) {
        $folderName = Get-DSObjectProperty -Object $rootFolder -Names @('Name', 'FolderName')
        if ([string]::IsNullOrWhiteSpace($folderName)) {
            continue
        }

        Write-Host "Processing folder '$folderName'..." -ForegroundColor Cyan

        $destinationVault = $null
        if ($vaultLookup.ContainsKey($folderName)) {
            $destinationVault = $vaultLookup[$folderName]
            if ($SkipExistingVaults) {
                Write-Verbose "Skipping folder '$folderName' because vault '$folderName' already exists."
                continue
            }
        } else {
            if ($PSCmdlet.ShouldProcess("Vault '$folderName'", 'Create vault')) {
                try {
                    $destinationVault = New-DSVault -Name $folderName -ErrorAction Stop
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

        try {
            Copy-VaultFolderContent -SourceVaultId $sourceVaultId -RootFolder $rootFolder -AllFolders $allFolders -AllEntries $allEntries -DestinationVault $destinationVault
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
