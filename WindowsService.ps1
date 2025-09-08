#requires -Version 7
#

<#
.SYNOPSIS
Updates the password for a specified service account and optionally restarts the service on a remote system.

.DESCRIPTION
This script updates the service account password on a specified endpoint. It supports both domain and local user accounts and can handle multiple services. If specified, it can also restart the services after updating the password.

.PARAMETER Endpoint
Specifies the target endpoint where the service(s) are running. This should be the hostname or IP address of the remote system.

.PARAMETER EndpointUserName
Specifies the username used to authenticate against the endpoint. This should be an account with permissions to modify service settings.

.PARAMETER EndpointPassword
Specifies the password for the EndpointUserName as a secure string.

.PARAMETER AccountUserName
Specifies the service account username whose password needs updating. This parameter must be a flat username without domain information.

.PARAMETER NewPassword
Specifies the new password for the service account as a secure string.

.PARAMETER AccountUserNameDomain
Optional. Specifies the domain of the service account in FQDN format if the account is a domain account.

.PARAMETER ServiceName
Optional. Specifies the name of the service that needs the service account password updated. If not provided, all services running under the specified account will be updated.

.PARAMETER RestartService
Optional. Specifies whether to restart the service after updating the password. Acceptable values are 'yes' to restart the service, or an empty string to leave the service running without restarting.

.EXAMPLE
PS C:\\> .\\script.ps1 -Endpoint 'server01' -EndpointUserName 'administrator' -EndpointPassword (ConvertTo-SecureString 'Passw0rd!' -AsPlainText -Force) -AccountUserName 'svc_account' -NewPassword (ConvertTo-SecureString 'N3wPassw0rd!' -AsPlainText -Force) -AccountUserNameDomain 'domain.local' -ServiceName 'MyService' -RestartService 'yes'

This example updates the password for the 'svc_account' user on the 'domain.local' domain, specifically for 'MyService' on 'server01', and restarts the service after the update.

.NOTES
This script uses CIM for remote operations. Ensure WinRM is enabled and that the provided credentials have the necessary administrative rights on the remote system.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Endpoint,
    
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EndpointUserName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [securestring]$EndpointPassword,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern(
        '^\w+$',
        ErrorMessage = 'You must provide the AccountUserName parameter as a flat name like "user"; not domain\user, et al. To specify a domain, use the AccountUserNameDomain parameter.'
    )]
    [string]$AccountUserName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [securestring]$NewPassword,

    [Parameter()]
    [string]$AccountUserNameDomain,

    [Parameter()]
    [string]$ServiceName,

    [Parameter()]
    [ValidateSet('yes', '')]
    [string]$RestartService
)

# Output the script parameters and the current user running the script
Write-Output -InputObject "Running script with parameters: $($PSBoundParameters | Out-String) as [$($env:USERNAME)]"

if ($AccountUserNameDomain -and $AccountUserNameDomain -notmatch '^\w+\.\w+$') {
    throw 'When using the AccountUserNameDomain parameter, you must provide the domain as an FQDN (domain.local)'
}

#region Functions
function newCredential([string]$UserName, [securestring]$Password) {
    New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $UserName, $Password
}

function testIsOnDomain([string]$ComputerName,[pscredential]$Credential) {
    (Get-CimInstance -ClassName win32_computersystem -ComputerName $ComputerName -Credential $Credential).PartOfDomain
}

