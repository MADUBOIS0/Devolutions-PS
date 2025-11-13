Function GetAllEntriesByCustomFieldValueExport {
    param (
        [string]$DataSourceName = "DVLS-02 AZ",
        [string]$CustomFieldValue = "CustomerName",
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

        $sessions = Get-RDMSession | Where-Object { $_.MetaInformation.CustomField1Value -eq $CustomFieldValue }
        foreach ($s in $sessions) {
            $results += [pscustomobject]@{
                Name = $s.Name
                CustomField1Value = $s.MetaInformation.CustomField1Value
            }
        }
    }

    $exportDirectory = Split-Path -Path $ExportPath -Parent
    if (-not (Test-Path -LiteralPath $exportDirectory)) {
        New-Item -ItemType Directory -Path $exportDirectory -Force | Out-Null
    }

    if ($results.Count -eq 0) {
        "Name,CustomField1Value" | Set-Content -Path $ExportPath -Encoding UTF8
        Write-Host "No sessions matched '$CustomFieldValue'. Created empty export at $ExportPath."
        return
    }

    $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($results.Count) entries to $ExportPath."
}
