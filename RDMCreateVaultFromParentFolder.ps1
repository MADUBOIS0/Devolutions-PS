<#
.SYNOPSIS
    Creates dedicated vaults from the first-level folders of a source RDM vault using RDM cmdlets only.
.DESCRIPTION
    For each first-level folder found in the specified source vault, the script creates (or reuses) a destination RDM
    vault with the same name and copies every entry contained in that folder (including subfolders) into the new vault.
    The original folder remains untouched in the source vault. The operation relies exclusively on the
    Devolutions.PowerShell RDM cmdlets (e.g., Get-RDMSession, New-RDMRepository).
.PARAMETER SourceVaultName
    Name of the source RDM vault whose first-level folders should be exported.
.PARAMETER SourceDataSourceName
    Optional data source name that contains the source vault. Defaults to the currently selected data source.
.PARAMETER DestinationDataSourceName
    Optional destination data source name. Defaults to the source data source when omitted.
.PARAMETER TempFolder
    Optional working directory used to store temporary export files. A unique folder under the system temporary path
    is created when omitted.
.PARAMETER ExportPassword
    Secure string password used to protect export files. A random password is generated when omitted.
.PARAMETER ExportPasswordPlainText
    Convenience parameter that lets you supply the export password as plain text. The value is converted to a secure
    string internally.
.PARAMETER SkipExistingVaults
    Skips folders whose destination vault already exists.
.PARAMETER KeepTempFiles
    Prevents deletion of the temporary export folder.

.EXAMPLE
    .\RDMCreateVaultFromParentFolder.ps1 -SourceVaultName "Default" -SourceDataSourceName "Production" -Verbose
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceVaultName = "ACustomerVault",

    [Parameter()]
    [string]$SourceDataSourceName = "DVLS-02 AZ",

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
        [string]
    )

    if ([string]::IsNullOrWhiteSpace()) {
         = Get-RDMCurrentDataSource
        if (-not ) {
            throw "No current RDM data source is selected. Specify SourceDataSourceName."
        }

        return 
    }

     = Get-RDMDataSource -Name 
    if (-not ) {
        throw "RDM data source '' was not found."
    }

    return 
}

function Ensure-Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Normalize-FileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Name.ToCharArray()) {
        if ($invalid -contains $char) {
            [void]$builder.Append('_')
        } else {
            [void]$builder.Append($char)
        }
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
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Folder
    )

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
        [Parameter(Mandatory = $true)]
        [string]$VaultName,
        [Parameter(Mandatory = $true)]
        [switch]$SkipExisting
    )

    $existing = Get-RDMRepository -Name $VaultName
    if ($existing) {
        if ($SkipExisting) {
            Write-Verbose "Vault '$VaultName' already exists. Skipping per SkipExistingVaults."
            return $null
        }

        Write-Verbose "Vault '$VaultName' already exists. Reusing."
        return $existing
    }

    Write-Verbose "Creating vault '$VaultName'."
    return New-RDMRepository -Name $VaultName -Description "Created by RDMCreateVaultFromParentFolder" -ForcePromptAnswer Yes
}



$originalDataSource = Get-RDMCurrentDataSource
$originalVault = Get-RDMCurrentVault

$sourceDataSource = Get-RDMDataSourceOrCurrent -Name $SourceDataSourceName
$destinationDataSource = Get-RDMDataSourceOrCurrent -Name ($DestinationDataSourceName ?? $SourceDataSourceName)

if ($PSBoundParameters.ContainsKey('ExportPasswordPlainText')) {
    $ExportPassword = ConvertTo-SecureString -String $ExportPasswordPlainText -AsPlainText -Force
}

if (-not $ExportPassword) {
    $generatedPassword = [Guid]::NewGuid().ToString('N')
    $ExportPassword = ConvertTo-SecureString -String $generatedPassword -AsPlainText -Force
    Write-Verbose "Generated export password automatically."
}

$temporaryRoot = if ([string]::IsNullOrWhiteSpace($TempFolder)) {
    $folder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("RDMCreateVaultFromParent_{0}" -f ([Guid]::NewGuid().ToString('N')))
    $folder
} else {
    $TempFolder
}

Ensure-Directory -Path $temporaryRoot
$removeTempFolder = -not $KeepTempFiles

$results = @()

try {
    Set-RDMCurrentDataSource $sourceDataSource | Out-Null
    Update-RDMUI

    $sourceVault = Get-RDMRepository -Name $SourceVaultName
    if (-not $sourceVault) {
        throw "Source vault '$SourceVaultName' was not found in data source '$($sourceDataSource.Name)'."
    }

    Set-RDMCurrentVault -Repository $sourceVault | Out-Null
    Update-RDMUI

    $topLevelFolders = Get-TopLevelFolders
    if (-not $topLevelFolders) {
        Write-Warning "No first-level folders were found in vault '$SourceVaultName'."
        return
    }

    foreach ($folder in $topLevelFolders) {
        $folderName = $folder.Name
        Write-Verbose "Processing folder '$folderName'."

        if (-not ($PSCmdlet.ShouldProcess("Vault '$folderName' in data source '$($destinationDataSource.Name)'", "Create or update and copy entries"))) {
            continue
        }

        Set-RDMCurrentDataSource $sourceDataSource | Out-Null
        Update-RDMUI
        Set-RDMCurrentVault -Repository $sourceVault | Out-Null
        Update-RDMUI

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

        Set-RDMCurrentDataSource $destinationDataSource | Out-Null
        Update-RDMUI

        $destinationVault = Ensure-DestinationVault -VaultName $folderName -SkipExisting:$SkipExistingVaults.IsPresent
        if ($null -eq $destinationVault) {
            $results += [pscustomobject]@{ Folder = $folderName; Status = 'Skipped (vault existed)' }
            if (-not $KeepTempFiles) { Remove-Item -LiteralPath $exportPath -ErrorAction SilentlyContinue }
            continue
        }

        Set-RDMCurrentVault -Repository $destinationVault | Out-Null
        Update-RDMUI

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
        try {
            Set-RDMCurrentDataSource $originalDataSource | Out-Null
            Update-RDMUI
        } catch {}
    }

    if ($originalVault) {
        try {
            Set-RDMCurrentVault -Repository $originalVault | Out-Null
            Update-RDMUI
        } catch {}
    }

    if ($removeTempFolder -and (Test-Path -LiteralPath $temporaryRoot)) {
        try {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        } catch {}
    }
}

if ($results) {
    $results | Format-Table -AutoSize | Out-String | Write-Verbose
}





