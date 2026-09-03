<#
.SYNOPSIS
    Core helpers for AzQuotaRequester: ARM REST access, provider checks, SKU
    resolution, quota reads and automatic quota increase requests.
.NOTES
    Only Az.Accounts is required. Everything else goes through Invoke-AzRestMethod.
#>

# API versions used across the tool (kept in one place for easy maintenance).
$script:AqrApi = @{
    Quota    = '2023-02-01'
    Compute  = '2024-07-01'
    Skus     = '2021-07-01'
    Provider = '2021-04-01'
    Sub      = '2022-12-01'
    Support  = '2024-04-01'
}

#region console output ------------------------------------------------------

function Test-AqrAnsiSupport {
    <#
    .SYNOPSIS
        Tells whether the host renders ANSI colour escapes.
    .DESCRIPTION
        Without it the escapes would print as literal garbage, so the caller
        falls back to the plain console colours.
    #>
    if ($null -ne $script:AqrAnsi) { return $script:AqrAnsi }

    $script:AqrAnsi = $false
    if ($env:NO_COLOR) { return $script:AqrAnsi }
    try { $script:AqrAnsi = [bool]$Host.UI.SupportsVirtualTerminal } catch { $script:AqrAnsi = $false }
    $script:AqrAnsi
}

function Write-AqrColorLine {
    <#
    .SYNOPSIS
        Writes a line in one of the tool's semantic tones.
    .DESCRIPTION
        Tone carries one meaning only: how usable the entry is. The table tones
        are deliberately lighter than the [ok]/[warn]/[fail] colours, so a row
        is not mistaken for a result message.
          FullZone    - usable in every AZ of the region
          PartialZone - usable in some AZs only
          Unusable    - restricted, blocked, or not offered
        The entry the user came in with keeps its meaning and only gains
        intensity, so a healthy selection never reads as a problem:
          SelectedFull/SelectedPartial/SelectedUnusable
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('FullZone', 'PartialZone', 'Unusable',
            'SelectedFull', 'SelectedPartial', 'SelectedUnusable',
            'Header', 'Plain')][string]$Tone = 'Plain'
    )

    # 256-colour tones, chosen to sit apart from the status message colours.
    # Unselected rows are pastel; the selection is the saturated tone of the
    # same colour, so intensity says "this is yours" and hue says "this is how
    # usable it is".
    $ansi = @{
        FullZone         = 120; PartialZone     = 229; Unusable         = 88
        SelectedFull     = 40;  SelectedPartial = 208; SelectedUnusable = 196
        Header           = 117
    }
    $fallback = @{
        FullZone         = 'Green';     PartialZone     = 'Yellow';     Unusable         = 'DarkRed'
        SelectedFull     = 'DarkGreen'; SelectedPartial = 'DarkYellow'; SelectedUnusable = 'Red'
        Header           = 'DarkCyan'
    }

    if ($Tone -eq 'Plain') { Write-Host $Text; return }

    if (Test-AqrAnsiSupport) {
        $esc = [char]27
        Write-Host "$esc[38;5;$($ansi[$Tone])m$Text$esc[0m"
    }
    else {
        Write-Host $Text -ForegroundColor $fallback[$Tone]
    }
}

function Write-AqrHeadline {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "  $('-' * $Text.Length)" -ForegroundColor DarkCyan
}

function Write-AqrStep { param([string]$Text) Write-Host "  > $Text" -ForegroundColor Gray }
function Write-AqrOk   { param([string]$Text) Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-AqrWarn { param([string]$Text) Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-AqrFail { param([string]$Text) Write-Host "  [fail] $Text" -ForegroundColor Red }
function Write-AqrInfo { param([string]$Text) Write-Host "  $Text" -ForegroundColor White }

#endregion

#region ARM plumbing --------------------------------------------------------

function Invoke-AqrArm {
    <#
    .SYNOPSIS
        Thin wrapper around Invoke-AzRestMethod returning a normalised result.
    .DESCRIPTION
        Retries throttled (429) and transient server errors, honouring Retry-After.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'PUT', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [string]$Path,
        [string]$Uri,
        [string]$Payload,
        [int[]]$OkStatus = @(200, 201, 202),
        [int]$RetryCount = 4
    )

    $splat = @{ Method = $Method; ErrorAction = 'Stop' }
    if ($Uri)     { $splat.Uri = $Uri }     else { $splat.Path = $Path }
    if ($Payload) { $splat.Payload = $Payload }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $response = Invoke-AzRestMethod @splat
        }
        catch {
            return [pscustomobject]@{
                StatusCode = 0; Success = $false; Body = $null
                Raw = $_.Exception.Message; Response = $null
                ErrorMessage = $_.Exception.Message
            }
        }

        # Only reads and idempotent PUTs are retried; 429/5xx are transient.
        $transient = ($response.StatusCode -eq 429 -or $response.StatusCode -ge 500)
        if (-not $transient -or $attempt -gt $RetryCount) { break }

        $wait = [int](Get-AqrResponseHeader -Response $response -Name 'Retry-After')
        if ($wait -le 0) { $wait = [Math]::Min(30, [Math]::Pow(2, $attempt)) }
        # Cap it: a large Retry-After would otherwise look like a frozen tool.
        if ($wait -gt 60) { $wait = 60 }
        Write-AqrStep "ARM returned $($response.StatusCode); retrying in $wait s (attempt $attempt/$RetryCount)."
        Start-Sleep -Seconds $wait
    }

    $body = $null
    if ($response.Content) {
        try { $body = $response.Content | ConvertFrom-Json -ErrorAction Stop } catch { $body = $null }
    }

    # Surface the ARM error message when the call was not successful.
    $errorMessage = $null
    if ($response.StatusCode -notin $OkStatus) {
        if ($body -and $body.PSObject.Properties.Name -contains 'error' -and $body.error) {
            $errorMessage = "$($body.error.code): $($body.error.message)"
            # Microsoft.Support returns the actionable reason in error.details.
            $detail = @($body.error.details | Where-Object { $_.message }) | ForEach-Object { $_.message }
            if ($detail) { $errorMessage += " ($($detail -join ' | '))" }
        }
        else { $errorMessage = $response.Content }
    }

    [pscustomobject]@{
        StatusCode   = $response.StatusCode
        Success      = ($response.StatusCode -in $OkStatus)
        Body         = $body
        Raw          = $response.Content
        Response     = $response
        ErrorMessage = $errorMessage
    }
}

