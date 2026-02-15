param(
    [string]$SummaryPath = "demo-traces/invariant-trends.summary.json",
    [string]$HistoryDir = "demo-traces/invariant-history",
    [string]$IndexPath = "demo-traces/invariant-history/index.json",
    [int]$MaxEntries = 120,
    [string]$RunSource = "",
    [string]$BranchName = "",
    [string]$CommitSha = "",
    [string]$RunId = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($MaxEntries -lt 1) {
    throw "MaxEntries must be >= 1"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Convert-ToRepoRelativePath {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $trimmed = $fullPath.Substring($fullRoot.Length).TrimStart("\", "/")
        return $trimmed.Replace("\", "/")
    }
    return $fullPath
}

function Sanitize-Token {
    param(
        [string]$Value,
        [string]$Fallback = "unknown"
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Fallback
    }
    $safe = [System.Text.RegularExpressions.Regex]::Replace($Value, "[^A-Za-z0-9._-]", "-")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return $Fallback
    }
    return $safe
}

function Get-GitOutputOrEmpty {
    param([string[]]$GitArgs)

    try {
        $result = & git @GitArgs 2>$null
        if ($LASTEXITCODE -eq 0) {
            return ([string]$result).Trim()
        }
    }
    catch {
        # ignore
    }
    return ""
}

if (-not (Test-Path $SummaryPath)) {
    throw ("Trend summary not found: {0}" -f $SummaryPath)
}

$summary = Get-Content $SummaryPath -Raw | ConvertFrom-Json -Depth 64

if ([string]::IsNullOrWhiteSpace($RunSource)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)) {
        $RunSource = "github-actions"
    }
    else {
        $RunSource = "local"
    }
}
if ([string]::IsNullOrWhiteSpace($BranchName)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) {
        $BranchName = $env:GITHUB_REF_NAME
    }
    else {
        $BranchName = Get-GitOutputOrEmpty -GitArgs @("rev-parse", "--abbrev-ref", "HEAD")
    }
}
if ([string]::IsNullOrWhiteSpace($CommitSha)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
        $CommitSha = $env:GITHUB_SHA
    }
    else {
        $CommitSha = Get-GitOutputOrEmpty -GitArgs @("rev-parse", "HEAD")
    }
}
if ([string]::IsNullOrWhiteSpace($RunId)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
        $RunId = $env:GITHUB_RUN_ID
    }
    else {
        $RunId = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
    }
}
if ([string]::IsNullOrWhiteSpace($BranchName)) {
    $BranchName = "unknown"
}
if ([string]::IsNullOrWhiteSpace($CommitSha)) {
    $CommitSha = "unknown"
}

$branchToken = Sanitize-Token -Value $BranchName -Fallback "unknown-branch"
$commitToken = Sanitize-Token -Value $CommitSha -Fallback "unknown-sha"
if ($commitToken.Length -gt 12) {
    $commitToken = $commitToken.Substring(0, 12)
}
$runToken = Sanitize-Token -Value $RunId -Fallback "run"

$timestampUtc = Get-Date
if (-not [string]::IsNullOrWhiteSpace([string]$summary.generated_at_utc)) {
    try {
        $timestampUtc = [DateTime]::Parse([string]$summary.generated_at_utc).ToUniversalTime()
    }
    catch {
        $timestampUtc = (Get-Date).ToUniversalTime()
    }
}
else {
    $timestampUtc = (Get-Date).ToUniversalTime()
}

$timestampToken = $timestampUtc.ToString("yyyyMMddTHHmmssZ")
$historyDirPath = Join-Path $repoRoot $HistoryDir
New-Item -ItemType Directory -Path $historyDirPath -Force | Out-Null

$snapshotName = ("invariant-trends-{0}-{1}-{2}-{3}.json" -f $timestampToken, $branchToken, $commitToken, $runToken)
$snapshotPath = Join-Path $historyDirPath $snapshotName
[System.IO.File]::WriteAllText($snapshotPath, ($summary | ConvertTo-Json -Depth 64))

$indexFilePath = Join-Path $repoRoot $IndexPath
$indexDirPath = Split-Path -Parent $indexFilePath
if (-not [string]::IsNullOrWhiteSpace($indexDirPath)) {
    New-Item -ItemType Directory -Path $indexDirPath -Force | Out-Null
}

$existingEntries = @()
if (Test-Path $indexFilePath) {
    $existingIndex = Get-Content $indexFilePath -Raw | ConvertFrom-Json -Depth 64
    $existingEntries = @($existingIndex.entries)
}

$snapshotRelative = Convert-ToRepoRelativePath -Path $snapshotPath -Root $repoRoot
$summaryRelative = Convert-ToRepoRelativePath -Path (Join-Path $repoRoot $SummaryPath) -Root $repoRoot

$entry = [ordered]@{
    generated_at_utc = $timestampUtc.ToString("o")
    snapshot_path = $snapshotRelative
    source_summary_path = $summaryRelative
    source = $RunSource
    branch = $BranchName
    commit_sha = $CommitSha
    run_id = $RunId
    matrix_count = [int]$summary.matrix_count
    issue_counts = @{
        local_verify = [int]$summary.global.issue_counts.local_verify
        cluster_verify = [int]$summary.global.issue_counts.cluster_verify
        total = [int]$summary.global.issue_counts.total
    }
}

$merged = @()
foreach ($e in $existingEntries) {
    if ($null -eq $e) {
        continue
    }
    if ([string]$e.snapshot_path -eq $snapshotRelative) {
        continue
    }
    $merged += $e
}
$merged += $entry

$sortedEntries = @(
    $merged | Sort-Object -Property `
        @{ Expression = { [DateTime]::Parse([string]$_.generated_at_utc) }; Descending = $true }, `
        @{ Expression = { [string]$_.run_id }; Descending = $true }
)

$trimmedEntries = @($sortedEntries | Select-Object -First $MaxEntries)
$deletedEntries = @($sortedEntries | Select-Object -Skip $MaxEntries)

foreach ($old in $deletedEntries) {
    $oldPath = [string]$old.snapshot_path
    if ([string]::IsNullOrWhiteSpace($oldPath)) {
        continue
    }
    $oldFullPath = Join-Path $repoRoot $oldPath
    if (Test-Path $oldFullPath) {
        Remove-Item $oldFullPath -Force
    }
}

$index = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    history_dir = Convert-ToRepoRelativePath -Path $historyDirPath -Root $repoRoot
    max_entries = $MaxEntries
    entry_count = $trimmedEntries.Count
    latest_snapshot = if ($trimmedEntries.Count -gt 0) { $trimmedEntries[0].snapshot_path } else { "" }
    entries = $trimmedEntries
}

[System.IO.File]::WriteAllText($indexFilePath, ($index | ConvertTo-Json -Depth 64))

Write-Host ("[invariant-trend-history] snapshot written: {0}" -f $snapshotRelative)
Write-Host ("[invariant-trend-history] index written: {0}" -f (Convert-ToRepoRelativePath -Path $indexFilePath -Root $repoRoot))
Write-Host ("[invariant-trend-history] entries={0} max_entries={1} pruned={2}" -f $trimmedEntries.Count, $MaxEntries, $deletedEntries.Count)
