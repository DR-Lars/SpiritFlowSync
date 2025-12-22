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
$LogPath = "C:\Scripts\FlowSync.log"
$MaxRetries = 3
$RetryDelaySeconds = 10

# Validate environment variables
if (-not $LocalApiUrl -or -not $RemoteApiUrl -or -not $RemoteBatchUrl -or -not $MeterID -or -not $ShipName -or -not $ArchiveName) {
    Write-Log "ERROR: Environment variables not loaded. Check .env file."
    Write-Log "METER_ID=$env:METER_ID"
    Write-Log "SHIP_NAME=$env:SHIP_NAME"
    Write-Log "LOCAL_API_URL=$env:LOCAL_API_URL"
    Write-Log "REMOTE_API_URL=$env:REMOTE_API_URL"
    Write-Log "REMOTE_API_URL_BATCH=$env:REMOTE_API_URL_BATCH"
    Write-Log "ARCHIVE_NAME=$env:ARCHIVE_NAME"
    exit 1
}

function Write-Log($msg) {
    $logDir = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path -Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp `t $msg" | Out-File -FilePath $LogPath -Append -Encoding utf8
}

$headers = @{
    "Content-Type" = "application/json"
    # "Authorization" = "Bearer $env:REMOTE_API_TOKEN"  # Use env vars or Windows Credential Manager
}

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
        Write-Log "INFO: Attempt $attempt/$MaxRetries"
        Write-Log "INFO: Starting snapshot retrieval from $LocalApiUrl"


        
# First, fetch just the first page to determine the latest batch number
        Write-Log "INFO: Fetching first page to determine latest batch number..."
        $batchSize = 100
        $firstPageUrl = "$LocalApiUrl&count=$batchSize"
        $firstPage = Invoke-RestMethod -Uri $firstPageUrl -Method GET -TimeoutSec 30
        
        # Ensure $firstPage is always an array
        if ($firstPage -is [System.Management.Automation.PSCustomObject]) {
            $firstPage = @($firstPage)
        }

        if (-not $firstPage -or $firstPage.Count -eq 0) {
            Write-Log "ERROR: No snapshots found in local API."
            if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $RetryDelaySeconds }
            else { exit 1 }
            continue
        }

        # Get the latest batch number from the first snapshot and normalize it
        $targetBatchRaw = $firstPage[0].snapshot.tags.'LM_RUN1!RUN1_BATCH_NR_PRV'.v
        $latestBatch = [string]([int]([double]$targetBatchRaw))
        $previousBatch = [string]([int]$latestBatch - 1)
        Write-Log "INFO: Latest batch number detected: $targetBatchRaw (normalized: $latestBatch)"
        Write-Log "INFO: Will collect current batch $latestBatch and previous batch $previousBatch"

        # Check which batches already exist on remote
        $batchesToProcess = @{}
        foreach ($batchNum in @($latestBatch, $previousBatch)) {
            if (-not $RemoteApiUrl -or $RemoteApiUrl.Trim().Length -eq 0) {
                Write-Log "ERROR: RemoteApiUrl is empty, cannot perform batch check."
                exit 1
            }

            $separator = if ($RemoteApiUrl -match "\?") { '&' } else { '?' }
            $checkUrl = "$RemoteApiUrl$separator" + "meter_id=$MeterID&ship_name=$ShipName&batch_number=$batchNum"
            Write-Log "INFO: Checking if batch $batchNum already exists: $checkUrl"
            
            $shouldProcess = $false
            try {
                $existingBatch = Invoke-RestMethod -Uri $checkUrl -Method GET -TimeoutSec 30 -ErrorAction Stop

                $existingCount = 0
                if ($existingBatch -is [array]) {
                    $existingCount = $existingBatch.Count
                } elseif ($existingBatch -is [System.Management.Automation.PSCustomObject]) {
                    if ($existingBatch.PSObject.Properties.Name -contains 'data' -and $existingBatch.data -is [array]) {
                        $existingCount = $existingBatch.data.Count
                    } elseif ($existingBatch) {
                        $existingCount = 1
                    }
                } elseif ($existingBatch) {
                    $existingCount = 1
                }
                
                if ($existingCount -gt 0) {
                    Write-Log "WARNING: Batch $batchNum already exists in remote API (found $existingCount item(s)), will skip."
                } else {
                    Write-Log "INFO: Batch $batchNum does not exist in remote API, will collect and upload."
                    $shouldProcess = $true
                }
            } catch {
                $statusCode = $null
                try { $statusCode = $_.Exception.Response.StatusCode.Value__ } catch { }
                
                if ($statusCode -eq 404) {
                    Write-Log "INFO: Batch $batchNum not present (404), will collect and upload."
                    $shouldProcess = $true
                } else {
                    $err = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
                    Write-Log "WARNING: Batch check failed: $err. Will collect and upload anyway."
                    $shouldProcess = $true
                }
            }
            
            if ($shouldProcess) {
                $batchesToProcess[$batchNum] = @()
            }
        }

        if ($batchesToProcess.Count -eq 0) {
            Write-Log "INFO: All batches already exist on remote, nothing to process."
            break
        }

        # Collect snapshots for batches that need processing by paging through once
        Write-Log "INFO: Starting snapshot collection..."
        $lastUuid = $null
        $stopPaging = $false
        $pageCount = 0

        do {
            $url = if ($lastUuid) {
                "$LocalApiUrl&iterator=$lastUuid&count=$batchSize"
            } else {
                "$LocalApiUrl&count=$batchSize"
            }

            Write-Log "INFO: Fetching page $($pageCount + 1) with URL: $url"
            $page = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 30
            $pageCount++

            # Ensure $page is always an array
            if ($page -is [System.Management.Automation.PSCustomObject]) {
                $page = @($page)
            }

            if (-not $page -or $page.Count -eq 0) {
                Write-Log "INFO: No more snapshots retrieved, stopping."
                break
            }

            Write-Log "INFO: Page $pageCount contains $($page.Count) snapshots"

            foreach ($snap in $page) {
                $currentBatch = $snap.snapshot.tags.'LM_RUN1!RUN1_BATCH_NR_PRV'.v
                $currentBatchNormalized = [string]([int]([double]$currentBatch))

                # Check if we've gone past our batches of interest
                if ([int]$currentBatchNormalized -lt [int]$previousBatch) {
                    Write-Log "INFO: Reached batch $currentBatchNormalized which is before our target batches, stopping pagination."
                    $stopPaging = $true
                    break
                }

                # Add to appropriate batch collection if we're tracking it
                if ($batchesToProcess.ContainsKey($currentBatchNormalized)) {
                    $batchesToProcess[$currentBatchNormalized] += $snap
                }
            }

            if ($stopPaging) {
                Write-Log "INFO: Stopping pagination."
                break
            }

            $lastUuid = $page[-1].uuid
            
        } while (-not $stopPaging -and $page.Count -eq $batchSize)

        # Process and send each batch
        foreach ($targetBatch in @($latestBatch, $previousBatch)) {
            if (-not $batchesToProcess.ContainsKey($targetBatch)) {
                Write-Log "INFO: Batch $targetBatch already exists on remote, skipping."
                continue
            }

            $latestBatchSnapshots = $batchesToProcess[$targetBatch]
            Write-Log "INFO: ===== Processing batch $targetBatch ====="

        if (-not $latestBatchSnapshots -or $latestBatchSnapshots.Count -eq 0) {
            Write-Log "WARNING: No snapshots found for batch $targetBatch, skipping."
            continue
        }

        Write-Log "INFO: Found $($latestBatchSnapshots.Count) snapshots for batch $targetBatch"

        # Normalize timestamps and drop snapshots without timestamp
        $filteredSnapshots = @()
        $skippedWithoutTimestamp = 0
        foreach ($snap in $latestBatchSnapshots) {
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
            Write-Log "ERROR: No snapshots with valid timestamp to send for batch $targetBatch."
            continue
        }

        # Debug: verify endpoint and sample timestamps
        $firstSnap = $filteredSnapshots[0]
        Write-Log "DEBUG: Endpoint=$RemoteApiUrl"
        Write-Log "DEBUG: First snapshot timestamps: top=$($firstSnap.timestamp), inner=$($firstSnap.snapshot.ts)"

        # Send all snapshots in one batch
        $payload = @{
            ship_name = $ShipName
            meter_id = [string]$MeterID
            batch_number = $targetBatch
            snapshots = @($filteredSnapshots)
        }

        $payloadJson = $payload | ConvertTo-Json -Depth 50 -Compress
        $payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payloadJson)
        Write-Log "INFO: Sending batch payload ($($payloadBytes.Length) bytes) to $RemoteBatchUrl"

        # Use 5 minute timeout for large batches
        $timeoutSeconds = 300
        $remoteResponse = Invoke-RestMethod -Uri $RemoteBatchUrl -Method POST -Body $payloadBytes -ContentType "application/json; charset=utf-8" -Headers $headers -TimeoutSec $timeoutSeconds
        Write-Log "SUCCESS: Posted $($latestBatchSnapshots.Count) snapshots from batch $targetBatch in one request"
        if ($remoteResponse) {
            Write-Log "SUCCESS: Response: $($remoteResponse | ConvertTo-Json -Depth 3 -Compress)"
        }
        }
    } catch {
        $errorDetails = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Log "ERROR (attempt $attempt): $errorDetails"
        if ($attempt -lt $MaxRetries) { 
            Write-Log "INFO: Retrying in $RetryDelaySeconds seconds..."
            Start-Sleep -Seconds $RetryDelaySeconds 
        }
        else { 
            Write-Log "ERROR: Max retries exceeded, exiting."
            exit 1 
        }
    }
}