function Get-AqrResponseHeader {
    <#
    .SYNOPSIS
        Reads a single header value from an Invoke-AzRestMethod response.
    #>
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Response -or -not $Response.Headers) { return $null }
    $value = $null
    if ($Response.Headers.TryGetValues($Name, [ref]$value)) { return ($value | Select-Object -First 1) }
    return $null
}

#endregion

#region context & providers -------------------------------------------------

function Initialize-AqrContext {
    <#
    .SYNOPSIS
        Ensures an Azure sign-in exists and selects the requested tenant and
        subscription.
    .PARAMETER Reauthenticate
        Forces a fresh interactive sign-in even when a session already exists.
    #>
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [string]$TenantId,
        [switch]$Reauthenticate
    )

    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        throw 'Module Az.Accounts is not installed. Run: Install-Module Az.Accounts -Scope CurrentUser'
    }
    Import-Module Az.Accounts -ErrorAction Stop

    $context = Get-AzContext -ErrorAction SilentlyContinue

    if ($Reauthenticate -or -not $context) {
        Write-AqrStep 'Starting interactive Azure sign-in.'
        $connect = @{ ErrorAction = 'Stop' }
        if ($TenantId) { $connect.TenantId = $TenantId }
        if ($SubscriptionId) { $connect.SubscriptionId = $SubscriptionId }
        Connect-AzAccount @connect | Out-Null
        $context = Get-AzContext -ErrorAction Stop
    }

    # Switching tenant may need a new token, so fall back to a sign-in.
    if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
        Write-AqrStep "Switching context to tenant $TenantId."
        try { $context = Set-AzContext -Tenant $TenantId -ErrorAction Stop }
        catch {
            Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null
            $context = Get-AzContext -ErrorAction Stop
        }
    }

    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        Write-AqrStep "Switching context to subscription $SubscriptionId."
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }

    if (-not $context.Subscription) { throw 'The current Azure context has no subscription selected.' }

    [pscustomobject]@{
        SubscriptionId   = $context.Subscription.Id
        SubscriptionName = $context.Subscription.Name
        TenantId         = $context.Tenant.Id
        Account          = $context.Account.Id
    }
}

function Test-AqrResourceProvider {
    <#
    .SYNOPSIS
        Checks (and optionally registers) the resource providers the tool needs.
    .OUTPUTS
        One object per provider with its registration state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string[]]$Namespace = @('Microsoft.Compute', 'Microsoft.Quota', 'Microsoft.Support'),
        [switch]$Register,
        [int]$TimeoutSeconds = 180
    )

    foreach ($ns in $Namespace) {
        $get = Invoke-AqrArm -Path "/subscriptions/$SubscriptionId/providers/$($ns)?api-version=$($script:AqrApi.Provider)"
        $state = if ($get.Success) { $get.Body.registrationState } else { 'Unknown' }
        if (-not $get.Success) { Write-AqrWarn "Could not read provider $ns : $($get.ErrorMessage)" }

        if ($state -ne 'Registered' -and $Register) {
            Write-AqrStep "Registering resource provider $ns (current state: $state)."
            $reg = Invoke-AqrArm -Method POST -Path "/subscriptions/$SubscriptionId/providers/$ns/register?api-version=$($script:AqrApi.Provider)"
            if (-not $reg.Success) {
                Write-AqrWarn "Registration call for $ns failed: $($reg.ErrorMessage)"
            }
            else {
                # Registration is asynchronous - wait until it flips to Registered.
                $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                do {
                    Start-Sleep -Seconds 5
                    $poll = Invoke-AqrArm -Path "/subscriptions/$SubscriptionId/providers/$($ns)?api-version=$($script:AqrApi.Provider)"
                    $state = if ($poll.Success) { $poll.Body.registrationState } else { $state }
                } while ($state -ne 'Registered' -and (Get-Date) -lt $deadline)
            }
        }

        [pscustomobject]@{
            Namespace  = $ns
            State      = $state
            Registered = ($state -eq 'Registered')
        }
    }
}

function Get-AqrLocationList {
    <#
    .SYNOPSIS
        Returns the regions available to the subscription, cached per run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [switch]$Refresh
    )

    if (-not $script:AqrLocationCache) { $script:AqrLocationCache = @{} }
    if (-not $Refresh -and $script:AqrLocationCache.ContainsKey($SubscriptionId)) { return $script:AqrLocationCache[$SubscriptionId] }

    $result = Invoke-AqrArm -Path "/subscriptions/$SubscriptionId/locations?api-version=$($script:AqrApi.Sub)"
    if (-not $result.Success) { throw "Could not list regions: $($result.ErrorMessage)" }

    $script:AqrLocationCache[$SubscriptionId] = @($result.Body.value)
    $script:AqrLocationCache[$SubscriptionId]
}

function Get-AqrLocation {
    <#
    .SYNOPSIS
        Resolves a region name and returns the TitleCase form required by
        support-ticket quota payloads (for example westeurope -> WestEurope).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location
    )

    $locations = Get-AqrLocationList -SubscriptionId $SubscriptionId

    $normalized = $Location.Replace(' ', '').ToLowerInvariant()
    $match = $locations | Where-Object {
        $_.name -eq $normalized -or $_.displayName.Replace(' ', '').ToLowerInvariant() -eq $normalized
    } | Select-Object -First 1

    if (-not $match) { throw "Region '$Location' is not available for this subscription." }

    [pscustomobject]@{
        Name        = $match.name
        DisplayName = $match.displayName
        TitleCase   = ($match.displayName -replace '\s', '')
    }
}

#endregion

#region SKU & quota reads ---------------------------------------------------

function Get-AqrQuotaDisplayName {
    <#
    .SYNOPSIS
        Derives the quota display name from a family name when the region has no
        bucket to read it from, e.g. standardDSv5Family -> "Standard DSv5 Family vCPUs".
    #>
    param([Parameter(Mandatory)][string]$Family)

    $core = $Family -replace 'Family$', ''
    if ($core -match '^standard(.+)$') { $core = "Standard $($Matches[1])" }
    elseif ($core -match '^basic(.+)$') { $core = "Basic $($Matches[1])" }
    else { $core = $core.Substring(0, 1).ToUpperInvariant() + $core.Substring(1) }
    "$core Family vCPUs"
}

