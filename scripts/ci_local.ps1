param(
    [switch]$SkipFaultMatrix,
    [switch]$SkipClusterScenario,
    [switch]$SkipCluster3Scenario,
    [switch]$SkipClusterFaultScenario,
    [switch]$SkipClusterFaultMatrix,
    [switch]$SkipCluster3FaultMatrix,
    [switch]$SkipCluster3MultiFaultMatrix,
    [switch]$SkipCluster3EnvelopeFaultMatrix,
    [switch]$SkipCluster3ChoreographyFaultMatrix,
    [switch]$SkipInvariantTrends,
    [switch]$SkipInvariantTrendGate,
    [switch]$SkipInvariantTrendPolicy,
    [switch]$SkipInvariantTrendPolicyLint,
    [switch]$SkipInvariantTrendDebtWindows,
    [switch]$SkipInvariantTrendHistory,
    [switch]$SkipInvariantTrendAnalytics,
    [switch]$SkipInvariantTrendSignals,
    [switch]$SkipInvariantTrendNotify,
    [switch]$SkipArtifactStorageGuard,
    [switch]$SkipLean,
    [string]$TrendPolicyProfile = "",
    [string]$TrendPolicyFile = "configs/invariant-trend-policies.json",
    [ValidateSet("info", "warn", "error")]
    [string]$TrendNotifyMinSeverity = "warn",
    [string]$TrendNotifyWebhookUrl = "",
    [switch]$FailOnTrendNotifyDelivery
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$env:CARGO_INCREMENTAL = "0"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

Write-Host "[1/21] cargo fmt --check"
cargo fmt --all -- --check | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "cargo fmt --check failed"
}

Write-Host "[2/21] cargo check"
cargo check --workspace --all-targets --locked | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "cargo check failed"
}

Write-Host "[3/21] cargo test"
cargo test --workspace --locked | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "cargo test failed"
}

if (-not $SkipFaultMatrix) {
    Write-Host "[4/21] fault matrix"
    pwsh -File scripts/fault_matrix.ps1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "fault matrix failed"
    }
}
else {
    Write-Host "[4/21] fault matrix skipped"
}

if (-not $SkipClusterScenario) {
    Write-Host "[5/21] cluster scenario"
    pwsh -File scripts/cluster_scenario.ps1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "cluster scenario failed"
    }
}
else {
    Write-Host "[5/21] cluster scenario skipped"
}

if (-not $SkipCluster3Scenario) {
    Write-Host "[6/21] cluster3 scenario"
    pwsh -File scripts/cluster3_scenario.ps1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "cluster3 scenario failed"
    }
}
else {
    Write-Host "[6/21] cluster3 scenario skipped"
}

if (-not $SkipClusterFaultScenario -and -not $SkipClusterFaultMatrix) {
    Write-Host "[7/21] cluster fault matrix"
    pwsh -File scripts/cluster_fault_matrix.ps1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "cluster fault matrix failed"
    }
}
else {
    Write-Host "[7/21] cluster fault matrix skipped"
}

if (-not $SkipCluster3FaultMatrix) {
    Write-Host "[8/21] cluster3 fault matrix"
    pwsh -File scripts/cluster3_fault_matrix.ps1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "cluster3 fault matrix failed"
    }
}
else {
    Write-Host "[8/21] cluster3 fault matrix skipped"
}

if (-not $SkipCluster3MultiFaultMatrix) {
    Write-Host "[9/21] cluster3 multi-target fault matrix"
    pwsh -File scripts/cluster3_multi_fault_matrix.ps1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "cluster3 multi-target fault matrix failed"
    }
}
else {
    Write-Host "[9/21] cluster3 multi-target fault matrix skipped"
}

if (-not $SkipCluster3EnvelopeFaultMatrix) {
    Write-Host "[10/21] cluster3 partition/churn envelope matrix"
    pwsh -File scripts/cluster3_envelope_matrix.ps1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "cluster3 envelope matrix failed"
    }
}
else {
    Write-Host "[10/21] cluster3 partition/churn envelope matrix skipped"
}

