<#
.SYNOPSIS
    Console UI for AzQuotaRequester.
.DESCRIPTION
    Small menu-driven wizard used when the entry script is started without the
    required parameters.
#>

Import-Module (Join-Path $PSScriptRoot 'AzQuotaRequester.Core.psm1') -DisableNameChecking

function Show-AqrBanner {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '   AzQuotaRequester - Azure vCPU quota check, raise, escalate' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
}

function Read-AqrText {
    <#
    .SYNOPSIS
        Prompts for free text with an optional default value.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default,
        [switch]$AllowEmpty
    )
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $value = Read-Host "  $Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if ($AllowEmpty -or -not [string]::IsNullOrWhiteSpace($value)) { return $value }
        Write-AqrWarn 'A value is required.'
    }
}

function Read-AqrInt {
    <#
    .SYNOPSIS
        Prompts for a positive integer.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [int]$Default = 0,
        [int]$Minimum = 1
    )
    while ($true) {
        $suffix = if ($Default -gt 0) { " [$Default]" } else { '' }
        $value = Read-Host "  $Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value) -and $Default -gt 0) { return $Default }
        $parsed = 0
        if ([int]::TryParse($value, [ref]$parsed) -and $parsed -ge $Minimum) { return $parsed }
        Write-AqrWarn "Enter a whole number of at least $Minimum."
    }
}

function Read-AqrYesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = (Read-Host "  $Prompt [$hint]").Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        if ($value -in 'y', 'yes') { return $true }
        if ($value -in 'n', 'no') { return $false }
    }
}

function Read-AqrChoice {
    <#
    .SYNOPSIS
        Numbered single-select menu.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Option,
        [int]$PageSize = 25
    )
    if ($Option.Count -eq 1) { return $Option[0] }

    $index = 0
    while ($true) {
        $page = $Option[$index..([Math]::Min($index + $PageSize - 1, $Option.Count - 1))]
        Write-Host ''
        Write-Host "  $Title" -ForegroundColor Cyan
        for ($i = 0; $i -lt $page.Count; $i++) {
            '    {0,3}) {1}' -f ($index + $i + 1), $page[$i] | Write-Host
        }
        $more = ($index + $PageSize) -lt $Option.Count
        if ($more) { Write-Host '      m) more...' -ForegroundColor DarkGray }

        $answer = (Read-Host '  Select').Trim()
        if ($more -and $answer -eq 'm') { $index += $PageSize; continue }

        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Option.Count) {
            return $Option[$number - 1]
        }
        Write-AqrWarn 'Invalid selection.'
    }
}

function Read-AqrSearchChoice {
    <#
    .SYNOPSIS
        Search-then-pick selection for long option lists.
    .DESCRIPTION
        Accepts an exact value directly, otherwise filters the list and shows a
        numbered menu of the matches.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Option,
        [string]$Default
    )
    while ($true) {
        $filter = Read-AqrText -Prompt $Prompt -Default $Default
        $exact = @($Option | Where-Object { $_ -eq $filter })
        if ($exact) { return $exact[0] }

        $hits = @($Option | Where-Object { $_ -like "*$filter*" })
        if (-not $hits) { Write-AqrWarn "Nothing matches '$filter'."; continue }
        if ($hits.Count -eq 1) { return $hits[0] }
        return (Read-AqrChoice -Title "Matches for '$filter'" -Option $hits)
    }
}

