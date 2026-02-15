param(
    [string]$PolicyFilePath = "configs/invariant-trend-policies.json",
    [string]$ReportPath = "demo-traces/invariant-trends.debt-windows.json",
    [int]$WarnDays = 14,
    [int]$FailDays = 7,
    [switch]$FailOnExpiringSoon
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($WarnDays -lt 0) {
    throw "WarnDays must be >= 0"
}
if ($FailDays -lt 0) {
    throw "FailDays must be >= 0"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Parse-UtcDateTimeOffset {
    param(
        [string]$RawValue,
        [string]$FieldLabel
    )

    try {
        return [DateTimeOffset]::Parse(
            $RawValue,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
    }
    catch {
        throw ("Invalid {0} value `{1}`; expected ISO-8601 UTC timestamp" -f $FieldLabel, $RawValue)
    }
}

if (-not (Test-Path $PolicyFilePath)) {
    throw ("Trend policy file not found: {0}" -f $PolicyFilePath)
}

$policyFile = Get-Content $PolicyFilePath -Raw | ConvertFrom-Json -Depth 64
$profileProps = @()
if ($null -ne $policyFile.profiles) {
    $profileProps = @($policyFile.profiles.PSObject.Properties)
}

$nowUtc = (Get-Date).ToUniversalTime()
$windows = @()
$warnings = @()
$failures = @()

foreach ($prop in $profileProps) {
    $profileName = [string]$prop.Name
    $profileNode = $prop.Value
    if ($null -eq $profileNode.debt_window) {
        continue
    }

    $windowState = [ordered]@{
        profile = $profileName
        status = "active"
        now_utc = $nowUtc.ToString("o")
        allow_until_utc = $null
        owner = ""
        tracking_issue = ""
        reason = ""
        remaining_days = $null
        remaining_hours = $null
        error = $null
    }

    try {
        $window = $profileNode.debt_window
        $allowUntilRaw = [string]$window.allow_until_utc
        if ([string]::IsNullOrWhiteSpace($allowUntilRaw)) {
            throw "missing allow_until_utc"
        }
        $allowUntil = Parse-UtcDateTimeOffset -RawValue $allowUntilRaw -FieldLabel "allow_until_utc"

        $owner = [string]$window.owner
        $trackingIssue = [string]$window.tracking_issue
        if ([string]::IsNullOrWhiteSpace($owner)) {
            throw "missing owner"
        }
        if ([string]::IsNullOrWhiteSpace($trackingIssue)) {
            throw "missing tracking_issue"
        }

        $windowState.allow_until_utc = $allowUntil.ToString("o")
        $windowState.owner = $owner
        $windowState.tracking_issue = $trackingIssue
        $windowState.reason = [string]$window.reason

        $remaining = $allowUntil - $nowUtc
        $windowState.remaining_days = [int][Math]::Floor($remaining.TotalDays)
        $windowState.remaining_hours = [double][Math]::Round($remaining.TotalHours, 2)

        $isExpired = ($allowUntil -lt $nowUtc)
        $isExpiringSoon = (-not $isExpired) -and ($remaining.TotalDays -le $WarnDays)
        $isFailingSoon = (-not $isExpired) -and $FailOnExpiringSoon -and ($remaining.TotalDays -le $FailDays)

        if ($isExpired) {
            $windowState.status = "expired"
            $failures += ("profile={0} expired_at={1} owner={2} tracking_issue={3}" -f `
                    $profileName, $allowUntil.ToString("o"), $owner, $trackingIssue)
        }
        elseif ($isFailingSoon) {
            $windowState.status = "expiring_soon_fail"
            $failures += ("profile={0} expires_soon remaining_days={1} allow_until={2} owner={3} tracking_issue={4}" -f `
                    $profileName, $windowState.remaining_days, $allowUntil.ToString("o"), $owner, $trackingIssue)
        }
        elseif ($isExpiringSoon) {
            $windowState.status = "expiring_soon"
            $warnings += ("profile={0} expires_soon remaining_days={1} allow_until={2} owner={3} tracking_issue={4}" -f `
                    $profileName, $windowState.remaining_days, $allowUntil.ToString("o"), $owner, $trackingIssue)
        }
    }
    catch {
        $windowState.status = "invalid"
        $windowState.error = [string]$_.Exception.Message
        $failures += ("profile={0} invalid debt_window metadata: {1}" -f $profileName, $windowState.error)
    }

    $windows += $windowState
}

$windowStatuses = @($windows | ForEach-Object { [string]$_.status })
$report = [ordered]@{
    generated_at_utc = $nowUtc.ToString("o")
    policy_file_path = $PolicyFilePath
    settings = @{
        warn_days = $WarnDays
        fail_days = $FailDays
        fail_on_expiring_soon = [bool]$FailOnExpiringSoon
    }
    profile_count = $profileProps.Count
    debt_window_count = $windows.Count
    counts = @{
        active = @($windowStatuses | Where-Object { $_ -eq "active" }).Count
        expiring_soon = @($windowStatuses | Where-Object { $_ -eq "expiring_soon" }).Count
        expiring_soon_fail = @($windowStatuses | Where-Object { $_ -eq "expiring_soon_fail" }).Count
        expired = @($windowStatuses | Where-Object { $_ -eq "expired" }).Count
        invalid = @($windowStatuses | Where-Object { $_ -eq "invalid" }).Count
    }
    pass = ($failures.Count -eq 0)
    warnings = $warnings
    failures = $failures
    windows = $windows
}

$reportFile = Join-Path $repoRoot $ReportPath
$reportDir = Split-Path -Parent $reportFile
if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($reportFile, ($report | ConvertTo-Json -Depth 64))

Write-Host ("[invariant-trend-debt-windows] report written: {0}" -f $ReportPath)
Write-Host ("[invariant-trend-debt-windows] profiles={0} debt_windows={1} active={2} expiring_soon={3} expiring_soon_fail={4} expired={5} invalid={6}" -f `
        $report.profile_count, $report.debt_window_count, $report.counts.active, $report.counts.expiring_soon, $report.counts.expiring_soon_fail, $report.counts.expired, $report.counts.invalid)

foreach ($warning in $warnings) {
    Write-Warning ("[invariant-trend-debt-windows] {0}" -f $warning)
}

if ($failures.Count -gt 0) {
    throw ("Invariant debt-window guard failed: {0}" -f ($failures -join "; "))
}
