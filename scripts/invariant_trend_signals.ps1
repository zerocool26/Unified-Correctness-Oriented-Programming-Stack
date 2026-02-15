param(
    [string]$SummaryPath = "demo-traces/invariant-trends.summary.json",
    [string]$GateReportPath = "demo-traces/invariant-trends.gate.json",
    [string]$PolicyLintReportPath = "demo-traces/invariant-trends.policy-lint.json",
    [string]$PolicyReportPath = "demo-traces/invariant-trends.policy.json",
    [string]$DebtWindowReportPath = "demo-traces/invariant-trends.debt-windows.json",
    [string]$AnalyticsPath = "demo-traces/invariant-history/analytics.json",
    [string]$SignalsPath = "demo-traces/invariant-trends.signals.json",
    [switch]$FailOnWarn,
    [switch]$FailOnError
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Get-SafeInt {
    param(
        $Value,
        [int]$Default = 0
    )
    if ($null -eq $Value) {
        return $Default
    }
    try {
        return [int]$Value
    }
    catch {
        return $Default
    }
}

function Add-Signal {
    param(
        [System.Collections.ArrayList]$Signals,
        [string]$Severity,
        [string]$Code,
        [string]$Message,
        $Data = $null
    )

    $item = [ordered]@{
        severity = $Severity
        code = $Code
        message = $Message
    }
    if ($null -ne $Data) {
        $item.data = $Data
    }
    [void]$Signals.Add($item)
}

function Read-JsonIfExists {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }
    return (Get-Content $Path -Raw | ConvertFrom-Json -Depth 64)
}

$signals = New-Object System.Collections.ArrayList
$summary = Read-JsonIfExists -Path $SummaryPath
$gate = Read-JsonIfExists -Path $GateReportPath
$policyLint = Read-JsonIfExists -Path $PolicyLintReportPath
$policy = Read-JsonIfExists -Path $PolicyReportPath
$debtWindows = Read-JsonIfExists -Path $DebtWindowReportPath
$analytics = Read-JsonIfExists -Path $AnalyticsPath

if ($null -eq $summary) {
    Add-Signal -Signals $signals -Severity "error" -Code "missing_summary" -Message ("Trend summary not found: {0}" -f $SummaryPath)
}
else {
    $totalIssues = Get-SafeInt -Value $summary.global.issue_counts.total
    $localIssues = Get-SafeInt -Value $summary.global.issue_counts.local_verify
    $clusterIssues = Get-SafeInt -Value $summary.global.issue_counts.cluster_verify

    if ($totalIssues -gt 0) {
        Add-Signal -Signals $signals -Severity "warn" -Code "non_zero_issues" -Message ("Global invariant issues detected: total={0} local={1} cluster={2}" -f $totalIssues, $localIssues, $clusterIssues) -Data @{
            total = $totalIssues
            local = $localIssues
            cluster = $clusterIssues
        }
    }

    $matrixFailures = @($summary.matrices | Where-Object { (Get-SafeInt -Value $_.failed_count) -gt 0 })
    if ($matrixFailures.Count -gt 0) {
        $failedNames = @($matrixFailures | ForEach-Object { [string]$_.matrix })
        Add-Signal -Signals $signals -Severity "error" -Code "matrix_failures" -Message ("Matrix failures detected: {0}" -f ($failedNames -join ", ")) -Data @{
            failed_matrices = $failedNames
            failed_count = $matrixFailures.Count
        }
    }
}

if ($null -eq $gate) {
    Add-Signal -Signals $signals -Severity "warn" -Code "missing_gate_report" -Message ("Gate report not found: {0}" -f $GateReportPath)
}
else {
    if (-not [bool]$gate.pass) {
        Add-Signal -Signals $signals -Severity "error" -Code "gate_failed" -Message "Invariant trend gate failed." -Data @{
            reasons = @($gate.reasons)
        }
    }
    elseif (-not [bool]$gate.has_previous_baseline) {
        Add-Signal -Signals $signals -Severity "info" -Code "missing_previous_baseline" -Message "No previous trend baseline was available for delta comparison."
    }
}

if ($null -eq $policyLint) {
    Add-Signal -Signals $signals -Severity "warn" -Code "missing_policy_lint_report" -Message ("Policy lint report not found: {0}" -f $PolicyLintReportPath)
}
else {
    $lintErrors = Get-SafeInt -Value $policyLint.counts.error
    $lintWarnings = Get-SafeInt -Value $policyLint.counts.warn
    if ($lintErrors -gt 0) {
        Add-Signal -Signals $signals -Severity "error" -Code "policy_lint_errors" -Message ("Policy lint failed with {0} error(s)." -f $lintErrors) -Data @{
            counts = $policyLint.counts
            findings = @($policyLint.findings)
        }
    }
    elseif ($lintWarnings -gt 0) {
        Add-Signal -Signals $signals -Severity "warn" -Code "policy_lint_warnings" -Message ("Policy lint reported {0} warning(s)." -f $lintWarnings) -Data @{
            counts = $policyLint.counts
            findings = @($policyLint.findings)
        }
    }
}

