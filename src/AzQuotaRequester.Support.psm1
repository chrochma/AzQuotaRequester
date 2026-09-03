<#
.SYNOPSIS
    Support-ticket fallback for AzQuotaRequester.
.DESCRIPTION
    Resolves the Microsoft.Support service and problem classification for quota
    cases, renders an adjustable JSON template and files the ticket.
#>

# Core provides Invoke-AqrArm and the console helpers.
# No -Force here: it would unload an already imported Core in the caller's scope.
Import-Module (Join-Path $PSScriptRoot 'AzQuotaRequester.Core.psm1') -DisableNameChecking

$script:AqrSupportApi = '2024-04-01'

# "Service and subscription limits (quotas)" - resolved dynamically, kept as fallback.
$script:AqrQuotaServiceIdFallback = '06bfd9d3-516b-d5c6-5802-169c800dec89'

$script:AqrValidSeverity = @('minimal', 'moderate', 'critical', 'highestcriticalimpact')

# Highest to lowest. Used as the fallback ladder when a severity is rejected.
$script:AqrSeverityLadder = @('highestcriticalimpact', 'critical', 'moderate', 'minimal')

$script:AqrValidContactMethod = @('email', 'phone')

$script:AqrQuotaDocUrl = 'https://learn.microsoft.com/azure/quotas/quickstart-increase-quota-portal'
$script:AqrSupportApiDocUrl = 'https://learn.microsoft.com/rest/api/support/'

function Get-AqrSupportApiStateFile {
    <#
    .SYNOPSIS
        Path of the cache that records whether the Support API is usable.
    #>
    Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AzQuotaRequester\support-api-state.json'
}

function Get-AqrSupportApiState {
    <#
    .SYNOPSIS
        Returns what is known about Support API access for a subscription.
    .DESCRIPTION
        Azure exposes no API to read the support plan, so this is only known
        after an attempt. A previous InvalidSupportPlan is remembered so the
        tool does not offer an automated case it cannot create.
    .OUTPUTS
        'Available', 'Unavailable' or 'Unknown'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    $path = Get-AqrSupportApiStateFile
    if (-not (Test-Path -LiteralPath $path)) { return 'Unknown' }
    try { $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return 'Unknown' }

    $entry = $state.PSObject.Properties | Where-Object Name -EQ $SubscriptionId | Select-Object -First 1
    if (-not $entry) { return 'Unknown' }
    if ($entry.Value -in 'Available', 'Unavailable') { return $entry.Value }
    'Unknown'
}

function Set-AqrSupportApiState {
    <#
    .SYNOPSIS
        Remembers whether the Support API worked for a subscription.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][ValidateSet('Available', 'Unavailable')][string]$State
    )

    $path = Get-AqrSupportApiStateFile
    $data = [ordered]@{}
    if (Test-Path -LiteralPath $path) {
        try {
            $existing = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) { $data[$p.Name] = $p.Value }
        }
        catch { }
    }
    $data[$SubscriptionId] = $State

    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

function Show-AqrPortalQuotaGuidance {
    <#
    .SYNOPSIS
        Prints how to raise a quota case without the Support API.
    #>
    [CmdletBinding()]
    param(
        [string]$Location,
        [string]$QuotaDisplayName,
        [int]$TargetLimit
    )

    Write-Host ''
    Write-AqrInfo 'Raise the quota request in the Azure portal instead - quota requests are free of charge on any support plan:'
    Write-AqrInfo '  1. Azure portal  ->  Quotas  ->  My quotas'
    Write-AqrInfo "  2. Filter by provider 'Compute', region '$Location'"
    if ($QuotaDisplayName) { Write-AqrInfo "  3. Select '$QuotaDisplayName'" } else { Write-AqrInfo '  3. Select the quota you need' }
    if ($TargetLimit -gt 0) { Write-AqrInfo "  4. Request a new limit of $TargetLimit" } else { Write-AqrInfo '  4. Request the new limit' }
    Write-Host ''
    Write-AqrInfo "Documentation: $script:AqrQuotaDocUrl"
    Write-AqrInfo "Support API prerequisites: $script:AqrSupportApiDocUrl"
    Write-AqrInfo 'Direct link:   https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas'
}

