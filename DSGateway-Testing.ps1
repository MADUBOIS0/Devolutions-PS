Import-Module Devolutions.PowerShell -RequiredVersion 2025.1.5

# Environment Variables
# URI of the DVLS Instance
$DVLSURI = ""
# App key and secret - Must be admin in DVLS

$AppKey = ""
$AppSecret = ""


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