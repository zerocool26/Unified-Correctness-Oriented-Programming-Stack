param(
    [string]$HistoryIndexPath = "demo-traces/invariant-history/index.json",
    [string]$AnalyticsPath = "demo-traces/invariant-history/analytics.json",
    [string]$MarkdownPath = "demo-traces/invariant-history/analytics.md",
    [int[]]$Windows = @(5, 10, 20),
    [double]$AlertSlopeThreshold = 0.5,
    [int]$AlertIncreaseStreak = 3
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($AlertIncreaseStreak -lt 2) {
    throw "AlertIncreaseStreak must be >= 2"
}

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

function Get-LinearSlope {
    param([double[]]$Series)

    if ($Series.Count -lt 2) {
        return 0.0
    }
    $n = [double]$Series.Count
    $sumX = 0.0
    $sumY = 0.0
    $sumXY = 0.0
    $sumXX = 0.0
    for ($i = 0; $i -lt $Series.Count; $i++) {
        $x = [double]$i
        $y = [double]$Series[$i]
        $sumX += $x
        $sumY += $y
        $sumXY += ($x * $y)
        $sumXX += ($x * $x)
    }
    $den = ($n * $sumXX) - ($sumX * $sumX)
    if ([Math]::Abs($den) -lt 1e-9) {
        return 0.0
    }
    return (($n * $sumXY) - ($sumX * $sumY)) / $den
}

if (-not (Test-Path $HistoryIndexPath)) {
    throw ("History index not found: {0}" -f $HistoryIndexPath)
}

$index = Get-Content $HistoryIndexPath -Raw | ConvertFrom-Json -Depth 64
$entries = @($index.entries)
$entries = @(
    $entries | Sort-Object -Property @{ Expression = { [DateTime]::Parse([string]$_.generated_at_utc) }; Descending = $false }
)

$series = @()
foreach ($entry in $entries) {
    $series += [ordered]@{
        generated_at_utc = [string]$entry.generated_at_utc
        branch = [string]$entry.branch
        commit_sha = [string]$entry.commit_sha
        run_id = [string]$entry.run_id
        total_issues = (Get-SafeInt -Value $entry.issue_counts.total)
        local_issues = (Get-SafeInt -Value $entry.issue_counts.local_verify)
        cluster_issues = (Get-SafeInt -Value $entry.issue_counts.cluster_verify)
    }
}

$totals = @($series | ForEach-Object { [double]$_.total_issues })
$entryCount = $series.Count
$latestTotal = if ($entryCount -gt 0) { [int]$series[$entryCount - 1].total_issues } else { 0 }
$firstTotal = if ($entryCount -gt 0) { [int]$series[0].total_issues } else { 0 }
$deltaFromFirst = $latestTotal - $firstTotal
$globalSlope = [Math]::Round((Get-LinearSlope -Series $totals), 4)

$increaseStreak = 1
if ($entryCount -eq 0) {
    $increaseStreak = 0
}
elseif ($entryCount -gt 1) {
    $increaseStreak = 1
    for ($i = $entryCount - 1; $i -gt 0; $i--) {
        $curr = [int]$series[$i].total_issues
        $prev = [int]$series[$i - 1].total_issues
        if ($curr -gt $prev) {
            $increaseStreak += 1
        }
        else {
            break
        }
    }
}

$windowRows = @()
foreach ($w in @($Windows | Where-Object { $_ -gt 0 } | Sort-Object -Unique)) {
    if ($entryCount -eq 0) {
        $windowRows += [ordered]@{
            window = $w
            sample_count = 0
            avg_total_issues = 0.0
            max_total_issues = 0
            min_total_issues = 0
            latest_total_issues = 0
            slope = 0.0
        }
        continue
    }
    $take = [Math]::Min($w, $entryCount)
    $slice = @($series | Select-Object -Last $take)
    $sliceTotals = @($slice | ForEach-Object { [double]$_.total_issues })
    $avg = 0.0
    if ($sliceTotals.Count -gt 0) {
        $avg = ($sliceTotals | Measure-Object -Average).Average
    }
    $windowRows += [ordered]@{
        window = $w
        sample_count = $take
        avg_total_issues = [Math]::Round([double]$avg, 4)
        max_total_issues = [int](($sliceTotals | Measure-Object -Maximum).Maximum)
        min_total_issues = [int](($sliceTotals | Measure-Object -Minimum).Minimum)
        latest_total_issues = [int]$slice[$slice.Count - 1].total_issues
        slope = [Math]::Round((Get-LinearSlope -Series $sliceTotals), 4)
    }
}

$alerts = @()
if ($entryCount -lt 2) {
    $alerts += [ordered]@{
        severity = "info"
        code = "insufficient_history"
        message = "Need at least 2 entries for drift analytics."
    }
}
if ($latestTotal -gt 0) {
    $alerts += [ordered]@{
        severity = "warn"
        code = "non_zero_latest_issues"
        message = ("Latest history entry has non-zero issues ({0})." -f $latestTotal)
    }
}
if ($globalSlope -gt $AlertSlopeThreshold) {
    $alerts += [ordered]@{
        severity = "warn"
        code = "positive_issue_slope"
        message = ("Issue slope {0} exceeds threshold {1}." -f $globalSlope, $AlertSlopeThreshold)
    }
}
if ($increaseStreak -ge $AlertIncreaseStreak) {
    $alerts += [ordered]@{
        severity = "warn"
        code = "increase_streak"
        message = ("Issue totals increased for {0} consecutive entries." -f $increaseStreak)
    }
}

$analytics = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    history_index_path = $HistoryIndexPath
    entry_count = $entryCount
    latest_total_issues = $latestTotal
    first_total_issues = $firstTotal
    delta_from_first = $deltaFromFirst
    global_slope = $globalSlope
    increase_streak = $increaseStreak
    windows = $windowRows
    alerts = $alerts
    series = $series
}