function Get-AqrSupportClassification {
    <#
    .SYNOPSIS
        Resolves serviceId and problemClassificationId for a quota case.
    .PARAMETER ClassificationMatch
        Regex used to pick the problem classification, e.g. 'Compute-VM'.
    #>
    [CmdletBinding()]
    param(
        [string]$ServiceMatch = 'limits \(quotas\)|quota',
        [string]$ClassificationMatch = 'Compute-VM'
    )

    $services = Invoke-AqrArm -Path "/providers/Microsoft.Support/services?api-version=$script:AqrSupportApi"
    if (-not $services.Success) { throw "Could not list support services: $($services.ErrorMessage)" }

    $service = $services.Body.value | Where-Object { $_.properties.displayName -match $ServiceMatch } | Select-Object -First 1
    $serviceGuid = if ($service) { $service.name } else { $script:AqrQuotaServiceIdFallback }
    $serviceName = if ($service) { $service.properties.displayName } else { 'Service and subscription limits (quotas)' }

    $classes = Invoke-AqrArm -Path "/providers/Microsoft.Support/services/$serviceGuid/problemClassifications?api-version=$script:AqrSupportApi"
    if (-not $classes.Success) { throw "Could not list problem classifications: $($classes.ErrorMessage)" }

    $class = $classes.Body.value | Where-Object { $_.properties.displayName -match $ClassificationMatch } | Select-Object -First 1
    if (-not $class) {
        $available = ($classes.Body.value.properties.displayName | Sort-Object) -join ', '
        throw "No problem classification matched '$ClassificationMatch'. Available: $available"
    }

    [pscustomobject]@{
        ServiceId                 = "/providers/Microsoft.Support/services/$serviceGuid"
        ServiceDisplayName        = $serviceName
        ProblemClassificationId   = "/providers/Microsoft.Support/services/$serviceGuid/problemClassifications/$($class.name)"
        ProblemClassificationName = $class.properties.displayName
    }
}

function Get-AqrTemplatePath {
    <#
    .SYNOPSIS
        Resolves which support ticket template to use.
    .DESCRIPTION
        The personal template must survive a git pull, so it lives in the user
        profile rather than in the repository. Resolution order:
          1. an explicit path
          2. $env:AQR_TEMPLATE_PATH
          3. <ApplicationData>\AzQuotaRequester\support-ticket-template.json
          4. a legacy copy next to the tool (config\support-ticket-template.json)
          5. the shipped example, which is a starting point only
    .PARAMETER ForWrite
        Return the location to write to, ignoring the legacy and example files.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$ForWrite
    )

    if ($Path) { return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path)) }
    if ($env:AQR_TEMPLATE_PATH) { return $env:AQR_TEMPLATE_PATH }

    $userPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AzQuotaRequester\support-ticket-template.json'
    if ($ForWrite -or (Test-Path -LiteralPath $userPath)) { return $userPath }

    # Tool root is the parent of src\.
    $toolRoot = Split-Path -Parent $PSScriptRoot
    foreach ($candidate in 'config\support-ticket-template.json', 'config\support-ticket-template.example.json') {
        $full = Join-Path $toolRoot $candidate
        if (Test-Path -LiteralPath $full) { return $full }
    }

    $userPath
}

function Test-AqrTemplatePersonalized {
    <#
    .SYNOPSIS
        Detects a template that still carries the shipped placeholder values.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Template)

    $contact = $Template.contactDetails
    if (-not $contact) { return $false }

    $placeholders = @('change.me@example.com', 'change me', 'changeme')
    if ($contact.primaryEmailAddress -and $contact.primaryEmailAddress.ToLowerInvariant() -in $placeholders) { return $false }
    if ("$($contact.firstName) $($contact.lastName)".ToLowerInvariant() -in $placeholders) { return $false }
    $true
}

