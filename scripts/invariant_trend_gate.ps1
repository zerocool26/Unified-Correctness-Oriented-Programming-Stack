param(
    [string]$SummaryPath = "demo-traces/invariant-trends.summary.json",
    [string]$GateReportPath = "demo-traces/invariant-trends.gate.json",
    [int]$MaxTotalIssues = 0,
    [int]$MaxLocalIssues = 0,
    [int]$MaxClusterIssues = 0,
    [int]$MaxTotalDeltaIncrease = 0,
    [int]$MaxLocalDeltaIncrease = 0,
    [int]$MaxClusterDeltaIncrease = 0,
    [int]$MaxSingleCodeDeltaIncrease = 0,
    [switch]$FailOnMissingPrevious
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

function Sum-RowField {
    param(
        $Rows,
        [string]$Field
    )

    $sum = 0
    foreach ($row in @($Rows)) {
        if ($null -eq $row) {
            continue
        }
        $sum += (Get-SafeInt -Value $row.$Field)
    }
    return $sum
}

if (-not (Test-Path $SummaryPath)) {
    throw ("Trend summary not found: {0}" -f $SummaryPath)
}

$summary = Get-Content $SummaryPath -Raw | ConvertFrom-Json -Depth 64

$observedLocal = Get-SafeInt -Value $summary.global.issue_counts.local_verify
$observedCluster = Get-SafeInt -Value $summary.global.issue_counts.cluster_verify
$observedTotal = Get-SafeInt -Value $summary.global.issue_counts.total

$hasPrevious = ($null -ne $summary.global.delta_from_previous)
$localDeltaIncrease = 0
$clusterDeltaIncrease = 0
$totalDeltaIncrease = 0
$maxSingleCodeDeltaIncrease = 0

if ($hasPrevious) {
    $localRows = @($summary.global.delta_from_previous.by_code.local_verify)
    $clusterRows = @($summary.global.delta_from_previous.by_code.cluster_verify)

    $localCurrent = Sum-RowField -Rows $localRows -Field "current"
    $localPrevious = Sum-RowField -Rows $localRows -Field "previous"
    $clusterCurrent = Sum-RowField -Rows $clusterRows -Field "current"
    $clusterPrevious = Sum-RowField -Rows $clusterRows -Field "previous"

    $localDeltaIncrease = [Math]::Max(0, ($localCurrent - $localPrevious))
    $clusterDeltaIncrease = [Math]::Max(0, ($clusterCurrent - $clusterPrevious))
    $totalDeltaIncrease = [Math]::Max(0, (($localCurrent + $clusterCurrent) - ($localPrevious + $clusterPrevious)))

    foreach ($row in @($localRows + $clusterRows)) {
        if ($null -eq $row) {
            continue
        }
        $delta = Get-SafeInt -Value $row.delta
        if ($delta -gt $maxSingleCodeDeltaIncrease) {
            $maxSingleCodeDeltaIncrease = $delta
        }
    }
}

$reasons = @()
if ($observedTotal -gt $MaxTotalIssues) {
    $reasons += ("total issues {0} exceeds threshold {1}" -f $observedTotal, $MaxTotalIssues)
}
if ($observedLocal -gt $MaxLocalIssues) {
    $reasons += ("local issues {0} exceeds threshold {1}" -f $observedLocal, $MaxLocalIssues)
}
if ($observedCluster -gt $MaxClusterIssues) {
    $reasons += ("cluster issues {0} exceeds threshold {1}" -f $observedCluster, $MaxClusterIssues)
}

if ($hasPrevious) {
    if ($totalDeltaIncrease -gt $MaxTotalDeltaIncrease) {
        $reasons += ("total delta increase {0} exceeds threshold {1}" -f $totalDeltaIncrease, $MaxTotalDeltaIncrease)
    }
    if ($localDeltaIncrease -gt $MaxLocalDeltaIncrease) {
        $reasons += ("local delta increase {0} exceeds threshold {1}" -f $localDeltaIncrease, $MaxLocalDeltaIncrease)
    }
    if ($clusterDeltaIncrease -gt $MaxClusterDeltaIncrease) {
        $reasons += ("cluster delta increase {0} exceeds threshold {1}" -f $clusterDeltaIncrease, $MaxClusterDeltaIncrease)
    }
    if ($maxSingleCodeDeltaIncrease -gt $MaxSingleCodeDeltaIncrease) {
        $reasons += ("single invariant delta increase {0} exceeds threshold {1}" -f $maxSingleCodeDeltaIncrease, $MaxSingleCodeDeltaIncrease)
    }
}
elseif ($FailOnMissingPrevious) {
    $reasons += "previous summary baseline is missing but FailOnMissingPrevious is set"
}

$gate = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    summary_path = $SummaryPath
    pass = ($reasons.Count -eq 0)
    has_previous_baseline = $hasPrevious
    thresholds = @{
        max_total_issues = $MaxTotalIssues
        max_local_issues = $MaxLocalIssues
        max_cluster_issues = $MaxClusterIssues
        max_total_delta_increase = $MaxTotalDeltaIncrease
        max_local_delta_increase = $MaxLocalDeltaIncrease
        max_cluster_delta_increase = $MaxClusterDeltaIncrease
        max_single_code_delta_increase = $MaxSingleCodeDeltaIncrease
    }
    observed = @{
        total_issues = $observedTotal
        local_issues = $observedLocal
        cluster_issues = $observedCluster
        total_delta_increase = $totalDeltaIncrease
        local_delta_increase = $localDeltaIncrease
        cluster_delta_increase = $clusterDeltaIncrease
        max_single_code_delta_increase = $maxSingleCodeDeltaIncrease
    }
    reasons = $reasons
}

$reportPath = Join-Path $repoRoot $GateReportPath
$reportDir = Split-Path -Parent $reportPath
if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($reportPath, ($gate | ConvertTo-Json -Depth 32))

Write-Host ("[invariant-trend-gate] report written: {0}" -f $GateReportPath)
Write-Host ("[invariant-trend-gate] observed issues: local={0} cluster={1} total={2}" -f $observedLocal, $observedCluster, $observedTotal)
if ($hasPrevious) {
    Write-Host ("[invariant-trend-gate] delta increase: local={0} cluster={1} total={2} max_code={3}" -f `
            $localDeltaIncrease, $clusterDeltaIncrease, $totalDeltaIncrease, $maxSingleCodeDeltaIncrease)
}

if ($reasons.Count -gt 0) {
    throw ("Invariant trend gate failed: {0}" -f ($reasons -join "; "))
}