$analyticsFile = Join-Path $repoRoot $AnalyticsPath
$analyticsDir = Split-Path -Parent $analyticsFile
if (-not [string]::IsNullOrWhiteSpace($analyticsDir)) {
    New-Item -ItemType Directory -Path $analyticsDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($analyticsFile, ($analytics | ConvertTo-Json -Depth 64))

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Invariant Trend History Analytics")
[void]$md.AppendLine()
[void]$md.AppendLine(("Generated (UTC): {0}" -f $analytics.generated_at_utc))
[void]$md.AppendLine()
[void]$md.AppendLine(("Entries: {0}" -f $analytics.entry_count))
[void]$md.AppendLine(("Latest Total Issues: {0}" -f $analytics.latest_total_issues))
[void]$md.AppendLine(("Delta From First: {0}" -f $analytics.delta_from_first))
[void]$md.AppendLine(("Global Slope: {0}" -f $analytics.global_slope))
[void]$md.AppendLine(("Increase Streak: {0}" -f $analytics.increase_streak))
[void]$md.AppendLine()
[void]$md.AppendLine("## Window Rollups")
[void]$md.AppendLine()
[void]$md.AppendLine("| Window | Samples | Avg Total | Min | Max | Latest | Slope |")
[void]$md.AppendLine("|---:|---:|---:|---:|---:|---:|---:|")
foreach ($row in $analytics.windows) {
    [void]$md.AppendLine((
        "| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f
        [int]$row.window,
        [int]$row.sample_count,
        [double]$row.avg_total_issues,
        [int]$row.min_total_issues,
        [int]$row.max_total_issues,
        [int]$row.latest_total_issues,
        [double]$row.slope
    ))
}
[void]$md.AppendLine()
[void]$md.AppendLine("## Alerts")
[void]$md.AppendLine()
if ($analytics.alerts.Count -eq 0) {
    [void]$md.AppendLine("- none")
}
else {
    foreach ($alert in $analytics.alerts) {
        [void]$md.AppendLine(("- [{0}] {1}: {2}" -f [string]$alert.severity, [string]$alert.code, [string]$alert.message))
    }
}
[void]$md.AppendLine()

$markdownFile = Join-Path $repoRoot $MarkdownPath
$markdownDir = Split-Path -Parent $markdownFile
if (-not [string]::IsNullOrWhiteSpace($markdownDir)) {
    New-Item -ItemType Directory -Path $markdownDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($markdownFile, $md.ToString())

Write-Host ("[invariant-trend-analytics] analytics written: {0}" -f $AnalyticsPath)
Write-Host ("[invariant-trend-analytics] markdown written: {0}" -f $MarkdownPath)
Write-Host ("[invariant-trend-analytics] entries={0} latest_total={1} slope={2}" -f $entryCount, $latestTotal, $globalSlope)
