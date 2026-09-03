<#
.SYNOPSIS
    MCP server exposing AzQuotaRequester to local MCP clients (GitHub Copilot
    CLI, VS Code, and anything else speaking MCP over stdio).

.DESCRIPTION
    Speaks JSON-RPC 2.0 over stdio, newline delimited, per the MCP stdio
    transport. It runs on your machine and uses the Azure context you are
    already signed in with, so quota reads and requests happen under your own
    RBAC - no hosting, no app registration, no on-behalf-of exchange.

    Cloud-hosted Copilot surfaces (Microsoft 365 Copilot, Copilot Studio) cannot
    talk to this server: their plugin manifests only accept a remote HTTPS URL.
    This is for local MCP clients.

.PARAMETER LogPath
    Optional file for diagnostics. Nothing is ever written to stdout except
    JSON-RPC, so a log file is the only way to see what the server is doing.

.EXAMPLE
    copilot mcp add azquota -- pwsh -NoProfile -File C:\path\mcp\Start-AqrMcpServer.ps1
#>
[CmdletBinding()]
param(
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- stdout guard -----------------------------------------------------------
# The Core/UI modules report progress with Write-Host, which lands on stdout
# and would corrupt the JSON-RPC stream. Redirecting per call is one forgotten
# call away from a broken protocol, so the real stdout is captured once and the
# console is blackholed process-wide. Write-Host, warnings and stray pipeline
# output then go nowhere, and only $Rpc can reach the client.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$Rpc = [Console]::Out
[Console]::SetOut([System.IO.StreamWriter]::Null)

$ServerName = 'azquotarequester'
$ServerVersion = '1.0.0'
# Echoed back when the client asks for one of these; otherwise ours is returned.
$KnownProtocols = @('2024-11-05', '2025-03-26', '2025-06-18')
$DefaultProtocol = '2025-06-18'

$ModuleRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$script:ModulesLoaded = $false

function Write-AqrMcpLog {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $LogPath) { return }
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
        Add-Content -Path $LogPath -Value $line -Encoding utf8
    }
    catch { }
}

function Send-AqrMcpMessage {
    <#
    .SYNOPSIS
        Writes one JSON-RPC message as a single line.
    .DESCRIPTION
        -Compress matters: the stdio transport forbids embedded newlines.
        -Depth is explicit because ConvertTo-Json silently truncates at 2.
    #>
    param([Parameter(Mandatory)][hashtable]$Message)

    $json = $Message | ConvertTo-Json -Depth 20 -Compress
    $Rpc.WriteLine($json)
    $Rpc.Flush()
    Write-AqrMcpLog "-> $json" 'TRACE'
}

function Send-AqrMcpResult {
    param([Parameter(Mandatory)]$Id, $Result)
    Send-AqrMcpMessage -Message @{ jsonrpc = '2.0'; id = $Id; result = $Result }
}

function Send-AqrMcpError {
    param($Id, [int]$Code, [string]$MessageText)
    Send-AqrMcpMessage -Message @{
        jsonrpc = '2.0'; id = $Id
        error   = @{ code = $Code; message = $MessageText }
    }
}

function Initialize-AqrMcpModule {
    <#
    .SYNOPSIS
        Loads the tool modules on first use.
    .DESCRIPTION
        Deliberately not done at startup: MCP clients time out if initialize is
        slow, and importing Az.Accounts takes seconds.
    #>
    if ($script:ModulesLoaded) { return }
    Import-Module (Join-Path $ModuleRoot 'AzQuotaRequester.Core.psm1') -DisableNameChecking -Global
    $script:ModulesLoaded = $true
    Write-AqrMcpLog 'Core module loaded'
}

function Get-AqrMcpContext {
    <#
    .SYNOPSIS
        Resolves the Azure context, optionally for a specific subscription.
    .DESCRIPTION
        Never signs in interactively - there is no terminal attached to an MCP
        server, so a login prompt would hang the client forever.
    #>
    param([string]$SubscriptionId)

    Initialize-AqrMcpModule
    $ctx = Get-AzContext
    if (-not $ctx) {
        throw 'Not signed in to Azure. Run Connect-AzAccount in a normal PowerShell session, then retry.'
    }

    if ($SubscriptionId -and $ctx.Subscription.Id -ne $SubscriptionId) {
        $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
        $ctx = Get-AzContext
    }

    [pscustomobject]@{
        subscriptionId   = $ctx.Subscription.Id
        subscriptionName = $ctx.Subscription.Name
        tenantId         = $ctx.Tenant.Id
        account          = $ctx.Account.Id
    }
}