function Select-AqrSubscription {
    <#
    .SYNOPSIS
        Lets the user pick a subscription available to the current sign-in.
    .DESCRIPTION
        Lists every tenant the account can reach by default, so a subscription
        in another tenant can be picked directly.
    .OUTPUTS
        Object with SubscriptionId and TenantId, or $null when none are found.
    #>
    param([string]$TenantId)

    $splat = @{ ErrorAction = 'SilentlyContinue'; WarningAction = 'SilentlyContinue' }
    if ($TenantId) { $splat.TenantId = $TenantId }
    $subs = @(Get-AzSubscription @splat | Where-Object { $_.State -eq 'Enabled' } | Sort-Object Name)

    if (-not $subs) { Write-AqrWarn 'No enabled subscriptions found for this sign-in.'; return $null }

    # Show the tenant only when the list spans more than one.
    $multiTenant = (@($subs.TenantId | Sort-Object -Unique).Count -gt 1)
    $labels = $subs | ForEach-Object {
        if ($multiTenant) { "$($_.Name)  ($($_.Id))  [tenant $($_.TenantId)]" } else { "$($_.Name)  ($($_.Id))" }
    }

    $picked = Read-AqrChoice -Title 'Subscription' -Option $labels
    $sub = $subs | Where-Object { $picked -like "*$($_.Id)*" } | Select-Object -First 1
    if (-not $sub) { return $null }

    [pscustomobject]@{ SubscriptionId = $sub.Id; TenantId = $sub.TenantId; Name = $sub.Name }
}

function Select-AqrTenant {
    <#
    .SYNOPSIS
        Lets the user pick a tenant the current account can reach, or enter one.
    #>
    $tenants = @(Get-AzTenant -ErrorAction SilentlyContinue)

    if (-not $tenants) { return (Read-AqrText -Prompt 'Tenant id (GUID) or domain') }

    $manual = 'Enter a different tenant id manually'
    $labels = @($tenants | ForEach-Object {
            $name = if ($_.Name) { $_.Name } elseif ($_.DefaultDomain) { $_.DefaultDomain } else { 'unnamed' }
            "$name  ($($_.Id))"
        }) + $manual

    $picked = Read-AqrChoice -Title 'Tenant' -Option $labels
    if ($picked -eq $manual) { return (Read-AqrText -Prompt 'Tenant id (GUID) or domain') }
    ($tenants | Where-Object { $picked -like "*$($_.Id)*" } | Select-Object -First 1).Id
}

function Select-AqrAzureContext {
    <#
    .SYNOPSIS
        Asks whether to keep the current Azure context, switch subscription, or
        sign in again as another user or into another tenant.
    .OUTPUTS
        Object with SubscriptionId and TenantId to work with.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        throw 'Module Az.Accounts is not installed. Run: Install-Module Az.Accounts -Scope CurrentUser'
    }
    Import-Module Az.Accounts -ErrorAction Stop

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context -or -not $context.Subscription) {
        Write-AqrStep 'No usable Azure session found, starting interactive sign-in.'
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $context = Get-AzContext -ErrorAction Stop
    }

    $useCurrent = 'Use the current context'
    $otherSub = 'Select another subscription for this account'
    $otherUser = 'Sign in with a different user'
    $otherTenant = 'Sign in to a different tenant'

    while ($true) {
        Write-Host ''
        Write-AqrInfo "Account:      $($context.Account.Id)"
        Write-AqrInfo "Tenant:       $($context.Tenant.Id)"
        Write-AqrInfo "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"

        $choice = Read-AqrChoice -Title 'Azure context' -Option @($useCurrent, $otherSub, $otherUser, $otherTenant)

        if ($choice -eq $useCurrent) {
            return [pscustomobject]@{ SubscriptionId = $context.Subscription.Id; TenantId = $context.Tenant.Id }
        }

        if ($choice -eq $otherSub) {
            # No tenant filter: the account may own subscriptions in other tenants.
            $picked = Select-AqrSubscription
            if ($picked) { return $picked }
            continue
        }

        if ($choice -eq $otherUser) {
            Connect-AzAccount -ErrorAction Stop | Out-Null
        }
        else {
            $tenant = Select-AqrTenant
            if (-not $tenant) { continue }
            Connect-AzAccount -TenantId $tenant -ErrorAction Stop | Out-Null
        }

        # Re-read the context after the sign-in and offer the new subscriptions.
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context.Subscription) { Write-AqrWarn 'The new sign-in has no subscription selected.'; continue }
        $picked = Select-AqrSubscription -TenantId $context.Tenant.Id
        if ($picked) { return $picked }
    }
}