function Get-AqrSkuAvailability {
    <#
    .SYNOPSIS
        Explains whether a VM SKU can actually be used in a region, and why not.
    .DESCRIPTION
        Separates the cases that look alike from the outside:
          NotOfferedInRegion            - Azure does not list the SKU there at all.
          RestrictedBySubscriptionOffer - blocked by the subscription offer (reasonCode QuotaId).
          RestrictedForSubscription     - listed, but not enabled for this subscription.
          ZoneRestricted                - blocked in some zones only.
          NoQuotaBucket                 - listed and unrestricted, but the region has
                                          no quota bucket for the family.
          ZeroQuota                     - bucket exists with a limit of 0.
          Available                     - usable.
    .OUTPUTS
        Classification object. Quota is $null when the region has no bucket.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$VmSku,
        [string]$QuotaName
    )

    # The subscription offer explains a QuotaId restriction.
    $subInfo = Invoke-AqrArm -Path "/subscriptions/$($SubscriptionId)?api-version=$($script:AqrApi.Sub)"
    $offer = if ($subInfo.Success) { $subInfo.Body.subscriptionPolicies.quotaId } else { $null }

    $allSkus = Get-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location
    $sku = $allSkus | Where-Object { $_.name -eq $VmSku } | Select-Object -First 1

    # Accept a pasted name with different casing or separators.
    if (-not $sku) {
        $key = ConvertTo-AqrSkuKey -Text $VmSku
        $sku = $allSkus | Where-Object { (ConvertTo-AqrSkuKey -Text $_.name) -eq $key } | Select-Object -First 1
    }
    if ($sku) { $VmSku = $sku.name }

    $info = [ordered]@{
        VmSku                 = $VmSku
        Location              = $Location
        SubscriptionOffer     = $offer
        Listed                = [bool]$sku
        Family                = $sku.family
        VCpus                 = 0
        Zones                 = @()
        RestrictedZones       = @()
        Status                = 'NotOfferedInRegion'
        Reason                = $null
        Detail                = $null
        Quota                 = $null
        UsableZones           = @()
        CanRequestQuota       = $false
        SupportRequestAdvised = $false
    }

    if (-not $sku) {
        $info.Reason = 'The region does not offer this SKU'
        $info.Detail = "Azure does not list $VmSku in $Location at all. It is either not rolled out there yet or has been retired. A quota request cannot make it appear - pick another region or SKU."
        return [pscustomobject]$info
    }

    $info.VCpus = [int](($sku.capabilities | Where-Object name -EQ 'vCPUs' | Select-Object -First 1).value)
    $zoneInfo = Get-AqrSkuZoneInfo -Sku $sku
    $info.Zones = $zoneInfo.Zones

    $restrictions = @($sku.restrictions)
    $locationBlock = $restrictions | Where-Object { $_.type -eq 'Location' } | Select-Object -First 1
    $info.RestrictedZones = $zoneInfo.RestrictedZones
    $info.UsableZones = $zoneInfo.UsableZones

    if ($locationBlock) {
        $info.SupportRequestAdvised = $true
        if ($locationBlock.reasonCode -eq 'QuotaId') {
            $info.Status = 'RestrictedBySubscriptionOffer'
            $info.Reason = 'Blocked by the subscription offer'
            $info.Detail = "The subscription offer$(if ($offer) { " '$offer'" }) does not include $VmSku in $Location. Raising quota will not unblock it - a support request or a different offer is needed."
        }
        else {
            $info.Status = 'RestrictedForSubscription'
            $info.Reason = "Restricted for this subscription ($($locationBlock.reasonCode))"
            $info.Detail = "$VmSku exists in $Location but is not enabled for this subscription, usually a staged rollout or a capacity restriction. Access has to be requested through support."
        }
        return [pscustomobject]$info
    }

    if (-not $QuotaName) { $QuotaName = $sku.family }
    $quota = Get-AqrQuota -SubscriptionId $SubscriptionId -Location $Location -QuotaName $QuotaName
    $info.Quota = $quota

    if (-not $quota) {
        $info.Status = 'NoQuotaBucket'
        $info.Reason = 'No quota bucket in this region'
        $info.Detail = "$VmSku is offered in $Location and is not restricted, but the region exposes no quota bucket '$QuotaName' for this subscription. The family is not enabled here yet, so the automatic quota API cannot be used - a support request is the way in."
        $info.SupportRequestAdvised = $true
        return [pscustomobject]$info
    }

    if ($info.RestrictedZones.Count -gt 0 -and $info.UsableZones.Count -gt 0) {
        $info.Status = 'ZoneRestricted'
        $info.Reason = "Restricted in zone(s) $($info.RestrictedZones -join ', ')"
        $info.Detail = "$VmSku is usable in $Location in zone(s) $($info.UsableZones -join ', ') only. Quota can be requested normally, but pin the deployment to a usable zone."
        $info.CanRequestQuota = $true
        return [pscustomobject]$info
    }
    if ($info.RestrictedZones.Count -gt 0 -and $info.UsableZones.Count -eq 0) {
        # Every offered zone is blocked, so the SKU cannot be deployed at all.
        $info.Status = 'RestrictedForSubscription'
        $info.Reason = 'Restricted in every zone of this region'
        $info.Detail = "$VmSku is blocked in all zones ($($info.RestrictedZones -join ', ')) for this subscription in $Location. Access has to be requested through support."
        $info.SupportRequestAdvised = $true
        return [pscustomobject]$info
    }

    $info.CanRequestQuota = $true
    if ($quota.Limit -le 0) {
        $info.Status = 'ZeroQuota'
        $info.Reason = 'Quota bucket exists but the limit is 0'
        $info.Detail = "No capacity is allocated for '$($quota.LocalizedName)' in $Location yet. An increase can be requested, but Azure may answer QuotaNotAvailableForResource if the family is not deployable for this subscription there."
        return [pscustomobject]$info
    }

    $info.Status = 'Available'
    $info.Reason = 'Available'
    $info.Detail = "$VmSku is available in $Location with a limit of $($quota.Limit) and $($quota.Used) in use."
    [pscustomobject]$info
}

