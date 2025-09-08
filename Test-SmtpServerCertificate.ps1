
function Test-SmtpServerCertificate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position=0)]
        [string]$Hostname,

        [Parameter(Position=1)]
        [int]$Port = 465,

        [Parameter()]
        [string]$OutputPath = "$env:TEMP\smtp_cert.cer"
    )

    try {
        Write-Verbose "Connecting to $Hostname on port $Port..."
        $tcp = New-Object System.Net.Sockets.TcpClient($Hostname, $Port)

        Write-Verbose "Starting TLS handshake..."
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($Hostname)

        Write-Verbose "Fetching server certificate..."
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)

        [System.IO.File]::WriteAllBytes($OutputPath, $bytes)

        Write-Output "✔ Certificate saved to: $OutputPath"

        $ssl.Close()
        $tcp.Close()

        Write-Output "`nRunning certutil validation..."
        certutil -urlfetch -verify $OutputPath
    }
    catch {
        Write-Error "❌ Failed to retrieve or validate certificate: $_"
    }
}

Test-SmtpServerCertificate "dvls-02.devolutions.services" 443
