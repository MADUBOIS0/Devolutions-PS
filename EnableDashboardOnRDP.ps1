if(-not (Get-Module Devolutions.PowerShell -ListAvailable)){
    Install-Module Devolutions.PowerShell -Scope CurrentUser
}

# Adapt the data source name
$ds = Get-RDMDataSource -Name "Yourdatasourcename"
Set-RDMCurrentDataSource $ds

#loop into all vaults, if the entry is an RDP session, enable the dashboard, save changes.

$vaults = Get-RDMVault
foreach ($vault in $vaults){
    Set-RDMCurrentRepository $vault
    $session = Get-RDMSession
	Foreach ($s in $session | Where-Object {$_.ConnectionType -eq 'RDPConfigured'} )
		{
			$s.ConnectUsingDashboardOnDoubleClick = 'True'
			Set-RDMSession -Session $session
		}
	}