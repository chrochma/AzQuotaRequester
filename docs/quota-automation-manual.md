# Azure vCPU quota automation — manual

How to verify, request and escalate Azure compute vCPU quota **from your own code**, using nothing but `Az.Accounts` and the Azure REST APIs.

This is the process the AzQuotaRequester tool implements, written out so it can be reused, adapted or handed to a customer without adopting the tool itself. Every snippet is standalone and copy-pasteable into a PowerShell console.

> **Disclaimer**
> The sample scripts are not supported under any Microsoft standard support program or service. The sample scripts are provided AS IS without warranty of any kind. Microsoft further disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose. The entire risk arising out of the use or performance of the sample scripts and documentation remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the scripts be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the sample scripts or documentation, even if Microsoft has been advised of the possibility of such damages.

---

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Three states you must tell apart](#2-three-states-you-must-tell-apart)
3. [Step 1 — verify what you have (read-only)](#3-step-1--verify-what-you-have-read-only)
4. [Step 2 — request the quota](#4-step-2--request-the-quota)
5. [Step 3 — raise the quota support case](#5-step-3--raise-the-quota-support-case)
6. [API reference](#6-api-reference)
7. [Pitfalls](#7-pitfalls)

---

## 1. Prerequisites

| Item | Requirement |
|---|---|
| PowerShell | 5.1 or 7 |
| Module | `Az.Accounts` only — everything else goes through `Invoke-AzRestMethod` |
| Read the quota | **Reader** on the subscription |
| Request the quota | **Contributor** or **Quota Request Operator** |
| Raise the case | **Support Request Contributor** *and* a Professional Direct, Premier or Unified support plan |

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Connect-AzAccount
Set-AzContext -SubscriptionId '<your-subscription-id>'
```

> The quota request in step 2 works on **any** support plan. Only the support case in step 3 needs a high-tier plan.

---

## 2. Three states you must tell apart

"I cannot deploy this SKU" has three different causes, and only one of them is fixed by a quota request:

| What you see | Meaning | Correct action |
|---|---|---|
| **Quota is 0** (bucket exists) | SKU is allowed, no capacity assigned yet. | **Quota request** — usually automatic. |
| **Restricted** (`NotAvailableForSubscription` / `QuotaId`) | SKU exists in the region but is not enabled for this subscription or its offer type. | **Support case.** A quota request will not unblock it. |
| **No quota bucket** / not listed | The family is not enabled for the subscription in that region, or the SKU is not offered there at all. | **Support case**, or pick another region. |

### The same SKU behaves differently per region

Measured on one subscription, one SKU (`Standard_DC32as_v6`), one day — all three states occur at once:

| Region | Result | Action |
|---|---|---|
| westeurope | Quota is 0 | Request quota |
| eastus | Quota is 0 | Request quota |
| southeastasia | Quota is 0 | Request quota |
| germanywestcentral | No quota bucket | Support case or other region |
| uksouth | Restricted (`NotAvailableForSubscription`) | Support case |

A SKU is rarely blocked for a subscription *in general* — it is blocked **per region**. Always run the check for your own subscriptions; restrictions differ by offer type, by region, and change over time.

---

## 3. Step 1 — verify what you have (read-only)

Nothing is changed. Three questions per region, in order, because each one makes the next meaningful:

1. Is the SKU offered to this subscription in this region?
2. Is it restricted for this subscription?
3. Does the region expose a quota bucket for the SKU family?

```powershell
$SkuName = 'Standard_DC32as_v6'
$Regions = 'westeurope','eastus','germanywestcentral','southeastasia','uksouth'

$sub   = (Get-AzContext).Subscription.Id
$offer = ((Invoke-AzRestMethod -Method GET -Path "/subscriptions/$sub`?api-version=2022-12-01").Content | ConvertFrom-Json).subscriptionPolicies.quotaId
Write-Host "Subscription : $sub"
Write-Host "Offer        : $offer`n"

$report = foreach ($region in $Regions) {

    # 1) Is the SKU offered to this subscription in this region?
    $filter = [uri]::EscapeDataString("location eq '$region'")
    $skuUri = "/subscriptions/$sub/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=$filter"
    $sku = ((Invoke-AzRestMethod -Method GET -Path $skuUri).Content | ConvertFrom-Json).value |
        Where-Object { $_.resourceType -eq 'virtualMachines' -and $_.name -eq $SkuName } | Select-Object -First 1

    if (-not $sku) {
        [pscustomobject]@{ Region=$region; Verdict='Not offered in region'; Family='-'; Limit='-'; Used='-'; Action='Use another region' }
        continue
    }

    # 2) Is it restricted for this subscription?
    $block = $sku.restrictions | Where-Object { $_.type -eq 'Location' } | Select-Object -First 1
    if ($block) {
        $action = if ($block.reasonCode -eq 'QuotaId') { 'Subscription offer excludes it - support case' } else { 'Not enabled for this subscription - support case' }
        [pscustomobject]@{ Region=$region; Verdict="Restricted ($($block.reasonCode))"; Family=$sku.family; Limit='-'; Used='-'; Action=$action }
        continue
    }

    # 3) Does the region expose a quota bucket for the SKU family?
    $usageUri = "/subscriptions/$sub/providers/Microsoft.Compute/locations/$region/usages?api-version=2024-07-01"
    $bucket = ((Invoke-AzRestMethod -Method GET -Path $usageUri).Content | ConvertFrom-Json).value |
        Where-Object { $_.name.value -eq $sku.family } | Select-Object -First 1

    if (-not $bucket) {
        [pscustomobject]@{ Region=$region; Verdict='No quota bucket'; Family=$sku.family; Limit='-'; Used='-'; Action='Family not enabled here - support case' }
        continue
    }

    [pscustomobject]@{
        Region  = $region
        Verdict = if ($bucket.limit -gt 0) { 'Available' } else { 'Quota is 0' }
        Family  = $sku.family
        Limit   = $bucket.limit
        Used    = $bucket.currentValue
        Action  = if ($bucket.limit -gt 0) { 'Deploy or raise quota' } else { 'Request quota' }
    }
}

$report | Format-Table -AutoSize
```

Output:

```text
Region             Verdict                                  Family               Limit Used Action
------             -------                                  ------               ----- ---- ------
westeurope         Quota is 0                               standardDCasv6Family     0    0 Request quota
eastus             Quota is 0                               standardDCasv6Family     0    0 Request quota
germanywestcentral No quota bucket                          standardDCasv6Family     -    - Family not enabled here - support case
southeastasia      Quota is 0                               standardDCasv6Family     0    0 Request quota
uksouth            Restricted (NotAvailableForSubscription) standardDCasv6Family     -    - Not enabled for this subscription - support case
```

### Optional: check availability zones

A SKU can be available in a region but not in every zone, and there are two different reasons for that. `locationInfo.zones` lists the zones the SKU is **offered** in; a `Zone` restriction lists zones that are offered but **blocked** for this subscription.

```powershell
$region = 'westeurope'
$filter = [uri]::EscapeDataString("location eq '$region'")
$skuUri = "/subscriptions/$sub/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=$filter"
$sku = ((Invoke-AzRestMethod -Method GET -Path $skuUri).Content | ConvertFrom-Json).value | Where-Object { $_.resourceType -eq 'virtualMachines' -and $_.name -eq $SkuName } | Select-Object -First 1

# Zones the region itself provides
$locUri = "/subscriptions/$sub/locations?api-version=2022-12-01"
$regionZones = ((Invoke-AzRestMethod -Method GET -Path $locUri).Content | ConvertFrom-Json).value | Where-Object { $_.name -eq $region } | ForEach-Object { $_.availabilityZoneMappings.logicalZone } | Sort-Object -Unique

$offered    = @($sku.locationInfo.zones | Sort-Object -Unique)
$restricted = @($sku.restrictions | Where-Object { $_.type -eq 'Zone' } | ForEach-Object { $_.restrictionInfo.zones } | Sort-Object -Unique)
$usable     = @($offered | Where-Object { $_ -notin $restricted })

[pscustomobject]@{
    RegionZones  = $regionZones -join ','
    Usable       = $usable -join ','
    NotAvailable = (@($regionZones | Where-Object { $_ -notin $offered }) -join ',')
    Restricted   = $restricted -join ','
}
```

An empty `Usable` means the SKU cannot be deployed in that region at all, even if the quota bucket exists.

---

## 4. Step 2 — request the quota

Where the verdict is **Quota is 0** or **Available**, request the new limit through `Microsoft.Quota`. Small increases are approved automatically within seconds to minutes.

> The value is the **new absolute limit**, not an increment.

```powershell
$sub      = (Get-AzContext).Subscription.Id
$region   = 'westeurope'
$family   = 'standardDCasv6Family'   # SKU family from the check above
$newLimit = 64                       # absolute target, e.g. 2 x DC32as_v6

$body = @{ properties = @{
    limit = @{ limitObjectType = 'LimitValue'; value = $newLimit }
    name  = @{ value = $family }
} } | ConvertTo-Json -Depth 5

$quotaUri = "/subscriptions/$sub/providers/Microsoft.Compute/locations/$region/providers/Microsoft.Quota/quotas/$family`?api-version=2023-02-01"
$put = Invoke-AzRestMethod -Method PUT -Payload $body -Path $quotaUri

if ($put.StatusCode -eq 200) {
    Write-Host 'Approved immediately.'
} elseif ($put.StatusCode -eq 202) {
    # Accepted - poll the operation until it reaches a final state
    $pollUri = $put.Headers.GetValues('Location')[0]
    do {
        Start-Sleep -Seconds 15
        $state = ((Invoke-AzRestMethod -Method GET -Uri $pollUri).Content | ConvertFrom-Json).properties.provisioningState
        Write-Host "State: $state"
    } until ($state -in 'Succeeded','Failed','Invalid','Canceled')

    # The detailed record carries the message and the reason code
    $requestId = ($pollUri -split '\?')[0].Split('/')[-1]
    $detailUri = "/subscriptions/$sub/providers/Microsoft.Compute/locations/$region/providers/Microsoft.Quota/quotaRequests/$requestId`?api-version=2023-02-01"
    ((Invoke-AzRestMethod -Method GET -Path $detailUri).Content | ConvertFrom-Json).properties |
        Select-Object provisioningState, message, error
} else {
    Write-Warning "Rejected (HTTP $($put.StatusCode)): $($put.Content)"
}
```

### Always verify the result

`provisioningState: Succeeded` is not proof that you got what you asked for. Read the quota back and compare — a partial grant otherwise looks like a full success:

```powershell
$actual = ((Invoke-AzRestMethod -Method GET -Path $quotaUri).Content | ConvertFrom-Json).properties.limit.value
if ($actual -ge $newLimit) {
    Write-Host "Confirmed: limit is now $actual."
} else {
    Write-Warning "Reported success, but the limit is $actual and $newLimit was requested."
}
```

### Reason codes

| Code | Meaning | Next step |
|---|---|---|
| `ContactSupport` | Azure will not auto-approve this increase. | Support case (step 3). |
| `QuotaNotAvailableForResource` | No capacity assigned for that family in that region for this subscription. | Support case (step 3). |

### Do not forget the regional total

A family increase alone does not unblock a deployment — **Total Regional vCPUs** must cover it too. It is just another quota name, so the same snippet applies with `$family = 'cores'` (or `lowPriorityCores` for Spot capacity).

---

## 5. Step 3 — raise the quota support case

A quota case is a normal support ticket with a `quotaTicketDetails` section, which routes it directly to the quota team.

> **The Support API requires a high-tier support plan.** Per the [REST API prerequisites](https://learn.microsoft.com/rest/api/support/), creating or updating tickets needs a **Professional Direct, Premier or Unified** plan — Free, Basic, Developer and Standard are not sufficient. On those plans the call is accepted with HTTP 202 and then fails asynchronously with `InvalidSupportPlan`, and no ticket is created. This is an API-level gate: REST, `Az.Support` and `az support` all call the same endpoint.
>
> Without a high-tier plan, raise the case in the portal, where quota requests are free of charge:
> **Azure portal → Quotas → My quotas → select the quota → New quota request**
> <https://learn.microsoft.com/azure/quotas/quickstart-increase-quota-portal>

```powershell
$sub      = (Get-AzContext).Subscription.Id
$region   = 'GermanyWestCentral'                    # TitleCase, as the support API expects
$vmFamily = 'Standard DCasv6 Family vCPUs'          # family display name from the check above
$newLimit = '64'                                    # absolute target, not an increment

# "Service and subscription limits (quotas)" / "Compute-VM (cores-vCPUs) subscription limit increases"
$service        = '/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89'
$classification = "$service/problemClassifications/e12e3d1d-7fa0-af33-c6d0-3c50df9658a3"

$payload = @{ VMFamily = $vmFamily; NewLimit = $newLimit; DeploymentStack = 'ARM'; Type = 'Regional'; EdgeZone = '' } | ConvertTo-Json -Compress

$body = @{ properties = @{
    title                     = "vCPU quota increase: $vmFamily to $newLimit in $region"
    description               = "Please enable and increase the $vmFamily quota to $newLimit vCPUs in $region. Business justification: production rollout."
    severity                  = 'minimal'
    advancedDiagnosticConsent = 'No'
    require24X7Response       = $false
    serviceId                 = $service
    problemClassificationId   = $classification
    contactDetails            = @{
        firstName                = 'Jane'
        lastName                 = 'Doe'
        primaryEmailAddress      = 'jane.doe@contoso.com'
        preferredContactMethod   = 'email'
        preferredTimeZone        = 'W. Europe Standard Time'
        preferredSupportLanguage = 'en-us'
        country                  = 'DEU'
    }
    quotaTicketDetails        = @{
        quotaChangeRequestVersion = '1.0'
        quotaChangeRequests       = @(@{ region = $region; payload = $payload })
    }
} } | ConvertTo-Json -Depth 10

$ticket = "quota-$([guid]::NewGuid().ToString('N').Substring(0,12))"
$res = Invoke-AzRestMethod -Method PUT -Payload $body -Path "/subscriptions/$sub/providers/Microsoft.Support/supportTickets/$ticket`?api-version=2024-04-01"

# The PUT answers 202 with an empty body. Creation runs asynchronously and can
# still fail, so poll the operation instead of assuming success.
$async = $res.Headers.GetValues('Azure-AsyncOperation')[0]
do {
    Start-Sleep -Seconds 10
    $op = (Invoke-AzRestMethod -Method GET -Uri $async).Content | ConvertFrom-Json
    Write-Host "Status: $($op.status)"
} until ($op.status -in 'Succeeded','Failed','Canceled')

if ($op.status -eq 'Succeeded') {
    ((Invoke-AzRestMethod -Method GET -Path "/subscriptions/$sub/providers/Microsoft.Support/supportTickets/$ticket`?api-version=2024-04-01").Content | ConvertFrom-Json).properties |
        Select-Object supportTicketId, status, severity
} else {
    $op.error | Select-Object code, message
}
```

### Rules the API enforces

Each of these returns a bare `InvalidParameterValue` if you get it wrong — the detail is in `error.details[].message`:

| Field | Rule |
|---|---|
| `region` | TitleCase (`WestEurope`), not the ARM name `westeurope`. |
| `payload` | A JSON **string**, not a nested object — hence the `ConvertTo-Json -Compress`. |
| `phoneNumber`, `additionalEmailAddresses` | Omit them entirely when unused. An empty string or empty array is rejected. |
| `severity` | Must be covered by the support plan. Quota cases are `minimal`; higher values need a higher plan. |
| `require24X7Response` | Keep `$false` on severity `minimal` — 24x7 is not offered on severity C. |
| `country` / `preferredTimeZone` | 3-letter ISO code (`DEU`) and a Windows time zone id (`W. Europe Standard Time`). |
| `quotaChangeRequestSubType` | Leave it out for Compute; it only applies to Batch and SQL MI. |
| HTTP 202 | Means **accepted**, not created, and the body is empty. Always poll `Azure-AsyncOperation` — a rejected case fails there, not on the PUT. |

### Discovering the two GUIDs

They are stable, but you can list them yourself:

```powershell
$svcUri = "/providers/Microsoft.Support/services?api-version=2024-04-01"
((Invoke-AzRestMethod -Method GET -Path $svcUri).Content | ConvertFrom-Json).value | Where-Object { $_.properties.displayName -like '*quota*' } | Select-Object name, @{n='display';e={$_.properties.displayName}}

$pcUri = "/providers/Microsoft.Support/services/06bfd9d3-516b-d5c6-5802-169c800dec89/problemClassifications?api-version=2024-04-01"
((Invoke-AzRestMethod -Method GET -Path $pcUri).Content | ConvertFrom-Json).value | Select-Object name, @{n='display';e={$_.properties.displayName}}
```

---

## 6. API reference

| Purpose | Method and path | API version |
|---|---|---|
| Subscription offer | `GET /subscriptions/{sub}` | `2022-12-01` |
| Region list and zones | `GET /subscriptions/{sub}/locations` | `2022-12-01` |
| VM SKUs and restrictions | `GET /subscriptions/{sub}/providers/Microsoft.Compute/skus` | `2021-07-01` |
| Quota buckets, limit and usage | `GET /subscriptions/{sub}/providers/Microsoft.Compute/locations/{region}/usages` | `2024-07-01` |
| Read one quota | `GET .../locations/{region}/providers/Microsoft.Quota/quotas/{family}` | `2023-02-01` |
| Request an increase | `PUT .../locations/{region}/providers/Microsoft.Quota/quotas/{family}` | `2023-02-01` |
| Quota request detail | `GET .../locations/{region}/providers/Microsoft.Quota/quotaRequests/{id}` | `2023-02-01` |
| Support services | `GET /providers/Microsoft.Support/services` | `2024-04-01` |
| Problem classifications | `GET /providers/Microsoft.Support/services/{id}/problemClassifications` | `2024-04-01` |
| Create a support case | `PUT /subscriptions/{sub}/providers/Microsoft.Support/supportTickets/{name}` | `2024-04-01` |

Useful constants:

| Value | Meaning |
|---|---|
| `06bfd9d3-516b-d5c6-5802-169c800dec89` | Support service "Service and subscription limits (quotas)" |
| `e12e3d1d-7fa0-af33-c6d0-3c50df9658a3` | Problem classification "Compute-VM (cores-vCPUs) subscription limit increases" |
| `cores` | Quota name for Total Regional vCPUs |
| `lowPriorityCores` | Quota name for regional Spot / low-priority vCPUs |

---

## 7. Pitfalls

Things that cost time when automating this:

- **A family increase alone is not enough.** `Total Regional vCPUs` (`cores`) must cover the new limit as well.
- **The limit is absolute, not a delta.** Sending `8` when the limit is already `20` lowers it.
- **`Succeeded` is not proof.** Read the quota back and compare against the target.
- **HTTP 202 means accepted, not done.** Both the quota API and the support API can fail *after* returning 202. Poll the operation.
- **Quota family names are not predictable.** `Standard_D16ads_v5` → `standardDADSv5Family`, but `Standard_D16ads_v6` → `standardDadv6Family`. Always read `family` from the SKU rather than constructing it.
- **Family name casing varies.** Compare case-insensitively, and use the exact name from the usages API in the request URI.
- **A newer generation is often the faster route.** If `_v5` is restricted, check `_v6` and `_v7` of the same size — they frequently have quota available and fewer zone restrictions.
- **Support case regions are TitleCase.** `WestEurope`, not `westeurope`.
- **Support cases need a high-tier plan.** Everything else on this page works on any plan.

---

## References

- [Microsoft.Quota REST API](https://learn.microsoft.com/rest/api/quota/)
- [Increase regional vCPU quotas](https://learn.microsoft.com/azure/quotas/regional-quota-requests)
- [Increase quotas in the portal](https://learn.microsoft.com/azure/quotas/quickstart-increase-quota-portal)
- [Support REST API prerequisites](https://learn.microsoft.com/rest/api/support/)
- [Create a support ticket (REST)](https://learn.microsoft.com/rest/api/support/support-tickets/create)
- [Compare Azure support plans](https://azure.microsoft.com/support/plans/)