if ($null -eq $policy) {
    Add-Signal -Signals $signals -Severity "warn" -Code "missing_policy_report" -Message ("Policy report not found: {0}" -f $PolicyReportPath)
}
else {
    $profile = [string]$policy.profile
    if (-not [string]::IsNullOrWhiteSpace($profile)) {
        Add-Signal -Signals $signals -Severity "info" -Code "policy_profile" -Message ("Trend policy profile resolved: {0}" -f $profile)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$policy.error)) {
        Add-Signal -Signals $signals -Severity "error" -Code "policy_error" -Message ([string]$policy.error)
    }
}

if ($null -eq $debtWindows) {
    Add-Signal -Signals $signals -Severity "warn" -Code "missing_debt_window_report" -Message ("Debt-window report not found: {0}" -f $DebtWindowReportPath)
}
else {
    $expired = Get-SafeInt -Value $debtWindows.counts.expired
    $invalid = Get-SafeInt -Value $debtWindows.counts.invalid
    $expSoon = Get-SafeInt -Value $debtWindows.counts.expiring_soon
    $expSoonFail = Get-SafeInt -Value $debtWindows.counts.expiring_soon_fail

    if ($expired -gt 0 -or $invalid -gt 0) {
        Add-Signal -Signals $signals -Severity "error" -Code "debt_windows_invalid_or_expired" -Message ("Debt-window failures detected: expired={0} invalid={1}" -f $expired, $invalid) -Data @{
            expired = $expired
            invalid = $invalid
            failures = @($debtWindows.failures)
        }
    }
    if ($expSoon -gt 0 -or $expSoonFail -gt 0) {
        Add-Signal -Signals $signals -Severity "warn" -Code "debt_windows_expiring_soon" -Message ("Debt windows nearing expiry: warn={0} fail_mode={1}" -f $expSoon, $expSoonFail) -Data @{
            expiring_soon = $expSoon
            expiring_soon_fail = $expSoonFail
            warnings = @($debtWindows.warnings)
        }
    }
}

if ($null -eq $analytics) {
    Add-Signal -Signals $signals -Severity "warn" -Code "missing_analytics" -Message ("Trend analytics not found: {0}" -f $AnalyticsPath)
}
else {
    foreach ($alert in @($analytics.alerts)) {
        if ($null -eq $alert) {
            continue
        }
        $severity = [string]$alert.severity
        if ([string]::IsNullOrWhiteSpace($severity)) {
            $severity = "warn"
        }
        Add-Signal -Signals $signals -Severity $severity -Code ("analytics_{0}" -f [string]$alert.code) -Message ([string]$alert.message)
    }
}

$severityRank = @{
    info = 0
    warn = 1
    error = 2
}
$maxRank = 0
foreach ($signal in $signals) {
    $sev = [string]$signal.severity
    $rank = if ($severityRank.ContainsKey($sev)) { [int]$severityRank[$sev] } else { 1 }
    if ($rank -gt $maxRank) {
        $maxRank = $rank
    }
}

$status = "pass"
if ($maxRank -ge 2) {
    $status = "fail"
}
elseif ($maxRank -ge 1) {
    $status = "warn"
}

$signalsReport = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    status = $status
    source_paths = @{
        summary = $SummaryPath
        gate = $GateReportPath
        policy_lint = $PolicyLintReportPath
        policy = $PolicyReportPath
        debt_windows = $DebtWindowReportPath
        analytics = $AnalyticsPath
    }
    counts = @{
        total = $signals.Count
        error = @($signals | Where-Object { [string]$_.severity -eq "error" }).Count
        warn = @($signals | Where-Object { [string]$_.severity -eq "warn" }).Count
        info = @($signals | Where-Object { [string]$_.severity -eq "info" }).Count
    }
    signals = $signals
}

$signalsFile = Join-Path $repoRoot $SignalsPath
$signalsDir = Split-Path -Parent $signalsFile
if (-not [string]::IsNullOrWhiteSpace($signalsDir)) {
    New-Item -ItemType Directory -Path $signalsDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($signalsFile, ($signalsReport | ConvertTo-Json -Depth 64))

Write-Host ("[invariant-trend-signals] report written: {0}" -f $SignalsPath)
Write-Host ("[invariant-trend-signals] status={0} total={1} error={2} warn={3} info={4}" -f `
        $signalsReport.status, $signalsReport.counts.total, $signalsReport.counts.error, $signalsReport.counts.warn, $signalsReport.counts.info)

if ($FailOnError -and $signalsReport.counts.error -gt 0) {
    throw ("Invariant trend signals failed on error severity ({0} error signal(s))" -f $signalsReport.counts.error)
}
if ($FailOnWarn -and ($signalsReport.counts.error + $signalsReport.counts.warn) -gt 0) {
    throw ("Invariant trend signals failed on warn severity (error={0}, warn={1})" -f $signalsReport.counts.error, $signalsReport.counts.warn)
}