function decryptPassword {
    param(
        [securestring]$Password
    )
    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        ## Clear the decrypted password from memory
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function updateServiceUserPassword {
    param(
        $ServiceInstance,
        [string]$UserName,
        [securestring]$Password,
        [string]$ComputerName,
        [pscredential]$Credential
    )    

    Invoke-CimMethod -InputObject $ServiceInstance -MethodName Change -Arguments @{
        StartName     = $UserName
        StartPassword = decryptPassword($Password)
    } -ComputerName $ComputerName -Credential $Credential
}

function GetServiceAccountNames {
    param(
        $UserName,
        $Domain = '.'
    )

    if (!$PSBoundParameters.ContainsKey('Domain')) {
        ## local account
        @(
            "$Domain\$Username" ## domain\user
        )
    } else {
        ## Domain account with domain as FQDN
        @(
            "$Username@$Domain", ## user@domain.local
            "$($Domain.split('.')[0])\$Username" ## domain\user
        )
    }
}

function ValidateUserAccountPassword {
    [CmdletBinding()]
    param(
        [string]$UserName,
        [string]$Domain,
        [securestring]$Password,
        [string]$ComputerName
    )

    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement

        if ($Domain) {
            $context = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Domain, $Domain)
        } else {
            $context = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Machine, $ComputerName)
        }
    
        $context.ValidateCredentials($UserName, (decryptPassword($Password)))
    } catch {
        Write-Error "An error occurred: $_"
    } finally {
        if ($context) {
            $context.Dispose()
        }
    }
}
#endregion

# Create a new PSCredential object using the provided EndpointUserName and EndpointPassword
$credential = newCredential $EndpointUserName $EndpointPassword

if ($AccountUserNameDomain -and -not (testIsOnDomain -ComputerName $Endpoint -Credential $credential)) {
    throw "The AccountUserNameDomain parameter was used and the host is not on a domain. For local accounts, do not use the AccountUserNameDomain parameter."
}

## Ensure the password is valid
$valUserAcctParams = @{
    UserName     = $AccountUserName
    Password     = $NewPassword
    ComputerName = $Endpoint
}
if ($AccountUserNameDomain) {
    $valUserAcctParams.Domain = $AccountUserNameDomain
}
$validatePwResult = ValidateUserAccountPassword @valUserAcctParams
if (!$validatePwResult) {
    throw "The password for user account [$($AccountUserName)] is invalid. Did you mean to provide a domain account? If so, use the AccountUserNameDomain parameter."
}

$getSrvAccountNamesParams = @{
    UserName = $AccountUserName
}
if ($AccountUserNameDomain) {
    $getSrvAccountNamesParams.Domain = $AccountUserNameDomain
}
[array]$serviceAccountNames = GetServiceAccountNames @getSrvAccountNamesParams
$startNameCimQuery = "(StartName = '{0}')" -f ($serviceAccountNames -join "' OR StartName = '") ## (StartName = 'user@domain.local' OR StartName = 'domain\\user')

if (-not $ServiceName) {
    $cimFilter = $startNameCimQuery
} else {
    $cimFilter = "(Name='{0}') AND {1}" -f ($ServiceName -split ',' -join "' OR Name='"), $startNameCimQuery
}
$cimFilter = $cimFilter.replace('\\', '\\\\')
    
$serviceInstances = Get-CimInstance -ClassName Win32_Service -Filter $cimFilter -ComputerName $Endpoint -Credential $credential
if (-not $serviceInstances) {
    throw "No services found on [{0}] running as [{1}] could be found." -f $Endpoint, $serviceAccountNames[0]
}

$results = foreach ($servInst in $serviceInstances) {
    try {
        $updateResult = updateServiceUserPassword -ServiceInstance $servInst -Username $serviceAccountNames[0] -Password $NewPassword -ComputerName $Endpoint -Credential $credential
        if ($updateResult.ReturnValue -ne 0) {
            throw "Password update for service [{0}] failed with return value [{1}]" -f $servInst.Name, $updateResult.ReturnValue
        }
        if ($RestartService -eq 'yes' -and $servInst.State -eq 'Running') {
            Invoke-CimMethod -InputObject $servInst -MethodName StopService -ComputerName $Endpoint -Credential $credential | Out-Null
            Invoke-CimMethod -InputObject $servInst -MethodName StartService -ComputerName $Endpoint -Credential $credential | Out-Null
        }
        $true
    } catch {
        Write-Error -Message $_.Exception.Message
    }
}
@($results).Count -eq @($serviceInstances).Count
