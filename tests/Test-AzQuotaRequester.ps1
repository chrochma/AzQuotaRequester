<#
.SYNOPSIS
    Offline self-test for AzQuotaRequester.
.DESCRIPTION
    Parses every script, verifies the exported command surface, validates the
    support ticket template and checks the ticket payload rendering.
    Live Azure calls are only made with -Online.
.EXAMPLE
    .\Test-AzQuotaRequester.ps1
.EXAMPLE
    .\Test-AzQuotaRequester.ps1 -Online -Location westeurope -VmSku Standard_D4s_v5
#>
[CmdletBinding()]
param(
    [switch]$Online,
    [string]$Location = 'westeurope',
    [string]$VmSku = 'Standard_D4s_v5'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) { Write-Host "  [pass] $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:failures++ }
}

# Defined up here because both the online checks and the MCP section drive the
# server, and the online block runs first.
$mcpScript = Join-Path $root 'mcp\Start-AqrMcpServer.ps1'
$handshake = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'

function Invoke-AqrMcpTestFrame {
    <#
    .SYNOPSIS
        Sends JSON-RPC lines to a fresh server process and returns raw stdout.
    #>
    param([string[]]$Frame)
    $psExe = (Get-Process -Id $PID).Path
    ($Frame -join "`n") | & $psExe -NoProfile -File $mcpScript 2>$null
}

function Get-AqrMcpTestPayload {
    <#
    .SYNOPSIS
        Runs one tool call and returns the deserialized tool payload.
    #>
    param([string]$Tool, [hashtable]$ToolArgs)
    $call = @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = $Tool; arguments = $ToolArgs } } | ConvertTo-Json -Depth 10 -Compress
    $out = @(Invoke-AqrMcpTestFrame -Frame @($handshake, $call))
    ($out[1] | ConvertFrom-Json).result.content[0].text | ConvertFrom-Json
}

Write-Host "`nAzQuotaRequester self-test" -ForegroundColor Cyan

# --- syntax -----------------------------------------------------------------
Write-Host "`nParsing" -ForegroundColor Cyan
foreach ($file in Get-ChildItem -Path $root -Include '*.ps1', '*.psm1' -Recurse) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
    Assert-True -Name "syntax: $($file.Name)" -Condition ($errors.Count -eq 0) -Detail ($errors -join '; ')
}

# --- module surface ---------------------------------------------------------
Write-Host "`nModules" -ForegroundColor Cyan
$core = Import-Module (Join-Path $root 'src\AzQuotaRequester.Core.psm1') -Force -PassThru -DisableNameChecking
$support = Import-Module (Join-Path $root 'src\AzQuotaRequester.Support.psm1') -Force -PassThru -DisableNameChecking
$ui = Import-Module (Join-Path $root 'src\AzQuotaRequester.UI.psm1') -Force -PassThru -DisableNameChecking

foreach ($fn in 'Invoke-AqrArm', 'Get-AqrQuota', 'Resolve-AqrVmSku', 'Request-AqrQuotaIncrease', 'Get-AqrLocation') {
    Assert-True -Name "core exports $fn" -Condition ($core.ExportedFunctions.Keys -contains $fn)
}
foreach ($fn in 'Import-AqrTicketTemplate', 'New-AqrQuotaSupportTicket', 'Get-AqrSupportClassification') {
    Assert-True -Name "support exports $fn" -Condition ($support.ExportedFunctions.Keys -contains $fn)
}
Assert-True -Name 'ui exports Invoke-AqrWizard' -Condition ($ui.ExportedFunctions.Keys -contains 'Invoke-AqrWizard')
foreach ($fn in 'Select-AqrAzureContext', 'Select-AqrSubscription', 'Select-AqrTenant', 'Read-AqrSearchChoice') {
    Assert-True -Name "ui exports $fn" -Condition ($ui.ExportedFunctions.Keys -contains $fn)
}
foreach ($p in 'TenantId', 'Reauthenticate') {
    Assert-True -Name "Initialize-AqrContext accepts -$p" -Condition ((Get-Command Initialize-AqrContext).Parameters.Keys -contains $p)
}
$entry = Get-Command (Join-Path $root 'Start-AzQuotaRequest.ps1')
foreach ($p in 'TenantId', 'Reauthenticate', 'UseCurrentContext') {
    Assert-True -Name "entry script accepts -$p" -Condition ($entry.Parameters.Keys -contains $p)
}

# --- template ---------------------------------------------------------------
Write-Host "`nTemplate" -ForegroundColor Cyan
$templatePath = Join-Path $root 'config\support-ticket-template.example.json'
Assert-True -Name 'example template is shipped' -Condition (Test-Path -LiteralPath $templatePath)

# The personal template must not be a tracked repo file, or a git pull wipes it.
Assert-True -Name 'personal template is not tracked in the repo' -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'config\support-ticket-template.json'))) -Detail 'config\support-ticket-template.json should not exist in the checkout'
$ignore = Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw -ErrorAction SilentlyContinue
Assert-True -Name 'gitignore covers a local personal template' -Condition ($ignore -match 'support-ticket-template\.json')

