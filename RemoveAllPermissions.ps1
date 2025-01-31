#Verifier si module est installer.
if(-not (Get-Module Devolutions.PowerShell -ListAvailable)){
        Install-Module Devolutions.PowerShell -Scope CurrentUser
    }
    
# Selectionner data source.
$ds = Get-RDMDataSource -Name "Datasource name in File - Data sources"
Set-RDMCurrentDataSource $ds

#Refresh des entrées#
Update-RDMUI

#Sélectionner la vault ou appliquer permissions
$vault = Get-RDMVault "PermissionsTestVault"
Set-RDMVault -Vault $vault

$entries = Get-RDMSession
foreach($entry in $entries){
    $entry.Security.RoleOverride = "Inherited"
    $entry.Security.ViewOverride = "Inherited"
    $entry.Security.ViewRoles = "Inherited"
    Set-RDMSession -Refresh -Session $entry
}

#Un autre refresh pour être certain d'avoir bonne info dans UI
Update-RDMUI