<# The goal of this script is to showcase you can obtain the name of an entry and it's password through PowerShell. #>

#Import Module
Import-Module -Name Devolutions.PowerShell -RequiredVersion 2025.2.6

#Authenticate using RDM
function AuthenticateRDM {
    
    $ds = Get-RDMDataSource -Name "DVLS-02 AZ" #Change this to your datasource name in RDM.
    Set-RDMCurrentDataSource $ds
}

function GetWebsiteInformation {
    
    $Vault = Get-RDMRepository -Name 'Testing vault'
    Set-RDMRepository $Vault
    $Sessions = Get-RDMSession | Where-Object {($_.ConnectionType -eq 'WebBrowser')} #Only filter for website entries.
        ForEach ($s in $Sessions ){
            Write-Host $s.Name #Return the name of the entry
            Write-Host (Get-RDMEntryPassword -ID $s.ID -AsPlainText) #Return the entry password.
        }
    Update-RDMUI    
}
