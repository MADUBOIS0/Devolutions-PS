<#
.SYNOPSIS
    Splits first-level folders from a source RDM vault into separate vaults using only RDM cmdlets.
.DESCRIPTION
    For each first-level folder (ConnectionType "Group" where Name equals Group) found in the specified source vault,
    the script exports all sessions contained in that folder (including subfolders, attachments, documentation, and
    credentials) to a temporary .rdm file. It then switches to the destination data source, ensures that a vault with
    the same name exists (creating it when needed), and imports the sessions. The source vault remains unchanged.
.PARAMETER SourceVaultName
    Name of the source RDM vault to process.
.PARAMETER SourceDataSourceName
    Optional data source name that hosts the source vault. Defaults to the currently selected data source.
.PARAMETER DestinationDataSourceName
    Optional destination data source name. Defaults to the source data source if omitted.
.PARAMETER TempFolder
    Optional working directory used to store temporary export files. When omitted, a unique folder under the system
    temp directory is created.
.PARAMETER ExportPassword
    Optional secure string password used to protect the export files. A random password is generated when omitted.
.PARAMETER ExportPasswordPlainText
    Optional plain text password that is converted to a secure string.
.PARAMETER SkipExistingVaults
    Skips processing for folders whose destination vault already exists.
.PARAMETER KeepTempFiles
    Keeps the temporary export files on disk instead of deleting them at the end.
.EXAMPLE
    .\RDMCreateVaultFromParentFolder.ps1 -SourceVaultName "Default" -SourceDataSourceName "Production" -Verbose
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceVaultName,

    [Parameter()]
    [string]$SourceDataSourceName,

    [Parameter()]
    [string]$DestinationDataSourceName,

    [Parameter()]
    [string]$TempFolder,

    [Parameter()]
    [SecureString]$ExportPassword,

    [Parameter()]
    [string]$ExportPasswordPlainText,

    [Parameter()]
    [switch]$SkipExistingVaults,

    [Parameter()]
    [switch]$KeepTempFiles
)

Import-Module Devolutions.PowerShell -RequiredVersion 2025.2.6 -ErrorAction Stop

function Get-RDMDataSourceOrCurrent {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $current = Get-RDMCurrentDataSource
        if (-not $current) {
            throw "No current RDM data source is selected. Specify SourceDataSourceName."
        }
        return $current
    }

    $ds = Get-RDMDataSource -Name $Name
    if (-not $ds) {
        throw "RDM data source '$Name' was not found."
    }

    return $ds
}

function Get-RDMRepositoryByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return Get-RDMRepository | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Ensure-Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Normalize-FileName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Name.ToCharArray()) {
        if ($invalid -contains $char) { [void]$builder.Append('_') } else { [void]$builder.Append($char) }
    }

    $result = $builder.ToString()
    if ([string]::IsNullOrWhiteSpace($result)) {
        return 'RDMExport'
    }

    return $result
}

function Get-TopLevelFolders {
    [CmdletBinding()]
    param()

    return Get-RDMSession | Where-Object { $_.ConnectionType -eq 'Group' -and $_.Name -eq $_.Group }
}

function Get-FolderSessions {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Folder)

    $folderPath = if ([string]::IsNullOrWhiteSpace($Folder.Group)) { $Folder.Name } else { $Folder.Group }
    $prefix = $folderPath + '\\'

    return Get-RDMSession -IncludeSubFolders | Where-Object {
        ($_.ConnectionType -eq 'Group' -and $_.ID -eq $Folder.ID) -or
        ($_.Group -eq $folderPath) -or
        ($_.Group -like ($prefix + '*'))
    }
}

function Ensure-DestinationVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VaultName,
        [Parameter()][switch]$SkipExisting
    )

    $existing = Get-RDMRepositoryByName -Name $VaultName
    if ($existing) {
        if ($SkipExisting) {
            Write-Verbose "Vault '$VaultName' already exists. Skipping per SkipExistingVaults."
            return $null
        }

        Write-Verbose "Vault '$VaultName' already exists. Reusing it."
        return $existing
    }

    Write-Verbose "Creating vault '$VaultName'."
    return New-RDMRepository -Name $VaultName -Description "Created by RDMCreateVaultFromParentFolder" -ForcePromptAnswer Yes
}

$originalDataSource = Get-RDMCurrentDataSource
$originalVault = Get-RDMCurrentVault

$sourceDataSource = Get-RDMDataSourceOrCurrent -Name $SourceDataSourceName
if ([string]::IsNullOrWhiteSpace($DestinationDataSourceName)) {
    $destinationDataSource = $sourceDataSource
} else {
    $destinationDataSource = Get-RDMDataSourceOrCurrent -Name $DestinationDataSourceName
}