if (-not $SkipCluster3ChoreographyFaultMatrix) {
    Write-Host "[11/21] cluster3 phased choreography matrix"
    pwsh -File scripts/cluster3_choreography_matrix.ps1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "cluster3 choreography matrix failed"
    }
}
else {
    Write-Host "[11/21] cluster3 phased choreography matrix skipped"
}

if (-not $SkipInvariantTrends) {
    Write-Host "[12/21] invariant trend summary"
    pwsh -File scripts/invariant_trends.ps1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "invariant trend summary failed"
    }
}
else {
    Write-Host "[12/21] invariant trend summary skipped"
}

if (-not $SkipInvariantTrendPolicyLint) {
    Write-Host "[13/21] invariant trend policy lint"
    pwsh -File scripts/invariant_trend_policy_lint.ps1 `
        -PolicyFilePath $TrendPolicyFile `
        -ReportPath demo-traces/invariant-trends.policy-lint.json | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "invariant trend policy lint failed"
    }
}
else {
    Write-Host "[13/21] invariant trend policy lint skipped"
}

$branchName = ""
try {
    $branchName = (& git rev-parse --abbrev-ref HEAD 2>$null).Trim()
}
catch {
    $branchName = ""
}

if (-not $SkipInvariantTrendPolicy -and -not $SkipInvariantTrendGate -and -not $SkipInvariantTrends) {
    $policyArgs = @{
        SummaryPath = "demo-traces/invariant-trends.summary.json"
        PolicyFilePath = $TrendPolicyFile
        BranchName = $branchName
        RunSource = "local"
        GateReportPath = "demo-traces/invariant-trends.gate.json"
        PolicyReportPath = "demo-traces/invariant-trends.policy.json"
    }
    if (-not [string]::IsNullOrWhiteSpace($TrendPolicyProfile)) {
        $policyArgs["Profile"] = $TrendPolicyProfile
    }
    $profileLabel = if ($policyArgs.ContainsKey("Profile")) { [string]$policyArgs["Profile"] } else { "auto" }
    Write-Host "[14/21] invariant trend policy gate (profile=$profileLabel)"
    pwsh -File scripts/invariant_trend_policy.ps1 @policyArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "invariant trend policy gate failed"
    }
}
else {
    Write-Host "[14/21] invariant trend policy gate skipped"
}

if (-not $SkipInvariantTrendDebtWindows) {
    Write-Host "[15/21] invariant trend debt-window guard"
    $debtWindowArgs = @{
        PolicyFilePath = $TrendPolicyFile
        ReportPath = "demo-traces/invariant-trends.debt-windows.json"
        WarnDays = 14
        FailDays = 7
    }
    $failOnExpiringSoon = $false
    if (Test-Path "demo-traces/invariant-trends.policy.json") {
        try {
            $policyReport = Get-Content "demo-traces/invariant-trends.policy.json" -Raw | ConvertFrom-Json -Depth 32
            if ([string]::Equals([string]$policyReport.profile, "strict", [System.StringComparison]::OrdinalIgnoreCase)) {
                $failOnExpiringSoon = $true
            }
        }
        catch {
            $failOnExpiringSoon = $false
        }
    }
    elseif ($branchName -eq "main" -or $branchName -eq "master") {
        $failOnExpiringSoon = $true
    }
    if ($failOnExpiringSoon) {
        $debtWindowArgs["FailOnExpiringSoon"] = $true
    }
    pwsh -File scripts/invariant_trend_debt_windows.ps1 @debtWindowArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "invariant trend debt-window guard failed"
    }
}
else {
    Write-Host "[15/21] invariant trend debt-window guard skipped"
}