# Resolution order must land outside the repository for writes.
$writePath = Get-AqrTemplatePath -ForWrite
Assert-True -Name 'write path is outside the repo' -Condition ($writePath -notlike "$root*") -Detail $writePath
Assert-True -Name 'write path is under the user profile' -Condition ($writePath -like (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AzQuotaRequester*')) -Detail $writePath
Assert-True -Name 'explicit path wins' -Condition ((Get-AqrTemplatePath -Path 'X.json') -like '*X.json')

# The shipped example must never be usable as a real case.
$exampleTemplate = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
Assert-True -Name 'example is detected as not personalized' -Condition (-not (Test-AqrTemplatePersonalized -Template $exampleTemplate))
$exampleRejected = $false
try { Import-AqrTicketTemplate -Path $templatePath | Out-Null } catch { $exampleRejected = $true }
Assert-True -Name 'example template is rejected for a real ticket' -Condition $exampleRejected

# Build a personalized copy for the remaining template assertions.
$personalPath = Join-Path $env:TEMP "aqr-personal-$([guid]::NewGuid().ToString('N')).json"
$exampleTemplate.contactDetails.firstName = 'Test'
$exampleTemplate.contactDetails.lastName = 'User'
$exampleTemplate.contactDetails.primaryEmailAddress = 'test.user@example.org'
$exampleTemplate | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $personalPath -Encoding utf8

$template = Import-AqrTicketTemplate -Path $personalPath
Assert-True -Name 'template loads and validates' -Condition ($null -ne $template)
Assert-True -Name 'template severity is valid' -Condition ($template.severity -in 'minimal', 'moderate', 'critical', 'highestcriticalimpact')
Assert-True -Name 'template has quota details' -Condition ($template.quotaTicketDetails.quotaChangeRequestVersion -eq '1.0')

$rendered = Expand-AqrTemplateToken -Text $template.title -Token @{ QuotaDisplayName = 'Standard DSv5 Family vCPUs'; TargetLimit = 200; Location = 'westeurope' }
Assert-True -Name 'placeholders are replaced' -Condition ($rendered -notmatch '\{[A-Za-z]+\}') -Detail $rendered
Remove-Item -LiteralPath $personalPath -Force -ErrorAction SilentlyContinue

# The builder must expose the same field surface the template needs.
$builder = Get-Command (Join-Path $root 'New-AqrTicketTemplate.ps1')
foreach ($p in 'Path', 'Force') {
    Assert-True -Name "template builder accepts -$p" -Condition ($builder.Parameters.Keys -contains $p)
}
$builderText = Get-Content -LiteralPath (Join-Path $root 'New-AqrTicketTemplate.ps1') -Raw
foreach ($field in 'preferredContactMethod', 'preferredTimeZone', 'preferredSupportLanguage', 'country', 'advancedDiagnosticConsent', 'quotaChangeRequestVersion') {
    Assert-True -Name "template builder writes $field" -Condition ($builderText -match [regex]::Escape($field))
}

# The banner must keep the text block clear of both icon zones.
$svg = [xml](Get-Content -LiteralPath (Join-Path $root 'assets\azquotarequester-banner.svg') -Raw)
$textX = @($svg.svg.text | ForEach-Object { [double]$_.x })
Assert-True -Name 'banner text starts right of the left icon' -Condition (($textX | Measure-Object -Minimum).Minimum -ge 210) -Detail "min x=$(($textX | Measure-Object -Minimum).Minimum)"
Assert-True -Name 'banner text starts left of the right icon' -Condition (($textX | Measure-Object -Maximum).Maximum -le 900) -Detail "max x=$(($textX | Measure-Object -Maximum).Maximum)"

# A bad template must be rejected.
$badPath = Join-Path $env:TEMP "aqr-bad-$([guid]::NewGuid().ToString('N')).json"
try {
    ($template | ConvertTo-Json -Depth 10 | ConvertFrom-Json) | ForEach-Object { $_.contactDetails.country = 'DE'; $_ } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badPath -Encoding utf8
    $rejected = $false
    try { Import-AqrTicketTemplate -Path $badPath | Out-Null } catch { $rejected = $true }
    Assert-True -Name 'invalid country code is rejected' -Condition $rejected
}
finally { Remove-Item -LiteralPath $badPath -Force -ErrorAction SilentlyContinue }

# --- severity safety net ----------------------------------------------------
Write-Host "`nSeverity safety net" -ForegroundColor Cyan

# Rejections that should trigger a lower severity retry.
Assert-True -Name 'generic 400 is treated as a severity rejection' -Condition (Test-AqrSeverityRejection -StatusCode 400 -Message 'InvalidParameterValue: The calling client sent a bad request to the service')
Assert-True -Name 'support plan message is a severity rejection' -Condition (Test-AqrSeverityRejection -StatusCode 403 -Message 'The subscription does not have a support plan')
# A plan without API access is not fixed by a lower severity.
Assert-True -Name 'InvalidSupportPlan does not retry' -Condition (-not (Test-AqrSeverityRejection -StatusCode 400 -Message 'x' -ErrorCode 'InvalidSupportPlan'))
Assert-True -Name 'Free plan message does not retry' -Condition (-not (Test-AqrSeverityRejection -StatusCode 400 -Message 'Your support plan type is Free. To create and update support tickets...'))
# The async operation must be polled, not assumed successful.
Assert-True -Name 'support exports Wait-AqrSupportOperation' -Condition ($support.ExportedFunctions.Keys -contains 'Wait-AqrSupportOperation')
$createText = (Get-Command New-AqrQuotaSupportTicket).Definition
Assert-True -Name 'ticket creation polls the async operation' -Condition ($createText -match 'Wait-AqrSupportOperation')
Assert-True -Name 'ticket is re-read after a successful async operation' -Condition ($createText -match 'supportTickets/\$\(\$TicketName\)\?api-version')
# Real payload errors must not trigger a retry.
Assert-True -Name 'field error is not a severity rejection' -Condition (-not (Test-AqrSeverityRejection -StatusCode 400 -Message 'InvalidParameterValue: bad request (Phone Number cannot be empty)'))
Assert-True -Name 'server error is not a severity rejection' -Condition (-not (Test-AqrSeverityRejection -StatusCode 500 -Message 'InternalServerError'))

$baseProps = [ordered]@{
    title = 't'; description = 'original body'; severity = 'critical'
    require24X7Response = $true; advancedDiagnosticConsent = 'No'
}
$asCritical = ConvertTo-AqrTicketBody -Properties $baseProps -Severity 'critical' -RequestedSeverity 'critical' | ConvertFrom-Json
Assert-True -Name 'unchanged severity keeps the description' -Condition ($asCritical.properties.description -eq 'original body')
Assert-True -Name 'unchanged severity keeps 24x7' -Condition ($asCritical.properties.require24X7Response -eq $true)

$asMinimal = ConvertTo-AqrTicketBody -Properties $baseProps -Severity 'minimal' -RequestedSeverity 'critical' | ConvertFrom-Json
Assert-True -Name 'downgrade sets the lower severity' -Condition ($asMinimal.properties.severity -eq 'minimal')
Assert-True -Name 'minimal severity forces 24x7 off' -Condition ($asMinimal.properties.require24X7Response -eq $false)
Assert-True -Name 'downgrade is recorded in the description' -Condition ($asMinimal.properties.description -match "Severity 'critical' was requested but rejected")
Assert-True -Name 'downgrade does not mutate the source properties' -Condition ($baseProps.severity -eq 'critical' -and $baseProps.require24X7Response -eq $true)

# The builder must not ask for 24x7 when severity is minimal.
Assert-True -Name 'builder skips 24x7 on minimal severity' -Condition ($builderText -match "severity -eq 'minimal'")

# --- resilience -------------------------------------------------------------
Write-Host "`nResilience" -ForegroundColor Cyan

Assert-True -Name 'ui exports Resolve-AqrSkuQuota' -Condition ($ui.ExportedFunctions.Keys -contains 'Resolve-AqrSkuQuota')
Assert-True -Name 'Resolve-AqrSkuQuota supports -NonInteractive' -Condition ((Get-Command Resolve-AqrSkuQuota).Parameters.Keys -contains 'NonInteractive')
Assert-True -Name 'Resolve-AqrSkuQuota supports -Spot' -Condition ((Get-Command Resolve-AqrSkuQuota).Parameters.Keys -contains 'Spot')

# An unusable SKU must re-prompt, so the resolver has to swallow the error itself.
$resolverText = (Get-Command Resolve-AqrSkuQuota).Definition
Assert-True -Name 'resolver catches SKU and quota failures' -Condition ($resolverText -match 'catch\s*\{')
Assert-True -Name 'resolver offers a different SKU' -Condition ($resolverText -match 'Choose a different VM SKU')

# The quota table must tolerate a missing bucket instead of blowing up.
$tableOk = $true
try {
    Show-AqrQuotaTable -Quota @($null, $null) | Out-Null
    Show-AqrQuotaTable -Quota @($null, [pscustomobject]@{ Name = 'cores'; LocalizedName = 'Total Regional vCPUs'; Used = 0; Limit = 10; Available = 10 }) | Out-Null
}
catch { $tableOk = $false }
Assert-True -Name 'quota table tolerates null rows' -Condition $tableOk

# Get-AqrQuota must report a missing bucket as $null rather than throwing.
$quotaText = (Get-Command Get-AqrQuota).Definition
Assert-True -Name 'missing quota bucket returns null' -Condition ($quotaText -match 'if \(-not \$usage\) \{ return \$null \}')
Assert-True -Name 'quota falls back to the usages API' -Condition ($quotaText -match 'Falling back to the usages API')

# SKU availability classification.
Assert-True -Name 'core exports Get-AqrSkuAvailability' -Condition ($core.ExportedFunctions.Keys -contains 'Get-AqrSkuAvailability')
Assert-True -Name 'core exports Get-AqrQuotaDisplayName' -Condition ($core.ExportedFunctions.Keys -contains 'Get-AqrQuotaDisplayName')

# Display names are derived when the region exposes no bucket to read them from.
$derived = @{
    'standardDSv5Family'   = 'Standard DSv5 Family vCPUs'
    'standardDCasv6Family' = 'Standard DCasv6 Family vCPUs'
}
foreach ($family in $derived.Keys) {
    $actual = Get-AqrQuotaDisplayName -Family $family
    Assert-True -Name "display name for $family" -Condition ($actual -eq $derived[$family]) -Detail $actual
}

$availabilityText = (Get-Command Get-AqrSkuAvailability).Definition
foreach ($status in 'NotOfferedInRegion', 'RestrictedBySubscriptionOffer', 'RestrictedForSubscription', 'ZoneRestricted', 'NoQuotaBucket', 'ZeroQuota', 'Available') {
    Assert-True -Name "availability reports $status" -Condition ($availabilityText -match [regex]::Escape($status))
}
Assert-True -Name 'availability reads the subscription offer' -Condition ($availabilityText -match 'subscriptionPolicies\.quotaId')

$resolverOptions = (Get-Command Resolve-AqrSkuQuota).Definition
Assert-True -Name 'resolver offers a support-request path' -Condition ($resolverOptions -match 'Continue anyway and raise a support request')
Assert-True -Name 'resolver offers abort' -Condition ($resolverOptions -match "abort = 'Abort'")

# --- SKU suggestions --------------------------------------------------------
Write-Host "`nSKU suggestions" -ForegroundColor Cyan

foreach ($fn in 'Split-AqrSkuGeneration', 'Get-AqrSkuZoneInfo', 'Get-AqrSkuOption', 'Get-AqrUsedSkuFamily') {
    Assert-True -Name "core exports $fn" -Condition ($core.ExportedFunctions.Keys -contains $fn)
}
foreach ($fn in 'Show-AqrUsedSkuFamily', 'Show-AqrSkuOption') {
    Assert-True -Name "ui exports $fn" -Condition ($ui.ExportedFunctions.Keys -contains $fn)
}

# Generation parsing drives the "same size, newer generation" proposal.
$cases = @(
    @{ Sku = 'Standard_D4s_v5'; Stem = 'Standard_D4s'; Version = 5 }
    @{ Sku = 'Standard_D4s'; Stem = 'Standard_D4s'; Version = 1 }
    @{ Sku = 'Standard_NC24ads_A100_v4'; Stem = 'Standard_NC24ads_A100'; Version = 4 }
    @{ Sku = 'Standard_DC32as_v6'; Stem = 'Standard_DC32as'; Version = 6 }
)
foreach ($c in $cases) {
    $g = Split-AqrSkuGeneration -VmSku $c.Sku
    Assert-True -Name "generation split of $($c.Sku)" -Condition ($g.Stem -eq $c.Stem -and $g.Version -eq $c.Version) -Detail "got stem='$($g.Stem)' v$($g.Version)"
}
# Different sizes must not be proposed as generations of each other.
$d2 = Split-AqrSkuGeneration -VmSku 'Standard_D2s_v5'
$d4 = Split-AqrSkuGeneration -VmSku 'Standard_D4s_v5'
Assert-True -Name 'different sizes have different stems' -Condition ($d2.Stem -ne $d4.Stem)

# Zone maths: usable = offered minus restricted, and a zone the region has but
# the SKU does not offer is "not available" rather than "restricted".
$partial = Get-AqrSkuZoneInfo -RegionZone @('1', '2', '3') -Sku ([pscustomobject]@{
        locationInfo = @([pscustomobject]@{ zones = @('1', '2', '3') })
        restrictions = @([pscustomobject]@{ type = 'Zone'; restrictionInfo = [pscustomobject]@{ zones = @('2', '3') } })
    })
Assert-True -Name 'partial zone restriction keeps usable zones' -Condition (($partial.UsableZones -join ',') -eq '1' -and -not $partial.FullyRestricted)
Assert-True -Name 'restricted zones are not reported as not offered' -Condition ($partial.NotOfferedZones.Count -eq 0 -and ($partial.RestrictedZones -join ',') -eq '2,3')
Assert-True -Name 'partial coverage is detected' -Condition ($partial.Coverage -eq 'Partial') -Detail $partial.Coverage

# A SKU offered in only two of the region's three zones: zone 1 is not available.
$notOffered = Get-AqrSkuZoneInfo -RegionZone @('1', '2', '3') -Sku ([pscustomobject]@{
        locationInfo = @([pscustomobject]@{ zones = @('2', '3') })
        restrictions = @()
    })
Assert-True -Name 'missing zone is reported as not available' -Condition (($notOffered.NotOfferedZones -join ',') -eq '1')
Assert-True -Name 'not-available zone is not called restricted' -Condition ($notOffered.RestrictedZones.Count -eq 0)
Assert-True -Name 'two of three zones is partial coverage' -Condition ($notOffered.Coverage -eq 'Partial') -Detail $notOffered.Coverage
Assert-True -Name 'not-available zone is still unusable' -Condition (($notOffered.UnavailableZones -join ',') -eq '1')

$full = Get-AqrSkuZoneInfo -RegionZone @('1', '2', '3') -Sku ([pscustomobject]@{
        locationInfo = @([pscustomobject]@{ zones = @('1', '2', '3') })
        restrictions = @([pscustomobject]@{ type = 'Zone'; restrictionInfo = [pscustomobject]@{ zones = @('1', '2', '3') } })
    })
Assert-True -Name 'all zones restricted is detected' -Condition ($full.FullyRestricted -and $full.UsableZones.Count -eq 0)
Assert-True -Name 'no usable zone is coverage None' -Condition ($full.Coverage -eq 'None') -Detail $full.Coverage

$none = Get-AqrSkuZoneInfo -RegionZone @('1', '2', '3') -Sku ([pscustomobject]@{
        locationInfo = @([pscustomobject]@{ zones = @('1', '2', '3') })
        restrictions = @()
    })
Assert-True -Name 'unrestricted SKU has all zones usable' -Condition (($none.UsableZones -join ',') -eq '1,2,3' -and -not $none.FullyRestricted)
Assert-True -Name 'all zones usable is full coverage' -Condition ($none.Coverage -eq 'Full') -Detail $none.Coverage

# Display must warn on partial coverage rather than presenting it as clean.
Assert-True -Name 'core exports Get-AqrRegionZone' -Condition ($core.ExportedFunctions.Keys -contains 'Get-AqrRegionZone')
$zoneShow = (Get-Command Show-AqrSkuOption).Definition
Assert-True -Name 'partial AZ coverage is coloured light yellow' -Condition ($zoneShow -match "elseif \(\`$partial\) \{ 'PartialZone' \}")
Assert-True -Name 'partial coverage is not marked recommended' -Condition ($zoneShow -match "elseif \(\`$usable -and -not \`$partial\) \{ '\*' \}")
Assert-True -Name 'table uses shared AZ explanation' -Condition ($zoneShow -match 'Get-AqrZoneSummary')
$zoneSummaryText = (Get-Command Get-AqrZoneSummary).Definition
Assert-True -Name 'missing AZ is worded not available' -Condition ($zoneSummaryText -match 'not available')
Assert-True -Name 'restricted AZ is worded restricted' -Condition ($zoneSummaryText -match 'restricted for this subscription')
Assert-True -Name 'AZ count is shown for partial coverage' -Condition ($zoneShow -match 'only \$\(\$o\.UsableZones\.Count\) of')
Assert-True -Name 'blocked wording is gone' -Condition ($zoneShow -notmatch 'blocked')

# Pasted input: a SKU name, a family name or a family display name must all work.
foreach ($fn in 'ConvertTo-AqrSkuKey', 'Resolve-AqrSkuQuery', 'Get-AqrVmSku') {
    Assert-True -Name "core exports $fn" -Condition ($core.ExportedFunctions.Keys -contains $fn)
}

# Normalisation collapses separators, casing and quota-name noise words.
$sameKey = @('Standard_D4ads_v7', 'standard d4ads v7', 'D4ADS-V7', 'd4ads_v7') | ForEach-Object { ConvertTo-AqrSkuKey -Text $_ }
Assert-True -Name 'SKU spellings normalise to one key' -Condition (@($sameKey | Sort-Object -Unique).Count -eq 1) -Detail ($sameKey -join ' | ')
Assert-True -Name 'family display name normalises to the family key' -Condition ((ConvertTo-AqrSkuKey -Text 'Standard Dadsv7 Family vCPUs') -eq (ConvertTo-AqrSkuKey -Text 'StandardDadsv7Family'))
Assert-True -Name 'different sizes keep different keys' -Condition ((ConvertTo-AqrSkuKey -Text 'Standard_D2ads_v7') -ne (ConvertTo-AqrSkuKey -Text 'Standard_D4ads_v7'))

$fakeSkus = @(
    [pscustomobject]@{ name = 'Standard_D4ads_v7'; family = 'StandardDadsv7Family' }
    [pscustomobject]@{ name = 'Standard_D2ads_v7'; family = 'StandardDadsv7Family' }
    [pscustomobject]@{ name = 'Standard_D4s_v5'; family = 'standardDSv5Family' }
)
$queries = @(
    @{ Q = 'Standard_D4ads_v7'; Match = 'Sku'; Count = 1 }
    @{ Q = 'd4ads_v7'; Match = 'Sku'; Count = 1 }
    @{ Q = 'Standard D4ads v7'; Match = 'Sku'; Count = 1 }
    @{ Q = 'StandardDadsv7Family'; Match = 'Family'; Count = 2 }
    @{ Q = 'Standard Dadsv7 Family vCPUs'; Match = 'Family'; Count = 2 }
    @{ Q = 'nonsense_xyz'; Match = 'None'; Count = 0 }
)
foreach ($case in $queries) {
    $r = Resolve-AqrSkuQuery -Query $case.Q -Sku $fakeSkus
    Assert-True -Name "query '$($case.Q)' resolves as $($case.Match)" -Condition ($r.Match -eq $case.Match -and $r.Names.Count -eq $case.Count) -Detail "got $($r.Match) with $($r.Names.Count)"
}
# An exact SKU name must win over a family that also contains it.
$exact = Resolve-AqrSkuQuery -Query 'Standard_D4ads_v7' -Sku $fakeSkus
Assert-True -Name 'exact SKU wins over family match' -Condition ($exact.Names[0] -eq 'Standard_D4ads_v7')

# Partial input: one hit is taken directly, several are offered as a choice.
$onePartial = Resolve-AqrSkuQuery -Query 'D2ads' -Sku $fakeSkus
Assert-True -Name 'unique partial resolves to one SKU' -Condition ($onePartial.Match -eq 'Partial' -and $onePartial.Names.Count -eq 1) -Detail "$($onePartial.Match)/$($onePartial.Names.Count)"
$manyPartial = Resolve-AqrSkuQuery -Query 'ads' -Sku $fakeSkus
Assert-True -Name 'ambiguous partial returns every hit' -Condition ($manyPartial.Match -eq 'Partial' -and $manyPartial.Names.Count -eq 2) -Detail "$($manyPartial.Match)/$($manyPartial.Names.Count)"

# Menus must read in size order, not alphabetically.
foreach ($fn in 'Get-AqrSkuSortKey', 'Sort-AqrSkuName') {
    Assert-True -Name "core exports $fn" -Condition ($core.ExportedFunctions.Keys -contains $fn)
}
$sorted = Sort-AqrSkuName -Name @('Standard_D128ads_v7', 'Standard_D2ads_v7', 'Standard_D16ads_v7', 'Standard_D4ads_v7')
Assert-True -Name 'SKU menu sorts by size, not alphabetically' -Condition (($sorted -join ',') -eq 'Standard_D2ads_v7,Standard_D4ads_v7,Standard_D16ads_v7,Standard_D128ads_v7') -Detail ($sorted -join ',')
$mixedGen = Sort-AqrSkuName -Name @('Standard_D4ads_v7', 'Standard_D4ads_v5', 'Standard_D4ads_v6')
Assert-True -Name 'same size sorts by generation' -Condition (($mixedGen -join ',') -eq 'Standard_D4ads_v5,Standard_D4ads_v6,Standard_D4ads_v7') -Detail ($mixedGen -join ',')

# The prompt loop must re-ask on no match rather than fall through.
$selectText = (Get-Command Select-AqrVmSku).Definition
Assert-True -Name 'no match re-asks for a SKU' -Condition ($selectText -match 'while \(-not \$picked\)')
Assert-True -Name 'single partial match is reported' -Condition ($selectText -match [regex]::Escape('matched $picked'))

# --- honest results ---------------------------------------------------------
Write-Host "`nResult reporting" -ForegroundColor Cyan

# A reported success must be backed by a re-read of the actual limit.
$requestText = (Get-Command Request-AqrQuotaIncrease).Definition
Assert-True -Name 'success is verified against the real limit' -Condition ($requestText -match 'Get-AqrQuota -SubscriptionId \$SubscriptionId -Location \$Location -QuotaName \$QuotaName')
Assert-True -Name 'partial approval is reported as Partial' -Condition ($requestText -match "Outcome = 'Partial'")
Assert-True -Name 'unverifiable success is not reported as success' -Condition ($requestText -match "State = 'Unverified'")
Assert-True -Name 'success message uses the actual limit' -Condition ($requestText -notmatch "increased to \`$NewLimit")
Assert-True -Name 'partial escalates to support' -Condition ($requestText -match "Outcome = 'Partial'; NeedsSupportTicket = \`$true")

# The entry script must print a per-bucket result table and a failure count.
$entryText = Get-Content -LiteralPath (Join-Path $root 'Start-AzQuotaRequest.ps1') -Raw
Assert-True -Name 'entry script prints a per-quota result table' -Condition ($entryText -match "'QUOTA', 'RESULT', 'BEFORE', 'NOW'")
Assert-True -Name 'entry script reports how many failed' -Condition ($entryText -match 'did NOT succeed')

# A stale limit must never turn into a request that lowers the live quota.
# Raising a family quota often makes Azure raise the regional total too, so the
# value read earlier in the run can be out of date by the time it is used.
Assert-True -Name 'the limit is re-read before requesting' -Condition ($requestText -match '# The limit may have moved since it was read')
Assert-True -Name 'an already satisfied quota is not requested' -Condition ($requestText -match "State = 'AlreadySatisfied'")
Assert-True -Name 'already satisfied short-circuits before the PUT' -Condition ($requestText.IndexOf("AlreadySatisfied") -lt $requestText.IndexOf('-Method PUT'))
Assert-True -Name 'the re-read name is used for the request' -Condition ($requestText -match '\$QuotaName = \$current\.Name')

# Long waits must be visible and bounded, so the tool never looks frozen.
$armText = (Get-Command Invoke-AqrArm).Definition
Assert-True -Name 'retry waits are announced' -Condition ($armText -match 'retrying in \$wait s')
Assert-True -Name 'retry waits are capped' -Condition ($armText -match 'if \(\$wait -gt 60\) \{ \$wait = 60 \}')
Assert-True -Name 'polling reports elapsed time' -Condition ($requestText -match 'of max \$TimeoutSeconds s')
Assert-True -Name 'a stateless poll does not loop silently' -Condition ($requestText -match 'Waiting for the operation to report a state')

# The big lists are fetched once per run: repeated silent downloads of the same
# 1000+ SKU list are what made the tool look frozen.
foreach ($fn in 'Get-AqrLocationList', 'Get-AqrComputeUsage', 'Clear-AqrCache') {
    Assert-True -Name "core exports $fn" -Condition ($core.ExportedFunctions.Keys -contains $fn)
}
$coreText = Get-Content -LiteralPath (Join-Path $root 'src\AzQuotaRequester.Core.psm1') -Raw
Assert-True -Name 'the SKU list is fetched from one place only' -Condition ((@([regex]::Matches($coreText, 'Microsoft\.Compute/skus'))).Count -eq 1) -Detail "$((@([regex]::Matches($coreText, 'Microsoft\.Compute/skus'))).Count) call site(s)"
Assert-True -Name 'the region list is fetched from one place only' -Condition ((@([regex]::Matches($coreText, '/locations\?api-version'))).Count -eq 1) -Detail "$((@([regex]::Matches($coreText, '/locations\?api-version'))).Count) call site(s)"
Assert-True -Name 'the usage list is fetched from one place only' -Condition ((@([regex]::Matches($coreText, 'locations/\$Location/usages'))).Count -eq 1) -Detail "$((@([regex]::Matches($coreText, 'locations/\$Location/usages'))).Count) call site(s)"

# A quota read must never come from a stale snapshot.
$quotaText = (Get-Command Get-AqrQuota).Definition
Assert-True -Name 'quota reads bypass the usage cache' -Condition ($quotaText -match 'Get-AqrComputeUsage .* -Refresh')

# Slow steps must announce themselves.
$locText = (Get-Command Select-AqrLocation).Definition
Assert-True -Name 'region resolution reports progress' -Condition ($locText -match "Resolving region")
$skuSelectText = (Get-Command Select-AqrVmSku).Definition
Assert-True -Name 'SKU loading warns it takes a few seconds' -Condition ($skuSelectText -match 'takes a few seconds')

# Support API state cache drives the step 6 branch.
foreach ($fn in 'Get-AqrSupportApiState', 'Set-AqrSupportApiState', 'Show-AqrPortalQuotaGuidance') {
    Assert-True -Name "support exports $fn" -Condition ($support.ExportedFunctions.Keys -contains $fn)
}
Assert-True -Name 'unknown subscription has unknown API state' -Condition ((Get-AqrSupportApiState -SubscriptionId ([guid]::NewGuid().ToString())) -eq 'Unknown')
Assert-True -Name 'no case is offered when the API is unavailable' -Condition ($entryText -match "Get-AqrSupportApiState -SubscriptionId \`$SubscriptionId\) -eq 'Unavailable'")
Assert-True -Name 'portal guidance is shown instead' -Condition ($entryText -match 'Show-AqrPortalQuotaGuidance')
Assert-True -Name 'InvalidSupportPlan is remembered' -Condition ($entryText -match "Set-AqrSupportApiState -SubscriptionId \`$SubscriptionId -State 'Unavailable'")

$guidance = (Get-Command Show-AqrPortalQuotaGuidance).Definition
Assert-True -Name 'guidance links the quota documentation' -Condition ($guidance -match 'AqrQuotaDocUrl')
Assert-True -Name 'guidance links the Support API prerequisites' -Condition ($guidance -match 'AqrSupportApiDocUrl')

# Quota family options: each generation is its own bucket.
Assert-True -Name 'core exports Get-AqrFamilyOption' -Condition ($core.ExportedFunctions.Keys -contains 'Get-AqrFamilyOption')

# A family entry skips the size question, a specific size keeps it.
$selectText = (Get-Command Select-AqrVmSku).Definition
Assert-True -Name 'family entry skips the size question' -Condition ($selectText -match 'no size is needed')
Assert-True -Name 'family entry sets family mode' -Condition ($selectText -match 'FamilyMode = \$true')
Assert-True -Name 'SKU selection returns a name and family mode' -Condition ($selectText -match 'FamilyMode = \$false')

$wizardText = (Get-Command Invoke-AqrWizard).Definition
Assert-True -Name 'family mode skips the instance-count question' -Condition ($wizardText -match '\(-not \$familyMode\) -and \(Read-AqrYesNo')
Assert-True -Name 'specific size still offers the instance question' -Condition ($wizardText -match 'Instances of \$\(\$sku\.Name\) needed')

# Labels and highlighting.
$showText = (Get-Command Show-AqrSkuOption).Definition
Assert-True -Name 'requested entry is labelled current selection' -Condition ($showText -match 'current selection')
Assert-True -Name 'requested label is gone' -Condition ($showText -notmatch "note \+= 'requested'")
Assert-True -Name 'usable newer generation is highlighted' -Condition ($showText -match 'NEWER GENERATION - recommended')
Assert-True -Name 'usable newer generation is marked and coloured' -Condition ($showText -match "elseif \(\`$usable -and -not \`$partial\) \{ '\*' \}" -and $showText -match "else \{ 'FullZone' \}")
Assert-True -Name 'newer usable options are summarised' -Condition ($showText -match 'A newer generation is usable across all AZs')
Assert-True -Name 'partial-AZ newer options are summarised separately' -Condition ($showText -match 'A newer generation is usable but not in every AZ')

# Tone scheme: lighter than the [ok]/[warn]/[fail] colours so a table row is
# never mistaken for a result message.
foreach ($fn in 'Write-AqrColorLine', 'Test-AqrAnsiSupport') {
    Assert-True -Name "core exports $fn" -Condition ($core.ExportedFunctions.Keys -contains $fn)
}
$toneText = (Get-Command Write-AqrColorLine).Definition
Assert-True -Name 'full AZ coverage uses light green' -Condition ($toneText -match 'FullZone\s+= 120')
Assert-True -Name 'partial AZ coverage uses light yellow' -Condition ($toneText -match 'PartialZone\s+= 229')
Assert-True -Name 'unusable uses dark red' -Condition ($toneText -match 'Unusable\s+= 88')
Assert-True -Name 'tones fall back to console colours' -Condition ($toneText -match "FullZone\s+= 'Green'" -and $toneText -match "Unusable\s+= 'DarkRed'")
Assert-True -Name 'ANSI is skipped when unsupported' -Condition ($toneText -match 'Test-AqrAnsiSupport')
Assert-True -Name 'NO_COLOR is honoured' -Condition ((Get-Command Test-AqrAnsiSupport).Definition -match 'NO_COLOR')

# The selection keeps the meaning of its colour and only gains intensity, so a
# healthy selection never renders as a problem.
Assert-True -Name 'a healthy selection is green, not red' -Condition ($toneText -match 'SelectedFull\s+= 40')
Assert-True -Name 'a partial selection is orange' -Condition ($toneText -match 'SelectedPartial\s+= 208')
Assert-True -Name 'an unusable selection is red' -Condition ($toneText -match 'SelectedUnusable\s+= 196')
Assert-True -Name 'no single colour is used for every selection' -Condition ($toneText -notmatch "Selected\s+=")

# Render real rows and read the colour actually emitted, rather than trusting
# the source text. Write-Host lands on the information stream; its raw message
# is read directly because Out-String strips ANSI when output is redirected.
$renderTone = {
    param($Status, $Coverage, $IsRequested)
    $opt = [pscustomobject]@{
        Name = 'Standard_D4ads_v7'; VCpus = 4; Status = $Status; Limit = 20
        UsableZones = @('1', '2'); RegionZones = @('1', '2', '3')
        NotOfferedZones = @(); RestrictedZones = @(); RestrictionCode = $null
        Coverage = $Coverage; IsRequested = $IsRequested; InUse = $false; Used = 0
    }
    $records = Show-AqrSkuOption -Option @($opt) 6>&1
    $row = @($records | ForEach-Object {
            if ($_.MessageData) { [string]$_.MessageData.Message } else { [string]$_ }
        } | Where-Object { $_ -match 'Standard_D4ads_v7' })[0]
    if ($row -match "$([char]27)\[38;5;(\d+)m") { [int]$Matches[1] } else { -1 }
}

if (Test-AqrAnsiSupport) {
    Assert-True -Name 'selected + all AZs renders green' -Condition ((& $renderTone 'Available' 'Full' $true) -eq 40)
    Assert-True -Name 'selected + some AZs renders orange' -Condition ((& $renderTone 'Available' 'Partial' $true) -eq 208)
    Assert-True -Name 'selected + restricted renders red' -Condition ((& $renderTone 'RestrictedForSubscription' 'None' $true) -eq 196)
    Assert-True -Name 'unselected + all AZs renders light green' -Condition ((& $renderTone 'Available' 'Full' $false) -eq 120)
    Assert-True -Name 'unselected + some AZs renders light yellow' -Condition ((& $renderTone 'Available' 'Partial' $false) -eq 229)
    Assert-True -Name 'unselected + restricted renders dark red' -Condition ((& $renderTone 'RestrictedForSubscription' 'None' $false) -eq 88)
    Assert-True -Name 'selection is a stronger tone, not a different meaning' -Condition ((& $renderTone 'Available' 'Full' $true) -ne (& $renderTone 'Available' 'Partial' $true))
}
else {
    Write-Host '  [skip] colour rendering (host has no virtual terminal)' -ForegroundColor DarkGray
}

# The legend must cover all four row meanings. The wording is cosmetic and
# deliberately not pinned, so it can be reworded without breaking the suite.
Assert-True -Name 'a colour legend is printed' -Condition ($showText -match 'usable in every AZ' -and $showText -match 'restricted or not available')
Assert-True -Name 'the legend explains the selection marker' -Condition ($showText -match "-Text '\s*>\s+current selection")

# Azure names the same SKU line differently per generation
# (standardDADSv5Family -> standardDadv6Family -> StandardDadsv7Family), so a
# family row must show a member SKU or the v6 row reads like another line.
Assert-True -Name 'family rows show an example SKU' -Condition ($showText -match 'e\.g\. \$\(\$o\.Sizes\[0\]\)')
Assert-True -Name 'the example is family-mode only' -Condition ($showText -match 'if \(\$isFamily -and \$o\.Sizes\.Count\)')

$famRows = {
    $mk = {
        param($Name, $Sizes, $IsRequested)
        [pscustomobject]@{
            Name = $Name; Sizes = $Sizes; VCpus = 0; Status = 'Available'; Limit = 20
            UsableZones = @('1', '2', '3'); RegionZones = @('1', '2', '3')
            NotOfferedZones = @(); RestrictedZones = @(); RestrictionCode = $null
            Coverage = 'Full'; IsRequested = $IsRequested; InUse = $false; Used = 0
            DisplayName = "$Name vCPUs"; Version = 5
        }
    }
    $opts = @(
        (& $mk 'standardDADSv5Family' @('Standard_D2ads_v5') $true),
        (& $mk 'standardDadv6Family'  @('Standard_D2ads_v6') $false)
    )
    $records = Show-AqrSkuOption -Option $opts -Title 'QUOTA FAMILY' 6>&1
    @($records | ForEach-Object {
            if ($_.MessageData) { [string]$_.MessageData.Message } else { [string]$_ }
        }) -join "`n"
}
$famOut = & $famRows
Assert-True -Name 'the v6 family row names a v6 SKU' -Condition ($famOut -match 'standardDadv6Family.*e\.g\. Standard_D2ads_v6')
Assert-True -Name 'the v5 family row names a v5 SKU' -Condition ($famOut -match 'standardDADSv5Family.*e\.g\. Standard_D2ads_v5')

# The family picker appends the example, because selection matches on the two
# spaces that follow the display name.
$selText = (Get-Command Select-AqrVmSku).Definition
Assert-True -Name 'the family label keeps its two-space separator' -Condition ($selText -match '\$\(\$_\.DisplayName\)  \[\$\(\$_\.Status\)\]\$tag - e\.g\.')
$label = 'standard Dadv6 Family vCPUs  [Available] (newer, all AZs) - e.g. Standard_D2ads_v6'
Assert-True -Name 'a labelled family still matches its option' -Condition ($label -like 'standard Dadv6 Family vCPUs  *')

# --- console regression checks ---------------------------------------------
& (Join-Path $PSScriptRoot 'Test-AqrConsole.ps1')

# --- online checks ----------------------------------------------------------
if ($Online) {
    Write-Host "`nOnline (read-only)" -ForegroundColor Cyan
    $context = Initialize-AqrContext
    Assert-True -Name 'azure context available' -Condition ([bool]$context.SubscriptionId)

    $loc = Get-AqrLocation -SubscriptionId $context.SubscriptionId -Location $Location
    Assert-True -Name "region $Location resolves to TitleCase" -Condition ($loc.TitleCase -notmatch '\s') -Detail $loc.TitleCase

    $sku = Resolve-AqrVmSku -SubscriptionId $context.SubscriptionId -Location $loc.Name -VmSku $VmSku
    Assert-True -Name "$VmSku maps to a quota family" -Condition ([bool]$sku.Family) -Detail $sku.Family
    Assert-True -Name "$VmSku reports vCPUs" -Condition ($sku.VCpus -gt 0)

    $quota = Get-AqrQuota -SubscriptionId $context.SubscriptionId -Location $loc.Name -QuotaName $sku.Family
    # A region legitimately may not expose a bucket for the family - that is a
    # supported outcome, not a failure.
    if ($quota) {
        Assert-True -Name 'quota read returns a limit' -Condition ($quota.Limit -ge 0) -Detail "limit=$($quota.Limit) used=$($quota.Used)"
    }
    else {
        Assert-True -Name 'missing bucket is reported as null' -Condition $true -Detail "$($sku.Family) has no bucket in $($loc.Name)"
    }
    $quotaDisplayName = if ($quota) { $quota.LocalizedName } else { Get-AqrQuotaDisplayName -Family $sku.Family }
    $quotaLimit = if ($quota) { $quota.Limit } else { 0 }

    $providers = Test-AqrResourceProvider -SubscriptionId $context.SubscriptionId
    Assert-True -Name 'provider states resolved' -Condition (($providers | Where-Object State -EQ 'Unknown').Count -eq 0)

    $class = Get-AqrSkuAvailability -SubscriptionId $context.SubscriptionId -Location $loc.Name -VmSku $VmSku
    Assert-True -Name "$VmSku availability is classified" -Condition ($class.Status -in 'Available', 'ZeroQuota', 'ZoneRestricted', 'NoQuotaBucket', 'RestrictedForSubscription', 'RestrictedBySubscriptionOffer') -Detail $class.Status
    Assert-True -Name 'availability carries a reason' -Condition ([bool]$class.Reason) -Detail $class.Reason

    # The recommendation is the point of the assessment, so exercise it against
    # the live subscription rather than trusting the source text.
    $assessed = Get-AqrMcpTestPayload -Tool 'azqr_assess_sku' -ToolArgs @{ location = $loc.Name; vmSku = $VmSku }
    $validVerdicts = 'Proceed', 'ProceedWithZonePinning', 'ProceedOrSwitch', 'SwitchSku', 'SupportCase', 'RequestQuota'
    $alts = @($assessed.recommendation.alternatives)

    Assert-True -Name 'the assessment reaches a verdict' -Condition ($assessed.recommendation.verdict -in $validVerdicts) -Detail $assessed.recommendation.verdict
    Assert-True -Name 'the verdict is explained in prose' -Condition ($assessed.recommendation.summary.Length -gt 30)
    Assert-True -Name 'quota and zones travel with the verdict' -Condition ($null -ne $assessed.quota -and $null -ne $assessed.zones)
    Assert-True -Name 'zone coverage is classified' -Condition ($assessed.zones.coverage -in 'Full', 'Partial', 'None', 'NonZonal') -Detail $assessed.zones.coverage
    Assert-True -Name 'every recommended alternative is usable' -Condition (@($alts | Where-Object { $_.status -notin 'Available', 'ZeroQuota' }).Count -eq 0)
    Assert-True -Name 'every alternative says why it is offered' -Condition (@($alts | Where-Object { -not $_.why }).Count -eq 0)
    Assert-True -Name 'alternatives are ranked, full coverage before partial' -Condition (
        $alts.Count -lt 2 -or -not @($alts | Where-Object { $_.zoneCoverage -eq 'Full' }).Count -or $alts[0].zoneCoverage -eq 'Full'
    )
    Assert-True -Name 'a usable SKU is its own best pick' -Condition (
        $assessed.recommendation.verdict -notin @('Proceed', 'ProceedWithZonePinning') -or $assessed.recommendation.bestPick -eq $assessed.query
    )
    Assert-True -Name 'a switch verdict never points back at the blocked SKU' -Condition (
        $assessed.recommendation.verdict -ne 'SwitchSku' -or $assessed.recommendation.bestPick -ne $assessed.query
    )

    # A restriction must never read as "you have quota, go ahead".
    $blocked = Get-AqrMcpTestPayload -Tool 'azqr_check_quota' -ToolArgs @{ location = 'germanywestcentral'; vmSku = 'Standard_D4ads_v5' }
    if ($blocked.status -eq 'RestrictedForSubscription') {
        Assert-True -Name 'a restricted SKU is flagged inside the quota result' -Condition (@($blocked.blockers).Count -gt 0)
        Assert-True -Name 'a restricted SKU never gets a proceed verdict' -Condition ($blocked.recommendation.verdict -in 'SwitchSku', 'SupportCase') -Detail $blocked.recommendation.verdict
        Assert-True -Name 'quota headroom does not mask the restriction' -Condition ($blocked.familyQuota.limit -le 0 -or @($blocked.blockers).Count -gt 0)
    }
    else {
        Assert-True -Name 'restricted-SKU check skipped (not restricted here)' -Condition $true -Detail $blocked.status
    }

    $missing = Get-AqrSkuAvailability -SubscriptionId $context.SubscriptionId -Location $loc.Name -VmSku 'Standard_NoSuchSku_v9'
    Assert-True -Name 'unknown SKU is NotOfferedInRegion' -Condition ($missing.Status -eq 'NotOfferedInRegion') -Detail $missing.Status
    Assert-True -Name 'unknown SKU cannot request quota' -Condition (-not $missing.CanRequestQuota -and -not $missing.SupportRequestAdvised)

    # Generation options must only contain SKUs the region really offers.
    $options = @(Get-AqrSkuOption -SubscriptionId $context.SubscriptionId -Location $loc.Name -VmSku $VmSku)
    Assert-True -Name 'options include the requested SKU' -Condition (($options | Where-Object IsRequested).Count -eq 1) -Detail "$($options.Count) option(s)"
    $offered = Get-AqrVmSkuName -SubscriptionId $context.SubscriptionId -Location $loc.Name
    Assert-True -Name 'every option is offered in the region' -Condition (@($options | Where-Object { $_.Name -notin $offered }).Count -eq 0)
    Assert-True -Name 'options are same size, newer generation only' -Condition (@($options | Where-Object { (Split-AqrSkuGeneration -VmSku $_.Name).Stem -ne (Split-AqrSkuGeneration -VmSku $VmSku).Stem }).Count -eq 0)
    Assert-True -Name 'options carry an availability status' -Condition (@($options | Where-Object { -not $_.Status }).Count -eq 0)

    # A pasted family display name must resolve back to real SKUs in the region.
    $regionSkus = Get-AqrVmSku -SubscriptionId $context.SubscriptionId -Location $loc.Name
    $family = ($regionSkus | Where-Object { $_.name -eq $sku.Name }).family
    $display = Get-AqrQuotaDisplayName -Family $family
    $byFamily = Resolve-AqrSkuQuery -Query $display -Sku $regionSkus
    Assert-True -Name 'family display name resolves to SKUs' -Condition ($byFamily.Match -eq 'Family' -and $byFamily.Names -contains $sku.Name) -Detail "'$display' -> $($byFamily.Match), $($byFamily.Names.Count) size(s)"
    $bySku = Resolve-AqrSkuQuery -Query $sku.Name -Sku $regionSkus
    Assert-True -Name 'pasted SKU name resolves exactly' -Condition ($bySku.Match -eq 'Sku' -and $bySku.Names[0] -eq $sku.Name)

    # Family options must be real quota buckets, one per generation.
    $familyOptions = @(Get-AqrFamilyOption -SubscriptionId $context.SubscriptionId -Location $loc.Name -Family $family)
    Assert-True -Name 'family options include the requested family' -Condition ((@($familyOptions | Where-Object IsRequested).Count) -eq 1) -Detail "$($familyOptions.Count) option(s)"
    Assert-True -Name 'each family option is a distinct quota bucket' -Condition ((@($familyOptions.Name | Sort-Object -Unique).Count) -eq $familyOptions.Count)
    Assert-True -Name 'family options carry sizes' -Condition (@($familyOptions | Where-Object { $_.Sizes.Count -eq 0 }).Count -eq 0)
    Assert-True -Name 'family options carry a status' -Condition (@($familyOptions | Where-Object { -not $_.Status }).Count -eq 0)

    $class2 = Get-AqrSupportClassification
    Assert-True -Name 'quota support classification resolves' -Condition ($class2.ProblemClassificationId -match 'problemClassifications/') -Detail $class2.ProblemClassificationName

    # Render the ticket without sending it and check the payload rules the
    # Microsoft.Support API enforces (empty strings and empty arrays are rejected).
    $dryRun = New-AqrQuotaSupportTicket -SubscriptionId $context.SubscriptionId -SubscriptionName 'test' `
        -Location $loc.Name -LocationTitleCase $loc.TitleCase -VmSku $sku.Name -Template $template -WhatIf `
        -QuotaRequest @([pscustomobject]@{
            QuotaName = $sku.Family; LocalizedName = $quotaDisplayName
            CurrentLimit = $quotaLimit; CurrentUsage = 0; TargetLimit = ($quotaLimit + 8)
        })

    $payload = $dryRun.Body | ConvertFrom-Json
    $contact = $payload.properties.contactDetails
    Assert-True -Name 'ticket omits empty phoneNumber' -Condition ($contact.PSObject.Properties.Name -notcontains 'phoneNumber' -or $contact.phoneNumber)
    Assert-True -Name 'ticket omits empty additionalEmailAddresses' -Condition ($contact.PSObject.Properties.Name -notcontains 'additionalEmailAddresses' -or $contact.additionalEmailAddresses.Count -gt 0)
    Assert-True -Name 'ticket omits empty quotaChangeRequestSubType' -Condition ($payload.properties.quotaTicketDetails.PSObject.Properties.Name -notcontains 'quotaChangeRequestSubType' -or $payload.properties.quotaTicketDetails.quotaChangeRequestSubType)
    Assert-True -Name 'ticket region is TitleCase' -Condition ($payload.properties.quotaTicketDetails.quotaChangeRequests[0].region -eq $loc.TitleCase)
    Assert-True -Name 'ticket payload carries the localized VM family' -Condition (($payload.properties.quotaTicketDetails.quotaChangeRequests[0].payload | ConvertFrom-Json).VMFamily -eq $quotaDisplayName)
    Assert-True -Name 'ticket description has no leftover placeholders' -Condition ($payload.properties.description -notmatch '\{[A-Za-z]+\}')
}

# --- MCP server -------------------------------------------------------------
# Driven over real stdio rather than by calling functions: the whole point of
# this server is the wire protocol, and the failure modes that matter (stray
# output, a missing newline, an answered notification) only appear there.
Write-Host "`nMCP server" -ForegroundColor Cyan

Assert-True -Name 'the MCP server is shipped' -Condition (Test-Path $mcpScript)

$raw = @(Invoke-AqrMcpTestFrame -Frame @(
        $handshake
        '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
        '{"jsonrpc":"2.0","id":3,"method":"ping"}'
        '{"jsonrpc":"2.0","id":4,"method":"no/such/method"}'
    ))

Assert-True -Name 'a notification is never answered' -Condition ($raw.Count -eq 4) -Detail "got $($raw.Count) lines"
Assert-True -Name 'every stdout line is one JSON message' -Condition (@($raw | Where-Object { -not ($_ | ConvertFrom-Json -ErrorAction SilentlyContinue) }).Count -eq 0)

$init = $raw[0] | ConvertFrom-Json
Assert-True -Name 'initialize reports the protocol version' -Condition ($init.result.protocolVersion -eq '2025-06-18')
Assert-True -Name 'initialize reports serverInfo' -Condition ($init.result.serverInfo.name -and $init.result.serverInfo.version)
Assert-True -Name 'initialize advertises tools' -Condition ($null -ne $init.result.capabilities.tools)
Assert-True -Name 'initialize carries usage instructions' -Condition ($init.result.instructions -match 'absolute limit')

$old = @(Invoke-AqrMcpTestFrame -Frame @('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}'))
Assert-True -Name 'a known older protocol is echoed back' -Condition ((($old[0] | ConvertFrom-Json).result.protocolVersion) -eq '2024-11-05')
$odd = @(Invoke-AqrMcpTestFrame -Frame @('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{}}}'))
Assert-True -Name 'an unknown protocol falls back to ours' -Condition ((($odd[0] | ConvertFrom-Json).result.protocolVersion) -ne '1999-01-01')

$unknown = $raw[3] | ConvertFrom-Json
Assert-True -Name 'an unknown method is a JSON-RPC error' -Condition ($unknown.error.code -eq -32601)
Assert-True -Name 'ping answers' -Condition ($null -ne ($raw[2] | ConvertFrom-Json).result)

$bad = @(Invoke-AqrMcpTestFrame -Frame @('this is not json'))
Assert-True -Name 'malformed input is a parse error, not a crash' -Condition ((($bad[0] | ConvertFrom-Json).error.code) -eq -32700)

$tools = ($raw[1] | ConvertFrom-Json).result.tools
$expected = 'azqr_get_context', 'azqr_check_quota', 'azqr_check_sku', 'azqr_suggest_skus', 'azqr_request_quota'
foreach ($t in $expected) {
    Assert-True -Name "tools/list offers $t" -Condition (@($tools.name) -contains $t)
}
Assert-True -Name 'every tool has a description' -Condition (@($tools | Where-Object { -not $_.description }).Count -eq 0)
Assert-True -Name 'every tool has an object input schema' -Condition (@($tools | Where-Object { $_.inputSchema.type -ne 'object' }).Count -eq 0)
Assert-True -Name 'the read tools are marked read-only' -Condition (@($tools | Where-Object { $_.name -ne 'azqr_request_quota' -and -not $_.annotations.readOnlyHint }).Count -eq 0)
Assert-True -Name 'the request tool is not marked read-only' -Condition ((@($tools | Where-Object { $_.name -eq 'azqr_request_quota' })[0].annotations.readOnlyHint) -eq $false)
Assert-True -Name 'the request tool documents the absolute limit' -Condition ((@($tools | Where-Object { $_.name -eq 'azqr_request_quota' })[0].description) -match 'ABSOLUTE')
Assert-True -Name 'the request tool never files a support case' -Condition ((@($tools | Where-Object { $_.name -eq 'azqr_request_quota' })[0].description) -match 'never files a support case')

# The modules narrate with Write-Host, which lands on stdout and would corrupt
# the stream. This is the check that proves the process-wide guard holds.
$mcpText = Get-Content $mcpScript -Raw
Assert-True -Name 'stdout is captured before being blackholed' -Condition ($mcpText -match '\$Rpc = \[Console\]::Out' -and $mcpText -match '\[Console\]::SetOut')
Assert-True -Name 'JSON-RPC is written only through the captured handle' -Condition ($mcpText -match '\$Rpc\.WriteLine')
Assert-True -Name 'messages are compressed to a single line' -Condition ($mcpText -match 'ConvertTo-Json -Depth \d+ -Compress')
Assert-True -Name 'the server does not print with Write-Host' -Condition ($mcpText -notmatch '(?m)^\s*Write-Host')

$noisy = @(Invoke-AqrMcpTestFrame -Frame @(
        $handshake
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"azqr_check_quota","arguments":{"location":"nowhere-at-all","vmSku":"nope"}}}'
    ))
