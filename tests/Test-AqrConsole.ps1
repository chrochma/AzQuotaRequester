[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$core = Import-Module (Join-Path $root 'src\AzQuotaRequester.Core.psm1') -PassThru -DisableNameChecking
$ui = Import-Module (Join-Path $root 'src\AzQuotaRequester.UI.psm1') -Force -PassThru -DisableNameChecking
$failures = 0

function Assert-Console {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-ConsoleCase {
    param([string]$Name, [scriptblock]$Test)
    try { & $Test; Write-Host "  [pass] $Name" -ForegroundColor Green }
    catch { $script:failures++; Write-Host "  [FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red }
}

function ConvertTo-ConsoleText {
    param([object[]]$Records)
    @($Records | ForEach-Object {
        if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData.Message }
        else { [string]$_ }
    }) -join "`n"
}

function Assert-AlertFrame {
    param([string]$Text, [string[]]$Content)
    $lines = @($Text -split '\r?\n' | Where-Object { $_.Trim() })
    Assert-Console ($lines.Count -ge 3) 'Alert must have content and two separators.'
    Assert-Console ($lines[0] -match '^\s*-{20,}\s*$') 'Missing opening separator.'
    Assert-Console ($lines[-1] -eq $lines[0]) 'Missing matching closing separator after the full block.'
    Assert-Console (@($lines | Where-Object { $_ -match '^\s*-{20,}\s*$' }).Count -eq 2) 'Must frame the whole block, not each line.'
    foreach ($item in $Content) {
        Assert-Console ($Text.Contains($item)) "Alert lost: $item"
    }
}

Write-Host "`nConsole regression tests" -ForegroundColor Cyan

Test-ConsoleCase 'region order, canonical mappings, Down and Enter' {
    $labels = @('Germany West Central', 'West Europe', 'North Europe', 'East US',
        'Mexico Central', 'Southeast Asia', 'Japan East', 'South Africa North', 'Other')
    $names = @('germanywestcentral', 'westeurope', 'northeurope', 'eastus',
        'mexicocentral', 'southeastasia', 'japaneast', 'southafricanorth')
    for ($index = 0; $index -lt $names.Count; $index++) {
        $records = @(& $ui {
            param($Index)
            function Test-AqrConsoleInput { $true }
            $keys = [System.Collections.Generic.Queue[ConsoleKey]]::new()
            for ($i = 0; $i -lt $Index; $i++) { $keys.Enqueue([ConsoleKey]::DownArrow) }
            $keys.Enqueue([ConsoleKey]::Enter)
            function Read-AqrConsoleKey { $keys.Dequeue() }
            function Read-AqrText { throw 'A preset must not invoke free text.' }
            function Get-AqrLocation { param($SubscriptionId, $Location) [pscustomobject]@{ Name = $Location } }
            Select-AqrLocation -SubscriptionId 'test'
        } $index 6>&1)
        $picked = @($records | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        Assert-Console ($picked.Count -eq 1 -and $picked[0].Name -ceq $names[$index]) "Wrong mapping at $index."
        $text = ConvertTo-ConsoleText $records
        $last = -1
        foreach ($label in $labels) {
            $position = $text.IndexOf($label)
            Assert-Console ($position -gt $last) "Missing or unordered region: $label"
            $last = $position
        }
    }
}

Test-ConsoleCase 'Up/Down wrap, ignored keys, and Enter confirmation' {
    & $ui {
        param($Assert)
        function Test-AqrConsoleInput { $true }
        $keys = [System.Collections.Generic.Queue[ConsoleKey]]::new()
        foreach ($key in 'UpArrow', 'DownArrow', 'DownArrow', 'UpArrow', 'A', 'Enter') {
            $keys.Enqueue([ConsoleKey]$key)
        }
        function Read-AqrConsoleKey { $keys.Dequeue() }
        $result = Read-AqrArrowChoice -Title 'Test' -Option @('first', 'second', 'Other') 6>$null
        & $Assert ($result -eq 'first' -and $keys.Count -eq 0) 'Navigation or Enter confirmation failed.'
    } ${function:Assert-Console}
}

Test-ConsoleCase 'Other preserves free-text prompt, default, and resolution retry' {
    & $ui {
        param($Assert)
        function Test-AqrConsoleInput { $true }
        $keys = [System.Collections.Generic.Queue[ConsoleKey]]::new()
        $keys.Enqueue([ConsoleKey]::UpArrow)
        $keys.Enqueue([ConsoleKey]::Enter)
        function Read-AqrConsoleKey { $keys.Dequeue() }
        $state = @{ Prompts = 0; Resolutions = 0 }
        function Read-AqrText {
            param($Prompt, $Default)
            & $Assert ($Prompt -ceq 'Region (name or display name)' -and $Default -ceq 'westeurope') 'Free-text contract changed.'
            $state.Prompts++
            if ($state.Prompts -eq 1) { 'bad region' } else { 'Italy North' }
        }
        function Get-AqrLocation {
            param($SubscriptionId, $Location)
            $state.Resolutions++
            if ($Location -eq 'bad region') { throw 'Unknown region.' }
            & $Assert ($Location -ceq 'Italy North') 'Free text must reach the existing resolver unchanged.'
            [pscustomobject]@{ Name = 'italynorth'; TitleCase = 'ItalyNorth' }
        }
        $result = Select-AqrLocation -SubscriptionId 'test' 6>$null
        & $Assert ($result.Name -eq 'italynorth' -and $state.Prompts -eq 2 -and $state.Resolutions -eq 2 -and $keys.Count -eq 0) 'Other did not retry the existing flow.'
    } ${function:Assert-Console}
}

Test-ConsoleCase 'unsupported hosts fail without reading keys or free text' {
    & $ui {
        param($Assert)
        function Test-AqrConsoleInput { $false }
        function Read-AqrConsoleKey { throw 'Unexpected key read.' }
        function Read-AqrText { throw 'Unexpected prompt.' }
        $message = ''
        try { Select-AqrLocation -SubscriptionId 'test' 6>$null } catch { $message = $_.Exception.Message }
        & $Assert ($message -like '*-Location*') 'Fallback must fail promptly with explicit -Location guidance.'
    } ${function:Assert-Console}
}

Test-ConsoleCase 'real non-interactive and redirected child processes cannot enter the picker' {
    $psExe = (Get-Process -Id $PID).Path
    $modulePath = (Join-Path $root 'src\AzQuotaRequester.UI.psm1').Replace("'", "''")
    $command = "Import-Module '$modulePath' -DisableNameChecking; try { Select-AqrLocation -SubscriptionId test; exit 2 } catch { if (`$_.Exception.Message -like '*-Location*') { exit 0 }; exit 3 }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    foreach ($flag in @('-NonInteractive', '-NonI', '')) {
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = [Diagnostics.ProcessStartInfo]@{
            FileName = $psExe
            Arguments = "-NoProfile $flag -InputFormat Text -OutputFormat Text -EncodedCommand $encoded"
            UseShellExecute = $false
            RedirectStandardInput = $true
            RedirectStandardOutput = $true
            RedirectStandardError = $true
        }
        try {
            [void]$process.Start()
            $process.StandardInput.Close()
            Assert-Console ($process.WaitForExit(10000)) "Picker hung with '$flag'."
            Assert-Console ($process.ExitCode -eq 0) "Fallback failed with '$flag': $($process.ExitCode) $($process.StandardError.ReadToEnd())"
        }
        finally {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id }
            $process.Dispose()
        }
    }
}

foreach ($scenario in 'Mixed', 'AllRestricted', 'MissingQuota', 'LocationRestricted', 'UnknownRegionZones') {
    Test-ConsoleCase "$scenario AZ detail survives assessment, tables, and follow-up failure block" {
        $data = & $core {
            param($Scenario)
            $offered = if ($Scenario -eq 'AllRestricted') { @('1', '2', '3') } else { @('1', '2') }
            $restrictions = @([pscustomobject]@{
                type = 'Zone'; reasonCode = 'NotAvailableForSubscription'
                restrictionInfo = [pscustomobject]@{ zones = $offered }
            })
            if ($Scenario -eq 'LocationRestricted') {
                $restrictions += [pscustomobject]@{ type = 'Location'; reasonCode = 'NotAvailableForSubscription' }
            }
            $fixture = [pscustomobject]@{
                name = 'Standard_D2ads_v5'; family = 'standardDADSv5Family'
                locationInfo = @([pscustomobject]@{ zones = $offered })
                restrictions = $restrictions
                capabilities = @([pscustomobject]@{ name = 'vCPUs'; value = '2' })
            }
            function Invoke-AqrArm { [pscustomobject]@{ Success = $true; Body = [pscustomobject]@{} } }
            function Get-AqrVmSku { $fixture }
            function Get-AqrRegionZone { if ($Scenario -ne 'UnknownRegionZones') { '1', '2', '3' } }
            function Get-AqrQuota {
                if ($Scenario -ne 'MissingQuota') {
                    [pscustomobject]@{ Name = 'standardDADSv5Family'; Limit = 20; Used = 0 }
                }
            }
            function Get-AqrComputeUsage {
                @{ standardDADSv5Family = [pscustomobject]@{ limit = 20; currentValue = 0 } }
            }
            [pscustomobject]@{
                Availability = Get-AqrSkuAvailability -SubscriptionId 'test' -Location 'testregion' -VmSku $fixture.name
                Family = @(Get-AqrFamilyOption -SubscriptionId 'test' -Location 'testregion' -Family $fixture.family)
                Sku = @(Get-AqrSkuOption -SubscriptionId 'test' -Location 'testregion' -VmSku $fixture.name)
            }
        } $scenario
        $expected = if ($scenario -eq 'AllRestricted') { 'AZ 1,2,3 restricted for this subscription' }
                    elseif ($scenario -eq 'UnknownRegionZones') { 'AZ 1,2 restricted for this subscription' }
                    else { 'AZ 3 not available; AZ 1,2 restricted for this subscription' }
        Assert-Console (-not $data.Availability.CanRequestQuota) 'Fully restricted zones must never permit automatic quota requests.'
        Assert-Console ($data.Availability.Status -eq 'RestrictedForSubscription') 'Restriction must take precedence over a missing quota bucket.'
        $reason = "$($data.Availability.Reason). $($data.Availability.Detail)"
        Assert-Console ($reason.Contains($expected)) "Assessment lost exact detail: $reason"
        foreach ($options in @($data.Family, $data.Sku)) {
            $table = ConvertTo-ConsoleText @(Show-AqrSkuOption -Option $options 6>&1)
            Assert-Console ($table.Contains($expected)) "Table lost exact detail: $table"
        }
        $records = @(& $ui {
            param($Availability)
            function Get-AqrSkuAvailability { $Availability }
            function Read-AqrChoice { 'Abort' }
            try { Resolve-AqrSkuQuota -SubscriptionId 'test' -Location 'testregion' -VmSku 'Standard_D2ads_v5' }
            catch { if ($_.Exception.Message -notlike 'Aborted:*') { throw } }
        } $data.Availability 6>&1)
        $failureText = ConvertTo-ConsoleText $records
        Assert-AlertFrame $failureText @('[fail]', $expected, $data.Availability.Detail)
        if ($scenario -eq 'UnknownRegionZones') {
            Assert-Console (-not $failureText.Contains('AZ 3')) 'Unknown regional zones must not be invented.'
        }
        $exception = & $ui {
            param($Availability)
            function Get-AqrSkuAvailability { $Availability }
            try { Resolve-AqrSkuQuota -SubscriptionId 'test' -Location 'testregion' -VmSku 'Standard_D2ads_v5' -NonInteractive 6>$null }
            catch { $_.Exception.Message }
        } $data.Availability
        Assert-Console ($exception.Contains($expected)) 'Non-interactive failure lost exact zones.'
    }
}

Test-ConsoleCase 'warning frames enclose reason and all explanation lines' {
    $records = @(& $ui {
        $availability = [pscustomobject]@{
            Status = 'ZoneRestricted'; Reason = 'AZ 3 not available; AZ 2 restricted for this subscription'
            Detail = 'Usable in AZ 1 only. Pin the deployment.'; VmSku = 'Standard_D2ads_v5'; Quota = @{}
        }
        function Get-AqrSkuAvailability { $availability }
        function Resolve-AqrVmSku { [pscustomobject]@{ Name = 'Standard_D2ads_v5' } }
        Resolve-AqrSkuQuota -SubscriptionId 'test' -Location 'testregion' -VmSku 'Standard_D2ads_v5' | Out-Null
    } 6>&1)
    Assert-AlertFrame (ConvertTo-ConsoleText $records) @('[warn]', 'AZ 3 not available; AZ 2 restricted for this subscription', 'Usable in AZ 1 only. Pin the deployment.')
}

Test-ConsoleCase 'disabled-zone warning uses the support-request guidance' {
    $scriptText = Get-Content -LiteralPath (Join-Path $root 'Start-AzQuotaRequest.ps1') -Raw
    Assert-Console ($scriptText.Contains('No enabled availability zone. Open Support Request to validate possibilities.')) 'Disabled-zone warning text changed unexpectedly.'
    Assert-Console (-not $scriptText.Contains('No usable availability zone.')) 'Obsolete disabled-zone warning text remains.'
}

Test-ConsoleCase 'partial newer-generation warning is framed after the table legend' {
    $option = [pscustomobject]@{
        Name = 'Standard_D2ads_v7'; VCpus = 2; Status = 'Available'; Coverage = 'Partial'
        IsRequested = $false; UsableZones = @('1', '2'); RegionZones = @('1', '2', '3')
        NotOfferedZones = @('3'); RestrictedZones = @(); Limit = 20
    }
    $text = ConvertTo-ConsoleText @(Show-AqrSkuOption -Option @($option) 6>&1)
    $start = $text.IndexOf("  $('-' * 60)")
    Assert-Console ($start -ge 0) 'Missing warning frame after table.'
    Assert-AlertFrame $text.Substring($start) @('[warn]', 'Standard_D2ads_v7 (AZ 1,2)', 'Pin the deployment to a usable zone.')
}

if ($failures) { throw "$failures console regression test(s) failed." }
Write-Host 'All console regression tests passed.' -ForegroundColor Green
