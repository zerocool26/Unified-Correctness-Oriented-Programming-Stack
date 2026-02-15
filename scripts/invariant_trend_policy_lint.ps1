param(
    [string]$PolicyFilePath = "configs/invariant-trend-policies.json",
    [string]$ReportPath = "demo-traces/invariant-trends.policy-lint.json",
    [switch]$FailOnWarning
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

$AllowedRunSources = @("local", "github-actions", "unknown")
$AllowedRunSourceSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($src in $AllowedRunSources) {
    $null = $AllowedRunSourceSet.Add($src)
}

$findings = New-Object System.Collections.ArrayList

function Add-Finding {
    param(
        [ValidateSet("error", "warn", "info")]
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
    [void]$script:findings.Add($item)
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

function Test-IsBoolLike {
    param($Value)

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return $true
    }
    if ($Value -is [string]) {
        $raw = ([string]$Value).Trim().ToLowerInvariant()
        return ($raw -in @("true", "false", "1", "0", "yes", "no", "on", "off", "y", "n"))
    }
    return $false
}

function Test-IsNonNegativeIntLike {
    param($Value)

    if ($null -eq $Value) {
        return $false
    }
    try {
        $num = [int]$Value
        return ($num -ge 0)
    }
    catch {
        return $false
    }
}

function Parse-BoolLikeValueOrNull {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($Value -is [string]) {
        $raw = ([string]$Value).Trim().ToLowerInvariant()
        if ($raw -in @("true", "1", "yes", "on", "y")) {
            return $true
        }
        if ($raw -in @("false", "0", "no", "off", "n")) {
            return $false
        }
    }
    return $null
}

function Test-RuleMatchForContext {
    param(
        $Rule,
        [string]$BranchName,
        [string]$RunSource,
        [bool]$IsPullRequest
    )

    $branchExact = @(Get-StringList -Value $Rule.branch_exact)
    if ($branchExact.Count -gt 0) {
        $exactMatch = $false
        foreach ($candidate in $branchExact) {
            if ([string]::Equals($BranchName, [string]$candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
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
            if ($BranchName -like $pattern) {
                $globMatch = $true
                break
            }
        }
        if (-not $globMatch) {
            return $false
        }
    }

    $branchRegex = [string]$Rule.branch_regex
    if (-not [string]::IsNullOrWhiteSpace($branchRegex)) {
        if (-not [regex]::IsMatch($BranchName, $branchRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            return $false
        }
    }

    $ruleRunSources = @(Get-StringList -Value $Rule.run_source)
    if ($ruleRunSources.Count -gt 0) {
        $runSourceMatch = $false
        foreach ($candidate in $ruleRunSources) {
            if ([string]::Equals($RunSource, [string]$candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                $runSourceMatch = $true
                break
            }
        }
        if (-not $runSourceMatch) {
            return $false
        }
    }

    if ($Rule.PSObject.Properties.Name -contains "is_pull_request") {
        $expected = Parse-BoolLikeValueOrNull -Value $Rule.is_pull_request
        if ($null -eq $expected) {
            return $false
        }
        if ([bool]$expected -ne $IsPullRequest) {
            return $false
        }
    }

    return $true
}

function Resolve-ProfileForContext {
    param(
        $Rules,
        [string]$DefaultProfile,
        [string]$BranchName,
        [string]$RunSource,
        [bool]$IsPullRequest
    )

    for ($i = 0; $i -lt $Rules.Count; $i++) {
        $rule = $Rules[$i]
        if ($null -eq $rule) {
            continue
        }
        $ruleProfile = [string]$rule.profile
        if ([string]::IsNullOrWhiteSpace($ruleProfile)) {
            continue
        }
        if (Test-RuleMatchForContext -Rule $rule -BranchName $BranchName -RunSource $RunSource -IsPullRequest $IsPullRequest) {
            return [ordered]@{
                profile = $ruleProfile
                source = "rule"
                rule_index = $i
                rule_name = [string]$rule.name
            }
        }
    }

    return [ordered]@{
        profile = $DefaultProfile
        source = "default"
        rule_index = -1
        rule_name = ""
    }
}

if (-not (Test-Path $PolicyFilePath)) {
    throw ("Trend policy file not found: {0}" -f $PolicyFilePath)
}

$policy = Get-Content $PolicyFilePath -Raw | ConvertFrom-Json -Depth 64

$profilesNode = $policy.profiles
$profileNames = @()
if ($null -ne $profilesNode) {
    foreach ($p in $profilesNode.PSObject.Properties) {
        $profileNames += [string]$p.Name
    }
}
if ($profileNames.Count -eq 0) {
    Add-Finding -Severity "error" -Code "missing_profiles" -Message "No profiles defined in policy file."
}

$profileNameSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in $profileNames) {
    $null = $profileNameSet.Add($name)
}

$topDefault = [string]$policy.default_profile
if ([string]::IsNullOrWhiteSpace($topDefault)) {
    Add-Finding -Severity "error" -Code "missing_default_profile" -Message "Top-level default_profile is missing."
}
elseif (-not $profileNameSet.Contains($topDefault)) {
    Add-Finding -Severity "error" -Code "unknown_default_profile" -Message ("Top-level default_profile `{0}` is not present in profiles." -f $topDefault)
}

$debtWindowCount = 0
foreach ($profileName in $profileNames) {
    $profile = $profilesNode.$profileName
    foreach ($key in $ThresholdKeys) {
        $value = $profile.$key
        if ($null -eq $value) {
            Add-Finding -Severity "error" -Code "missing_threshold_key" -Message ("Profile `{0}` missing required threshold key `{1}`." -f $profileName, $key)
            continue
        }
        if (-not (Test-IsNonNegativeIntLike -Value $value)) {
            Add-Finding -Severity "error" -Code "invalid_threshold_value" -Message ("Profile `{0}` has invalid non-negative integer for `{1}`: `{2}`." -f $profileName, $key, [string]$value)
        }
    }

    if ($profile.PSObject.Properties.Name -contains "fail_on_missing_previous") {
        if (-not (Test-IsBoolLike -Value $profile.fail_on_missing_previous)) {
            Add-Finding -Severity "error" -Code "invalid_fail_on_missing_previous" -Message ("Profile `{0}` has non-boolean fail_on_missing_previous." -f $profileName)
        }
    }

    if ($null -ne $profile.debt_window) {
        $debtWindowCount += 1
        $window = $profile.debt_window
        $allowUntil = [string]$window.allow_until_utc
        if ([string]::IsNullOrWhiteSpace($allowUntil)) {
            Add-Finding -Severity "error" -Code "missing_debt_window_allow_until" -Message ("Profile `{0}` debt_window missing allow_until_utc." -f $profileName)
        }
        else {
            try {
                [DateTimeOffset]::Parse(
                    $allowUntil,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
                ) | Out-Null
            }
            catch {
                Add-Finding -Severity "error" -Code "invalid_debt_window_allow_until" -Message ("Profile `{0}` debt_window has invalid allow_until_utc `{1}`." -f $profileName, $allowUntil)
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$window.owner)) {
            Add-Finding -Severity "error" -Code "missing_debt_window_owner" -Message ("Profile `{0}` debt_window requires owner." -f $profileName)
        }
        if ([string]::IsNullOrWhiteSpace([string]$window.tracking_issue)) {
            Add-Finding -Severity "error" -Code "missing_debt_window_tracking_issue" -Message ("Profile `{0}` debt_window requires tracking_issue." -f $profileName)
        }

        if ($null -ne $window.threshold_overrides) {
            foreach ($prop in $window.threshold_overrides.PSObject.Properties) {
                $overrideKey = [string]$prop.Name
                if ($overrideKey -notin $ThresholdKeys) {
                    Add-Finding -Severity "error" -Code "unknown_debt_window_override_key" -Message ("Profile `{0}` debt_window.threshold_overrides contains unknown key `{1}`." -f $profileName, $overrideKey)
                    continue
                }
                if (-not (Test-IsNonNegativeIntLike -Value $prop.Value)) {
                    Add-Finding -Severity "error" -Code "invalid_debt_window_override_value" -Message ("Profile `{0}` debt_window override `{1}` must be non-negative integer." -f $profileName, $overrideKey)
                }
            }
        }
    }
}

$profileResolution = $policy.profile_resolution
$ruleCount = 0
$ruleNameSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
$broadCatchAllRuleIndexes = @()
$rules = @()
$effectiveResolutionDefault = $topDefault
$resolutionTests = @()
$executedResolutionTests = 0
$failedResolutionTests = 0

if ($null -eq $profileResolution) {
    Add-Finding -Severity "warn" -Code "missing_profile_resolution" -Message "profile_resolution is not configured; policy auto-selection will use default_profile only."
}
else {
    $resolutionDefault = [string]$profileResolution.default_profile
    if (-not [string]::IsNullOrWhiteSpace($resolutionDefault)) {
        if (-not $profileNameSet.Contains($resolutionDefault)) {
            Add-Finding -Severity "error" -Code "unknown_profile_resolution_default" -Message ("profile_resolution.default_profile '{0}' is not present in profiles." -f $resolutionDefault)
        }
        else {
            $effectiveResolutionDefault = $resolutionDefault
        }
    }

    if ($null -ne $profileResolution.rules) {
        $rules = @($profileResolution.rules)
    }
    $ruleCount = $rules.Count
    if ($rules.Count -eq 0) {
        Add-Finding -Severity "warn" -Code "empty_profile_resolution_rules" -Message "profile_resolution.rules is empty; only default profile selection is possible."
    }

    for ($i = 0; $i -lt $rules.Count; $i++) {
        $rule = $rules[$i]
        if ($null -eq $rule) {
            Add-Finding -Severity "error" -Code "null_rule" -Message ("profile_resolution.rules[{0}] is null." -f $i)
            continue
        }

        $ruleName = [string]$rule.name
        if ([string]::IsNullOrWhiteSpace($ruleName)) {
            Add-Finding -Severity "warn" -Code "unnamed_rule" -Message ("profile_resolution.rules[{0}] has no name." -f $i)
        }
        else {
            if (-not $ruleNameSet.Add($ruleName)) {
                Add-Finding -Severity "error" -Code "duplicate_rule_name" -Message ("Duplicate profile_resolution rule name `{0}`." -f $ruleName)
            }
        }

        $ruleProfile = [string]$rule.profile
        if ([string]::IsNullOrWhiteSpace($ruleProfile)) {
            Add-Finding -Severity "error" -Code "missing_rule_profile" -Message ("profile_resolution.rules[{0}] missing required profile." -f $i)
        }
        elseif (-not $profileNameSet.Contains($ruleProfile)) {
            Add-Finding -Severity "error" -Code "unknown_rule_profile" -Message ("profile_resolution.rules[{0}] references unknown profile '{1}'." -f $i, $ruleProfile)
        }

        $branchExact = @(Get-StringList -Value $rule.branch_exact)
        $branchGlob = @(Get-StringList -Value $rule.branch_glob)
        $branchRegex = [string]$rule.branch_regex
        $runSources = @(Get-StringList -Value $rule.run_source)
        $hasIsPullRequest = ($rule.PSObject.Properties.Name -contains "is_pull_request")

        foreach ($val in $branchExact) {
            if ([string]::IsNullOrWhiteSpace([string]$val)) {
                Add-Finding -Severity "error" -Code "invalid_branch_exact_entry" -Message ("profile_resolution.rules[{0}] contains empty branch_exact entry." -f $i)
            }
        }
        foreach ($val in $branchGlob) {
            if ([string]::IsNullOrWhiteSpace([string]$val)) {
                Add-Finding -Severity "error" -Code "invalid_branch_glob_entry" -Message ("profile_resolution.rules[{0}] contains empty branch_glob entry." -f $i)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($branchRegex)) {
            try {
                [regex]::new($branchRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | Out-Null
            }
            catch {
                Add-Finding -Severity "error" -Code "invalid_branch_regex" -Message ("profile_resolution.rules[{0}] has invalid branch_regex `{1}`." -f $i, $branchRegex)
            }
        }

        foreach ($src in $runSources) {
            if (-not $AllowedRunSourceSet.Contains([string]$src)) {
                Add-Finding -Severity "warn" -Code "unknown_rule_run_source" -Message ("profile_resolution.rules[{0}] has non-standard run_source `{1}`." -f $i, [string]$src)
            }
        }

        if ($hasIsPullRequest) {
            if (-not (Test-IsBoolLike -Value $rule.is_pull_request)) {
                Add-Finding -Severity "error" -Code "invalid_rule_is_pull_request" -Message ("profile_resolution.rules[{0}] has non-boolean is_pull_request." -f $i)
            }
        }

        $selectorCount = 0
        if ($branchExact.Count -gt 0) { $selectorCount += 1 }
        if ($branchGlob.Count -gt 0) { $selectorCount += 1 }
        if (-not [string]::IsNullOrWhiteSpace($branchRegex)) { $selectorCount += 1 }
        if ($runSources.Count -gt 0) { $selectorCount += 1 }
        if ($hasIsPullRequest) { $selectorCount += 1 }

        if ($selectorCount -eq 0) {
            Add-Finding -Severity "error" -Code "rule_without_selectors" -Message ("profile_resolution.rules[{0}] has no selectors; this is a broad catch-all and should be explicit." -f $i)
        }

        $isBroadCatchAll = ($branchExact.Count -eq 0) -and `
            ($runSources.Count -eq 0) -and `
            (-not $hasIsPullRequest) -and `
            ([string]::IsNullOrWhiteSpace($branchRegex)) -and `
            ($branchGlob.Count -eq 1) -and `
            ([string]$branchGlob[0] -eq "*")
        if ($isBroadCatchAll) {
            $broadCatchAllRuleIndexes += $i
        }
    }

    foreach ($idx in $broadCatchAllRuleIndexes) {
        if ($idx -lt ($rules.Count - 1)) {
            Add-Finding -Severity "warn" -Code "broad_catch_all_not_last" -Message ("profile_resolution.rules[{0}] is a broad catch-all (`*`) and should be last." -f $idx)
        }
    }
    if ($broadCatchAllRuleIndexes.Count -gt 1) {
        Add-Finding -Severity "warn" -Code "multiple_broad_catch_all_rules" -Message ("Found {0} broad catch-all rules; only one should normally exist." -f $broadCatchAllRuleIndexes.Count)
    }

    if ($null -ne $profileResolution.tests) {
        $resolutionTests = @($profileResolution.tests)
    }
}

if ($resolutionTests.Count -eq 0) {
    Add-Finding -Severity "warn" -Code "empty_profile_resolution_tests" -Message "profile_resolution.tests is empty; rule behavior is not being asserted with deterministic test contexts."
}
else {
    $testNameSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    for ($ti = 0; $ti -lt $resolutionTests.Count; $ti++) {
        $testCase = $resolutionTests[$ti]
        if ($null -eq $testCase) {
            Add-Finding -Severity "error" -Code "null_profile_resolution_test" -Message ("profile_resolution.tests[{0}] is null." -f $ti)
            $failedResolutionTests += 1
            continue
        }

        $testName = [string]$testCase.name
        if ([string]::IsNullOrWhiteSpace($testName)) {
            $testName = ("case-{0}" -f $ti)
            Add-Finding -Severity "warn" -Code "unnamed_profile_resolution_test" -Message ("profile_resolution.tests[{0}] has no name; using `{1}` for reporting." -f $ti, $testName)
        }
        elseif (-not $testNameSet.Add($testName)) {
            Add-Finding -Severity "warn" -Code "duplicate_profile_resolution_test_name" -Message ("Duplicate profile_resolution test name `{0}`." -f $testName)
        }

        $expectedProfile = [string]$testCase.expected_profile
        $branchName = [string]$testCase.branch
        $runSource = [string]$testCase.run_source
        if ([string]::IsNullOrWhiteSpace($runSource)) {
            $runSource = "local"
        }
        $parsedTestIsPullRequest = $false
        $isPullRequestValid = $true
        if ($testCase.PSObject.Properties.Name -contains "is_pull_request") {
            $parsedMaybe = Parse-BoolLikeValueOrNull -Value $testCase.is_pull_request
            if ($null -eq $parsedMaybe) {
                $isPullRequestValid = $false
                Add-Finding -Severity "error" -Code "invalid_profile_resolution_test_is_pull_request" -Message ("profile_resolution.tests[{0}] (`{1}`) has non-boolean is_pull_request." -f $ti, $testName)
            }
            else {
                $parsedTestIsPullRequest = [bool]$parsedMaybe
            }
        }

        $testHasError = $false
        if ([string]::IsNullOrWhiteSpace($expectedProfile)) {
            Add-Finding -Severity "error" -Code "missing_profile_resolution_test_expected_profile" -Message ("profile_resolution.tests[{0}] (`{1}`) missing expected_profile." -f $ti, $testName)
            $testHasError = $true
        }
        elseif (-not $profileNameSet.Contains($expectedProfile)) {
            Add-Finding -Severity "error" -Code "unknown_profile_resolution_test_expected_profile" -Message ("profile_resolution.tests[{0}] (`{1}`) references unknown expected_profile `{2}`." -f $ti, $testName, $expectedProfile)
            $testHasError = $true
        }

        if ([string]::IsNullOrWhiteSpace($branchName)) {
            Add-Finding -Severity "error" -Code "missing_profile_resolution_test_branch" -Message ("profile_resolution.tests[{0}] (`{1}`) missing branch." -f $ti, $testName)
            $testHasError = $true
        }

        if (-not $AllowedRunSourceSet.Contains($runSource)) {
            Add-Finding -Severity "warn" -Code "unknown_profile_resolution_test_run_source" -Message ("profile_resolution.tests[{0}] (`{1}`) uses non-standard run_source `{2}`." -f $ti, $testName, $runSource)
        }

        if (-not $isPullRequestValid) {
            $testHasError = $true
        }
        if ($testHasError) {
            $failedResolutionTests += 1
            continue
        }

        $executedResolutionTests += 1
        $resolved = Resolve-ProfileForContext `
            -Rules $rules `
            -DefaultProfile $effectiveResolutionDefault `
            -BranchName $branchName `
            -RunSource $runSource `
            -IsPullRequest $parsedTestIsPullRequest

        if (-not [string]::Equals([string]$resolved.profile, $expectedProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
            $failedResolutionTests += 1
            Add-Finding -Severity "error" -Code "profile_resolution_test_mismatch" -Message ("profile_resolution.tests[{0}] (`{1}`) expected `{2}` but resolved `{3}`." -f $ti, $testName, $expectedProfile, [string]$resolved.profile) -Data @{
                test_name = $testName
                branch = $branchName
                run_source = $runSource
                is_pull_request = [bool]$parsedTestIsPullRequest
                expected_profile = $expectedProfile
                resolved_profile = [string]$resolved.profile
                resolved_source = [string]$resolved.source
                resolved_rule_index = [int]$resolved.rule_index
                resolved_rule_name = [string]$resolved.rule_name
            }
        }
    }
}

$errorCount = @($findings | Where-Object { [string]$_.severity -eq "error" }).Count
$warnCount = @($findings | Where-Object { [string]$_.severity -eq "warn" }).Count
$infoCount = @($findings | Where-Object { [string]$_.severity -eq "info" }).Count

$report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    policy_file_path = $PolicyFilePath
    profile_count = $profileNames.Count
    debt_window_count = $debtWindowCount
    profile_resolution = @{
        default_profile = $effectiveResolutionDefault
        rule_count = $ruleCount
        broad_catch_all_rule_indexes = $broadCatchAllRuleIndexes
        test_count = $resolutionTests.Count
        executed_test_count = $executedResolutionTests
        failed_test_count = $failedResolutionTests
    }
    counts = @{
        total = $findings.Count
        error = $errorCount
        warn = $warnCount
        info = $infoCount
    }
    pass = ($errorCount -eq 0 -and (-not $FailOnWarning -or $warnCount -eq 0))
    findings = $findings
}

$reportFile = Join-Path $repoRoot $ReportPath
$reportDir = Split-Path -Parent $reportFile
if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($reportFile, ($report | ConvertTo-Json -Depth 64))

Write-Host ("[invariant-trend-policy-lint] report written: {0}" -f $ReportPath)
Write-Host ("[invariant-trend-policy-lint] findings total={0} error={1} warn={2} info={3}" -f `
        $report.counts.total, $report.counts.error, $report.counts.warn, $report.counts.info)

if ($errorCount -gt 0) {
    throw ("Invariant trend policy lint failed with {0} error(s)." -f $errorCount)
}
if ($FailOnWarning -and $warnCount -gt 0) {
    throw ("Invariant trend policy lint failed with {0} warning(s) and FailOnWarning enabled." -f $warnCount)
}
