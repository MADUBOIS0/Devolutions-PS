function Split-FirstLevelFolderToNewVaults{
    param(
        [switch] $SkipExport,
        [switch] $CreateRDMDatasource
    )

    # ensure that both app key are admin

    # connect the first server
    $DVLSName1 = ""
    $DVLSURI1 = ""
    $AppKey1 = ""
    $AppSecret1 = ""
    $SourceVault = "ParentVault"
    # Connect the second server
    $DVLSName2 = "ALPHA"
    $DVLSURI2 = $DVLSURI1
    $AppKey2 = $AppKey1
    $AppSecret2 = $AppSecret1

    $exportPath = "c:\temp\split\split_"

    # ensure that both datasource are accessible:
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

    # Extract FirstLevel of folders
    $1stLevel = Get-RDMSession | Where-Object{($_.ConnectionType -eq "Group") -and ($_.Name -eq $_.Group)}
    $pwd = ConvertTo-SecureString -String "abc123$" -AsPlainText -Force

    # export files and vault names 
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
    # create target vaults and import
    foreach ($vault in $1stLevel)
    {    
        $name = $vault.group
        #create new vault        
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
        #import
        $filename = "$exportPath$name.rdm"
        write-host "Importing  $filename"
        try {
            Import-RDMSession -Path $filename -Password $pwd -KeepID -Verbose -DuplicateAction Overwrite -SetSession -ForcePromptAnswer Yes
            write-host "$filename imported"
        }
        catch {
            <#Do this if a terminating exception happens#>
            write-host "Error while importing $filename"            
        }
    }
}