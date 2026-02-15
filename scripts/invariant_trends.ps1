param(
    [string[]]$IndexPaths = @(
        "demo-traces/cluster-fault-matrix.index.json",
        "demo-traces/cluster3-fault-matrix.index.json",
        "demo-traces/cluster3-multi-fault-matrix.index.json",
        "demo-traces/cluster3-envelope-fault-matrix.index.json",
        "demo-traces/cluster3-choreography-fault-matrix.index.json"
    ),
    [string]$SummaryPath = "demo-traces/invariant-trends.summary.json",
    [string]$MarkdownPath = "demo-traces/invariant-trends.summary.md",
    [string]$PreviousSummaryPath = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function New-IssueBucket {
    return @{}
}

function Convert-ToCountMap {
    param($Obj)

    $map = @{}
    if ($null -eq $Obj) {
        return $map
    }

    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($entry in $Obj.GetEnumerator()) {
            $name = [string]$entry.Key
            $value = 0
            if ($null -ne $entry.Value) {
                $value = [int]$entry.Value
            }
            $map[$name] = $value
        }
        return $map
    }

    foreach ($prop in $Obj.PSObject.Properties) {
        $name = [string]$prop.Name
        $value = 0
        if ($null -ne $prop.Value) {
            $value = [int]$prop.Value
        }
        $map[$name] = $value
    }

    return $map
}

function Merge-IssueBucket {
    param(
        [hashtable]$Into,
        $From
    )

    $fromMap = Convert-ToCountMap -Obj $From
    foreach ($key in $fromMap.Keys) {
        if (-not $Into.ContainsKey($key)) {
            $Into[$key] = 0
        }
        $Into[$key] += [int]$fromMap[$key]
    }
}

function Get-IssueBucketTotal {
    param($Bucket)

    $total = 0
    $map = Convert-ToCountMap -Obj $Bucket
    foreach ($value in $map.Values) {
        $total += [int]$value
    }
    return $total
}

function Convert-BucketToRows {
    param($Bucket)

    $map = Convert-ToCountMap -Obj $Bucket
    $total = Get-IssueBucketTotal -Bucket $map
    $rows = @()
    foreach ($code in @($map.Keys | Sort-Object)) {
        $count = [int]$map[$code]
        $share = if ($total -gt 0) { [Math]::Round((100.0 * $count) / $total, 2) } else { 0.0 }
        $rows += [ordered]@{
            code = $code
            count = $count
            share_percent = $share
        }
    }

    return @{
        total = $total
        rows = $rows
    }
}

function Convert-BucketDeltaToRows {
    param(
        $CurrentBucket,
        $PreviousBucket
    )

    $current = Convert-ToCountMap -Obj $CurrentBucket
    $previous = Convert-ToCountMap -Obj $PreviousBucket
    $allCodes = @()
    $allCodes += @($current.Keys)
    $allCodes += @($previous.Keys)
    $allCodes = @(
        $allCodes |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )

    $rows = @()
    foreach ($code in $allCodes) {
        $curr = if ($current.ContainsKey($code)) { [int]$current[$code] } else { 0 }
        $prev = if ($previous.ContainsKey($code)) { [int]$previous[$code] } else { 0 }
        $delta = $curr - $prev
        $rows += [ordered]@{
            code = $code
            current = $curr
            previous = $prev
            delta = $delta
        }
    }
    return $rows
}

function Convert-GlobalTopInvariants {
    param(
        $LocalBucket,
        $ClusterBucket
    )

    $local = Convert-ToCountMap -Obj $LocalBucket
    $cluster = Convert-ToCountMap -Obj $ClusterBucket
    $grandTotal = (Get-IssueBucketTotal -Bucket $local) + (Get-IssueBucketTotal -Bucket $cluster)
    $rows = @()

    foreach ($code in @($local.Keys | Sort-Object)) {
        $count = [int]$local[$code]
        $share = if ($grandTotal -gt 0) { [Math]::Round((100.0 * $count) / $grandTotal, 2) } else { 0.0 }
        $rows += [ordered]@{
            kind = "local_verify"
            code = $code
            count = $count
            share_percent = $share
        }
    }
    foreach ($code in @($cluster.Keys | Sort-Object)) {
        $count = [int]$cluster[$code]
        $share = if ($grandTotal -gt 0) { [Math]::Round((100.0 * $count) / $grandTotal, 2) } else { 0.0 }
        $rows += [ordered]@{
            kind = "cluster_verify"
            code = $code
            count = $count
            share_percent = $share
        }
    }

    if ($rows.Count -eq 0) {
        return @()
    }
    return @(
        $rows | Sort-Object -Property @{ Expression = "count"; Descending = $true }, @{ Expression = "kind"; Descending = $false }, @{ Expression = "code"; Descending = $false }
    )
}

