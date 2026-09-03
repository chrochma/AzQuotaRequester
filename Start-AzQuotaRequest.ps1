<#
.SYNOPSIS
    Checks Azure compute vCPU quota, requests an increase automatically and
    falls back to an Azure support request when the automatic path is denied.

.DESCRIPTION
    Flow:
      1. Sign in / select subscription.
      2. Verify (and optionally register) Microsoft.Compute, Microsoft.Quota
         and Microsoft.Support resource providers.
      3. Resolve the VM SKU to its quota family and vCPU size.
      4. Read the currently available quota (family + total regional vCPUs).
      5. Try an automatic increase through the Microsoft.Quota API.
      6. If that is rejected, create a quota support ticket from an adjustable
         JSON template.

    Without -VmSku / -TargetVCores the script starts a console wizard.

.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context. When omitted in
    interactive mode the script asks whether to keep the current context,
    switch subscription, or sign in as another user or tenant.

.PARAMETER TenantId
    Tenant to work in. Switches the context or signs in when it differs.

.PARAMETER Reauthenticate
    Forces a fresh Connect-AzAccount even when a session already exists.

.PARAMETER UseCurrentContext
    Skips the context question and uses the current Az context as-is.

.PARAMETER Location
    Azure region, e.g. westeurope or "West Europe".

.PARAMETER VmSku
    VM size whose quota family should be raised, e.g. Standard_D4s_v5.

.PARAMETER TargetVCores
    New total vCPU limit for the quota family (absolute limit, not a delta).

.PARAMETER InstanceCount
    Alternative to -TargetVCores: number of VM instances needed. The target
    limit becomes current usage + InstanceCount * vCPUs per instance.

.PARAMETER Spot
    Target the regional Spot / low-priority vCPU pool instead of the family quota.

.PARAMETER SkipRegionalTotal
    Do not raise the "Total Regional vCPUs" (cores) quota alongside the family.

.PARAMETER RegisterProviders
    Register missing resource providers instead of only reporting them.

.PARAMETER TemplatePath
    Support ticket template. Defaults to the personal template under
    %APPDATA%\AzQuotaRequester (or $env:AQR_TEMPLATE_PATH), which a git pull
    cannot overwrite.

.PARAMETER Severity
    Overrides the severity from the template.

.PARAMETER NoSupportTicket
    Never create a support request, only report the automatic result.

.PARAMETER ForceSupportTicket
    Skip the automatic attempt and go straight to the support request.

.PARAMETER NonInteractive
    Fail instead of prompting when required parameters are missing.

.EXAMPLE
    .\Start-AzQuotaRequest.ps1
    Runs the interactive wizard. It first asks whether to use the current Azure
    context, pick another subscription, or sign in as another user or tenant.

.EXAMPLE
    .\Start-AzQuotaRequest.ps1 -UseCurrentContext -Location westeurope -VmSku Standard_D4s_v5 -TargetVCores 200

.EXAMPLE
    .\Start-AzQuotaRequest.ps1 -TenantId contoso.onmicrosoft.com -Reauthenticate

.EXAMPLE
    .\Start-AzQuotaRequest.ps1 -Location westeurope -VmSku Standard_D4s_v5 -TargetVCores 200 -RegisterProviders

.EXAMPLE
    .\Start-AzQuotaRequest.ps1 -Location northeurope -VmSku Standard_NC24ads_A100_v4 -InstanceCount 4 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [switch]$Reauthenticate,
    [switch]$UseCurrentContext,
    [string]$Location,
    [string]$VmSku,
    [int]$TargetVCores,
    [int]$InstanceCount,
    [switch]$Spot,
    [switch]$SkipRegionalTotal,
    [switch]$RegisterProviders,
    [string]$TemplatePath,
    [ValidateSet('minimal', 'moderate', 'critical', 'highestcriticalimpact')][string]$Severity,
    [switch]$NoSupportTicket,
    [switch]$ForceSupportTicket,
    [switch]$NonInteractive,
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\AzQuotaRequester.Core.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src\AzQuotaRequester.Support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src\AzQuotaRequester.UI.psm1')      -Force -DisableNameChecking

