param(
    [string]$SignalsPath = "demo-traces/invariant-trends.signals.json",
    [string]$SummaryPath = "demo-traces/invariant-trends.summary.json",
    [string]$MarkdownPath = "demo-traces/invariant-trends.notify.md",
    [string]$PayloadPath = "demo-traces/invariant-trends.notify.payload.json",
    [string]$WebhookUrl = "",
    [ValidateSet("info", "warn", "error")]
    [string]$MinSeverity = "warn",
    [int]$MaxSignals = 12,
    [int]$TimeoutSec = 15,
    [switch]$AppendGitHubStepSummary,
    [switch]$FailOnDeliveryError,
    [switch]$ForceNotify,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($MaxSignals -lt 1) {
    throw "MaxSignals must be >= 1"
}
if ($TimeoutSec -lt 1) {
    throw "TimeoutSec must be >= 1"
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

function Read-Json {
    param(
        [string]$Path,
        [switch]$Required
    )

    if (-not (Test-Path $Path)) {
        if ($Required) {
            throw ("Required JSON file not found: {0}" -f $Path)
        }
        return $null
    }
    return (Get-Content $Path -Raw | ConvertFrom-Json -Depth 64)
}

$severityRank = @{
    info = 0
    warn = 1
    error = 2
}

$signals = Read-Json -Path $SignalsPath -Required
$summary = Read-Json -Path $SummaryPath

$repoName = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) { $env:GITHUB_REPOSITORY } else { [System.IO.Path]::GetFileName($repoRoot) }
$branchName = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) { $env:GITHUB_REF_NAME } else { (Get-GitOutputOrEmpty -GitArgs @("rev-parse", "--abbrev-ref", "HEAD")) }
$commitSha = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) { $env:GITHUB_SHA } else { (Get-GitOutputOrEmpty -GitArgs @("rev-parse", "HEAD")) }
$runId = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { $env:GITHUB_RUN_ID } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString() }
$runAttempt = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ATTEMPT)) { $env:GITHUB_RUN_ATTEMPT } else { "1" }
$runSource = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)) { "github-actions" } else { "local" }

if ([string]::IsNullOrWhiteSpace($branchName)) {
    $branchName = "unknown"
}
if ([string]::IsNullOrWhiteSpace($commitSha)) {
    $commitSha = "unknown"
}

$counts = [ordered]@{
    total = (Get-SafeInt -Value $signals.counts.total)
    error = (Get-SafeInt -Value $signals.counts.error)
    warn = (Get-SafeInt -Value $signals.counts.warn)
    info = (Get-SafeInt -Value $signals.counts.info)
}

$allSignals = @($signals.signals)
$allSignals = @(
    $allSignals | Sort-Object `
        -Property @{ Expression = { $sev = [string]$_.severity; if ($severityRank.ContainsKey($sev)) { [int]$severityRank[$sev] } else { -1 } }; Descending = $true }, `
        @{ Expression = { [string]$_.code }; Descending = $false }
)

$thresholdRank = [int]$severityRank[$MinSeverity]
$notifiableSignals = @(
    $allSignals | Where-Object {
        $sev = [string]$_.severity
        $rank = if ($severityRank.ContainsKey($sev)) { [int]$severityRank[$sev] } else { -1 }
        $rank -ge $thresholdRank
    }
)
$topSignals = @($notifiableSignals | Select-Object -First $MaxSignals)

$shouldNotify = $ForceNotify.IsPresent -or ($notifiableSignals.Count -gt 0)
$status = [string]$signals.status
if ([string]::IsNullOrWhiteSpace($status)) {
    $status = "unknown"
}

$summaryTotals = [ordered]@{
    total = 0
    local_verify = 0
    cluster_verify = 0
}
$matrixSummary = [ordered]@{
    matrix_count = 0
    failed_matrices = @()
}
if ($null -ne $summary) {
    $summaryTotals.total = Get-SafeInt -Value $summary.global.issue_counts.total
    $summaryTotals.local_verify = Get-SafeInt -Value $summary.global.issue_counts.local_verify
    $summaryTotals.cluster_verify = Get-SafeInt -Value $summary.global.issue_counts.cluster_verify
    $matrixSummary.matrix_count = Get-SafeInt -Value $summary.matrix_count
    $matrixSummary.failed_matrices = @(
        @($summary.matrices | Where-Object { (Get-SafeInt -Value $_.failed_count) -gt 0 }) |
            ForEach-Object { [string]$_.matrix }
    )
}

$shortSha = $commitSha
if ($shortSha.Length -gt 12) {
    $shortSha = $shortSha.Substring(0, 12)
}

