Import-Module Devolutions.PowerShell -RequiredVersion 2025.1.4

# Environment Variables
# URI of the DVLS Instance
$DVLSURI = "https://dvls-02.devolutions.services"
# Path of the CSV to import
$csvPath = ""
# App key and secret - Must be admin in DVLS

$AppKey = "b3fba317-69c2-4959-a286-4c6cc29826d8"
$AppSecret = "kMuklGlwDGPzsASq6RSa0ZRDCBYMPu4WC1xI5cYhHhTWe1fK4F11QTWrKaGmTXac"


Function Connect-DVLSWithAppKey {
    # Function to connect to DVLS using an Administrator
    # Returns an active DVLS connection using the appKey / secret
    [securestring]$secAppSecret = ConvertTo-SecureString $AppSecret -AsPlainText -Force
    [pscredential]$credObject = New-Object System.Management.Automation.PSCredential ($AppKey, $secAppSecret)
    
    $DSSession = New-DSSession -BaseUri $DVLSURI -AsApplication -Credential $credObject 
    return $DSSession

}
Connect-DVLSWithAppKey

#Initialize list of all the regular users
$ListRegularUsers = Get-DSUser -All

#PAM Vault ID
$PAMVaultID = "0b818fb0-3281-44bd-983f-e98addb8157d"

#Get PAM Accounts in PAM vault.
$PAMAccountsList = Get-DSPamAccount -VaultID $PAMVaultID

foreach ($PAMAccount in $PAMAccountsList) {
    
    #Update-DSPAMAccount -PAMAccount $PAMAccount
     
    #Get username of PAM entry
    $fullName = $PAMAccount.name  # "DSinghSA"
    
    #Remove the SA from the username and store in regularUserName.
    $regularUserName = $fullName -replace 'SA$', ''

    #Does the standard user exist, if equal to 1 user, apply permission, otherwise ignore.
    $StandardUserExists = (@($ListRegularUsers | Where-Object { $_.name -like "$regularUserName*" }).Count -eq 1)
    If($StandardUserExists){
        $CurrentEntry = Get-DSEntriesPermissions -EntryID $PAMAccount.id
        $ff
    }


}