Assert-True -Name 'a failing tool call still yields clean JSON only' -Condition (@($noisy | Where-Object { -not ($_ | ConvertFrom-Json -ErrorAction SilentlyContinue) }).Count -eq 0)
$err = ($noisy[1] | ConvertFrom-Json)
Assert-True -Name 'a tool failure is a result with isError, not a protocol error' -Condition ($err.result.isError -eq $true -and $null -eq $err.error)
Assert-True -Name 'a tool failure explains itself' -Condition ($err.result.content[0].text.Length -gt 10)

# A preview must never read as an outcome.
Assert-True -Name 'a preview never claims the target was reached' -Condition ($mcpText -match 'Preview only, nothing was changed')
Assert-True -Name 'the preview summary is chosen before the success summary' -Condition ($mcpText -match '\$summary = if \(\$whatIf\)')
Assert-True -Name 'a request is verified by re-reading the limit' -Condition ($mcpText -match '\$after = Get-AqrQuota' -and $mcpText -match "'Unverified'")
Assert-True -Name 'a restricted SKU is refused before requesting' -Condition ($mcpText -match 'NotRequestable')
Assert-True -Name 'the server never signs in interactively' -Condition ($mcpText -notmatch 'Connect-AzAccount\s*$' -and $mcpText -match 'Not signed in to Azure')