function Convert-GlobalDeltaTopInvariants {
    param(
        $LocalDeltaRows,
        $ClusterDeltaRows
    )

    $rows = @()
    foreach ($row in @($LocalDeltaRows)) {
        if ($null -eq $row) {
            continue
        }
        $code = [string]$row.code
        if ([string]::IsNullOrWhiteSpace($code)) {
            continue
        }
        $rows += [ordered]@{
            kind = "local_verify"
            code = $code
            current = [int]$row.current
            previous = [int]$row.previous
            delta = [int]$row.delta
        }
    }
    foreach ($row in @($ClusterDeltaRows)) {
        if ($null -eq $row) {
            continue
        }
        $code = [string]$row.code
        if ([string]::IsNullOrWhiteSpace($code)) {
            continue
        }
        $rows += [ordered]@{
            kind = "cluster_verify"
            code = $code
            current = [int]$row.current
            previous = [int]$row.previous
            delta = [int]$row.delta
        }
    }

    if ($rows.Count -eq 0) {
        return @()
    }
    return @(
        $rows | Sort-Object -Property @{ Expression = { [Math]::Abs([int]$_.delta) }; Descending = $true }, @{ Expression = "kind"; Descending = $false }, @{ Expression = "code"; Descending = $false }
    )
}

$matrixSummaries = @()
$missingIndexes = @()
$globalLocalBucket = New-IssueBucket
$globalClusterBucket = New-IssueBucket

foreach ($indexPath in $IndexPaths) {
    if (-not (Test-Path $indexPath)) {
        $missingIndexes += $indexPath
        continue
    }

    $index = Get-Content $indexPath -Raw | ConvertFrom-Json -Depth 64
    $matrixName = [string]$index.matrix
    if ([string]::IsNullOrWhiteSpace($matrixName)) {
        $matrixName = [System.IO.Path]::GetFileNameWithoutExtension([string]$indexPath)
    }

    $localBucket = Convert-ToCountMap -Obj $index.aggregate.invariant_buckets.local_verify
    $clusterBucket = Convert-ToCountMap -Obj $index.aggregate.invariant_buckets.cluster_verify
    Merge-IssueBucket -Into $globalLocalBucket -From $localBucket
    Merge-IssueBucket -Into $globalClusterBucket -From $clusterBucket

    $localRows = Convert-BucketToRows -Bucket $localBucket
    $clusterRows = Convert-BucketToRows -Bucket $clusterBucket
    $localIssueCount = [int]$index.aggregate.issue_counts.local_verify
    $clusterIssueCount = [int]$index.aggregate.issue_counts.cluster_verify
    $issueTotal = $localIssueCount + $clusterIssueCount
    $failedCount = [int]$index.failed_count
    $health = if ($failedCount -gt 0) { "failed" } elseif ($issueTotal -gt 0) { "pass_with_issues" } else { "pass_clean" }

    $matrixSummaries += [ordered]@{
        matrix = $matrixName
        index_path = $indexPath
        scenario_count = [int]$index.scenario_count
        passed_count = [int]$index.passed_count
        failed_count = $failedCount
        health = $health
        issue_counts = @{
            local_verify = $localIssueCount
            cluster_verify = $clusterIssueCount
            total = $issueTotal
        }
        by_code = @{
            local_verify = $localRows.rows
            cluster_verify = $clusterRows.rows
        }
    }
}

$globalLocalRows = Convert-BucketToRows -Bucket $globalLocalBucket
$globalClusterRows = Convert-BucketToRows -Bucket $globalClusterBucket
$globalTopRows = @(Convert-GlobalTopInvariants -LocalBucket $globalLocalBucket -ClusterBucket $globalClusterBucket)

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_indexes = @($matrixSummaries | ForEach-Object { [string]$_.index_path })
    missing_indexes = $missingIndexes
    matrix_count = $matrixSummaries.Count
    matrices = $matrixSummaries
    global = @{
        issue_counts = @{
            local_verify = $globalLocalRows.total
            cluster_verify = $globalClusterRows.total
            total = $globalLocalRows.total + $globalClusterRows.total
        }
        invariant_buckets = @{
            local_verify = $globalLocalBucket
            cluster_verify = $globalClusterBucket
        }
        by_code = @{
            local_verify = @($globalLocalRows.rows)
            cluster_verify = @($globalClusterRows.rows)
        }
        top_invariants = @($globalTopRows)
    }
}

