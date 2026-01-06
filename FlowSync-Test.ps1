param()

# Load environment variables from .env file
$envFile = Join-Path (Split-Path -Path $PSCommandPath -Parent) ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^\s*[^#]' -and $_ -match '=' } | ForEach-Object {
        $line = $_.Trim()
        if ($line) {
            $name, $value = $line -split '=', 2
            $name = $name.Trim()
            $value = $value.Trim()
            if ($name -and $value) {
                [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
        }
    }
}

$MeterID = [int]$env:METER_ID
$ShipName = ($env:SHIP_NAME).Trim()
$LocalApiUrlBase = ($env:LOCAL_API_URL).Trim()
$ArchiveName = ($env:ARCHIVE_NAME).Trim()
$LocalApiUrl = "$LocalApiUrlBase/snapshots?archive=$ArchiveName&ascending=0"
$RemoteBatchUrl = ($env:REMOTE_API_URL_BATCH).Trim()
$RemoteApiToken = ($env:REMOTE_API_TOKEN).Trim()
$LogPath = "C:\Scripts\FlowSync-Test.log"

# Validate environment variables
if (-not $LocalApiUrl -or -not $RemoteBatchUrl -or -not $MeterID -or -not $ShipName -or -not $ArchiveName -or -not $RemoteApiToken) {
    Write-Host "ERROR: Environment variables not loaded. Check .env file."
    Write-Host "METER_ID=$env:METER_ID"
    Write-Host "SHIP_NAME=$env:SHIP_NAME"
    Write-Host "LOCAL_API_URL=$env:LOCAL_API_URL"
    Write-Host "REMOTE_API_URL_BATCH=$env:REMOTE_API_URL_BATCH"
    Write-Host "ARCHIVE_NAME=$env:ARCHIVE_NAME"
    Write-Host "REMOTE_API_TOKEN=$env:REMOTE_API_TOKEN"
    exit 1
}

function Write-Log($msg) {
    $logDir = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path -Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp `t $msg" | Out-File -FilePath $LogPath -Append -Encoding utf8
    Write-Host $msg
}

$headers = @{
    "Content-Type" = "application/json"
    "Authorization" = "Bearer $RemoteApiToken"
}

try {
    Write-Log "INFO: Starting quick test - fetching latest 100 snapshots"
    
    # Fetch the latest 100 snapshots
    $batchSize = 100
    $url = "$LocalApiUrl&count=$batchSize"
    Write-Log "INFO: Fetching snapshots from: $url"
    
    $snapshots = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 30 -Headers @{"Content-Type" = "application/json"}
    
    # Ensure snapshots is always an array
    if ($snapshots -is [System.Management.Automation.PSCustomObject]) {
        $snapshots = @($snapshots)
    }
    
    if (-not $snapshots -or $snapshots.Count -eq 0) {
        Write-Log "ERROR: No snapshots found in local API."
        exit 1
    }
    
    Write-Log "INFO: Retrieved $($snapshots.Count) snapshots"
    
    # Get batch number from first snapshot
    $targetBatchRaw = $snapshots[0].snapshot.tags.'LM_RUN1!RUN1_BATCH_NR_PRV'.v
    $targetBatch = [string]([int]([double]$targetBatchRaw))
    Write-Log "INFO: Batch number: $targetBatch"
    
    # Normalize timestamps and drop snapshots without timestamp
    $filteredSnapshots = @()
    $skippedWithoutTimestamp = 0
    
    foreach ($snap in $snapshots) {
        # Fallback: use inner snapshot.ts if top-level timestamp is missing
        if (-not $snap.timestamp -and $snap.snapshot -and $snap.snapshot.ts) {
            $snap.timestamp = $snap.snapshot.ts
        }
        
        if (-not $snap.timestamp) {
            $skippedWithoutTimestamp++
            continue
        }
        
        try {
            $snap.timestamp = ([datetime]$snap.timestamp).ToString("yyyy-MM-dd HH:mm:ss")
        } catch {
            $skippedWithoutTimestamp++
            continue
        }
        
        $filteredSnapshots += $snap
    }
    
    if ($skippedWithoutTimestamp -gt 0) {
        Write-Log "INFO: Skipped $skippedWithoutTimestamp snapshots without valid timestamp"
    }
    
    if (-not $filteredSnapshots -or $filteredSnapshots.Count -eq 0) {
        Write-Log "ERROR: No snapshots with valid timestamp to send."
        exit 1
    }
    
    Write-Log "INFO: Prepared $($filteredSnapshots.Count) snapshots with valid timestamps for sending"
    
    # Send batch to API
    $payload = @{
        ship_name = $ShipName
        meter_id = [string]$MeterID
        batch_number = $targetBatch
        snapshots = @($filteredSnapshots)
    }
    
    $payloadJson = $payload | ConvertTo-Json -Depth 50 -Compress
    $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
    
    Write-Log "INFO: Sending payload ($($payloadBytes.Length) bytes) to $RemoteBatchUrl"
    Write-Log "INFO: Payload size breakdown:"
    Write-Log "  - Ship Name: $ShipName"
    Write-Log "  - Meter ID: $MeterID"
    Write-Log "  - Batch Number: $targetBatch"
    Write-Log "  - Snapshots: $($filteredSnapshots.Count)"
    
    $remoteResponse = Invoke-RestMethod -Uri $RemoteBatchUrl -Method POST -Body $payloadBytes -ContentType "application/json; charset=utf-8" -Headers $headers -TimeoutSec 300
    
    Write-Log "SUCCESS: Posted $($filteredSnapshots.Count) snapshots to remote API"
    if ($remoteResponse) {
        Write-Log "SUCCESS: Response: $($remoteResponse | ConvertTo-Json -Depth 3)"
    }
    
} catch {
    $errorDetails = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Log "ERROR: $errorDetails"
    exit 1
}

Write-Log "INFO: Test completed successfully!"