function Import-AqrTicketTemplate {
    <#
    .SYNOPSIS
        Loads and validates the support-ticket template.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Support ticket template not found: $Path" }
    try { $template = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Support ticket template '$Path' is not valid JSON: $($_.Exception.Message)" }

    $contact = $template.contactDetails
    if (-not $contact) { throw 'Template is missing the contactDetails section.' }

    # A case raised with the shipped placeholder contact is useless to support.
    if (-not (Test-AqrTemplatePersonalized -Template $template)) {
        throw "The template at '$Path' still has the shipped placeholder contact details. Run New-AqrTicketTemplate.ps1 to fill it in."
    }

    foreach ($field in 'firstName', 'lastName', 'primaryEmailAddress', 'preferredContactMethod', 'preferredTimeZone', 'country', 'preferredSupportLanguage') {
        if ([string]::IsNullOrWhiteSpace($contact.$field)) { throw "Template field contactDetails.$field must be set." }
    }
    if ($contact.primaryEmailAddress -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        throw "Template field contactDetails.primaryEmailAddress '$($contact.primaryEmailAddress)' is not a valid e-mail address."
    }
    if ($contact.preferredContactMethod -notin $script:AqrValidContactMethod) {
        throw "contactDetails.preferredContactMethod must be one of: $($script:AqrValidContactMethod -join ', ')"
    }
    if ($contact.preferredContactMethod -eq 'phone' -and [string]::IsNullOrWhiteSpace($contact.phoneNumber)) {
        throw 'contactDetails.phoneNumber is required when preferredContactMethod is "phone".'
    }
    if ($contact.country -notmatch '^[A-Za-z]{3}$') {
        throw "contactDetails.country must be a 3-letter ISO 3166 code (e.g. DEU), got '$($contact.country)'."
    }
    if ($template.severity -notin $script:AqrValidSeverity) {
        throw "severity must be one of: $($script:AqrValidSeverity -join ', ')"
    }
    if ($contact.preferredTimeZone -notin ([System.TimeZoneInfo]::GetSystemTimeZones().Id)) {
        Write-AqrWarn "contactDetails.preferredTimeZone '$($contact.preferredTimeZone)' is not a known Windows time zone id on this machine."
    }
    # A 24x7 response is not offered on severity "minimal".
    if ($template.severity -eq 'minimal' -and $template.require24x7Response) {
        Write-AqrWarn 'require24x7Response is not available on severity "minimal" and is ignored.'
    }

    $template
}

function Expand-AqrTemplateToken {
    <#
    .SYNOPSIS
        Replaces {Placeholder} tokens in a template string.
    #>
    param(
        [string]$Text,
        [Parameter(Mandatory)][hashtable]$Token
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($key in $Token.Keys) { $Text = $Text.Replace("{$key}", [string]$Token[$key]) }
    $Text
}

function ConvertTo-AqrTicketBody {
    <#
    .SYNOPSIS
        Renders the ticket request body for one severity attempt.
    .DESCRIPTION
        A 24x7 response is not offered on severity "minimal", so it is forced off
        there. When the severity was lowered, the original request is recorded in
        the description so support still sees the intended urgency.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Properties,
        [Parameter(Mandatory)][string]$Severity,
        [Parameter(Mandatory)][string]$RequestedSeverity
    )

    $attempt = [ordered]@{}
    foreach ($key in $Properties.Keys) { $attempt[$key] = $Properties[$key] }

    $attempt.severity = $Severity
    if ($Severity -eq 'minimal') { $attempt.require24X7Response = $false }

    if ($Severity -ne $RequestedSeverity) {
        $attempt.description = "$($Properties.description)`n`nNOTE: This case was raised with severity '$Severity'. Severity '$RequestedSeverity' was requested but rejected, most likely because the subscription's support plan does not include it."
    }

    @{ properties = $attempt } | ConvertTo-Json -Depth 10
}

function Test-AqrSeverityRejection {
    <#
    .SYNOPSIS
        Decides whether a failed ticket creation looks like a severity or
        support-plan restriction rather than a malformed request.
    #>
    [CmdletBinding()]
    param(
        [int]$StatusCode,
        [string]$Message,
        [string]$ErrorCode
    )

    # A plan that cannot use the Support API at all is not fixed by a lower severity.
    if ($ErrorCode -eq 'InvalidSupportPlan') { return $false }
    if ($Message -match 'support plan type is Free|support plan type is Basic') { return $false }

    if ($StatusCode -notin 400, 401, 403) { return $false }

    # Clear signals first.
    if ($Message -match 'support plan|severity|entitle|not eligible|SubscriptionNotRegistered|unauthorized|forbidden') { return $true }

    # Azure often answers with a generic InvalidParameterValue and no detail, so
    # a 400 with no field-level reason is treated as retryable.
    if ($StatusCode -eq 400 -and $Message -notmatch 'cannot be empty|is not valid|JsonDeserializationError|Provide a valid') { return $true }

    return $false
}

function Wait-AqrSupportOperation {
    <#
    .SYNOPSIS
        Waits for an asynchronous Microsoft.Support operation to finish.
    .DESCRIPTION
        Creating a support ticket returns 202 with an empty body. The real
        outcome - including InvalidSupportPlan - only shows up on the
        Azure-AsyncOperation endpoint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Response,
        [int]$TimeoutSeconds = 180,
        [int]$PollSeconds = 10
    )

    $async = Get-AqrResponseHeader -Response $Response -Name 'Azure-AsyncOperation'
    if (-not $async) { $async = Get-AqrResponseHeader -Response $Response -Name 'Location' }
    if (-not $async) {
        return [pscustomobject]@{ Succeeded = $true; Status = 'Unknown'; Code = $null; Message = 'No async operation returned.' }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $status = 'InProgress'
    $body = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $poll = Invoke-AqrArm -Uri $async
        if (-not $poll.Success) {
            return [pscustomobject]@{ Succeeded = $false; Status = 'PollFailed'; Code = 'PollFailed'; Message = $poll.ErrorMessage }
        }
        $body = $poll.Body
        $status = $body.status
        if ($status -in 'Succeeded', 'Failed', 'Canceled') { break }
        Write-AqrStep "Support request status: $status"
    }

    [pscustomobject]@{
        Succeeded = ($status -eq 'Succeeded')
        Status    = $status
        Code      = $body.error.code
        Message   = if ($body.error.message) { $body.error.message } else { "Support request ended with status '$status'." }
    }
}

