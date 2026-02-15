param(
    [string]$IndexPath = "demo-traces/cluster-fault-matrix.index.json",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function New-CountMap {
    return @{
        Drop = 0
        Delay = 0
        Reorder = 0
    }
}

function New-IssueBucket {
    return @{}
}

function Add-IssueCounts {
    param(
        [hashtable]$Bucket,
        $Issues
    )

    foreach ($issue in @($Issues)) {
        $code = [string]$issue.code
        if ([string]::IsNullOrWhiteSpace($code)) {
            $code = "unknown"
        }
        if (-not $Bucket.ContainsKey($code)) {
            $Bucket[$code] = 0
        }
        $Bucket[$code] += 1
    }
}

function Merge-IssueBucket {
    param(
        [hashtable]$Into,
        [hashtable]$From
    )

    foreach ($key in $From.Keys) {
        if (-not $Into.ContainsKey($key)) {
            $Into[$key] = 0
        }
        $Into[$key] += [int]$From[$key]
    }
}

function Get-IssueBucketTotal {
    param([hashtable]$Bucket)
    $total = 0
    foreach ($value in $Bucket.Values) {
        $total += [int]$value
    }
    return $total
}

function Get-InvariantIssueRollups {
    param(
        [string[]]$VerifyReportPaths,
        [string]$ClusterReportPath
    )

    $localBucket = New-IssueBucket
    $clusterBucket = New-IssueBucket
    $localReportCount = 0

    foreach ($path in $VerifyReportPaths) {
        if (-not (Test-Path $path)) {
            continue
        }
        $localReportCount += 1
        $report = Get-Content $path -Raw | ConvertFrom-Json -Depth 64
        Add-IssueCounts -Bucket $localBucket -Issues $report.issues
    }

    if (Test-Path $ClusterReportPath) {
        $clusterReport = Get-Content $ClusterReportPath -Raw | ConvertFrom-Json -Depth 64
        if ($localReportCount -eq 0 -and $null -ne $clusterReport.local) {
            foreach ($local in $clusterReport.local) {
                Add-IssueCounts -Bucket $localBucket -Issues $local.issues
            }
        }
        if ($null -ne $clusterReport.cluster) {
            Add-IssueCounts -Bucket $clusterBucket -Issues $clusterReport.cluster.issues
        }
    }

    return @{
        local_verify = $localBucket
        cluster_verify = $clusterBucket
    }
}

function New-NodeId {
    param([int]$Suffix)
    return ("00000000-0000-0000-0000-{0:x12}" -f $Suffix)
}

if (-not $SkipBuild) {
    Write-Host "[cluster-fault-matrix] building runtime + tool..."
    cargo build -p runtime -p tool | Out-Host
}
else {
    Write-Host "[cluster-fault-matrix] build skipped (using existing binaries)"
}

New-Item -ItemType Directory -Path (Join-Path $repoRoot "demo-traces") -Force | Out-Null

$profiles = @(
    @{
        Name = "delay-reorder"
        Delay = 2
        Reorder = 2
        DropEvery = 0
        BootstrapBurst = 3
    },
    @{
        Name = "delay-drop"
        Delay = 1
        Reorder = 1
        DropEvery = 3
        BootstrapBurst = 3
    },
    @{
        Name = "reorder-drop"
        Delay = 0
        Reorder = 3
        DropEvery = 4
        BootstrapBurst = 3
    }
)

$targets = @("node1", "node2")
$scenarios = @()
$scenarioIndex = 0
foreach ($target in $targets) {
    foreach ($profile in $profiles) {
        $scenarioIndex += 1
        $portBase = 7600 + ($scenarioIndex * 10)
        $idBase = 0x700 + ($scenarioIndex * 10)
        $reportPrefix = "cluster-fault-$target-$($profile.Name)"

        $scenarios += @{
            Name = "$($profile.Name)-target-$target"
            ReportPrefix = $reportPrefix
            FaultTarget = $target
            Node1Id = (New-NodeId -Suffix ($idBase + 1))
            Node2Id = (New-NodeId -Suffix ($idBase + 2))
            Node1Port = ($portBase + 1)
            Node2Port = ($portBase + 2)
            Node1Trace = "demo-traces/$reportPrefix-node1.trace.jsonl"
            Node2Trace = "demo-traces/$reportPrefix-node2.trace.jsonl"
            Delay = $profile.Delay
            Reorder = $profile.Reorder
            DropEvery = $profile.DropEvery
            BootstrapBurst = $profile.BootstrapBurst
        }
    }
}

$results = @()
for ($i = 0; $i -lt $scenarios.Count; $i++) {
    $s = $scenarios[$i]
    $summaryPath = "demo-traces/$($s.ReportPrefix).scenario.json"
    $node1VerifyReportPath = "demo-traces/$($s.ReportPrefix)-node1.verify.report.json"
    $node2VerifyReportPath = "demo-traces/$($s.ReportPrefix)-node2.verify.report.json"
    $clusterVerifyReportPath = "demo-traces/$($s.ReportPrefix).verify.report.json"

    Write-Host ("[cluster-fault-matrix] [{0}/{1}] running {2}" -f ($i + 1), $scenarios.Count, $s.Name)

    $scenarioError = $null
    try {
        & pwsh -File scripts/cluster_fault_scenario.ps1 `
            -ScenarioName $s.Name `
            -ReportPrefix $s.ReportPrefix `
            -ScenarioReportPath $summaryPath `
            -Node1Id $s.Node1Id `
            -Node2Id $s.Node2Id `
            -Node1Port $s.Node1Port `
            -Node2Port $s.Node2Port `
            -Node1Trace $s.Node1Trace `
            -Node2Trace $s.Node2Trace `
            -BootstrapBurst $s.BootstrapBurst `
            -FaultTarget $s.FaultTarget `
            -FaultDelaySteps $s.Delay `
            -FaultReorderWindow $s.Reorder `
            -FaultDropEvery $s.DropEvery `
            -SkipBuild | Out-Host

        if ($LASTEXITCODE -ne 0) {
            throw ("cluster fault scenario exited with code {0}" -f $LASTEXITCODE)
        }
    }
    catch {
        $scenarioError = $_.Exception.Message
        Write-Host ("[cluster-fault-matrix] scenario failed: {0}" -f $scenarioError)
    }

    $rollups = Get-InvariantIssueRollups `
        -VerifyReportPaths @($node1VerifyReportPath, $node2VerifyReportPath) `
        -ClusterReportPath $clusterVerifyReportPath

    if (Test-Path $summaryPath) {
        $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json -Depth 64
    }
    else {
        $summary = [ordered]@{
            scenario = $s.Name
            ok = $false
            traces = @($s.Node1Trace, $s.Node2Trace)
            reports = @{
                node1_verify = $node1VerifyReportPath
                node2_verify = $node2VerifyReportPath
                cluster_verify = $clusterVerifyReportPath
            }
            fault_config = @{
                target = $s.FaultTarget
                drop_every = $s.DropEvery
                delay_steps = $s.Delay
                reorder_window = $s.Reorder
            }
        }
    }

    if ($null -ne $scenarioError) {
        $summary | Add-Member -NotePropertyName ok -NotePropertyValue $false -Force
        $summary | Add-Member -NotePropertyName error -NotePropertyValue $scenarioError -Force
    }
    else {
        $summary | Add-Member -NotePropertyName error -NotePropertyValue $null -Force
    }

    $issueCounts = @{
        local_verify = (Get-IssueBucketTotal -Bucket $rollups.local_verify)
        cluster_verify = (Get-IssueBucketTotal -Bucket $rollups.cluster_verify)
    }
    $summary | Add-Member -NotePropertyName invariant_buckets -NotePropertyValue $rollups -Force
    $summary | Add-Member -NotePropertyName issue_counts -NotePropertyValue $issueCounts -Force

    $results += $summary
}

$passed = @($results | Where-Object { $_.ok })
$failed = @($results | Where-Object { -not $_.ok })

$aggregateFaultCountsTarget = New-CountMap
$aggregateFaultCountsByNode = @{
    node1 = (New-CountMap)
    node2 = (New-CountMap)
}
$aggregateTraffic = @{
    node1_net_send = 0
    node1_net_recv = 0
    node2_net_send = 0
    node2_net_recv = 0
}
$aggregateClusterVerify = @{
    matched_recv = 0
    matched_drop = 0
    resolved_lineage_parents = 0
    external_lineage_parents = 0
    external_inbound = 0
    external_outbound = 0
}
$aggregateIssueBuckets = @{
    local_verify = (New-IssueBucket)
    cluster_verify = (New-IssueBucket)
}

foreach ($r in $results) {
    if ($null -ne $r.invariant_buckets) {
        Merge-IssueBucket -Into $aggregateIssueBuckets.local_verify -From $r.invariant_buckets.local_verify
        Merge-IssueBucket -Into $aggregateIssueBuckets.cluster_verify -From $r.invariant_buckets.cluster_verify
    }
}

foreach ($r in $passed) {
    $faultCountsTarget = if ($null -ne $r.fault_counts_target) { $r.fault_counts_target } else { $r.fault_counts }
    $aggregateFaultCountsTarget.Drop += [int]$faultCountsTarget.Drop
    $aggregateFaultCountsTarget.Delay += [int]$faultCountsTarget.Delay
    $aggregateFaultCountsTarget.Reorder += [int]$faultCountsTarget.Reorder

    if ($null -ne $r.fault_counts_by_node) {
        foreach ($nodeName in @("node1", "node2")) {
            $aggregateFaultCountsByNode[$nodeName].Drop += [int]$r.fault_counts_by_node.$nodeName.Drop
            $aggregateFaultCountsByNode[$nodeName].Delay += [int]$r.fault_counts_by_node.$nodeName.Delay
            $aggregateFaultCountsByNode[$nodeName].Reorder += [int]$r.fault_counts_by_node.$nodeName.Reorder
        }
    }
    elseif ($null -ne $r.fault_counts) {
        $aggregateFaultCountsByNode.node2.Drop += [int]$r.fault_counts.Drop
        $aggregateFaultCountsByNode.node2.Delay += [int]$r.fault_counts.Delay
        $aggregateFaultCountsByNode.node2.Reorder += [int]$r.fault_counts.Reorder
    }

    $aggregateTraffic.node1_net_send += [int]$r.traffic.node1_net_send
    $aggregateTraffic.node1_net_recv += [int]$r.traffic.node1_net_recv
    $aggregateTraffic.node2_net_send += [int]$r.traffic.node2_net_send
    $aggregateTraffic.node2_net_recv += [int]$r.traffic.node2_net_recv

    $aggregateClusterVerify.matched_recv += [int]$r.cluster_verify.matched_recv
    $aggregateClusterVerify.matched_drop += [int]$r.cluster_verify.matched_drop
    $aggregateClusterVerify.resolved_lineage_parents += [int]$r.cluster_verify.resolved_lineage_parents
    $aggregateClusterVerify.external_lineage_parents += [int]$r.cluster_verify.external_lineage_parents
    $aggregateClusterVerify.external_inbound += [int]$r.cluster_verify.external_inbound
    $aggregateClusterVerify.external_outbound += [int]$r.cluster_verify.external_outbound
}

$aggregateIssueCounts = @{
    local_verify = (Get-IssueBucketTotal -Bucket $aggregateIssueBuckets.local_verify)
    cluster_verify = (Get-IssueBucketTotal -Bucket $aggregateIssueBuckets.cluster_verify)
}

$index = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    matrix = "cluster-fault-2node"
    scenario_count = $results.Count
    passed_count = $passed.Count
    failed_count = $failed.Count
    aggregate = @{
        fault_counts_target = $aggregateFaultCountsTarget
        fault_counts_by_node = $aggregateFaultCountsByNode
        traffic = $aggregateTraffic
        cluster_verify = $aggregateClusterVerify
        invariant_buckets = $aggregateIssueBuckets
        issue_counts = $aggregateIssueCounts
    }
    scenarios = $results
}

$indexJson = $index | ConvertTo-Json -Depth 64
[System.IO.File]::WriteAllText((Join-Path $repoRoot $IndexPath), $indexJson)

Write-Host ("[cluster-fault-matrix] index written: {0}" -f $IndexPath)
Write-Host ("[cluster-fault-matrix] scenarios passed: {0}/{1}" -f $passed.Count, $results.Count)

if ($failed.Count -gt 0) {
    $failedNames = @($failed | ForEach-Object { [string]$_.scenario })
    throw ("cluster-fault-matrix failed scenarios: {0}" -f ($failedNames -join ", "))
}
