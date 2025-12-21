param()

# Load environment variables from .env file
$envFile = Join-Path (Split-Path -Path $PSCommandPath -Parent) ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^\s*[^#]' } | ForEach-Object {
        $name, $value = $_ -split '=', 2
        [System.Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim(), 'Process')
    }
}

$MeterID = [int]$env:METER_ID
$ShipName = $env:SHIP_NAME
$LocalApiUrl = $env:LOCAL_API_URL
$RemoteApiUrl = $env:REMOTE_API_URL
$LogPath = "C:\Scripts\FlowSync.log"
$MaxRetries = 1
$RetryDelaySeconds = 10

# Validate environment variables
if (-not $LocalApiUrl -or -not $RemoteApiUrl) {
    Write-Host "ERROR: Environment variables not loaded. Check .env file."
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
        
        # Retrieve only the latest batch snapshots by paging until the batch number changes
        $latestBatchSnapshots = @()
        $lastUuid = $null
        $batchSize = 100
        $targetBatch = $null
        $stopPaging = $false
        $pageCount = 0

        Write-Log "INFO: Starting snapshot retrieval..."

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

                if (-not $targetBatch) {
                    $targetBatch = $currentBatch
                    Write-Log "INFO: Latest batch number detected: $targetBatch"
                }

                if ($currentBatch -ne $targetBatch) {
                    Write-Log "INFO: Batch number changed from $targetBatch to $currentBatch, stopping pagination."
                    $stopPaging = $true
                    break
                }

                $latestBatchSnapshots += $snap
            }

            if ($stopPaging) {
                Write-Log "INFO: Stopping pagination due to batch change."
                break
            }

            $lastUuid = $page[-1].uuid
            Write-Log "INFO: Last UUID: $lastUuid, Total snapshots so far: $($latestBatchSnapshots.Count)"
            
        } while (-not $stopPaging -and $page.Count -eq $batchSize)

        if (-not $latestBatchSnapshots -or $latestBatchSnapshots.Count -eq 0) {
            Write-Log "ERROR: No snapshots found for the latest batch."
            if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $RetryDelaySeconds }
            else { exit 1 }
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
            Write-Log "ERROR: No snapshots with valid timestamp to send."
            exit 1
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
        Write-Log "INFO: Sending batch payload ($($payloadBytes.Length) bytes) to $RemoteApiUrl"

        # Use 5 minute timeout for large batches
        $timeoutSeconds = 300
        $remoteResponse = Invoke-RestMethod -Uri $RemoteApiUrl -Method POST -Body $payloadBytes -ContentType "application/json; charset=utf-8" -Headers $headers -TimeoutSec $timeoutSeconds

        Write-Log "SUCCESS: Posted $($latestBatchSnapshots.Count) snapshots from batch $targetBatch in one request"
        if ($remoteResponse) {
            Write-Log "SUCCESS: Response: $($remoteResponse | ConvertTo-Json -Depth 3 -Compress)"
        }
        break
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