function Split-AqrSkuGeneration {
    <#
    .SYNOPSIS
        Splits a VM SKU name into its generation-independent stem and version.
    .DESCRIPTION
        Standard_D4s_v5 -> stem 'Standard_D4s', version 5.
        Standard_D4s    -> stem 'Standard_D4s', version 1 (v1 is implicit).
    #>
    param([Parameter(Mandatory)][string]$VmSku)

    if ($VmSku -match '^(?<stem>.+)_[vV](?<ver>\d+)$') {
        return [pscustomobject]@{ Stem = $Matches.stem; Version = [int]$Matches.ver }
    }
    [pscustomobject]@{ Stem = $VmSku; Version = 1 }
}

function Get-AqrRegionZone {
    <#
    .SYNOPSIS
        Returns the availability zones a region exposes to the subscription.
    .DESCRIPTION
        Needed to tell "this zone is not offered for the SKU" apart from
        "the region has no such zone at all". Cached per region.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location
    )

    if (-not $script:AqrRegionZoneCache) { $script:AqrRegionZoneCache = @{} }
    $cacheKey = "$SubscriptionId|$Location"
    if ($script:AqrRegionZoneCache.ContainsKey($cacheKey)) { return $script:AqrRegionZoneCache[$cacheKey] }

    $zones = @()
    try {
        $region = Get-AqrLocationList -SubscriptionId $SubscriptionId | Where-Object { $_.name -eq $Location } | Select-Object -First 1
        $zones = @($region.availabilityZoneMappings.logicalZone | Sort-Object -Unique)
    }
    catch { Write-Verbose "Could not read region zones: $($_.Exception.Message)" }

    $script:AqrRegionZoneCache[$cacheKey] = $zones
    $zones
}

function Get-AqrSkuZoneInfo {
    <#
    .SYNOPSIS
        Returns the zone picture for one SKU entry.
    .DESCRIPTION
        Separates the two reasons a zone cannot be used:
          not offered - the SKU is simply not available in that zone
          restricted  - the zone is offered but blocked for this subscription
        Coverage compares the usable zones against what the region provides:
          Full     - usable in every zone the region has
          Partial  - usable in some zones only
          None     - usable in no zone
          NonZonal - the region exposes no zones
    .PARAMETER RegionZone
        Zones the region provides. Without it, only the SKU's own zones are known.
    #>
    param(
        [Parameter(Mandatory)]$Sku,
        [string[]]$RegionZone = @()
    )

    $offered = @($Sku.locationInfo.zones | Sort-Object -Unique)
    $restricted = @($Sku.restrictions | Where-Object { $_.type -eq 'Zone' } | ForEach-Object { $_.restrictionInfo.zones } | Sort-Object -Unique)
    $usable = @($offered | Where-Object { $_ -notin $restricted })

    $regionZones = @($RegionZone | Sort-Object -Unique)
    if (-not $regionZones) { $regionZones = $offered }

    $notOffered = @($regionZones | Where-Object { $_ -notin $offered })
    $unavailable = @($regionZones | Where-Object { $_ -notin $usable })

    $coverage = if (-not $regionZones) { 'NonZonal' }
                elseif ($usable.Count -eq 0) { 'None' }
                elseif ($usable.Count -lt $regionZones.Count) { 'Partial' }
                else { 'Full' }

    [pscustomobject]@{
        Zones            = $offered
        RegionZones      = $regionZones
        RestrictedZones  = $restricted
        NotOfferedZones  = $notOffered
        UnavailableZones = $unavailable
        UsableZones      = $usable
        Coverage         = $coverage
        # Every offered zone blocked means the SKU is effectively unusable here.
        FullyRestricted  = ($offered.Count -gt 0 -and $usable.Count -eq 0)
    }
}

function Get-AqrSkuOption {
    <#
    .SYNOPSIS
        Proposes the requested VM SKU plus newer generations of the same size
        that are actually offered in the region.
    .DESCRIPTION
        For Standard_D4s_v5 this returns Standard_D4s_v5, _v6, _v7 ... but only
        those the region really offers, each annotated with its restriction and
        quota state so an unusable option is visible before it is picked.
    .PARAMETER IncludeOlder
        Also list older generations of the same size.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$VmSku,
        [switch]$IncludeOlder
    )

    $allSkus = Get-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location
    $buckets = Get-AqrComputeUsage -SubscriptionId $SubscriptionId -Location $Location

    $base = Split-AqrSkuGeneration -VmSku $VmSku
    $regionZones = Get-AqrRegionZone -SubscriptionId $SubscriptionId -Location $Location

    $candidates = foreach ($sku in $allSkus) {
        $g = Split-AqrSkuGeneration -VmSku $sku.name
        if ($g.Stem -ne $base.Stem) { continue }
        if (-not $IncludeOlder -and $g.Version -lt $base.Version) { continue }
        [pscustomobject]@{ Sku = $sku; Version = $g.Version }
    }

    foreach ($candidate in ($candidates | Sort-Object Version)) {
        $sku = $candidate.Sku
        $zone = Get-AqrSkuZoneInfo -Sku $sku -RegionZone $regionZones
        $locationBlock = $sku.restrictions | Where-Object { $_.type -eq 'Location' } | Select-Object -First 1
        $bucket = $buckets[$sku.family]

        $status = if ($locationBlock) { 'Restricted' }
                  elseif (-not $bucket) { 'NoQuotaBucket' }
                  elseif ($zone.FullyRestricted) { 'ZoneRestricted' }
                  elseif ([int]$bucket.limit -le 0) { 'ZeroQuota' }
                  else { 'Available' }

        [pscustomobject]@{
            Name             = $sku.name
            Version          = $candidate.Version
            IsRequested      = ($sku.name -eq $VmSku)
            Family           = $sku.family
            VCpus            = [int](($sku.capabilities | Where-Object name -EQ 'vCPUs' | Select-Object -First 1).value)
            Status           = $status
            RestrictionCode  = $locationBlock.reasonCode
            Zones            = $zone.Zones
            RegionZones      = $zone.RegionZones
            RestrictedZones  = $zone.RestrictedZones
            NotOfferedZones  = $zone.NotOfferedZones
            UnavailableZones = $zone.UnavailableZones
            UsableZones      = $zone.UsableZones
            Coverage         = $zone.Coverage
            Limit            = if ($bucket) { [int]$bucket.limit } else { $null }
            Used             = if ($bucket) { [int]$bucket.currentValue } else { $null }
            InUse            = ($bucket -and [int]$bucket.currentValue -gt 0)
        }
    }
}

