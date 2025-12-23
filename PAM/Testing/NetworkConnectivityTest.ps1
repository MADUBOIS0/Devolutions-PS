[CmdletBinding()]
Param (
	[Parameter(Mandatory = $True)]
	[ValidateNotNullOrEmpty()]
	[String]$Hosts,
	[Parameter(Mandatory = $True)]
	[ValidateNotNullOrEmpty()]
	[String]$LoginUsername,
	[Parameter(Mandatory = $True)]
	[ValidateNotNullOrEmpty()]
	[SecureString]$LoginPassword,
	[Parameter(Mandatory = $False)]
	[Boolean]$ExcludeDisabledAccountsInDiscovery,
	[Parameter(Mandatory = $False)]
	[String]$HostsLDAPSearchFilter
)

Function Get-ExceptionStack
{
	Param ([System.Exception]$Exception)

	$Stack = New-Object System.Collections.Generic.List[string]
	while ($Exception)
	{
		[void]$Stack.Add($Exception.ToString())
		$Exception = $Exception.InnerException
	}

	$Stack.ToArray()
}

Function Add-ErrorRecordDetails
{
	Param (
		[System.Collections.Generic.List[string]]$Errors,
		[String]$Context,
		[System.Management.Automation.ErrorRecord]$Record
	)

	Function Normalize-ErrorText
	{
		Param ([String]$Text)

		if ([String]::IsNullOrEmpty($Text))
		{
			return $Text
		}

		return ($Text -replace "(\r\n|\r|\n)", " | ")
	}

	$Prefix = ""
	if ($Context)
	{
		$Prefix = "$Context "
	}

	if ($Record.Exception)
	{
		[void]$Errors.Add("${Prefix}ErrorType: $($Record.Exception.GetType().FullName)")
		[void]$Errors.Add("${Prefix}Message: $(Normalize-ErrorText $Record.Exception.Message)")

		if ($Record.Exception.HResult)
		{
			[void]$Errors.Add(("{0}HResult: 0x{1:X8}" -f $Prefix, $Record.Exception.HResult))
		}
	}

	if ($Record.FullyQualifiedErrorId)
	{
		[void]$Errors.Add("${Prefix}FullyQualifiedErrorId: $($Record.FullyQualifiedErrorId)")
	}

	if ($Record.CategoryInfo)
	{
		[void]$Errors.Add("${Prefix}CategoryInfo: $($Record.CategoryInfo.Category) | $($Record.CategoryInfo.Reason) | $($Record.CategoryInfo.TargetName) | $($Record.CategoryInfo.TargetType)")
	}

	if ($Record.ErrorDetails -and $Record.ErrorDetails.Message)
	{
		[void]$Errors.Add("${Prefix}ErrorDetails: $(Normalize-ErrorText $Record.ErrorDetails.Message)")
	}

	if ($Record.Exception)
	{
		$Stack = Get-ExceptionStack -Exception $Record.Exception
		foreach ($Entry in $Stack)
		{
			[void]$Errors.Add("${Prefix}Exception: $(Normalize-ErrorText $Entry)")
		}
	}
}

Function Add-NetConnectionSummary
{
	Param (
		[System.Collections.Generic.List[string]]$Details,
		[String]$Label,
		$TestResult
	)

	if (-not $TestResult)
	{
		[void]$Details.Add("${Label}: Test-NetConnection returned no data.")
		return
	}

	$SummaryParts = New-Object System.Collections.Generic.List[string]
	[void]$SummaryParts.Add("TcpTestSucceeded=$($TestResult.TcpTestSucceeded)")

	if ($null -ne $TestResult.RemoteAddress)
	{
		[void]$SummaryParts.Add("RemoteAddress=$($TestResult.RemoteAddress)")
	}
	if ($null -ne $TestResult.RemotePort)
	{
		[void]$SummaryParts.Add("RemotePort=$($TestResult.RemotePort)")
	}
	if ($null -ne $TestResult.SourceAddress)
	{
		[void]$SummaryParts.Add("SourceAddress=$($TestResult.SourceAddress)")
	}
	if ($null -ne $TestResult.InterfaceAlias)
	{
		[void]$SummaryParts.Add("InterfaceAlias=$($TestResult.InterfaceAlias)")
	}
	if ($null -ne $TestResult.PingSucceeded)
	{
		[void]$SummaryParts.Add("PingSucceeded=$($TestResult.PingSucceeded)")
	}

	[void]$Details.Add(("{0}: {1}" -f $Label, ($SummaryParts -join "; ")))
}

