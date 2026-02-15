param(
    [string]$ArtifactsDir = "demo-traces",
    [int]$MaxTotalMB = 64,
    [int]$KeepLatest = 120,
    [int]$MinKeep = 60,
    [string]$SummaryPath = "demo-traces/artifact-storage.summary.json",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($KeepLatest -lt 0) {
    throw "KeepLatest must be >= 0"
}
if ($MinKeep -lt 0) {
    throw "MinKeep must be >= 0"
}
if ($KeepLatest -lt $MinKeep) {
    throw "KeepLatest must be >= MinKeep"
}
if ($MaxTotalMB -lt 1) {
    throw "MaxTotalMB must be >= 1"
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

function Get-FileSetTotalBytes {
    param($Files)

    $sum = 0L
    foreach ($f in @($Files)) {
        $sum += [int64]$f.Length
    }
    return $sum
}

$artifactRoot = Join-Path $repoRoot $ArtifactsDir
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

$patterns = @(
    "*.trace.jsonl",
    "*.report.json",
    "*.scenario.json",
    "*.index.json",
    "invariant-trends.summary.json",
    "invariant-trends.summary.md",
    "invariant-trends.gate.json",
    "invariant-trends.policy.json",
    "invariant-trends.debt-windows.json",
    "invariant-trends.signals.json",
    "invariant-trends.notify.md",
    "invariant-trends.notify.payload.json",
    "artifact-storage.summary.json"
)

$protectedNames = @(
    "invariant-trends.summary.json",
    "invariant-trends.summary.md",
    "invariant-trends.gate.json",
    "invariant-trends.policy.json",
    "invariant-trends.debt-windows.json",
    "invariant-trends.signals.json",
    "invariant-trends.notify.md",
    "invariant-trends.notify.payload.json",
    "artifact-storage.summary.json"
)

$protectedNameSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $protectedNames) {
    $null = $protectedNameSet.Add($name)
}

$allFiles = @()
foreach ($pattern in $patterns) {
    $allFiles += @(Get-ChildItem -Path (Join-Path $artifactRoot $pattern) -File -ErrorAction SilentlyContinue)
}
$allFiles = @($allFiles | Sort-Object FullName -Unique)

$maxBytes = [int64]$MaxTotalMB * 1MB
$initialBytes = Get-FileSetTotalBytes -Files $allFiles

$sortedNewestFirst = @($allFiles | Sort-Object -Property LastWriteTimeUtc, Name -Descending)
$evictionCandidates = @()
for ($i = 0; $i -lt $sortedNewestFirst.Count; $i++) {
    $file = $sortedNewestFirst[$i]
    $isProtected = $protectedNameSet.Contains($file.Name)
    if ($isProtected) {
        continue
    }
    if ($i -lt $KeepLatest) {
        continue
    }
    $evictionCandidates += $file
}

$deleted = @()
$currentBytes = $initialBytes

foreach ($file in @($evictionCandidates | Sort-Object LastWriteTimeUtc, Name)) {
    if ($currentBytes -le $maxBytes) {
        break
    }

    $remainingCount = $allFiles.Count - $deleted.Count
    if ($remainingCount -le $MinKeep) {
        break
    }

    if (-not $DryRun) {
        Remove-Item $file.FullName -Force
    }
    $deleted += $file
    $currentBytes -= [int64]$file.Length
}

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    artifact_dir = Convert-ToRepoRelativePath -Path $artifactRoot -Root $repoRoot
    dry_run = [bool]$DryRun
    policy = @{
        max_total_mb = $MaxTotalMB
        max_total_bytes = $maxBytes
        keep_latest = $KeepLatest
        min_keep = $MinKeep
        patterns = $patterns
        protected_names = $protectedNames
    }
    before = @{
        file_count = $allFiles.Count
        total_bytes = $initialBytes
    }
    after = @{
        file_count = ($allFiles.Count - $deleted.Count)
        total_bytes = $currentBytes
        within_budget = ($currentBytes -le $maxBytes)
    }
    deleted = @{
        file_count = $deleted.Count
        total_bytes = (Get-FileSetTotalBytes -Files $deleted)
        files = @($deleted | ForEach-Object { Convert-ToRepoRelativePath -Path $_.FullName -Root $repoRoot })
    }
}

if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
    $summaryFilePath = Join-Path $repoRoot $SummaryPath
    $summaryDir = Split-Path -Parent $summaryFilePath
    if (-not [string]::IsNullOrWhiteSpace($summaryDir)) {
        New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($summaryFilePath, ($summary | ConvertTo-Json -Depth 16))
}

$beforeMB = [math]::Round(($initialBytes / 1MB), 2)
$afterMB = [math]::Round(($currentBytes / 1MB), 2)
$freedMB = [math]::Round((((Get-FileSetTotalBytes -Files $deleted)) / 1MB), 2)

Write-Host ("[artifact-storage-guard] files={0}->{1} size_mb={2}->{3} freed_mb={4}" -f `
        $summary.before.file_count, $summary.after.file_count, $beforeMB, $afterMB, $freedMB)

if (-not $summary.after.within_budget) {
    Write-Warning ("[artifact-storage-guard] budget still exceeded after pruning (limit_mb={0})" -f $MaxTotalMB)
}
