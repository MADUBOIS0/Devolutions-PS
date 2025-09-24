function Split-FirstLevelFolderToNewVaults{
    param(
        [switch] $SkipExport,
        [switch] $CreateRDMDatasource
    )

    # Ensure both application keys have administrative rights

    # Configure the first DVLS connection
    $DVLSName1 = "" # Name of the data source. Example: "Production"
    $DVLSURI1 = "" # DVLS FQDN (only needed when the data source is not defined inside RDM). Example: dvls-01.mydomain.loc
    $AppKey1 = "" # Documentation : https://docs.devolutions.net/server/web-interface/administration/security-management/applications/
    $AppSecret1 = "" # Documentation : https://docs.devolutions.net/server/web-interface/administration/security-management/applications/
    $SourceVault = "" # Source vault containing the clients.
    # Parameters for the second DVLS connection
    $DVLSName2 = $DVLSName1
    $DVLSURI2 = $DVLSURI1
    $AppKey2 = $AppKey1
    $AppSecret2 = $AppSecret1

    $exportPath = "C:\temp\"

    # Ensure both data sources are accessible:
    if ($CreateRDMDatasource){
        if ($null -eq (Get-RDMDataSource | Where-Object{$_.Name -eq "DVLS-Source"})){
            Write-Host "Creating Data Source DVLS-Source"
            New-RDMDataSource -DVLS -Name $DVLSName1 -ScriptingTenantID $AppKey1 -ScriptingApplicationPassword $AppSecret1 -Server $DVLSURI1 -SetDatasource
            Write-Host "Data Source DVLS-Source created"
        }
        else {
            Write-Host "Data Source DVLS-Source already exists"
        }
        if ($null -eq (Get-RDMDataSource | Where-Object{$_.Name -eq "DVLS-Target"})){
            Write-Host "Creating Data Source DVLS-Target"
            New-RDMDataSource -DVLS -Name $DVLSName2 -ScriptingTenantID $AppKey2 -ScriptingApplicationPassword $AppSecret2 -Server $DVLSURI2 -SetDatasource 
            Write-Host "Data Source DVLS-Target created"
        }
        else {
            Write-Host "Data Source DVLS-Target already exists"
        }
    }

    Set-RDMCurrentDataSource -DataSource (Get-RDMDataSource -Name $DVLSName1)
    Update-RDMUI
    Set-RDMCurrentVault -Repository (Get-RDMRepository -Name $SourceVault)

    # Extract first-level folders
    $1stLevel = Get-RDMSession | Where-Object{($_.ConnectionType -eq "Group") -and ($_.Name -eq $_.Group)}
    $pwd = ConvertTo-SecureString -String "abc123$" -AsPlainText -Force

    # Export folder data and vault names 
    if (-not $SkipExport){
        foreach($folder in $1stLevel)
        {
            $name = $folder.group        
            Write-host "Exporting $name"
            $s = Get-RDMSession -IncludeSubFolders | Where-Object{$_.Group -like $name}
            $filename = "$exportPath$name.rdm"
            $filename = $filename.Replace("/", "-")
            Export-RDMSession -XML -Path $filename -Sessions $s -Password $pwd -IncludeCredentials
            Write-host "$name Exported" 
        }
    }

    Set-RDMCurrentDataSource -DataSource (Get-RDMDataSource -Name $DVLSName2)
    # Create target vaults and import data
    foreach ($vault in $1stLevel)
    {    
        $name = $vault.group
        # Create a new vault if necessary        
        $NewVault = Get-RDMRepository | where-object {$_.Name -eq "$name"}
        
        If ($null -eq $NewVault){
            Write-Host "$name does not exist - creating $name"
            $NewVault = New-RDMRepository -Description "automatically created" -Name $name -ForcePromptAnswer Yes 
            Set-RDMRepository -Repository $NewVault
            Write-Host "$name created"
        }
        Update-RDMUI        
        Set-RDMCurrentVault -Repository (Get-RDMVault -Name "$name")
        Update-RDMUI
        # Import content into the target vault
        $filename = "$exportPath$name.rdm"
        write-host "Importing  $filename"
        try {
            Import-RDMSession -Path $filename -Password $pwd -KeepID -Verbose -DuplicateAction Overwrite -SetSession -ForcePromptAnswer Yes
            write-host "$filename imported"
        }
        catch {
            <#Run this block if a terminating exception occurs#>
            write-host "Error while importing $filename"            
        }
    }
}










