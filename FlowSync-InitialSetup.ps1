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
$RemoteApiUrl = ($env:REMOTE_API_URL).Trim()
$RemoteBatchUrl = ($env:REMOTE_API_URL_BATCH).Trim()
$RemoteApiToken = ($env:REMOTE_API_TOKEN).Trim()
$LogPath = "C:\Scripts\FlowSync-InitialSetup.log"
$MaxRetries = 3
$RetryDelaySeconds = 10

# Validate environment variables
if (-not $LocalApiUrl -or -not $RemoteApiUrl -or -not $RemoteBatchUrl -or -not $MeterID -or -not $ShipName -or -not $ArchiveName -or -not $RemoteApiToken) {
    Write-Host "ERROR: Environment variables not loaded. Check .env file."
    Write-Host "METER_ID=$env:METER_ID"
    Write-Host "SHIP_NAME=$env:SHIP_NAME"
    Write-Host "LOCAL_API_URL=$env:LOCAL_API_URL"
    Write-Host "REMOTE_API_URL=$env:REMOTE_API_URL"
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

$localHeaders = @{
    "Content-Type" = "application/json"
}

Write-Log "========================================"
Write-Log "INITIAL SETUP: Fetching ALL snapshots"
Write-Log "========================================"

try {
    # Collect ALL snapshots by paging through entire history
    Write-Log "INFO: Starting to collect all snapshots from local API..."
    $batchSnapshots = @{}
    $lastUuid = $null
    $batchSize = 100
    $pageCount = 0
    $totalSnapshots = 0
    
    do {
        $url = if ($lastUuid) {
            "$LocalApiUrl&iterator=$lastUuid&count=$batchSize"
        } else {
            "$LocalApiUrl&count=$batchSize"
        }
        
        Write-Log "INFO: Fetching page $($pageCount + 1)..."
        $page = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 30 -Headers $localHeaders
        $pageCount++
        
        # Ensure $page is always an array
        if ($page -is [System.Management.Automation.PSCustomObject]) {
            $page = @($page)
        }
        
        if (-not $page -or $page.Count -eq 0) {
            Write-Log "INFO: No more snapshots, pagination complete."
            break
        }
        
        Write-Log "INFO: Page $pageCount contains $($page.Count) snapshots"
        $totalSnapshots += $page.Count
        
        # Group snapshots by batch number
        foreach ($snap in $page) {
            $currentBatch = $snap.snapshot.tags.'LM_RUN1!RUN1_BATCH_NR_PRV'.v
            $currentBatchNormalized = [string]([int]([double]$currentBatch))
            
            if (-not $batchSnapshots.ContainsKey($currentBatchNormalized)) {
                $batchSnapshots[$currentBatchNormalized] = @()
            }
            
            $batchSnapshots[$currentBatchNormalized] += $snap
        }
        
        $lastUuid = $page[-1].uuid
        Write-Log "INFO: Progress: $totalSnapshots total snapshots collected across $($batchSnapshots.Count) batches"
        
    } while ($page.Count -eq $batchSize)
    
    Write-Log "INFO: ========================================"
    Write-Log "INFO: Collection complete!"
    Write-Log "INFO: Total snapshots: $totalSnapshots"
    Write-Log "INFO: Total batches: $($batchSnapshots.Count)"
    Write-Log "INFO: ========================================"
    
    # Sort batch numbers in descending order (newest first)
    $sortedBatchNumbers = $batchSnapshots.Keys | Sort-Object { [int]$_ } -Descending
    
    Write-Log "INFO: Batch numbers found (newest to oldest): $($sortedBatchNumbers -join ', ')"
    Write-Log "INFO: Starting upload process..."
    
    $successCount = 0
    $skipCount = 0
    $errorCount = 0
    
    # Process each batch
    foreach ($batchNumber in $sortedBatchNumbers) {
        $snapshots = $batchSnapshots[$batchNumber]
        
        Write-Log "INFO: ===== Processing batch $batchNumber ($($snapshots.Count) snapshots) ====="
        
        # Check if batch already exists on remote
        $separator = if ($RemoteApiUrl -match "\?") { '&' } else { '?' }
        $checkUrl = "$RemoteApiUrl$separator" + "meter_id=$MeterID&ship_name=$ShipName&batch_number=$batchNumber"
        
        $shouldSkip = $false
        try {
            $existingBatch = Invoke-RestMethod -Uri $checkUrl -Method GET -TimeoutSec 30 -ErrorAction Stop -Headers $headers
            
            $remoteCount = 0
            if ($existingBatch -is [array]) {
                $remoteCount = $existingBatch.Count
            } elseif ($existingBatch -is [System.Management.Automation.PSCustomObject]) {
                if ($existingBatch.PSObject.Properties.Name -contains 'data' -and $existingBatch.data -is [array]) {
                    $remoteCount = $existingBatch.data.Count
                } elseif ($existingBatch) {
                    $remoteCount = 1
                }
            } elseif ($existingBatch) {
                $remoteCount = 1
            }
            
            if ($remoteCount -gt 0) {
                if ($remoteCount -eq $snapshots.Count) {
                    Write-Log "INFO: Batch $batchNumber already exists with same count ($remoteCount snapshots), skipping."
                    $shouldSkip = $true
                    $skipCount++
                } else {
                    Write-Log "WARNING: Batch $batchNumber exists with $remoteCount snapshots but local has $($snapshots.Count), will upload anyway."
                }
            }
        } catch {
            $statusCode = $null
            try { $statusCode = $_.Exception.Response.StatusCode.Value__ } catch { }
            
            if ($statusCode -eq 404) {
                Write-Log "INFO: Batch $batchNumber not found remotely (404), proceeding with upload."
            } else {
                $err = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
                Write-Log "WARNING: Batch check failed: $err. Proceeding with upload anyway."
            }
        }
        
        if ($shouldSkip) {
            continue
        }
        
        # Normalize timestamps and filter
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
            Write-Log "ERROR: No snapshots with valid timestamp for batch $batchNumber, skipping."
            $errorCount++
            continue
        }
        
        # Send batch with retry logic
        $uploaded = $false
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                $payload = @{
                    ship_name = $ShipName
                    meter_id = [string]$MeterID
                    batch_number = $batchNumber
                    snapshots = @($filteredSnapshots)
                }
                
                $payloadJson = $payload | ConvertTo-Json -Depth 50 -Compress
                $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
                
                Write-Log "INFO: Uploading batch $batchNumber (attempt $attempt/$MaxRetries, $($payloadBytes.Length) bytes)..."
                
                $remoteResponse = Invoke-RestMethod -Uri $RemoteBatchUrl -Method POST -Body $payloadBytes -ContentType "application/json; charset=utf-8" -Headers $headers -TimeoutSec 300
                
                Write-Log "SUCCESS: Uploaded batch $batchNumber with $($filteredSnapshots.Count) snapshots"
                if ($remoteResponse) {
                    Write-Log "SUCCESS: Response: $($remoteResponse | ConvertTo-Json -Depth 3 -Compress)"
                }
                
                $uploaded = $true
                $successCount++
                break
                
            } catch {
                $errorDetails = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
                Write-Log "ERROR: Failed to upload batch $batchNumber (attempt $attempt/$MaxRetries): $errorDetails"
                
                if ($attempt -lt $MaxRetries) {
                    Write-Log "INFO: Retrying in $RetryDelaySeconds seconds..."
                    Start-Sleep -Seconds $RetryDelaySeconds
                } else {
                    Write-Log "ERROR: Max retries exceeded for batch $batchNumber"
                    $errorCount++
                }
            }
        }
    }
    
    Write-Log "========================================"
    Write-Log "INITIAL SETUP COMPLETE"
    Write-Log "========================================"
    Write-Log "Total batches processed: $($batchSnapshots.Count)"
    Write-Log "Successfully uploaded: $successCount"
    Write-Log "Skipped (already exist): $skipCount"
    Write-Log "Failed: $errorCount"
    Write-Log "========================================"
    
    if ($errorCount -gt 0) {
        Write-Log "WARNING: Some batches failed to upload. Check log for details."
        exit 1
    }
    
} catch {
    $errorDetails = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Log "FATAL ERROR: $errorDetails"
    exit 1
}
