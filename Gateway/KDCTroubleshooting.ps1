<# 
Returns whether the *current* session was established with Kerberos, based on the 4624 event for the current LogonId.
Output has: KerberosLikely (True/False/Null), Reason, and matched Event details.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-CurrentLogonIdHex {
    # Get the current token's AuthenticationId (LUID) via TokenStatistics
    $src = @"
using System;
using System.Runtime.InteropServices;

public static class TokenUtil {
    public const int TokenStatistics = 10;

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID {
        public uint LowPart;
        public int HighPart;
        public override string ToString() {
            // Format as 0xHHHHHHHHLLLLLLLL style (like Security log often shows)
            ulong v = ((ulong)(uint)HighPart << 32) | (uint)LowPart;
            return "0x" + v.ToString("x");
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_STATISTICS {
        public LUID TokenId;
        public LUID AuthenticationId;
        public long ExpirationTime;
        public uint TokenType;
        public uint ImpersonationLevel;
        public uint DynamicCharged;
        public uint DynamicAvailable;
        public uint GroupCount;
        public uint PrivilegeCount;
        public LUID ModifiedId;
    }

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public const uint TOKEN_QUERY = 0x0008;

    public static string GetAuthenticationIdHex() {
        IntPtr hTok;
        if(!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, TOKEN_QUERY, out hTok)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            int len;
            GetTokenInformation(hTok, TokenStatistics, IntPtr.Zero, 0, out len);
            IntPtr p = Marshal.AllocHGlobal(len);
            try {
                if(!GetTokenInformation(hTok, TokenStatistics, p, len, out len)) {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
                TOKEN_STATISTICS stats = (TOKEN_STATISTICS)Marshal.PtrToStructure(p, typeof(TOKEN_STATISTICS));
                return stats.AuthenticationId.ToString();
            } finally {
                Marshal.FreeHGlobal(p);
            }
        } finally {
            CloseHandle(hTok);
        }
    }
}
"@

    if (-not ("TokenUtil" -as [type])) {
        Add-Type -TypeDefinition $src -Language CSharp
    }

    return [TokenUtil]::GetAuthenticationIdHex()
}

function Get-4624ForLogonId {
    param(
        [Parameter(Mandatory=$true)][string]$LogonIdHex,
        [int]$LookBackHours = 24
    )

    $start = (Get-Date).AddHours(-1 * $LookBackHours)

    $events = Get-WinEvent -FilterHashtable @{ LogName="Security"; Id=4624; StartTime=$start } -ErrorAction Stop

    foreach ($ev in $events) {
        [xml]$x = $ev.ToXml()
        $dataNodes = $x.Event.EventData.Data
        $targetLogonId = ($dataNodes | Where-Object { $_.Name -eq "TargetLogonId" } | Select-Object -First 1).'#text'
        if ($targetLogonId -and ($targetLogonId.ToLower() -eq $LogonIdHex.ToLower())) {
            return $x
        }
    }

    return $null
}

function Test-HasKerberosTGT {
    # Looks for a krbtgt ticket in the current logon session cache.
    try {
        $out = & klist 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        return ($out -match "krbtgt/") -or ($out -match "krbtgt")
    } catch {
        return $false
    }
}

# Main
$logonId = Get-CurrentLogonIdHex
$eventXml = Get-4624ForLogonId -LogonIdHex $logonId -LookBackHours 48

if (-not $eventXml) {
    [pscustomobject]@{
        KerberosLikely = $null
        Reason         = "No matching 4624 found for current TargetLogonId ($logonId) in the lookback window. Increase LookBackHours or confirm auditing/log retention."
        LogonId        = $logonId
    }
    return
}

$data = $eventXml.Event.EventData.Data
$authPkg   = ($data | Where-Object { $_.Name -eq "AuthenticationPackageName" } | Select-Object -First 1).'#text'
$logonType = ($data | Where-Object { $_.Name -eq "LogonType" } | Select-Object -First 1).'#text'
$ip        = ($data | Where-Object { $_.Name -eq "IpAddress" } | Select-Object -First 1).'#text'
$user      = ($data | Where-Object { $_.Name -eq "TargetUserName" } | Select-Object -First 1).'#text'
$domain    = ($data | Where-Object { $_.Name -eq "TargetDomainName" } | Select-Object -First 1).'#text'

$tgt = Test-HasKerberosTGT

$kerbLikely = $null
$reason = ""

if ($authPkg -eq "Kerberos") {
    $kerbLikely = $true
    $reason = "4624 AuthenticationPackageName is Kerberos (definitive)."
}
elseif ($authPkg -eq "NTLM") {
    $kerbLikely = $false
    $reason = "4624 AuthenticationPackageName is NTLM (definitive)."
}
elseif ($authPkg -eq "Negotiate") {
    if ($tgt) {
        $kerbLikely = $true
        $reason = "4624 uses Negotiate, and a krbtgt ticket (TGT) is present in this session (strong evidence Kerberos was used)."
    } else {
        $kerbLikely = $null
        $reason = "4624 uses Negotiate, but no krbtgt ticket was found. Could be NTLM fallback, or tickets not present/accessible."
    }
}
else {
    $kerbLikely = $null
    $reason = "AuthenticationPackageName is '$authPkg' (not enough to decide)."
}

[pscustomobject]@{
    KerberosLikely           = $kerbLikely
    Reason                  = $reason
    LogonId                 = $logonId
    User                    = "$domain\$user"
    LogonType               = $logonType
    AuthenticationPackageName = $authPkg
    IpAddress               = $ip
    HasKerberosTGT          = $tgt
}
