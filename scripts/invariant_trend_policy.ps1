param(
    [string]$SummaryPath = "demo-traces/invariant-trends.summary.json",
    [string]$PolicyFilePath = "configs/invariant-trend-policies.json",
    [string]$Profile = "",
    [string]$BranchName = "",
    [string]$RunSource = "",
    [string]$GitHubEventName = "",
    [string]$IsPullRequest = "",
    [string]$GateReportPath = "demo-traces/invariant-trends.gate.json",
    [string]$PolicyReportPath = "demo-traces/invariant-trends.policy.json",
    [switch]$FailOnMissingPrevious
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$ThresholdKeys = @(
    "max_total_issues",
    "max_local_issues",
    "max_cluster_issues",
    "max_total_delta_increase",
    "max_local_delta_increase",
    "max_cluster_delta_increase",
    "max_single_code_delta_increase"
)

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

function Get-StringList {
    param($Value)

    $items = @()
    if ($null -eq $Value) {
        return $items
    }
    if ($Value -is [System.Array]) {
        foreach ($v in $Value) {
            $s = [string]$v
            if (-not [string]::IsNullOrWhiteSpace($s)) {
                $items += $s
            }
        }
        return $items
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($v in $Value) {
            $s = [string]$v
            if (-not [string]::IsNullOrWhiteSpace($s)) {
                $items += $s
            }
        }
        return $items
    }
    $single = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($single)) {
        $items += $single
    }
    return $items
}

function Parse-OptionalBool {
    param([string]$RawValue)

    if ([string]::IsNullOrWhiteSpace($RawValue)) {
        return $null
    }

    $normalized = $RawValue.Trim().ToLowerInvariant()
    if ($normalized -in @("1", "true", "yes", "y", "on")) {
        return $true
    }
    if ($normalized -in @("0", "false", "no", "n", "off")) {
        return $false
    }

    throw ("Invalid IsPullRequest value `{0}`; expected true/false" -f $RawValue)
}

