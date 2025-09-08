Import-Module Devolutions.PowerShell -RequiredVersion 2025.1.5

# Environment Variables
# URI of the DVLS Instance
$DVLSURI = "https://dvls-02.devolutions.services"
# App key and secret - Must be admin in DVLS

$AppKey = "b3fba317-69c2-4959-a286-4c6cc29826d8"
$AppSecret = "8AShx5kvOpPPAhFhZpcMNRYp24mXsSW8yREAdrSvw0rVNvS71Uh0vGgDAeIrCkmZ"


Function Connect-DVLSWithAppKey {
    # Function to connect to DVLS using an Administrator
    # Returns an active DVLS connection using the appKey / secret
    [securestring]$secAppSecret = ConvertTo-SecureString $AppSecret -AsPlainText -Force
    [pscredential]$credObject = New-Object System.Management.Automation.PSCredential ($AppKey, $secAppSecret)
    
    $DSSession = New-DSSession -BaseUri $DVLSURI -AsApplication -Credential $credObject 
    return $DSSession

}

Connect-DVLSWithAppkey

$vGet = Get-DSGateway -GatewayID '2634027e-dc1b-476f-b03a-db0a937776e5'
$vTest = Test-DSGateway -GatewayID '2634027e-dc1b-476f-b03a-db0a937776e5'
$Run = (Get-DSGateway -GatewayID '2634027e-dc1b-476f-b03a-db0a937776e5').Health
$f