if ($PSBoundParameters.ContainsKey('ExportPasswordPlainText')) {
    $ExportPassword = ConvertTo-SecureString -String $ExportPasswordPlainText -AsPlainText -Force
}

if (-not $ExportPassword) {
    $generatedPassword = [Guid]::NewGuid().ToString('N')
    $ExportPassword = ConvertTo-SecureString -String $generatedPassword -AsPlainText -Force
    Write-Verbose "Generated export password automatically."
}

$temporaryRoot = if ([string]::IsNullOrWhiteSpace($TempFolder)) {
    Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("RDMCreateVaultFromParent_{0}" -f ([Guid]::NewGuid().ToString('N')))
} else {
    $TempFolder
}
Ensure-Directory -Path $temporaryRoot
$removeTempFolder = -not $KeepTempFiles

$results = @()

try {
    Set-RDMCurrentDataSource -DataSource $sourceDataSource | Out-Null

    $sourceVault = Get-RDMRepositoryByName -Name $SourceVaultName
    if (-not $sourceVault) {
        throw "Source vault '$SourceVaultName' was not found in data source '$($sourceDataSource.Name)'."
    }

    Set-RDMCurrentVault -Repository $sourceVault | Out-Null

    $topLevelFolders = Get-TopLevelFolders
    if (-not $topLevelFolders) {
        Write-Warning "No first-level folders were found in vault '$SourceVaultName'."
        return
    }

    foreach ($folder in $topLevelFolders) {
        $folderName = $folder.Name
        Write-Verbose "Processing folder '$folderName'."

        if (-not ($PSCmdlet.ShouldProcess("Vault '$folderName' in data source '$($destinationDataSource.Name)'", "Create or update vault and copy sessions"))) {
            continue
        }

        Set-RDMCurrentDataSource -DataSource $sourceDataSource | Out-Null
        Set-RDMCurrentVault -Repository $sourceVault | Out-Null

        $folderSessions = Get-FolderSessions -Folder $folder
        if (-not $folderSessions) {
            Write-Verbose "Folder '$folderName' does not contain any sessions. Skipping."
            $results += [pscustomobject]@{ Folder = $folderName; Status = 'Skipped (empty folder)' }
            continue
        }

        $exportFileName = Normalize-FileName -Name $folderName
        $exportPath = Join-Path -Path $temporaryRoot -ChildPath ("{0}.rdm" -f $exportFileName)

        Write-Verbose "Exporting folder '$folderName' to '$exportPath'."
        Export-RDMSession -XML -Path $exportPath -Sessions $folderSessions -Password $ExportPassword -IncludeCredentials -IncludeAttachements -IncludeDocumentation -IncludeFavorite -ForcePromptAnswer Yes

        Set-RDMCurrentDataSource -DataSource $destinationDataSource | Out-Null

        $destinationVault = Ensure-DestinationVault -VaultName $folderName -SkipExisting:$SkipExistingVaults.IsPresent
        if ($null -eq $destinationVault) {
            $results += [pscustomobject]@{ Folder = $folderName; Status = 'Skipped (vault existed)' }
            if (-not $KeepTempFiles) { Remove-Item -LiteralPath $exportPath -ErrorAction SilentlyContinue }
            continue
        }

        Set-RDMCurrentVault -Repository $destinationVault | Out-Null

        try {
            Write-Verbose "Importing sessions from '$exportPath' into vault '$folderName'."
            Import-RDMSession -Path $exportPath -Password $ExportPassword -DuplicateAction Skip -ForcePromptAnswer Yes | Out-Null
            $results += [pscustomobject]@{ Folder = $folderName; Status = 'Copied' }
        } catch {
            Write-Warning "Failed to import folder '$folderName': $($_.Exception.Message)"
            $results += [pscustomobject]@{ Folder = $folderName; Status = 'Failed to import' }
        }

        if (-not $KeepTempFiles) {
            Remove-Item -LiteralPath $exportPath -ErrorAction SilentlyContinue
        }
    }
}
finally {
    if ($originalDataSource) {
        try { Set-RDMCurrentDataSource -DataSource $originalDataSource | Out-Null } catch {}
    }

    if ($originalVault) {
        try { Set-RDMCurrentVault -Repository $originalVault | Out-Null } catch {}
    }

    if ($removeTempFolder -and (Test-Path -LiteralPath $temporaryRoot)) {
        try { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force } catch {}
    }
}

if ($results) {
    $results | Format-Table -AutoSize | Out-String | Write-Verbose
}