function Get-AqrUsedSkuFamily {
    <#
    .SYNOPSIS
        Lists the compute quota families that already carry usage in a region.
    .PARAMETER IncludeAllocated
        Also return families with an allocated limit but no usage yet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [switch]$IncludeAllocated
    )

    $buckets = Get-AqrComputeUsage -SubscriptionId $SubscriptionId -Location $Location

    $buckets.Values |
        Where-Object { $_.name.value -match 'Family$' -and ($_.currentValue -gt 0 -or ($IncludeAllocated -and $_.limit -gt 0)) } |
        ForEach-Object {
            [pscustomobject]@{
                Name          = $_.name.value
                LocalizedName = $_.name.localizedValue
                Used          = [int]$_.currentValue
                Limit         = [int]$_.limit
            }
        } | Sort-Object -Property @{e = 'Used'; Descending = $true }, Name
}

function Get-AqrSkuSortKey {
    <#
    .SYNOPSIS
        Builds a natural sort key for a VM SKU name.
    .DESCRIPTION
        Plain alphabetical sorting puts Standard_D128ads_v7 before
        Standard_D2ads_v7. This sorts by the leading size number and the
        generation instead, so a menu reads in the order a human expects.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $size = 0
    if ($Name -match '^[A-Za-z_]*?(?<size>\d+)') { $size = [int]$Matches.size }
    $gen = 0
    if ($Name -match '_[vV](?<gen>\d+)$') { $gen = [int]$Matches.gen }

    # Stem first so different families stay grouped, then size, then generation.
    '{0}|{1:D5}|{2:D3}' -f ($Name -replace '\d+', '#'), $size, $gen
}

function Sort-AqrSkuName {
    <#
    .SYNOPSIS
        Sorts SKU names by family stem, then size, then generation.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Name)
    $Name | Sort-Object -Property @{ Expression = { Get-AqrSkuSortKey -Name $_ } }
}

function ConvertTo-AqrSkuKey {
    <#
    .SYNOPSIS
        Normalises a SKU or family string for tolerant comparison.
    .DESCRIPTION
        Lowercases and removes separators and the noise words that appear in
        quota display names, so 'Standard_D4ads_v7', 'standard d4ads v7' and
        'D4ADS-V7' all collapse to the same key.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $key = $Text.ToLowerInvariant()
    $key = $key -replace 'v?cpus?$', ''
    $key = $key -replace 'family', ''
    $key = $key -replace '[\s_\-]', ''
    $key = $key -replace '^standard', ''
    $key = $key -replace '^basic', ''
    $key.Trim()
}

function Resolve-AqrSkuQuery {
    <#
    .SYNOPSIS
        Resolves free-text input to VM SKU names, accepting a SKU name, a quota
        family name or a quota family display name.
    .DESCRIPTION
        Lets the user paste anything the tool prints: 'Standard_D4ads_v7',
        'D4ads_v7', 'StandardDadsv7Family' or 'Standard Dadsv7 Family vCPUs'.
        Matching is tried in order of confidence so an exact SKU name always
        wins over a family match.
    .OUTPUTS
        Object with Match ('Sku' / 'Family' / 'Partial' / 'None'), Names and Family.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][array]$Sku
    )

    $key = ConvertTo-AqrSkuKey -Text $Query
    $empty = [pscustomobject]@{ Match = 'None'; Names = @(); Family = $null }
    if (-not $key) { return $empty }

    # 1) exact SKU name, separator and case tolerant
    $exact = @($Sku | Where-Object { (ConvertTo-AqrSkuKey -Text $_.name) -eq $key })
    if ($exact) { return [pscustomobject]@{ Match = 'Sku'; Names = @(Sort-AqrSkuName -Name ($exact.name | Sort-Object -Unique)); Family = $exact[0].family } }

    # 2) quota family, by family name or by its display name
    $family = @($Sku | Where-Object { $_.family -and (ConvertTo-AqrSkuKey -Text $_.family) -eq $key })
    if ($family) {
        return [pscustomobject]@{
            Match  = 'Family'
            Names  = @(Sort-AqrSkuName -Name ($family.name | Sort-Object -Unique))
            Family = $family[0].family
        }
    }

    # 3) substring, over SKU names and family names alike
    $partial = @($Sku | Where-Object {
            (ConvertTo-AqrSkuKey -Text $_.name).Contains($key) -or
            ($_.family -and (ConvertTo-AqrSkuKey -Text $_.family).Contains($key))
        })
    if ($partial) { return [pscustomobject]@{ Match = 'Partial'; Names = @(Sort-AqrSkuName -Name ($partial.name | Sort-Object -Unique)); Family = $null } }

    $empty
}

