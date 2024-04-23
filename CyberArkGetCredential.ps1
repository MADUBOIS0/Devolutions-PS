#Fetch the Datasource
Function AuthenticateRDM {
    $ds = Get-RDMDataSource -Name "BreakGlass"
    Set-RDMCurrentDataSource $ds
}

Function GetCyberArk{
    #Select the vault where CyberArk Dashboard is located
    $Vault = Get-RDMRepository -Name "T-Dawgs"
    Set-RDMCurrentRepository $Vault

    #Set the CyberArk entry name
    $CyberArkEntryName = "CyberArk Vault - StandardUser"

    #Fetch the entry
    $Entry = Get-RDMSession | Where-Object {$_.Name -EQ $CyberArkEntryName}

    $T = '1'
}