if (-not [string]::IsNullOrWhiteSpace($PreviousSummaryPath) -and (Test-Path $PreviousSummaryPath)) {
    $previous = Get-Content $PreviousSummaryPath -Raw | ConvertFrom-Json -Depth 64

    $prevLocalBucket = if ($null -ne $previous.global -and $null -ne $previous.global.invariant_buckets) {
        $previous.global.invariant_buckets.local_verify
    }
    else {
        @{}
    }
    $prevClusterBucket = if ($null -ne $previous.global -and $null -ne $previous.global.invariant_buckets) {
        $previous.global.invariant_buckets.cluster_verify
    }
    else {
        @{}
    }

    $localDeltaRows = @(Convert-BucketDeltaToRows -CurrentBucket $globalLocalBucket -PreviousBucket $prevLocalBucket)
    $clusterDeltaRows = @(Convert-BucketDeltaToRows -CurrentBucket $globalClusterBucket -PreviousBucket $prevClusterBucket)
    $topDeltaRows = @(Convert-GlobalDeltaTopInvariants -LocalDeltaRows $localDeltaRows -ClusterDeltaRows $clusterDeltaRows)

    $summary.previous_summary_path = $PreviousSummaryPath
    $summary.global.delta_from_previous = @{
        by_code = @{
            local_verify = @($localDeltaRows)
            cluster_verify = @($clusterDeltaRows)
        }
        top_deltas = @($topDeltaRows)
    }
}

$summaryJson = $summary | ConvertTo-Json -Depth 64
New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName((Join-Path $repoRoot $SummaryPath))) -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $repoRoot $SummaryPath), $summaryJson)

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Invariant Trend Summary")
[void]$md.AppendLine()
[void]$md.AppendLine(("Generated (UTC): {0}" -f $summary.generated_at_utc))
[void]$md.AppendLine()

if ($missingIndexes.Count -gt 0) {
    [void]$md.AppendLine("Missing indexes:")
    foreach ($path in $missingIndexes) {
        [void]$md.AppendLine(("- {0}" -f $path))
    }
    [void]$md.AppendLine()
}

[void]$md.AppendLine("## Matrix Health")
[void]$md.AppendLine()
[void]$md.AppendLine("| Matrix | Scenarios | Failed | Local Issues | Cluster Issues | Health |")
[void]$md.AppendLine("|---|---:|---:|---:|---:|---|")
foreach ($m in @($matrixSummaries | Sort-Object -Property matrix)) {
    [void]$md.AppendLine((
        "| {0} | {1} | {2} | {3} | {4} | {5} |" -f
        $m.matrix,
        $m.scenario_count,
        $m.failed_count,
        $m.issue_counts.local_verify,
        $m.issue_counts.cluster_verify,
        $m.health
    ))
}
[void]$md.AppendLine()

[void]$md.AppendLine("## Global Invariant Totals")
[void]$md.AppendLine()
[void]$md.AppendLine(("- Local verify issues: {0}" -f $summary.global.issue_counts.local_verify))
[void]$md.AppendLine(("- Cluster verify issues: {0}" -f $summary.global.issue_counts.cluster_verify))
[void]$md.AppendLine(("- Total issues: {0}" -f $summary.global.issue_counts.total))
[void]$md.AppendLine()

[void]$md.AppendLine("### Top Invariants")
[void]$md.AppendLine()
[void]$md.AppendLine("| Kind | Code | Count | Share % |")
[void]$md.AppendLine("|---|---|---:|---:|")
foreach ($row in @($summary.global.top_invariants | Select-Object -First 20)) {
    [void]$md.AppendLine((
        "| {0} | {1} | {2} | {3} |" -f
        [string]$row.kind,
        [string]$row.code,
        [int]$row.count,
        [double]$row.share_percent
    ))
}
[void]$md.AppendLine()

if ($null -ne $summary.global.delta_from_previous) {
    [void]$md.AppendLine(("## Delta From Previous ({0})" -f [string]$summary.previous_summary_path))
    [void]$md.AppendLine()
    [void]$md.AppendLine("| Kind | Code | Previous | Current | Delta |")
    [void]$md.AppendLine("|---|---|---:|---:|---:|")
    foreach ($row in @($summary.global.delta_from_previous.top_deltas | Select-Object -First 20)) {
        [void]$md.AppendLine((
            "| {0} | {1} | {2} | {3} | {4} |" -f
            [string]$row.kind,
            [string]$row.code,
            [int]$row.previous,
            [int]$row.current,
            [int]$row.delta
        ))
    }
    [void]$md.AppendLine()
}

New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName((Join-Path $repoRoot $MarkdownPath))) -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $repoRoot $MarkdownPath), $md.ToString())

Write-Host ("[invariant-trends] summary written: {0}" -f $SummaryPath)
Write-Host ("[invariant-trends] markdown written: {0}" -f $MarkdownPath)
Write-Host ("[invariant-trends] matrices loaded: {0}" -f $matrixSummaries.Count)
if ($missingIndexes.Count -gt 0) {
    Write-Host ("[invariant-trends] missing indexes: {0}" -f ($missingIndexes -join ", "))
}
Write-Host ("[invariant-trends] global issue totals: local={0} cluster={1} total={2}" -f `
        $summary.global.issue_counts.local_verify, `
        $summary.global.issue_counts.cluster_verify, `
        $summary.global.issue_counts.total)