function Select-AqrLocation {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string]$Default = 'westeurope'
    )
    while ($true) {
        $value = Read-AqrText -Prompt 'Region (name or display name)' -Default $Default
        try {
            Write-AqrStep "Resolving region '$value' ..."
            return (Get-AqrLocation -SubscriptionId $SubscriptionId -Location $value)
        }
        catch { Write-AqrWarn $_.Exception.Message }
    }
}

function Show-AqrUsedSkuFamily {
    <#
    .SYNOPSIS
        Prints the quota families that already carry usage in the region, so an
        existing family can be extended instead of enabling a new one.
    .DESCRIPTION
        Each family is shown with an example SKU name, because the family
        display name itself is not a valid SKU and cannot be pasted back.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [array]$Sku
    )

    $used = @(Get-AqrUsedSkuFamily -SubscriptionId $SubscriptionId -Location $Location)
    if ($used) {
        Write-Host ''
        Write-AqrInfo "Families already in use in $Location :"
        foreach ($f in $used) {
            $example = ($Sku | Where-Object { $_.family -eq $f.Name } | Sort-Object name | Select-Object -First 1).name
            $hint = if ($example) { "   e.g. $example" } else { '' }
            '    {0,-34} {1}/{2} vCPUs{3}' -f $f.LocalizedName, $f.Used, $f.Limit, $hint | Write-Host -ForegroundColor Green
        }
        Write-AqrInfo 'Paste a SKU name, or the family name above - both are accepted.'
        return
    }

    # Nothing running: allocated quota still shows which families are enabled.
    $allocated = @(Get-AqrUsedSkuFamily -SubscriptionId $SubscriptionId -Location $Location -IncludeAllocated)
    Write-Host ''
    if ($allocated) {
        Write-AqrInfo "No vCPUs in use in $Location. $($allocated.Count) families already have quota allocated."
    }
    else {
        Write-AqrInfo "No vCPUs in use in $Location."
    }
}

