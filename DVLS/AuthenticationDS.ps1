# Environment Variables
# URI of the DVLS Instance
$DVLSURI = ""
# Path of the CSV to import
$csvPath = ""
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