function Resolve-AqrMcpLocation {
    <#
    .SYNOPSIS
        Accepts a region name or display name and returns the canonical form.
    #>
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Location)

    $info = Get-AqrLocation -SubscriptionId $SubscriptionId -Location $Location
    if (-not $info -or -not $info.Name) { throw "Unknown Azure region '$Location'." }
    $info
}

function Resolve-AqrMcpSku {
    <#
    .SYNOPSIS
        Turns free-form SKU input into a concrete SKU or quota family.
    .DESCRIPTION
        Reuses the resolver the console tool uses, so 'dadsv7',
        'Standard_D4ads_v7' and the family display name all work. An ambiguous
        query returns the candidates instead of guessing, because silently
        picking one could raise quota on the wrong family.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Query
    )

    $skus = Get-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location
    $match = Resolve-AqrSkuQuery -Query $Query -Sku $skus
    $names = @($match.Names)

    if ($match.Match -eq 'Family') {
        return [pscustomobject]@{ IsFamily = $true; Name = $match.Family; Family = $match.Family }
    }
    if ($match.Match -eq 'Sku' -or ($match.Match -eq 'Partial' -and $names.Count -eq 1)) {
        $name = $names[0]
        $family = if ($match.Family) { $match.Family } else { ($skus | Where-Object { $_.name -eq $name } | Select-Object -First 1).family }
        return [pscustomobject]@{ IsFamily = $false; Name = $name; Family = $family }
    }
    if ($match.Match -eq 'Partial') {
        throw ("'$Query' matches {0} SKUs: {1}{2}. Ask the user which one is meant." -f `
                $names.Count, (($names | Select-Object -First 12) -join ', '), $(if ($names.Count -gt 12) { ', ...' } else { '' }))
    }
    throw "'$Query' is not a known VM SKU or quota family in $Location."
}

function New-AqrMcpToolResult {
    <#
    .SYNOPSIS
        Wraps a payload as an MCP tool result.
    .DESCRIPTION
        The payload is returned as pretty JSON text rather than
        structuredContent, because structuredContent is only valid when the tool
        declares an outputSchema and stricter clients reject it otherwise.
    #>
    param($Payload, [switch]$IsError)

    $text = if ($Payload -is [string]) { $Payload } else { $Payload | ConvertTo-Json -Depth 20 }
    @{
        content = @(@{ type = 'text'; text = $text })
        isError = [bool]$IsError
    }
}

function Get-AqrMcpArgument {
    <#
    .SYNOPSIS
        Reads one argument from the deserialized JSON params.
    .DESCRIPTION
        Goes through a helper because StrictMode turns a missing property into a
        terminating error rather than $null.
    #>
    param($Arguments, [Parameter(Mandatory)][string]$Key, $Default = $null)

    if (-not $Arguments) { return $Default }
    if ($Arguments.PSObject.Properties.Name -notcontains $Key) { return $Default }
    if ($null -eq $Arguments.$Key) { return $Default }
    $Arguments.$Key
}

# --- tools ------------------------------------------------------------------

function Get-AqrMcpToolDefinition {
    @(
        @{
            name        = 'azqr_get_context'
            description = 'Show the Azure subscription, tenant and account the quota tools will act as. Call this first when the user has not named a subscription.'
            inputSchema = @{ type = 'object'; properties = @{}; required = @() }
            annotations = @{ title = 'Show Azure context'; readOnlyHint = $true; destructiveHint = $false; openWorldHint = $true }
        },
        @{
            name        = 'azqr_assess_sku'
            description = 'One-call answer to "can I actually deploy this here, and what should I use instead". Combines quota, subscription restrictions, region and zone availability, then recommends whether to proceed, pin zones, switch to a newer SKU, or raise a support case - with ranked alternatives. Prefer this over calling check_quota, check_sku and suggest_skus separately. Read-only.'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    location       = @{ type = 'string'; description = "Azure region, e.g. 'westeurope' or 'West Europe'." }
                    vmSku          = @{ type = 'string'; description = "VM SKU or quota family, e.g. 'Standard_D4ads_v7', 'dadsv7' or 'Standard Dadsv7 Family vCPUs'." }
                    subscriptionId = @{ type = 'string'; description = 'Optional. Defaults to the current context.' }
                }
                required   = @('location', 'vmSku')
            }
            annotations = @{ title = 'Assess SKU and recommend'; readOnlyHint = $true; destructiveHint = $false; openWorldHint = $true }
        },
        @{
            name        = 'azqr_check_quota'
            description = 'Read the current vCPU quota for a VM SKU or quota family in a region: limit, used and available, for both the SKU family and the regional total. Also reports whether the SKU is actually usable, because quota headroom is meaningless when the SKU is restricted. Read-only.'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    location       = @{ type = 'string'; description = "Azure region, e.g. 'westeurope' or 'West Europe'." }
                    vmSku          = @{ type = 'string'; description = "VM SKU or quota family, e.g. 'Standard_D4ads_v7', 'dadsv7' or 'Standard Dadsv7 Family vCPUs'." }
                    subscriptionId = @{ type = 'string'; description = 'Optional. Defaults to the current context.' }
                }
                required   = @('location', 'vmSku')
            }
            annotations = @{ title = 'Check vCPU quota'; readOnlyHint = $true; destructiveHint = $false; openWorldHint = $true }
        },
        @{
            name        = 'azqr_check_sku'
            description = 'Check whether a VM SKU can actually be used in a region for this subscription: availability state, availability zones, and whether it is restricted. Use this before requesting quota, because a restriction cannot be fixed by a quota increase. Read-only.'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    location       = @{ type = 'string'; description = "Azure region, e.g. 'westeurope'." }
                    vmSku          = @{ type = 'string'; description = "VM SKU, e.g. 'Standard_D4ads_v7'." }
                    subscriptionId = @{ type = 'string'; description = 'Optional. Defaults to the current context.' }
                }
                required   = @('location', 'vmSku')
            }
            annotations = @{ title = 'Check SKU availability'; readOnlyHint = $true; destructiveHint = $false; openWorldHint = $true }
        },
        @{
            name        = 'azqr_suggest_skus'
            description = 'List the same VM size in newer generations that the region really offers, with quota limit, availability and zone coverage for each. Useful when the requested SKU is restricted. Read-only.'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    location       = @{ type = 'string'; description = "Azure region, e.g. 'westeurope'." }
                    vmSku          = @{ type = 'string'; description = 'VM SKU or quota family to find newer generations of.' }
                    subscriptionId = @{ type = 'string'; description = 'Optional. Defaults to the current context.' }
                }
                required   = @('location', 'vmSku')
            }
            annotations = @{ title = 'Suggest newer SKUs'; readOnlyHint = $true; destructiveHint = $false; openWorldHint = $true }
        },
        @{
            name        = 'azqr_request_quota'
            description = 'Request a vCPU quota increase through the Microsoft.Quota API and wait for the outcome. targetVCores is the ABSOLUTE new limit, not an increment. This changes your subscription. It never files a support case; if Azure refuses, the result says so and the console tool handles the escalation.'
            inputSchema = @{
                type       = 'object'
                properties = @{
                    location             = @{ type = 'string'; description = "Azure region, e.g. 'westeurope'." }
                    vmSku                = @{ type = 'string'; description = 'VM SKU or quota family whose quota should be raised.' }
                    targetVCores         = @{ type = 'integer'; description = 'Absolute new vCPU limit for the family, not a delta. Must be higher than the current limit.' }
                    subscriptionId       = @{ type = 'string'; description = 'Optional. Defaults to the current context.' }
                    includeRegionalTotal = @{ type = 'boolean'; description = "Also raise 'Total Regional vCPUs' when it is below the target. Default true." }
                    whatIf               = @{ type = 'boolean'; description = 'Preview only: report what would be requested and change nothing. Default false.' }
                }
                required   = @('location', 'vmSku', 'targetVCores')
            }
            annotations = @{ title = 'Request quota increase'; readOnlyHint = $false; destructiveHint = $false; idempotentHint = $true; openWorldHint = $true }
        }
    )
}

function Get-AqrMcpQuotaFamily {
    param([string]$SubscriptionId, [string]$Location, $Sku)
    if ($Sku.IsFamily) { return $Sku.Family }
    # Resolve-AqrVmSku exposes the quota bucket as .Family - the family name is
    # never derivable from the SKU name, so it must be read, not constructed.
    (Resolve-AqrVmSku -SubscriptionId $SubscriptionId -Location $Location -VmSku $Sku.Name).Family
}

function Get-AqrMcpAlternativeScore {
    <#
    .SYNOPSIS
        Ranks a candidate SKU or family. Higher is better.
    .DESCRIPTION
        Usability dominates everything: an unusable option is never a
        recommendation, however new it is. Among usable ones, full zone coverage
        beats partial, because partial coverage forces the deployment to pin
        zones. Generation and existing headroom only break ties.
    #>
    param($Option)

    if ($Option.Status -notin @('Available', 'ZeroQuota')) { return -1 }

    $score = 1000
    if ($Option.Coverage -eq 'Full' -or $Option.Coverage -eq 'NonZonal') { $score += 500 }
    elseif ($Option.Coverage -eq 'Partial') { $score += 100 }
    $score += [int]$Option.Version * 10
    if ($null -ne $Option.Limit -and $null -ne $Option.Used -and ($Option.Limit - $Option.Used) -gt 0) { $score += 5 }
    $score
}

function Get-AqrMcpAssessment {
    <#
    .SYNOPSIS
        Assesses a SKU or quota family and recommends what to actually deploy.
    .DESCRIPTION
        Answers the three questions together, because separately they mislead:
        is there quota, is the SKU usable at all, and is there a better
        successor in this region. Quota headroom is meaningless if the SKU is
        restricted, and a restriction is only actionable if an alternative
        exists - so the verdict is derived from all of it at once.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)]$Sku
    )

    $family = Get-AqrMcpQuotaFamily -SubscriptionId $SubscriptionId -Location $Location -Sku $Sku
    $regionZones = @(Get-AqrRegionZone -SubscriptionId $SubscriptionId -Location $Location)

    # Both option sources mark the requested entry, so one shape covers a
    # concrete size and a whole family without special-casing below.
    $options = @(if ($Sku.IsFamily) {
            Get-AqrFamilyOption -SubscriptionId $SubscriptionId -Location $Location -Family $Sku.Family
        }
        else {
            Get-AqrSkuOption -SubscriptionId $SubscriptionId -Location $Location -VmSku $Sku.Name
        })

    $requestedRow = @($options | Where-Object { $_.IsRequested }) | Select-Object -First 1
    $alternatives = @($options | Where-Object { -not $_.IsRequested })

    # A concrete size also gets the richer restriction detail.
    $av = $null
    if (-not $Sku.IsFamily) {
        $av = Get-AqrSkuAvailability -SubscriptionId $SubscriptionId -Location $Location -VmSku $Sku.Name
    }

    $status = if ($av) { $av.Status } elseif ($requestedRow) { $requestedRow.Status } else { 'NotOfferedInRegion' }
    $usableZones = @(if ($av) { $av.UsableZones } elseif ($requestedRow) { $requestedRow.UsableZones })
    $restrictedZones = @(if ($av) { $av.RestrictedZones } elseif ($requestedRow) { $requestedRow.RestrictedZones })
    $offeredZones = @(if ($av) { $av.Zones } elseif ($requestedRow) { $requestedRow.Zones })
    # A zone can be unusable for two different reasons and they need different
    # answers: 'restricted' may be liftable, 'not offered' never is.
    $notOffered = @($regionZones | Where-Object { $_ -notin $offeredZones })
    $coverage = if (-not $regionZones.Count) { 'NonZonal' }
    elseif (-not $usableZones.Count) { 'None' }
    elseif ($usableZones.Count -lt $regionZones.Count) { 'Partial' }
    else { 'Full' }

    $familyQuota = Get-AqrQuota -SubscriptionId $SubscriptionId -Location $Location -QuotaName $family
    $regional = Get-AqrQuota -SubscriptionId $SubscriptionId -Location $Location -QuotaName 'cores'

    # --- what is actually blocking -----------------------------------------
    $usable = $status -in @('Available', 'ZeroQuota')
    $blockers = @()
    switch ($status) {
        'NotOfferedInRegion' { $blockers += "Azure does not offer this in $Location at all. A quota request cannot help." }
        'RestrictedForSubscription' { $blockers += 'Not enabled for this subscription, or blocked in every zone. A quota request cannot lift this.' }
        'RestrictedBySubscriptionOffer' { $blockers += 'The subscription offer excludes this SKU. A quota request cannot lift this.' }
        'NoQuotaBucket' { $blockers += "The region exposes no quota bucket for '$family', so there is nothing to raise." }
        'ZoneRestricted' { $blockers += 'Blocked in every zone that is offered here.' }
        'ZeroQuota' { $blockers += 'The quota bucket exists but the limit is 0. This one a quota request can fix.' }
    }
    if ($usable -and $coverage -eq 'Partial') {
        $blockers += "Usable in only $($usableZones.Count) of $($regionZones.Count) availability zones ($($usableZones -join ',')). The deployment must pin a usable zone."
    }
    if ($restrictedZones.Count) { $blockers += "AZ $($restrictedZones -join ',') restricted for this subscription." }
    if ($notOffered.Count) { $blockers += "AZ $($notOffered -join ',') not available (not offered here, as opposed to blocked)." }

    # --- ranked alternatives ------------------------------------------------
    $ranked = @($alternatives |
        Select-Object *, @{ n = 'Score'; e = { Get-AqrMcpAlternativeScore -Option $_ } } |
        Where-Object { $_.Score -ge 0 } |
        Sort-Object Score -Descending)

    $altRows = foreach ($a in $ranked) {
        $why = @()
        if ($requestedRow -and $a.Version -gt $requestedRow.Version) { $why += 'newer generation' }
        if ($a.Coverage -eq 'Full' -and $coverage -ne 'Full') { $why += 'usable in every AZ, unlike the requested one' }
        elseif ($a.Coverage -eq 'Full') { $why += 'usable in every AZ' }
        elseif ($a.Coverage -eq 'Partial') { $why += "usable in $(@($a.UsableZones).Count) of $($regionZones.Count) AZs only" }
        if (-not $usable) { $why += 'usable while the requested one is not' }
        if ($a.Status -eq 'ZeroQuota') { $why += 'quota limit is 0 and must be raised first' }
        if ($a.InUse) { $why += "already in use ($($a.Used) vCPUs)" }

        [pscustomobject]@{
            name         = $a.Name
            exampleSize  = if ($Sku.IsFamily -and @($a.Sizes).Count) { @($a.Sizes)[0] } else { $null }
            status       = $a.Status
            limit        = $a.Limit
            used         = $a.Used
            zoneCoverage = $a.Coverage
            usableZones  = @($a.UsableZones)
            why          = ($why -join '; ')
        }
    }
    $altRows = @($altRows)

    # --- verdict ------------------------------------------------------------
    $best = $altRows | Select-Object -First 1
    $betterExists = $best -and ($coverage -ne 'Full') -and ($best.zoneCoverage -eq 'Full')

    if (-not $usable) {
        $verdict = if ($best) { 'SwitchSku' } else { 'SupportCase' }
        $summary = if ($best) {
            "$($Sku.Name) cannot be used in $Location ($status). Switch to $($best.name) - $($best.why)."
        }
        else {
            "$($Sku.Name) cannot be used in $Location ($status), and no newer generation here is usable either. This needs a support case or another region."
        }
    }
    elseif ($status -eq 'ZeroQuota') {
        $verdict = 'RequestQuota'
        $summary = "$($Sku.Name) is offered in $Location but the quota limit is 0. Request quota to use it."
    }
    elseif ($betterExists) {
        $verdict = 'ProceedOrSwitch'
        $summary = "$($Sku.Name) is usable but only in AZ $($usableZones -join ','). $($best.name) covers every AZ - consider switching before raising quota."
    }
    elseif ($coverage -eq 'Partial') {
        $verdict = 'ProceedWithZonePinning'
        $summary = "$($Sku.Name) is usable in $Location but only in AZ $($usableZones -join ','). Quota can be raised; pin the deployment to a usable zone."
    }
    else {
        $verdict = 'Proceed'
        $summary = "$($Sku.Name) is usable in $Location across every availability zone. Quota can be raised normally."
        # Say so even when nothing is wrong: a newer generation is usually the
        # better place to put new capacity, and it is easy to miss.
        if ($best) {
            $newer = @($altRows | Where-Object { $_.why -match 'newer generation' } | Select-Object -First 3)
            if ($newer.Count) {
                $summary += " Newer generations are also usable here: $(($newer.name) -join ', ') - worth considering for new capacity."
            }
        }
    }

    [pscustomobject]@{
        location        = $Location
        query           = $Sku.Name
        kind            = if ($Sku.IsFamily) { 'quota family' } else { 'vm sku' }
        quotaFamily     = $family
        status          = $status
        canRequestQuota = if ($av) { $av.CanRequestQuota } else { $usable }
        reason          = if ($av) { $av.Reason } else { $status }
        detail          = if ($av) { $av.Detail } else { $null }
        zones           = [pscustomobject]@{
            coverage        = $coverage
            regionZones     = $regionZones
            usableZones     = $usableZones
            restrictedZones = $restrictedZones
            notOfferedZones = $notOffered
        }
        quota           = [pscustomobject]@{
            family        = if ($familyQuota) { [pscustomobject]@{ name = $familyQuota.LocalizedName; limit = $familyQuota.Limit; used = $familyQuota.Used; available = $familyQuota.Available } } else { $null }
            regionalTotal = if ($regional) { [pscustomobject]@{ name = $regional.LocalizedName; limit = $regional.Limit; used = $regional.Used; available = $regional.Available } } else { $null }
        }
        blockers        = @($blockers)
        recommendation  = [pscustomobject]@{
            verdict      = $verdict
            summary      = $summary
            bestPick     = if ($verdict -in @('SwitchSku', 'ProceedOrSwitch') -and $best) { $best.name } elseif ($usable) { $Sku.Name } else { $null }
            alternatives = $altRows
        }
    }
}

function Invoke-AqrMcpTool {
    param([Parameter(Mandatory)][string]$Name, $Arguments)

    if ($Name -eq 'azqr_get_context') {
        return New-AqrMcpToolResult -Payload (Get-AqrMcpContext)
    }

    # Every remaining tool is scoped to a region and a SKU.
    $ctx = Get-AqrMcpContext -SubscriptionId (Get-AqrMcpArgument -Arguments $Arguments -Key 'subscriptionId')
    $loc = Resolve-AqrMcpLocation -SubscriptionId $ctx.subscriptionId -Location (Get-AqrMcpArgument -Arguments $Arguments -Key 'location')
    $sku = Resolve-AqrMcpSku -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Query (Get-AqrMcpArgument -Arguments $Arguments -Key 'vmSku')

    switch ($Name) {
        'azqr_assess_sku' {
            return New-AqrMcpToolResult -Payload (Get-AqrMcpAssessment -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Sku $sku)
        }

        'azqr_check_quota' {
            # Quota alone is misleading - a healthy limit on a restricted SKU
            # reads like "you are fine" when nothing can be deployed. The
            # verdict and blockers travel with the numbers.
            $a = Get-AqrMcpAssessment -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Sku $sku

            return New-AqrMcpToolResult -Payload ([pscustomobject]@{
                    subscriptionId = $ctx.subscriptionId
                    location       = $loc.Name
                    resolvedAs     = $a.kind
                    vmSku          = $a.query
                    quotaFamily    = $a.quotaFamily
                    familyQuota    = $a.quota.family
                    regionalTotal  = $a.quota.regionalTotal
                    status         = $a.status
                    blockers       = $a.blockers
                    recommendation = $a.recommendation
                    note           = if (-not $a.quota.family) { "The region exposes no quota bucket for '$($a.quotaFamily)'. A quota request cannot create one - this needs a support case." } else { $null }
                })
        }

        'azqr_check_sku' {
            if ($sku.IsFamily) { throw "'$($sku.Name)' is a quota family. Pass a concrete VM size, e.g. Standard_D4ads_v7, or use azqr_assess_sku which accepts both." }
            $a = Get-AqrMcpAssessment -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Sku $sku
            $av = Get-AqrSkuAvailability -SubscriptionId $ctx.subscriptionId -Location $loc.Name -VmSku $sku.Name

            return New-AqrMcpToolResult -Payload ([pscustomobject]@{
                    location              = $loc.Name
                    vmSku                 = $sku.Name
                    vCpus                 = $av.VCpus
                    quotaFamily           = $a.quotaFamily
                    status                = $a.status
                    canRequestQuota       = $a.canRequestQuota
                    supportRequestAdvised = $av.SupportRequestAdvised
                    reason                = $a.reason
                    detail                = $a.detail
                    zones                 = $a.zones
                    blockers              = $a.blockers
                    recommendation        = $a.recommendation
                })
        }

        'azqr_suggest_skus' {
            $a = Get-AqrMcpAssessment -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Sku $sku
            return New-AqrMcpToolResult -Payload ([pscustomobject]@{
                    location       = $loc.Name
                    query          = $a.query
                    kind           = $a.kind
                    currentStatus  = $a.status
                    currentZones   = $a.zones
                    recommendation = $a.recommendation
                })
        }

        'azqr_request_quota' {
            $target = [int](Get-AqrMcpArgument -Arguments $Arguments -Key 'targetVCores' -Default 0)
            $whatIf = [bool](Get-AqrMcpArgument -Arguments $Arguments -Key 'whatIf' -Default $false)
            $withRegional = [bool](Get-AqrMcpArgument -Arguments $Arguments -Key 'includeRegionalTotal' -Default $true)
            if ($target -le 0) { throw 'targetVCores must be a positive absolute limit.' }

            $family = Get-AqrMcpQuotaFamily -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Sku $sku

            # Refuse early when the SKU is blocked: a quota request cannot lift a
            # subscription restriction. Return what WOULD work rather than a
            # bare refusal, so the next step is obvious.
            if (-not $sku.IsFamily) {
                $av = Get-AqrSkuAvailability -SubscriptionId $ctx.subscriptionId -Location $loc.Name -VmSku $sku.Name
                if (-not $av.CanRequestQuota) {
                    $a = Get-AqrMcpAssessment -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Sku $sku
                    return New-AqrMcpToolResult -IsError -Payload ([pscustomobject]@{
                            outcome        = 'NotRequestable'
                            vmSku          = $sku.Name
                            location       = $loc.Name
                            status         = $a.status
                            reason         = $a.reason
                            blockers       = $a.blockers
                            message        = "A quota increase cannot help here: $($a.reason) Nothing was requested."
                            recommendation = $a.recommendation
                        })
                }
            }

            $targets = @([pscustomobject]@{ Name = $family; Kind = 'family' })
            if ($withRegional) { $targets += [pscustomobject]@{ Name = 'cores'; Kind = 'regional total' } }

            $results = foreach ($t in $targets) {
                $before = Get-AqrQuota -SubscriptionId $ctx.subscriptionId -Location $loc.Name -QuotaName $t.Name
                if (-not $before) {
                    [pscustomobject]@{ quota = $t.Name; kind = $t.Kind; outcome = 'NoQuotaBucket'; message = "The region exposes no bucket named '$($t.Name)'."; limitBefore = $null; limitAfter = $null; needsSupportTicket = $true }
                    continue
                }
                if ($before.Limit -ge $target) {
                    [pscustomobject]@{ quota = $t.Name; kind = $t.Kind; outcome = 'AlreadySatisfied'; message = "Already $($before.Limit) (>= $target). Nothing requested."; limitBefore = $before.Limit; limitAfter = $before.Limit; needsSupportTicket = $false }
                    continue
                }
                if ($whatIf) {
                    [pscustomobject]@{ quota = $t.Name; kind = $t.Kind; outcome = 'WhatIf'; message = "Would request $target (currently $($before.Limit))."; limitBefore = $before.Limit; limitAfter = $null; needsSupportTicket = $false }
                    continue
                }

                $r = Request-AqrQuotaIncrease -SubscriptionId $ctx.subscriptionId -Location $loc.Name -QuotaName $t.Name -NewLimit $target
                # Re-read rather than trusting the reported outcome: the two have
                # disagreed before, and reporting a success that did not happen
                # is worse than reporting nothing.
                $after = Get-AqrQuota -SubscriptionId $ctx.subscriptionId -Location $loc.Name -QuotaName $t.Name
                [pscustomobject]@{
                    quota              = $t.Name
                    kind               = $t.Kind
                    outcome            = if ($after -and $after.Limit -ge $target) { 'Succeeded' } elseif ($r.Outcome -eq 'Succeeded') { 'Unverified' } else { $r.Outcome }
                    message            = $r.Message
                    limitBefore        = $before.Limit
                    limitAfter         = if ($after) { $after.Limit } else { $null }
                    needsSupportTicket = [bool]$r.NeedsSupportTicket
                }
            }

            $results = @($results)
            $failed = @($results | Where-Object { $_.outcome -notin @('Succeeded', 'AlreadySatisfied', 'WhatIf') })

            # The summary must never imply a limit was reached when nothing was
            # sent. A preview reports intent; only a real run reports outcome.
            $summary = if ($whatIf) {
                $would = @($results | Where-Object { $_.outcome -eq 'WhatIf' })
                if ($would.Count) {
                    "Preview only, nothing was changed. Would request $target vCPUs for: $(($would.quota) -join ', ')."
                }
                else {
                    "Preview only, nothing was changed. No request would be sent - every target is already at or above $target vCPUs."
                }
            }
            elseif ($failed.Count) {
                "$($failed.Count) of $($results.Count) quota target(s) did not reach $target. Azure refused the automatic request. Escalate by running Start-AzQuotaRequest.ps1, which files a support case from your template."
            }
            else {
                "All quota targets are at or above $target vCPUs."
            }

            # A refusal is where an alternative matters most: another generation
            # in this region may have the headroom this one was denied.
            $recommendation = $null
            if ($failed.Count -and -not $whatIf) {
                $recommendation = (Get-AqrMcpAssessment -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Sku $sku).recommendation
            }

            return New-AqrMcpToolResult -IsError:([bool]$failed.Count) -Payload ([pscustomobject]@{
                    subscriptionId = $ctx.subscriptionId
                    location       = $loc.Name
                    quotaFamily    = $family
                    targetVCores   = $target
                    whatIf         = $whatIf
                    results        = $results
                    summary        = $summary
                    recommendation = $recommendation
                })
        }

        default { throw "Unknown tool '$Name'." }
    }
}

# --- dispatch ---------------------------------------------------------------

function Invoke-AqrMcpRequest {
    param([Parameter(Mandatory)]$Request)

    $hasId = $Request.PSObject.Properties.Name -contains 'id'
    $id = if ($hasId) { $Request.id } else { $null }
    $method = if ($Request.PSObject.Properties.Name -contains 'method') { $Request.method } else { '' }

    switch ($method) {
        'initialize' {
            # Honour the client's protocol version when we know it, so an older
            # client is not forced onto a newer revision.
            $wanted = $null
            if ($Request.PSObject.Properties.Name -contains 'params' -and $Request.params -and
                $Request.params.PSObject.Properties.Name -contains 'protocolVersion') {
                $wanted = $Request.params.protocolVersion
            }
            $version = if ($wanted -and $KnownProtocols -contains $wanted) { $wanted } else { $DefaultProtocol }

            Send-AqrMcpResult -Id $id -Result @{
                protocolVersion = $version
                capabilities    = @{ tools = @{ listChanged = $false } }
                serverInfo      = @{ name = $ServerName; version = $ServerVersion }
                instructions    = 'Azure vCPU quota tools running as the signed-in Azure user. Check the SKU is usable before requesting quota: a subscription restriction cannot be fixed by a quota increase. targetVCores is an absolute limit, not an increment.'
            }
            return
        }
        'ping' { Send-AqrMcpResult -Id $id -Result @{}; return }
        'tools/list' { Send-AqrMcpResult -Id $id -Result @{ tools = @(Get-AqrMcpToolDefinition) }; return }
        'tools/call' {
            $name = $Request.params.name
            $toolArgs = if ($Request.params.PSObject.Properties.Name -contains 'arguments') { $Request.params.arguments } else { $null }
            Write-AqrMcpLog "tool call: $name"
            try {
                Send-AqrMcpResult -Id $id -Result (Invoke-AqrMcpTool -Name $name -Arguments $toolArgs)
            }
            catch {
                # Tool failures come back as a result with isError, not a
                # JSON-RPC error, so the model can read the reason and react.
                Write-AqrMcpLog "tool failed: $($_.Exception.Message)" 'ERROR'
                Send-AqrMcpResult -Id $id -Result (New-AqrMcpToolResult -IsError -Payload $_.Exception.Message)
            }
            return
        }
        default {
            # Notifications carry no id and must never be answered.
            if ($hasId) { Send-AqrMcpError -Id $id -Code -32601 -MessageText "Method not found: $method" }
            return
        }
    }
}

Write-AqrMcpLog "$ServerName $ServerVersion starting"

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }          # stdin closed: the client went away
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    Write-AqrMcpLog "<- $line" 'TRACE'
    $request = $null
    try {
        $request = $line | ConvertFrom-Json
    }
    catch {
        Send-AqrMcpError -Id $null -Code -32700 -MessageText 'Parse error'
        continue
    }

    try { Invoke-AqrMcpRequest -Request $request }
    catch {
        Write-AqrMcpLog "dispatch failed: $($_.Exception.Message)" 'ERROR'
        $rid = if ($request.PSObject.Properties.Name -contains 'id') { $request.id } else { $null }
        if ($null -ne $rid) { Send-AqrMcpError -Id $rid -Code -32603 -MessageText $_.Exception.Message }
    }
}

Write-AqrMcpLog "$ServerName stopping"