# Recommendations. Quota, restrictions and successors are only useful together:
# a healthy limit on a restricted SKU reads like "you are fine" on its own.
Assert-True -Name 'tools/list offers azqr_assess_sku' -Condition (@($tools.name) -contains 'azqr_assess_sku')
$assessTool = @($tools | Where-Object { $_.name -eq 'azqr_assess_sku' })[0]
Assert-True -Name 'assess_sku is read-only' -Condition ($assessTool.annotations.readOnlyHint -eq $true)
Assert-True -Name 'assess_sku is steered as the preferred entry point' -Condition ($assessTool.description -match 'Prefer this over')
Assert-True -Name 'assess_sku promises a recommendation' -Condition ($assessTool.description -match 'recommends')

Assert-True -Name 'one assessment feeds every tool' -Condition (@([regex]::Matches($mcpText, 'Get-AqrMcpAssessment -SubscriptionId')).Count -ge 5)
Assert-True -Name 'quota results carry the verdict' -Condition ($mcpText -match 'recommendation = \$a\.recommendation')
Assert-True -Name 'a refused request suggests alternatives' -Condition ($mcpText -match 'if \(\$failed\.Count -and -not \$whatIf\)')
foreach ($v in 'Proceed', 'ProceedWithZonePinning', 'ProceedOrSwitch', 'SwitchSku', 'SupportCase', 'RequestQuota') {
    # Matches the literal, not an assignment shape: some verdicts are chosen
    # inline, and pinning the syntax breaks on a harmless refactor.
    Assert-True -Name "the verdict '$v' exists" -Condition ($mcpText -match "'$v'")
}
Assert-True -Name 'a blocked SKU with no usable successor asks for support' -Condition ($mcpText -match "if \(\`$best\) \{ 'SwitchSku' \} else \{ 'SupportCase' \}")
Assert-True -Name 'an unusable option scores below zero' -Condition ($mcpText -match "Status -notin @\('Available', 'ZeroQuota'\)\) \{ return -1 \}")
Assert-True -Name 'unusable candidates are filtered out before ranking' -Condition ($mcpText -match 'Where-Object \{ \$_\.Score -ge 0 \}')
Assert-True -Name 'full zone coverage outranks partial' -Condition ($mcpText -match "\`$score \+= 500" -and $mcpText -match "\`$score \+= 100")
Assert-True -Name 'a healthy SKU still surfaces newer generations' -Condition ($mcpText -match 'worth considering for new capacity')
Assert-True -Name 'blockers separate restricted from not offered' -Condition ($mcpText -match 'not offered here, as opposed to blocked')
Assert-True -Name 'a restriction says a quota request cannot lift it' -Condition (@([regex]::Matches($mcpText, 'quota request cannot')).Count -ge 3)

Write-Host ''
if ($failures -eq 0) { Write-Host "All checks passed." -ForegroundColor Green }
else { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }