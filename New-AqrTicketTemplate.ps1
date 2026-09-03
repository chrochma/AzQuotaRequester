<#
.SYNOPSIS
    Builds the AzQuotaRequester support ticket template step by step.

.DESCRIPTION
    Console wizard that prefills every field the Azure Support API needs for a
    quota case: contact data and contact method, country, time zone, support
    language, severity, response options and the case text.

    Defaults come from the existing template if there is one, otherwise from the
    local machine (time zone, region, UI language). The result is validated
    before it is written, so the file is always usable by Start-AzQuotaRequest.ps1.

.PARAMETER Path
    Template file to write. Defaults to the personal template under
    %APPDATA%\AzQuotaRequester, which a git pull cannot overwrite.

.PARAMETER Force
    Overwrite without asking. An existing file is still backed up.

.EXAMPLE
    .\New-AqrTicketTemplate.ps1

.EXAMPLE
    .\New-AqrTicketTemplate.ps1 -Path .\config\support-ticket-template.prod.json
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\AzQuotaRequester.Core.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src\AzQuotaRequester.Support.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src\AzQuotaRequester.UI.psm1')      -Force -DisableNameChecking

$TotalSteps = 12

# Description skeleton. The placeholders are filled by the tool at ticket time.
$DescriptionSkeleton = @'
Please increase the compute vCPU quota for subscription {SubscriptionName} ({SubscriptionId}).

Region:            {Location}
VM SKU:            {VmSku}
Quota family:      {QuotaName} ({QuotaDisplayName})
Current limit:     {CurrentLimit} vCPUs
Current usage:     {CurrentUsage} vCPUs
Requested limit:   {TargetLimit} vCPUs
Additional vCPUs:  {AdditionalVCores}

The automatic quota request via Microsoft.Quota did not succeed:
{AutoRequestResult}

Business justification: __JUSTIFICATION__

Raised automatically by AzQuotaRequester at {Timestamp}.
'@

function Get-DefaultCountry {
    # 3-letter ISO code of the machine region, e.g. de-DE -> DEU.
    try { return ([System.Globalization.RegionInfo]::new((Get-Culture).Name)).ThreeLetterISORegionName }
    catch { return 'USA' }
}

function Get-CountryOption {
    # "DEU - Germany" labels built from the installed cultures.
    [System.Globalization.CultureInfo]::GetCultures('SpecificCultures') | ForEach-Object {
        try {
            $region = [System.Globalization.RegionInfo]::new($_.Name)
            "$($region.ThreeLetterISORegionName) - $($region.EnglishName)"
        }
        catch { }
    } | Sort-Object -Unique
}

Show-AqrBanner
Write-AqrHeadline 'Support ticket template builder'

# The personal template lives outside the repository so a git pull cannot
# overwrite it.
$Path = Get-AqrTemplatePath -Path $Path -ForWrite
$resolvedTarget = $Path
Write-AqrInfo "Target file: $resolvedTarget"

# Reuse the existing template as the default answer set. If there is none yet,
# fall back to any legacy copy inside the repo, then to the shipped example.
$existing = $null
$defaultsFrom = $null
foreach ($candidate in @($resolvedTarget, (Join-Path $PSScriptRoot 'config\support-ticket-template.json'), (Join-Path $PSScriptRoot 'config\support-ticket-template.example.json'))) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    try {
        $existing = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
        $defaultsFrom = $candidate
        break
    }
    catch { Write-AqrWarn "Ignoring '$candidate': not valid JSON." }
}
if ($defaultsFrom -and $defaultsFrom -ne $resolvedTarget) { Write-AqrInfo "Defaults taken from: $defaultsFrom" }

$old = if ($existing) { $existing.contactDetails } else { $null }
# Never seed the shipped placeholder contact as a default answer.
if ($old -and -not (Test-AqrTemplatePersonalized -Template $existing)) { $old = $null }

# --- 1) name ----------------------------------------------------------------
Write-AqrHeadline "Step 1/$TotalSteps  Contact name"
Write-AqrInfo 'The person Azure support will contact about this case.'
$firstName = Read-AqrText -Prompt 'First name' -Default ($old.firstName)
$lastName = Read-AqrText -Prompt 'Last name'  -Default ($old.lastName)

# --- 2) primary e-mail ------------------------------------------------------
Write-AqrHeadline "Step 2/$TotalSteps  Primary e-mail"
while ($true) {
    $primaryEmail = Read-AqrText -Prompt 'Primary e-mail address' -Default ($old.primaryEmailAddress)
    if ($primaryEmail -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { break }
    Write-AqrWarn 'That is not a valid e-mail address.'
}

# --- 3) additional e-mails --------------------------------------------------
Write-AqrHeadline "Step 3/$TotalSteps  Additional e-mail addresses"
Write-AqrInfo 'Optional. Comma separated, leave empty for none.'
$additionalDefault = if ($old -and $old.additionalEmailAddresses) { ($old.additionalEmailAddresses -join ', ') } else { '' }
$additionalEmails = @()
while ($true) {
    $raw = Read-AqrText -Prompt 'Additional e-mail addresses' -Default $additionalDefault -AllowEmpty
    if ([string]::IsNullOrWhiteSpace($raw)) { break }
    $candidates = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $bad = @($candidates | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
    if ($bad) { Write-AqrWarn "Not valid: $($bad -join ', ')"; continue }
    $additionalEmails = $candidates
    break
}

# --- 4) contact method ------------------------------------------------------
Write-AqrHeadline "Step 4/$TotalSteps  Preferred contact method"
$methodDefault = if ($old -and $old.preferredContactMethod -eq 'phone') { 'phone' } else { 'email' }
$contactMethod = Read-AqrChoice -Title "Contact method (current: $methodDefault)" -Option @('email', 'phone')

# --- 5) phone ---------------------------------------------------------------
Write-AqrHeadline "Step 5/$TotalSteps  Phone number"
$phoneNumber = ''
if ($contactMethod -eq 'phone') {
    Write-AqrInfo 'Required because the contact method is phone. Use the international format.'
    while ($true) {
        $phoneNumber = Read-AqrText -Prompt 'Phone number' -Default ($old.phoneNumber)
        if ($phoneNumber -match '^\+?[0-9 ()\-]{6,}$') { break }
        Write-AqrWarn 'Enter a plausible phone number, e.g. +49 89 1234567.'
    }
}
else {
    Write-AqrInfo 'Optional for e-mail contact. Left empty it is omitted from the ticket.'
    $phoneNumber = Read-AqrText -Prompt 'Phone number' -Default ($old.phoneNumber) -AllowEmpty
}

# --- 6) country -------------------------------------------------------------
Write-AqrHeadline "Step 6/$TotalSteps  Country"
Write-AqrInfo 'Azure expects a 3-letter ISO 3166 code.'
$countryDefault = if ($old -and $old.country) { $old.country.ToUpperInvariant() } else { Get-DefaultCountry }
$countryPick = Read-AqrSearchChoice -Prompt 'Country (code or name)' -Option (Get-CountryOption) -Default $countryDefault
$country = ($countryPick -split ' ')[0].ToUpperInvariant()

# --- 7) time zone -----------------------------------------------------------
Write-AqrHeadline "Step 7/$TotalSteps  Time zone"
Write-AqrInfo 'Windows time zone id, used to schedule the callback window.'
$tzDefault = if ($old -and $old.preferredTimeZone) { $old.preferredTimeZone } else { (Get-TimeZone).Id }
$timeZone = Read-AqrSearchChoice -Prompt 'Time zone' -Option ([System.TimeZoneInfo]::GetSystemTimeZones().Id) -Default $tzDefault

# --- 8) support language ----------------------------------------------------
Write-AqrHeadline "Step 8/$TotalSteps  Support language"
$languages = @('en-us', 'de-de', 'es-es', 'fr-fr', 'it-it', 'ja-jp', 'ko-kr', 'pt-br', 'ru-ru', 'zh-hans', 'zh-hant')
$langDefault = if ($old -and $old.preferredSupportLanguage) { $old.preferredSupportLanguage } else { (Get-UICulture).Name.ToLowerInvariant() }
if ($langDefault -notin $languages) { $langDefault = 'en-us' }
$language = Read-AqrChoice -Title "Support language (current: $langDefault)" -Option $languages

# --- 9) severity ------------------------------------------------------------
Write-AqrHeadline "Step 9/$TotalSteps  Severity"
Write-AqrInfo 'Quota cases are normally "minimal". Higher severities need a paid support plan.'
$severity = Read-AqrChoice -Title 'Severity' -Option @('minimal', 'moderate', 'critical', 'highestcriticalimpact')

# --- 10) response options ---------------------------------------------------
Write-AqrHeadline "Step 10/$TotalSteps  Response options"
if ($severity -eq 'minimal') {
    # Azure does not offer a 24x7 response on severity C.
    $require24x7 = $false
    Write-AqrInfo 'A 24x7 response is not available on severity "minimal", so it is set to false.'
}
else {
    $require24x7 = Read-AqrYesNo -Prompt 'Require a 24x7 response?' -Default ([bool]($existing.require24x7Response))
}
Write-AqrInfo 'Advanced diagnostic consent lets support collect diagnostic information.'
$consentDefault = [bool]($existing -and $existing.advancedDiagnosticConsent -eq 'Yes')
$consent = if (Read-AqrYesNo -Prompt 'Give advanced diagnostic consent?' -Default $consentDefault) { 'Yes' } else { 'No' }

# --- 11) case text ----------------------------------------------------------
Write-AqrHeadline "Step 11/$TotalSteps  Case text"
$title = Read-AqrText -Prompt 'Title' -Default $(if ($existing -and $existing.title) { $existing.title } else { 'vCPU quota increase: {QuotaDisplayName} to {TargetLimit} in {Location}' })

$keepDescription = $false
if ($existing -and $existing.description) {
    $keepDescription = Read-AqrYesNo -Prompt 'Keep the existing description text?' -Default $true
}
if ($keepDescription) {
    $description = $existing.description
}
else {
    Write-AqrInfo 'The quota numbers are filled in automatically. Only the justification is up to you.'
    $justification = Read-AqrText -Prompt 'Business justification' -Default 'planned workload rollout requires the additional capacity'
    $description = $DescriptionSkeleton.Replace('__JUSTIFICATION__', $justification)
}

# --- 12) support plan -------------------------------------------------------
Write-AqrHeadline "Step 12/$TotalSteps  Support plan"
Write-AqrInfo 'Optional. Leave empty to use the subscription default support plan.'
$supportPlanId = Read-AqrText -Prompt 'Support plan id' -Default ($existing.supportPlanId) -AllowEmpty

# --- build, validate, write -------------------------------------------------
$template = [ordered]@{
    '_comment'                = @(
        'Generated by New-AqrTicketTemplate.ps1.',
        'Placeholders replaced at runtime: {SubscriptionId} {SubscriptionName} {Location} {VmSku} {QuotaName}',
        '{QuotaDisplayName} {CurrentLimit} {CurrentUsage} {TargetLimit} {AdditionalVCores} {Timestamp} {AutoRequestResult}',
        'phoneNumber and additionalEmailAddresses are omitted from the ticket when empty.',
        'quotaChangeRequestSubType stays empty for Compute; it only applies to Batch/SQLMI.'
    )
    title                     = $title
    severity                  = $severity
    require24x7Response       = $require24x7
    advancedDiagnosticConsent = $consent
    description               = $description
    contactDetails            = [ordered]@{
        firstName                = $firstName
        lastName                 = $lastName
        primaryEmailAddress      = $primaryEmail
        additionalEmailAddresses = @($additionalEmails)
        phoneNumber              = $phoneNumber
        preferredContactMethod   = $contactMethod
        preferredTimeZone        = $timeZone
        country                  = $country
        preferredSupportLanguage = $language
    }
    quotaTicketDetails        = [ordered]@{
        quotaChangeRequestSubType = ''
        quotaChangeRequestVersion = '1.0'
    }
    supportPlanId             = if ([string]::IsNullOrWhiteSpace($supportPlanId)) { $null } else { $supportPlanId }
}

Write-AqrHeadline 'Summary'
Write-AqrInfo "Contact:   $firstName $lastName <$primaryEmail>"
if ($additionalEmails) { Write-AqrInfo "CC:        $($additionalEmails -join ', ')" }
Write-AqrInfo "Method:    $contactMethod$(if ($phoneNumber) { " ($phoneNumber)" })"
Write-AqrInfo "Locale:    $country / $timeZone / $language"
Write-AqrInfo "Severity:  $severity, 24x7: $require24x7, diagnostics: $consent"
Write-AqrInfo "Title:     $title"

$json = $template | ConvertTo-Json -Depth 10

# Validate before writing so a broken template can never land on disk.
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "aqr-template-$([guid]::NewGuid().ToString('N')).json"
try {
    Set-Content -LiteralPath $temp -Value $json -Encoding utf8
    Import-AqrTicketTemplate -Path $temp | Out-Null
    Write-AqrOk 'Template passed validation.'
}
catch {
    Write-AqrFail "Template is not valid: $($_.Exception.Message)"
    throw
}
finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }

if ((Test-Path -LiteralPath $Path) -and -not $Force) {
    if (-not (Read-AqrYesNo -Prompt "Overwrite $Path ?" -Default $true)) {
        Write-AqrWarn 'Nothing written.'
        return
    }
}

if (Test-Path -LiteralPath $Path) {
    $backup = "$Path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Write-AqrInfo "Previous template backed up to $(Split-Path -Leaf $backup)"
}

$directory = Split-Path -Parent $Path
if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

# Write through .NET so the encoding is identical on Windows PowerShell 5.1 and
# PowerShell 7 (Set-Content -Encoding utf8 adds a BOM on 5.1).
$absolute = $resolvedTarget
[System.IO.File]::WriteAllText($absolute, $json, (New-Object System.Text.UTF8Encoding($false)))

# Read the file back so a silent write failure or an editor holding an old copy
# can never be mistaken for success.
$written = $null
try { $written = Get-Content -LiteralPath $absolute -Raw | ConvertFrom-Json }
catch { throw "The template was written but cannot be read back as JSON: $($_.Exception.Message)" }

$mismatch = @()
if ($written.contactDetails.primaryEmailAddress -ne $primaryEmail) { $mismatch += 'primaryEmailAddress' }
if ($written.contactDetails.firstName -ne $firstName) { $mismatch += 'firstName' }
if ($written.severity -ne $severity) { $mismatch += 'severity' }
if ($written.contactDetails.preferredContactMethod -ne $contactMethod) { $mismatch += 'preferredContactMethod' }
if ($mismatch) {
    Write-AqrFail "The file on disk does not match what was entered: $($mismatch -join ', ')"
    throw "Write verification failed for $absolute"
}

Write-AqrOk "Template written and verified: $absolute"
Write-AqrInfo "On disk now: $($written.contactDetails.firstName) $($written.contactDetails.lastName) <$($written.contactDetails.primaryEmailAddress)>, severity $($written.severity), $((Get-Item -LiteralPath $absolute).Length) bytes"
Write-AqrWarn 'If this file is open in an editor, reload it - the editor may still show the previous content.'
Write-AqrInfo 'Run Start-AzQuotaRequest.ps1 to use it.'