try {
    Show-AqrBanner

    # --- 1. context ---------------------------------------------------------
    Write-AqrHeadline '1/6  Azure context'

    # Ask before doing anything, unless the caller already pinned the context.
    $askForContext = -not ($NonInteractive -or $UseCurrentContext -or $SubscriptionId -or $Reauthenticate -or $TenantId)
    if ($askForContext) {
        $picked = Select-AqrAzureContext
        $SubscriptionId = $picked.SubscriptionId
        $TenantId = $picked.TenantId
    }

    $context = Initialize-AqrContext -SubscriptionId $SubscriptionId -TenantId $TenantId -Reauthenticate:$Reauthenticate
    $SubscriptionId = $context.SubscriptionId
    Write-AqrOk "$($context.SubscriptionName) ($SubscriptionId) as $($context.Account)"

    # --- 2. resource providers ---------------------------------------------
    Write-AqrHeadline '2/6  Resource providers'
    $providers = Test-AqrResourceProvider -SubscriptionId $SubscriptionId -Register:$RegisterProviders
    foreach ($provider in $providers) {
        if ($provider.Registered) { Write-AqrOk "$($provider.Namespace): $($provider.State)" }
        else { Write-AqrWarn "$($provider.Namespace): $($provider.State)" }
    }
    $missing = @($providers | Where-Object { -not $_.Registered })
    if ($missing) {
        $names = ($missing.Namespace -join ', ')
        if ($NonInteractive -or -not (Read-AqrYesNo -Prompt "Register missing provider(s) $names now?" -Default $true)) {
            throw "Required resource provider(s) not registered: $names. Re-run with -RegisterProviders."
        }
        $providers = Test-AqrResourceProvider -SubscriptionId $SubscriptionId -Namespace $missing.Namespace -Register
        $stillMissing = @($providers | Where-Object { -not $_.Registered })
        if ($stillMissing) { throw "Registration did not complete for: $($stillMissing.Namespace -join ', ')" }
        Write-AqrOk "Registered: $names"
    }

    # --- 3. inputs ----------------------------------------------------------
    Write-AqrHeadline '3/6  Request details'
    $answers = $null
    if (-not $VmSku -or (-not $TargetVCores -and -not $InstanceCount) -or -not $Location) {        if ($NonInteractive) { throw 'Missing parameters: -Location, -VmSku and -TargetVCores (or -InstanceCount) are required in non-interactive mode.' }
        $answers = Invoke-AqrWizard -SubscriptionId $SubscriptionId -Location $Location -VmSku $VmSku -TargetVCores $TargetVCores -Spot:$Spot
        $SubscriptionId = $answers.SubscriptionId
        $Location = $answers.Location
        $VmSku = $answers.VmSku
        $TargetVCores = $answers.TargetVCores
    }

    $locationInfo = Get-AqrLocation -SubscriptionId $SubscriptionId -Location $Location
    $Location = $locationInfo.Name

    # Explains restricted / not-rolled-out SKUs and retries instead of ending the run.
    # The wizard already resolved this, so do not ask the user twice.
    $resolved = if ($answers -and $answers.Resolved) { $answers.Resolved }
                else { Resolve-AqrSkuQuota -SubscriptionId $SubscriptionId -Location $Location -VmSku $VmSku -Spot:$Spot -NonInteractive:$NonInteractive }
    $sku = $resolved.Sku
    $VmSku = $resolved.VmSku
    $primaryQuota = $resolved.Quota
    $primaryQuotaName = $primaryQuota.Name
    $availability = $resolved.Availability

    Write-AqrOk "$($sku.Name): $($sku.VCpus) vCPUs per instance, quota family '$($sku.Family)'."
    Write-AqrInfo "Availability: $($availability.Status) - $($availability.Reason)"
    if ($availability.SubscriptionOffer) { Write-AqrInfo "Subscription offer: $($availability.SubscriptionOffer)" }
    if ($availability.RestrictedZones.Count -gt 0) {
        if ($availability.UsableZones.Count -gt 0) {
            Write-AqrWarn "Zonal restriction in $Location : zone(s) $($availability.RestrictedZones -join ', ') blocked, deployable in $($availability.UsableZones -join ', ')."
        }
        else {
            Write-AqrWarn "Zonal restriction in $Location : every zone ($($availability.RestrictedZones -join ', ')) is blocked for this subscription."
        }
    }

    # --- 4. current quota ---------------------------------------------------
    Write-AqrHeadline '4/6  Current quota'
    $regionalQuota = Get-AqrQuota -SubscriptionId $SubscriptionId -Location $Location -QuotaName 'cores'
    Show-AqrQuotaTable -Quota @($primaryQuota, $regionalQuota)

    if (-not $TargetVCores -and $InstanceCount) {
        $used = if ($null -ne $primaryQuota.Used) { $primaryQuota.Used } else { 0 }
        $TargetVCores = $used + ($InstanceCount * $sku.VCpus)
        Write-AqrInfo "$InstanceCount x $($sku.VCpus) vCPUs + $used in use = target limit $TargetVCores."
    }
    if (-not $TargetVCores) { throw 'No target vCPU limit resolved.' }

    if ($primaryQuota.Unlimited) {
        Write-AqrOk "Nothing to do: '$($primaryQuota.LocalizedName)' has no limit in $Location."
        return
    }
    if (-not $resolved.SkipAutomaticRequest -and -not $primaryQuota.QuotaApiAvailable) {
        Write-AqrWarn "Microsoft.Quota does not expose '$primaryQuotaName' in $Location. Limits come from the usages API and the automatic increase may not be supported for this family."
    }

    # The regional pool may be missing or unlimited; treat that as "not a blocker".
    $regionalBlocks = ($regionalQuota -and -not $regionalQuota.Unlimited -and $regionalQuota.Limit -lt $TargetVCores)

    if ($primaryQuota.Limit -ge $TargetVCores) {
        Write-AqrOk "Nothing to do: '$($primaryQuota.LocalizedName)' limit is already $($primaryQuota.Limit) (>= $TargetVCores)."
        if ($SkipRegionalTotal -or -not $regionalBlocks) { return }
        Write-AqrWarn "Total Regional vCPUs limit ($($regionalQuota.Limit)) is still below $TargetVCores and would block deployment."
    }

    # Build the list of quota buckets to raise. Regional total must cover the family.
    $targets = [System.Collections.Generic.List[object]]::new()
    if ($primaryQuota.Limit -lt $TargetVCores) {
        $targets.Add([pscustomobject]@{ Quota = $primaryQuota; TargetLimit = $TargetVCores })
    }
    if (-not $SkipRegionalTotal -and $regionalBlocks -and $regionalQuota.Name -ne $primaryQuota.Name) {
        $targets.Add([pscustomobject]@{ Quota = $regionalQuota; TargetLimit = $TargetVCores })
    }

    if (-not $targets) {
        Write-AqrOk 'Nothing to request.'
        return
    }

    Write-Host ''
    foreach ($target in $targets) {
        Write-AqrInfo "Planned: $($target.Quota.LocalizedName)  $($target.Quota.Limit) -> $($target.TargetLimit)"
    }
    if (-not $NonInteractive -and -not $WhatIfPreference -and -not (Read-AqrYesNo -Prompt 'Submit these quota increases?' -Default $true)) {
        Write-AqrWarn 'Cancelled by user.'
        return
    }

    # --- 5. automatic quota request ----------------------------------------
    Write-AqrHeadline '5/6  Automatic quota request (Microsoft.Quota)'
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($target in $targets) {
        # Only the family bucket is unusable; the regional pool is still fine.
        $skipThis = $resolved.SkipAutomaticRequest -and $target.Quota.Name -eq $primaryQuota.Name

        if ($ForceSupportTicket -or $skipThis) {
            $why = if ($skipThis) {
                "Microsoft.Quota cannot serve '$($target.Quota.Name)' in $Location ($($availability.Status)). Going straight to a support request."
            }
            else { 'Automatic request skipped (-ForceSupportTicket).' }
            Write-AqrWarn $why
            $results.Add([pscustomobject]@{
                Quota = $target.Quota; TargetLimit = $target.TargetLimit
                Outcome = 'Skipped'; NeedsSupportTicket = $true
                Message = $why
            })
            continue
        }

        Write-AqrStep "Requesting $($target.Quota.Name) -> $($target.TargetLimit) in $Location"
        # -WhatIf must be passed explicitly: preference variables do not cross module boundaries.
        $request = Request-AqrQuotaIncrease -SubscriptionId $SubscriptionId -Location $Location `
            -QuotaName $target.Quota.Name -NewLimit $target.TargetLimit -TimeoutSeconds $TimeoutSeconds `
            -WhatIf:$WhatIfPreference

        if ($request.Outcome -eq 'Succeeded') { Write-AqrOk $request.Message }
        elseif ($request.Outcome -eq 'Skipped') { Write-AqrWarn $request.Message }
        else { Write-AqrFail $request.Message }
        $results.Add([pscustomobject]@{
            Quota = $target.Quota; TargetLimit = $target.TargetLimit
            Outcome = $request.Outcome
            # A WhatIf run still renders the ticket so the payload can be reviewed.
            NeedsSupportTicket = ($request.NeedsSupportTicket -or $request.Outcome -eq 'Skipped')
            Message = $request.Message
            ActualLimit = $request.ActualLimit
        })
    }

    # Per-bucket result, so a success on one bucket cannot be mistaken for the
    # SKU family the user actually asked about.
    Write-Host ''
    '  {0,-26} {1,-12} {2,8} {3,8}' -f 'QUOTA', 'RESULT', 'BEFORE', 'NOW' | Write-Host -ForegroundColor DarkCyan
    foreach ($r in $results) {
        $color = switch ($r.Outcome) {
            'Succeeded' { 'Green' }
            'Skipped' { 'Yellow' }
            'Partial' { 'Yellow' }
            default { 'Red' }
        }
        $now = if ($null -ne $r.ActualLimit) { $r.ActualLimit } else { '-' }
        '  {0,-26} {1,-12} {2,8} {3,8}' -f $r.Quota.Name, $r.Outcome, $r.Quota.Limit, $now | Write-Host -ForegroundColor $color
    }

    $failed = @($results | Where-Object { $_.Outcome -ne 'Succeeded' })
    if ($failed) {
        Write-Host ''
        Write-AqrFail "$($failed.Count) of $($results.Count) quota increase(s) did NOT succeed: $(($failed.Quota.Name) -join ', ')."
    }

    # --- 6. support ticket fallback ----------------------------------------
    Write-AqrHeadline '6/6  Support request'
    $escalate = @($results | Where-Object { $_.NeedsSupportTicket })

    if (-not $escalate) {
        Write-AqrOk 'All quota increases were approved automatically. No support request needed.'
        return
    }
    if ($NoSupportTicket) {
        Write-AqrWarn 'Automatic request failed, but -NoSupportTicket was specified. Nothing else to do.'
        return
    }

    # Azure exposes no API for the support plan, so a previous InvalidSupportPlan
    # is remembered. Without API access there is no point offering a case.
    $primaryEscalation = $escalate | Select-Object -First 1
    if ((Get-AqrSupportApiState -SubscriptionId $SubscriptionId) -eq 'Unavailable') {
        Write-AqrWarn 'This subscription cannot create support cases through the API (the support plan does not include it).'
        Write-AqrInfo 'A Professional Direct, Premier or Unified plan is required for the Support API.'
        Show-AqrPortalQuotaGuidance -Location $Location -QuotaDisplayName $primaryEscalation.Quota.LocalizedName -TargetLimit $primaryEscalation.TargetLimit
        return
    }

    $TemplatePath = Get-AqrTemplatePath -Path $TemplatePath
    $template = Import-AqrTicketTemplate -Path $TemplatePath
    Write-AqrInfo "Template: $TemplatePath"
    if ($TemplatePath -like '*example*') {
        Write-AqrWarn 'This is the shipped example template. Run New-AqrTicketTemplate.ps1 to create your own.'
    }
    Write-AqrInfo "Contact:  $($template.contactDetails.firstName) $($template.contactDetails.lastName) <$($template.contactDetails.primaryEmailAddress)> via $($template.contactDetails.preferredContactMethod)"

    if (-not $NonInteractive -and -not $WhatIfPreference -and -not (Read-AqrYesNo -Prompt 'Create an Azure support request with these details?' -Default $true)) {
        Write-AqrWarn 'Support request cancelled. Adjust the template and re-run with -ForceSupportTicket.'
        return
    }

    $quotaRequests = foreach ($item in $escalate) {
        [pscustomobject]@{
            QuotaName     = $item.Quota.Name
            LocalizedName = $item.Quota.LocalizedName
            CurrentLimit  = $item.Quota.Limit
            CurrentUsage  = if ($null -ne $item.Quota.Used) { $item.Quota.Used } else { 0 }
            TargetLimit   = $item.TargetLimit
        }
    }

    $ticket = New-AqrQuotaSupportTicket -SubscriptionId $SubscriptionId -SubscriptionName $context.SubscriptionName `
        -Location $Location -LocationTitleCase $locationInfo.TitleCase -VmSku $sku.Name `
        -QuotaRequest @($quotaRequests) -Template $template -Severity $Severity `
        -AutoRequestResult (($escalate | ForEach-Object { "[$($_.Quota.Name)] $($_.Message)" }) -join "`n") `
        -WhatIf:$WhatIfPreference

    if ($ticket.Created) {
        Set-AqrSupportApiState -SubscriptionId $SubscriptionId -State 'Available'
        Write-AqrOk $ticket.Message
        Write-AqrInfo "Status: $($ticket.Status)"
        if ($ticket.SeverityDowngraded) {
            Write-Host ''
            Write-AqrWarn "SEVERITY LOWERED: requested '$($ticket.RequestedSeverity)', raised as '$($ticket.EffectiveSeverity)'."
            Write-AqrWarn 'Cause: the subscription support plan does not cover the requested severity.'
            Write-AqrInfo 'The ticket description records the originally requested severity. Upgrade the support plan to raise a higher severity case.'
        }
        Write-AqrInfo "Portal: https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade/supportRequest"
    }
    elseif ($ticket.Status -eq 'WhatIf') {
        Write-AqrWarn 'Dry run - the following support request payload would be sent:'
        Write-Host $ticket.Body -ForegroundColor DarkGray
    }
    else {
        Write-AqrFail "Support request not created ($($ticket.Status)): $($ticket.Message)"
        if ($ticket.Message -match 'InvalidSupportPlan|support plan type is') {
            # Remember it, so the next run does not offer a case again.
            Set-AqrSupportApiState -SubscriptionId $SubscriptionId -State 'Unavailable'
            Write-AqrInfo 'The Support API needs a Professional Direct, Premier or Unified plan.'
            Show-AqrPortalQuotaGuidance -Location $Location -QuotaDisplayName $primaryEscalation.Quota.LocalizedName -TargetLimit $primaryEscalation.TargetLimit
        }
        else {
            Write-AqrInfo 'Every severity down to "minimal" was rejected. Check the contact details in the template and the subscription support plan.'
        }
    }

    # The raw JSON body is dropped here; it is already shown on a dry run.
    $ticket | Select-Object -ExcludeProperty Body
}
catch {
    Write-AqrFail $_.Exception.Message
    throw
}
