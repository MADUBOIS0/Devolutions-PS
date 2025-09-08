# Set API endpoint
$uri = "https://dvls-02.devolutions.services/api/v1/login"

# Prepare the JSON body with your credentials
$body = @{
    appKey    = "432f6098-bf27-448b-b956-647a2096976f"
    appSecret = "0QeTTX692M8VEFxO1o8h26PwhVnoSji2GPep8DnWRnXXk2aXdxbpbZ4DqFCDQOzv"
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


