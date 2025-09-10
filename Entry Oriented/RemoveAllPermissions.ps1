#Verify if module is installed.
if(-not (Get-Module Devolutions.PowerShell -ListAvailable)){
        Install-Module Devolutions.PowerShell -Scope CurrentUser
    }
    
# Select datasource
$ds = Get-RDMDataSource -Name "Datasource name in File - Data sources"
Set-RDMCurrentDataSource $ds

#Refresh entries
Update-RDMUI

#Select vault where you want to reset permissions to inherited
$vault = Get-RDMVault "PermissionsTestVault"
Set-RDMVault -Vault $vault

$entries = Get-RDMSession
foreach($entry in $entries){
    $entry.Security.RoleOverride = "Inherited"
    $entry.Security.ViewOverride = "Inherited"
    $entry.Security.ViewRoles = "Inherited"
    Set-RDMSession -Refresh -Session $entry
}

#Refresh to make sure entries in RDM are correct
Update-RDMUI