function New-AqrQuotaSupportTicket {
    <#
    .SYNOPSIS
        Creates a Microsoft.Support quota ticket for one or more quota buckets.
    .PARAMETER QuotaRequest
        One object per quota bucket with: QuotaName, LocalizedName, TargetLimit,
        CurrentLimit, CurrentUsage, RegionTitleCase.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$SubscriptionName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$LocationTitleCase,
        [Parameter(Mandatory)][string]$VmSku,
        [Parameter(Mandatory)][array]$QuotaRequest,
        [Parameter(Mandatory)]$Template,
        [string]$AutoRequestResult = 'Not attempted.',
        [string]$Severity,
        [string]$TicketName
    )

    $classification = Get-AqrSupportClassification
    Write-AqrStep "Classification: $($classification.ProblemClassificationName)"

    $primary = $QuotaRequest | Select-Object -First 1
    $token = @{
        SubscriptionId    = $SubscriptionId
        SubscriptionName  = $SubscriptionName
        Location          = $Location
        VmSku             = $VmSku
        QuotaName         = $primary.QuotaName
        QuotaDisplayName  = $primary.LocalizedName
        CurrentLimit      = $primary.CurrentLimit
        CurrentUsage      = $primary.CurrentUsage
        TargetLimit       = $primary.TargetLimit
        AdditionalVCores  = [int]$primary.TargetLimit - [int]$primary.CurrentLimit
        Timestamp         = (Get-Date).ToString('u')
        AutoRequestResult = $AutoRequestResult
    }

    # Every requested bucket becomes one quotaChangeRequests entry.
    $changeRequests = foreach ($request in $QuotaRequest) {
        $payload = [ordered]@{
            VMFamily        = $request.LocalizedName
            NewLimit        = [string]$request.TargetLimit
            DeploymentStack = 'ARM'
            Type            = 'Regional'
            EdgeZone        = ''
        } | ConvertTo-Json -Compress

        @{ region = $LocationTitleCase; payload = $payload }
    }

    $contact = $Template.contactDetails
    # Microsoft.Support rejects empty strings and empty arrays, so optional
    # contact fields are only added when they actually carry a value.
    $contactDetails = [ordered]@{
        firstName                = $contact.firstName
        lastName                 = $contact.lastName
        preferredContactMethod   = $contact.preferredContactMethod
        primaryEmailAddress      = $contact.primaryEmailAddress
        preferredTimeZone        = $contact.preferredTimeZone
        country                  = $contact.country.ToUpperInvariant()
        preferredSupportLanguage = $contact.preferredSupportLanguage
    }
    if (-not [string]::IsNullOrWhiteSpace($contact.phoneNumber)) { $contactDetails.phoneNumber = $contact.phoneNumber }
    $additional = @($contact.additionalEmailAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($additional.Count -gt 0) { $contactDetails.additionalEmailAddresses = $additional }

    $quotaDetails = [ordered]@{
        quotaChangeRequestVersion = $Template.quotaTicketDetails.quotaChangeRequestVersion
        quotaChangeRequests       = @($changeRequests)
    }
    # Compute tickets must not carry a subType; it only applies to Batch/SQLMI.
    if (-not [string]::IsNullOrWhiteSpace($Template.quotaTicketDetails.quotaChangeRequestSubType)) {
        $quotaDetails.Insert(0, 'quotaChangeRequestSubType', $Template.quotaTicketDetails.quotaChangeRequestSubType)
    }

    $properties = [ordered]@{
        serviceId                 = $classification.ServiceId
        problemClassificationId   = $classification.ProblemClassificationId
        title                     = Expand-AqrTemplateToken -Text $Template.title -Token $token
        description               = Expand-AqrTemplateToken -Text $Template.description -Token $token
        severity                  = if ($Severity) { $Severity } else { $Template.severity }
        advancedDiagnosticConsent = if ($Template.advancedDiagnosticConsent) { $Template.advancedDiagnosticConsent } else { 'No' }
        require24X7Response       = [bool]$Template.require24x7Response
        contactDetails            = $contactDetails
        quotaTicketDetails        = $quotaDetails
    }
    if ($Template.supportPlanId) { $properties.supportPlanId = $Template.supportPlanId }

    if (-not $TicketName) { $TicketName = "aqr-$([guid]::NewGuid().ToString('N').Substring(0, 12))" }

    $requestedSeverity = $properties.severity
    $body = ConvertTo-AqrTicketBody -Properties $properties -Severity $requestedSeverity -RequestedSeverity $requestedSeverity

    if (-not $PSCmdlet.ShouldProcess("support ticket $TicketName", "Create Azure support request (severity $requestedSeverity)")) {
        return [pscustomobject]@{
            Created = $false; TicketName = $TicketName; Status = 'WhatIf'
            RequestedSeverity = $requestedSeverity; EffectiveSeverity = $requestedSeverity; SeverityDowngraded = $false
            Message = 'Support ticket creation skipped (WhatIf).'; Body = $body
        }
    }

    # Ticket names must be unique per subscription.
    $check = Invoke-AqrArm -Method POST -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Support/checkNameAvailability?api-version=$script:AqrSupportApi" `
        -Payload (@{ name = $TicketName; type = 'Microsoft.Support/supportTickets' } | ConvertTo-Json)
    if ($check.Success -and -not $check.Body.nameAvailable) {
        $TicketName = "aqr-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    }

    # Safety net: a severity the support plan does not cover is rejected, so walk
    # down the ladder until one is accepted rather than losing the case.
    $ladder = @($script:AqrSeverityLadder)
    $start = [array]::IndexOf($ladder, $requestedSeverity)
    if ($start -lt 0) { $start = $ladder.Count - 1 }

    $lastError = $null
    $lastStatus = $null

    for ($i = $start; $i -lt $ladder.Count; $i++) {
        $attemptSeverity = $ladder[$i]
        $downgraded = ($attemptSeverity -ne $requestedSeverity)
        $body = ConvertTo-AqrTicketBody -Properties $properties -Severity $attemptSeverity -RequestedSeverity $requestedSeverity

        if ($downgraded) { Write-AqrStep "Retrying with severity '$attemptSeverity'." }

        $create = Invoke-AqrArm -Method PUT -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Support/supportTickets/$($TicketName)?api-version=$script:AqrSupportApi" -Payload $body

        # The PUT answers 202 with an empty body: creation is asynchronous and
        # can still fail, so the operation has to be polled before claiming success.
        $asyncError = $null
        if ($create.Success -and $create.StatusCode -eq 202) {
            $async = Wait-AqrSupportOperation -Response $create.Response
            if (-not $async.Succeeded) {
                $asyncError = $async
                $create = [pscustomobject]@{
                    Success = $false; StatusCode = $create.StatusCode; Body = $null
                    ErrorMessage = "$($async.Code): $($async.Message)"
                }
            }
            else {
                $create = Invoke-AqrArm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Support/supportTickets/$($TicketName)?api-version=$script:AqrSupportApi"
            }
        }

        if ($create.Success) {
            $message = "Support ticket $($create.Body.properties.supportTicketId) created."
            if ($downgraded) {
                $message += " Severity was lowered from '$requestedSeverity' to '$attemptSeverity' because the subscription's support plan does not cover '$requestedSeverity'."
            }
            return [pscustomobject]@{
                Created            = $true
                TicketName         = $TicketName
                TicketId           = $create.Body.properties.supportTicketId
                Status             = $create.Body.properties.status
                Title              = $create.Body.properties.title
                RequestedSeverity  = $requestedSeverity
                EffectiveSeverity  = $create.Body.properties.severity
                SeverityDowngraded = $downgraded
                Message            = $message
                Body               = $body
            }
        }

        $lastError = $create.ErrorMessage
        $lastStatus = $create.StatusCode

        # Only a plan/severity rejection is worth retrying; anything else is a real error.
        if (-not (Test-AqrSeverityRejection -StatusCode $create.StatusCode -Message $create.ErrorMessage -ErrorCode $asyncError.Code)) { break }
        if ($i -lt $ladder.Count - 1) {
            Write-AqrWarn "Severity '$attemptSeverity' was rejected (HTTP $($create.StatusCode)). The support plan probably does not cover it."
        }
    }

    [pscustomobject]@{
        Created            = $false
        TicketName         = $TicketName
        Status             = "HTTP $lastStatus"
        RequestedSeverity  = $requestedSeverity
        EffectiveSeverity  = $null
        SeverityDowngraded = $false
        Message            = $lastError
        Body               = $body
    }
}

Export-ModuleMember -Function @(
    'Get-AqrSupportClassification', 'Get-AqrTemplatePath', 'Test-AqrTemplatePersonalized',
    'Import-AqrTicketTemplate', 'Expand-AqrTemplateToken', 'ConvertTo-AqrTicketBody',
    'Test-AqrSeverityRejection', 'Wait-AqrSupportOperation', 'New-AqrQuotaSupportTicket',
    'Get-AqrSupportApiState', 'Set-AqrSupportApiState', 'Get-AqrSupportApiStateFile',
    'Show-AqrPortalQuotaGuidance'
)