function Show-AqrSkuOption {
    <#
    .SYNOPSIS
        Prints SKU or quota family options with their availability.
    .DESCRIPTION
        Marks the entry the user asked for and highlights newer generations that
        are actually usable, because those are the ones worth switching to.
    #>
    param(
        [Parameter(Mandatory)][array]$Option,
        [string]$Title = 'SKU'
    )

    $isFamily = [bool]($Option[0].PSObject.Properties.Name -contains 'Sizes')
    $sizeHeader = if ($isFamily) { 'SIZES' } else { 'vCPU' }

    Write-Host ''
    Write-AqrColorLine -Tone Header -Text ('  {0,-28} {1,5} {2,-14} {3,7} {4,-10} {5}' -f $Title, $sizeHeader, 'STATUS', 'LIMIT', 'ZONES', 'NOTE')

    foreach ($o in $Option) {
        $usable = ($o.Status -in 'Available', 'ZeroQuota')
        $partial = ($o.Coverage -eq 'Partial')

        $note = @()
        if ($o.IsRequested) { $note += 'current selection' }
        elseif ($usable) { $note += if ($partial) { 'newer generation' } else { 'NEWER GENERATION - recommended' } }
        else { $note += 'newer generation' }
        # Azure names quota families inconsistently across generations
        # (standardDADSv5Family -> standardDadv6Family -> StandardDadsv7Family),
        # so show a member SKU: without it the v6 row reads like a different line.
        if ($isFamily -and $o.Sizes.Count) { $note += "e.g. $($o.Sizes[0])" }
        if ($o.InUse) { $note += "in use ($($o.Used))" }

        # A zone can be missing for two different reasons; say which.
        if ($o.NotOfferedZones.Count) {
            $note += "AZ $($o.NotOfferedZones -join ',') not available"
        }
        if ($o.RestrictedZones.Count) {
            $note += "AZ $($o.RestrictedZones -join ',') restricted for this subscription"
        }
        if ($usable -and $partial) {
            $note += "only $($o.UsableZones.Count) of $($o.RegionZones.Count) AZs"
        }
        if ($o.RestrictionCode) { $note += $o.RestrictionCode }

        # Tone means one thing: how usable the entry is. The current selection
        # keeps that meaning and only gains intensity, so a healthy selection
        # never reads as a problem.
        $marker = if ($o.IsRequested) { '>' } elseif ($usable -and -not $partial) { '*' } else { ' ' }
        $coverage = if (-not $usable) { 'Unusable' }
                    elseif ($partial) { 'PartialZone' }
                    else { 'FullZone' }
        $tone = if ($o.IsRequested) {
            switch ($coverage) {
                'Unusable'    { 'SelectedUnusable' }
                'PartialZone' { 'SelectedPartial' }
                default       { 'SelectedFull' }
            }
        }
        else { $coverage }

        $count = if ($isFamily) { $o.Sizes.Count } else { $o.VCpus }
        $limit = if ($null -ne $o.Limit) { $o.Limit } else { '-' }
        $zones = if ($o.UsableZones.Count) { $o.UsableZones -join ',' } else { '-' }
        Write-AqrColorLine -Tone $tone -Text ('{0} {1,-28} {2,5} {3,-14} {4,7} {5,-10} {6}' -f $marker, $o.Name, $count, $o.Status, $limit, $zones, ($note -join '; '))
    }

    $full = @($Option | Where-Object { -not $_.IsRequested -and $_.Status -in 'Available', 'ZeroQuota' -and $_.Coverage -ne 'Partial' })
    $limited = @($Option | Where-Object { -not $_.IsRequested -and $_.Status -in 'Available', 'ZeroQuota' -and $_.Coverage -eq 'Partial' })

    Write-Host ''
    Write-AqrColorLine -Tone FullZone -Text '  *  usable in every AZ'
    Write-AqrColorLine -Tone PartialZone -Text '     usable in some AZs only'
    Write-AqrColorLine -Tone Unusable -Text '     restricted or not available'
    Write-AqrColorLine -Tone Header -Text '  >  current selection'

    if ($full) {
        Write-Host ''
        Write-AqrInfo "A newer generation is usable across all AZs: $(($full.Name) -join ', '). Raising quota there is often faster than on the older family."
    }
    elseif ($limited) {
        Write-Host ''
        Write-AqrWarn "A newer generation is usable but not in every AZ: $(($limited | ForEach-Object { "$($_.Name) (AZ $($_.UsableZones -join ','))" }) -join ', '). Pin the deployment to a usable zone."
    }
}

function Select-AqrVmSku {
    <#
    .SYNOPSIS
        Resolves a pasted SKU or family name to a VM SKU, then offers the same
        size in newer generations.
    .DESCRIPTION
        Accepts anything the tool prints: a SKU name (Standard_D4ads_v7), a
        short form (D4ads_v7), a quota family name (StandardDadsv7Family) or a
        family display name (Standard Dadsv7 Family vCPUs).
        Newer generations usually have more capacity and fewer zone
        restrictions, so raising quota on one of those is often the faster route
        than pushing the older family.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [switch]$NoSuggestion
    )

    Write-AqrStep "Loading VM SKUs for $Location (this takes a few seconds) ..."
    $skus = Get-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location
    Write-AqrInfo "$($skus.Count) VM SKUs available in $Location."

    if (-not $NoSuggestion) { Show-AqrUsedSkuFamily -SubscriptionId $SubscriptionId -Location $Location -Sku $skus }

    $picked = $null
    $familyMode = $false
    $pickedFamily = $null

    while (-not $picked) {
        $query = Read-AqrText -Prompt 'VM SKU, quota family, or search text (e.g. Standard_D4ads_v7, Dadsv7)'
        $result = Resolve-AqrSkuQuery -Query $query -Sku $skus

        switch ($result.Match) {
            'None' {
                Write-AqrWarn "Nothing matches '$query'. Enter a SKU name, a quota family, or part of either."
            }
            'Sku' { $picked = $result.Names[0] }
            'Family' {
                # Quota is granted per family in vCPUs, so the individual size is
                # irrelevant here - skip it and work at family level.
                Write-AqrInfo "'$query' is the quota family '$($result.Family)' ($($result.Names.Count) sizes). Quota is granted per family, so no size is needed."
                $familyMode = $true
                $pickedFamily = $result.Family
                $picked = $result.Names[0]
            }
            default {
                # Partial match: take it when unambiguous, otherwise let the user choose.
                if ($result.Names.Count -eq 1) {
                    $picked = $result.Names[0]
                    Write-AqrInfo "'$query' matched $picked."
                }
                else {
                    Write-AqrInfo "$($result.Names.Count) SKUs match '$query'."
                    $picked = Read-AqrChoice -Title "Matches for '$query'" -Option $result.Names
                }
            }
        }
    }

    if ($NoSuggestion) {
        return [pscustomobject]@{ Name = $picked; FamilyMode = $familyMode; Family = $pickedFamily }
    }

    if ($familyMode) {
        # Offer the same family in newer generations; each generation is its own
        # quota bucket, so this is a real choice, not cosmetic.
        $options = @(Get-AqrFamilyOption -SubscriptionId $SubscriptionId -Location $Location -Family $pickedFamily | Sort-Object Version)
        if ($options.Count -gt 1) {
            Show-AqrSkuOption -Option $options -Title 'QUOTA FAMILY'
            $labels = $options | ForEach-Object {
                $tag = if ($_.IsRequested) { ' (current selection)' }
                       elseif ($_.Status -notin 'Available', 'ZeroQuota') { ' (newer)' }
                       elseif ($_.Coverage -eq 'Partial') { " (newer, AZ $($_.UsableZones -join ',') only)" }
                       else { ' (newer, all AZs)' }
                # The example SKU is appended, not inserted: the selection below
                # matches on the two spaces that follow the display name.
                "$($_.DisplayName)  [$($_.Status)]$tag - e.g. $($_.Sizes[0])"
            }
            $choice = Read-AqrChoice -Title 'Which quota family should be raised?' -Option $labels
            $chosen = $options | Where-Object { $choice -like "$($_.DisplayName)  *" } | Select-Object -First 1
            $pickedFamily = $chosen.Name
            $picked = $chosen.Sizes[0]
        }
        return [pscustomobject]@{ Name = $picked; FamilyMode = $true; Family = $pickedFamily }
    }

    # Offer the same size in this and newer generations, if the region has any.
    $options = @(Get-AqrSkuOption -SubscriptionId $SubscriptionId -Location $Location -VmSku $picked)
    if ($options.Count -le 1) {
        return [pscustomobject]@{ Name = $picked; FamilyMode = $false; Family = $null }
    }

    Show-AqrSkuOption -Option $options -Title 'SKU'
    $labels = $options | ForEach-Object {
        $tag = if ($_.IsRequested) { ' (current selection)' }
               elseif ($_.Status -notin 'Available', 'ZeroQuota') { ' (newer)' }
               elseif ($_.Coverage -eq 'Partial') { " (newer, AZ $($_.UsableZones -join ',') only)" }
               else { ' (newer, all AZs)' }
        "$($_.Name)  [$($_.Status)]$tag"
    }
    $choice = Read-AqrChoice -Title 'Which SKU should the quota be raised for?' -Option $labels
    $name = ($options | Where-Object { $choice -like "$($_.Name)  *" } | Select-Object -First 1).Name
    [pscustomobject]@{ Name = $name; FamilyMode = $false; Family = $null }
}

function Resolve-AqrSkuQuota {
    <#
    .SYNOPSIS
        Resolves a VM SKU and its quota bucket, explaining exactly why a SKU is
        unusable and offering a way forward instead of ending the run.
    .OUTPUTS
        Object with VmSku, Sku, Quota, Availability and SkipAutomaticRequest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [string]$VmSku,
        [switch]$Spot,
        [switch]$NonInteractive
    )

    $pickAnother = 'Choose a different VM SKU'
    $viaSupport = 'Continue anyway and raise a support request for this SKU'
    $abort = 'Abort'

    while ($true) {
        $familyMode = $false
        if (-not $VmSku) {
            if ($NonInteractive) { throw 'No VM SKU specified.' }
            $selection = Select-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location
            $VmSku = $selection.Name
            $familyMode = $selection.FamilyMode
        }
        # Spot capacity is tracked in the regional low-priority pool, not per family.
        $quotaName = if ($Spot) { 'lowPriorityCores' } else { $null }

        try {
            $availability = Get-AqrSkuAvailability -SubscriptionId $SubscriptionId -Location $Location -VmSku $VmSku -QuotaName $quotaName
        }
        catch {
            Write-AqrWarn $_.Exception.Message
            if ($NonInteractive) { throw }
            $VmSku = $null
            continue
        }

        if ($availability.Status -in 'Available', 'ZeroQuota', 'ZoneRestricted') {
            if ($availability.Status -ne 'Available') { Write-AqrWarn "$($availability.Reason). $($availability.Detail)" }
            return [pscustomobject]@{
                VmSku = $availability.VmSku
                Sku = Resolve-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location -VmSku $availability.VmSku
                Quota = $availability.Quota
                Availability = $availability
                SkipAutomaticRequest = $false
                FamilyMode = $familyMode
            }
        }

        # Unusable: say why, then let the user decide how to continue.
        Write-AqrFail "$VmSku in $Location - $($availability.Reason)."
        Write-AqrInfo $availability.Detail

        if ($NonInteractive) { throw "$VmSku in $Location - $($availability.Reason). $($availability.Detail)" }

        $options = @($pickAnother)
        # Only a support request can unblock a restriction; a missing region cannot.
        if ($availability.SupportRequestAdvised) { $options += $viaSupport }
        $options += $abort

        $choice = Read-AqrChoice -Title 'How do you want to continue?' -Option $options
        if ($choice -eq $abort) { throw "Aborted: $VmSku is not usable in $Location." }
        if ($choice -eq $pickAnother) { $VmSku = $null; continue }

        # Support path: no bucket to read, so carry a synthetic zero-limit quota.
        $family = if ($availability.Family) { $availability.Family } else { $VmSku }
        $quota = if ($availability.Quota) { $availability.Quota } else {
            [pscustomobject]@{
                Name = $family
                LocalizedName = Get-AqrQuotaDisplayName -Family $family
                Location = $Location
                Limit = 0; Used = 0; Available = 0; Unit = 'Count'
                IsQuotaApplicable = $false; QuotaApiAvailable = $false; Unlimited = $false
            }
        }

        return [pscustomobject]@{
            VmSku = $VmSku
            Sku = Resolve-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location -VmSku $VmSku
            Quota = $quota
            Availability = $availability
            SkipAutomaticRequest = $true
            FamilyMode = $familyMode
        }
    }
}

function Show-AqrQuotaTable {
    <#
    .SYNOPSIS
        Prints the current quota picture before anything is changed.
    #>
    param([Parameter(Mandatory)][AllowNull()][array]$Quota)

    $rows = @($Quota | Where-Object { $_ })
    if (-not $rows) { return }

    Write-Host ''
    '  {0,-26} {1,-34} {2,8} {3,8} {4,10}' -f 'QUOTA', 'DISPLAY NAME', 'USED', 'LIMIT', 'AVAILABLE' | Write-Host -ForegroundColor DarkCyan
    foreach ($q in $rows) {
        $used = if ($null -ne $q.Used) { $q.Used } else { '?' }
        $free = if ($null -ne $q.Available) { $q.Available } else { '?' }
        $color = if ($null -ne $q.Available -and $q.Available -le 0) { 'Red' } elseif ($null -ne $q.Available -and $q.Available -lt 8) { 'Yellow' } else { 'Green' }
        '  {0,-26} {1,-34} {2,8} {3,8} {4,10}' -f $q.Name, $q.LocalizedName, $used, $q.Limit, $free | Write-Host -ForegroundColor $color
    }
}

