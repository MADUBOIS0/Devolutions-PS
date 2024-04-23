#Goal: Showcase that it's possible to launch a CyberArk Dashboard from a PS Script.

#Fetch the Datasource (Run this before calling other methods)
Function AuthenticateRDM {
    $ds = Get-RDMDataSource -Name "BreakGlass" #Change the RDM Datasource to the correct DS Name in RDM.
    Set-RDMCurrentDataSource $ds
}

#Fetch the CyberArk Dashboard Entry information
Function GetCyberArkEntry{

    #Vault where CyberArk Dashboard is located
    $VaultName = "MarcVault"
    #Name of the CyberArk DashBoard Entry
    $CyberArkEntryName = "CyberArk Vault - StandardUser"

    #Select the vault where CyberArk Dashboard is located
    $Vault = Get-RDMRepository -Name $VaultName
    Set-RDMCurrentRepository $Vault

    #Get the information of the entry and return it
    $Entry = Get-RDMEntry | Where-Object {$_.Name -EQ $CyberArkEntryName}
    Return $Entry
}


#Open a CyberArk DashBoard
Function OpenDashBoard{

    #Get the CyberArk Dashboard by calling function GetCyberArkEntry
    $DashBoardEntry = GetCyberArkEntry
    Open-RDMSession -ID $DashBoardEntry.ID
}