function Get-AqrFamilyOption {
    <#
    .SYNOPSIS
        Proposes the requested quota family plus newer generations of it.
    .DESCRIPTION
        Each generation is its own quota bucket, and the family name does not
        follow a predictable pattern (standardDADSv5Family -> standardDadv6Family
        -> StandardDadsv7Family). The newer generations are therefore derived
        from the SKU names in the family, not from the family name itself.
    .PARAMETER IncludeOlder
        Also list older generations of the same family.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Family,
        [switch]$IncludeOlder
    )

    $allSkus = Get-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location
    $buckets = Get-AqrComputeUsage -SubscriptionId $SubscriptionId -Location $Location

    $baseSkus = @($allSkus | Where-Object { $_.family -eq $Family })
    if (-not $baseSkus) { return @() }

    $regionZones = Get-AqrRegionZone -SubscriptionId $SubscriptionId -Location $Location
    $baseVersion = (Split-AqrSkuGeneration -VmSku $baseSkus[0].name).Version
    $stems = @($baseSkus | ForEach-Object { (Split-AqrSkuGeneration -VmSku $_.name).Stem } | Sort-Object -Unique)

    # Every SKU that is the same size as one in the base family.
    $related = @($allSkus | Where-Object {
            $g = Split-AqrSkuGeneration -VmSku $_.name
            $g.Stem -in $stems -and ($IncludeOlder -or $g.Version -ge $baseVersion)
        })

    foreach ($group in ($related | Group-Object -Property family)) {
        $familyName = $group.Name
        if (-not $familyName) { continue }

        $members = @($group.Group)
        $version = (Split-AqrSkuGeneration -VmSku $members[0].name).Version
        $bucket = $buckets[$familyName]
        $zoneInfos = @($members | ForEach-Object { Get-AqrSkuZoneInfo -Sku $_ -RegionZone $regionZones })

        $restricted = @($members | Where-Object { $_.restrictions | Where-Object { $_.type -eq 'Location' } })
        # A zone counts as usable for the family when any size can use it.
        $usableZones = @($zoneInfos | ForEach-Object { $_.UsableZones } | Sort-Object -Unique)
        $blockedZones = @($zoneInfos | ForEach-Object { $_.RestrictedZones } | Sort-Object -Unique)
        $unavailable = @($regionZones | Where-Object { $_ -notin $usableZones })
        $notOffered = @($unavailable | Where-Object { $_ -notin $blockedZones })

        $coverage = if (-not $regionZones) { 'NonZonal' }
                    elseif ($usableZones.Count -eq 0) { 'None' }
                    elseif ($usableZones.Count -lt $regionZones.Count) { 'Partial' }
                    else { 'Full' }

        $status = if ($restricted.Count -eq $members.Count) { 'Restricted' }
                  elseif (-not $bucket) { 'NoQuotaBucket' }
                  elseif ($usableZones.Count -eq 0 -and $blockedZones.Count -gt 0) { 'ZoneRestricted' }
                  elseif ([int]$bucket.limit -le 0) { 'ZeroQuota' }
                  else { 'Available' }

        [pscustomobject]@{
            Name             = $familyName
            DisplayName      = if ($bucket) { $bucket.name.localizedValue } else { Get-AqrQuotaDisplayName -Family $familyName }
            Version          = $version
            IsRequested      = ($familyName -eq $Family)
            Sizes            = @(Sort-AqrSkuName -Name ($members.name | Sort-Object -Unique))
            VCpus            = 0
            Status           = $status
            RestrictionCode  = ($restricted | Select-Object -First 1).restrictions.reasonCode | Select-Object -First 1
            Zones            = @($zoneInfos | ForEach-Object { $_.Zones } | Sort-Object -Unique)
            RegionZones      = $regionZones
            RestrictedZones  = $blockedZones
            NotOfferedZones  = $notOffered
            UnavailableZones = $unavailable
            UsableZones      = $usableZones
            Coverage         = $coverage
            Limit            = if ($bucket) { [int]$bucket.limit } else { $null }
            Used             = if ($bucket) { [int]$bucket.currentValue } else { $null }
            InUse            = ($bucket -and [int]$bucket.currentValue -gt 0)
        }
    }
}

function Clear-AqrCache {
    <#
    .SYNOPSIS
        Drops the cached SKU, region and usage lists.
    #>
    [CmdletBinding()]
    param()
    $script:AqrSkuCache = @{}
    $script:AqrLocationCache = @{}
    $script:AqrRegionZoneCache = @{}
}

