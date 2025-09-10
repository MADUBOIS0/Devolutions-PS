#You need to import the Devolutions PowerShell module for RDM.
Import-Module -Name Devolutions.PowerShell -RequiredVersion 2025.2.6

# You must authenticate once in your PS terminal lifetime before using the Hashicorp function.
Function AuthenticateRDM {
    $ds = Get-RDMDataSource -Name "DVLS-02 AZ" #Change the RDM Datasource to the correct DS Name in RDM.
    Set-RDMCurrentDataSource $ds
}
Function Hashicorp{

    #Vault where you want to change your Hashicorp IDs. You must run the script for every vault.
    $Vault = Get-RDMRepository -Name "Testing Vault"
    Set-RDMCurrentRepository $Vault

    #This is the HashiCorpID of your newly copied Hashicorp entry.
    $HashicorpName = "Hashicorp"
    $HashicorpID = (Get-RDMEntry -Type "Credential" -Name $HashicorpName).ID

    #This is the initial ID of the Hashicorp entry that's still set in the session entries.
    $LegacyHashiCorpID = "dd7672af-e43c-4ecc-ab52-03503cf18a03"

    #Loop through all entries where the CredentialConnectionID is equal to the legacy ID and replace with the new ID.
    $Sessions = Get-RDMSession | Where-Object {($_.CredentialConnectionID -eq $LegacyHashiCorpID)}
    ForEach ($s in $Sessions ){
        $s.CredentialConnectionID = $HashicorpID
        Set-RDMSession -Refresh -Session $s
     }
     Update-RDMUI
}