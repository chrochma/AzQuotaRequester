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
            name        = 'azqr_check_quota'
            description = 'Read the current vCPU quota for a VM SKU or quota family in a region: limit, used and available, for both the SKU family and the regional total. Read-only.'
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
        'azqr_check_quota' {
            $family = Get-AqrMcpQuotaFamily -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Sku $sku
            $familyQuota = Get-AqrQuota -SubscriptionId $ctx.subscriptionId -Location $loc.Name -QuotaName $family
            $regional = Get-AqrQuota -SubscriptionId $ctx.subscriptionId -Location $loc.Name -QuotaName 'cores'

            return New-AqrMcpToolResult -Payload ([pscustomobject]@{
                    subscriptionId = $ctx.subscriptionId
                    location       = $loc.Name
                    resolvedAs     = if ($sku.IsFamily) { 'quota family' } else { 'vm sku' }
                    vmSku          = $sku.Name
                    quotaFamily    = $family
                    familyQuota    = if ($familyQuota) { [pscustomobject]@{ name = $familyQuota.LocalizedName; limit = $familyQuota.Limit; used = $familyQuota.Used; available = $familyQuota.Available } } else { $null }
                    regionalTotal  = if ($regional) { [pscustomobject]@{ name = $regional.LocalizedName; limit = $regional.Limit; used = $regional.Used; available = $regional.Available } } else { $null }
                    note           = if (-not $familyQuota) { "The region exposes no quota bucket for '$family'. A quota request cannot create one - this needs a support case." } else { $null }
                })
        }

        'azqr_check_sku' {
            if ($sku.IsFamily) { throw "'$($sku.Name)' is a quota family. Pass a concrete VM size, e.g. Standard_D4ads_v7." }
            $av = Get-AqrSkuAvailability -SubscriptionId $ctx.subscriptionId -Location $loc.Name -VmSku $sku.Name
            $regionZones = @(Get-AqrRegionZone -SubscriptionId $ctx.subscriptionId -Location $loc.Name)
            # A zone can be unusable for two different reasons, and they need
            # different answers: 'restricted' may be liftable, 'not offered'
            # never is. Keep them apart rather than merging into "blocked".
            $notOffered = @($regionZones | Where-Object { $_ -notin @($av.Zones) })

            return New-AqrMcpToolResult -Payload ([pscustomobject]@{
                    location              = $loc.Name
                    vmSku                 = $sku.Name
                    vCpus                 = $av.VCpus
                    quotaFamily           = $av.Family
                    status                = $av.Status
                    canRequestQuota       = $av.CanRequestQuota
                    supportRequestAdvised = $av.SupportRequestAdvised
                    reason                = $av.Reason
                    detail                = $av.Detail
                    regionZones           = $regionZones
                    usableZones           = @($av.UsableZones)
                    restrictedZones       = @($av.RestrictedZones)
                    notOfferedZones       = $notOffered
                    zoneCoverage          = if (-not $regionZones.Count) { 'NonZonal' }
                    elseif (-not @($av.UsableZones).Count) { 'None' }
                    elseif (@($av.UsableZones).Count -lt $regionZones.Count) { 'Partial' }
                    else { 'Full' }
                })
        }

        'azqr_suggest_skus' {
            $options = if ($sku.IsFamily) {
                Get-AqrFamilyOption -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Family $sku.Family
            }
            else {
                Get-AqrSkuOption -SubscriptionId $ctx.subscriptionId -Location $loc.Name -VmSku $sku.Name
            }

            $rows = foreach ($o in @($options | Sort-Object Version)) {
                [pscustomobject]@{
                    name            = $o.Name
                    isCurrentChoice = [bool]$o.IsRequested
                    status          = $o.Status
                    limit           = $o.Limit
                    used            = $o.Used
                    usableZones     = @($o.UsableZones)
                    zoneCoverage    = $o.Coverage
                    exampleSize     = if ($sku.IsFamily -and @($o.Sizes).Count) { @($o.Sizes)[0] } else { $null }
                }
            }

            return New-AqrMcpToolResult -Payload ([pscustomobject]@{
                    location = $loc.Name
                    query    = $sku.Name
                    kind     = if ($sku.IsFamily) { 'quota family' } else { 'vm sku' }
                    options  = @($rows)
                })
        }

        'azqr_request_quota' {
            $target = [int](Get-AqrMcpArgument -Arguments $Arguments -Key 'targetVCores' -Default 0)
            $whatIf = [bool](Get-AqrMcpArgument -Arguments $Arguments -Key 'whatIf' -Default $false)
            $withRegional = [bool](Get-AqrMcpArgument -Arguments $Arguments -Key 'includeRegionalTotal' -Default $true)
            if ($target -le 0) { throw 'targetVCores must be a positive absolute limit.' }

            $family = Get-AqrMcpQuotaFamily -SubscriptionId $ctx.subscriptionId -Location $loc.Name -Sku $sku

            # Refuse early when the SKU is blocked: a quota request cannot lift a
            # subscription restriction, and submitting one only wastes time.
            if (-not $sku.IsFamily) {
                $av = Get-AqrSkuAvailability -SubscriptionId $ctx.subscriptionId -Location $loc.Name -VmSku $sku.Name
                if (-not $av.CanRequestQuota) {
                    return New-AqrMcpToolResult -IsError -Payload ([pscustomobject]@{
                            outcome = 'NotRequestable'
                            vmSku   = $sku.Name
                            status  = $av.Status
                            reason  = $av.Reason
                            message = "A quota increase cannot help here: $($av.Reason) This needs a support case, another region, or another SKU."
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

            return New-AqrMcpToolResult -IsError:([bool]$failed.Count) -Payload ([pscustomobject]@{
                    subscriptionId = $ctx.subscriptionId
                    location       = $loc.Name
                    quotaFamily    = $family
                    targetVCores   = $target
                    whatIf         = $whatIf
                    results        = $results
                    summary        = $summary
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