$statusLine = ("[{0}] invariant trend signals: error={1} warn={2} info={3}" -f $status, $counts.error, $counts.warn, $counts.info)

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Invariant Trend Notification")
[void]$md.AppendLine()
[void]$md.AppendLine($statusLine)
[void]$md.AppendLine()
[void]$md.AppendLine(("Repository: {0}" -f $repoName))
[void]$md.AppendLine(("Branch: {0}" -f $branchName))
[void]$md.AppendLine(("Commit: {0}" -f $shortSha))
[void]$md.AppendLine(("Run: {0} (attempt {1})" -f $runId, $runAttempt))
[void]$md.AppendLine()
[void]$md.AppendLine(("Signals status: {0}" -f $status))
[void]$md.AppendLine(("Counts: total={0} error={1} warn={2} info={3}" -f $counts.total, $counts.error, $counts.warn, $counts.info))
[void]$md.AppendLine(("Notify threshold: {0} | should_notify={1} | dry_run={2}" -f $MinSeverity, $shouldNotify, [bool]$DryRun))
[void]$md.AppendLine()
[void]$md.AppendLine("Trend totals from summary:")
[void]$md.AppendLine(("- total={0} local={1} cluster={2}" -f $summaryTotals.total, $summaryTotals.local_verify, $summaryTotals.cluster_verify))
if (@($matrixSummary.failed_matrices).Count -gt 0) {
    [void]$md.AppendLine(("- failed matrices: {0}" -f ((@($matrixSummary.failed_matrices) -join ", "))))
}
[void]$md.AppendLine()
[void]$md.AppendLine("Top notifiable signals:")
if ($topSignals.Count -eq 0) {
    [void]$md.AppendLine("- none")
}
else {
    foreach ($signal in $topSignals) {
        [void]$md.AppendLine(("- [{0}] {1}: {2}" -f [string]$signal.severity, [string]$signal.code, [string]$signal.message))
    }
}
[void]$md.AppendLine()

$context = [ordered]@{
    source = $runSource
    repository = $repoName
    branch = $branchName
    commit_sha = $commitSha
    run_id = $runId
    run_attempt = $runAttempt
}

$payload = [ordered]@{
    schema = "uco.invariant_trend_notification.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    context = $context
    status = $status
    min_severity = $MinSeverity
    should_notify = [bool]$shouldNotify
    dry_run = [bool]$DryRun
    counts = $counts
    trend_totals = $summaryTotals
    failed_matrices = @($matrixSummary.failed_matrices)
    source_paths = @{
        signals = $SignalsPath
        summary = $SummaryPath
    }
    top_signals = @($topSignals)
    text = $statusLine
    markdown = $md.ToString()
}

$markdownFile = Join-Path $repoRoot $MarkdownPath
$markdownDir = Split-Path -Parent $markdownFile
if (-not [string]::IsNullOrWhiteSpace($markdownDir)) {
    New-Item -ItemType Directory -Path $markdownDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($markdownFile, $md.ToString())

$payloadFile = Join-Path $repoRoot $PayloadPath
$payloadDir = Split-Path -Parent $payloadFile
if (-not [string]::IsNullOrWhiteSpace($payloadDir)) {
    New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($payloadFile, ($payload | ConvertTo-Json -Depth 64))

Write-Host ("[invariant-trend-notify] markdown written: {0}" -f $MarkdownPath)
Write-Host ("[invariant-trend-notify] payload written: {0}" -f $PayloadPath)

if ($AppendGitHubStepSummary -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $md.ToString()
    Write-Host "[invariant-trend-notify] appended notification summary to GITHUB_STEP_SUMMARY"
}

$resolvedWebhook = $WebhookUrl
if ([string]::IsNullOrWhiteSpace($resolvedWebhook) -and -not [string]::IsNullOrWhiteSpace($env:INVARIANT_TREND_WEBHOOK_URL)) {
    $resolvedWebhook = $env:INVARIANT_TREND_WEBHOOK_URL
}

$delivered = $false
$deliveryError = ""

if (-not $shouldNotify) {
    Write-Host ("[invariant-trend-notify] no signals at or above threshold {0}; webhook dispatch skipped" -f $MinSeverity)
}
elseif ([string]::IsNullOrWhiteSpace($resolvedWebhook)) {
    Write-Host "[invariant-trend-notify] webhook URL not configured; payload generated only"
}
elseif ($DryRun) {
    Write-Host ("[invariant-trend-notify] dry-run enabled; webhook dispatch skipped (would notify {0})" -f $resolvedWebhook)
}
else {
    try {
        $body = $payload | ConvertTo-Json -Depth 64
        Invoke-RestMethod -Uri $resolvedWebhook -Method Post -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec | Out-Null
        $delivered = $true
        Write-Host "[invariant-trend-notify] webhook notification delivered"
    }
    catch {
        $deliveryError = [string]$_.Exception.Message
        Write-Warning ("[invariant-trend-notify] webhook delivery failed: {0}" -f $deliveryError)
        if ($FailOnDeliveryError) {
            throw ("Invariant trend notification delivery failed: {0}" -f $deliveryError)
        }
    }
}

Write-Host ("[invariant-trend-notify] status={0} should_notify={1} delivered={2} threshold={3}" -f `
        $status, $shouldNotify, $delivered, $MinSeverity)
