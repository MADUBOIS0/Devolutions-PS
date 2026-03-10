<#
.SYNOPSIS
    Export all entries from one or more RDM vaults to CSV, including metadata and custom fields.
.DESCRIPTION
    Authenticates against a specified data source, iterates over either a single named vault or every vault,
    gathers all entries, and exports their metadata, tags, password (when accessible), and the values of the
    five custom fields to a CSV file.
.PARAMETER DataSourceName
    Name of the RDM data source to connect to before enumerating vaults.
.PARAMETER VaultName
    Specific vault to export; when left blank, the script processes every available vault.
.PARAMETER ExportPath
    Destination CSV path. The directory is created automatically if it does not exist.
#>
Function GetAllEntriesByCustomFieldValueExport {
    [CmdletBinding()]
    param (
        [string]$DataSourceName = "DVLS-02 AZ",    # Target data source name inside RDM
        [string]$VaultName = 'Testing Vault',      # Vault to process (blank = all vaults)
        [string]$ExportPath = "C:\Temp\Export.csv" # Location of the generated CSV
    )

    # Validate and switch to the requested data source.
    $ds = Get-RDMDataSource -Name $DataSourceName
    if (-not $ds) {
        throw "Unable to locate the data source '$DataSourceName'."
    }

    Write-Verbose "Switching to data source '$DataSourceName'."
    Set-RDMCurrentDataSource $ds

    # Determine which vaults to enumerate.
    if ([string]::IsNullOrWhiteSpace($VaultName)) {
        Write-Verbose "No vault name supplied; retrieving all available vaults."
        $vaults = Get-RDMRepository
    } else {
        Write-Verbose "Locating vault '$VaultName'."
        $vault = Get-RDMRepository -Name $VaultName -ErrorAction SilentlyContinue
        if (-not $vault) {
            throw "Unable to locate the vault '$VaultName'."
        }
        $vaults = @($vault)
    }

    if (-not $vaults -or $vaults.Count -eq 0) {
        Write-Verbose "No vaults returned; aborting."
        return
    }

    $results = @() # Accumulator for entries from every vault.
    $canRetrievePassword = $null -ne (Get-Command -Name Get-RDMSessionPassword -ErrorAction SilentlyContinue)
    Write-Verbose ("Password retrieval command {0} present." -f ($(if ($canRetrievePassword) { "is" } else { "is not" })))

    foreach ($v in $vaults) {
        Write-Verbose "Processing vault '$($v.Name)'."
        Set-RDMCurrentRepository -Repository $v
        Update-RDMUI
        Write-Verbose "Repository context set. Gathering sessions."

        $sessions = Get-RDMSession
        Write-Verbose "Retrieved $($sessions.Count) sessions from '$($v.Name)'."
        foreach ($s in $sessions) {
            # Cache custom field values so we only read MetaInformation once.
            $customFieldMap = @{
                CustomField1Value = $s.MetaInformation.CustomField1Value
                CustomField2Value = $s.MetaInformation.CustomField2Value
                CustomField3Value = $s.MetaInformation.CustomField3Value
                CustomField4Value = $s.MetaInformation.CustomField4Value
                CustomField5Value = $s.MetaInformation.CustomField5Value
            }

            # Normalize tag data. Entries might expose either TagList or Tags.
            $tagSource = $null
            if ($s.PSObject.Properties.Name -contains 'TagList') {
                $tagSource = $s.TagList
            } elseif ($s.PSObject.Properties.Name -contains 'Tags') {
                $tagSource = $s.Tags
            }

            if ($tagSource -is [string] -and [string]::IsNullOrWhiteSpace($tagSource)) {
                $tagSource = $null
            }

            $tagValue = $null
            if ($tagSource) {
                if ($tagSource -is [System.Collections.IEnumerable] -and -not ($tagSource -is [string])) {
                    $tagValue = ($tagSource | Where-Object { $_ } | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ } | Sort-Object -Unique) -join '; '
                } else {
                    $tagValue = $tagSource.ToString()
                }
            }

            # Retrieve passwords only when the cmdlet exists and suppress failures.
            $password = ''
            if ($canRetrievePassword) {
                try {
                    $retrievedPassword = Get-RDMSessionPassword -ID $s.ID -AsPlainText
                    if ($null -ne $retrievedPassword) {
                        $password = $retrievedPassword
                    }
                } catch {
                    Write-Verbose "Unable to retrieve password for entry '$($s.Name)': $($_.Exception.Message)"
                }
            }

            $results += [pscustomobject][ordered]@{
                Name = $s.Name
                'Entry Type' = $s.ConnectionType
                Host = $s.Host
                Folder = $s.Group
                Tag = $tagValue
                Password = $password
                CustomField1Value = $customFieldMap.CustomField1Value
                CustomField2Value = $customFieldMap.CustomField2Value
                CustomField3Value = $customFieldMap.CustomField3Value
                CustomField4Value = $customFieldMap.CustomField4Value
                CustomField5Value = $customFieldMap.CustomField5Value
            }
        }

        Write-Verbose "Completed vault '$($v.Name)'."
    }

    $exportDirectory = Split-Path -Path $ExportPath -Parent
    if (-not (Test-Path -LiteralPath $exportDirectory)) {
        # Ensure the export folder is present.
        Write-Verbose "Creating export directory '$exportDirectory'."
        New-Item -ItemType Directory -Path $exportDirectory -Force | Out-Null
    }

    if ($results.Count -eq 0) {
        Write-Verbose "No sessions matched criteria; writing header-only CSV."
        "Name,""Entry Type"",Host,Folder,Tag,Password,CustomField1Value,CustomField2Value,CustomField3Value,CustomField4Value,CustomField5Value" | Set-Content -Path $ExportPath -Encoding UTF8
        Write-Host "No sessions found in vault '$VaultName'. Created empty export at $ExportPath."
        return
    }

    Write-Verbose "Exporting $($results.Count) session records to '$ExportPath'."
    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($results.Count) entries from vault '$VaultName' to $ExportPath."
}
