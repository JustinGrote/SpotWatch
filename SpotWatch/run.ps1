param($Request, $TriggerMetadata)

function Send-JsonResponse {
    param(
        [int]$StatusCode,
        [object]$Body
    )

    $jsonBody = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
    Write-Output "Sent JSON Response: $jsonBody"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = $jsonBody
    })
}

function Test-RestartNeeded ($payload) {

    #Sanity checking and filtering for Spot Eviction event
    if ($payload.schemaId -ne 'azureMonitorCommonAlertSchema' -or
        -not $payload.data -or -not $payload.data.essentials -or -not $payload.data.alertContext) {
        Send-JsonResponse -StatusCode 400 -Body @{ error = 'Expected an Azure Monitor common alert schema payload.' }
        return
    }

    $essentials = $payload.data.essentials
    $alertContext = $payload.data.alertContext

    #Simulated eviction events use a different format
    if ($essentials.monitoringService -eq 'Activity Log - Administrative' -and
        $alertContext.status -eq 'Succeeded') {
        # The simulated eviction action uses the event log format, not the resource health format
        Send-JsonResponse -StatusCode 200 -Body @{
            status  = 'ignored'
            message = 'Simulated eviction detected. Attempting to start the virtual machine.'
        }
        return $true
    }

    if ($essentials.monitoringService -ne 'Resource Health') {
        Send-JsonResponse -StatusCode 200 -Body @{
            status  = 'ignored'
            message = 'The event is not a Resource Health alert'
        }
        return
    }
    if ($essentials.monitorCondition -ne 'Fired') {
        Send-JsonResponse -StatusCode 200 -Body @{
            status  = 'ignored'
            message = 'Only fired alerts start a virtual machine.'
        }
        return
    }

    if ($essentials.targetResourceType -ne 'microsoft.compute/virtualmachines' -or
        @($essentials.alertTargetIDs).Count -ne 1) {
        Send-JsonResponse -StatusCode 400 -Body @{
            error = 'Expected exactly one virtual-machine target in alertTargetIDs.'
        }
        return
    }

    # Ignore test alerts
    if ($essentials.alertRule -eq 'test-ResourceHealthAlertRule') {
        Send-JsonResponse -StatusCode 200 -Body @{
            status  = 'ignored'
            message = 'Received properly formatted Alert Group test alert.'
        }
        return
    }

    if (-not $restartNeeded -and $alertContext.properties.currentHealthStatus -ne 'Unavailable') {
        Send-JsonResponse -StatusCode 200 -Body @{
            status  = 'ignored'
            message = 'The current health status is not unavailable.'
        }
        return
    }

    if (-not $restartNeeded -and $alertContext.properties.title -ne 'Low priority machine preempted') {
        Send-JsonResponse -StatusCode 200 -Body @{
            status  = 'ignored'
            message = 'The alert is not for a spot instance eviction.'
        }
        return
    }

    if (-not $restartNeeded -and $alertContext.properties.cause -ne 'PlatformInitiated') {
        Send-JsonResponse -StatusCode 200 -Body @{
            status  = 'ignored'
            message = 'The alert cause is not platform initiated.'
        }
        return
    }

    #If we get this far, it is a valid alert instance for restart
    return $true
}

# Initial Sanity Check
try {
    if ($Request.Body -is [string]) {
        $payload = ConvertFrom-Json -InputObject $Request.Body -AsHashtable -ErrorAction Stop
    }
    else {
        $payload = ConvertTo-Json -InputObject $Request.Body -Depth 100 |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
} catch {
    Send-JsonResponse -StatusCode 400 -Body @{ error = 'Request body must be valid JSON.' }
    return
}

# Check if the alert requires a restart
if (-not (Test-RestartNeeded -Payload $payload)) {
    return
}

$resourceId = [string]$payload.data.essentials.alertTargetIDs[0]
if ($resourceId -notmatch '^/subscriptions/(?<subscription>[^/]+)/resourceGroups/(?<resourceGroup>[^/]+)/providers/Microsoft\.Compute/virtualMachines/(?<name>[^/]+)/?$') {
    Send-JsonResponse -StatusCode 400 -Body @{ error = 'The alert target is not a valid virtual-machine resource ID.' }
    return
}

$subscriptionId = $Matches.subscription
$resourceGroup = $Matches.resourceGroup
$vmName = $Matches.name

try {
    Write-Output "Evicted Spot VM Detected: $resourceId. Attempting to Start..."
    $connectParams = @{ ErrorAction = 'Stop' }

    if ($env:AZURE_CLIENT_ID -and $env:AZURE_TENANT_ID -and $env:AZURE_CLIENT_SECRET) {
        $secureSecret = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
        $credential = [PSCredential]::new($env:AZURE_CLIENT_ID, $secureSecret)
        $connectParams.ServicePrincipal = $true
        $connectParams.Tenant = $env:AZURE_TENANT_ID
        $connectParams.Credential = $credential
    }
    elseif ($env:AZURE_CLIENT_ID) {
        $connectParams.Identity = $true
        $connectParams.AccountId = $env:AZURE_CLIENT_ID
    }
    else {
        $connectParams.Identity = $true
    }

    Connect-AzAccount @connectParams | Out-Null

    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
    Start-AzVM -ResourceGroupName $resourceGroup -Name $vmName -NoWait -ErrorAction Stop | Out-Null


    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        $vm = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Status -ErrorAction Stop
        $powerState = ($vm.Statuses |
            Where-Object { $_.Code -like 'PowerState/*' } |
            Select-Object -First 1).Code

        if ($powerState -eq 'PowerState/running') {
            Send-JsonResponse -StatusCode 200 -Body @{
                status       = 'running'
                virtualMachineId = $resourceId
            }
            Write-Output "STARTED EVICTED SPOT VM: $resourceId"
            return
        }

        if ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 5
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    Send-JsonResponse -StatusCode 504 -Body @{
        error          = 'The virtual machine did not reach the running state within 120 seconds.'
        virtualMachineId = $resourceId
        powerState     = $powerState
    }
}
catch {
    Write-Error -ErrorRecord $_
    Send-JsonResponse -StatusCode 500 -Body @{
        error = 'The virtual machine could not be started or verified. Check the Function logs for details.'
    }
}