function Invoke-AqrWizard {
    <#
    .SYNOPSIS
        Collects the missing inputs interactively.
    .OUTPUTS
        Hashtable with SubscriptionId, Location, VmSku and TargetVCores.
    #>
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [string]$Location,
        [string]$VmSku,
        [int]$TargetVCores,
        [switch]$Spot
    )

    # The subscription is already resolved in step 1 of the entry script.
    if (-not $SubscriptionId) { $SubscriptionId = (Get-AzContext).Subscription.Id }
    $locationInfo = if ($Location) { Get-AqrLocation -SubscriptionId $SubscriptionId -Location $Location } else { Select-AqrLocation -SubscriptionId $SubscriptionId }

    if (-not $VmSku) {
        $selection = Select-AqrVmSku -SubscriptionId $SubscriptionId -Location $locationInfo.Name
        $VmSku = $selection.Name
    }

    # Retries on an unusable SKU instead of ending the run.
    $resolved = Resolve-AqrSkuQuota -SubscriptionId $SubscriptionId -Location $locationInfo.Name -VmSku $VmSku -Spot:$Spot
    $sku = $resolved.Sku
    $quota = $resolved.Quota
    $VmSku = $resolved.VmSku
    $familyMode = [bool]$selection.FamilyMode

    $used = if ($null -ne $quota.Used) { $quota.Used } else { 0 }
    if ($familyMode) {
        Write-AqrInfo "Quota family '$($quota.LocalizedName)': limit $($quota.Limit), used $used."
    }
    else {
        Write-AqrInfo "$($sku.Name): $($sku.VCpus) vCPUs/instance, family '$($sku.Family)', limit $($quota.Limit), used $used."
    }

    if (-not $TargetVCores) {
        # In family mode there is no single size, so an instance count is meaningless.
        $askInstances = (-not $familyMode) -and (Read-AqrYesNo -Prompt 'Calculate the target from a number of VM instances instead of requesting exact vCores?' -Default $false)
        if ($askInstances) {
            $count = Read-AqrInt -Prompt "Instances of $($sku.Name) needed"
            $needed = $count * $sku.VCpus
            $TargetVCores = $used + $needed
            Write-AqrInfo "$count x $($sku.VCpus) vCPUs + $used in use = target limit $TargetVCores."
        }
        else {
            $TargetVCores = Read-AqrInt -Prompt "Target total vCPU limit for '$($quota.LocalizedName)'" -Default ([Math]::Max($quota.Limit * 2, $quota.Limit + [Math]::Max($sku.VCpus, 1)))
        }
    }

    @{
        SubscriptionId = $SubscriptionId
        Location       = $locationInfo.Name
        VmSku          = $sku.Name
        TargetVCores   = $TargetVCores
        Resolved       = $resolved
    }
}

Export-ModuleMember -Function @(
    'Show-AqrBanner', 'Read-AqrText', 'Read-AqrInt', 'Read-AqrYesNo', 'Read-AqrChoice', 'Read-AqrSearchChoice',
    'Select-AqrAzureContext', 'Select-AqrSubscription', 'Select-AqrTenant',
    'Select-AqrLocation', 'Select-AqrVmSku', 'Resolve-AqrSkuQuota',
    'Show-AqrUsedSkuFamily', 'Show-AqrSkuOption',
    'Show-AqrQuotaTable', 'Invoke-AqrWizard'
)