function Get-AqrVmSku {
    <#
    .SYNOPSIS
        Returns the raw virtualMachines SKU entries for a region.
    .DESCRIPTION
        The list is large (1000+ entries per region) and several steps need it,
        so it is fetched once per subscription and region and then reused. Use
        Clear-AqrCache to force a refresh.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [switch]$Refresh
    )

    if (-not $script:AqrSkuCache) { $script:AqrSkuCache = @{} }
    $cacheKey = "$SubscriptionId|$Location"
    if (-not $Refresh -and $script:AqrSkuCache.ContainsKey($cacheKey)) { return $script:AqrSkuCache[$cacheKey] }

    $filter = [uri]::EscapeDataString("location eq '$Location'")
    $result = Invoke-AqrArm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/skus?api-version=$($script:AqrApi.Skus)&`$filter=$filter"
    if (-not $result.Success) { throw "Could not list VM SKUs: $($result.ErrorMessage)" }

    $skus = @($result.Body.value | Where-Object { $_.resourceType -eq 'virtualMachines' })
    $script:AqrSkuCache[$cacheKey] = $skus
    $skus
}

function Get-AqrComputeUsage {
    <#
    .SYNOPSIS
        Returns the compute usage entries for a region, keyed by quota name.
    .DESCRIPTION
        Cached per subscription and region, but always refreshed after a quota
        change so a limit is never read from a stale snapshot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [switch]$Refresh
    )

    if (-not $script:AqrUsageCache) { $script:AqrUsageCache = @{} }
    $cacheKey = "$SubscriptionId|$Location"
    if (-not $Refresh -and $script:AqrUsageCache.ContainsKey($cacheKey)) { return $script:AqrUsageCache[$cacheKey] }

    $usages = Invoke-AqrArm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location/usages?api-version=$($script:AqrApi.Compute)"
    if (-not $usages.Success) { throw "Could not read compute usages in '$Location': $($usages.ErrorMessage)" }

    $map = @{}
    foreach ($u in $usages.Body.value) { $map[$u.name.value] = $u }
    $script:AqrUsageCache[$cacheKey] = $map
    $map
}

function Resolve-AqrVmSku {
    <#
    .SYNOPSIS
        Maps a VM SKU (Standard_D4s_v5) to its quota family and vCPU count.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$VmSku
    )

    $allSkus = Get-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location
    $sku = $allSkus | Where-Object { $_.name -eq $VmSku } | Select-Object -First 1

    # Accept a pasted name with different casing or separators.
    if (-not $sku) {
        $key = ConvertTo-AqrSkuKey -Text $VmSku
        $sku = $allSkus | Where-Object { (ConvertTo-AqrSkuKey -Text $_.name) -eq $key } | Select-Object -First 1
    }

    if (-not $sku) { throw "VM SKU '$VmSku' is not offered in region '$Location'." }

    $vcpu = ($sku.capabilities | Where-Object name -EQ 'vCPUs' | Select-Object -First 1).value
    # A SKU can be blocked for the subscription even though it exists in the region.
    $restriction = $sku.restrictions | Where-Object { $_.reasonCode } | Select-Object -First 1

    [pscustomobject]@{
        Name            = $sku.name
        Family          = $sku.family
        VCpus           = [int]$vcpu
        Zones           = ($sku.locationInfo.zones | Sort-Object)
        RestrictionCode = $restriction.reasonCode
    }
}

function Get-AqrVmSkuName {
    <#
    .SYNOPSIS
        Returns all VM SKU names available in a region (used by the console UI).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [string]$Filter
    )

    $names = Get-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location | Select-Object -ExpandProperty name -Unique
    if ($Filter) { $names = $names | Where-Object { $_ -like "*$Filter*" } }
    $names | Sort-Object
}

function Get-AqrQuota {
    <#
    .SYNOPSIS
        Reads the current limit and usage for one compute quota bucket.
    .DESCRIPTION
        The usages endpoint is the authoritative list of quota buckets for a
        region and already carries limit and current value, so it is used as the
        source of truth. Microsoft.Quota is queried on top for isQuotaApplicable,
        but it does not know every family and must not break the flow when it
        rejects a name.
    .PARAMETER QuotaName
        Quota resource name, for example standardDSv5Family, cores, lowPriorityCores.
    .OUTPUTS
        The quota object, or $null when the region has no such bucket.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$QuotaName
    )

    $base = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location"

    # Always read fresh: this is the value a request is decided on, and a quota
    # change made moments ago must not be missed. It refreshes the shared cache.
    $buckets = Get-AqrComputeUsage -SubscriptionId $SubscriptionId -Location $Location -Refresh

    # The hashtable lookup is case-insensitive, which also absorbs casing
    # differences between the SKU family property and the quota bucket name.
    $usage = $buckets[$QuotaName]
    if (-not $usage) { return $null }

    $exactName = $usage.name.value
    $limit = [int]$usage.limit
    $applicable = $true

    $quota = Invoke-AqrArm -Path "$base/providers/Microsoft.Quota/quotas/$($exactName)?api-version=$($script:AqrApi.Quota)"
    if ($quota.Success) {
        $limit = [int]$quota.Body.properties.limit.value
        $applicable = [bool]$quota.Body.properties.isQuotaApplicable
    }
    else {
        Write-Verbose "Microsoft.Quota could not read '$exactName' ($($quota.ErrorMessage)). Falling back to the usages API."
    }

    [pscustomobject]@{
        Name              = $exactName
        LocalizedName     = $usage.name.localizedValue
        Location          = $Location
        Limit             = $limit
        Used              = [int]$usage.currentValue
        Available         = $limit - [int]$usage.currentValue
        Unit              = 'Count'
        IsQuotaApplicable = $applicable
        QuotaApiAvailable = $quota.Success
        Unlimited         = ($limit -lt 0)
    }
}

#endregion

#region automatic quota increase -------------------------------------------

function Request-AqrQuotaIncrease {
    <#
    .SYNOPSIS
        Submits an automatic quota increase through Microsoft.Quota and waits
        for the outcome.
    .OUTPUTS
        Object with Outcome (Succeeded / Failed / Error), NeedsSupportTicket and Message.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$QuotaName,
        [Parameter(Mandatory)][int]$NewLimit,
        [int]$TimeoutSeconds = 600,
        [int]$PollSeconds = 15
    )

    # The limit may have moved since it was read - raising a family quota often
    # makes Azure raise the regional total as a side effect. Re-read first, so a
    # stale value cannot turn into a request that LOWERS the live quota.
    $current = Get-AqrQuota -SubscriptionId $SubscriptionId -Location $Location -QuotaName $QuotaName
    if ($current) {
        if ($current.Limit -ge $NewLimit) {
            return [pscustomobject]@{
                Outcome = 'Succeeded'; NeedsSupportTicket = $false; State = 'AlreadySatisfied'
                Message = "Quota '$QuotaName' is already $($current.Limit) (>= $NewLimit). Nothing requested."
                RequestId = $null; ActualLimit = $current.Limit
            }
        }
        $QuotaName = $current.Name
    }

    $uriPath = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location/providers/Microsoft.Quota/quotas/$($QuotaName)?api-version=$($script:AqrApi.Quota)"
    $body = @{
        properties = @{
            limit = @{ limitObjectType = 'LimitValue'; value = $NewLimit }
            name  = @{ value = $QuotaName }
        }
    } | ConvertTo-Json -Depth 5

    if (-not $PSCmdlet.ShouldProcess("$QuotaName in $Location", "Request new quota limit $NewLimit")) {
        return [pscustomobject]@{
            Outcome = 'Skipped'; NeedsSupportTicket = $false
            Message = 'Automatic quota request skipped (WhatIf).'; State = 'Skipped'; RequestId = $null; ActualLimit = $null
        }
    }

    $put = Invoke-AqrArm -Method PUT -Path $uriPath -Payload $body -OkStatus @(200, 201, 202)

    if (-not $put.Success) {
        return [pscustomobject]@{
            Outcome = 'Error'; NeedsSupportTicket = $true; State = 'Rejected'
            Message = "Microsoft.Quota rejected the request (HTTP $($put.StatusCode)): $($put.ErrorMessage)"
            RequestId = $null; ActualLimit = $null
        }
    }

    # 200 means the new limit was applied synchronously.
    if ($put.StatusCode -eq 200 -and $put.Body.properties.limit.value -ge $NewLimit) {
        return [pscustomobject]@{
            Outcome = 'Succeeded'; NeedsSupportTicket = $false; State = 'Succeeded'
            Message = "Quota '$QuotaName' is now $($put.Body.properties.limit.value)."
            RequestId = $put.Body.name; ActualLimit = [int]$put.Body.properties.limit.value
        }
    }

    $pollUri = Get-AqrResponseHeader -Response $put.Response -Name 'Location'
    if (-not $pollUri) { $pollUri = Get-AqrResponseHeader -Response $put.Response -Name 'Azure-AsyncOperation' }

    if (-not $pollUri) {
        # No async handle: fall back to re-reading the quota until it moves.
        return Wait-AqrQuotaValue -SubscriptionId $SubscriptionId -Location $Location -QuotaName $QuotaName -NewLimit $NewLimit -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
    }

    Write-AqrStep "Request accepted, polling status every $PollSeconds s (timeout $TimeoutSeconds s)."
    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $state = 'InProgress'
    $message = 'Quota request still in progress.'
    $errorCode = $null

    # The operation id is the last path segment of the polling URI and is also
    # the quotaRequests id, which carries the detailed result.
    $requestId = (($pollUri -split '\?')[0]).TrimEnd('/').Split('/')[-1]

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $poll = Invoke-AqrArm -Uri $pollUri
        if (-not $poll.Success) { $message = "Polling failed (HTTP $($poll.StatusCode)): $($poll.ErrorMessage)"; break }

        $props = $poll.Body.properties
        if (-not $props) {
            # Nothing to read yet: say so rather than looping silently.
            $waited = [int]((Get-Date) - $started).TotalSeconds
            Write-AqrStep "Waiting for the operation to report a state ($waited s)."
            continue
        }

        $state = $props.provisioningState
        if ($state -in @('Succeeded', 'Failed', 'Invalid', 'Canceled')) { break }
        $waited = [int]((Get-Date) - $started).TotalSeconds
        Write-AqrStep "State: $state ($waited s of max $TimeoutSeconds s)"
    }

    # operationsStatus only returns the state, so read the quota request record
    # for the message and the ContactSupport error code.
    $detail = Get-AqrQuotaRequestDetail -SubscriptionId $SubscriptionId -Location $Location -RequestId $requestId
    if ($detail) {
        if ($detail.State) { $state = $detail.State }
        if ($detail.Message) { $message = $detail.Message }
        $errorCode = $detail.ErrorCode
    }

    switch ($state) {
        'Succeeded' {
            # Never trust the state alone: re-read the quota and report the real
            # limit, so a partial grant is not announced as the full request.
            $actual = Get-AqrQuota -SubscriptionId $SubscriptionId -Location $Location -QuotaName $QuotaName
            if (-not $actual) {
                [pscustomobject]@{
                    Outcome = 'Failed'; NeedsSupportTicket = $true; State = 'Unverified'
                    Message = "Azure reported success for '$QuotaName', but the quota could not be read back to confirm it."
                    RequestId = $requestId; ActualLimit = $null
                }
            }
            elseif ($actual.Limit -ge $NewLimit) {
                [pscustomobject]@{
                    Outcome = 'Succeeded'; NeedsSupportTicket = $false; State = $state
                    Message = "Quota '$QuotaName' is now $($actual.Limit). $message"
                    RequestId = $requestId; ActualLimit = $actual.Limit
                }
            }
            else {
                [pscustomobject]@{
                    Outcome = 'Partial'; NeedsSupportTicket = $true; State = 'PartiallyApproved'
                    Message = "Azure reported success for '$QuotaName', but the limit is $($actual.Limit) and $NewLimit was requested."
                    RequestId = $requestId; ActualLimit = $actual.Limit
                }
            }
        }
        { $_ -in 'Failed', 'Invalid', 'Canceled' } {
            $hint = switch ($errorCode) {
                'ContactSupport' { ' Azure will not auto-approve this increase, so a support request is required.' }
                'QuotaNotAvailableForResource' { ' No capacity is allocated for this family in this region for the subscription, so the limit cannot be raised automatically.' }
                default { '' }
            }
            [pscustomobject]@{
                Outcome = 'Failed'; NeedsSupportTicket = $true; State = $state
                Message = "Automatic request $state$(if ($errorCode) { " ($errorCode)" }): $message$hint"
                RequestId = $requestId; ActualLimit = $null
            }
        }
        default {
            [pscustomobject]@{
                Outcome = 'Timeout'; NeedsSupportTicket = $true; State = $state
                Message = "Automatic request did not complete within $TimeoutSeconds s. Last state: $state. $message"
                RequestId = $requestId
            }
        }
    }
}

function Get-AqrQuotaRequestDetail {
    <#
    .SYNOPSIS
        Reads the detailed result of a submitted quota request.
    .NOTES
        The operationsStatus endpoint only returns the provisioning state, while
        the quotaRequests record carries the message and the error code
        (ContactSupport = escalate to a support request).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$RequestId
    )

    $result = Invoke-AqrArm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location/providers/Microsoft.Quota/quotaRequests/$($RequestId)?api-version=$($script:AqrApi.Quota)"
    if (-not $result.Success -or -not $result.Body.properties) { return $null }

    $props = $result.Body.properties
    [pscustomobject]@{
        RequestId = $result.Body.name
        State     = $props.provisioningState
        Message   = $props.message
        ErrorCode = if ($props.PSObject.Properties.Name -contains 'error' -and $props.error) { $props.error.code } else { $null }
    }
}

function Wait-AqrQuotaValue {
    <#
    .SYNOPSIS
        Fallback watcher used when the quota PUT returns no polling header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$QuotaName,
        [Parameter(Mandatory)][int]$NewLimit,
        [int]$TimeoutSeconds = 300,
        [int]$PollSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $current = Get-AqrQuota -SubscriptionId $SubscriptionId -Location $Location -QuotaName $QuotaName
        if ($current) { $last = $current.Limit }
        if ($current -and $current.Limit -ge $NewLimit) {
            return [pscustomobject]@{
                Outcome = 'Succeeded'; NeedsSupportTicket = $false; State = 'Succeeded'
                Message = "Quota '$QuotaName' is now $($current.Limit)."; RequestId = $null; ActualLimit = $current.Limit
            }
        }
    }

    [pscustomobject]@{
        Outcome = 'Timeout'; NeedsSupportTicket = $true; State = 'Unknown'
        Message = "Quota '$QuotaName' did not reach $NewLimit within $TimeoutSeconds s (still $last)."
        RequestId = $null; ActualLimit = $last
    }
}

#endregion

Export-ModuleMember -Function @(
    'Write-AqrHeadline', 'Write-AqrStep', 'Write-AqrOk', 'Write-AqrWarn', 'Write-AqrFail', 'Write-AqrInfo',
    'Write-AqrColorLine', 'Test-AqrAnsiSupport',
    'Invoke-AqrArm', 'Get-AqrResponseHeader',
    'Initialize-AqrContext', 'Test-AqrResourceProvider', 'Get-AqrLocation',
    'Resolve-AqrVmSku', 'Get-AqrVmSkuName', 'Get-AqrQuota',
    'Get-AqrSkuAvailability', 'Get-AqrQuotaDisplayName',
    'Split-AqrSkuGeneration', 'Get-AqrSkuZoneInfo', 'Get-AqrSkuOption', 'Get-AqrUsedSkuFamily',
    'Get-AqrRegionZone', 'Get-AqrLocationList', 'Get-AqrComputeUsage', 'Clear-AqrCache',
    'ConvertTo-AqrSkuKey', 'Resolve-AqrSkuQuery', 'Get-AqrVmSku',
    'Get-AqrSkuSortKey', 'Sort-AqrSkuName', 'Get-AqrFamilyOption',
    'Request-AqrQuotaIncrease', 'Get-AqrQuotaRequestDetail', 'Wait-AqrQuotaValue'
)
