Function GetAllEntriesByCustomFieldValueExport {
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

    foreach ($v in $vaults) {
        Set-RDMCurrentRepository -Repository $v
        Update-RDMUI

        $sessions = Get-RDMSession
        foreach ($s in $sessions) {
            $customFieldValue = $s.MetaInformation."$CustomFieldProperty"
            if ([string]::IsNullOrWhiteSpace($customFieldValue)) {
                continue
            }

            $results += [pscustomobject]@{
                Name = $s.Name
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
        "Name,CustomFieldName,CustomFieldValue" | Set-Content -Path $ExportPath -Encoding UTF8
        Write-Host "No sessions contained '$CustomFieldProperty'. Created empty export at $ExportPath."
        return
    }

    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($results.Count) entries containing '$CustomFieldProperty' to $ExportPath."
}