if (-not $SkipInvariantTrendHistory -and -not $SkipInvariantTrends) {
    Write-Host "[16/21] invariant trend history"
    pwsh -File scripts/invariant_trend_history.ps1 `
        -SummaryPath demo-traces/invariant-trends.summary.json `
        -HistoryDir demo-traces/invariant-history `
        -IndexPath demo-traces/invariant-history/index.json `
        -MaxEntries 120 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "invariant trend history failed"
    }
}
else {
    Write-Host "[16/21] invariant trend history skipped"
}

if (-not $SkipInvariantTrendAnalytics -and -not $SkipInvariantTrends -and -not $SkipInvariantTrendHistory) {
    Write-Host "[17/21] invariant trend analytics"
    pwsh -File scripts/invariant_trend_analytics.ps1 `
        -HistoryIndexPath demo-traces/invariant-history/index.json `
        -AnalyticsPath demo-traces/invariant-history/analytics.json `
        -MarkdownPath demo-traces/invariant-history/analytics.md | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "invariant trend analytics failed"
    }
}
else {
    Write-Host "[17/21] invariant trend analytics skipped"
}

if (-not $SkipInvariantTrendSignals -and -not $SkipInvariantTrends) {
    Write-Host "[18/21] invariant trend signals"
    pwsh -File scripts/invariant_trend_signals.ps1 `
        -SummaryPath demo-traces/invariant-trends.summary.json `
        -GateReportPath demo-traces/invariant-trends.gate.json `
        -PolicyReportPath demo-traces/invariant-trends.policy.json `
        -DebtWindowReportPath demo-traces/invariant-trends.debt-windows.json `
        -AnalyticsPath demo-traces/invariant-history/analytics.json `
        -SignalsPath demo-traces/invariant-trends.signals.json | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "invariant trend signals failed"
    }
}
else {
    Write-Host "[18/21] invariant trend signals skipped"
}

if (-not $SkipInvariantTrendNotify -and -not $SkipInvariantTrendSignals -and -not $SkipInvariantTrends) {
    Write-Host "[19/21] invariant trend notify"
    $notifyArgs = @{
        SignalsPath = "demo-traces/invariant-trends.signals.json"
        SummaryPath = "demo-traces/invariant-trends.summary.json"
        MarkdownPath = "demo-traces/invariant-trends.notify.md"
        PayloadPath = "demo-traces/invariant-trends.notify.payload.json"
        MinSeverity = $TrendNotifyMinSeverity
    }
    $resolvedNotifyWebhook = $TrendNotifyWebhookUrl
    if ([string]::IsNullOrWhiteSpace($resolvedNotifyWebhook) -and -not [string]::IsNullOrWhiteSpace($env:INVARIANT_TREND_WEBHOOK_URL)) {
        $resolvedNotifyWebhook = $env:INVARIANT_TREND_WEBHOOK_URL
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedNotifyWebhook)) {
        $notifyArgs["WebhookUrl"] = $resolvedNotifyWebhook
    }
    if ($FailOnTrendNotifyDelivery) {
        $notifyArgs["FailOnDeliveryError"] = $true
    }
    pwsh -File scripts/invariant_trend_notify.ps1 @notifyArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "invariant trend notify failed"
    }
}
else {
    Write-Host "[19/21] invariant trend notify skipped"
}

if (-not $SkipArtifactStorageGuard) {
    Write-Host "[20/21] artifact storage guard"
    pwsh -File scripts/artifact_storage_guard.ps1 -MaxTotalMB 64 -KeepLatest 120 -MinKeep 60 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "artifact storage guard failed"
    }
}
else {
    Write-Host "[20/21] artifact storage guard skipped"
}

if (-not $SkipLean) {
    $lakeCmd = Get-Command lake -ErrorAction SilentlyContinue
    if ($null -ne $lakeCmd) {
        Write-Host "[21/21] lean kernel build"
        Push-Location semantics-lean
        try {
            lake build | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "lean kernel build failed"
            }
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Host "[21/21] lean kernel build skipped (lake not installed)"
    }
}
else {
    Write-Host "[21/21] lean kernel build skipped"
}

Write-Host "Local CI checks passed."
