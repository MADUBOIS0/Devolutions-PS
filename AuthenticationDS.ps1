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

Connect-DVLSWithAppkey

Function GetPamAccounts{
    $PAMAccount = Get-DSPamAccount -AccountID "1901de29-5214-4f8f-81ea-4bb954343857"
    $PamProviders = Get-DSPamProviders
    #$PamRotationReport = Get-DSPam
    $var = Get-DSPamAccount -AsLegacyResponse
    #| Where-Object {$_.Name -eq "maduboisT0"}
    $tt
}