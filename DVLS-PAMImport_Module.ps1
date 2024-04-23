<# DVLS-PAMImportModule 
This module will be used to massively import DVLS Pam ACcount from an external source.
The source is a preformated CSV File 


********************************************************************************************************
Cheat sheet
ID : ID of the Object
FolderID : ID or the parent Folder
TeamFolderID : ID of the Vault
********************************************************************************************************

#>

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

Function Open-DVLSCsvPamAccountsImport {
    # Opens the csv file specified in the environment variable
    # Returns the content of the csv File dataset
    $csv = Import-Csv $csvPath
    Return $csv
}

Function Import-DVLSPamAccounts {
    # params 
    # CreateMissingVaults : will indicate if we create vaults that are specified in the csv and missing on DVLS
    # CreateMissingFolders : will indicate if we create Folders that are specified in the csv and missing on DVLS
    param(
        [switch]$CreateMissingVaults,
        [switch]$CreateMissingFolders
    )
    # Use the csv to loop through and import accounts

    $DVLSSession = Connect-DVLSWithAppKey
    $dataset = Open-DVLSCSVPamAccountsImport

    # Loop Through the CSV    
    foreach ($rec in $dataset)
    {
        <#
            VAULT        
        #>
        # verify existance of the Vault - Create if needed
        $pamAccTestID = $null
        $vaultName = $rec.VaultName
        $vaultID = ((Get-DSPamFolders).Body.data | where-Object {($_.Name -eq $VaultName) -and ($_.ID -eq $_.TeamFolderID)}).ID
        If ($NULL -eq $vaultID)
        {        
            If ($CreateMissingVaults){
                Write-Host -ForegroundColor Yellow $vaultName " does not exist - Creating $vaultName"
                # Create the Vault
                $vaultID = New-DVLSPAMVault -NewVaultName $vaultName
            }
            else {
                Write-Host -ForegroundColor Yellow $vaultName " does not exist - PAM Account " $rec.Name " will not be imported"
                # break and go to next record of the csv
                continue
            }
        }
        
        <#
            FOLDER and SUB FOLDERS
        #>
        # verify the existance of the Folder        
        # we'll use "\" as a separator in the csv
        # The objective of this codeblock is to find the Real FolderID to be used at the import
        # Also possible to create the missing folders if the switch is on
        $folderPath = $rec.Folder
        $FolderStructure = $folderPath.Split("\")
        if ($folderPath -eq "") {
            $FolderStructure = $NULL
        }
        $parentFolderID = $vaultId    
        for ($i=0; $i -lt $FolderStructure.Count; $i++){
            # At least one level of folder
            $folderName = $FolderStructure[$i]
            # Verify if the Folder exists at the root
            # $folder = ((Get-DSPamFolders).Body.Data) | Where-Object{($_.TeamFolderID -eq $vaultId) -and ($_.FolderID -eq $_.FolderID) -and $_.Name -eq $folderName}
            $folder = ((Get-DSPamFolders).Body.Data) | Where-Object{($_.TeamFolderID -eq $vaultId) -and $_.Name -eq $folderName}
            # when FolderID = TeamFolderID, we have a folder at the root and in the proper vault we've got from previous block            
            If ($folder.count -eq 1){
                # Folder Found in the desired Vault - All good
                $parentFolderID = $folder.ID
                continue
            }
            else{
                # Folder does not exist
                # Create if needed
                if ($CreateMissingFolders){
                    Write-Host -ForegroundColor Yellow "Folder " $folderName " does not exist - Creating $folderName"
                    $parentFolderID = New-DVLSPAMFolder -NewFolderName $folderName -ParentFolderID $parentFolderID
                }
                else {
                    # Account won't be created, folder not found
                    $parentFolderID = $NULL
                    continue
                }
            }
        }
        
        <#
            ACCOUNTS
        #>
        # Now we have the ParentFolderID that ultimately chain links to the vault as well
        # Find the provider ID
        $ProvID = ((Get-DSPamProvider).Body.Data | Where-Object{$_.Label -eq $rec.Provider}).ID
        if ($NULL -eq $ProvID){
            # provider not found
            write-host -ForegroundColor Yellow "Provider" $rec.Provider "cannot be found on DVLS, Account can not be imported"
        }

        # Might be a good idea to protect from duplicates
        $pamAccTestID = ((Get-DSPamAccounts).Body.Data | Where-Object{($_.Username -eq $rec.Username) -and ($_.AdminCredentialID -eq $ProvID)}).ID
        if ($pamAccTestID.count -gt 0)
        {
            Write-Host -ForegroundColor Yellow "Account" $rec.Username "Already Exists with Provider" $rec.Provider "- Cannot Create Account"
        }
        else {
            #New-DSPamAccount -CredentialType $rec."Account Type" -FolderID $parentFolderID -Name $rec.Name -Username $rec.Username -Provider $ProvID
            $pamAccTestID = (New-DVLSPamAccount -accountName $rec.name -Type $rec."Account Type" -folderID $parentFolderID -Username $rec.Username -provID $ProvID).ID

            # we could need to trace back the account to adjust the additional settings that are not processed by new-DSPamAccount
            # DomainName                          : {}
            # DependantComputers                  : {}
            # Protocol                            : Ldap
            
            # $pamAddedAccount.DomainName = @{}
            # $pamAddedAccount.DependantComputers = New-Object -TypeName Devolutions.Server.Pam.Dto.DependantComputer
            # $pamAddedAccount.Protocol = "Ldap"
            # Update-DSPamAccount -PamAccount $pamAddedAccount

            # might need to add the permission part later on for the log message
            Write-Host -ForegroundColor Yellow $rec.Name "successfully Imported"
        }
        
        <#
            PERMISSIONS
        #>
        # Each Roles are defined independently in the CSV File
        # We assume that if they're left empty, it will be inherited
        # When there is a group or a user defined in the file, we use Custom (Override)
        
        if ($pamAccTestID.count -eq 1){
            $permOwners = $rec.PermOwners
            $PermManagers = $rec.PermManagers
            $PermContributors = $rec.PermContributors
            $PermOperators = $rec.PermOperators
            $PermReaders = $rec.PermReaders
            $PermApprovers = $rec.PermApprovers
            $PermLogReaders = $rec.PermLogReaders

            # See if Owners is empty
            If ($permOwners.length -gt 0){
                # Owners are defined, build a String Array of Owners
                [string[]]$secUserOrGroup = $null
                $owners = $permOwners.Split(";")
                foreach($owner in $owners){
                    # Try to find a group or a user                    
                    $groups = (((Get-DSRole -GetAll).Body.data) | Where-Object{$_.Name -eq $owner}).ID
                    $users = (((Get-DSUsers -All).Body.data) | Where-Object{$_.Name -eq $owner}).ID                    
                    # Verify that only one either user or group is found
                    If (($groups.length + $users.length) -eq 1){
                        # Only one correspondance, all good
                        $secUserOrGroup += [string]$groups + [string]$users
                    }
                    elseif (($group.length + $users.length) -eq 0) {
                        # No User or Group found
                        # Log the error :
                        Write-Host -ForegroundColor Yellow "No User or group " $owner " found - cannot set Owner permissions on " $rec.Name
                    }
                    else {
                        Write-Host -ForegroundColor Yellow "More than one " $owner " user or group found - cannot set Owner permissions on " $rec.Name
                    }
                }
                $secToSet = New-DSPamSecurity -Role Owner -Mode Override -UserID $secUserOrGroup
                Set-DVLSPAMAccountPermission -pamAccount $pamAccTestID -pamPermission $secToSet
            }
            else {
                Write-Host -ForegroundColor Yellow "No Owner were defined in the file, Inherited permission will be set on " $rec.Name
            }

            # see if managers is empty
            If ($PermManagers.length -gt 0){
                # Managers are defined, build a String Array of Managers
                [string[]]$secUserOrGroup = $null
                $managers = $PermManagers.Split(";")
                foreach($manager in $managers){
                    # Try to find a group or a user                    
                    $groups = (((Get-DSRole -GetAll).Body.data) | Where-Object{$_.Name -eq $manager}).ID
                    $users = (((Get-DSUsers -All).Body.data) | Where-Object{$_.Name -eq $manager}).ID                    
                    # Verify that only either one user or group is found
                    If (($groups.length + $users.length) -eq 1){
                        # Only one correspondance, all good
                        $secUserOrGroup += [string]$groups + [string]$users
                    }
                    elseif (($group.length + $users.length) -eq 0) {
                        # No User or Group found
                        # Log the error :
                        Write-Host -ForegroundColor Yellow "No User or group " $manager " found - cannot set Manager permissions on " $rec.Name
                    }
                    else {
                        Write-Host -ForegroundColor Yellow "More than one " $manager " user or group found - cannot set Manager permissions on " $rec.Name
                    }
                }
                $secToSet = New-DSPamSecurity -Role Manager -Mode Override -UserID $secUserOrGroup
                Set-DVLSPAMAccountPermission -pamAccount $pamAccTestID -pamPermission $secToSet 
            }
            else {
                Write-Host -ForegroundColor Yellow "No Manager were defined in the file, Inherited permission will be set on " $rec.Name
            }

            # see if contributors is empty
            If ($PermContributors.length -gt 0){
                # contributors are defined, build a String Array of contributors
                [string[]]$secUserOrGroup = $null
                $contributors = $Permcontributors.Split(";")
                foreach($contributor in $contributors){
                    # Try to find a group or a user                    
                    $groups = (((Get-DSRole -GetAll).Body.data) | Where-Object{$_.Name -eq $contributor}).ID
                    $users = (((Get-DSUsers -All).Body.data) | Where-Object{$_.Name -eq $contributor}).ID                    
                    # Verify that only either one user or group is found
                    If (($groups.length + $users.length) -eq 1){
                        # Only one correspondance, all good
                        $secUserOrGroup += [string]$groups + [string]$users
                    }
                    elseif (($group.length + $users.length) -eq 0) {
                        # No User or Group found
                        # Log the error :
                        Write-Host -ForegroundColor Yellow "No User or group " $contributor " found - cannot set contributor permissions on " $rec.Name
                    }
                    else {
                        Write-Host -ForegroundColor Yellow "More than one " $contributor " user or group found - cannot set contributor permissions on " $rec.Name
                    }
                }
                $secToSet = New-DSPamSecurity -Role Contributor -Mode Override -UserID $secUserOrGroup
                Set-DVLSPAMAccountPermission -pamAccount $pamAccTestID -pamPermission $secToSet 
            }
            else {
                Write-Host -ForegroundColor Yellow "No Contributor were defined in the file, Inherited permission will be set on " $rec.Name
            }

            # see if operators is empty
            If ($PermOperators.length -gt 0){
                # operators are defined, build a String Array of operators
                [string[]]$secUserOrGroup = $null
                $operators = $PermOperators.Split(";")
                foreach($operator in $operators){
                    # Try to find a group or a user                    
                    $groups = (((Get-DSRole -GetAll).Body.data) | Where-Object{$_.Name -eq $operator}).ID
                    $users = (((Get-DSUsers -All).Body.data) | Where-Object{$_.Name -eq $operator}).ID                    
                    # Verify that only either one user or group is found
                    If (($groups.length + $users.length) -eq 1){
                        # Only one correspondance, all good
                        $secUserOrGroup += [string]$groups + [string]$users
                    }
                    elseif (($group.length + $users.length) -eq 0) {
                        # No User or Group found
                        # Log the error :
                        Write-Host -ForegroundColor Yellow "No User or group " $operator " found - cannot set operator permissions on " $rec.Name
                    }
                    else {
                        Write-Host -ForegroundColor Yellow "More than one " $operator " user or group found - cannot set operator permissions on " $rec.Name
                    }
                }
                $secToSet = New-DSPamSecurity -Role operator -Mode Override -UserID $secUserOrGroup
                Set-DVLSPAMAccountPermission -pamAccount $pamAccTestID -pamPermission $secToSet 
            }
            else {
                Write-Host -ForegroundColor Yellow "No operator were defined in the file, Inherited permission will be set on " $rec.Name
            }

            # see if readers is empty
            If ($PermReaders.length -gt 0){
            # readers are defined, build a String Array of readers
                [string[]]$secUserOrGroup = $null
                $readers = $PermReaders.Split(";")
                foreach($reader in $readers){
                    # Try to find a group or a user                    
                    $groups = (((Get-DSRole -GetAll).Body.data) | Where-Object{$_.Name -eq $reader}).ID
                    $users = (((Get-DSUsers -All).Body.data) | Where-Object{$_.Name -eq $reader}).ID                    
                    # Verify that only either one user or group is found
                    If (($groups.length + $users.length) -eq 1){
                        # Only one correspondance, all good
                        $secUserOrGroup += [string]$groups + [string]$users
                    }
                    elseif (($group.length + $users.length) -eq 0) {
                        # No User or Group found
                        # Log the error :
                        Write-Host -ForegroundColor Yellow "No User or group " $reader " found - cannot set reader permissions on " $rec.Name
                    }
                    else {
                        Write-Host -ForegroundColor Yellow "More than one " $reader " user or group found - cannot set reader permissions on " $rec.Name
                    }
                }
                $secToSet = New-DSPamSecurity -Role reader -Mode Override -UserID $secUserOrGroup
                Set-DVLSPAMAccountPermission -pamAccount $pamAccTestID -pamPermission $secToSet 
            }
            else {
                Write-Host -ForegroundColor Yellow "No reader were defined in the file, Inherited permission will be set on " $rec.Name
            }

            # see if approvers is empty
            If ($PermApprovers.length -gt 0){
                # approvers are defined, build a String Array of approvers
                [string[]]$secUserOrGroup = $null
                $approvers = $PermApprovers.Split(";")
                foreach($approver in $approvers){
                    # Try to find a group or a user                    
                    $groups = (((Get-DSRole -GetAll).Body.data) | Where-Object{$_.Name -eq $approver}).ID
                    $users = (((Get-DSUsers -All).Body.data) | Where-Object{$_.Name -eq $approver}).ID                    
                    # Verify that only either one user or group is found
                    If (($groups.length + $users.length) -eq 1){
                        # Only one correspondance, all good
                        $secUserOrGroup += [string]$groups + [string]$users
                    }
                    elseif (($group.length + $users.length) -eq 0) {
                        # No User or Group found
                        # Log the error :
                        Write-Host -ForegroundColor Yellow "No User or group " $approver " found - cannot set approver permissions on " $rec.Name
                    }
                    else {
                        Write-Host -ForegroundColor Yellow "More than one " $approver " user or group found - cannot set approver permissions on " $rec.Name
                    }    
                }
                $secToSet = New-DSPamSecurity -Role approver -Mode Override -UserID $secUserOrGroup
                Set-DVLSPAMAccountPermission -pamAccount $pamAccTestID -pamPermission $secToSet 
            }
            else {
                Write-Host -ForegroundColor Yellow "No approver were defined in the file, Inherited permission will be set on " $rec.Name
            }

            # see if logReaders is empty
            If ($PermLogReaders.length -gt 0){
                # logReaders are defined, build a String Array of logReaders
                [string[]]$secUserOrGroup = $null
                $logReaders = $PermLogReaders.Split(";")
                foreach($logReader in $logReaders){
                    # Try to find a group or a user                    
                    $groups = (((Get-DSRole -GetAll).Body.data) | Where-Object{$_.Name -eq $logReader}).ID
                    $users = (((Get-DSUsers -All).Body.data) | Where-Object{$_.Name -eq $logReader}).ID                    
                    # Verify that only either one user or group is found
                    If (($groups.length + $users.length) -eq 1){
                        # Only one correspondance, all good
                        $secUserOrGroup += [string]$groups + [string]$users
                    }
                    elseif (($group.length + $users.length) -eq 0) {
                        # No User or Group found
                        # Log the error :
                        Write-Host -ForegroundColor Yellow "No User or group " $logReader " found - cannot set logReader permissions on " $rec.Name
                    }
                    else {
                        Write-Host -ForegroundColor Yellow "More than one " $logReader " user or group found - cannot set logReader permissions on " $rec.Name
                    }    
                }
                $secToSet = New-DSPamSecurity -Role logReader -Mode Override -UserID $secUserOrGroup
                Set-DVLSPAMAccountPermission -pamAccount $pamAccTestID -pamPermission $secToSet 
            }
            else {
                Write-Host -ForegroundColor Yellow "No logReader were defined in the file, Inherited permission will be set on " $rec.Name
            }
        }

        else {
            Write-Host -ForegroundColor Yellow $pamAccTestID.count " PAM Account(s) found - cannot set permissions on " $rec.Name
        }

    }
}

Function New-DVLSPAMVault {
    param(
        [Parameter(Mandatory=$true)]
        [string]$NewVaultName
    )
    # Create a new Vault
    # Return the ID fo the newly created Vault
    $result = New-DSPamFolder -AsNewVault -Name $NewVaultName
    if ($result.IsSuccess){
        # find the newly created Vault ID
        $newID = (Get-DSPamFolders).Body.data | where-Object {($_.Name -eq $NewVaultName) -and ($_.ID -eq $_.TeamFolderID)}
        Return $newID.ID
    }
    else {        
        Return $NULL
    }
}

Function New-DVLSPAMFolder {
    param(
        [Parameter(Mandatory=$true)]
        [string]$NewFolderName,
        [Parameter(Mandatory=$true)]
        [string]$ParentFolderID
    )
    $result = New-DSPamFolder -Name $NewFolderName -ParentFolderID $ParentFolderID
    if ($result.IsSuccess){
        $newID = (Get-DSPamFolders -IncludeFolder).Body.Data | Where-Object{($_.Name -eq $NewFolderName) -and ($_.FolderID -eq $ParentFolderID)}
        Return $newID.ID
    }
    else {
        Return $NULL
    }   
}

Function New-DVLSPamAccount {
    param(
        [Parameter(Mandatory=$true)]
        [string]$accountName,
        [Parameter(Mandatory=$true)]
        [ValidateSet("AzureADUser","Certificate","Custom","DomainUser","LocalUser","SqlServer","Standalone","Unknown","WindowsLocalAccount")]     
        [string]$Type,
        [Parameter(Mandatory=$true)]
        [string]$folderID,
        [Parameter(Mandatory=$true)]
        [string]$Username,
        [Parameter(Mandatory=$true)]
        [string]$provID
    )
    #  -CredentialType $rec."Account Type" -FolderID $parentFolderID -Name $rec.Name -Username $rec.Username -Provider $ProvID
    New-DSPamAccount -CredentialType $Type -FolderID $FolderID -Name $accountName -Username $userName -Provider $provID
    $ret =((Get-DSPamAccounts).Body.Data | Where-Object{($_.Username -eq $Username) -and ($_.AdminCredentialID -eq $provID)})
    return $ret

}

Function Set-DVLSPAMAccountPermission{
    param(
        [parameter(Mandatory=$true)]
        [string]$pamAccountID,
        [parameter(Mandatory=$true)]
        [Devolutions.Server.ApiWrapper.Models.Pam.Dto.Permission.PamUserPermission[]]$pamPermission
    )

    # Should we handle "Inherited", "Inherited + Custom", or just "Custom"
    # Will have to look throught he Permissions structure DONE 
    # https://devolutions.atlassian.net/wiki/spaces/Support/pages/3796009136/PAM+Permissions+Structure
    $pamAccnt = Get-DSPamAccount -AccountID $pamAccountID
    
    # might need to perform a TRY here
    $r = Update-DSPamAccount -PamAccount $pamAccnt.Data -Security $pamPermission
    return $r}