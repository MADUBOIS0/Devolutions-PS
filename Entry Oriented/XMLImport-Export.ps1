# Verify if module is installed.
if (-not (Get-Module Devolutions.PowerShell -ListAvailable)) {
    Install-Module Devolutions.PowerShell -Scope CurrentUser
}

# Export configuration for session files.
$TemplateExportDirectory = 'C:\Export'
$TemplateExportFileName = 'TemplateExport.xml'
$TemplateExportPath = Join-Path -Path $TemplateExportDirectory -ChildPath $TemplateExportFileName
$TemplateExportFile = $TemplateExportPath

function AuthenticateRDM {
    # Select datasource
    $ds = Get-RDMDataSource -Name "YourDataSourceName"
    Set-RDMCurrentDataSource $ds

    # Select Vault
    $vault = Get-RDMVault "TheVaultToExportImport"
    Set-RDMVault -Vault $vault
}

function ExportSession {
    param(
        [System.Collections.IEnumerable]$Sessions = $script:templateEntries
    )

    if (-not $Sessions) {
        throw "No sessions provided for export. Provide session objects or populate `$templateEntries`."
    }

    $sessionArray = @($Sessions)
    if ($sessionArray.Count -eq 0) {
        throw "Session collection is empty. Nothing to export."
    }

    try {
        if (-not (Test-Path -Path $TemplateExportDirectory -PathType Container)) {
            New-Item -Path $TemplateExportDirectory -ItemType Directory -ErrorAction Stop | Out-Null
        }
    }
    catch {
        throw "Unable to create or access export directory '$TemplateExportDirectory'. $($_.Exception.Message)"
    }

    $activity = 'Exporting Devolutions sessions'
    for ($i = 0; $i -lt $sessionArray.Count; $i++) {
        $session = $sessionArray[$i]
        $sessionName = if ($session -and $session.PSObject.Properties['Name']) { $session.Name } else { $session }
        $percentComplete = [int](((($i + 1) / $sessionArray.Count) * 100))
        Write-Progress -Activity $activity -Status "Queued $sessionName ($($i + 1)/$($sessionArray.Count))" -PercentComplete $percentComplete
    }

    try {
        Export-RDMSession -XML -Sessions $sessionArray -IncludeCredentials -IncludeAttachements -IncludeDocumentation `
            -Path $TemplateExportPath -ErrorAction Stop -ForcePromptAnswer ([System.Windows.Forms.DialogResult]::Yes)
    }
    catch {
        throw "Failed to export sessions to '$TemplateExportPath'. $($_.Exception.Message)"
    }
    finally {
        Write-Progress -Activity $activity -Completed -Status "Processed $($sessionArray.Count) session(s)."
    }
}

function ImportSession {
    if (-not (Test-Path -Path $TemplateExportFile -PathType Leaf)) {
        throw "The export file '$TemplateExportFile' does not exist. Run ExportSession first."
    }

    try {
        Import-RDMSession -Path $TemplateExportFile -SetSession -ErrorAction Stop `
            -ForcePromptAnswer ([System.Windows.Forms.DialogResult]::Yes) -DuplicateAction "Overwrite"
    }
    catch {
        throw "Failed to import sessions from '$TemplateExportFile'. $($_.Exception.Message)"
    }
}