Function Test-HostConnectivity
{
	Param (
		[String]$Hostname,
		[PSCredential]$Credential
	)

	$Errors = New-Object System.Collections.Generic.List[string]
	$ConnectivityDetails = New-Object System.Collections.Generic.List[string]
	$Result = [PSCustomObject]@{
		HostName = $Hostname
		PingSucceeded = $False
		WinRMHttpOpen = $False
		WinRMSslOpen = $False
		AuthenticationSucceeded = $False
		Errors = ""
	}

	try
	{
		$Resolved = [System.Net.Dns]::GetHostAddresses($Hostname)
		if ($Resolved -and $Resolved.Length -gt 0)
		{
			$ResolvedList = $Resolved | ForEach-Object { $_.IPAddressToString } | Sort-Object -Unique
			[void]$ConnectivityDetails.Add("DNS: " + ($ResolvedList -join ", "))
		}
		else
		{
			[void]$ConnectivityDetails.Add("DNS: No addresses resolved.")
		}
	}
	catch
	{
		Add-ErrorRecordDetails -Errors $Errors -Context "DNS" -Record $_
	}

	try
	{
		$PingDetails = Test-Connection -ComputerName $Hostname -Count 1 -ErrorAction Stop
		$Result.PingSucceeded = $True
		if ($PingDetails)
		{
			$FirstPing = $PingDetails | Select-Object -First 1
			[void]$ConnectivityDetails.Add("Ping: Success (Address=$($FirstPing.Address), ResponseTimeMs=$($FirstPing.ResponseTime))")
		}
	}
	catch
	{
		$Result.PingSucceeded = $False
		Add-ErrorRecordDetails -Errors $Errors -Context "Ping" -Record $_
	}

	$HttpTest = Test-NetConnection -ComputerName $Hostname -Port 5985 -WarningAction SilentlyContinue
	$SslTest = Test-NetConnection -ComputerName $Hostname -Port 5986 -WarningAction SilentlyContinue
	$Result.WinRMHttpOpen = [bool]$HttpTest.TcpTestSucceeded
	$Result.WinRMSslOpen = [bool]$SslTest.TcpTestSucceeded
	Add-NetConnectionSummary -Details $ConnectivityDetails -Label "WinRM HTTP 5985" -TestResult $HttpTest
	Add-NetConnectionSummary -Details $ConnectivityDetails -Label "WinRM HTTPS 5986" -TestResult $SslTest

	if (-not ($Result.PingSucceeded -or $Result.WinRMHttpOpen -or $Result.WinRMSslOpen))
	{
		[void]$Errors.Add("No network connectivity to $Hostname (ICMP and WinRM ports 5985/5986 failed).")
		foreach ($Detail in $ConnectivityDetails)
		{
			[void]$Errors.Add("Connectivity: $Detail")
		}
		$Result.Errors = ($Errors.ToArray() -join " | ")
		return $Result
	}

	$Session = $null
	try
	{
		if (Get-Command Test-WSMan -ErrorAction SilentlyContinue)
		{
			try
			{
				if ($Result.WinRMSslOpen)
				{
					$Wsman = Test-WSMan -ComputerName $Hostname -UseSSL -Credential $Credential -ErrorAction Stop
				}
				else
				{
					$Wsman = Test-WSMan -ComputerName $Hostname -Credential $Credential -ErrorAction Stop
				}
				if ($Wsman)
				{
					[void]$ConnectivityDetails.Add("WSMan: ProtocolVersion=$($Wsman.ProtocolVersion), ProductVersion=$($Wsman.ProductVersion)")
				}
			}
			catch
			{
				Add-ErrorRecordDetails -Errors $Errors -Context "WSMan" -Record $_
			}
		}

		if ($Result.WinRMSslOpen)
		{
			$Session = New-PSSession -ComputerName $Hostname -Credential $Credential -UseSSL -ErrorAction Stop
		}
		else
		{
			$Session = New-PSSession -ComputerName $Hostname -Credential $Credential -ErrorAction Stop
		}

		Invoke-Command -Session $Session -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop | Out-Null
		$Result.AuthenticationSucceeded = $True
	}
	catch
	{
		Add-ErrorRecordDetails -Errors $Errors -Context "Authentication" -Record $_
	}
	finally
	{
		if ($Session)
		{
			$Session | Remove-PSSession -ErrorAction SilentlyContinue
		}
	}

	if (-not $Result.AuthenticationSucceeded)
	{
		foreach ($Detail in $ConnectivityDetails)
		{
			[void]$Errors.Add("Connectivity: $Detail")
		}
	}

	$Result.Errors = ($Errors.ToArray() -join " | ")
	return $Result
}

Try
{
	$Credential = New-Object System.Management.Automation.PSCredential @($LoginUsername, $LoginPassword)
	$HostsArray = $Hosts -split "[ ,;]"

	Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
	Import-Module NetTCPIP

	if (($HostsArray.Count -eq 1) -and ((Test-NetConnection $HostsArray[0] -Port 636).TcpTestSucceeded))
	{
		$DomainFQDN = $HostsArray[0]
		$ADSI = $null

		Try
		{
			$ADSI = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DomainFQDN`:636", $Credential.UserName, $Credential.GetNetworkCredential().Password) -ErrorAction Stop
			[void]$ADSI.ToString()
		}
		catch [System.Management.Automation.RuntimeException]
		{
			Write-Error "Unable to connect to $DomainFQDN"
		}
		catch
		{
			Write-Error $error[0].Exception.ToString()
		}

		if ($ADSI -and ($ADSI.distinguishedName -ne ""))
		{
			$Searcher = New-Object -TypeName System.DirectoryServices.DirectorySearcher($ADSI)
			$Searcher.Filter = "(&(objectclass=computer)"
			$Searcher.Filter += "(!useraccountcontrol:1.2.840.113556.1.4.804:=2)"
			$Searcher.Filter += "(!userAccountControl:1.2.840.113556.1.4.803:=8192)"
			$Searcher.Filter += "(!serviceprincipalname=*MSClusterVirtualServer*)"
			if ($HostsLDAPSearchFilter)
			{
				$Searcher.Filter += $HostsLDAPSearchFilter
			}
			$Searcher.Filter += ")"

			$DomainComputers = $Searcher.FindAll()
			if ($DomainComputers.Count -gt 0)
			{
				$HostsArray.Clear()
				$HostsArray = @()
				foreach ($Computer in $DomainComputers)
				{
					$HostsArray += $Computer.Properties['dnshostname']
				}
			}
		}
	}

	$Results = $HostsArray | ForEach-Object {
		$Hostname = $_.Trim()

		if ($Hostname -eq $null -or $Hostname -eq "")
		{
			return
		}

		return Test-HostConnectivity -Hostname $Hostname -Credential $Credential
	}

	return $Results
}
catch
{
	Write-Error $error[0].Exception.ToString()
}