function Test-ProfileSelectionRule {
    param(
        $Rule,
        [string]$ResolvedBranch,
        [string]$ResolvedRunSource,
        [bool]$ResolvedIsPullRequest
    )

    $branchExact = @(Get-StringList -Value $Rule.branch_exact)
    if ($branchExact.Count -gt 0) {
        $exactMatch = $false
        foreach ($candidate in $branchExact) {
            if ([string]::Equals($ResolvedBranch, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                $exactMatch = $true
                break
            }
        }
        if (-not $exactMatch) {
            return $false
        }
    }

    $branchGlob = @(Get-StringList -Value $Rule.branch_glob)
    if ($branchGlob.Count -gt 0) {
        $globMatch = $false
        foreach ($pattern in $branchGlob) {
            if ($ResolvedBranch -like $pattern) {
                $globMatch = $true
                break
            }
        }
        if (-not $globMatch) {
            return $false
        }
    }

    $branchRegexRaw = [string]$Rule.branch_regex
    if (-not [string]::IsNullOrWhiteSpace($branchRegexRaw)) {
        if (-not [regex]::IsMatch($ResolvedBranch, $branchRegexRaw, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            return $false
        }
    }

    $ruleRunSources = @(Get-StringList -Value $Rule.run_source)
    if ($ruleRunSources.Count -gt 0) {
        $runSourceMatch = $false
        foreach ($candidate in $ruleRunSources) {
            if ([string]::Equals($ResolvedRunSource, [string]$candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                $runSourceMatch = $true
                break
            }
        }
        if (-not $runSourceMatch) {
            return $false
        }
    }

    if ($Rule.PSObject.Properties.Name -contains "is_pull_request") {
        $expected = [bool]$Rule.is_pull_request
        if ($ResolvedIsPullRequest -ne $expected) {
            return $false
        }
    }

    return $true
}

function Resolve-PolicyProfile {
    param(
        $PolicyFile,
        [string[]]$AvailableProfiles,
        [string]$ResolvedBranch,
        [string]$ResolvedRunSource,
        [bool]$ResolvedIsPullRequest
    )

    $selectionConfig = $PolicyFile.profile_resolution
    $defaultProfile = [string]$PolicyFile.default_profile
    if ($null -ne $selectionConfig -and -not [string]::IsNullOrWhiteSpace([string]$selectionConfig.default_profile)) {
        $defaultProfile = [string]$selectionConfig.default_profile
    }
    if ([string]::IsNullOrWhiteSpace($defaultProfile)) {
        throw "No policy profile provided and no default profile is configured."
    }
    if ($defaultProfile -notin $AvailableProfiles) {
        throw ("Default trend policy profile `{0}` is not present in profiles." -f $defaultProfile)
    }

    $rules = @()
    if ($null -ne $selectionConfig -and $null -ne $selectionConfig.rules) {
        $rules = @($selectionConfig.rules)
    }

    for ($i = 0; $i -lt $rules.Count; $i++) {
        $rule = $rules[$i]
        if ($null -eq $rule) {
            continue
        }

        $ruleProfile = [string]$rule.profile
        if ([string]::IsNullOrWhiteSpace($ruleProfile)) {
            throw ("profile_resolution.rules[{0}] missing required 'profile'" -f $i)
        }
        if ($ruleProfile -notin $AvailableProfiles) {
            throw ("profile_resolution.rules[{0}] references unknown profile '{1}'" -f $i, $ruleProfile)
        }

        $matched = Test-ProfileSelectionRule `
            -Rule $rule `
            -ResolvedBranch $ResolvedBranch `
            -ResolvedRunSource $ResolvedRunSource `
            -ResolvedIsPullRequest $ResolvedIsPullRequest
        if ($matched) {
            return [ordered]@{
                profile = $ruleProfile
                source = "profile_resolution_rule"
                rule = [ordered]@{
                    index = $i
                    name = [string]$rule.name
                    profile = $ruleProfile
                }
                default_profile = $defaultProfile
            }
        }
    }

    return [ordered]@{
        profile = $defaultProfile
        source = "default_profile"
        rule = $null
        default_profile = $defaultProfile
    }
}

function Get-ThresholdsFromProfile {
    param($ProfileNode)

    return [ordered]@{
        max_total_issues = (Get-SafeInt -Value $ProfileNode.max_total_issues)
        max_local_issues = (Get-SafeInt -Value $ProfileNode.max_local_issues)
        max_cluster_issues = (Get-SafeInt -Value $ProfileNode.max_cluster_issues)
        max_total_delta_increase = (Get-SafeInt -Value $ProfileNode.max_total_delta_increase)
        max_local_delta_increase = (Get-SafeInt -Value $ProfileNode.max_local_delta_increase)
        max_cluster_delta_increase = (Get-SafeInt -Value $ProfileNode.max_cluster_delta_increase)
        max_single_code_delta_increase = (Get-SafeInt -Value $ProfileNode.max_single_code_delta_increase)
    }
}

function Resolve-DebtWindow {
    param(
        [string]$ProfileName,
        $ProfileNode,
        $Thresholds,
        [DateTimeOffset]$NowUtc
    )

    $state = [ordered]@{
        configured = $false
        active = $false
        expired = $false
        now_utc = $NowUtc.ToString("o")
        allow_until_utc = $null
        reason = ""
        owner = ""
        tracking_issue = ""
        applied_threshold_overrides = @{}
    }

    if ($null -eq $ProfileNode.debt_window) {
        return $state
    }

    $state.configured = $true

    $window = $ProfileNode.debt_window
    $allowUntilRaw = [string]$window.allow_until_utc
    if ([string]::IsNullOrWhiteSpace($allowUntilRaw)) {
        throw ("Trend policy profile `{0}` has debt_window but missing allow_until_utc" -f $ProfileName)
    }

    $allowUntil = Parse-UtcDateTimeOffset -RawValue $allowUntilRaw -FieldLabel "allow_until_utc"
    $state.allow_until_utc = $allowUntil.ToString("o")
    $state.reason = [string]$window.reason
    $state.owner = [string]$window.owner
    $state.tracking_issue = [string]$window.tracking_issue

    if ([string]::IsNullOrWhiteSpace($state.owner)) {
        throw ("Trend policy profile `{0}` debt window requires non-empty owner metadata" -f $ProfileName)
    }
    if ([string]::IsNullOrWhiteSpace($state.tracking_issue)) {
        throw ("Trend policy profile `{0}` debt window requires non-empty tracking_issue metadata" -f $ProfileName)
    }

    if ($NowUtc -gt $allowUntil) {
        $state.expired = $true
        throw ("Trend policy profile `{0}` debt window expired on {1} (now: {2}). owner={3} tracking_issue={4}" -f `
                $ProfileName, $allowUntil.ToString("o"), $NowUtc.ToString("o"), $state.owner, $state.tracking_issue)
    }

    $state.active = $true
    if ($null -eq $window.threshold_overrides) {
        return $state
    }

    foreach ($key in $ThresholdKeys) {
        $value = $window.threshold_overrides.$key
        if ($null -eq $value) {
            continue
        }
        $Thresholds[$key] = Get-SafeInt -Value $value -Default ([int]$Thresholds[$key])
        $state.applied_threshold_overrides[$key] = [int]$Thresholds[$key]
    }

    return $state
}

if (-not (Test-Path $PolicyFilePath)) {
    throw ("Trend policy file not found: {0}" -f $PolicyFilePath)
}

$policyFile = Get-Content $PolicyFilePath -Raw | ConvertFrom-Json -Depth 64

$availableProfiles = @()
if ($null -ne $policyFile.profiles) {
    foreach ($p in $policyFile.profiles.PSObject.Properties) {
        $availableProfiles += [string]$p.Name
    }
}
if ($availableProfiles.Count -eq 0) {
    throw "No policy profiles found in policy file."
}

if ([string]::IsNullOrWhiteSpace($BranchName)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) {
        $BranchName = [string]$env:GITHUB_REF_NAME
    }
    else {
        $BranchName = Get-GitOutputOrEmpty -GitArgs @("rev-parse", "--abbrev-ref", "HEAD")
    }
}
if ([string]::IsNullOrWhiteSpace($BranchName)) {
    $BranchName = "unknown"
}

if ([string]::IsNullOrWhiteSpace($RunSource)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)) {
        $RunSource = "github-actions"
    }
    else {
        $RunSource = "local"
    }
}
if ([string]::IsNullOrWhiteSpace($RunSource)) {
    $RunSource = "unknown"
}

if ([string]::IsNullOrWhiteSpace($GitHubEventName) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_EVENT_NAME)) {
    $GitHubEventName = [string]$env:GITHUB_EVENT_NAME
}
$parsedIsPullRequest = Parse-OptionalBool -RawValue $IsPullRequest
if ($null -eq $parsedIsPullRequest) {
    $parsedIsPullRequest = [string]::Equals($GitHubEventName, "pull_request", [System.StringComparison]::OrdinalIgnoreCase) -or `
        [string]::Equals($GitHubEventName, "pull_request_target", [System.StringComparison]::OrdinalIgnoreCase)
}

$profileSelection = $null
if ([string]::IsNullOrWhiteSpace($Profile)) {
    $resolvedIsPullRequestBool = [bool]$parsedIsPullRequest
    $profileSelection = Resolve-PolicyProfile `
        -PolicyFile $policyFile `
        -AvailableProfiles $availableProfiles `
        -ResolvedBranch $BranchName `
        -ResolvedRunSource $RunSource `
        -ResolvedIsPullRequest $resolvedIsPullRequestBool
    $Profile = [string]$profileSelection.profile
}
else {
    $profileSelection = [ordered]@{
        profile = $Profile
        source = "explicit"
        rule = $null
        default_profile = [string]$policyFile.default_profile
    }
}

$profileNode = $policyFile.profiles.$Profile
if ($null -eq $profileNode) {
    throw ("Unknown trend policy profile `{0}`. Available: {1}" -f $Profile, ($availableProfiles -join ", "))
}

$nowUtc = (Get-Date).ToUniversalTime()
$resolvedThresholds = Get-ThresholdsFromProfile -ProfileNode $profileNode
$debtWindowState = $null
$gateResult = $null
$policyError = $null

$gateArgs = @{
    SummaryPath = $SummaryPath
    GateReportPath = $GateReportPath
    MaxTotalIssues = 0
    MaxLocalIssues = 0
    MaxClusterIssues = 0
    MaxTotalDeltaIncrease = 0
    MaxLocalDeltaIncrease = 0
    MaxClusterDeltaIncrease = 0
    MaxSingleCodeDeltaIncrease = 0
}

$profileFailOnMissingPrevious = [bool]$profileNode.fail_on_missing_previous
if ($profileFailOnMissingPrevious -or $FailOnMissingPrevious) {
    $gateArgs["FailOnMissingPrevious"] = $true
}

try {
    $debtWindowState = Resolve-DebtWindow `
        -ProfileName $Profile `
        -ProfileNode $profileNode `
        -Thresholds $resolvedThresholds `
        -NowUtc $nowUtc

    $gateArgs.MaxTotalIssues = [int]$resolvedThresholds["max_total_issues"]
    $gateArgs.MaxLocalIssues = [int]$resolvedThresholds["max_local_issues"]
    $gateArgs.MaxClusterIssues = [int]$resolvedThresholds["max_cluster_issues"]
    $gateArgs.MaxTotalDeltaIncrease = [int]$resolvedThresholds["max_total_delta_increase"]
    $gateArgs.MaxLocalDeltaIncrease = [int]$resolvedThresholds["max_local_delta_increase"]
    $gateArgs.MaxClusterDeltaIncrease = [int]$resolvedThresholds["max_cluster_delta_increase"]
    $gateArgs.MaxSingleCodeDeltaIncrease = [int]$resolvedThresholds["max_single_code_delta_increase"]

    if ([bool]$debtWindowState.active) {
        Write-Host ("[invariant-trend-policy] debt window active until {0}" -f $debtWindowState.allow_until_utc)
    }

    $gateScriptPath = Join-Path $repoRoot "scripts/invariant_trend_gate.ps1"
    & $gateScriptPath @gateArgs | Out-Host
    if (-not $?) {
        throw "Invariant trend gate script failed"
    }

    if (Test-Path $GateReportPath) {
        $gateResult = Get-Content $GateReportPath -Raw | ConvertFrom-Json -Depth 64
    }
}
catch {
    $policyError = [string]$_.Exception.Message
}

if ($null -eq $debtWindowState) {
    $debtWindowState = [ordered]@{
        configured = $false
        active = $false
        expired = $false
        now_utc = $nowUtc.ToString("o")
        allow_until_utc = $null
        reason = ""
        owner = ""
        tracking_issue = ""
        applied_threshold_overrides = @{}
    }
}

$policyReport = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    summary_path = $SummaryPath
    gate_report_path = $GateReportPath
    policy_file_path = $PolicyFilePath
    profile = $Profile
    profile_description = [string]$profileNode.description
    profile_selection = $profileSelection
    context = @{
        branch = $BranchName
        run_source = $RunSource
        github_event_name = $GitHubEventName
        is_pull_request = [bool]$parsedIsPullRequest
    }
    available_profiles = $availableProfiles
    debt_window = $debtWindowState
    resolved_thresholds = @{
        max_total_issues = $gateArgs.MaxTotalIssues
        max_local_issues = $gateArgs.MaxLocalIssues
        max_cluster_issues = $gateArgs.MaxClusterIssues
        max_total_delta_increase = $gateArgs.MaxTotalDeltaIncrease
        max_local_delta_increase = $gateArgs.MaxLocalDeltaIncrease
        max_cluster_delta_increase = $gateArgs.MaxClusterDeltaIncrease
        max_single_code_delta_increase = $gateArgs.MaxSingleCodeDeltaIncrease
        fail_on_missing_previous = [bool]$gateArgs.ContainsKey("FailOnMissingPrevious")
    }
    gate = $gateResult
    error = $policyError
}

$policyReportFile = Join-Path $repoRoot $PolicyReportPath
$policyReportDir = Split-Path -Parent $policyReportFile
if (-not [string]::IsNullOrWhiteSpace($policyReportDir)) {
    New-Item -ItemType Directory -Path $policyReportDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($policyReportFile, ($policyReport | ConvertTo-Json -Depth 64))

Write-Host ("[invariant-trend-policy] profile: {0}" -f $Profile)
Write-Host ("[invariant-trend-policy] policy report written: {0}" -f $PolicyReportPath)

if (-not [string]::IsNullOrWhiteSpace($policyError)) {
    throw $policyError
}
