# Set API endpoint
$uri = ""

# Prepare the JSON body with your credentials
$body = @{
    appKey    = ""
    appSecret = ""
} | ConvertTo-Json

# Set headers
$headers = @{
    "Accept"       = "application/json"
    "Content-Type" = "application/json"
}

# Send POST request with error handling
try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
    Write-Host "Login successful."
    Write-Host "Token ID:" $response.tokenId
} catch {
    $errorMessage = $_.Exception.Message

    if ($_.Exception.Response -ne $null) {
        $statusCode = ($_.Exception.Response).StatusCode.value__
        Write-Host "Request failed."
        Write-Host "Status code:" $statusCode
        Write-Host "Message:" $errorMessage
    } else {
        Write-Host "Request failed."
        Write-Host "Error:" $errorMessage
    }
}


