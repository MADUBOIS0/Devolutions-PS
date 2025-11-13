Function GetAllEntriesByCustomFieldValueExport {
    [CmdletBinding()]
    param (
        [string]$DataSourceName = "DVLS-02 AZ",
        [ValidateSet('CustomField1Value','CustomField2Value','CustomField3Value','CustomField4Value','CustomField5Value')]
        [string]$CustomFieldProperty = 'CustomField1Value',
        [string]$ExportPath = "C:\Temp\Export.csv"
    )

    $ds = Get-RDMDataSource -Name $DataSourceName
    if (-not $ds) {
        throw "Unable to locate the data source '$DataSourceName'."
    }

    Set-RDMCurrentDataSource $ds

    $vaults = Get-RDMRepository
    $results = @()
    $canRetrievePassword = $null -ne (Get-Command -Name Get-RDMSessionPassword -ErrorAction SilentlyContinue)

    foreach ($v in $vaults) {
        Set-RDMCurrentRepository -Repository $v
        Update-RDMUI

        $sessions = Get-RDMSession
        foreach ($s in $sessions) {
            $customFieldValue = $s.MetaInformation."$CustomFieldProperty"
            if ([string]::IsNullOrWhiteSpace($customFieldValue)) {
                continue
            }

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
                CustomFieldName = $CustomFieldProperty
                CustomFieldValue = $customFieldValue
            }
        }
    }

    $exportDirectory = Split-Path -Path $ExportPath -Parent
    if (-not (Test-Path -LiteralPath $exportDirectory)) {
        New-Item -ItemType Directory -Path $exportDirectory -Force | Out-Null
    }

    if ($results.Count -eq 0) {
        "Name,""Entry Type"",Host,Folder,Tag,Password,CustomFieldName,CustomFieldValue" | Set-Content -Path $ExportPath -Encoding UTF8
        Write-Host "No sessions contained '$CustomFieldProperty'. Created empty export at $ExportPath."
        return
    }

    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($results.Count) entries containing '$CustomFieldProperty' to $ExportPath."
}
